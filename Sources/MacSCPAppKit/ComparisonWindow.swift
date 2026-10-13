import AppKit
import Observation
import SwiftUI
import macSCPCore

/// What a comparison window opens with: the tab that owns the connection and
/// the comparison on it, as identifiers.
///
/// **Ids only, like `WindowSeed`.** A seed is persisted by SwiftUI and may be
/// compared, so it names things and carries none of them; the live objects
/// are found through `TabRegistry` when the window appears
/// (`ComparisonWindowModel.resolve(seed:registry:)`). It is not written to
/// `windows.json` and is not restored: its scene turns system restoration
/// off, because both ids mean nothing in the process after a relaunch.
///
/// **Equality is per comparison, on purpose.** `WindowSeed` carries a fresh
/// `id` to defeat window reuse — a seed there is consumed by one window. Here
/// the opposite is wanted: asking for the same comparison twice should raise
/// the window that shows it, not open a second one over the same object, so
/// two seeds for one comparison are equal.
///
/// The struct body holds stored properties and nothing else.
struct ComparisonSeed: Codable, Hashable, Sendable {
    let tabID: UUID
    let comparisonID: UUID
}

/// What the window knows about the comparison it shows, in one object so the
/// rules can be tested without a view.
///
/// **It resolves ONCE and holds the object.** The comparison belongs to the
/// tab. When that tab is torn down, `SessionTab.endComparisons()` removes it
/// from `tab.comparisons` and, deliberately, keeps its rows, progress and
/// outcome — a result the user may have waited ten minutes for. A window that
/// looked the comparison up again on every render would turn that finished
/// result into "gone". So `resolve(seed:registry:)` latches, and nothing else
/// in this file touches the registry or the tab.
///
/// **It holds the comparison and nothing the comparison borrows.** The file
/// systems and the transfer queue are the comparison's to offer and to let
/// go of (`Comparison.fileSystems`, `releaseFileSystems()`); this object has
/// no reference to the tab, the session or any file system, so a closed
/// session cannot be kept open by a window that is still on screen.
/// `ComparisonWindowWiringGuardTests` reads the stored properties to say so.
///
/// **Two states that look alike and are not.**
/// - `isUnavailable`: the lookup found nothing — the registry no longer knows
///   the tab, or the tab no longer lists the comparison. There is nothing to
///   show.
/// - `isSessionClosed`: a comparison IS held and has let go of its file
///   systems. The rows stay readable; whatever needs a connection is
///   unavailable because it cannot be done, not because a view declines to
///   offer it.
///
/// A comparison that is unfinished and without file systems does not occur
/// after a teardown — the cancel runs before the release — and this type does
/// not design for it.
@MainActor
@Observable
final class ComparisonWindowModel {
    private(set) var comparison: Comparison?
    private(set) var hasResolved = false
    /// How this window tells the tab to forget its comparison when it closes.
    /// Captures the tab WEAKLY and the comparison's id, so the model holds no
    /// reference to the tab and cannot keep its session alive.
    private var forgetFromTab: (@MainActor () -> Void)?

    var isUnavailable: Bool {
        hasResolved && comparison == nil
    }

    var isSessionClosed: Bool {
        guard let comparison else { return false }
        return comparison.fileSystems == nil
    }

    /// Finds the comparison the seed names, the first time it is called, and
    /// does nothing afterwards: a window is for one comparison for as long as
    /// it is open, and a later call — with this seed or another — must not
    /// replace what is held.
    func resolve(seed: ComparisonSeed, registry: TabRegistry) {
        guard !hasResolved else { return }
        hasResolved = true
        let tab = registry.tab(for: seed.tabID)
        comparison = tab?.comparison(id: seed.comparisonID)
        if let held = comparison {
            let id = held.id
            forgetFromTab = { [weak tab] in tab?.forgetComparison(id: id) }
        }
    }

    /// The window is closing, and the user is done with this comparison.
    ///
    /// Cancels the walk and releases the file systems, in that order — the
    /// order `SessionTab.endComparisons()` uses. The release is the point:
    /// `Comparison.cancel()` does not remove the fetched files (a cancel is
    /// not a statement about a diff somebody is reading), so the temporary
    /// directory goes only with `releaseFileSystems()`, and while the TAB
    /// stays open nothing else would ever call it. The cancel is what stops a
    /// walk nobody can see any more from going on using the connection; it is
    /// a no-op on a comparison that already finished, and the outcome stays.
    ///
    /// Then the tab forgets it (`SessionTab.forgetComparison(id:)`): this
    /// comparison is closed, and a window opened later from the same seed
    /// must find nothing ("no longer available") rather than a released
    /// comparison that says "session closed" about a session that is open.
    /// The window's own reference is untouched, so what it shows while it
    /// finishes closing is unchanged.
    ///
    /// Idempotent, and a no-op for a window that held nothing. When the tab
    /// itself is closed first, teardown has already done the first two and
    /// the tab is gone, so there is nothing to forget.
    func windowClosed() {
        guard let comparison else { return }
        comparison.cancel()
        comparison.releaseFileSystems()
        forgetFromTab?()
        forgetFromTab = nil
    }
}

/// The window that shows one `Comparison` (diff view, Task 9): its shell, its
/// resolution and its states. The folder overview and the content diff are
/// drawn inside it by later tasks.
///
/// **It holds no connection.** It stores its seed and a model that stores the
/// comparison; the connection stays with the `SessionTab` that owns it, and
/// the window is a view onto a result.
///
/// **Closing.** The window listens for ITS OWN `willClose`, with the same
/// identity check `ContentView` uses, and tells the model. `onDisappear` is
/// not used: it is a statement about a view and not about a window.
struct ComparisonWindow: View {
    let seed: ComparisonSeed
    @State private var model = ComparisonWindowModel()
    @State private var window: NSWindow?

    var body: some View {
        content
            .frame(minWidth: 640, minHeight: 420)
            .background(
                WindowAccessor { resolved in
                    if window !== resolved { window = resolved }
                }
            )
            .onAppear { model.resolve(seed: seed, registry: .shared) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) {
                notification in
                guard let closing = notification.object as? NSWindow, closing === window else {
                    return
                }
                model.windowClosed()
            }
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasResolved {
            ProgressView().controlSize(.small)
        } else if let comparison = model.comparison {
            held(comparison)
        } else {
            unavailable
        }
    }

    private var unavailable: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            L10n.text(
                "compare.window.unavailable",
                "This comparison is no longer available: its session was closed before this window could show it."
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The comparison this window holds, whatever became of its session.
    private func held(_ comparison: Comparison) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            roots(of: comparison)
            Divider()
            notices(for: comparison)
            // The folder overview (Task 10) and the content diff (Task 11)
            // are drawn here, from `comparison`. Anything in them that needs
            // a connection reads `comparison.fileSystems`, which is `nil`
            // once the session has closed.
            Spacer(minLength: 0)
        }
    }

    private func roots(of comparison: Comparison) -> some View {
        HStack(spacing: 8) {
            Text(comparison.leftRoot)
                .lineLimit(1).truncationMode(.middle)
            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(comparison.rightRoot)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if comparison.isRunning {
                ProgressView().controlSize(.small)
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func notices(for comparison: Comparison) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch comparison.outcome {
            case .cancelled?:
                Label {
                    L10n.text(
                        "compare.window.cancelled",
                        "This comparison was stopped before it finished. The list is incomplete.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            case .failed?:
                Label {
                    L10n.text(
                        "compare.window.failed",
                        "This comparison could not be completed. The list is incomplete.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            case .completed?, nil:
                EmptyView()
            }
            if model.isSessionClosed {
                Label {
                    L10n.text(
                        "compare.window.sessionClosed",
                        "The session this comparison ran over has been closed. The result stays readable, but the contents of files can no longer be fetched."
                    )
                } icon: {
                    Image(systemName: "bolt.horizontal.circle")
                }
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
