import Foundation

/// A session from an import file, resolved against the existing store: a
/// fresh id, an optionally re-mapped group, and its carried-along password
/// (if the export included one).
public struct PlannedSession: Equatable, Sendable {
    public var session: StoredSession
    public var password: String?

    public init(session: StoredSession, password: String?) {
        self.session = session
        self.password = password
    }
}

/// The result of planning an import: what to create, additively, against
/// the existing store. Pure data — applying it is the caller's job.
public struct SessionImportPlan: Equatable, Sendable {
    public var groupsToCreate: [StoredGroup]
    public var sessionsToImport: [PlannedSession]
    public var skipped: [ExportedSession]

    public init(groupsToCreate: [StoredGroup], sessionsToImport: [PlannedSession], skipped: [ExportedSession]) {
        self.groupsToCreate = groupsToCreate
        self.sessionsToImport = sessionsToImport
        self.skipped = skipped
    }
}

/// Plans an additive import from a decoded `SessionExportPayload` against
/// the current store contents (spec M9a §2.2/§2.3). Pure function: no
/// store, no keychain — every branch is unit testable.
public enum SessionImportPlanner {
    public static func plan(
        existing: [StoredSession], existingGroups: [StoredGroup], incoming: SessionExportPayload
    ) -> SessionImportPlan {
        // Resolve groups first: exact name match against existing groups,
        // otherwise a fresh group is created. A local mapping tracks
        // file-local group id -> resolved (existing or freshly created) id.
        var groupIDMap: [UUID: UUID] = [:]
        var groupsToCreate: [StoredGroup] = []
        for fileGroup in incoming.groups {
            if let match = existingGroups.first(where: { $0.name == fileGroup.name }) {
                groupIDMap[fileGroup.id] = match.id
            } else {
                let created = StoredGroup(name: fileGroup.name)
                groupsToCreate.append(created)
                groupIDMap[fileGroup.id] = created.id
            }
        }

        // Then sessions, in file order: duplicate key is
        // (host.lowercased(), port, username) against both the existing
        // store and triples already accepted from earlier in this file
        // (keep-first).
        var seenKeys = Set(existing.map { duplicateKey(host: $0.host, port: $0.port, username: $0.username) })
        var sessionsToImport: [PlannedSession] = []
        var skipped: [ExportedSession] = []

        for fileSession in incoming.sessions {
            let key = duplicateKey(host: fileSession.host, port: fileSession.port, username: fileSession.username)
            if seenKeys.contains(key) {
                skipped.append(fileSession)
                continue
            }
            seenKeys.insert(key)

            let resolvedGroupID = fileSession.groupID.flatMap { groupIDMap[$0] }
            let session = StoredSession(
                id: UUID(),
                name: fileSession.name,
                host: fileSession.host,
                port: fileSession.port,
                username: fileSession.username,
                authKind: fileSession.authKind,
                keyPath: fileSession.keyPath,
                groupID: resolvedGroupID)
            sessionsToImport.append(PlannedSession(session: session, password: fileSession.password))
        }

        return SessionImportPlan(
            groupsToCreate: groupsToCreate, sessionsToImport: sessionsToImport, skipped: skipped)
    }

    private static func duplicateKey(host: String, port: Int, username: String) -> String {
        "\(host.lowercased())|\(port)|\(username)"
    }
}
