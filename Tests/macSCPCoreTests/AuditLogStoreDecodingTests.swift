import Foundation
import Testing
@testable import macSCPCore

/// Covers the "one bad entry erases the whole log" defect: `loadIfNeeded`
/// used to decode the on-disk array in one shot, so a single entry with an
/// unrecognized `AuditEvent.Kind` raw value (e.g. written by a newer app
/// version) made the whole array fail to decode and read back as empty --
/// and the next `append` then persisted only the new entry, discarding the
/// rest of the session's history.
@Suite("AuditLogStore decoding resilience")
struct AuditLogStoreDecodingTests {
    private func makeStore() throws -> (AuditLogStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-decoding-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (AuditLogStore(directory: dir), dir)
    }

    private func event(_ detail: String, kind: AuditEvent.Kind = .transferFinished) -> AuditEvent {
        AuditEvent(kind: kind, detail: detail)
    }

    /// Encodes `events` with the same encoder settings `AuditLogStore` uses,
    /// then replaces the middle entry's `kind` value with a raw value no
    /// current `Kind` case has -- simulating a log entry written by a newer
    /// app version. Building the file this way (encode, then targeted
    /// string replacement) keeps the rest of the format genuine instead of
    /// hand-assembling JSON that could drift from the real shape.
    private func writeLogWithUnknownKind(at path: URL, events: [AuditEvent]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(events)
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\"transferFailed\"", with: "\"somethingFromTheFuture\"")
        try Data(text.utf8).write(to: path)
    }

    @Test func unknownKindCostsOnlyItsEntry() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let path = dir.appendingPathComponent("\(id.uuidString).json")
        try writeLogWithUnknownKind(
            at: path,
            events: [event("first"), event("second", kind: .transferFailed), event("third")]
        )

        let read = store.events(for: id)
        #expect(read.map(\.detail) == ["first", "third"])
    }

    @Test func partiallyReadLogIsNotOverwritten() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let path = dir.appendingPathComponent("\(id.uuidString).json")
        try writeLogWithUnknownKind(
            at: path,
            events: [event("first"), event("second", kind: .transferFailed), event("third")]
        )

        _ = store.events(for: id)  // loads from disk, should flag the session as partially read
        store.append(event("fourth"), for: id)

        // The running session still sees everything it could decode, plus the new entry.
        #expect(store.events(for: id).map(\.detail) == ["first", "third", "fourth"])

        // But the file itself must be untouched: the entry this process
        // couldn't decode is still there for a version that can read it.
        let raw = try String(contentsOf: path, encoding: .utf8)
        #expect(raw.contains("somethingFromTheFuture"))
    }

    @Test func cleanLogAppendsNormally() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        store.append(event("first"), for: id)
        store.append(event("second"), for: id)
        _ = store.events(for: id)  // sync point: waits for both appends to reach disk

        // Fresh store instance forces a real decode from disk rather than reusing the cache.
        let reloaded = AuditLogStore(directory: dir)
        reloaded.append(event("third"), for: id)

        #expect(reloaded.events(for: id).map(\.detail) == ["first", "second", "third"])
        let raw = try String(
            contentsOf: dir.appendingPathComponent("\(id.uuidString).json"), encoding: .utf8)
        #expect(raw.contains("first") && raw.contains("second") && raw.contains("third"))
    }
}
