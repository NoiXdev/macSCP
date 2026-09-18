import Foundation
import Testing
@testable import macSCPCore

/// `GroupPickerEntries.build(groups:excluding:)` — the one list every place
/// that chooses a group reads (jump-and-groups plan, Task 5). Order, depth,
/// path, the exclusion of a folder's own subtree, and the repair of a
/// damaged parent chain are each pinned here; which places read it is
/// `GroupPickerWiringGuardTests`' claim, not this suite's.
@Suite("Group picker entries")
struct GroupPickerEntriesTests {
    /// Work (0) ├ Prod (0) │ └ Web (0) └ Stage (1); Home (1). Held in an
    /// order that is deliberately NOT the tree's, as the store keeps them.
    private static let work = StoredGroup(name: "Work", position: 0)
    private static let home = StoredGroup(name: "Home", position: 1)
    private static let prod = StoredGroup(name: "Prod", parentID: work.id, position: 0)
    private static let stage = StoredGroup(name: "Stage", parentID: work.id, position: 1)
    private static let web = StoredGroup(name: "Web", parentID: prod.id, position: 0)
    private static let stored = [home, web, stage, prod, work]

    @Test func entriesComeDepthFirstInSidebarOrderNotStoreOrder() {
        let entries = GroupPickerEntries.build(groups: Self.stored)
        #expect(entries.map(\.id) == [Self.work.id, Self.prod.id, Self.web.id, Self.stage.id, Self.home.id])
    }

    @Test func eachEntryCarriesItsDepth() {
        let entries = GroupPickerEntries.build(groups: Self.stored)
        #expect(entries.map(\.depth) == [0, 1, 2, 1, 0])
    }

    @Test func eachEntryCarriesItsOwnNameAndItsFullPath() {
        let entries = GroupPickerEntries.build(groups: Self.stored)
        #expect(entries.map(\.name) == ["Work", "Prod", "Web", "Stage", "Home"])
        #expect(entries.map(\.path) == ["Work", "Work / Prod", "Work / Prod / Web", "Work / Stage", "Home"])
    }

    /// The separator is the CLI's own: a group's path in a picker is the
    /// exact string `sessions --json` prints as a session's `groupPath` and
    /// `--group` reads back, so what the app shows can be typed.
    @Test func thePathIsTheOneTheCLIPrintsForASessionInThatGroup() {
        let session = StoredSession(name: "s", groupID: Self.web.id)
        let catalogPath = SessionCatalog(sessions: [session], groups: Self.stored)
            .rows(matching: .init()).first?.groupPath
        let entry = GroupPickerEntries.build(groups: Self.stored).first { $0.id == Self.web.id }
        #expect(catalogPath == "Work / Prod / Web")
        #expect(entry?.path == catalogPath)
    }

    /// Excluding a folder removes the folder and every group below it —
    /// the set `GroupTree.wouldCycle` refuses as a new parent — and nothing
    /// else: its parent and its siblings stay.
    @Test func excludingAGroupRemovesItAndItsDescendantsOnly() {
        let entries = GroupPickerEntries.build(groups: Self.stored, excluding: Self.prod.id)
        #expect(entries.map(\.id) == [Self.work.id, Self.stage.id, Self.home.id])
    }

    @Test func excludingAnIDNamingNoGroupExcludesNothing() {
        let entries = GroupPickerEntries.build(groups: Self.stored, excluding: UUID())
        #expect(entries.count == Self.stored.count)
    }

    /// A parent that is not in the list is repaired the way `GroupTree`
    /// repairs it everywhere else: the child is LIFTED to the top level,
    /// never dropped — and its path starts with its own name, since it no
    /// longer has an ancestor to name.
    @Test func aGroupWhoseParentIsMissingIsLiftedToTheTopLevel() {
        let orphan = StoredGroup(name: "Orphan", parentID: UUID(), position: 5)
        let entries = GroupPickerEntries.build(groups: Self.stored + [orphan])
        let lifted = entries.first { $0.id == orphan.id }
        #expect(lifted?.depth == 0)
        #expect(lifted?.path == "Orphan")
        #expect(entries.map(\.id).last == orphan.id)
    }

    /// A ring is cut the way `GroupTree.repaired` cuts it; every group still
    /// appears exactly once, and the walk terminates.
    @Test func aCycleIsRepairedAndEveryGroupAppearsOnce() {
        let aID = UUID()
        let bID = UUID()
        let a = StoredGroup(id: aID, name: "A", parentID: bID, position: 0)
        let b = StoredGroup(id: bID, name: "B", parentID: aID, position: 0)
        let entries = GroupPickerEntries.build(groups: [a, b])
        #expect(Set(entries.map(\.id)) == [aID, bID])
        #expect(entries.count == 2)
        #expect(entries.map(\.depth) == [0, 1])
    }

    /// A duplicated id — a file merged by hand, which `GroupTree.repaired`
    /// does not deduplicate — can leave a ring in the walk's own terms
    /// (the second "A" hangs under "B", which hangs under the first "A").
    /// The walk lists each id once and ends, rather than recursing until
    /// the stack runs out.
    @Test func aDuplicatedIDIsListedOnceAndTheWalkEnds() {
        let aID = UUID()
        let b = StoredGroup(name: "B", parentID: aID, position: 0)
        let first = StoredGroup(id: aID, name: "A", position: 0)
        let second = StoredGroup(id: aID, name: "A again", parentID: b.id, position: 0)
        let entries = GroupPickerEntries.build(groups: [first, b, second])
        #expect(entries.map(\.id) == [aID, b.id])
    }

    @Test func noGroupsAnswersNoEntries() {
        #expect(GroupPickerEntries.build(groups: []).isEmpty)
    }
}
