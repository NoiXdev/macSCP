import Foundation

/// JSON persistence for stored sessions. Stateless: every operation reads
/// and writes the file (small number of sessions, atomic writes).
public struct SessionStore: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("macSCP", isDirectory: true)
    }

    private var fileURL: URL {
        directory.appendingPathComponent("sessions.json")
    }

    public func all() throws -> [StoredSession] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([StoredSession].self, from: data)
    }

    public func upsert(_ session: StoredSession) throws {
        var sessions = try all()
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        try persist(sessions)
    }

    public func delete(id: UUID) throws {
        var sessions = try all()
        sessions.removeAll { $0.id == id }
        try persist(sessions)
    }

    private func persist(_ sessions: [StoredSession]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sessions).write(to: fileURL, options: .atomic)
    }
}
