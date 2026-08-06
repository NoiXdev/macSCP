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
    /// File-local reference target for `ExportedSession.groupID` — never
    /// imported as-is (the planner assigns fresh ids).
    public let id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ExportedSession: Codable, Equatable, Sendable {
    /// File-local id — only for group references inside the file.
    public let id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var authKind: StoredSession.AuthKind
    public var keyPath: String?
    public var groupID: UUID?
    /// Present only when the export included secrets AND the keychain had
    /// one for this session at export time.
    public var password: String?
    /// Jump host fields (M10c), always RESOLVED (a set reference becomes the
    /// set's own values at export time — sets themselves are never
    /// exported). `nil` when the session has no jump, or on legacy payloads
    /// written before M10c (no custom decoder — decodes nil like groupID).
    public var jumpHost: String?
    public var jumpPort: Int?
    public var jumpUsername: String?
    public var jumpAuthKind: StoredSession.AuthKind?
    public var jumpKeyPath: String?
    /// Present only when the export included secrets AND the keychain had
    /// one for the jump at export time.
    public var jumpPassword: String?
    /// The protocol this session speaks (M12). `nil` on legacy payloads
    /// written before M12 (no custom decoder -- decodes nil like groupID),
    /// which the import side maps to `.ssh`.
    public var kind: ConnectionKind?
    /// S3 parameters (M12), present only when `kind == .s3`. Secret-free
    /// mirror of `StoredS3Config` -- the secret access key travels
    /// separately, in `s3SecretAccessKey`.
    public var s3AccessKeyID: String?
    public var s3Region: String?
    public var s3Endpoint: String?
    public var s3Bucket: String?
    public var s3UsePathStyle: Bool?
    /// Present only when the export included secrets AND the keychain had
    /// one for this S3 session at export time -- the same optional-plaintext
    /// channel as `jumpPassword`, only ever populated in the encrypted
    /// export path.
    public var s3SecretAccessKey: String?
    /// WebDAV parameters (M21), present only when `kind == .webdav`. Flat
    /// mirror of `StoredWebDAVConfig`, laid out exactly like the `s3*` block
    /// above and Optional for the same reason: a file written before these
    /// columns existed simply has no such keys and decodes them as `nil`.
    ///
    /// There is deliberately no WebDAV secret column. Unlike S3 -- whose
    /// secret access key needed `s3SecretAccessKey` because the plain
    /// `password` slot is the SSH password's -- a WebDAV session's password
    /// already travels in `password` (same Keychain slot, see
    /// `SessionListViewModel.exportPayload`), so nothing secret is added here.
    public var webdavBaseURL: String?
    public var webdavUsername: String?
    public var webdavUseNextcloudPath: Bool?

    public init(
        id: UUID, name: String, host: String, port: Int, username: String,
        authKind: StoredSession.AuthKind, keyPath: String?, groupID: UUID?,
        password: String?,
        jumpHost: String? = nil, jumpPort: Int? = nil, jumpUsername: String? = nil,
        jumpAuthKind: StoredSession.AuthKind? = nil, jumpKeyPath: String? = nil,
        jumpPassword: String? = nil,
        kind: ConnectionKind? = nil,
        s3AccessKeyID: String? = nil, s3Region: String? = nil, s3Endpoint: String? = nil,
        s3Bucket: String? = nil, s3UsePathStyle: Bool? = nil, s3SecretAccessKey: String? = nil,
        webdavBaseURL: String? = nil, webdavUsername: String? = nil,
        webdavUseNextcloudPath: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authKind = authKind
        self.keyPath = keyPath
        self.groupID = groupID
        self.password = password
        self.jumpHost = jumpHost
        self.jumpPort = jumpPort
        self.jumpUsername = jumpUsername
        self.jumpAuthKind = jumpAuthKind
        self.jumpKeyPath = jumpKeyPath
        self.jumpPassword = jumpPassword
        self.kind = kind
        self.s3AccessKeyID = s3AccessKeyID
        self.s3Region = s3Region
        self.s3Endpoint = s3Endpoint
        self.s3Bucket = s3Bucket
        self.s3UsePathStyle = s3UsePathStyle
        self.s3SecretAccessKey = s3SecretAccessKey
        self.webdavBaseURL = webdavBaseURL
        self.webdavUsername = webdavUsername
        self.webdavUseNextcloudPath = webdavUseNextcloudPath
    }
}

/// `.macscpsessions` binding of the shared `ExportEnvelopeCodec` (spec M9a
/// §1+§2.1). Nothing but format identity lives here — envelope shape, key
/// derivation and AES-GCM are the generic core's job.
public enum SessionExportCodec {
    static let formatName = "macscp-sessions"
    static let currentVersion = 1

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

    public static func decode(_ data: Data, password: String?) throws -> SessionExportPayload {
        try ExportEnvelopeCodec.decode(
            data, as: SessionExportPayload.self, format: formatName,
            currentVersion: currentVersion, password: password)
    }
}
