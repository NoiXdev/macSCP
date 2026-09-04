import Foundation
import Testing
@testable import macSCPCore

@Suite("Sidebar ordering")
struct SidebarOrderingTests {
    // MARK: - Fixtures

    private func tree(
        groups: [StoredGroup] = [], sessions: [StoredSession] = []
    ) -> SidebarOrdering.Tree {
        SidebarOrdering.Tree(groups: groups, sessions: sessions)
    }

    private func session(_ name: String, in groupID: UUID? = nil, at position: Int = 0)
        -> StoredSession
    {
        var stored = sshSession(name: name, groupID: groupID)
        stored.position = position
        return stored
    }

    /// The names of a parent's children, in the order the sidebar reads them.
    private func names(of parentID: UUID?, in tree: SidebarOrdering.Tree) -> [String] {
        SidebarOrdering.children(of: parentID, in: tree).map { item in
            switch item {
            case .group(let id): tree.groups.first { $0.id == id }?.name ?? "?"
            case .session(let id): tree.sessions.first { $0.id == id }?.name ?? "?"
            }
        }
    }

    /// The stored positions of a parent's children, in reading order.
    private func positions(of parentID: UUID?, in tree: SidebarOrdering.Tree) -> [Int] {
        SidebarOrdering.children(of: parentID, in: tree).map { item in
            switch item {
            case .group(let id): tree.groups.first { $0.id == id }?.position ?? -1
            case .session(let id): tree.sessions.first { $0.id == id }?.position ?? -1
            }
        }
    }

    private func moved(_ outcome: SidebarOrdering.MoveOutcome) throws -> SidebarOrdering.Tree {
        guard case .moved(let tree) = outcome else {
            Issue.record("expected a move, got \(outcome)")
            throw MoveExpectationFailure()
        }
        return tree
    }

    private struct MoveExpectationFailure: Error {}

    // MARK: - Reordering between siblings

    @Test func draggingBetweenTwoSiblingsReorders() throws {
        let a = session("a", at: 0)
        let b = session("b", at: 1)
        let c = session("c", at: 2)
        let start = tree(sessions: [a, b, c])

        let result = try moved(
            SidebarOrdering.moved(.session(c.id), before: .session(b.id), in: start))

        #expect(names(of: nil, in: result) == ["a", "c", "b"])
    }

    /// The moved item lands BEFORE the target, whichever side it came from —
    /// the drop knows two rows and nothing else, so there is no direction to
    /// get wrong.
    @Test func draggingUpwardsAndDownwardsBothLandBeforeTheTarget() throws {
        let a = session("a", at: 0)
        let b = session("b", at: 1)
        let c = session("c", at: 2)
        let start = tree(sessions: [a, b, c])

        let downwards = try moved(
            SidebarOrdering.moved(.session(a.id), before: .session(c.id), in: start))
        #expect(names(of: nil, in: downwards) == ["b", "a", "c"])

        let upwards = try moved(
            SidebarOrdering.moved(.session(c.id), before: .session(a.id), in: start))
        #expect(names(of: nil, in: upwards) == ["c", "a", "b"])
    }

    /// Dropping between siblings of ANOTHER parent adopts that parent — the
    /// target names both where and among whom.
    @Test func draggingBetweenSiblingsAdoptsTheTargetsParent() throws {
        let folder = StoredGroup(name: "Folder", position: 0)
        let inside = session("inside", in: folder.id, at: 0)
        let outside = session("outside", at: 1)
        let start = tree(groups: [folder], sessions: [inside, outside])

        let result = try moved(
            SidebarOrdering.moved(.session(outside.id), before: .session(inside.id), in: start))

        #expect(names(of: folder.id, in: result) == ["outside", "inside"])
        #expect(names(of: nil, in: result) == ["Folder"])
    }

    /// The same reordering `draggingBetweenTwoSiblingsReorders` pins at the
    /// top level, pinned again with both siblings already INSIDE one named
    /// group — the origin and the destination are the same folder, not the
    /// top level, and that folder must renumber around the reorder same as
    /// any other parent does.
    @Test func draggingBetweenTwoSiblingsInTheSameGroupReorders() throws {
        let folder = StoredGroup(name: "Folder", position: 0)
        let a = session("a", in: folder.id, at: 0)
        let b = session("b", in: folder.id, at: 1)
        let c = session("c", in: folder.id, at: 2)
        let start = tree(groups: [folder], sessions: [a, b, c])

        let result = try moved(
            SidebarOrdering.moved(.session(c.id), before: .session(b.id), in: start))

        #expect(names(of: folder.id, in: result) == ["a", "c", "b"])
        #expect(positions(of: folder.id, in: result) == [0, 1, 2])
    }

    /// A session moving between two ALREADY-NAMED groups (neither one the
    /// top level) — every other reordering fixture here has the top level on
    /// one side or both. The origin group loses a member and must close the
    /// gap; the destination adopts the mover ahead of the row it landed on.
    @Test func draggingASessionBetweenTwoNamedGroupsAdoptsTheDestination() throws {
        let groupA = StoredGroup(name: "A", position: 0)
        let groupB = StoredGroup(name: "B", position: 1)
        let stayed = session("stayed", in: groupA.id, at: 0)
        let moving = session("moving", in: groupA.id, at: 1)
        let inB = session("inB", in: groupB.id, at: 0)
        let start = tree(groups: [groupA, groupB], sessions: [stayed, moving, inB])

        let result = try moved(
            SidebarOrdering.moved(.session(moving.id), before: .session(inB.id), in: start))

        #expect(names(of: groupB.id, in: result) == ["moving", "inB"])
        #expect(names(of: groupA.id, in: result) == ["stayed"])
        #expect(positions(of: groupA.id, in: result) == [0])
        #expect(positions(of: groupB.id, in: result) == [0, 1])
    }

    // MARK: - Dropping onto a folder

    @Test func draggingOntoAFolderAppendsToItsChildren() throws {
        let folder = StoredGroup(name: "Folder", position: 0)
        let first = session("first", in: folder.id, at: 0)
        let second = session("second", in: folder.id, at: 1)
        let newcomer = session("newcomer", at: 1)
        let start = tree(groups: [folder], sessions: [first, second, newcomer])

        let result = try moved(
            SidebarOrdering.moved(.session(newcomer.id), intoGroup: folder.id, in: start))

        #expect(names(of: folder.id, in: result) == ["first", "second", "newcomer"])
        #expect(names(of: nil, in: result) == ["Folder"])
    }

    @Test func draggingAFolderOntoAFolderNestsIt() throws {
        let outer = StoredGroup(name: "Outer", position: 0)
        let loose = StoredGroup(name: "Loose", position: 1)
        let start = tree(groups: [outer, loose])

        let result = try moved(SidebarOrdering.moved(.group(loose.id), intoGroup: outer.id, in: start))

        #expect(result.groups.first { $0.id == loose.id }?.parentID == outer.id)
        #expect(names(of: outer.id, in: result) == ["Loose"])
        #expect(names(of: nil, in: result) == ["Outer"])
    }

    /// `intoGroup: nil` is the top level, which is what makes "drop below
    /// everything" expressible without an index.
    @Test func draggingOntoTheTopLevelAppendsThere() throws {
        let folder = StoredGroup(name: "Folder", position: 0)
        let loose = session("loose", at: 1)
        let inside = session("inside", in: folder.id, at: 0)
        let start = tree(groups: [folder], sessions: [loose, inside])

        let result = try moved(
            SidebarOrdering.moved(.session(inside.id), intoGroup: nil, in: start))

        #expect(names(of: nil, in: result) == ["Folder", "loose", "inside"])
        #expect(names(of: folder.id, in: result).isEmpty)
    }

    /// A GROUP, not a session, dropped onto the top level — "folder to
    /// root". `aMoveDropsNothing` already drags a group `intoGroup: nil` but
    /// only checks that no id was lost; this pins the placement itself: the
    /// nested group's `parentID` clears to `nil`, and it appends after
    /// whatever the top level already held, not in front of it or nested
    /// under the sibling group beside it.
    @Test func draggingAGroupToTheTopLevelClearsItsParentAndAppends() throws {
        let outer = StoredGroup(name: "Outer", position: 0)
        let nested = StoredGroup(name: "Nested", parentID: outer.id, position: 0)
        let sibling = StoredGroup(name: "Sibling", position: 1)
        let start = tree(groups: [outer, nested, sibling])

        let result = try moved(SidebarOrdering.moved(.group(nested.id), intoGroup: nil, in: start))

        #expect(result.groups.first { $0.id == nested.id }?.parentID == nil)
        #expect(names(of: nil, in: result) == ["Outer", "Sibling", "Nested"])
        #expect(names(of: outer.id, in: result).isEmpty)
    }

    // MARK: - Refusals

    /// The refusal a user can actually provoke, and the reason this function
    /// answers with a value instead of quietly returning the tree it was
    /// given: a caller that cannot tell "moved" from "did nothing" has no way
    /// to say so either.
    @Test func aMoveThatWouldCloseACycleChangesNothingAndSaysSo() {
        let outer = StoredGroup(name: "Outer", position: 0)
        let inner = StoredGroup(name: "Inner", parentID: outer.id, position: 0)
        let start = tree(groups: [outer, inner])

        #expect(
            SidebarOrdering.moved(.group(outer.id), intoGroup: inner.id, in: start)
                == .refused(.wouldCycle))
        #expect(
            SidebarOrdering.moved(.group(outer.id), before: .group(inner.id), in: start)
                == .refused(.wouldCycle))
    }

    @Test func aFolderCannotBeDroppedIntoItself() {
        let folder = StoredGroup(name: "Folder", position: 0)
        #expect(
            SidebarOrdering.moved(.group(folder.id), intoGroup: folder.id, in: tree(groups: [folder]))
                == .refused(.wouldCycle))
    }

    /// A stale drop, on either side, is an ordinary outcome rather than a
    /// programmer error — the dragged row may have been deleted from another
    /// menu, and so may the target.
    @Test func aStaleDropIsRefusedAndNamesWhichHalfIsGone() {
        let present = session("present", at: 0)
        let start = tree(sessions: [present])

        #expect(
            SidebarOrdering.moved(.session(UUID()), before: .session(present.id), in: start)
                == .refused(.noSuchItem))
        #expect(
            SidebarOrdering.moved(.session(present.id), before: .session(UUID()), in: start)
                == .refused(.noSuchTarget))
        #expect(
            SidebarOrdering.moved(.session(present.id), intoGroup: UUID(), in: start)
                == .refused(.noSuchTarget))
    }

    @Test func droppingARowOnItselfLeavesTheOrderAlone() throws {
        let a = session("a", at: 0)
        let b = session("b", at: 1)
        let start = tree(sessions: [a, b])

        let result = try moved(
            SidebarOrdering.moved(.session(a.id), before: .session(a.id), in: start))

        #expect(names(of: nil, in: result) == ["a", "b"])
    }

    // MARK: - The renumbering guarantee

    /// Gapless and unique per parent, on BOTH parents a move touches — the
    /// source loses a member and the destination gains one, and every later
    /// reader hangs on the result.
    @Test func everyMoveLeavesBothTouchedParentsGaplessAndUnique() throws {
        let folder = StoredGroup(name: "Folder", position: 0)
        let a = session("a", at: 1)
        let b = session("b", at: 2)
        let c = session("c", at: 3)
        let inside = session("inside", in: folder.id, at: 0)
        let start = tree(groups: [folder], sessions: [a, b, c, inside])

        let result = try moved(SidebarOrdering.moved(.session(b.id), intoGroup: folder.id, in: start))

        #expect(positions(of: nil, in: result) == [0, 1, 2])
        #expect(positions(of: folder.id, in: result) == [0, 1])
    }

    /// A parent the move never touched keeps the positions it had. The
    /// renumbering is a promise about the siblings of the affected parent,
    /// not a licence to reshuffle the rest of the file.
    @Test func aParentThatWasNotTouchedKeepsItsPositions() throws {
        let untouched = StoredGroup(name: "Untouched", position: 0)
        let x = session("x", in: untouched.id, at: 7)
        let y = session("y", in: untouched.id, at: 9)
        let a = session("a", at: 1)
        let b = session("b", at: 2)
        let start = tree(groups: [untouched], sessions: [x, y, a, b])

        let result = try moved(
            SidebarOrdering.moved(.session(b.id), before: .session(a.id), in: start))

        #expect(positions(of: untouched.id, in: result) == [7, 9])
    }

    /// Additive, never destructive: a move rewrites where things sit and
    /// nothing else. The set of ids is the same one it started with.
    @Test func aMoveDropsNothing() throws {
        let folder = StoredGroup(name: "Folder", position: 0)
        let nested = StoredGroup(name: "Nested", parentID: folder.id, position: 0)
        let a = session("a", at: 1)
        let inside = session("inside", in: folder.id, at: 1)
        let start = tree(groups: [folder, nested], sessions: [a, inside])

        let result = try moved(SidebarOrdering.moved(.group(nested.id), intoGroup: nil, in: start))

        #expect(Set(result.groups.map(\.id)) == Set(start.groups.map(\.id)))
        #expect(Set(result.sessions.map(\.id)) == Set(start.sessions.map(\.id)))
    }

    // MARK: - The one-shot sort

    @Test func sortingOrdersTheImmediateChildrenByName() throws {
        let folder = StoredGroup(name: "Folder", position: 0)
        let charlie = session("charlie", in: folder.id, at: 0)
        let alpha = session("alpha", in: folder.id, at: 1)
        let bravo = StoredGroup(name: "bravo", parentID: folder.id, position: 2)
        let start = tree(groups: [folder, bravo], sessions: [charlie, alpha])

        let result = SidebarOrdering.sortedByName(childrenOf: folder.id, in: start)

        #expect(names(of: folder.id, in: result) == ["alpha", "bravo", "charlie"])
        #expect(positions(of: folder.id, in: result) == [0, 1, 2])
    }

    /// The comparison is the one the sidebar already sorts by:
    /// `localizedCaseInsensitiveCompare` (`SessionListViewModel.reload`).
    /// Plain `<` on `String` would put every capital first, so "B" before
    /// "a" — this fixture is chosen to tell the two apart.
    @Test func sortingUsesTheSidebarsCaseInsensitiveNameComparison() throws {
        let upper = session("B", at: 0)
        let lower = session("a", at: 1)
        let start = tree(sessions: [upper, lower])

        let result = SidebarOrdering.sortedByName(childrenOf: nil, in: start)

        #expect(names(of: nil, in: result) == ["a", "B"])
    }

    /// Exactly one level deep. Anything else would be a bulk change of the
    /// whole subtree behind a single menu entry.
    @Test func sortingLeavesDeeperLevelsAlone() throws {
        let folder = StoredGroup(name: "Folder", position: 0)
        let nested = StoredGroup(name: "Nested", parentID: folder.id, position: 0)
        let zulu = session("zulu", in: nested.id, at: 0)
        let alpha = session("alpha", in: nested.id, at: 1)
        let start = tree(groups: [folder, nested], sessions: [zulu, alpha])

        let result = SidebarOrdering.sortedByName(childrenOf: folder.id, in: start)

        #expect(names(of: nested.id, in: result) == ["zulu", "alpha"])
    }

    @Test func sortingDropsNothingAndMovesNobodyBetweenParents() throws {
        let folder = StoredGroup(name: "Folder", position: 0)
        let inside = session("inside", in: folder.id, at: 0)
        let loose = session("loose", at: 1)
        let start = tree(groups: [folder], sessions: [inside, loose])

        let result = SidebarOrdering.sortedByName(childrenOf: nil, in: start)

        #expect(result.sessions.count == 2)
        #expect(result.sessions.first { $0.id == inside.id }?.groupID == folder.id)
    }

    // MARK: - Reading order

    /// A file written before positions existed carries nothing but zeros, and
    /// the answer must still be deterministic: input order decides, exactly
    /// as `GroupTree.children(of:in:)` already decides it for groups.
    @Test func equalPositionsFallBackToInputOrder() {
        let folder = StoredGroup(name: "Folder")
        let a = session("a")
        let b = session("b")
        let start = tree(groups: [folder], sessions: [b, a])

        #expect(names(of: nil, in: start) == ["Folder", "b", "a"])
    }

    // MARK: - Dissolving

    @Test func dissolvingLiftsSessionsAndSubfoldersIntoTheDissolvedGroupsSlot() {
        let outer = StoredGroup(name: "Outer", position: 0)
        let middle = StoredGroup(name: "Middle", parentID: outer.id, position: 0)
        let inner = StoredGroup(name: "Inner", parentID: middle.id, position: 0)
        let last = session("last", in: outer.id, at: 1)
        let held = session("held", in: middle.id, at: 1)
        let start = tree(groups: [outer, middle, inner], sessions: [last, held])

        let result = SidebarOrdering.dissolving(middle.id, in: start)

        #expect(names(of: outer.id, in: result) == ["Inner", "held", "last"])
        #expect(positions(of: outer.id, in: result) == [0, 1, 2])
        #expect(result.groups.count == 2)
        #expect(result.sessions.count == 2)
    }

    /// A top-level group dissolves to `nil`, which is what the flat case
    /// always did — one level up, said the same way.
    @Test func dissolvingATopLevelGroupLiftsToTheTopLevel() {
        let group = StoredGroup(name: "Temp", position: 0)
        let inside = session("inside", in: group.id, at: 0)
        let result = SidebarOrdering.dissolving(group.id, in: tree(groups: [group], sessions: [inside]))

        #expect(result.groups.isEmpty)
        #expect(result.sessions.first?.groupID == nil)
    }
}
