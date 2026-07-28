import Foundation

/// A reusable, named login (M10b): username plus either a keychain-held
/// password or a private key path (with a keychain-held passphrase).
/// Contains NO secrets — those live in the SecretStore under `id`.
public struct LoginSet: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var username: String
    public var authKind: StoredSession.AuthKind
    /// Path to the private key (only set when authKind == .privateKey).
    public var keyPath: String?

    public init(
        id: UUID = UUID(), name: String, username: String,
        authKind: StoredSession.AuthKind = .password, keyPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.authKind = authKind
        self.keyPath = keyPath
    }
}

/// JSON persistence for login sets (`logins.json`), following the
/// SessionStore pattern: stateless, atomic writes.
///
/// Forward compatibility: entries are persisted as raw records whose
/// `authKind` is a plain string. A record with an UNKNOWN raw (e.g. a
/// future "agent" set written by a newer app version, M10d) is never
/// surfaced by `all()` — it must not be misread as a password set — but
/// it survives upsert/delete of other entries untouched.
public struct LoginSetStore: Sendable {
    private struct Record: Codable {
        var id: UUID
        var name: String
        var username: String
        var authKind: String
        var keyPath: String?
    }
    private struct StoreFile: Codable {
        var sets: [Record] = []
        var ignoredMergeGroups: [[UUID]] = []
    }

    private let directory: URL
    public init(directory: URL) { self.directory = directory }
    private var fileURL: URL { directory.appendingPathComponent("logins.json") }

    private func load() throws -> StoreFile {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return StoreFile()
        }
        return try JSONDecoder().decode(StoreFile.self, from: Data(contentsOf: fileURL))
    }

    private func persist(_ file: StoreFile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }

    /// All sets with a KNOWN auth kind, name-sorted case-insensitively.
    public func all() throws -> [LoginSet] {
        try load().sets.compactMap { record in
            guard let kind = StoredSession.AuthKind(rawValue: record.authKind) else { return nil }
            return LoginSet(
                id: record.id, name: record.name, username: record.username,
                authKind: kind, keyPath: record.keyPath)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func upsert(_ set: LoginSet) throws {
        var file = try load()
        let record = Record(
            id: set.id, name: set.name, username: set.username,
            authKind: set.authKind.rawValue, keyPath: set.keyPath)
        if let index = file.sets.firstIndex(where: { $0.id == set.id }) {
            file.sets[index] = record
        } else {
            file.sets.append(record)
        }
        try persist(file)
    }

    public func delete(id: UUID) throws {
        var file = try load()
        file.sets.removeAll { $0.id == id }
        try persist(file)
    }

    /// Persisted "don't suggest merging these again" groups (M10b spec §4):
    /// plain session-ID sets — deliberately never passwords or anything
    /// derived from them.
    public func ignoredMergeGroups() throws -> [Set<UUID>] {
        try load().ignoredMergeGroups.map(Set.init)
    }

    public func addIgnoredMergeGroup(_ sessionIDs: Set<UUID>) throws {
        var file = try load()
        file.ignoredMergeGroups.append(Array(sessionIDs).sorted { $0.uuidString < $1.uuidString })
        try persist(file)
    }
}
