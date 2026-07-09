import Foundation

/// Gemerkter Host-Key (TOFU). Der Fingerprint ist aus dem Blob abgeleitet.
public struct KnownHostKey: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let keyType: String
    public let publicKeyBase64: String

    /// Host wird lowercased gespeichert — Vergleiche sind case-insensitiv.
    public init(host: String, port: Int, keyType: String, publicKeyBase64: String) {
        self.host = host.lowercased()
        self.port = port
        self.keyType = keyType
        self.publicKeyBase64 = publicKeyBase64
    }

    public var fingerprintSHA256: String {
        HostKeyFingerprint.sha256(ofKeyBlobBase64: publicKeyBase64) ?? "SHA256:?"
    }
}

/// JSON-Persistenz der bekannten Host-Keys (Muster wie SessionStore:
/// zustandslos, atomare Writes, Single-App-Annahme).
public struct KnownHostsStore: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private var fileURL: URL {
        directory.appendingPathComponent("known_hosts.json")
    }

    public func find(host: String, port: Int) throws -> KnownHostKey? {
        try all().first { $0.host == host.lowercased() && $0.port == port }
    }

    public func upsert(_ key: KnownHostKey) throws {
        var keys = try all()
        keys.removeAll { $0.host == key.host && $0.port == key.port }
        keys.append(key)
        try persist(keys)
    }

    private func all() throws -> [KnownHostKey] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([KnownHostKey].self, from: data)
    }

    private func persist(_ keys: [KnownHostKey]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(keys).write(to: fileURL, options: .atomic)
    }
}
