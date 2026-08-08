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
        // ONE map doing the job `seenKeys: Set<String>` used to do alone: its
        // keys are membership (what `seenKeys.contains` used to answer), its
        // values are the display summary of whichever session — stored, or
        // the first incoming one accepted under a given key — established
        // that key. Merged into one collection, rather than a `Set` plus a
        // parallel `[String: String]`, so a `.sameConnection` conflict's
        // `existing` string (M23/P3 T3) comes out of the SAME lookup that
        // proves the collision, and cannot be missing by construction: there
        // is no second collection to fall out of sync with the first, so no
        // fallback value is needed below. Ties within `existing` itself (two
        // stored sessions that already share a connection identity) keep the
        // first one encountered; which of two identical connections gets
        // named is not a decision this planner needs to make well, only
        // reproducibly.
        var summaryByKey: [String: String] = Dictionary(
            existing.map { (duplicateKey(for: $0), displaySummary(for: $0)) },
            uniquingKeysWith: { first, _ in first })
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

            guard let collidingSummary = summaryByKey[key] else {
                summaryByKey[key] = displaySummary(for: fileSession)
                takenNames.insert(normalizedName(trimmedName))
                sessionsToImport.append(makePlanned(
                    from: fileSession, id: UUID(), name: trimmedName, groupID: resolvedGroupID))
                continue
            }

            guard let resolution = await arbiter.resolve(
                // A session collides on the CONNECTION, not the name — unlike
                // a login set. `collidingSummary` — bound by the `guard let`
                // above, the same lookup that proves `key` already collides —
                // names whatever established it: a stored session, or an
                // earlier session from this same file. So the conflict names
                // what the incoming item collides with, never the incoming
                // item's own name (M23/P3 T3) — but that is not always a
                // stored connection "about to be replaced": choosing Replace
                // only overwrites a genuine stored record; when
                // `collidingSummary` names an earlier file entry instead,
                // Replace falls through to a fresh id under a unique name at
                // :206, replacing nothing of the user's. No fallback value is
                // possible here, let alone needed: this branch only runs when
                // the lookup above already succeeded.
                ImportConflict(
                    itemName: trimmedName, kindLabel: kindLabel,
                    reason: .sameConnection(existing: collidingSummary))
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
        // legacy-safe default as `StoredSession.kind` itself.
        let kind = fileSession.kind ?? .ssh
        // The backend's own write adapter builds its block (M23/P3) — the
        // same one the connection form saves through, so import and save
        // cannot drift apart, and a fourth backend needs nothing here.
        //
        // An EMPTY bag means the file carried no block for this kind, which
        // is what `sessionValues` writes for an `.s3`/`.webdav` session
        // whose block is nil, and what a pre-M21 export left for a WebDAV
        // entry. Applying it would invent a server the file never named, so
        // the session keeps no block at all — as before the bag.
        //
        // The guard earns its place ONLY for `.s3`/`.webdav`, where it
        // preserves v1's all-columns-required gate. Removing it fails exactly
        // two tests, both WebDAV-empty-block ones
        // (`webdavFileSessionWithoutColumnsKeepsKindAndHasNoConfig`,
        // `preFixExportFileStillImports`) — measured by mutation, not assumed.
        // It does NOT hold up the bag round trip, which stays green without
        // it, and its `.ssh` arm is unreachable through any real file: v1's
        // `host` column was non-optional, so every v1 `.ssh` entry yields five
        // keys, and a stored `.ssh` session with `ssh == nil` never reaches an
        // export at all -- `SessionStore.load()` drops it (M26,
        // `SessionStore.swift:93`) before `sessionValues`, or anything else
        // downstream, gets a look. Only a hand-built `ExportedSession` or a
        // hand-edited `"fields": {}` reaches it.
        var session = StoredSession(id: id, name: name, groupID: groupID, kind: kind)
        if !fileSession.fields.isEmpty {
            var values = FieldValues()
            for (key, value) in fileSession.fields { values.setRaw(key, to: value) }
            BackendDescriptor.descriptor(for: kind).apply(values, &session)
        }
        // The jump is attached afterwards: it is a second login with its own
        // Keychain slot, which is why `apply` does not own it. It lands only
        // on an `.ssh` session (M23/T8) — a hop nobody can dial is dead
        // weight, and its password would be an orphan Keychain slot.
        if kind == .ssh, let jump {
            var ssh = session.ssh ?? StoredSSHConfig(host: "", username: "")
            ssh.jump = jump
            session.ssh = ssh
        }
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
            jumpPassword: session.ssh?.jump != nil ? fileSession.jumpPassword : nil,
            replacesExisting: replacesExisting)
    }

    /// What makes two sessions "the same connection" for import purposes.
    ///
    /// WHICH fields answer that is DECLARED by each backend since M23/P3
    /// (`ConnectionField.identity`, collected by
    /// `BackendDescriptor.identifyingFields`), not decided here. This function
    /// used to hold a `switch kind` of its own — the last compile-forcing
    /// `ConnectionKind` site outside the backend registry — and every rule
    /// below is now carried by a declaration next to the field it is about,
    /// rather than by an arm somebody has to remember to add.
    ///
    /// The rules the old switch recorded, and where each one now lives:
    ///
    /// `.ssh` keeps the original endpoint triple, byte for byte — SSH import
    /// semantics must not shift. `SSHFieldSchema` marks exactly `host`, `port`
    /// and `username` identifying, and `host` alone as `.caseInsensitive`,
    /// which is the one case fold this key has ever performed (DNS is
    /// case-insensitive; a POSIX user name is not).
    ///
    /// `.s3` and `.webdav` need their own identifying fields because they do
    /// not HAVE an endpoint triple: a session written before M23 stored the
    /// literal placeholder `host: "unused", port: 22, username: "unused"`
    /// there, and one written since simply leaves host and user name empty —
    /// either way the triple carries no identity. Keyed on it, every non-SSH
    /// session in the world was one and the same duplicate: three distinct
    /// WebDAV servers in one file collapsed to one import plus two silent
    /// drops, and an incoming WebDAV session could `Replace` an unrelated
    /// stored S3 one, taking over its id and destroying it.
    ///
    /// Keys are prefixed with the kind, so a `.s3` and a `.webdav` session can
    /// never share one even if their remaining parts were to match.
    ///
    /// Values are taken verbatim, with `host` the single declared exception:
    /// a URL path and a bucket name are case-sensitive, and an access key ID
    /// is an opaque credential. Identity is a declared SUBSET of the fields,
    /// never all of them — S3's `region` and `usePathStyle` are excluded on
    /// purpose, because two sessions differing only in those are one
    /// connection reached two ways.
    ///
    /// No secret ever enters a key; `BackendDescriptorTests` fails the build
    /// for a backend that marks one identifying, or that marks none at all.
    ///
    /// Known limit, unchanged since before the M23 fix: a `.macscp` written by
    /// a build whose export did not yet carry the `webdav*`/`s3*` columns has
    /// nothing to key on, so its non-SSH entries all fall back to the same
    /// constant (`"webdav||"`) and still self-collide within that file. That is
    /// exactly today's behaviour for those old files, not a regression, and it
    /// cannot be fixed on the import side — the data simply is not in the file.
    private static func duplicateKey(kind: ConnectionKind, values: FieldValues) -> String {
        let descriptor = BackendDescriptor.descriptor(for: kind)
        let namespace = descriptor.fieldNamespace
        var parts: [String] = [kind.rawValue]
        for field in descriptor.identifyingFields {
            let raw: String = values.raw["\(namespace).\(field.id)"] ?? ""
            let identity: FieldIdentity = field.identity ?? .verbatim
            parts.append(identity.normalized(raw))
        }
        return parts.joined(separator: "|")
    }

    private static func duplicateKey(for session: StoredSession) -> String {
        let kind = session.kind
        let values = BackendDescriptor.descriptor(for: kind).sessionValues(session)
        return duplicateKey(kind: kind, values: values)
    }

    /// The connection identity shown to the user on a `.sameConnection`
    /// conflict — the SAME one-line summary the sidebar and the audit trail
    /// already use (`BackendDescriptor.displaySummary`), so this planner
    /// invents no format of its own.
    private static func displaySummary(for session: StoredSession) -> String {
        let descriptor = BackendDescriptor.descriptor(for: session.kind)
        return descriptor.displaySummary(descriptor.sessionValues(session))
    }

    /// The file-side counterpart: the same summary computed from an incoming
    /// entry's own field bag, for the case where what a later duplicate in
    /// this same file collided with is that earlier entry, not anything on
    /// record. A legacy payload without `kind` is `.ssh`, exactly as
    /// `makePlanned` maps it.
    private static func displaySummary(for fileSession: ExportedSession) -> String {
        let kind = fileSession.kind ?? .ssh
        let descriptor = BackendDescriptor.descriptor(for: kind)
        return descriptor.displaySummary(FieldValues(raw: fileSession.fields))
    }

    /// The file-side counterpart of `duplicateKey(for: StoredSession)`. Both
    /// sides must derive the SAME key from the same connection, so they share
    /// one implementation — and, since M23/P3, one field vocabulary too: the
    /// store side arrives through `sessionValues`, the file side through the
    /// bag the export wrote (a v1 file's columns having been folded into that
    /// same bag by `decode`). A legacy payload without `kind` is `.ssh`,
    /// exactly as `makePlanned` maps it.
    ///
    /// One deliberate difference from the pre-M23/P3 key: the port is no
    /// longer re-parsed through `Int` on the way in, so a `.ssh` entry whose
    /// bag carries NO port at all keys on `""` rather than on the default 22.
    /// No exporter and no v1 upgrade produces such an entry — both always
    /// write a canonical port string — and an entry that carries no host
    /// either is precisely the "nothing to key on" case documented above.
    private static func duplicateKey(for fileSession: ExportedSession) -> String {
        duplicateKey(kind: fileSession.kind ?? .ssh, values: FieldValues(raw: fileSession.fields))
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
