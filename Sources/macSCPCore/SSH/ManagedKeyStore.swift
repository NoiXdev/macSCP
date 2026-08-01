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

    public func all() throws -> [ManagedKey] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ManagedKey].self, from: data)
    }

    public func add(_ key: ManagedKey) throws {
        var keys = try all()
        keys.removeAll { $0.id == key.id }
        keys.append(key)
        try persist(keys)
    }

    /// Removes metadata AND the private/public key files AND the Keychain
    /// passphrase slot under `id`. Missing files/slot are ignored (idempotent).
    ///
    /// Metadata is persisted FIRST, then the files/Keychain slot are deleted
    /// best-effort. This way, if `persist` throws, at worst an orphaned file
    /// is left behind (harmless) — never a metadata entry pointing at files
    /// that no longer exist.
    public func remove(id: UUID, secrets: any SecretStore) throws {
        let keys = try all()
        let key = keys.first(where: { $0.id == id })
        try persist(keys.filter { $0.id != id })
        if let key {
            let priv = keyDirectory.appendingPathComponent(key.fileName)
            try? FileManager.default.removeItem(at: priv)
            try? FileManager.default.removeItem(
                at: keyDirectory.appendingPathComponent(key.fileName + ".pub"))
        }
        try? secrets.deletePassword(for: id)
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
        try encoder.encode(keys).write(to: fileURL, options: .atomic)
    }
}
