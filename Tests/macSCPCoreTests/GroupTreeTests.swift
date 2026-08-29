import Foundation
import Testing
@testable import macSCPCore

@Suite("Group tree")
struct GroupTreeTests {
    private func group(_ name: String, parent: UUID? = nil, at position: Int = 0)
        -> StoredGroup
    {
        StoredGroup(id: UUID(), name: name, parentID: parent, position: position)
    }

    @Test func aGroupCannotBecomeItsOwnParent() {
        let a = group("a")
        #expect(GroupTree.wouldCycle(moving: a.id, under: a.id, in: [a]))
    }

    @Test func aGroupCannotMoveUnderItsOwnDescendant() {
        let a = group("a")
        let b = group("b", parent: a.id)
        let c = group("c", parent: b.id)
        #expect(GroupTree.wouldCycle(moving: a.id, under: c.id, in: [a, b, c]))
    }

    @Test func anUnrelatedMoveIsFine() {
        let a = group("a")
        let b = group("b")
        #expect(!GroupTree.wouldCycle(moving: a.id, under: b.id, in: [a, b]))
    }

    @Test func movingToTheTopLevelIsAlwaysFine() {
        let a = group("a")
        let b = group("b", parent: a.id)
        #expect(!GroupTree.wouldCycle(moving: b.id, under: nil, in: [a, b]))
    }

    @Test func repairLiftsAGroupWhoseParentIsMissing() {
        // An older export carries no parent, and a foreign file can name one
        // that is not in it. Nothing is discarded: the group lands at the top.
        let orphan = group("orphan", parent: UUID())
        let repaired = GroupTree.repaired([orphan])
        #expect(repaired.count == 1)
        #expect(repaired[0].parentID == nil)
    }

    @Test func repairBreaksACycleByLiftingTheFirstMemberItReaches() {
        var a = group("a")
        var b = group("b")
        a.parentID = b.id
        b.parentID = a.id
        let repaired = GroupTree.repaired([a, b])
        #expect(repaired.count == 2)
        #expect(repaired.filter { $0.parentID == nil }.count >= 1)
        #expect(!GroupTree.hasCycle(repaired))
    }

    @Test func repairLeavesAHealthyTreeAlone() {
        let a = group("a")
        let b = group("b", parent: a.id)
        #expect(GroupTree.repaired([a, b]) == [a, b])
    }

    @Test func childrenComeBackInPositionOrder() {
        let parent = group("p")
        let second = group("second", parent: parent.id, at: 1)
        let first = group("first", parent: parent.id, at: 0)
        let names = GroupTree.children(of: parent.id, in: [parent, second, first])
            .map(\.name)
        #expect(names == ["first", "second"])
    }

    /// The chain a filtered sidebar has to keep alive: a folder carrying no
    /// match of its own still has to be on screen when something below it
    /// matches, and that is answered by walking `parentID` upward from the
    /// match rather than by looking at the folder.
    @Test func selfAndAncestorsWalkTheWholeChainUpward() {
        let a = group("a")
        let b = group("b", parent: a.id)
        let c = group("c", parent: b.id)
        #expect(GroupTree.selfAndAncestors(of: c.id, in: [a, b, c]) == [a.id, b.id, c.id])
        #expect(GroupTree.selfAndAncestors(of: a.id, in: [a, b, c]) == [a.id])
    }

    /// Three ways the walk can run out of tree, none of them an error: a
    /// parent that is not in the list (the walk ends where the chain ends),
    /// a ring (every member is named once and the walk stops), and an id
    /// naming no group at all (nothing to name).
    @Test func selfAndAncestorsStopAtABrokenChainACycleAndAnUnknownID() {
        let orphan = group("orphan", parent: UUID())
        #expect(GroupTree.selfAndAncestors(of: orphan.id, in: [orphan]) == [orphan.id])

        var a = group("a")
        var b = group("b")
        a.parentID = b.id
        b.parentID = a.id
        #expect(GroupTree.selfAndAncestors(of: a.id, in: [a, b]) == [a.id, b.id])

        #expect(GroupTree.selfAndAncestors(of: UUID(), in: [a, b]).isEmpty)
    }
}

/// The migration half of the same change: `parentID` and `position` are new
/// keys in a file format that is NOT getting a new name, so every assertion
/// here is about JSON TEXT that lacks them — the state every file on every
/// disk is in right now.
///
/// A round trip through an in-memory value cannot make these statements: it
/// encodes the keys it is about to decode, so it passes whether or not the
/// decoder tolerates their absence. Only literal text without the keys can
/// fail the way a user's file would.
@Suite("Order fields on an older file")
struct OrderFieldMigrationTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func aGroupWrittenBeforeTheseFieldsDecodesToTheTopLevel() throws {
        let json = """
        {"id":"6E3E4B4A-6A0A-4E2E-9C5A-2B1D0F7A9C11","name":"Servers"}
        """
        let group = try decode(StoredGroup.self, json)
        #expect(group.name == "Servers")
        #expect(group.parentID == nil)
        #expect(group.position == 0)
    }

    @Test func aSessionWrittenBeforeThisFieldDecodesAtPositionZero() throws {
        let json = """
        {"id":"1C1D2E3F-4A5B-4C6D-8E7F-9A0B1C2D3E4F","name":"web"}
        """
        let session = try decode(StoredSession.self, json)
        #expect(session.name == "web")
        #expect(session.position == 0)
    }

    /// The same statement one level up: the whole container, under the file
    /// name the store really reads, through the store itself.
    @Test func aStoreFileWrittenBeforeTheseFieldsStillLoads() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
        {
          "groups" : [
            { "id" : "6E3E4B4A-6A0A-4E2E-9C5A-2B1D0F7A9C11", "name" : "Servers" }
          ],
          "sessions" : [
            {
              "groupID" : "6E3E4B4A-6A0A-4E2E-9C5A-2B1D0F7A9C11",
              "id" : "1C1D2E3F-4A5B-4C6D-8E7F-9A0B1C2D3E4F",
              "kind" : "ssh",
              "name" : "web",
              "ssh" : { "authKind" : "password", "host" : "example.com",
                        "port" : 22, "username" : "tim" }
            }
          ]
        }
        """
        try Data(json.utf8).write(
            to: directory.appendingPathComponent("sessions-v2.json"), options: .atomic)
        let store = SessionStore(directory: directory)

        let groups = try store.allGroups()
        #expect(groups.count == 1)
        #expect(groups[0].parentID == nil)
        #expect(groups[0].position == 0)

        let sessions = try store.all()
        #expect(sessions.count == 1)
        #expect(sessions[0].name == "web")
        #expect(sessions[0].groupID == groups[0].id)
        #expect(sessions[0].position == 0)
    }
}
