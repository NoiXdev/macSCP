import Foundation
import Testing
@testable import macSCPCore

@Suite("AuditLogStore")
struct AuditLogStoreTests {
    private func makeStore() throws -> (AuditLogStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (AuditLogStore(directory: dir), dir)
    }

    private func event(_ detail: String, kind: AuditEvent.Kind = .transferFinished) -> AuditEvent {
        AuditEvent(kind: kind, detail: detail)
    }

    @Test func appendAndReadRoundtrip() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        store.append(event("first"), for: id)
        store.append(event("second", kind: .rename), for: id)
        let events = store.events(for: id)
        #expect(events.map(\.detail) == ["first", "second"])
        #expect(events[1].kind == .rename)
        // Other sessions are isolated.
        #expect(store.events(for: UUID()).isEmpty)
    }

    @Test func rollingCapKeepsNewest() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        for index in 0...AuditLogStore.maxEntriesPerSession {  // one over the cap
            store.append(event("e\(index)"), for: id)
        }
        let events = store.events(for: id)
        #expect(events.count == AuditLogStore.maxEntriesPerSession)
        #expect(events.first?.detail == "e1")   // oldest ("e0") evicted
        #expect(events.last?.detail == "e\(AuditLogStore.maxEntriesPerSession)")
    }

    @Test func clearAndDeleteRemoveEverything() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        store.append(event("x"), for: id)
        store.clear(for: id)
        #expect(store.events(for: id).isEmpty)
        store.append(event("y"), for: id)
        store.deleteLog(for: id)
        #expect(store.events(for: id).isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("\(id).json").path(percentEncoded: false)))
    }

    @Test func corruptFileReadsAsEmpty() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        try Data("not json".utf8).write(to: dir.appendingPathComponent("\(id).json"))
        #expect(store.events(for: id).isEmpty)
        // A later append recovers the file (starts fresh rather than throwing).
        store.append(event("fresh"), for: id)
        #expect(store.events(for: id).map(\.detail) == ["fresh"])
    }

    @Test func unwritableDirectoryNeverThrowsOrDisturbs() throws {
        // Directory path that is actually a FILE (M9a pattern): every write
        // fails internally; append must swallow it silently.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-blocked-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = AuditLogStore(directory: file)
        let id = UUID()
        store.append(event("lost"), for: id)   // must not throw/trap
        store.clear(for: id)
        store.deleteLog(for: id)
        #expect(store.events(for: id).isEmpty)
    }
}
