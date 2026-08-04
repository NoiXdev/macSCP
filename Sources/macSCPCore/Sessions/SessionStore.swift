import Foundation

/// JSON persistence for stored sessions. Stateless: every operation reads
/// and writes the file (small number of sessions, atomic writes).
public struct SessionStore: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `MACSCP_STORAGE_DIRECTORY` redirects every store that derives its
    /// location from this property (sessions, known hosts, settings, audit
    /// log, managed keys, hidden imports) to a throwaway directory instead of
    /// the real `~/Library/Application Support/macSCP` (M20 Task 12). This
    /// exists ONLY so a gated integration test can drive the built
    /// `macscp-cli` binary as a subprocess — the one place that has no other
    /// way to point a stored session or the known-hosts store somewhere
    /// isolated, short of touching the developer's real data. The GUI app
    /// never sets this variable, so production behavior is unchanged; the
    /// check is a no-op whenever it is unset or empty.
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["MACSCP_STORAGE_DIRECTORY"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("macSCP", isDirectory: true)
    }

    private var fileURL: URL {
        directory.appendingPathComponent("sessions.json")
    }

    /// On-disk container (current format). Legacy files are a bare
    /// `[StoredSession]` array — `load()` falls back to that shape, so old
    /// installations keep working without a migration step.
    private struct StoreFile: Codable {
        var groups: [StoredGroup] = []
        var sessions: [StoredSession] = []
    }

    private func load() throws -> StoreFile {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return StoreFile()
        }
        let data = try Data(contentsOf: fileURL)
        var file: StoreFile
        if let container = try? JSONDecoder().decode(StoreFile.self, from: data) {
            file = container
        } else {
            file = StoreFile(groups: [], sessions: try JSONDecoder().decode([StoredSession].self, from: data))
        }
        // Defensive: a groupID whose group no longer exists behaves like nil.
        let knownIDs = Set(file.groups.map(\.id))
        for index in file.sessions.indices {
            guard let groupID = file.sessions[index].groupID,
                  !knownIDs.contains(groupID) else { continue }
            file.sessions[index].groupID = nil
        }
        return file
    }

    private func persist(_ file: StoreFile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }

    public func all() throws -> [StoredSession] { try load().sessions }
    public func allGroups() throws -> [StoredGroup] { try load().groups }

    public func upsert(_ session: StoredSession) throws {
        var file = try load()
        if let index = file.sessions.firstIndex(where: { $0.id == session.id }) {
            file.sessions[index] = session
        } else {
            file.sessions.append(session)
        }
        try persist(file)
    }

    public func delete(id: UUID) throws {
        var file = try load()
        file.sessions.removeAll { $0.id == id }
        try persist(file)
    }

    public func upsertGroup(_ group: StoredGroup) throws {
        var file = try load()
        if let index = file.groups.firstIndex(where: { $0.id == group.id }) {
            file.groups[index] = group
        } else {
            file.groups.append(group)
        }
        try persist(file)
    }

    public func dissolveGroup(id: UUID) throws {
        var file = try load()
        file.groups.removeAll { $0.id == id }
        for index in file.sessions.indices where file.sessions[index].groupID == id {
            file.sessions[index].groupID = nil
        }
        try persist(file)
    }
}
