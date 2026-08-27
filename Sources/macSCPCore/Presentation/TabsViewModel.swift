import Foundation
import Observation

/// Window-scoped tab collection rules (M8a). Pure state machine — no UI,
/// no SSH: the app layer instantiates it with its session payload and
/// renders `tabs`/`activeTabID`. Payload-generic so the rules stay unit
/// testable (the app target has no test target).
@MainActor
@Observable
public final class TabsViewModel<Tab: Identifiable> where Tab.ID == UUID {
    public private(set) var tabs: [Tab]
    public private(set) var activeTabID: UUID

    public init(initial: Tab) {
        self.tabs = [initial]
        self.activeTabID = initial.id
    }

    /// The active tab. `activeTabID` is maintained to always reference an
    /// existing element, so lookup failure is a programmer error.
    public var activeTab: Tab {
        guard let tab = tabs.first(where: { $0.id == activeTabID }) else {
            fatalError("activeTabID does not reference an existing tab")
        }
        return tab
    }

    public var isLastTab: Bool { tabs.count == 1 }

    /// Appends and activates (⊕ / Cmd-N / sidebar-into-new-tab).
    public func addTab(_ tab: Tab) {
        tabs.append(tab)
        activeTabID = tab.id
    }

    /// Moves a tab to another position. The only reordering there is —
    /// the context menu calls it with the neighbouring index, dragging
    /// calls it with the drop position, so the rule exists once.
    ///
    /// `activeTabID` is deliberately untouched: it names a tab, not a
    /// position, so the active tab stays active however the order changes.
    /// Out-of-range destinations and unknown ids leave the order alone
    /// rather than trapping — a gesture that ends outside the strip is an
    /// ordinary outcome, not a programmer error.
    public func move(tabID: UUID, to destination: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        guard tabs.indices.contains(destination), destination != from else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: destination)
    }

    /// No-op for unknown ids (defensive: a stale click on a closing tab).
    public func activate(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    /// Removes the tab. The LAST tab is not removable (the app interprets
    /// closing the last unconnected tab as closing the window). Closing the
    /// active tab activates the right neighbor, or the left one at the
    /// rightmost position (browser convention).
    @discardableResult
    public func closeTab(_ id: UUID) -> Bool {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else {
            return false
        }
        tabs.remove(at: index)
        if activeTabID == id {
            let successor = min(index, tabs.count - 1)
            activeTabID = tabs[successor].id
        }
        return true
    }

    /// The tabs a bulk close covers: **everything except the one it was
    /// asked about** — not everything except the ACTIVE one. The context
    /// menu hangs off a particular row and the user means that row, so a
    /// bulk close opened on a background tab closes the active one along
    /// with the rest.
    ///
    /// That distinction is the design's most emphatic rule about this
    /// feature and it is easy to get wrong by reading `activeTabID`, which
    /// is right there and almost always the same tab. It is a value
    /// question — a list and an id in, a list out — so it is answered here
    /// rather than inside a view where nothing can check it.
    ///
    /// Order is preserved, and an unknown id yields every tab: the caller
    /// then has nothing to keep, which `closeOthers(besides:)` below
    /// refuses to act on.
    public func tabsToClose(besides id: UUID) -> [Tab] {
        tabs.filter { $0.id != id }
    }

    /// Removes every tab but one and makes that one active — the second
    /// half of the same rule. The caller runs its own per-tab teardown over
    /// `tabsToClose(besides:)` first; this is the model change that follows
    /// it, in one step rather than a loop of `closeTab`, because "keep
    /// exactly this one" is the intent and `closeTab`'s last-tab refusal
    /// describes a different one.
    ///
    /// A no-op for an unknown id, rather than emptying the strip: `tabs` is
    /// never allowed to be empty (`activeTab` treats a missing active tab
    /// as a programmer error), and a stale click on a tab that has already
    /// gone is an ordinary outcome, the same reading `activate(_:)` and
    /// `move(tabID:to:)` take.
    public func closeOthers(besides id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        tabs.removeAll { $0.id != id }
        activeTabID = id
    }

    /// Sidebar-connect rule (spec 1.2): an unconnected active tab is reused
    /// in place; a connected one spawns a fresh tab so the running session
    /// is never torn down by a sidebar connect.
    public func sidebarConnectTarget(
        activeTabIsConnected: Bool, makeTab: () -> Tab
    ) -> Tab {
        guard activeTabIsConnected else { return activeTab }
        let fresh = makeTab()
        addTab(fresh)
        return fresh
    }
}
