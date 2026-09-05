import Foundation
import macSCPCore

/// Every decision window restoration takes, with no file, no window and no
/// clock in it (Detachable Tabs plan, Task 5).
///
/// The feature's whole promise is a pair of negatives — with the setting
/// off nothing is written and nothing is read; with it on nothing
/// connects — and negatives are what a running app is worst at proving.
/// Keeping the decisions in a pure value type is what lets
/// `WindowRestorationPlanTests` state them outright, and it is why the
/// store and the views ask this rather than each spelling `if flag`
/// somewhere of their own.
enum WindowRestorationPlan {
    /// Whether a closing window writes its description to `windows.json`.
    ///
    /// A window that closes with the setting off writes nothing AND
    /// clears nothing: the file is left exactly as it was found. That is
    /// deliberate and it is the reason this is a write decision rather
    /// than a "keep the file in step" one — an old file must not be
    /// half-updated by a run that is not restoring. What keeps stale
    /// windows from coming back when the setting is turned on again is
    /// the read side: a launch that restores CONSUMES the file.
    static func shouldWrite(flag: Bool) -> Bool { flag }

    /// Whether a launch reads `windows.json` at all.
    ///
    /// Separate from `shouldWrite(flag:)` above even though the answer is
    /// the same, because the two are different promises to the user and
    /// the tests state them separately: one is about what leaves the app,
    /// the other about what a launch is allowed to put on screen.
    static func shouldRead(flag: Bool) -> Bool { flag }

    /// The description belonging to the window SwiftUI opens by itself —
    /// the seedless, primary one. `nil` when the setting is off or the
    /// file names no primary window.
    ///
    /// The FIRST primary description wins. One run can only ever write
    /// one (there is only one seedless window), so a file with two has
    /// been hand-edited or half-written; the rest are not dropped, they
    /// open as ordinary windows below.
    static func primarySeed(flag: Bool, stored: [WindowSeed]) -> WindowSeed? {
        guard shouldRead(flag: flag) else { return nil }
        return stored.first(where: \.isPrimary)
    }

    /// The descriptions that need a window opened for them, in the order
    /// their windows closed: everything except the one
    /// `primarySeed(flag:stored:)` answered with, which is already on
    /// screen.
    static func seedsToOpen(flag: Bool, stored: [WindowSeed]) -> [WindowSeed] {
        guard shouldRead(flag: flag) else { return [] }
        guard let primary = primarySeed(flag: flag, stored: stored) else { return stored }
        return stored.filter { $0.id != primary.id }
    }

    /// Which pane visibility a connect actually uses, given the three
    /// answers that can exist at once.
    ///
    /// - `override` is an explicit request from the caller — the sidebar's
    ///   "Open Terminal" asks for a specific shape and must get it.
    /// - `restored` is what a restored tab was described with. It outranks
    ///   the stored session's own saved value because it is the more
    ///   recent statement of the same thing: the session was saved with
    ///   one shape at some point, and the window was closed showing
    ///   another.
    /// - `stored` is the stored session's saved value, and the answer for
    ///   every ordinary connect.
    ///
    /// It lives here rather than at the call site because the restored
    /// value is the only reason there are three: without restoration the
    /// expression is `override ?? stored`, which is what `connect` used to
    /// spell inline.
    static func paneVisibility(
        override: PaneVisibility?, restored: PaneVisibility?, stored: PaneVisibility
    ) -> PaneVisibility {
        override ?? restored ?? stored
    }
}

/// What this launch has left to restore (Detachable Tabs plan, Task 5).
///
/// A reference type, and hand-once semantics, for one reason each:
///
/// - **Reference**, because the decision is taken in `MacSCPApp.init` and
///   acted on by a `ContentView` that appears later. An App-scope `@State`
///   array could not be emptied from the view that consumed it.
/// - **Hand once**, because a window can appear more than once. Closing
///   the primary window and opening another must not rebuild the same
///   tabs a second time, and the pass that opens the restored windows must
///   not run again on a later window's appearance. Both `take…` methods
///   answer once and are empty afterwards.
///
/// Built through `WindowRestorationPlan`, so "the setting is off" is one
/// decision expressed in one place rather than a second `if` here.
@MainActor
final class WindowRestorationLaunch {
    private var primary: WindowSeed?
    private var toOpen: [WindowSeed]

    init(flag: Bool, stored: [WindowSeed]) {
        primary = WindowRestorationPlan.primarySeed(flag: flag, stored: stored)
        toOpen = WindowRestorationPlan.seedsToOpen(flag: flag, stored: stored)
    }

    /// The primary window's description, once. `nil` afterwards, and `nil`
    /// when this launch is not restoring.
    func takePrimarySeed() -> WindowSeed? {
        defer { primary = nil }
        return primary
    }

    /// The windows to open, once. Empty afterwards, and empty when this
    /// launch is not restoring.
    func takeSeedsToOpen() -> [WindowSeed] {
        defer { toOpen = [] }
        return toOpen
    }
}
