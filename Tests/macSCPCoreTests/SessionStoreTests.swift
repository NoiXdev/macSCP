import Foundation
import Testing
@testable import macSCPCore

@Suite("SessionStore")
struct SessionStoreTests {
    private func makeTempStore() -> (SessionStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-sessions-\(UUID().uuidString)")
        return (SessionStore(directory: dir), dir)
    }

    @Test func emptyWhenNoFileExists() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.all() == [])
    }

    @Test func upsertPersistsAndRoundtrips() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = sshSession(name: "web", host: "example.com", username: "tim")
        try store.upsert(session)
        #expect(try store.all() == [session])
    }

    @Test func upsertReplacesById() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var session = sshSession(name: "web", host: "example.com", username: "tim")
        try store.upsert(session)
        session.name = "web-neu"
        try store.upsert(session)
        let all = try store.all()
        #expect(all.count == 1)
        #expect(all.first?.name == "web-neu")
    }

    @Test func deleteRemovesSession() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = sshSession(name: "web", host: "example.com", username: "tim")
        try store.upsert(session)
        try store.delete(id: session.id)
        #expect(try store.all() == [])
    }

    @Test func deleteUnknownIdIsNoop() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = sshSession(name: "web", host: "example.com", username: "tim")
        try store.upsert(session)
        try store.delete(id: UUID())
        #expect(try store.all() == [session])
    }

    @Test func corruptFileThrows() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("kein json".utf8).write(to: dir.appendingPathComponent("sessions.json"))
        #expect(throws: (any Error).self) {
            _ = try store.all()
        }
    }

    @Test func groupsRoundtripThroughTheStore() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = StoredGroup(name: "Customers")
        try store.upsertGroup(group)
        let session = sshSession(name: "web", host: "h", username: "u", groupID: group.id)
        try store.upsert(session)

        #expect(try store.allGroups() == [group])
        #expect(try store.all().first?.groupID == group.id)
    }

    @Test func legacyPlainArrayFileLoadsWithoutGroups() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = """
        [{"authKind":"password","host":"legacy.example","id":"11111111-1111-1111-1111-111111111111",\
        "name":"old","port":22,"username":"tim"}]
        """
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try legacy.data(using: .utf8)!.write(to: dir.appendingPathComponent("sessions.json"))

        #expect(try store.allGroups().isEmpty)
        let sessions = try store.all()
        #expect(sessions.count == 1)
        #expect(sessions.first?.name == "old")
        #expect(sessions.first?.groupID == nil)
    }

    @Test func dissolveGroupUngroupsItsSessionsInOneWrite() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let group = StoredGroup(name: "Temp")
        try store.upsertGroup(group)
        try store.upsert(sshSession(name: "a", host: "h", username: "u", groupID: group.id))
        try store.dissolveGroup(id: group.id)

        #expect(try store.allGroups().isEmpty)
        #expect(try store.all().first?.groupID == nil)
    }

    @Test func orphanedGroupIDIsTreatedAsNilOnLoad() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.upsert(sshSession(name: "a", host: "h", username: "u", groupID: UUID()))
        #expect(try store.all().first?.groupID == nil)
    }

    @Test func groupRenamePersistsViaUpsertGroup() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var group = StoredGroup(name: "Old")
        try store.upsertGroup(group)
        group.name = "New"
        try store.upsertGroup(group)
        #expect(try store.allGroups() == [group])
        #expect(try store.allGroups().count == 1)
    }

    // MARK: - Blockless-record drop (M26/T1)
    //
    // These fixtures are written BY HAND as JSON, not produced through the
    // store: no save path in the app can write a `.ssh` record with no `ssh`
    // block (`SessionListViewModel.save` always attaches one), so the only
    // way this shape reaches disk is a hand-edited or damaged
    // `sessions-v2.json`. That is exactly the case under test, so a real
    // `SessionStore` reads a fixture file rather than going through a mock —
    // a mock would not exercise the read path this suite is about.

    /// A record with `"kind": "ssh"` and no `"ssh"` key, next to a healthy
    /// SSH neighbour, in the CURRENT container format (`sessions-v2.json`,
    /// not the pre-M23 legacy shape).
    private let blocklessSSHFixture = """
    {
      "groups": [],
      "sessions": [
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "broken",
          "kind": "ssh"
        },
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "name": "healthy",
          "kind": "ssh",
          "ssh": {
            "host": "example.com",
            "port": 22,
            "username": "tim",
            "authKind": "password"
          }
        }
      ]
    }
    """

    private func writeBlocklessSSHFixture(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(blocklessSSHFixture.utf8).write(to: dir.appendingPathComponent("sessions-v2.json"))
    }

    @Test func aBlocklessSSHRecordIsDroppedWhenLoading() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeBlocklessSSHFixture(to: dir)

        let sessions = try store.all()
        #expect(!sessions.contains { $0.name == "broken" })
    }

    @Test func aHealthyNeighbourSurvivesTheDrop() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeBlocklessSSHFixture(to: dir)

        let sessions = try store.all()
        let healthy = try #require(sessions.first { $0.name == "healthy" })
        #expect(healthy.kind == .ssh)
        #expect(healthy.ssh?.host == "example.com")
        #expect(healthy.ssh?.port == 22)
        #expect(healthy.ssh?.username == "tim")
        #expect(healthy.ssh?.authKind == .password)
    }

    /// Pins that the read path never writes: a broken record is skipped in
    /// the RETURNED list on every load, not rewritten out of the file. A
    /// write on the read path would be a new failure mode for a problem
    /// nobody has, and would change the user's file without being asked.
    @Test func loadingDoesNotRewriteTheFile() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeBlocklessSSHFixture(to: dir)
        let fileURL = dir.appendingPathComponent("sessions-v2.json")
        let before = try Data(contentsOf: fileURL)

        _ = try store.all()

        #expect(try Data(contentsOf: fileURL) == before)
    }

    /// Pins the deliberate asymmetry: an `.s3` record with no `s3` block is
    /// equally unusable but is NOT dropped here, because S3/WebDAV have no
    /// inventing accessors and their blockless case is already caught
    /// explicitly elsewhere (`StoredSessionConnectionConfig.build`). Widening
    /// the drop to those kinds later is a decision, not an oversight.
    @Test func aBlocklessS3RecordIsKept() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = """
        {
          "groups": [],
          "sessions": [
            {
              "id": "33333333-3333-3333-3333-333333333333",
              "name": "broken-s3",
              "kind": "s3"
            }
          ]
        }
        """
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(fixture.utf8).write(to: dir.appendingPathComponent("sessions-v2.json"))

        let sessions = try store.all()
        #expect(sessions.contains { $0.name == "broken-s3" })
    }
}
