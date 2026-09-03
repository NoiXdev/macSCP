import Foundation

/// The on-disk payload of a `.macscpsessions` export (spec M9a §1). Key
/// FILES are never part of an export — `keyPath` is a plain path reference.
public struct SessionExportPayload: Codable, Equatable, Sendable {
    public var includesSecrets: Bool
    public var groups: [ExportedGroup]
    public var sessions: [ExportedSession]

    public init(includesSecrets: Bool, groups: [ExportedGroup], sessions: [ExportedSession]) {
        self.includesSecrets = includesSecrets
        self.groups = groups
        self.sessions = sessions
    }
}

public struct ExportedGroup: Codable, Equatable, Sendable {
    /// File-local reference target for `ExportedSession.groupID` and for
    /// `parentID` below — never imported as-is (the planner assigns fresh
    /// ids and remaps both references onto them).
    public let id: UUID
    public var name: String
    /// The folder this folder sits in (`StoredGroup.parentID`, D1). Another
    /// `ExportedGroup.id` in this same file, so it is a REFERENCE and is
    /// rekeyed on import exactly like `ExportedSession.groupID` — carried
    /// over raw it would name an id that no longer exists.
    ///
    /// A file may still name a parent it does not carry, or close a ring;
    /// `GroupTree.repaired` lifts such a folder to the top level rather than
    /// dropping it, and the planner runs it before anything is taken over.
    ///
    /// `nil` on any payload written before this field existed — and, in a
    /// file that has it, on every top-level folder.
    public var parentID: UUID?
    /// Rank among the siblings under the same parent (`StoredGroup.position`,
    /// D2). A value, not a reference: no remapping, the same way
    /// `ExportedSession.paneVisibility` needs none.
    ///
    /// Optional for the same reason `kind` is: `nil` means a payload written
    /// before this field existed, and the import side applies
    /// `StoredGroup.position`'s own default (`0`) — mapped at import rather
    /// than at decode, so every reader sees what the file actually said.
    public var position: Int?

    public init(id: UUID, name: String, parentID: UUID? = nil, position: Int? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.position = position
    }
}

public struct ExportedSession: Codable, Equatable, Sendable {
    /// File-local id — only for group references inside the file.
    public let id: UUID
    public var name: String
    public var groupID: UUID?
    /// The protocol this session speaks (M12). `nil` on legacy payloads
    /// written before M12, which the import side maps to `.ssh`.
    public var kind: ConnectionKind?
    /// Which window halves were last shown for this session (P2
    /// terminal-chrome milestone, Task 4) — carried through export exactly
    /// like `groupID` above: a fact about the session, not a connection
    /// field, so it is NOT part of `fields`. `nil` on any payload written
    /// before this field existed; the import side applies the same
    /// "both visible" default `StoredSession.init(from:)` does, the same
    /// way `kind == nil` is mapped to `.ssh` at import rather than at decode.
    public var paneVisibility: PaneVisibility?
    /// Free-form labels for the sidebar's tag filter (`StoredSession.tags`,
    /// P3a). Carried the same way `paneVisibility` is, not the way `groupID`
    /// is: a tag list is a fact about the session, not a reference into
    /// something else the file also carries (there is no per-file "tag
    /// catalog" the way `ExportedGroup` is one for `groupID`), so it needs
    /// no id remapping on import and no `includeGroups`-style gate on
    /// export. `nil` on any payload written before this field existed; the
    /// import side applies `StoredSession.tags`'s own default (`[]`), the
    /// same way `paneVisibility == nil` maps to `.filesOnly` at import
    /// rather than at decode.
    public var tags: [String]?
    /// Rank among the siblings under the same parent
    /// (`StoredSession.position`, D2). Carried the way `tags` is and not the
    /// way `groupID` is: a rank is a value, not a reference into the file's
    /// own group catalog, so it needs no id remapping on import. `nil` on any
    /// payload written before this field existed; the import side applies
    /// `StoredSession.position`'s own default (`0`), the same way `kind ==
    /// nil` maps to `.ssh` at import rather than at decode.
    public var position: Int?

    /// Every backend field this session carries, keyed exactly as
    /// `FieldValues` keys them (`"<namespace>.<fieldID>"`).
    ///
    /// Replaced the per-protocol column blocks in M23/P3. Those had to grow a
    /// block per backend — the thing this milestone exists to stop — and they
    /// carried SSH's flat triple at the top level, where a pre-M23 export
    /// wrote the literal `"unused"` for every S3 and WebDAV session.
    ///
    /// SECRET-FREE by construction: `sessionValues` reads a `StoredSession`,
    /// which never holds a secret. Secrets travel in `password` /
    /// `s3SecretAccessKey` / `jumpPassword`, and only in the encrypted path.
    ///
    /// An EMPTY bag means the session carried no stored block for its kind —
    /// what `BackendDescriptor.sessionValues` returns for an `.s3`/`.webdav`
    /// session whose block is nil. The import side reads it back that way, so
    /// an export never invents a server the file did not name.
    public var fields: [String: String]

    /// Present only when the export included secrets AND the keychain had
    /// one for this session at export time.
    public var password: String?
    /// Jump host fields (M10c), always RESOLVED (a set reference becomes the
    /// set's own values at export time — sets themselves are never
    /// exported). `nil` when the session has no jump, or on legacy payloads
    /// written before M10c.
    ///
    /// NOT part of `fields`, and deliberately so: the jump is a second login
    /// with its own Keychain slot, which is exactly why
    /// `SSHFieldSchema.apply` does not own it either.
    public var jumpHost: String?
    public var jumpPort: Int?
    public var jumpUsername: String?
    public var jumpAuthKind: StoredSession.AuthKind?
    public var jumpKeyPath: String?
    /// Present only when the export included secrets AND the keychain had
    /// one for the jump at export time.
    public var jumpPassword: String?
    /// Present only when the export included secrets AND the keychain had
    /// one for this S3 session at export time -- the same optional-plaintext
    /// channel as `jumpPassword`, only ever populated in the encrypted
    /// export path. A secret, therefore never a field.
    public var s3SecretAccessKey: String?

    /// Provenance (Cyberduck import, M24) — carried the same way `tags` is,
    /// not the way `groupID` is: a fact about the session itself, needing no
    /// id remapping on import. `nil` on any payload written before these
    /// fields existed, or on a session that never came from an import;
    /// `StoredSession`'s own default (`nil`) is what the import side applies.
    /// See `StoredSession.importSource` for the field-by-field meaning.
    public var importSource: String?
    public var importID: String?
    public var importedAt: Date?

    // MARK: - Decode-only v1 columns (M23/P3)
    //
    // The columns a version-1 file carries instead of `fields`. They are read
    // when such a file is opened and are NEVER written: `encode(to:)` below
    // omits them, and nothing outside the decoder can set one (the
    // initializer does not take them, and their setters are private).
    //
    // `SessionExportCodec.decode` folds them into `fields` and clears them
    // before returning, so every reader downstream — the planner above all —
    // only ever sees one shape.

    /// v1's flat SSH triple. Carried by EVERY v1 session regardless of kind,
    /// holding the literal `"unused"` on an S3 or WebDAV session written
    /// before M23. `upgradeV1Columns` therefore only reads them for `.ssh`.
    public private(set) var legacyHost: String?
    public private(set) var legacyPort: Int?
    public private(set) var legacyUsername: String?
    public private(set) var legacyAuthKind: StoredSession.AuthKind?
    public private(set) var legacyKeyPath: String?
    /// v1's S3 block (M12) — the secret-free mirror of `StoredS3Config`.
    public private(set) var legacyS3AccessKeyID: String?
    public private(set) var legacyS3Region: String?
    public private(set) var legacyS3Endpoint: String?
    public private(set) var legacyS3Bucket: String?
    public private(set) var legacyS3UsePathStyle: Bool?
    /// v1's WebDAV block (M21/M23). There never was a WebDAV secret column:
    /// a WebDAV session's password rides the shared `password` slot.
    public private(set) var legacyWebDAVBaseURL: String?
    public private(set) var legacyWebDAVUsername: String?
    public private(set) var legacyWebDAVUseNextcloudPath: Bool?

    /// Explicit rather than memberwise: the v1 columns must not be settable
    /// from outside the decoder (see above), and a memberwise initializer
    /// would expose all thirteen of them. The order is what a session IS —
    /// identity, kind, its fields — followed by the things that are not
    /// backend fields: the group reference, the secrets, the jump.
    public init(
        id: UUID,
        name: String,
        kind: ConnectionKind? = nil,
        fields: [String: String] = [:],
        groupID: UUID? = nil,
        paneVisibility: PaneVisibility? = nil,
        tags: [String]? = nil,
        position: Int? = nil,
        password: String? = nil,
        jumpHost: String? = nil, jumpPort: Int? = nil, jumpUsername: String? = nil,
        jumpAuthKind: StoredSession.AuthKind? = nil, jumpKeyPath: String? = nil,
        jumpPassword: String? = nil,
        s3SecretAccessKey: String? = nil,
        importSource: String? = nil,
        importID: String? = nil,
        importedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.fields = fields
        self.groupID = groupID
        self.paneVisibility = paneVisibility
        self.tags = tags
        self.position = position
        self.password = password
        self.jumpHost = jumpHost
        self.jumpPort = jumpPort
        self.jumpUsername = jumpUsername
        self.jumpAuthKind = jumpAuthKind
        self.jumpKeyPath = jumpKeyPath
        self.jumpPassword = jumpPassword
        self.s3SecretAccessKey = s3SecretAccessKey
        self.importSource = importSource
        self.importID = importID
        self.importedAt = importedAt
    }

    /// The `legacy*` cases keep v1's original key names, so a v1 file decodes
    /// unchanged while the property names say what they are.
    private enum CodingKeys: String, CodingKey {
        case id, name, groupID, kind, fields, paneVisibility, tags, position, password
        case jumpHost, jumpPort, jumpUsername, jumpAuthKind, jumpKeyPath, jumpPassword
        case s3SecretAccessKey
        case importSource, importID, importedAt
        case legacyHost = "host"
        case legacyPort = "port"
        case legacyUsername = "username"
        case legacyAuthKind = "authKind"
        case legacyKeyPath = "keyPath"
        case legacyS3AccessKeyID = "s3AccessKeyID"
        case legacyS3Region = "s3Region"
        case legacyS3Endpoint = "s3Endpoint"
        case legacyS3Bucket = "s3Bucket"
        case legacyS3UsePathStyle = "s3UsePathStyle"
        case legacyWebDAVBaseURL = "webdavBaseURL"
        case legacyWebDAVUsername = "webdavUsername"
        case legacyWebDAVUseNextcloudPath = "webdavUseNextcloudPath"
    }

    /// Explicit because `fields` has no key in a v1 file and a synthesized
    /// decoder would throw `keyNotFound` on one — same reason
    /// `StoredSession.init(from:)` is explicit for `kind`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        kind = try c.decodeIfPresent(ConnectionKind.self, forKey: .kind)
        paneVisibility = try c.decodeIfPresent(PaneVisibility.self, forKey: .paneVisibility)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        position = try c.decodeIfPresent(Int.self, forKey: .position)
        fields = try c.decodeIfPresent([String: String].self, forKey: .fields) ?? [:]
        password = try c.decodeIfPresent(String.self, forKey: .password)
        jumpHost = try c.decodeIfPresent(String.self, forKey: .jumpHost)
        jumpPort = try c.decodeIfPresent(Int.self, forKey: .jumpPort)
        jumpUsername = try c.decodeIfPresent(String.self, forKey: .jumpUsername)
        jumpAuthKind = try c.decodeIfPresent(StoredSession.AuthKind.self, forKey: .jumpAuthKind)
        jumpKeyPath = try c.decodeIfPresent(String.self, forKey: .jumpKeyPath)
        jumpPassword = try c.decodeIfPresent(String.self, forKey: .jumpPassword)
        s3SecretAccessKey = try c.decodeIfPresent(String.self, forKey: .s3SecretAccessKey)
        importSource = try c.decodeIfPresent(String.self, forKey: .importSource)
        importID = try c.decodeIfPresent(String.self, forKey: .importID)
        importedAt = try c.decodeIfPresent(Date.self, forKey: .importedAt)
        legacyHost = try c.decodeIfPresent(String.self, forKey: .legacyHost)
        legacyPort = try c.decodeIfPresent(Int.self, forKey: .legacyPort)
        legacyUsername = try c.decodeIfPresent(String.self, forKey: .legacyUsername)
        legacyAuthKind = try c.decodeIfPresent(StoredSession.AuthKind.self, forKey: .legacyAuthKind)
        legacyKeyPath = try c.decodeIfPresent(String.self, forKey: .legacyKeyPath)
        legacyS3AccessKeyID = try c.decodeIfPresent(String.self, forKey: .legacyS3AccessKeyID)
        legacyS3Region = try c.decodeIfPresent(String.self, forKey: .legacyS3Region)
        legacyS3Endpoint = try c.decodeIfPresent(String.self, forKey: .legacyS3Endpoint)
        legacyS3Bucket = try c.decodeIfPresent(String.self, forKey: .legacyS3Bucket)
        legacyS3UsePathStyle = try c.decodeIfPresent(Bool.self, forKey: .legacyS3UsePathStyle)
        legacyWebDAVBaseURL = try c.decodeIfPresent(String.self, forKey: .legacyWebDAVBaseURL)
        legacyWebDAVUsername = try c.decodeIfPresent(String.self, forKey: .legacyWebDAVUsername)
        legacyWebDAVUseNextcloudPath =
            try c.decodeIfPresent(Bool.self, forKey: .legacyWebDAVUseNextcloudPath)
    }

    /// Explicit so the `legacy*` columns are structurally unwritable: a v2
    /// file carries `fields` and nothing column-shaped, whatever a decoded
    /// value happens to still hold.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(groupID, forKey: .groupID)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(paneVisibility, forKey: .paneVisibility)
        try c.encodeIfPresent(tags, forKey: .tags)
        try c.encodeIfPresent(position, forKey: .position)
        try c.encode(fields, forKey: .fields)
        try c.encodeIfPresent(password, forKey: .password)
        try c.encodeIfPresent(jumpHost, forKey: .jumpHost)
        try c.encodeIfPresent(jumpPort, forKey: .jumpPort)
        try c.encodeIfPresent(jumpUsername, forKey: .jumpUsername)
        try c.encodeIfPresent(jumpAuthKind, forKey: .jumpAuthKind)
        try c.encodeIfPresent(jumpKeyPath, forKey: .jumpKeyPath)
        try c.encodeIfPresent(jumpPassword, forKey: .jumpPassword)
        try c.encodeIfPresent(s3SecretAccessKey, forKey: .s3SecretAccessKey)
        try c.encodeIfPresent(importSource, forKey: .importSource)
        try c.encodeIfPresent(importID, forKey: .importID)
        try c.encodeIfPresent(importedAt, forKey: .importedAt)
    }

    /// Folds a v1 file's columns into `fields` and clears them. A no-op on a
    /// v2 payload, which carries no `legacy*` value at all.
    ///
    /// Three independent `if`s rather than a `switch kind`, on purpose. A
    /// fourth backend has no v1 columns — v1 predates it — so it has nothing
    /// to add here, and a `switch` would force an empty arm to be written for
    /// it, which is precisely the compile-forcing site this milestone exists
    /// to remove.
    ///
    /// The SSH block is gated on the kind because a v1 file carries the flat
    /// triple for EVERY session, holding the literal `"unused"` on an S3 or
    /// WebDAV session written before M23. Copying it unconditionally would
    /// import exactly the placeholder Phase 1 removed.
    fileprivate mutating func upgradeV1Columns() {
        var values = FieldValues(raw: fields)

        if (kind ?? .ssh) == .ssh, let host = legacyHost {
            values[SSHField.host] = host
            values[SSHField.port] = String(legacyPort ?? 22)
            values[SSHField.username] = legacyUsername ?? ""
            values[SSHField.authKind] = (legacyAuthKind ?? .password).rawValue
            // `SSHFieldSchema.values(from:)` writes "" for a missing key
            // path; matching it keeps an upgraded bag indistinguishable from
            // one a v2 export wrote.
            values[SSHField.keyPath] = legacyKeyPath ?? ""
        }

        // The S3 and WebDAV blocks were written all-or-nothing, so ANY column
        // means the file carried the block. Writing them individually would
        // leave a half-filled bag that no exporter ever produced.
        if kind == .s3, hasLegacyS3Columns {
            values[S3Field.accessKeyID] = legacyS3AccessKeyID ?? ""
            values[S3Field.region] = legacyS3Region ?? ""
            values[S3Field.endpoint] = legacyS3Endpoint ?? ""
            values[S3Field.bucket] = legacyS3Bucket ?? ""
            values[bool: S3Field.usePathStyle] = legacyS3UsePathStyle ?? false
        }

        if kind == .webdav, hasLegacyWebDAVColumns {
            values[WebDAVField.baseURL] = legacyWebDAVBaseURL ?? ""
            values[WebDAVField.username] = legacyWebDAVUsername ?? ""
            values[bool: WebDAVField.useNextcloudPath] = legacyWebDAVUseNextcloudPath ?? false
        }

        fields = values.raw
        legacyHost = nil
        legacyPort = nil
        legacyUsername = nil
        legacyAuthKind = nil
        legacyKeyPath = nil
        legacyS3AccessKeyID = nil
        legacyS3Region = nil
        legacyS3Endpoint = nil
        legacyS3Bucket = nil
        legacyS3UsePathStyle = nil
        legacyWebDAVBaseURL = nil
        legacyWebDAVUsername = nil
        legacyWebDAVUseNextcloudPath = nil
    }

    private var hasLegacyS3Columns: Bool {
        legacyS3AccessKeyID != nil || legacyS3Region != nil || legacyS3Endpoint != nil
            || legacyS3Bucket != nil || legacyS3UsePathStyle != nil
    }

    private var hasLegacyWebDAVColumns: Bool {
        legacyWebDAVBaseURL != nil || legacyWebDAVUsername != nil
            || legacyWebDAVUseNextcloudPath != nil
    }
}

/// `.macscpsessions` binding of the shared `ExportEnvelopeCodec` (spec M9a
/// §1+§2.1). Nothing but format identity lives here — envelope shape, key
/// derivation and AES-GCM are the generic core's job.
public enum SessionExportCodec {
    static let formatName = "macscp-sessions"

    /// 2 since M23/P3, when the per-protocol columns became one field bag.
    ///
    /// What the bump BUYS: `ExportEnvelopeCodec` validates the header before
    /// it decodes the payload, so an older macSCP refuses a v2 file with
    /// `unsupportedVersion` — a clear message — instead of half-reading a
    /// shape it does not understand and importing sessions with no host.
    ///
    /// What it COSTS: exchanging `.macscp` files with older installations
    /// ends. The format was additive until now, so an older build could read
    /// a newer export minus the backends it did not know; after this it can
    /// read nothing. That is the maintainer's decision and belongs in the
    /// release notes. This direction still reads every v1 file — see
    /// `ExportedSession.upgradeV1Columns`.
    static let currentVersion = 2

    public static func encode(_ payload: SessionExportPayload, password: String?) throws -> Data {
        try ExportEnvelopeCodec.encode(
            payload, format: formatName, version: currentVersion, password: password)
    }

    /// True = encrypted. Lets the UI decide whether to ask for a password
    /// without attempting decryption.
    public static func probe(_ data: Data) throws -> Bool {
        try ExportEnvelopeCodec.probe(
            data, as: SessionExportPayload.self, format: formatName,
            currentVersion: currentVersion)
    }

    /// `password` defaults to nil so a caller that knows the file is
    /// unencrypted need not say so; an encrypted file without one still
    /// throws `passwordRequired` rather than failing silently.
    public static func decode(
        _ data: Data, password: String? = nil
    ) throws -> SessionExportPayload {
        var payload = try ExportEnvelopeCodec.decode(
            data, as: SessionExportPayload.self, format: formatName,
            currentVersion: currentVersion, password: password)
        // The v1 -> bag upgrade happens HERE, not in the import planner: the
        // planner should only ever see one shape, and so should every other
        // reader of a decoded payload.
        for index in payload.sessions.indices {
            payload.sessions[index].upgradeV1Columns()
        }
        return payload
    }
}
