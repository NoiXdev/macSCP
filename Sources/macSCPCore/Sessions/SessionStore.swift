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
        directory.appendingPathComponent("sessions-v2.json")
    }

    /// The pre-M23 file. Read once, then left alone forever.
    ///
    /// A version key inside the file would have been the tidier design and is
    /// not available: macSCP 1.0 is already shipped, knows nothing about one,
    /// and aborts on the missing required `host`. A version number helps
    /// FUTURE readers, never past ones — so the new format gets a new name,
    /// and a downgrade finds its own file exactly where it left it.
    ///
    /// The price, stated where the code is: after the migration the two files
    /// diverge. A connection created here is invisible to an older build.
    private var legacyFileURL: URL {
        directory.appendingPathComponent("sessions.json")
    }

    /// On-disk container (current format).
    private struct StoreFile: Codable {
        var groups: [StoredGroup] = []
        var sessions: [StoredSession] = []
    }

    /// The same container in its pre-M23 shape.
    private struct LegacyStoreFile: Decodable {
        var groups: [StoredGroup] = []
        var sessions: [LegacyStoredSession] = []
    }

    private func load() throws -> StoreFile {
        var file: StoreFile
        if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            file = try JSONDecoder().decode(StoreFile.self, from: Data(contentsOf: fileURL))
        } else if let migrated = try migrateFromLegacy() {
            file = migrated
        } else {
            return StoreFile()
        }
        // Defensive: a groupID whose group no longer exists behaves like nil.
        let knownIDs = Set(file.groups.map(\.id))
        for index in file.sessions.indices {
            guard let groupID = file.sessions[index].groupID,
                  !knownIDs.contains(groupID) else { continue }
            file.sessions[index].groupID = nil
        }
        // Second hygiene rule, same shape as the group sweep above: an `.ssh`
        // record with no stored SSH block is unusable -- no host, no user
        // name, nothing to dial -- and before M26 it was the last thing that
        // made `StoredSession`'s SSH accessors invent `""`/`22`/`""`/
        // `.password` for a session that never had them.
        //
        // Only `.ssh`. An `.s3`/`.webdav` record with no block is equally
        // unusable, but those backends have no inventing accessors (a missing
        // block yields the EMPTY bag) and their blockless case is already
        // caught explicitly in several places -- dropping them here would make
        // those guards unreachable without removing them. See the design doc.
        //
        // Deliberately does NOT rewrite the file: a write on the read path
        // would be a new failure mode for a problem nobody has, and would
        // change the user's data without being asked. The next regular save
        // omits the record anyway; until then it is skipped on every start.
        file.sessions.removeAll(where: Self.dropsOnLoad)
        return file
    }

    /// The rule `load()` above applies, as a value anyone can ask about.
    ///
    /// It is factored out because the import planner has to reject exactly
    /// what this drops: a record it planned and this removed would be counted
    /// as imported, be invisible in the sidebar, and leave its Keychain secret
    /// unreachable. Two independent spellings of the same rule could drift;
    /// one predicate cannot. Widening it therefore widens both sides at once —
    /// see the reasoning above for why only `.ssh` is dropped.
    static func dropsOnLoad(_ session: StoredSession) -> Bool {
        session.kind == .ssh && session.ssh == nil
    }

    /// Reads the pre-M23 file, writes its upgrade to the new one, and returns
    /// it. Returns nil when there is nothing to migrate.
    ///
    /// The legacy file supported two shapes — the current container and an
    /// even older bare `[StoredSession]` array — and both are still read here,
    /// because an installation that never opened a version with groups still
    /// has the array on disk.
    private func migrateFromLegacy() throws -> StoreFile? {
        let path = legacyFileURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: legacyFileURL)
        let legacy: LegacyStoreFile
        if let container = try? JSONDecoder().decode(LegacyStoreFile.self, from: data) {
            legacy = container
        } else {
            legacy = LegacyStoreFile(
                groups: [],
                sessions: try JSONDecoder().decode([LegacyStoredSession].self, from: data))
        }
        let migrated = StoreFile(
            groups: legacy.groups, sessions: legacy.sessions.map { $0.upgraded() })
        // `try?`, deliberately: this is a READ path, and a write failure must
        // not turn a perfectly readable set of connections into an error and
        // an empty sidebar. On a read-only or full volume the first launch
        // after this update would otherwise hide every session the user has.
        // Failing to persist only costs the upgrade being redone next launch,
        // which is strictly better — and `sessions.json` is still there, so
        // nothing is lost either way.
        try? persist(migrated)
        return migrated
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
