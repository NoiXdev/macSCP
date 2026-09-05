import Foundation

/// Whether a window that just lost a tab should close itself (Detachable
/// Tabs plan, Task 2).
///
/// A pure function rather than a branch inside the view, for the reason
/// every decision in this project sits outside its view: the app target has
/// no SwiftUI rendering harness, so a rule written into a `body` can only be
/// read as text, while this one can be driven with values
/// (`TabsWindowLifecycleTests`).
///
/// The rule has two halves and both are load-bearing:
///
/// - **Emptied.** The window closes only when the tab that left was the
///   last one it held. A window with tabs still in it stays, whatever else
///   is going on.
/// - **Not the last window.** The last window stays open even when it is
///   emptied — closing it would end the session with no way back, and it is
///   the behaviour macSCP has had since it was a single-window app. The
///   caller restores that window's own invariant instead (a fresh tab; see
///   `TabDetachSequence.move`).
///
/// `windowCount` is `TabRegistry.windowCount`, which counts windows holding
/// at least one tab — asked BEFORE the tab is taken away, so the window
/// doing the asking is still counted.
enum WindowCloseDecision {
    /// `held` is the ids the window holds right now, `id` the one leaving.
    /// An id the window does not hold takes nothing away from it, so the
    /// answer is `false` — the same reading `TabRegistry.move(_:to:)` takes
    /// of an id it has never seen.
    static func after(removing id: UUID, in held: [UUID], windowCount: Int) -> Bool {
        let remaining = held.filter { $0 != id }
        return remaining.isEmpty && windowCount > 1
    }
}
