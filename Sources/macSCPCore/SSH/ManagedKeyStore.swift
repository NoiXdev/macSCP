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

    /// Removes the Keychain passphrase slot under `id`, then the metadata,
    /// then the private/public key files. A missing slot or missing files are
    /// ignored (idempotent).
    ///
    /// The Keychain delete goes FIRST and is the one step allowed to abort the
    /// removal. A slot that outlives its metadata entry can never be found
    /// again: `SecretStore` has no enumeration (a deliberate limit, see its
    /// own doc), and every caller resolves the id it deletes out of
    /// `managed_keys.json` — so once the entry is gone, no screen and no code
    /// path reaches the passphrase. While the slot was deleted last, producing
    /// such an unreachable secret took nothing more than an ordinary key
    /// deletion against a Keychain that is there but not answering. Failing
    /// before the metadata write instead leaves the key fully listed, which
    /// the user can see and retry.
    ///
    /// The FILES stay best-effort and come last: if `persist` throws, at worst
    /// an orphaned file is left behind (harmless) — never a metadata entry
    /// pointing at files that no longer exist.
    public func remove(id: UUID, secrets: any SecretStore) throws {
        let keys = try all()
        let key = keys.first(where: { $0.id == id })
        try secrets.deletePassword(for: id)
        try persist(keys.filter { $0.id != id })
        // A `fileName` that does not address a file inside the key directory
        // resolves to nothing, so the deletions are skipped entirely rather
        // than aimed at whatever it points to.
        if let key, let priv = privateKeyURL(for: key) {
            try? FileManager.default.removeItem(at: priv)
            try? FileManager.default.removeItem(at: priv.appendingPathExtension("pub"))
        }
    }

    /// The private key file of `key` inside `keyDirectory`, or `nil` when the
    /// stored `fileName` is not a single path component.
    ///
    /// macSCP writes `managed_keys.json` itself and always stores a UUID
    /// there, so the `nil` case needs a hand-edited or tampered store file to
    /// happen at all. It is still the one place to close it: every caller
    /// that turns a managed key into a file goes through here, and
    /// `appendingPathComponent("../…")` would otherwise hand them a URL
    /// OUTSIDE the key directory — which they would then read from or delete.
    public func privateKeyURL(for key: ManagedKey) -> URL? {
        guard Self.isSinglePathComponent(key.fileName) else { return nil }
        return keyDirectory.appendingPathComponent(key.fileName)
    }

    /// A name that can only ever address a file directly inside the key
    /// directory. Rejects the empty name, `.`/`..`, and anything with a
    /// separator — including an absolute path, whose leading `/`
    /// `appendingPathComponent` would otherwise simply swallow.
    static func isSinglePathComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    /// The managed key whose private file is at `path`, or nil. Matches by the
    /// resolved absolute path of `keyDirectory/fileName` (tilde-expanded).
    public func key(forPath path: String) throws -> ManagedKey? {
        let target = Self.resolved(path)
        return try all().first {
            privateKeyURL(for: $0)?.standardizedFileURL.path == target
        }
    }

    /// The managed key that `path` names but that `key(forPath:)` can never
    /// return, because its stored `fileName` is not a single path component and
    /// so addresses no file inside the key directory at all.
    ///
    /// Matched against the naive `keyDirectory + fileName` join such an entry
    /// was presumably written with, so a caller can tell "macSCP manages no key
    /// at this path" apart from "macSCP manages this key, but its metadata
    /// entry is unusable" — the difference between silently skipping a key and
    /// reporting it. The joined path is only ever COMPARED here: it is never
    /// opened, and no other store API will resolve such an entry to a file.
    func keyWithUnusableFileName(forPath path: String) throws -> ManagedKey? {
        let target = Self.resolved(path)
        return try all().first {
            !Self.isSinglePathComponent($0.fileName)
                && keyDirectory.appendingPathComponent($0.fileName)
                    .standardizedFileURL.path == target
        }
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }

    private func persist(_ keys: [ManagedKey]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(keys).write(to: fileURL, options: .atomic)
    }
}
