import Foundation

/// JSON persistence for managed SSH keys (`managed_keys.json`), following the
/// `KnownHostsStore` pattern (stateless, atomic writes). Secret-free: the
/// private key file lives under `keyDirectory` (0600), the passphrase in the
/// Keychain under `ManagedKey.id` — never here.
public struct ManagedKeyStore: Sendable {
    private let directory: URL
    private let fileURL: URL
    /// Where the private/public key files live (0700 subdirectory).
    public let keyDirectory: URL

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("managed_keys.json")
        self.keyDirectory = directory.appendingPathComponent("keys", isDirectory: true)
    }

    /// Wire format for `managed_keys.json`. Mirrors `ManagedKey` field-for-field
    /// except `hasPassphrase`, which is renamed to `encrypted` on the wire so
    /// the substring "passphrase" never appears in the file — the flag itself
    /// is not a secret, but the store must stay secret-free in letter and
    /// spirit (grep-safe for anyone auditing the JSON).
    private struct PersistedKey: Codable {
        let id: UUID
        let name: String
        let comment: String
        let type: KeyType
        let fingerprint: String
        let publicKeyOpenSSH: String
        let createdAt: Date
        let encrypted: Bool
        let fileName: String

        init(_ key: ManagedKey) {
            id = key.id
            name = key.name
            comment = key.comment
            type = key.type
            fingerprint = key.fingerprint
            publicKeyOpenSSH = key.publicKeyOpenSSH
            createdAt = key.createdAt
            encrypted = key.hasPassphrase
            fileName = key.fileName
        }

        var managedKey: ManagedKey {
            ManagedKey(
                id: id, name: name, comment: comment, type: type, fingerprint: fingerprint,
                publicKeyOpenSSH: publicKeyOpenSSH, createdAt: createdAt,
                hasPassphrase: encrypted, fileName: fileName)
        }
    }

    public func all() throws -> [ManagedKey] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PersistedKey].self, from: data).map(\.managedKey)
    }

    public func add(_ key: ManagedKey) throws {
        var keys = try all()
        keys.removeAll { $0.id == key.id }
        keys.append(key)
        try persist(keys)
    }

    /// Removes metadata AND the private/public key files AND the Keychain
    /// passphrase slot under `id`. Missing files/slot are ignored (idempotent).
    public func remove(id: UUID, secrets: any SecretStore) throws {
        let keys = try all()
        if let key = keys.first(where: { $0.id == id }) {
            let priv = keyDirectory.appendingPathComponent(key.fileName)
            try? FileManager.default.removeItem(at: priv)
            try? FileManager.default.removeItem(
                at: keyDirectory.appendingPathComponent(key.fileName + ".pub"))
        }
        try? secrets.deletePassword(for: id)
        try persist(keys.filter { $0.id != id })
    }

    /// The managed key whose private file is at `path`, or nil. Matches by the
    /// resolved absolute path of `keyDirectory/fileName` (tilde-expanded).
    public func key(forPath path: String) throws -> ManagedKey? {
        let target = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL.path
        return try all().first {
            keyDirectory.appendingPathComponent($0.fileName).standardizedFileURL.path == target
        }
    }

    private func persist(_ keys: [ManagedKey]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(keys.map(PersistedKey.init)).write(to: fileURL, options: .atomic)
    }
}
