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
    /// True when this replaces an existing session — `session.id` is the
    /// EXISTING record's id, so `store.upsert` overwrites it in place rather
    /// than creating a new one. Mirrors `PlannedLoginSet.replacesExisting`
    /// (M19): the applier must also overwrite that session's Keychain
    /// secret in this case, which is not yet wired (a following task's job —
    /// this field is the seam it uses). Defaults to `false` so call sites
    /// that only ever plan a fresh import need not repeat it.
    public var replacesExisting: Bool

    public init(
        session: StoredSession, password: String?, jumpPassword: String? = nil,
        replacesExisting: Bool = false
    ) {
        self.session = session
        self.password = password
        self.jumpPassword = jumpPassword
        self.replacesExisting = replacesExisting
    }
}

/// The result of planning an import: what to create against the existing
/// store, plus what the user decided about every duplicate. Pure data —
/// applying it is the caller's job.
public struct SessionImportPlan: Equatable, Sendable {
    public var groupsToCreate: [StoredGroup]
    public var sessionsToImport: [PlannedSession]
    /// Duplicates the user chose to skip. Still the whole `ExportedSession`
    /// (not just a name) so `applyImport`'s count and the M9a result alert
    /// keep working unchanged.
    public var skipped: [ExportedSession]
    /// Final (trimmed) names of the sessions that overwrote an existing
    /// record, and of the ones that came in under a new name — reported to
    /// the user, so they must be the names actually stored.
    public var replaced: [String]
    public var renamed: [String]
    /// True when the user cancelled the run; every other array is then empty
    /// and the caller must apply nothing at all.
    public var cancelled: Bool

    public init(
        groupsToCreate: [StoredGroup] = [], sessionsToImport: [PlannedSession] = [],
        skipped: [ExportedSession] = [], replaced: [String] = [], renamed: [String] = [],
        cancelled: Bool = false
    ) {
        self.groupsToCreate = groupsToCreate
        self.sessionsToImport = sessionsToImport
        self.skipped = skipped
        self.replaced = replaced
        self.renamed = renamed
        self.cancelled = cancelled
    }
}

/// Plans an additive import from a decoded `SessionExportPayload` against
/// the current store contents (spec M9a §2.2/§2.3), resolving duplicates
/// through the shared `ImportConflictArbiter` (M19) — the same arbiter the
/// login-set importer uses, so both flows read as siblings. Pure aside from
/// that one `await`: no store, no keychain — every branch is unit testable.
///
/// Duplicates used to be skipped silently; since M19 the user is asked.
/// An arbiter of `{ _ in (.skip, true) }` reproduces the old behaviour
/// exactly.
///
/// Items are walked SEQUENTIALLY (a plain `for` loop, no `TaskGroup`/`async
/// let`), so at most one `arbiter.resolve` call is ever in flight from this
/// planner. `ImportConflictArbiter.resolve` documents a residual: under
/// genuinely CONCURRENT calls its decider can be invoked more than once
/// before a rule exists (actor isolation does not span the `await
/// decider(...)` suspension). Walking sequentially means this planner never
/// creates that overlap, so the residual never applies here.
public enum SessionImportPlanner {
    /// Stable identifier passed as `ImportConflict.kindLabel` — NOT display
    /// text (Core has no UI language). The app maps this to its localized
    /// string.
    public static let kindLabel = "session"

    public static func plan(
        existing: [StoredSession], existingGroups: [StoredGroup],
        incoming: SessionExportPayload, arbiter: ImportConflictArbiter
    ) async -> SessionImportPlan {
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

        // Then sessions, in file order. The duplicate key is per BACKEND (see
        // `duplicateKey`): the endpoint triple for `.ssh` as since M9a, and
        // the connection's own identifying fields for `.s3`/`.webdav`, which
        // have no meaningful triple. Checked against both the existing store
        // and the keys already accepted earlier in this same file. Only the
        // HANDLING changed in M19: a duplicate is put to the arbiter instead
        // of being dropped.
        var seenKeys = Set(existing.map { duplicateKey(for: $0) })
        // Names are NOT the duplicate key and the store never enforces them
        // unique, but a rename still has to land on a name nothing else uses.
        // Seeded with the store's names and grown with every name this run
        // commits to (imported-unchanged, replaced, or renamed) — otherwise
        // two renames from the same file could collide with each other.
        var takenNames = Set(existing.map { normalizedName($0.name) })
        // An existing session may be the target of a `replace` at most once
        // per run: `SessionStore.upsert` matches on id, so two planned
        // sessions carrying the same id would end up as one, with the later
        // one silently overwriting the earlier. Tracked here so a second
        // collision against an already-claimed record falls through to the
        // fresh-id-and-unique-name fallback instead.
        var replacedExistingIDs: Set<UUID> = []
        var sessionsToImport: [PlannedSession] = []
        var skipped: [ExportedSession] = []
        var replaced: [String] = []
        var renamed: [String] = []

        for fileSession in incoming.sessions {
            let key = duplicateKey(for: fileSession)
            // The connection form trims on save, so import must not be the
            // one path that stores a name with surrounding whitespace — and
            // the summary arrays below report exactly what was stored.
            let trimmedName = fileSession.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedGroupID = fileSession.groupID.flatMap { groupIDMap[$0] }

            guard seenKeys.contains(key) else {
                seenKeys.insert(key)
                takenNames.insert(normalizedName(trimmedName))
                sessionsToImport.append(makePlanned(
                    from: fileSession, id: UUID(), name: trimmedName, groupID: resolvedGroupID))
                continue
            }

            guard let resolution = await arbiter.resolve(
                ImportConflict(itemName: trimmedName, kindLabel: kindLabel)
            ) else {
                // Cancellation applies nothing at all — not the items already
                // accepted earlier in this run, and therefore no groups
                // either (M9a Finding 2 holds on this path by construction).
                return SessionImportPlan(cancelled: true)
            }

            switch resolution {
            case .skip:
                skipped.append(fileSession)

            case .replace:
                if let match = existing.first(where: {
                    duplicateKey(for: $0) == key && !replacedExistingIDs.contains($0.id)
                }) {
                    replacedExistingIDs.insert(match.id)
                    takenNames.insert(normalizedName(trimmedName))
                    sessionsToImport.append(makePlanned(
                        from: fileSession, id: match.id, name: trimmedName, groupID: resolvedGroupID,
                        replacesExisting: true))
                    replaced.append(trimmedName)
                } else {
                    // Either the collision was against a triple first seen in
                    // THIS file (nothing on record to replace), or every
                    // existing session under that triple has already been
                    // claimed by an earlier replace in this same run. Fall
                    // back to a fresh id under a unique name rather than
                    // replacing a session that does not exist, or
                    // double-binding two incoming sessions to one id.
                    let name = uniqueName(for: trimmedName, avoiding: takenNames)
                    takenNames.insert(normalizedName(name))
                    sessionsToImport.append(makePlanned(
                        from: fileSession, id: UUID(), name: name, groupID: resolvedGroupID))
                    // `uniqueName` returns the name unchanged when nothing
                    // else uses it (the collision key here is the endpoint
                    // triple, not the name) — only report an actual rename.
                    if name != trimmedName { renamed.append(name) }
                }

            case .rename:
                let name = uniqueName(for: trimmedName, avoiding: takenNames)
                takenNames.insert(normalizedName(name))
                sessionsToImport.append(makePlanned(
                    from: fileSession, id: UUID(), name: name, groupID: resolvedGroupID))
                if name != trimmedName { renamed.append(name) }
            }
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
            groupsToCreate: groupsToCreate, sessionsToImport: sessionsToImport,
            skipped: skipped, replaced: replaced, renamed: renamed, cancelled: false)
    }

    /// Builds the planned session for one file entry under an already-decided
    /// id and name, so the unchanged, replaced and renamed paths cannot drift
    /// apart in how they map the file's fields.
    private static func makePlanned(
        from fileSession: ExportedSession, id: UUID, name: String, groupID: UUID?,
        replacesExisting: Bool = false
    ) -> PlannedSession {
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
        // WebDAV (M21): the same shape as the `s3` block above -- the
        // persisted config is only built when the file actually carries the
        // columns, so a `.webdav` entry from a pre-M21-export build (which had
        // none) still imports, just without a server. `useNextcloudPath`
        // defaults to false the way `s3UsePathStyle` does.
        var webdav: StoredWebDAVConfig?
        if kind == .webdav, let baseURL = fileSession.webdavBaseURL,
           let webdavUsername = fileSession.webdavUsername {
            webdav = StoredWebDAVConfig(
                baseURL: baseURL, username: webdavUsername,
                useNextcloudPath: fileSession.webdavUseNextcloudPath ?? false)
        }
        // SSH's block only for an `.ssh` session (M23/T8). The export format
        // still carries host/port/username as flat top-level columns —
        // including the literal `"unused"` a pre-M23 export wrote for an S3 or
        // WebDAV session — so building the block unconditionally would import
        // exactly the placeholder this milestone removed.
        var ssh: StoredSSHConfig?
        if kind == .ssh {
            ssh = StoredSSHConfig(
                host: fileSession.host, port: fileSession.port,
                username: fileSession.username, authKind: fileSession.authKind,
                keyPath: fileSession.keyPath, jump: jump)
        }
        let session = StoredSession(
            id: id,
            name: name,
            groupID: groupID,
            kind: kind,
            ssh: ssh,
            s3: s3,
            webdav: webdav)
        // The kind's single secret always travels in the same
        // `password` slot -- for `.ssh` this is the SSH password, for
        // `.webdav` the WebDAV password, and for `.s3` the secret access
        // key (all stored in the Keychain under the session's own id at
        // apply time). Only `.s3` needs a column of its own, because its
        // export writes `password` as nil.
        let secret = kind == .s3 ? fileSession.s3SecretAccessKey : fileSession.password
        return PlannedSession(
            session: session, password: secret,
            // Keyed on the jump that actually landed on the session, not the
            // one parsed out of the file: a non-SSH session keeps no jump
            // since M23/T8, and a password for a hop nobody dials is an
            // orphan Keychain slot.
            jumpPassword: ssh?.jump != nil ? fileSession.jumpPassword : nil,
            replacesExisting: replacesExisting)
    }

    /// What makes two sessions "the same connection" for import purposes,
    /// per backend.
    ///
    /// `.ssh` keeps the original endpoint triple, byte for byte — SSH import
    /// semantics must not shift.
    ///
    /// `.s3` and `.webdav` need their own key because they do not HAVE an
    /// endpoint triple: a session written before M23 stored the literal
    /// placeholder `host: "unused", port: 22, username: "unused"` there, and
    /// one written since simply leaves host and user name empty — either way
    /// the triple carries no identity. Keyed on it,
    /// every non-SSH session in the world was one and the same duplicate —
    /// three distinct WebDAV servers in one file collapsed to one import plus
    /// two silent drops, and an incoming WebDAV session could `Replace` an
    /// unrelated stored S3 one, taking over its id and destroying it.
    ///
    /// The keys are prefixed with the kind, so a `.s3` and a `.webdav` session
    /// can never share a key even if their remaining parts were to match.
    /// Values are taken verbatim (no case folding): unlike a host name, a URL
    /// path and a bucket name are case-sensitive, and the access key ID is an
    /// opaque credential.
    ///
    /// Known limit, unchanged from before this fix: a `.macscp` written by a
    /// build whose export did not yet carry the `webdav*`/`s3*` columns has
    /// nothing to key on, so its non-SSH entries all fall back to a constant
    /// (`"webdav||"`) and still self-collide within that file. That is exactly
    /// today's behaviour for those old files, not a regression, and it cannot
    /// be fixed on the import side — the data simply is not in the file.
    private static func duplicateKey(for session: StoredSession) -> String {
        duplicateKey(
            kind: session.kind, host: session.host, port: session.port,
            username: session.username,
            s3Endpoint: session.s3?.endpoint, s3Bucket: session.s3?.bucket,
            s3AccessKeyID: session.s3?.accessKeyID,
            webdavBaseURL: session.webdav?.baseURL, webdavUsername: session.webdav?.username)
    }

    /// The file-side counterpart of `duplicateKey(for: StoredSession)`. Both
    /// sides must derive the SAME key from the same connection, so they share
    /// one implementation. A legacy payload without `kind` is `.ssh`, exactly
    /// as `makePlanned` maps it.
    private static func duplicateKey(for fileSession: ExportedSession) -> String {
        duplicateKey(
            kind: fileSession.kind ?? .ssh, host: fileSession.host, port: fileSession.port,
            username: fileSession.username,
            s3Endpoint: fileSession.s3Endpoint, s3Bucket: fileSession.s3Bucket,
            s3AccessKeyID: fileSession.s3AccessKeyID,
            webdavBaseURL: fileSession.webdavBaseURL, webdavUsername: fileSession.webdavUsername)
    }

    private static func duplicateKey(
        kind: ConnectionKind, host: String, port: Int, username: String,
        s3Endpoint: String?, s3Bucket: String?, s3AccessKeyID: String?,
        webdavBaseURL: String?, webdavUsername: String?
    ) -> String {
        switch kind {
        case .ssh:
            return "\(host.lowercased())|\(port)|\(username)"
        case .s3:
            return "s3|\(s3Endpoint ?? "")|\(s3Bucket ?? "")|\(s3AccessKeyID ?? "")"
        case .webdav:
            return "webdav|\(webdavBaseURL ?? "")|\(webdavUsername ?? "")"
        }
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Keeps `name` when nothing else uses it, otherwise appends " (2)",
    /// " (3)", … until it is free. `taken` already carries every name
    /// committed so far this run.
    ///
    /// Deliberately different from `LoginSetImportPlanner.uniqueName`, which
    /// always suffixes: there the collision key IS the name, so the base is
    /// taken by definition. Here the collision is on the endpoint triple, so
    /// an incoming duplicate whose name nothing else uses keeps it.
    private static func uniqueName(for name: String, avoiding taken: Set<String>) -> String {
        guard taken.contains(normalizedName(name)) else { return name }
        var suffix = 2
        var candidate = "\(name) (\(suffix))"
        while taken.contains(normalizedName(candidate)) {
            suffix += 1
            candidate = "\(name) (\(suffix))"
        }
        return candidate
    }
}
