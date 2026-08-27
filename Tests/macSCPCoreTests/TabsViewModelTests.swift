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

    // MARK: - Moving one step (what the context menu asks for)
    //
    // The direction of "Move Left"/"Move Right" was the last arithmetic of
    // this feature and the only part of it no test reached: while the step
    // was taken in the app layer, swapping the two numbers left the whole
    // suite green (final review, I1). The step is taken in the model now,
    // and these say what each direction owes.

    @Test func movingOneStepLeftPutsTheTabBeforeItsLeftNeighbour() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID()), c = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b); vm.addTab(c)
        vm.move(tabID: b.id, oneStep: .left)
        #expect(vm.tabs.map(\.id) == [b.id, a.id, c.id])
    }

    @Test func movingOneStepRightPutsTheTabAfterItsRightNeighbour() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID()), c = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b); vm.addTab(c)
        vm.move(tabID: b.id, oneStep: .right)
        #expect(vm.tabs.map(\.id) == [a.id, c.id, b.id])
    }

    /// A tab with no neighbour on the side it is asked to move to stays
    /// where it is, rather than trapping on an index off the end. The menu
    /// does not offer that step, so this only ever arrives from a menu that
    /// went stale between opening and clicking.
    @Test func aStepPastEitherEndOfTheStripDoesNothing() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b)
        vm.move(tabID: a.id, oneStep: .left)
        #expect(vm.tabs.map(\.id) == [a.id, b.id])
        vm.move(tabID: b.id, oneStep: .right)
        #expect(vm.tabs.map(\.id) == [a.id, b.id])
    }

    @Test func steppingATabTheModelDoesNotKnowIsANoOp() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b)
        vm.move(tabID: UUID(), oneStep: .right)
        #expect(vm.tabs.map(\.id) == [a.id, b.id])
    }

    /// The reported failure, end to end: the first tab is offered exactly
    /// one move entry, and taking that entry moves it towards the tab next
    /// to it. Both halves of the direction are in this test — which step the
    /// edge tab is offered, and where that step puts it — so a disagreement
    /// between them shows up as the tab not moving, which is precisely what
    /// the user saw.
    @Test func theOnlyMoveTheFirstTabIsOfferedTakesItPastItsNeighbour() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID()), c = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b); vm.addTab(c)
        let entries = TabContextMenu.entries(
            atIndex: 0, ofTabCount: vm.tabs.count,
            supportsShell: false, isAdHoc: false, isConnected: true,
            filesToggle: PaneToggleState(isOn: true, isEnabled: false),
            terminalToggle: PaneToggleState(isOn: false, isEnabled: false))
        let steps = entries.compactMap { entry -> TabMoveStep? in
            guard case .move(let step) = entry else { return nil }
            return step
        }
        #expect(steps == [.right])
        for step in steps { vm.move(tabID: a.id, oneStep: step) }
        #expect(vm.tabs.map(\.id) == [b.id, a.id, c.id])
    }

    // MARK: - Moving onto another tab (what a drop reports)

    /// The drag's way in: two identities, no index. The destination is the
    /// position the TARGET holds at the moment of the drop, derived here
    /// from the model's own array — so a caller cannot compute a position,
    /// carry a stale one, or shift one by a step.
    @Test func movingATabOntoAnotherTakesThatTabsPosition() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID()), c = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b); vm.addTab(c)
        vm.move(tabID: a.id, onto: c.id)
        #expect(vm.tabs.map(\.id) == [b.id, c.id, a.id])
    }

    /// The same answer `move(tabID:to:)` gives for that target's index —
    /// this is one rule reached two ways, not a second one.
    @Test func movingOntoATabMatchesMovingToItsIndex() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID()), c = StubTab(id: UUID())
        let byTarget = TabsViewModel(initial: a)
        byTarget.addTab(b); byTarget.addTab(c)
        byTarget.move(tabID: c.id, onto: a.id)
        let byIndex = TabsViewModel(initial: a)
        byIndex.addTab(b); byIndex.addTab(c)
        byIndex.move(tabID: c.id, to: 0)
        #expect(byTarget.tabs.map(\.id) == byIndex.tabs.map(\.id))
    }

    /// Picked up and put back down on itself — the commonest drag there is.
    @Test func movingATabOntoItselfChangesNothing() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID()), c = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b); vm.addTab(c)
        vm.activate(c.id)
        vm.move(tabID: b.id, onto: b.id)
        #expect(vm.tabs.map(\.id) == [a.id, b.id, c.id])
        #expect(vm.activeTabID == c.id)
    }

    /// A tab that closed while the drag was in flight names no position any
    /// more. That is the whole of what used to need clamping: there is no
    /// stale index to clamp, only a target that is or is not there.
    @Test func movingOntoATabThatIsGoneDoesNothing() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b)
        vm.move(tabID: b.id, onto: UUID())
        #expect(vm.tabs.map(\.id) == [a.id, b.id])
    }

    @Test func movingAnUnknownTabOntoATabDoesNothing() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b)
        vm.move(tabID: UUID(), onto: a.id)
        #expect(vm.tabs.map(\.id) == [a.id, b.id])
    }

    @Test func movingOntoATabLeavesTheActiveTabActive() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID()), c = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b); vm.addTab(c)
        vm.activate(b.id)
        vm.move(tabID: c.id, onto: a.id)
        #expect(vm.tabs.map(\.id) == [c.id, a.id, b.id])
        #expect(vm.activeTabID == b.id)
        #expect(vm.activeTab.id == b.id)
    }

    @Test func movingAnUnknownTabIsANoOp() {
        let a = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.move(tabID: UUID(), to: 0)
        #expect(vm.tabs.map(\.id) == [a.id])
    }

    // MARK: - Every relative position a drop can have
    //
    // Every other `onto:` test that moves anything at all picks its
    // target two places away; the rest drop a tab on itself or name an id
    // the model does not have. That left the commonest drag there is — nudge a
    // tab one place — with no case of its own, and a derivation that
    // treated a neighbouring target as nothing to do would have passed all
    // of them. The four checks here say what the derivation owes for a
    // target on either side at any distance, so that "the position is
    // derived from the model" is a claim with values behind it.

    /// The nudge to the right: the dragged tab takes the neighbour's place
    /// and the neighbour takes the dragged tab's.
    @Test func movingATabOntoItsRightNeighbourSwapsTheTwo() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID()), c = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b); vm.addTab(c)
        vm.move(tabID: a.id, onto: b.id)
        #expect(vm.tabs.map(\.id) == [b.id, a.id, c.id])
    }

    /// The nudge to the left, which is the same rule read the other way:
    /// the dragged tab lands on the index its target held, whichever side
    /// it came from.
    @Test func movingATabOntoItsLeftNeighbourSwapsTheTwo() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID()), c = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b); vm.addTab(c)
        vm.move(tabID: c.id, onto: b.id)
        #expect(vm.tabs.map(\.id) == [a.id, c.id, b.id])
    }

    /// The longest drag a strip allows, in both directions: onto the tab at
    /// the far end. The dragged tab becomes the new end and everything it
    /// passed keeps its order.
    @Test func movingATabOntoTheOppositeEndTakesThatEndsPosition() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID())
        let c = StubTab(id: UUID()), d = StubTab(id: UUID())
        let rightwards = TabsViewModel(initial: a)
        rightwards.addTab(b); rightwards.addTab(c); rightwards.addTab(d)
        rightwards.move(tabID: a.id, onto: d.id)
        #expect(rightwards.tabs.map(\.id) == [b.id, c.id, d.id, a.id])
        let leftwards = TabsViewModel(initial: a)
        leftwards.addTab(b); leftwards.addTab(c); leftwards.addTab(d)
        leftwards.move(tabID: d.id, onto: a.id)
        #expect(leftwards.tabs.map(\.id) == [d.id, a.id, b.id, c.id])
    }

    /// Every ordered pair of a five-tab strip — each tab dropped on each
    /// tab, itself included — against the two things a drop promises,
    /// stated as values rather than as a rewrite of the implementation:
    /// the dragged tab ends up at the index its target held, and every
    /// other tab keeps the order it had.
    ///
    /// Together those two say the whole rule for every relative position
    /// there is: neighbour and distant, either side, and the drop onto
    /// itself, where the target's index is the dragged tab's own and the
    /// order therefore cannot change.
    @Test func everyRelativePositionPutsTheTabWhereItsTargetWas() {
        let ids = (0..<5).map { _ in UUID() }
        for draggedIndex in ids.indices {
            for targetIndex in ids.indices {
                let vm = TabsViewModel(initial: StubTab(id: ids[0]))
                for id in ids.dropFirst() { vm.addTab(StubTab(id: id)) }
                let before = vm.tabs.map(\.id)
                vm.move(tabID: ids[draggedIndex], onto: ids[targetIndex])
                let after = vm.tabs.map(\.id)
                #expect(
                    after.firstIndex(of: ids[draggedIndex]) == targetIndex,
                    "dropping tab \(draggedIndex) on tab \(targetIndex) did not land it there")
                #expect(
                    after.filter { $0 != ids[draggedIndex] }
                        == before.filter { $0 != ids[draggedIndex] },
                    "dropping tab \(draggedIndex) on tab \(targetIndex) disturbed the others")
            }
        }
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
