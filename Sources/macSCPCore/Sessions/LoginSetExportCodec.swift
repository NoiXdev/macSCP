import Foundation

/// The on-disk payload of a `.macscplogins` export (spec M19 "Payload"). Key
/// FILES are embedded only for managed keys and only when the user opts in
/// (see `ExportedLoginSet.embeddedKey`) -- external key paths are never read.
public struct LoginSetExportPayload: Codable, Equatable, Sendable {
    public var includesSecrets: Bool
    public var includesKeyFiles: Bool
    public var sets: [ExportedLoginSet]

    public init(includesSecrets: Bool, includesKeyFiles: Bool, sets: [ExportedLoginSet]) {
        self.includesSecrets = includesSecrets
        self.includesKeyFiles = includesKeyFiles
        self.sets = sets
    }
}

public struct ExportedLoginSet: Codable, Equatable, Sendable {
    /// File-local id -- carried through so a `replace` import can keep the
    /// set's identity (sessions referencing it by id keep pointing at it).
    public let id: UUID
    public var name: String
    public var kind: ConnectionKind
    public var username: String
    public var authKind: StoredSession.AuthKind
    public var keyPath: String?
    public var accessKeyID: String?
    /// Only present when the export included secrets (`includesSecrets`) --
    /// the set's Keychain secret (password or S3 secret access key) at
    /// export time.
    public var secret: String?
    /// Only present when the export embedded key files (`includesKeyFiles`)
    /// AND `keyPath` resolved to a macSCP-managed key at export time.
    /// External key paths are never read into this field.
    public var embeddedKey: EmbeddedKey?

    public init(
        id: UUID, name: String, kind: ConnectionKind, username: String,
        authKind: StoredSession.AuthKind, keyPath: String?, accessKeyID: String?,
        secret: String?, embeddedKey: EmbeddedKey?
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.username = username
        self.authKind = authKind
        self.keyPath = keyPath
        self.accessKeyID = accessKeyID
        self.secret = secret
        self.embeddedKey = embeddedKey
    }
}

public struct EmbeddedKey: Codable, Equatable, Sendable {
    /// The private key file's raw bytes, read only from a macSCP-managed key
    /// directory -- never from an external path.
    public var fileContents: Data
    public var name: String
    public var comment: String
    public var type: KeyType
    public var fingerprint: String
    /// The OpenSSH public key line. Carried unconditionally (a public key is
    /// not a secret, and it is already in `ManagedKey`, so it costs no extra
    /// file read): for an encrypted key exported WITHOUT its passphrase the
    /// import side cannot derive it, and would otherwise register the key
    /// with an empty public key -- exactly when the user needs that line for
    /// an `authorized_keys` entry.
    public var publicKeyOpenSSH: String
    public var hasPassphrase: Bool
    /// Only present when the export ALSO included secrets
    /// (`LoginSetExportPayload.includesSecrets`) -- the managed key's
    /// Keychain passphrase at export time.
    public var passphrase: String?

    public init(
        fileContents: Data, name: String, comment: String, type: KeyType,
        fingerprint: String, publicKeyOpenSSH: String, hasPassphrase: Bool,
        passphrase: String?
    ) {
        self.fileContents = fileContents
        self.name = name
        self.comment = comment
        self.type = type
        self.fingerprint = fingerprint
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.hasPassphrase = hasPassphrase
        self.passphrase = passphrase
    }
}

/// `.macscplogins` binding of the shared `ExportEnvelopeCodec` (spec M19).
/// Nothing but format identity lives here -- envelope shape, key derivation
/// and AES-GCM are the generic core's job (see `SessionExportCodec`, the
/// sibling facade for the `macscp-sessions` format).
public enum LoginSetExportCodec {
    static let formatName = "macscp-logins"
    static let currentVersion = 1

    public static func encode(_ payload: LoginSetExportPayload, password: String?) throws -> Data {
        try ExportEnvelopeCodec.encode(
            payload, format: formatName, version: currentVersion, password: password)
    }

    /// True = encrypted. Lets the UI decide whether to ask for a password
    /// without attempting decryption.
    public static func probe(_ data: Data) throws -> Bool {
        try ExportEnvelopeCodec.probe(
            data, as: LoginSetExportPayload.self, format: formatName,
            currentVersion: currentVersion)
    }

    public static func decode(_ data: Data, password: String?) throws -> LoginSetExportPayload {
        try ExportEnvelopeCodec.decode(
            data, as: LoginSetExportPayload.self, format: formatName,
            currentVersion: currentVersion, password: password)
    }
}
