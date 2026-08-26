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
