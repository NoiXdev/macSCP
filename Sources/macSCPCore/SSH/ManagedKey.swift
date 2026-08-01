import Foundation

/// The kind of SSH key (M17). Only ed25519 keys can be used to CONNECT in
/// macSCP today (the loader is ed25519-only); rsa/ecdsa keys can be
/// generated and their public key exported, but are not offered as a login.
public enum KeyType: Equatable, Sendable, Codable {
    case ed25519
    case rsa(bits: Int)
    case ecdsa

    /// True only for ed25519 — the one type `SSHPrivateKeyLoader` can load.
    public var isConnectable: Bool {
        if case .ed25519 = self { return true }
        return false
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
