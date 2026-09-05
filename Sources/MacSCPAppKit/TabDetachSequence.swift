import Foundation
import macSCPCore

/// Everything that happens to a window's own model and to the registry when
/// one of its tabs leaves for a window of its own (Detachable Tabs plan,
/// Task 2) — in ONE synchronous step, and outside any view, so it can be
/// driven with values instead of read as text.
///
/// **Why one step, and why it is the whole point of this type.**
/// `TabsViewModel.detach(tabID:)` empties the model when the tab it removes
/// was the only one, and it leaves `activeTabID` naming the tab that left;
/// `TabsViewModel.activeTab` traps on an id it cannot resolve, which is that
/// class's documented invariant. So between the detach and whatever restores
/// the invariant there must be no chance for a view body to run — and a view
/// body runs at the end of a main-actor turn, not in the middle of one.
/// Everything below happens in a single turn:
///
/// 1. the close decision is taken while the model still holds the tab,
/// 2. the tab is detached and parked under the seed,
/// 3. if the window is STAYING and would be left empty, a fresh tab takes
///    the leaver's place, so `activeTab` resolves again before this function
///    returns.
///
/// The caller closes the window when this returns `true`, in the same turn.
/// A window that is closing is allowed to carry an empty model for the rest
/// of that turn, because it is going away before anything can render it.
@MainActor
enum TabDetachSequence {
    /// Moves `tabID` out of `model` and parks it under `seedID`, returning
    /// whether the window that owned it must now close.
    ///
    /// `replacement` is called at most once, and only for a window that
    /// stays and would otherwise be empty — the last window, which macSCP
    /// has always shown with at least one (form) tab.
    ///
    /// A no-op returning `false` for an id `model` does not hold: nothing is
    /// detached, nothing is parked, and no window is asked to close, so a
    /// stale or repeated invocation cannot open a window over a tab that is
    /// already somewhere else.
    ///
    /// Nothing here touches the tab's connection: `detach` and `park` move a
    /// reference between collections and read nothing off the tab but its
    /// id (Global Constraints: "a move never touches the connection", pinned
    /// against the session itself in `TabRegistryTests`).
    @discardableResult
    static func move(
        _ tabID: UUID,
        outOf model: TabsViewModel<SessionTab>,
        parkingUnder seedID: UUID,
        in registry: TabRegistry,
        replacement: () -> SessionTab
    ) -> Bool {
        let closing = WindowCloseDecision.after(
            removing: tabID, in: model.tabs.map(\.id), windowCount: registry.windowCount)
        guard let tab = model.detach(tabID: tabID) else { return false }
        registry.park([tab], for: seedID)
        if !closing && model.tabs.isEmpty {
            model.addTab(replacement())
        }
        return closing
    }
}
