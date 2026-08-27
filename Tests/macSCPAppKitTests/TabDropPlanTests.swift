import Foundation
import Testing

@testable import MacSCPAppKit

/// Direct tests over `TabDropPlan` — the two value questions a tab drop
/// asks before anything is reordered: which tab was dragged, and which
/// position it should move to.
///
/// Same boundary as `LivenessDotPlanTests`: this project has no SwiftUI
/// rendering harness, so nothing here proves that a drag fires or that the
/// tab lands under the pointer. What it does prove is the part the drop
/// closure hands over — including the clamp, which exists because
/// `TabsViewModel.move(tabID:to:)` answers an out-of-range destination with
/// silence rather than with a move to the nearest end.
///
/// Reordering itself is not tested here because it is not here:
/// `TabsViewModelTests` owns `move(tabID:to:)`, and there is one of it.
@Suite("Tab drop plan")
struct TabDropPlanTests {
    // MARK: - Which tab was dragged

    @Test func anEmptyPayloadNamesNoTab() {
        #expect(TabDropPlan.draggedTabID(from: []) == nil)
    }

    @Test func aPayloadThatIsNotAUUIDNamesNoTab() {
        #expect(TabDropPlan.draggedTabID(from: ["/Users/someone/a-dropped-file.txt"]) == nil)
        #expect(TabDropPlan.draggedTabID(from: [""]) == nil)
    }

    @Test func aUUIDPayloadNamesThatTab() {
        let id = UUID()
        #expect(TabDropPlan.draggedTabID(from: [id.uuidString]) == id)
    }

    /// A drag carries one tab. Anything past the first item belongs to a
    /// gesture this strip did not start, so the first item is what is read
    /// rather than a search for the first item that happens to parse.
    @Test func onlyTheFirstPayloadItemIsRead() {
        let first = UUID()
        let second = UUID()
        #expect(TabDropPlan.draggedTabID(from: [first.uuidString, second.uuidString]) == first)
        #expect(TabDropPlan.draggedTabID(from: ["not a uuid", second.uuidString]) == nil)
    }

    /// A session row dragged out of the sidebar carries a plain uuid string
    /// too, so it parses here — and is meant to. The no-op comes from
    /// `move(tabID:to:)` not knowing the id, not from a second rule here
    /// about which ids are real.
    @Test func aForeignUUIDStillParsesAndIsLeftToTheModelToRefuse() {
        let strangerID = UUID()
        #expect(TabDropPlan.draggedTabID(from: [strangerID.uuidString]) == strangerID)
    }

    // MARK: - Which position it lands on

    @Test func aPositionInsideTheStripIsTheDestination() {
        #expect(TabDropPlan.destination(forDropOnIndex: 0, tabCount: 3) == 0)
        #expect(TabDropPlan.destination(forDropOnIndex: 1, tabCount: 3) == 1)
        #expect(TabDropPlan.destination(forDropOnIndex: 2, tabCount: 3) == 2)
    }

    /// The reason this function exists. `move(tabID:to:)` refuses a
    /// destination outside `tabs.indices` as a no-op — deliberately, so a
    /// gesture ending outside the strip leaves the order alone — which
    /// means a caller forwarding a stale position would produce a dropped
    /// gesture rather than a move.
    @Test func aPositionPastTheLastTabLandsOnTheLastTab() {
        #expect(TabDropPlan.destination(forDropOnIndex: 3, tabCount: 3) == 2)
        #expect(TabDropPlan.destination(forDropOnIndex: 99, tabCount: 3) == 2)
    }

    /// **A negative position cannot arrive from the strip** — a drop
    /// position is an offset out of `Array.enumerated()`. This is not an
    /// edge case being claimed as reachable; it is the other half of the
    /// function's totality, checked because the function is written to
    /// answer over every `Int` and a caller elsewhere would be entitled to
    /// rely on that. The reachable half is the one beyond the top end, where
    /// the tab count really can have shrunk under a drag in flight.
    @Test func aNegativePositionCannotArriveButIsStillAnsweredTotally() {
        #expect(TabDropPlan.destination(forDropOnIndex: -1, tabCount: 3) == 0)
        #expect(TabDropPlan.destination(forDropOnIndex: -99, tabCount: 3) == 0)
    }

    /// With no tabs there is no position to land on, and clamping would
    /// have to invent one (`-1`, or `0` for a strip with no index `0`).
    /// `nil` says there is nothing to move onto, and the caller then calls
    /// nothing at all.
    @Test func noTabsMeansNoDestination() {
        #expect(TabDropPlan.destination(forDropOnIndex: 0, tabCount: 0) == nil)
        #expect(TabDropPlan.destination(forDropOnIndex: 5, tabCount: 0) == nil)
        #expect(TabDropPlan.destination(forDropOnIndex: -5, tabCount: 0) == nil)
    }

    /// A one-tab strip has exactly one position, and every drop on it is
    /// that position — which `move(tabID:to:)` then recognizes as the tab's
    /// own index and leaves alone.
    @Test func aSingleTabStripAlwaysAnswersItsOnlyPosition() {
        #expect(TabDropPlan.destination(forDropOnIndex: 0, tabCount: 1) == 0)
        #expect(TabDropPlan.destination(forDropOnIndex: 7, tabCount: 1) == 0)
        #expect(TabDropPlan.destination(forDropOnIndex: -7, tabCount: 1) == 0)
    }

    /// Every clamped answer is a real index of the strip it was asked
    /// about — the property the caller relies on, checked over a range
    /// rather than at the two ends only. The negative half of that range is
    /// unreachable from today's only caller, for the reason spelled out on
    /// `aNegativePositionCannotArriveButIsStillAnsweredTotally`.
    @Test func everyAnswerIsAnIndexTheStripActuallyHas() {
        for tabCount in 1...6 {
            for dropIndex in -8...12 {
                let destination = TabDropPlan.destination(
                    forDropOnIndex: dropIndex, tabCount: tabCount)
                #expect(destination != nil)
                #expect((0..<tabCount).contains(destination ?? -1), """
                    a drop on position \(dropIndex) of a \(tabCount)-tab strip answered \
                    \(String(describing: destination)), which is not one of that strip's \
                    positions — `move(tabID:to:)` would refuse it and the drag would \
                    silently do nothing.
                    """)
            }
        }
    }
}
