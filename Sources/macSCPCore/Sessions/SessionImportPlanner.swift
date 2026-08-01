import Foundation

/// A session from an import file, resolved against the existing store: a
/// fresh id, an optionally re-mapped group, and its carried-along password
/// (if the export included one).
public struct PlannedSession: Equatable, Sendable {
    public var session: StoredSession
    public var password: String?
    /// Carried-along secret for `session.jump`, if any (M10c) — stored under
    /// the jump's FRESH `secretID` when applied, mirroring `password` for
    /// the target.
    public var jumpPassword: String?

    public init(session: StoredSession, password: String?, jumpPassword: String? = nil) {
        self.session = session
        self.password = password
        self.jumpPassword = jumpPassword
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
        // otherwise a fresh group is prepared. A local mapping tracks
        // file-local group id -> resolved (existing or freshly created) id.
        // Freshly-created groups are held in `freshGroupsByFileID` rather
        // than committed to `groupsToCreate` immediately — a file whose only
        // sessions referencing a group are all skipped as duplicates must
        // not leave a ghost group behind (M9a final review, Finding 2), so
        // the final `groupsToCreate` is filtered to groups an actually
        // imported session references, after the session loop below.
        var groupIDMap: [UUID: UUID] = [:]
        var freshGroupsByFileID: [UUID: StoredGroup] = [:]
        for fileGroup in incoming.groups {
            if let match = existingGroups.first(where: { $0.name == fileGroup.name }) {
                groupIDMap[fileGroup.id] = match.id
            } else {
                let created = StoredGroup(name: fileGroup.name)
                freshGroupsByFileID[fileGroup.id] = created
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
            // Jump fields are only present together (all-or-nothing from
            // `exportPayload`) -- `jumpHost`/`jumpUsername` gate construction.
            // `secretID` is left at its default, generating a FRESH slot;
            // `loginSetID` is always nil -- login sets are never imported, so
            // a jump that referenced one becomes plain manual mode with the
            // resolved values baked in at export time.
            var jump: StoredSession.JumpSpec?
            if let jumpHost = fileSession.jumpHost, let jumpUsername = fileSession.jumpUsername {
                jump = StoredSession.JumpSpec(
                    host: jumpHost,
                    port: fileSession.jumpPort ?? 22,
                    username: jumpUsername,
                    authKind: fileSession.jumpAuthKind ?? .password,
                    keyPath: fileSession.jumpKeyPath)
            }
            // Kind (M12): absent on legacy payloads -> `.ssh`, same
            // legacy-safe default as `StoredSession.kind` itself. An `.s3`
            // session's persisted (secret-free) config is only built when
            // the file actually carries S3 fields.
            let kind = fileSession.kind ?? .ssh
            var s3: StoredS3Config?
            if kind == .s3, let accessKeyID = fileSession.s3AccessKeyID,
               let region = fileSession.s3Region, let endpoint = fileSession.s3Endpoint,
               let bucket = fileSession.s3Bucket {
                s3 = StoredS3Config(
                    accessKeyID: accessKeyID, region: region, endpoint: endpoint,
                    bucket: bucket, usePathStyle: fileSession.s3UsePathStyle ?? false)
            }
            let session = StoredSession(
                id: UUID(),
                name: fileSession.name,
                host: fileSession.host,
                port: fileSession.port,
                username: fileSession.username,
                authKind: fileSession.authKind,
                keyPath: fileSession.keyPath,
                groupID: resolvedGroupID,
                jump: jump,
                kind: kind,
                s3: s3)
            // The kind's single secret always travels in the same
            // `password` slot -- for `.ssh` this is the SSH password, for
            // `.s3` it's the secret access key (both stored in the Keychain
            // under the session's own id at apply time).
            let secret = kind == .s3 ? fileSession.s3SecretAccessKey : fileSession.password
            sessionsToImport.append(PlannedSession(
                session: session, password: secret,
                jumpPassword: jump != nil ? fileSession.jumpPassword : nil))
        }

        // Only commit a freshly-created group if an actually-imported
        // session ends up referencing it; file order is preserved.
        let referencedGroupIDs = Set(sessionsToImport.compactMap(\.session.groupID))
        let groupsToCreate = incoming.groups.compactMap { fileGroup -> StoredGroup? in
            guard let created = freshGroupsByFileID[fileGroup.id],
                  referencedGroupIDs.contains(created.id) else { return nil }
            return created
        }

        return SessionImportPlan(
            groupsToCreate: groupsToCreate, sessionsToImport: sessionsToImport, skipped: skipped)
    }

    private static func duplicateKey(host: String, port: Int, username: String) -> String {
        "\(host.lowercased())|\(port)|\(username)"
    }
}
