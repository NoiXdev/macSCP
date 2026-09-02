import Foundation

/// The kind of SSH key (M17). All three cases can be used to CONNECT in
/// macSCP: `SSHPrivateKeyLoader` opens OpenSSH-format ed25519, RSA and
/// ECDSA (P-256/384/521) private key files (`fa67138`); DSA, `sk-*`
/// security-key types and PEM-format keys are not modelled here at all and
/// never reach `KeyType`.
public enum KeyType: Equatable, Sendable, Codable {
    case ed25519
    case rsa(bits: Int)
    case ecdsa

    /// Whether `SSHPrivateKeyLoader` can load a key of this type — true for
    /// all three cases. This is about the LOADER's reach, not about whether
    /// a given key is USEFUL to connect with: an RSA key this weak that a
    /// server refuses (OpenSSH's `RequiredRSASize` defaults to 1024, so a
    /// short key server-config can reject) is still loadable, and that
    /// rejection is the server's decision, not a case this property makes.
    public var isConnectable: Bool {
        switch self {
        case .ed25519, .rsa, .ecdsa: return true
        }
    }
}

/// A macSCP-managed SSH key (M17). Metadata only — the private key lives as a
/// 0600 file in the key directory; its passphrase (if any) lives in the
/// Keychain under `id`. This struct is persisted to `managed_keys.json` and
/// therefore contains NO secret material.
public struct ManagedKey: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var comment: String
    public var type: KeyType
    public var fingerprint: String        // "SHA256:…"
    public var publicKeyOpenSSH: String   // "ssh-ed25519 AAAA… comment"
    public var createdAt: Date
    /// Whether the key FILE is encrypted — NOT whether a Keychain slot exists.
    /// The two coincide for keys macSCP generates or imports by hand, but not
    /// for one materialized out of a login-set export that carried no secrets:
    /// that key is encrypted and has no slot. Anything asking "is the
    /// passphrase stored?" must call
    /// `ManagedKeyPassphrase.hasStoredPassphrase(keyPath:store:secrets:)`;
    /// this flag drives the lock glyph and the "look for a passphrase at all"
    /// fast path, nothing else.
    public var hasPassphrase: Bool
    public var fileName: String           // private key file, relative to the key dir

    public init(
        id: UUID = UUID(), name: String, comment: String, type: KeyType,
        fingerprint: String, publicKeyOpenSSH: String, createdAt: Date,
        hasPassphrase: Bool, fileName: String
    ) {
        self.id = id
        self.name = name
        self.comment = comment
        self.type = type
        self.fingerprint = fingerprint
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.createdAt = createdAt
        self.hasPassphrase = hasPassphrase
        self.fileName = fileName
    }
}
