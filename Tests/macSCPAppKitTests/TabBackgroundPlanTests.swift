import Foundation
import SwiftUI
import Testing

@testable import MacSCPAppKit

/// Pins `TabBackgroundPlan.build`: which of the reasons to draw a tab's
/// background wins when more than one holds at once, and which tab is
/// excluded from the drop highlight.
///
/// A type rather than ternaries in the item's `background` for the reason
/// `SessionRowHighlightTests` states about the sidebar's rows — precedence
/// is a decision, and one written into a view body is one no test can
/// reach.
///
/// Same boundary as `TabDropPlanTests` and `LivenessDotPlanTests`: this
/// project has no SwiftUI rendering harness, so nothing here proves that a
/// drag fires, that a tab is ever reported as targeted, or that any of
/// these colours reaches the screen.
@Suite("Tab background plan")
struct TabBackgroundPlanTests {
    private let tabID = UUID()
    private let otherTabID = UUID()

    /// The precedence that matters: the drop highlight answers a question
    /// that only exists during a drag, and it has to be answerable on the
    /// active tab too — which keeps its underline and its title treatment
    /// either way.
    @Test func aDropTargetOutranksTheActiveTab() {
        #expect(
            TabBackgroundPlan.build(
                isActive: true, isDropTargeted: true,
                draggedTabID: otherTabID, tabID: tabID) == .dropTarget)
    }

    /// The case the whole identity comparison exists for: dropping a tab
    /// onto itself moves nothing, so the tab being dragged must not offer
    /// itself as somewhere to let go.
    @Test func aTabIsNeverADropTargetForItsOwnDrag() {
        #expect(
            TabBackgroundPlan.build(
                isActive: false, isDropTargeted: true,
                draggedTabID: tabID, tabID: tabID) == .plain)
        #expect(
            TabBackgroundPlan.build(
                isActive: true, isDropTargeted: true,
                draggedTabID: tabID, tabID: tabID) == .active)
    }

    /// A drag over a tab that is not the one being carried is a drop
    /// target whether or not it is the active tab.
    @Test func anyOtherTargetedTabIsADropTarget() {
        #expect(
            TabBackgroundPlan.build(
                isActive: false, isDropTargeted: true,
                draggedTabID: otherTabID, tabID: tabID) == .dropTarget)
    }

    /// The recorded origin is compared, never merely tested for presence:
    /// `TabDragOrigin` is not cleared when a drag ends, so "some id is
    /// recorded" says nothing about whether a drag is in flight. An unknown
    /// origin is therefore a target like any other — the gap
    /// `TabBackgroundPlan.build` names, and the reason it is stated here
    /// rather than left to be discovered.
    @Test func anUnknownOriginIsStillADropTarget() {
        #expect(
            TabBackgroundPlan.build(
                isActive: false, isDropTargeted: true,
                draggedTabID: nil, tabID: tabID) == .dropTarget)
    }

    @Test func nothingOverATabLeavesItsUsualBackground() {
        #expect(
            TabBackgroundPlan.build(
                isActive: true, isDropTargeted: false,
                draggedTabID: otherTabID, tabID: tabID) == .active)
        #expect(
            TabBackgroundPlan.build(
                isActive: false, isDropTargeted: false,
                draggedTabID: otherTabID, tabID: tabID) == .plain)
    }

    /// The claim a background test can make without pixels: the three cases
    /// are three DIFFERENT colours. A mapping that quietly drew the drop
    /// target in the active tab's surface would satisfy every precedence
    /// check above while the feedback the whole change exists for was
    /// invisible on the active tab.
    @Test func theThreeCasesAreThreeDifferentFills() {
        let cases: [TabBackgroundPlan] = [.dropTarget, .active, .plain]
        for (index, first) in cases.enumerated() {
            for second in cases[(index + 1)...] {
                #expect(first.fill != second.fill, "\(first) and \(second) draw the same colour")
            }
        }
    }

    /// The second channel, so the drop target is not carried by hue alone.
    @Test func onlyTheDropTargetDrawsABorder() {
        #expect(TabBackgroundPlan.dropTarget.borderColor != Color.clear)
        #expect(TabBackgroundPlan.active.borderColor == Color.clear)
        #expect(TabBackgroundPlan.plain.borderColor == Color.clear)
    }

    @Test func theCaseThatIsDefinedByDrawingNothing() {
        #expect(TabBackgroundPlan.plain.fill == Color.clear)
    }

    /// Every case is reachable across the combinations of the two booleans
    /// and the two identities a tab can be handed — a `build` that could
    /// never answer `.dropTarget` would satisfy the precedence checks only
    /// by accident.
    @Test func everyCaseIsReachable() {
        var answers: Set<TabBackgroundPlan> = []
        let origins: [UUID?] = [tabID, otherTabID, nil]
        for isActive in [true, false] {
            for isDropTargeted in [true, false] {
                for draggedTabID in origins {
                    answers.insert(
                        TabBackgroundPlan.build(
                            isActive: isActive, isDropTargeted: isDropTargeted,
                            draggedTabID: draggedTabID, tabID: tabID))
                }
            }
        }
        #expect(answers == [.dropTarget, .active, .plain])
    }
}

/// `TabDragOrigin` carries one mutable note and no rule, so there is one
/// thing to pin: it starts out naming no tab. What the strip does with it
/// is `TabBackgroundPlanTests`' subject; that a drag ever writes to it is
/// not observable in this project — see `TabDragWiringGuardTests`, which
/// checks the source text of the drag that writes it.
@Suite("Tab drag origin")
struct TabDragOriginTests {
    @Test func aFreshOriginNamesNoTab() {
        #expect(TabDragOrigin().draggedTabID == nil)
    }

    @Test func theOriginKeepsWhatWasWrittenToIt() {
        let origin = TabDragOrigin()
        let id = UUID()
        origin.draggedTabID = id
        #expect(origin.draggedTabID == id)
    }
}
