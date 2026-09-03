import Foundation

/// What the user decided in the import sheet, before a single row is
/// translated (design §0/§4).
///
/// `groupID` and `createGroupNamed` are alternatives, not a pair: a group
/// already on record is named by its id, a group that does not exist yet by
/// its name. When both are set the id wins — the picker had an answer, so
/// nothing needs creating.
public struct ImportSwitches: Sendable, Equatable {
    /// Read passwords and S3 secret keys from the source's keychain items.
    /// The planner NEVER sees a secret: this only travels through to
    /// `SessionExportPayload.includesSecrets`, and the App's applier
    /// (`CyberduckSecretReader`, Task 4) fills the values in afterwards.
    public var takeSecrets: Bool
    /// Turn the source's labels into `StoredSession.tags`. Off, a bookmark's
    /// labels take no part in the preview at all — not in the change list,
    /// not in the payload.
    public var takeLabelsAsTags: Bool
    /// An EXISTING group, chosen in the sheet's picker.
    ///
    /// Resolved against the group catalogue `payload(for:sessions:groups:
    /// switches:)` is handed, which then carries that group into the payload's
    /// own `groups` — `SessionImportPlanner` drops a `groupID` the payload does
    /// not name. An id the catalogue no longer knows leaves the sessions
    /// ungrouped rather than pointing at nothing.
    public var groupID: UUID?
    /// A group to create for this import when `groupID` is nil. Becomes one
    /// `ExportedGroup` in the payload, which `SessionImportPlanner` either
    /// matches to an existing group of that name or creates.
    public var createGroupNamed: String?

    public init(
        takeSecrets: Bool = false, takeLabelsAsTags: Bool = false,
        groupID: UUID? = nil, createGroupNamed: String? = nil
    ) {
        self.takeSecrets = takeSecrets
        self.takeLabelsAsTags = takeLabelsAsTags
        self.groupID = groupID
        self.createGroupNamed = createGroupNamed
    }
}

/// One field a re-import would overwrite, as shown in a `.knownChanged` row.
///
/// `field` is a CATALOG KEY, not display text — Core has no UI language, the
/// same rule `SessionImportPlanner.kindLabel` follows. The App maps it (Task
/// 5); `ImportPreviewPlanner.FieldKey` lists every key this planner composes.
///
/// `old` and `new` are the raw values, so the sheet can render
/// "port 22 → 2222" without asking anything else. No secret can appear here:
/// an `ExternalBookmark` carries none.
public struct FieldChange: Sendable, Equatable {
    public let field: String
    public let old: String
    public let new: String

    public init(field: String, old: String, new: String) {
        self.field = field
        self.old = old
        self.new = new
    }
}

/// What the preview says about one bookmark.
///
/// The two "known" cases carry the STORED session's id — the record a
/// re-import updates, and the handle `payload(for:)` needs to copy everything
/// the source does not know.
public enum PreviewStatus: Sendable, Equatable {
    /// Nothing on record matches this bookmark.
    case new
    /// A stored session matches and every field the source knows agrees.
    case knownUnchanged(UUID)
    /// A stored session matches and these fields differ.
    case knownChanged(UUID, [FieldChange])
    /// The source's own protocol name for a protocol macSCP has no backend
    /// for (`"ftp"`, `"davs"`, …). Greyed and counted, never imported.
    case unsupported(String)
    /// The bookmark file could not be parsed at all; carries the file name
    /// and the reason (`ExternalBookmark.unreadable`).
    case unreadable(String)

    /// Whether the user may tick this row at all. False for exactly the two
    /// cases nothing can import, which is also why `payload(for:)` refuses
    /// them a second time: a row's `selected` is a `var`, so the check that
    /// runs at build time cannot rely on the check that ran at preview time.
    public var isSelectable: Bool {
        switch self {
        case .new, .knownUnchanged, .knownChanged: return true
        case .unsupported, .unreadable: return false
        }
    }

    /// The stored record this row is about, when there is one.
    public var storedSessionID: UUID? {
        switch self {
        case .knownUnchanged(let id), .knownChanged(let id, _): return id
        case .new, .unsupported, .unreadable: return nil
        }
    }

    /// What a freshly built row starts at (design §4): new and changed rows
    /// are ticked, an unchanged one is not (re-importing it would do
    /// nothing), and the two unimportable ones cannot be ticked at all.
    fileprivate var startsSelected: Bool {
        switch self {
        case .new, .knownChanged: return true
        case .knownUnchanged, .unsupported, .unreadable: return false
        }
    }
}

/// One line in the preview table. `selected` is the only mutable part — the
/// sheet's checkbox writes it, and `payload(for:)` reads it back.
public struct PreviewRow: Sendable, Equatable, Identifiable {
    /// The bookmark's own id, so the table's identity survives a re-read of
    /// the folder.
    public let id: String
    public let bookmark: ExternalBookmark
    public let status: PreviewStatus
    public var selected: Bool

    public init(id: String, bookmark: ExternalBookmark, status: PreviewStatus, selected: Bool) {
        self.id = id
        self.bookmark = bookmark
        self.status = status
        self.selected = selected
    }

    public var isSelectable: Bool { status.isSelectable }
}

/// Bookmarks × the store × the user's switches → preview rows, and the
/// selected rows → a `SessionExportPayload` for the existing import path
/// (design §2).
///
/// Pure and synchronous throughout: no store, no file system, no keychain,
/// and no secret ever passes through it.
public enum ImportPreviewPlanner {

    /// The catalog keys `FieldChange.field` carries. Core composes them; the
    /// App resolves them (Task 5).
    ///
    /// This is the SOURCE's vocabulary, not macSCP's: a Cyberduck `Hostname`
    /// is `host` on an sftp bookmark and `endpoint` on an s3 one, and
    /// `Username` is the S3 access key without changing the row's label. Seven
    /// of the nine are spelled by the schema field they compare, so a
    /// renamed field takes its key with it.
    public enum FieldKey {
        private static let prefix = "import.field."
        public static let host = prefix + SSHField.host.rawValue
        public static let port = prefix + SSHField.port.rawValue
        public static let username = prefix + SSHField.username.rawValue
        public static let keyPath = prefix + SSHField.keyPath.rawValue
        public static let authKind = prefix + SSHField.authKind.rawValue
        public static let endpoint = prefix + S3Field.endpoint.rawValue
        public static let bucket = prefix + S3Field.bucket.rawValue
        /// The session name (`Nickname`) and the labels have no schema field
        /// to be read off: both are properties of the saved session, not of
        /// the protocol it speaks.
        public static let name = prefix + "name"
        public static let labels = prefix + "labels"
    }

    /// One bookmark, judged: either a kind this planner translates, or the
    /// status the row carries instead. Refusing with the status — rather than
    /// with `nil` and a second look at the bookmark — is what keeps the
    /// unreadable-before-protocol rule in `translation(of:)` alone.
    private enum BookmarkTranslation {
        case importable(BookmarkKind)
        case refused(PreviewStatus)
    }

    /// The two protocols this planner can translate. A closed two-case enum
    /// rather than `ConnectionKind`, so every `switch` below is exhaustive
    /// over what actually arrives — a `.webdav` arm here would be a branch no
    /// bookmark can reach, doing nothing, forever.
    private enum BookmarkKind {
        case ssh
        case s3

        var connectionKind: ConnectionKind {
            switch self {
            case .ssh: return .ssh
            case .s3: return .s3
            }
        }
    }

    /// Cyberduck's own spelling of Amazon's endpoint — the one value in §3's
    /// translation table that is a foreign constant rather than one of ours.
    private static let awsHostname = "s3.amazonaws.com"

    /// The endpoint an AWS bookmark becomes: S3's own AWS preset, so the
    /// imported session is byte for byte what picking "Amazon S3" in the
    /// connection form produces. Chosen by the preset's IDENTITY, not by
    /// position — a preset inserted ahead of it would otherwise point every
    /// imported Amazon bookmark somewhere else.
    private static let awsPresetID = "aws"
    private static let awsEndpoint: String =
        S3FieldSchema.connection.presets
            .first { $0.id == awsPresetID }?
            .values[S3Field.endpoint.rawValue] ?? "https://\(awsHostname)"

    /// Hetzner's own hosts, keyed by the host itself, to the preset endpoint
    /// that names it — the same identity-not-position rule `awsEndpoint`
    /// follows above, extended to every `hetzner`/`hetzner-<location>`
    /// preset in `S3FieldSchema.connection.presets` (Task 3, per-region
    /// presets). A bookmark naming `nbg1.your-objectstorage.com` becomes the
    /// `hetzner-nbg1` preset's OWN endpoint string, so an import cannot drift
    /// from what picking that preset in the connection form produces even if
    /// a preset's endpoint spelling ever changed.
    ///
    /// Built from the presets rather than a literal host list, so a fourth
    /// location added to the schema is recognised here without a second edit
    /// — the hazard `S3FieldSchemaTests.everyHetznerPresetParsesToA
    /// YourObjectstorageComHostWithPathStyle` guards from the other side.
    private static let hetznerEndpointsByHost: [String: String] = {
        var map: [String: String] = [:]
        for preset in S3FieldSchema.connection.presets
        where preset.id == "hetzner" || preset.id.hasPrefix("hetzner-") {
            guard let endpoint = preset.values[S3Field.endpoint.rawValue],
                let host = S3FieldSchema.endpointComponents(endpoint)?.host
            else { continue }
            map[host.lowercased()] = endpoint
        }
        return map
    }()

    // MARK: - The preview

    public static func preview(
        _ bookmarks: [ExternalBookmark], against sessions: [StoredSession],
        switches: ImportSwitches
    ) -> [PreviewRow] {
        bookmarks.map { bookmark in
            let status = status(for: bookmark, against: sessions, switches: switches)
            return PreviewRow(
                id: bookmark.id, bookmark: bookmark, status: status,
                selected: status.startsSelected)
        }
    }

    private static func status(
        for bookmark: ExternalBookmark, against sessions: [StoredSession],
        switches: ImportSwitches
    ) -> PreviewStatus {
        switch translation(of: bookmark) {
        case .refused(let status):
            return status
        case .importable(let kind):
            guard let match = match(bookmark, kind: kind, in: sessions) else { return .new }
            let changes = changes(from: match, to: bookmark, kind: kind, switches: switches)
            return changes.isEmpty
                ? .knownUnchanged(match.id)
                : .knownChanged(match.id, changes)
        }
    }

    /// The stored session this bookmark is about, in the order §2 fixes.
    ///
    /// Provenance first: a session macSCP imported from this very bookmark is
    /// the same session even after the user moved it to another host, and
    /// that is exactly the case a connection key cannot see.
    ///
    /// Then the connection key — `SessionImportPlanner`'s own, called rather
    /// than copied, so "known" here and "duplicate" there can never disagree
    /// about what one connection is. It carries the kind, so a bookmark can
    /// only ever match a session of its own kind. Names are never compared.
    ///
    /// BOTH branches require the kind, and the first one has to say so itself:
    /// a bookmark keeps its UUID when the user changes its protocol in the
    /// source, so provenance alone would match an sftp-imported record to a
    /// bookmark that is now s3. That match updates the record across kinds,
    /// and an entry carrying no password makes the planner keep the existing
    /// secret — the SSH password stays in the id-keyed slot the S3 backend
    /// reads as its secret access key (and the mirror case sends a secret
    /// access key to an SSH server). A changed protocol therefore matches
    /// nothing here, the bookmark is `.new`, and the old record stays.
    private static func match(
        _ bookmark: ExternalBookmark, kind: BookmarkKind, in sessions: [StoredSession]
    ) -> StoredSession? {
        if let byProvenance = sessions.first(where: {
            $0.kind == kind.connectionKind
                && $0.importSource == bookmark.source && $0.importID == bookmark.id
        }) {
            return byProvenance
        }
        let key = SessionImportPlanner.duplicateKey(
            kind: kind.connectionKind, values: values(of: bookmark, kind: kind))
        return sessions.first { SessionImportPlanner.duplicateKey(for: $0) == key }
    }

    /// Every field the source knows that differs from the record, in the
    /// order the sheet reads them.
    ///
    /// Compared RAW, not folded: a host that differs only in case is matched
    /// (DNS folds it) and still listed, because importing would rewrite the
    /// stored spelling — the row says what would change, not what would
    /// become a different machine.
    private static func changes(
        from stored: StoredSession, to bookmark: ExternalBookmark, kind: BookmarkKind,
        switches: ImportSwitches
    ) -> [FieldChange] {
        // The stored side through the backend's own adapter: a session whose
        // block is missing yields the empty bag, so every field reads as
        // changed rather than as silently equal. The kind always agrees —
        // `match` requires it on both of its branches.
        let old = BackendDescriptor.descriptor(for: kind.connectionKind).sessionValues(stored)
        // The values an UPDATE would actually write, not the bookmark's own:
        // the two differ exactly where the source says nothing (see
        // `updateValues(of:kind:over:)`), and a row that listed a field the
        // import then leaves alone would be reporting a change nobody makes.
        let new = updateValues(of: bookmark, kind: kind, over: old)
        var result: [FieldChange] = []
        func compare(_ field: String, _ oldValue: String, _ newValue: String) {
            guard oldValue != newValue else { return }
            result.append(FieldChange(field: field, old: oldValue, new: newValue))
        }

        switch kind {
        case .ssh:
            compare(FieldKey.host, old[SSHField.host], new[SSHField.host])
            compare(FieldKey.port, old[SSHField.port], new[SSHField.port])
            compare(FieldKey.username, old[SSHField.username], new[SSHField.username])
            compare(FieldKey.keyPath, old[SSHField.keyPath], new[SSHField.keyPath])
            // Listed, because an update CAN move it — a bookmark that gained
            // a key file switches the session to private-key auth, and a row
            // that showed only "key path: → /keys/id_ed25519" would leave the
            // user to infer the rest.
            compare(FieldKey.authKind, old[SSHField.authKind], new[SSHField.authKind])
        case .s3:
            compare(FieldKey.endpoint, old[S3Field.endpoint], new[S3Field.endpoint])
            compare(FieldKey.username, old[S3Field.accessKeyID], new[S3Field.accessKeyID])
            compare(FieldKey.bucket, old[S3Field.bucket], new[S3Field.bucket])
        }
        // The nickname is a field the source knows, and an update applies it
        // (design §0 item 3), so a bookmark renamed in the source renames the
        // session — reported here first.
        compare(FieldKey.name, stored.name, displayName(of: bookmark))
        if switches.takeLabelsAsTags {
            compare(FieldKey.labels,
                    stored.tags.joined(separator: ", "),
                    tags(of: bookmark).joined(separator: ", "))
        }
        return result
    }

    // MARK: - The payload

    /// The selected rows as a `SessionExportPayload`, for the existing
    /// `SessionImportPlanner` → `applyImport` path.
    ///
    /// A `.new` row becomes a fresh `ExportedSession`. A `.knownChanged` row
    /// becomes one carrying the stored record's id in `replaces`, which makes
    /// `SessionImportPlanner` overwrite that record in place — same id, no
    /// arbiter question about the connection, because the entry IS that
    /// record.
    ///
    /// A ticked `.knownUnchanged` row becomes a provenance-only update — the
    /// record unchanged but stamped, so a later run recognises it after its
    /// connection moves (see `provenanceOnlyUpdate`). Such a row starts
    /// unticked, so this only happens on purpose.
    ///
    /// An update overwrites everything the source knows, the session's NAME
    /// included (design §0 item 3, the maintainer's decision): a bookmark
    /// renamed in Cyberduck renames the session here. What the source does not
    /// know is copied off the record instead — its group, its rank, its pane
    /// visibility, its tags (unless the labels switch replaces them) and every
    /// backend field outside §3's table, such as an S3 region. Those four
    /// session properties — group, rank, pane visibility, tags — are the whole
    /// list: `StoredSession` carries no notes and no colour, so there is
    /// nothing else to copy.
    ///
    /// `groups` is the store's group catalogue, and it is needed rather than
    /// convenient: `SessionImportPlanner` resolves `ExportedSession.groupID`
    /// against the payload's OWN `groups` and drops a reference the payload
    /// does not carry. So every group the rows reference — the one the picker
    /// chose, the one an update copied off its record — is emitted here, under
    /// its own id and name; the planner matches it to the existing group of
    /// that name. A group the catalogue does not know is not emitted, and the
    /// session then names no group at all rather than one that resolves to
    /// nothing.
    ///
    /// Unsupported and unreadable rows are refused here as well as at preview
    /// time. That is not belt and braces: `PreviewRow.selected` is mutable,
    /// so a caller can tick any row it holds, and the status a row was built
    /// with is the only thing that says whether it may be imported.
    ///
    /// `importedAt` is ONE timestamp for the whole call, so a run of forty
    /// bookmarks is one import rather than forty.
    public static func payload(
        for rows: [PreviewRow], sessions: [StoredSession], groups: [StoredGroup],
        switches: ImportSwitches
    ) -> SessionExportPayload {
        let importedAt = Date()
        var exportedGroups: [ExportedGroup] = []
        var createdGroupID: UUID?
        if switches.groupID == nil,
           let name = switches.createGroupNamed?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            let group = ExportedGroup(id: UUID(), name: name)
            exportedGroups.append(group)
            createdGroupID = group.id
        }
        // The chosen group is resolved against the catalogue exactly like a
        // copied one, so an id the store no longer knows names nothing.
        let chosenGroupID = switches.groupID.flatMap { id in
            groups.first { $0.id == id }?.id
        }

        var exported: [ExportedSession] = []
        for row in rows where row.selected {
            guard case .importable(let kind) = translation(of: row.bookmark) else { continue }
            switch row.status {
            case .new:
                exported.append(newSession(
                    from: row.bookmark, kind: kind,
                    groupID: chosenGroupID ?? createdGroupID,
                    switches: switches, importedAt: importedAt))
            case .knownChanged(let storedID, _):
                guard let stored = sessions.first(where: { $0.id == storedID }) else { continue }
                exported.append(updatedSession(
                    from: row.bookmark, kind: kind, stored: stored,
                    switches: switches, importedAt: importedAt))
            case .knownUnchanged(let storedID):
                // Ticked on purpose (an unchanged row starts unticked): the
                // user is LINKING this record to the bookmark, which is the
                // only way a key-matched session ever gains provenance.
                guard let stored = sessions.first(where: { $0.id == storedID }) else { continue }
                exported.append(provenanceOnlyUpdate(
                    from: row.bookmark, kind: kind, stored: stored, importedAt: importedAt))
            case .unsupported, .unreadable:
                continue
            }
        }

        // Every group the sessions above actually reference, in catalogue
        // order. `parentID` is deliberately not carried: a referenced group is
        // matched to the existing one of that name, where its own nesting
        // already holds, and a parent this payload does not carry would be
        // repaired away anyway.
        let referenced = Set(exported.compactMap(\.groupID))
        for group in groups where referenced.contains(group.id)
            && !exportedGroups.contains(where: { $0.id == group.id }) {
            exportedGroups.append(
                ExportedGroup(id: group.id, name: group.name, position: group.position))
        }

        // `includesSecrets` describes what the payload is ALLOWED to carry,
        // not what it carries today: this planner never sees a secret, and
        // the App's applier fills the slots in before planning (Task 4/5).
        return SessionExportPayload(
            includesSecrets: switches.takeSecrets, groups: exportedGroups, sessions: exported)
    }

    private static func newSession(
        from bookmark: ExternalBookmark, kind: BookmarkKind, groupID: UUID?,
        switches: ImportSwitches, importedAt: Date
    ) -> ExportedSession {
        var fields = baseline(for: kind)
        fields.merge(values(of: bookmark, kind: kind))
        return ExportedSession(
            id: UUID(),
            name: displayName(of: bookmark),
            kind: kind.connectionKind,
            fields: fields.raw,
            groupID: groupID,
            tags: switches.takeLabelsAsTags ? tags(of: bookmark) : nil,
            importSource: bookmark.source,
            importID: bookmark.id,
            importedAt: importedAt)
    }

    /// A ticked `.knownUnchanged` row: the record exactly as it stands, plus
    /// provenance and the `replaces` handle that lands it back on its own id.
    ///
    /// Every field is read off the RECORD, none off the bookmark — "nothing
    /// else changed" is the whole content of this case, and the row is
    /// `.knownUnchanged` precisely because the two already agree on
    /// everything the change list compares. Reading the record is what makes
    /// that true of the fields it does NOT compare as well.
    ///
    /// Why it is worth a case of its own: `importSource`/`importID` are
    /// written nowhere else, so without this a session matched by CONNECTION
    /// KEY could never be stamped. The run after the user changes that
    /// server's port in the source would find no provenance, no key match
    /// either, call the bookmark `.new`, and create a second session — the
    /// exact case provenance matching exists to prevent.
    ///
    /// No secret and no `takeLabelsAsTags`: the planner sets
    /// `keepsExistingSecret` for an entry carrying no password, and labels
    /// that differed would have made the row `.knownChanged`.
    private static func provenanceOnlyUpdate(
        from bookmark: ExternalBookmark, kind: BookmarkKind, stored: StoredSession,
        importedAt: Date
    ) -> ExportedSession {
        var fields = baseline(for: kind)
        fields.merge(BackendDescriptor.descriptor(for: kind.connectionKind)
            .sessionValues(stored))
        return ExportedSession(
            id: stored.id,
            name: stored.name,
            kind: kind.connectionKind,
            fields: fields.raw,
            groupID: stored.groupID,
            paneVisibility: stored.paneVisibility,
            tags: stored.tags,
            position: stored.position,
            importSource: bookmark.source,
            importID: bookmark.id,
            importedAt: importedAt,
            replaces: stored.id)
    }

    private static func updatedSession(
        from bookmark: ExternalBookmark, kind: BookmarkKind, stored: StoredSession,
        switches: ImportSwitches, importedAt: Date
    ) -> ExportedSession {
        // Three layers, and the order is the rule: the backend's baseline
        // (so a field neither side carries is still valid — an S3 session
        // with a blank region is one the schema refuses), then the stored
        // record, then what the source knows. Only the third layer is what
        // an update overwrites.
        let old = BackendDescriptor.descriptor(for: kind.connectionKind).sessionValues(stored)
        var fields = baseline(for: kind)
        fields.merge(old)
        fields.merge(updateValues(of: bookmark, kind: kind, over: old))
        return ExportedSession(
            id: stored.id,
            // The source's own name wins — see this function's caller.
            name: displayName(of: bookmark),
            kind: kind.connectionKind,
            fields: fields.raw,
            groupID: stored.groupID,
            paneVisibility: stored.paneVisibility,
            tags: switches.takeLabelsAsTags ? tags(of: bookmark) : stored.tags,
            position: stored.position,
            importSource: bookmark.source,
            importID: bookmark.id,
            importedAt: importedAt,
            replaces: stored.id)
    }

    // MARK: - Translation (design §3)

    /// What this planner can do with one bookmark — and the ONE place that
    /// decides it, so `preview` and `payload(for:)` cannot come to different
    /// answers about the same row.
    ///
    /// `unreadable` is read BEFORE the protocol, not after: a file that could
    /// not be parsed carries `.unsupported("")` and an empty host (Task 2), so
    /// reading the protocol first would report every malformed file as an
    /// unsupported protocol with no name. The rule is about the FIELD rather
    /// than about Cyberduck's shape — a later source may well read a protocol
    /// out of a file it then fails to parse.
    private static func translation(of bookmark: ExternalBookmark) -> BookmarkTranslation {
        if let reason = bookmark.unreadable { return .refused(.unreadable(reason)) }
        switch bookmark.protocol {
        case .sftp: return .importable(.ssh)
        case .s3: return .importable(.s3)
        case .unsupported(let name): return .refused(.unsupported(name))
        }
    }

    /// Exactly the fields §3's table maps, in `FieldValues`' own spelling —
    /// nothing else, so merging this over a stored session's bag replaces
    /// what the source knows and leaves the rest alone.
    ///
    /// Trimmed like `SSHFieldSchema.apply` and `S3FieldSchema.stored` trim,
    /// because these values also build the connection key: a trailing space
    /// would turn a re-import into a new session instead of an update.
    private static func values(of bookmark: ExternalBookmark, kind: BookmarkKind) -> FieldValues {
        var values = FieldValues()
        switch kind {
        case .ssh:
            values[SSHField.host] = trimmed(bookmark.host)
            // `Port` absent → SSH's own schema default, read off the schema
            // rather than written out again here.
            values[SSHField.port] =
                String(bookmark.port ?? SSHFieldSchema.port(SSHFieldSchema.defaults))
            values[SSHField.username] = trimmed(bookmark.username ?? "")
            let keyPath = trimmed(bookmark.keyPath ?? "")
            values[SSHField.keyPath] = keyPath
            // A key file means private-key auth; anything else means
            // password. Agent auth is never inferred (§3) — nothing in a
            // bookmark says the user runs one.
            values[SSHField.authKind] =
                (keyPath.isEmpty ? StoredSession.AuthKind.password
                                 : StoredSession.AuthKind.privateKey).rawValue
        case .s3:
            values[S3Field.endpoint] = endpoint(of: bookmark)
            values[S3Field.accessKeyID] = trimmed(bookmark.username ?? "")
            let bucket = trimmed(bookmark.path ?? "")
            values[S3Field.bucket] = bucket
            // No `Path` → the connection opens at the account's bucket list.
            values[bool: S3Field.startsAtBucketList] = bucket.isEmpty
            // `region` and `usePathStyle` are deliberately absent: no
            // bookmark carries either, so an update must keep whatever the
            // user configured, and a new session takes the baseline below.
        }
        return values
    }

    /// What an UPDATE writes over the record `old` describes: the bookmark's
    /// own values, minus the two auth fields when the bookmark makes no
    /// statement about auth.
    ///
    /// A missing `Private Key File` is SILENCE, not evidence. Cyberduck has
    /// no column saying "this connection uses an ssh-agent", so reading the
    /// absence as `.password` inverts design §3's "agent is never inferred"
    /// on exactly the path where there is something to lose: an `.agent`
    /// session whose bookmark had its port changed would come back with
    /// password auth and no stored password, and the preview would have shown
    /// one line about the port. The same silence over a stored key path is
    /// worse than cosmetic — clearing it leaves `.privateKey` with no key,
    /// which the backend schema refuses, so the entry would be rejected
    /// outright rather than updated.
    ///
    /// A key file IS a statement, and the only one that moves the auth kind.
    /// `changes(from:to:kind:switches:)` compares against this, so the row
    /// names `authKind` exactly when the import will change it.
    ///
    /// A NEW session has no auth to preserve, so it takes `values(of:kind:)`
    /// unmodified — there the silence really does mean password.
    private static func updateValues(
        of bookmark: ExternalBookmark, kind: BookmarkKind, over old: FieldValues
    ) -> FieldValues {
        var values = values(of: bookmark, kind: kind)
        guard case .ssh = kind, trimmed(bookmark.keyPath ?? "").isEmpty else { return values }
        values[SSHField.authKind] = old[SSHField.authKind]
        values[SSHField.keyPath] = old[SSHField.keyPath]
        return values
    }

    /// What a session of this kind needs beyond §3's table to be dialable at
    /// all. SSH needs nothing — its five fields are exactly the table.
    private static func baseline(for kind: BookmarkKind) -> FieldValues {
        switch kind {
        case .ssh: return FieldValues()
        case .s3: return S3FieldSchema.defaults
        }
    }

    /// `Hostname` → endpoint (§3): Amazon's own host becomes S3's AWS preset
    /// endpoint, one of Hetzner's own hosts becomes the matching location's
    /// preset endpoint, and anything else becomes an https origin carrying
    /// the bookmark's port when it has one.
    ///
    /// The Hetzner lookup is by HOST alone, ignoring any port the bookmark
    /// names — Hetzner Object Storage is reached on the default HTTPS port,
    /// so a bookmark naming another one is not this provider's endpoint,
    /// mirroring how `awsHostname` above is matched by host with no port
    /// check either.
    ///
    /// The generic fallback's spelling is composed by
    /// `S3FieldSchema.endpointSpelling`, not here: it is the same function
    /// the endpoint parse round-trips, so an imported bookmark is dialable
    /// by construction rather than by agreement. What this file wrote by
    /// hand before also bracketed no IPv6 literal — `https://::1:9000`
    /// parses to no host at all.
    private static func endpoint(of bookmark: ExternalBookmark) -> String {
        let host = trimmed(bookmark.host)
        guard host.caseInsensitiveCompare(awsHostname) != .orderedSame else {
            return awsEndpoint
        }
        if let hetznerEndpoint = hetznerEndpointsByHost[host.lowercased()] {
            return hetznerEndpoint
        }
        return S3FieldSchema.endpointSpelling(host: host, port: bookmark.port)
    }

    /// `Nickname`, falling back to the host (§3). A bookmark with neither is
    /// named by the empty string, which the store accepts and the sheet shows
    /// as a blank row — better than inventing a name the user never chose.
    private static func displayName(of bookmark: ExternalBookmark) -> String {
        let nickname = trimmed(bookmark.nickname ?? "")
        return nickname.isEmpty ? trimmed(bookmark.host) : nickname
    }

    /// The bookmark's labels under `StoredSession.tags`' own rule, so the
    /// change list compares what would actually be stored.
    private static func tags(of bookmark: ExternalBookmark) -> [String] {
        TagList.normalized(bookmark.labels)
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
