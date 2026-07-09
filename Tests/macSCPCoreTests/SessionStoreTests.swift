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
        let session = StoredSession(name: "web", host: "example.com", username: "tim")
        try store.upsert(session)
        #expect(try store.all() == [session])
    }

    @Test func upsertReplacesById() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var session = StoredSession(name: "web", host: "example.com", username: "tim")
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
        let session = StoredSession(name: "web", host: "example.com", username: "tim")
        try store.upsert(session)
        try store.delete(id: session.id)
        #expect(try store.all() == [])
    }

    @Test func deleteUnknownIdIsNoop() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = StoredSession(name: "web", host: "example.com", username: "tim")
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
}
