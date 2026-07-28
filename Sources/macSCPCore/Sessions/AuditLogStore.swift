import Foundation

/// Per-session audit log persistence (M9b). One JSON file per stored
/// session under `audit/`, rolling cap of the newest 1000 entries.
/// EVERY method is throw-free by design: a broken log must never disturb
/// a transfer or file action (spec M9b §2) — write errors are swallowed,
/// a corrupt file reads as empty and is recovered by the next append.
public struct AuditLogStore: Sendable {
    static let maxEntriesPerSession = 1000

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        SessionStore.defaultDirectory.appendingPathComponent("audit", isDirectory: true)
    }

    private func fileURL(for sessionID: UUID) -> URL {
        directory.appendingPathComponent("\(sessionID.uuidString).json")
    }

    public func append(_ event: AuditEvent, for sessionID: UUID) {
        var events = self.events(for: sessionID)
        events.append(event)
        if events.count > Self.maxEntriesPerSession {
            events.removeFirst(events.count - Self.maxEntriesPerSession)
        }
        persist(events, for: sessionID)
    }

    public func events(for sessionID: UUID) -> [AuditEvent] {
        guard let data = try? Data(contentsOf: fileURL(for: sessionID)) else { return [] }
        return (try? JSONDecoder().decode([AuditEvent].self, from: data)) ?? []
    }

    public func clear(for sessionID: UUID) {
        persist([], for: sessionID)
    }

    public func deleteLog(for sessionID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: sessionID))
    }

    private func persist(_ events: [AuditEvent], for sessionID: UUID) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(events).write(to: fileURL(for: sessionID), options: .atomic)
        } catch {
            // Deliberately silent (spec M9b §2): logging must never break
            // the flow it observes.
        }
    }
}
