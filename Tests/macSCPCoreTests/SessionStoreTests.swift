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
}
