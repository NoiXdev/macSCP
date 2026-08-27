import Foundation
import Testing
@testable import macSCPCore

/// Plain payload stand-in — the rules under test are payload-agnostic.
private struct StubTab: Identifiable, Equatable {
    let id: UUID
    var connected: Bool = false
}

@Suite("TabsViewModel")
@MainActor
struct TabsViewModelTests {
    @Test func initialTabIsActiveAndLast() {
        let first = StubTab(id: UUID())
        let vm = TabsViewModel(initial: first)
        #expect(vm.tabs.map(\.id) == [first.id])
        #expect(vm.activeTabID == first.id)
        #expect(vm.activeTab.id == first.id)
        #expect(vm.isLastTab)
    }

    @Test func addTabAppendsAndActivates() {
        let first = StubTab(id: UUID())
        let vm = TabsViewModel(initial: first)
        let second = StubTab(id: UUID())
        vm.addTab(second)
        #expect(vm.tabs.map(\.id) == [first.id, second.id])
        #expect(vm.activeTabID == second.id)
        #expect(!vm.isLastTab)
    }

    @Test func activateSwitchesAndIgnoresUnknown() {
        let first = StubTab(id: UUID())
        let vm = TabsViewModel(initial: first)
        let second = StubTab(id: UUID())
        vm.addTab(second)
        vm.activate(first.id)
        #expect(vm.activeTabID == first.id)
        vm.activate(UUID()) // unknown — no-op
        #expect(vm.activeTabID == first.id)
    }

    @Test func closeActiveTabActivatesRightNeighbor() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID()), c = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b)
        vm.addTab(c)
        vm.activate(b.id)
        #expect(vm.closeTab(b.id))
        #expect(vm.tabs.map(\.id) == [a.id, c.id])
        #expect(vm.activeTabID == c.id) // right neighbor
    }

    @Test func closeActiveLastPositionActivatesLeftNeighbor() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b) // b active, rightmost
        #expect(vm.closeTab(b.id))
        #expect(vm.activeTabID == a.id) // no right neighbor -> left
    }

    @Test func closeInactiveTabKeepsActive() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b) // b active
        #expect(vm.closeTab(a.id))
        #expect(vm.activeTabID == b.id)
        #expect(vm.tabs.map(\.id) == [b.id])
    }

    @Test func lastTabCannotBeClosed() {
        let a = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        #expect(!vm.closeTab(a.id))
        #expect(vm.tabs.count == 1)
        #expect(!vm.closeTab(UUID())) // unknown id -> false, no change
    }

    @Test func sidebarConnectTargetReusesUnconnectedActiveTab() {
        let a = StubTab(id: UUID(), connected: false)
        let vm = TabsViewModel(initial: a)
        let target = vm.sidebarConnectTarget(activeTabIsConnected: false) {
            StubTab(id: UUID())
        }
        #expect(target.id == a.id)
        #expect(vm.tabs.count == 1)
    }

    @Test func sidebarConnectTargetOpensNewTabWhenActiveConnected() {
        let a = StubTab(id: UUID(), connected: true)
        let vm = TabsViewModel(initial: a)
        let fresh = StubTab(id: UUID())
        let target = vm.sidebarConnectTarget(activeTabIsConnected: true) { fresh }
        #expect(target.id == fresh.id)
        #expect(vm.tabs.map(\.id) == [a.id, fresh.id])
        #expect(vm.activeTabID == fresh.id)
    }

    @Test func movingATabPutsItAtTheRequestedPosition() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID()), c = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b); vm.addTab(c)
        vm.move(tabID: a.id, to: 2)
        #expect(vm.tabs.map(\.id) == [b.id, c.id, a.id])
    }

    @Test func movingSomeOtherTabLeavesTheActiveOneActive() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID()), c = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b); vm.addTab(c)
        vm.activate(b.id)
        vm.move(tabID: c.id, to: 0)
        // b moved from the middle to the end without being touched.
        #expect(vm.tabs.map(\.id) == [c.id, a.id, b.id])
        #expect(vm.activeTabID == b.id)
        #expect(vm.activeTab.id == b.id)
    }

    @Test func movingTheActiveTabKeepsItActive() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b)
        vm.activate(a.id)
        vm.move(tabID: a.id, to: 1)
        #expect(vm.tabs.map(\.id) == [b.id, a.id])
        #expect(vm.activeTabID == a.id)
    }

    @Test func aDestinationBeyondTheEndsDoesNothingRatherThanTrapping() {
        // b sits in the middle — neither edge it would clamp to is where it
        // already is, so a clamp-and-move (instead of a true no-op) moves
        // it and this test catches that.
        let a = StubTab(id: UUID()), b = StubTab(id: UUID()), c = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b); vm.addTab(c)
        vm.move(tabID: b.id, to: -5)
        #expect(vm.tabs.map(\.id) == [a.id, b.id, c.id])
        vm.move(tabID: b.id, to: 99)
        #expect(vm.tabs.map(\.id) == [a.id, b.id, c.id])
    }

    /// The commonest drag of all: picked up and put back down on itself.
    /// It arrives here as a move to the tab's own index, and must leave
    /// both the order and the active tab exactly as they were — including
    /// when the tab dropped on itself is not the active one.
    @Test func movingATabOntoItsOwnPositionChangesNothing() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID()), c = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b); vm.addTab(c)
        vm.activate(c.id)
        vm.move(tabID: b.id, to: 1)
        #expect(vm.tabs.map(\.id) == [a.id, b.id, c.id])
        #expect(vm.activeTabID == c.id)
        vm.move(tabID: c.id, to: 2)
        #expect(vm.tabs.map(\.id) == [a.id, b.id, c.id])
        #expect(vm.activeTabID == c.id)
    }

    @Test func movingAnUnknownTabIsANoOp() {
        let a = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.move(tabID: UUID(), to: 0)
        #expect(vm.tabs.map(\.id) == [a.id])
    }

    // MARK: - Bulk close ("others" means all but the CLICKED tab)

    /// The rule the design emphasises hardest, and the one a reading of
    /// `activeTabID` gets subtly wrong: the active tab is closed too when
    /// the bulk close was asked about a different tab.
    @Test func othersMeansAllButTheAskedAboutTabNotAllButTheActiveOne() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID()), c = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b); vm.addTab(c)
        vm.activate(b.id)
        // Asked about `c` while `b` is active: `b` is in the closing set.
        #expect(vm.tabsToClose(besides: c.id).map(\.id) == [a.id, b.id])
        // And the active tab is NOT the yardstick — asking about the active
        // tab itself is only one case of the same rule, not the rule.
        #expect(vm.tabsToClose(besides: b.id).map(\.id) == [a.id, c.id])
    }

    @Test func theClosingSetKeepsStripOrder() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID()), c = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b); vm.addTab(c)
        #expect(vm.tabsToClose(besides: b.id).map(\.id) == [a.id, c.id])
    }

    @Test func aLoneTabHasNoOthersToClose() {
        let a = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        #expect(vm.tabsToClose(besides: a.id).isEmpty)
    }

    /// A tab that has already gone leaves nothing to keep, so every tab
    /// comes back — and `closeOthers(besides:)` refuses to act on it rather
    /// than emptying the strip.
    @Test func anUnknownTabYieldsEveryTabAndClosesNone() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b)
        let stale = UUID()
        #expect(vm.tabsToClose(besides: stale).map(\.id) == [a.id, b.id])
        vm.closeOthers(besides: stale)
        #expect(vm.tabs.map(\.id) == [a.id, b.id])
        #expect(vm.activeTabID == b.id)
    }

    /// The second half of the same rule: the tab the close was asked about
    /// is the one left, and it is active afterwards even when it was not
    /// before.
    @Test func closingOthersLeavesTheAskedAboutTabActive() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID()), c = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b); vm.addTab(c)
        vm.activate(b.id)
        vm.closeOthers(besides: c.id)
        #expect(vm.tabs.map(\.id) == [c.id])
        #expect(vm.activeTabID == c.id)
        #expect(vm.activeTab.id == c.id)
        #expect(vm.isLastTab)
    }

    /// Closing others around the ALREADY active tab keeps it active — the
    /// same code path, stated so the case cannot regress into a needless
    /// re-activation of something else.
    @Test func closingOthersAroundTheActiveTabKeepsItActive() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b)
        vm.activate(a.id)
        vm.closeOthers(besides: a.id)
        #expect(vm.tabs.map(\.id) == [a.id])
        #expect(vm.activeTabID == a.id)
    }
}
