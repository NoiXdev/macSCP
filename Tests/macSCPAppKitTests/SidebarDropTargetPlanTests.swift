import Foundation
import SwiftUI
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The sidebar's drop highlight, split out of the rows for the reason
/// `TabBackgroundPlan` already states for the tab strip: which row is
/// highlighted, and what the highlight MEANS, are decisions, and a decision
/// written as a ternary inside a view body is one no test can reach.
@Suite("Sidebar drop target plan")
struct SidebarDropTargetPlanTests {
    @Test func aTargetedFolderPromisesTheDroppedRowLandsInside() {
        #expect(
            SidebarDropTargetPlan.build(
                row: .group(UUID()), isTargeted: true, dragged: .session(UUID())) == .intoFolder)
    }

    @Test func aTargetedConnectionPromisesTheDroppedRowTakesItsPlace() {
        #expect(
            SidebarDropTargetPlan.build(
                row: .session(UUID()), isTargeted: true, dragged: .group(UUID())) == .beforeRow)
    }

    @Test func aRowNothingIsOverIsNotATarget() {
        #expect(
            SidebarDropTargetPlan.build(
                row: .group(UUID()), isTargeted: false, dragged: .session(UUID())) == .none)
        #expect(
            SidebarDropTargetPlan.build(
                row: .session(UUID()), isTargeted: false, dragged: nil) == .none)
    }

    /// A row is never a target for its own drag: dropping a row on itself
    /// changes nothing (`SidebarOrdering.moved` returns the tree untouched),
    /// so highlighting it would promise a move that will not happen — the
    /// same rule, for the same reason, as `TabBackgroundPlan`'s.
    @Test func aRowIsNeverATargetForItsOwnDrag() {
        let folder = UUID()
        #expect(
            SidebarDropTargetPlan.build(
                row: .group(folder), isTargeted: true, dragged: .group(folder)) == .none)
        let connection = UUID()
        #expect(
            SidebarDropTargetPlan.build(
                row: .session(connection), isTargeted: true, dragged: .session(connection))
                == .none)
    }

    /// Group ids and session ids are disjoint, so this pair cannot occur —
    /// but the comparison is between two ROWS rather than two raw ids, which
    /// is what keeps it from suppressing a real target if that ever stopped
    /// holding.
    @Test func theComparisonIsBetweenRowsNotBetweenBareIDs() {
        let id = UUID()
        #expect(
            SidebarDropTargetPlan.build(
                row: .group(id), isTargeted: true, dragged: .session(id)) == .intoFolder)
    }

    /// The one claim a test can make about a highlight it cannot see: the
    /// three answers are three different surfaces, and both live ones carry
    /// a border as well — so the target is not carried by hue alone, and the
    /// two MEANINGS are told apart rather than sharing one paint.
    @Test func theThreeAnswersAreThreeDistinctSurfaces() {
        #expect(SidebarDropTargetPlan.intoFolder.fill != SidebarDropTargetPlan.beforeRow.fill)
        #expect(SidebarDropTargetPlan.intoFolder.fill != SidebarDropTargetPlan.none.fill)
        #expect(SidebarDropTargetPlan.beforeRow.fill != SidebarDropTargetPlan.none.fill)
        #expect(SidebarDropTargetPlan.none.fill == Color.clear)
        #expect(SidebarDropTargetPlan.intoFolder.borderColor != Color.clear)
        #expect(SidebarDropTargetPlan.beforeRow.borderColor != Color.clear)
        #expect(SidebarDropTargetPlan.none.borderColor == Color.clear)
    }

    /// Sensitivity, not just correctness: a `build` hard-wired to one answer
    /// would satisfy each single assertion above in isolation. All three
    /// answers must be reachable from the inputs this sidebar actually
    /// supplies — the same pin `TabBackgroundPlanTests` keeps on its own
    /// precedence chain.
    @Test func allThreeAnswersAreReachable() {
        let folder = SidebarItem.group(UUID())
        let connection = SidebarItem.session(UUID())
        let answers = [
            SidebarDropTargetPlan.build(row: folder, isTargeted: true, dragged: connection),
            SidebarDropTargetPlan.build(row: connection, isTargeted: true, dragged: folder),
            SidebarDropTargetPlan.build(row: folder, isTargeted: false, dragged: connection),
        ]
        #expect(answers == [.intoFolder, .beforeRow, .none])
    }
}

/// Whether a folder offers its one-shot "sort by name" entry.
///
/// A type rather than an `if` in the menu body, the same move
/// `SessionRowTerminalMenuPlan` makes next door and for the same reason: a
/// visibility decision that only exists inside a SwiftUI body is a decision
/// no test can reach.
@Suite("Sidebar sort menu plan")
struct SidebarSortMenuPlanTests {
    /// Sorting nothing, or sorting one row, can only produce the order that
    /// is already there. The entry is HIDDEN rather than greyed out —
    /// this project's standing rule is that nothing is offered dead.
    @Test func aFolderWithFewerThanTwoRowsDoesNotOfferTheSort() {
        #expect(SidebarSortMenuPlan.build(childCount: 0) == .hidden)
        #expect(SidebarSortMenuPlan.build(childCount: 1) == .hidden)
    }

    @Test func aFolderWithTwoOrMoreRowsOffersIt() {
        #expect(SidebarSortMenuPlan.build(childCount: 2) == .shown)
        #expect(SidebarSortMenuPlan.build(childCount: 9) == .shown)
        #expect(SidebarSortMenuPlan.build(childCount: 2).isShown)
    }
}
