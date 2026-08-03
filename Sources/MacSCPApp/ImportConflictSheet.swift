import SwiftUI
import macSCPCore

/// Sheet item wrapper giving `ImportConflict` `Identifiable` conformance
/// without extending the Core type — same reason `ConflictPromptItem` exists
/// for transfers. One fresh id per prompt is enough: an import run resolves
/// its conflicts strictly one at a time.
struct ImportConflictPromptItem: Identifiable {
    let id = UUID()
    let conflict: ImportConflict
}

/// Turns `ImportConflictSheet`'s two callbacks into the `(resolution,
/// applyToAll)?` an `ImportConflictArbiter`'s decider must return — the import
/// twin of `ConflictPromptBridge` (transfers), down to the cancellation
/// handler.
///
/// **Exactly-once resumption** is the whole point, and it holds on every path:
/// - `resolve` is the ONLY place the continuation is ever resumed. It clears
///   `self.continuation` before resuming, so a second call (double click, or
///   a dismissal racing a button tap) finds `nil` and returns.
/// - The sheet is `.interactiveDismissDisabled(true)`, so Escape and
///   click-outside cannot answer it behind the bridge's back; every exit is
///   one of the buttons, and every button calls `onResolve`/`onCancel`.
/// - `.sheet(item:)` in the presenting view additionally routes its own
///   `onDismiss` (and a `nil` write to the binding) through `dismiss()`, which
///   is just `resolve(nil)` — harmless after a button already answered,
///   because of the guard above, and the safety net if the sheet ever
///   disappears for a reason outside its own buttons.
/// - If the planning task is cancelled while the prompt is open, the
///   cancellation handler resolves it as "cancel" instead of leaving the
///   continuation hanging forever.
@MainActor
@Observable
final class ImportConflictBridge {
    private(set) var currentPrompt: ImportConflictPromptItem?
    private var continuation:
        CheckedContinuation<(resolution: ImportConflictResolution, applyToAll: Bool)?, Never>?

    /// Decider side: awaited by `ImportConflictArbiter`.
    func ask(_ conflict: ImportConflict) async
        -> (resolution: ImportConflictResolution, applyToAll: Bool)?
    {
        currentPrompt = ImportConflictPromptItem(conflict: conflict)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    currentPrompt = nil
                    continuation.resume(returning: nil)
                    return
                }
                self.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(nil)
            }
        }
    }

    /// Called from the sheet's buttons. Exactly-once: a second resolution is
    /// ignored.
    func resolve(_ result: (resolution: ImportConflictResolution, applyToAll: Bool)?) {
        guard let continuation else {
            // No pending question — but a prompt may still be on screen from
            // the `Task.isCancelled` fast path above; make sure it goes away.
            currentPrompt = nil
            return
        }
        self.continuation = nil
        currentPrompt = nil
        continuation.resume(returning: result)
    }

    /// Resolves a still-open prompt as "cancel the import".
    func dismiss() {
        resolve(nil)
    }
}

/// Shared conflict-resolution sheet (M19/T7) for BOTH import flows — session
/// imports and login-set imports each route their naming collisions through
/// the same `ImportConflictArbiter`/`ImportConflict` (Core, M19/T3), so this
/// is the ONE sheet both present, instead of two near-identical inventions.
///
/// Shape mirrors the M5b transfer conflict sheet (`ConflictSheetView` in
/// `ContentView.swift`) on purpose, so imports read as a sibling of
/// transfers: same padding/spacing/frame, the same "apply to all" toggle,
/// the same button order (Cancel first with `role: .cancel`, then the
/// non-destructive actions, then the destructive one last carrying
/// `.keyboardShortcut(.defaultAction)`), and the same
/// `.interactiveDismissDisabled(true)` contract — Escape/click-outside must
/// never resolve the prompt on their own; only the buttons call `onResolve`/
/// `onCancel`. Whatever wires this sheet in (M19/T8, a continuation-based
/// bridge like `ConflictPromptBridge`) depends on that contract to avoid
/// ever leaving its continuation unfulfilled.
///
/// Two deliberate differences from the transfer sheet, both real
/// consequences of what an import conflict actually is:
/// - `kindLabel` arrives from Core as a stable identifier
///   (`LoginSetImportPlanner.kindLabel` / `SessionImportPlanner.kindLabel`),
///   not display text — Core has no UI language. `kindText` below maps it to
///   localized text, falling back to a neutral generic noun (never the raw
///   identifier) for any value neither planner currently sets.
/// - `Replace` here also destroys secret material (the stored password or
///   key passphrase for whatever it overwrites), which a mere file overwrite
///   never does — the sheet says so explicitly via `replaceNote` rather than
///   leaving it implicit the way the transfer sheet's plain "Overwrite" can.
///
/// Both import flows present it through `ImportConflictBridge` above:
/// `ContentView` for sessions, `LoginSetsSheet` for logins.
struct ImportConflictSheet: View {
    let conflict: ImportConflict
    let onResolve: (ImportConflictResolution, Bool) -> Void
    let onCancel: () -> Void

    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("import.conflict.title", "Name Already Exists"))
                .font(.headline)
            Text(String(format: L10n.string(
                "import.conflict.message", "“%@” already exists."), conflict.itemName))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(L10n.string("info.kind", "Kind"))
                    .foregroundStyle(DesignTokens.inkSecondary)
                Text(kindText)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Text(L10n.string(
                "import.conflict.replaceNote",
                "Replacing also overwrites the stored password or key passphrase."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(
                L10n.string("import.conflict.applyToAll", "Apply to all remaining conflicts"),
                isOn: $applyToAll)
            Text(L10n.string("import.conflict.cancelNote", "Cancelling imports nothing."))
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.string("import.conflict.cancel", "Cancel Import"), role: .cancel) {
                    onCancel()
                }
                Button(L10n.string("import.conflict.rename", "Rename")) {
                    onResolve(.rename, applyToAll)
                }
                Button(L10n.string("import.conflict.skip", "Skip")) {
                    onResolve(.skip, applyToAll)
                }
                Button(L10n.string("import.conflict.replace", "Replace"), role: .destructive) {
                    onResolve(.replace, applyToAll)
                }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        // Escape/click-outside must NOT resolve the prompt without fulfilling
        // whatever continuation the wiring task (T8) hangs off `onCancel` —
        // same reasoning `ConflictSheetView` documents for the M5b transfer
        // sheet. Resolution happens exclusively through the buttons above.
        .interactiveDismissDisabled(true)
    }

    /// Maps Core's stable `kindLabel` identifier to localized display text.
    /// `LoginSetImportPlanner.kindLabel` ("loginSet") and
    /// `SessionImportPlanner.kindLabel` ("session") are the only two values
    /// either import flow currently sets; anything else — a hypothetical
    /// future planner, or a value that drifted — falls back to a neutral
    /// generic noun instead of surfacing the raw identifier to the user.
    private var kindText: String {
        switch conflict.kindLabel {
        case LoginSetImportPlanner.kindLabel:
            return L10n.string("import.conflict.kind.loginSet", "login set")
        case SessionImportPlanner.kindLabel:
            return L10n.string("import.conflict.kind.session", "session")
        default:
            return L10n.string("import.conflict.kind.other", "item")
        }
    }
}
