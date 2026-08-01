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
    /// The protocol this set's credentials are for (M12). Legacy sets
    /// (persisted before this field existed) default to `.ssh`.
    public var kind: ConnectionKind = .ssh
    /// S3 access key ID (M12), only meaningful when `kind == .s3`. The
    /// SECRET (secret access key) is never here -- it lives in the Keychain
    /// under `id`, exactly like an SSH set's password/passphrase.
    public var accessKeyID: String? = nil

    public init(
        id: UUID = UUID(), name: String, username: String,
        authKind: StoredSession.AuthKind = .password, keyPath: String? = nil,
        kind: ConnectionKind = .ssh, accessKeyID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.authKind = authKind
        self.keyPath = keyPath
        self.kind = kind
        self.accessKeyID = accessKeyID
    }
}

/// JSON persistence for login sets (`logins.json`), following the
/// SessionStore pattern: stateless, atomic writes.
///
/// Forward compatibility: entries are persisted as raw records whose
/// `authKind` is a plain string. A record with an UNKNOWN raw (e.g. some
/// future auth kind written by a newer app version — `.agent`, M10d, was
/// exactly this kind of forward-compat case until it became a known raw
/// itself) is never surfaced by `all()` — it must not be misread as a
/// password set — but it survives upsert/delete of other entries untouched.
public struct LoginSetStore: Sendable {
    private struct Record: Codable {
        var id: UUID
        var name: String
        var username: String
        var authKind: String
        var keyPath: String?
        /// M12: absent on legacy records -- synthesized `Codable` decodes a
        /// missing key to `nil` for an Optional, which `all()` then maps to
        /// `.ssh`, so no custom `init(from:)` is needed here.
        var kind: ConnectionKind?
        /// M12: S3 access key ID; the secret access key is never persisted.
        var accessKeyID: String?
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
            guard let authKind = StoredSession.AuthKind(rawValue: record.authKind) else { return nil }
            return LoginSet(
                id: record.id, name: record.name, username: record.username,
                authKind: authKind, keyPath: record.keyPath,
                kind: record.kind ?? .ssh, accessKeyID: record.accessKeyID)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func upsert(_ set: LoginSet) throws {
        var file = try load()
        let record = Record(
            id: set.id, name: set.name, username: set.username,
            authKind: set.authKind.rawValue, keyPath: set.keyPath,
            kind: set.kind, accessKeyID: set.accessKeyID)
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
