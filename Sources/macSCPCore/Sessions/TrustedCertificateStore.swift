import Foundation

/// A remembered server certificate (TOFU). The fingerprint is derived from
/// the DER bytes, never stored separately — one source of truth.
public struct TrustedCertificate: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let derBase64: String
    public let subject: String
    public let issuer: String
    public let notAfter: Date?
    public let addedAt: Date?

    /// Host is stored lowercased — comparisons are case-insensitive.
    public init(host: String, port: Int, derBase64: String,
                subject: String, issuer: String, notAfter: Date?,
                addedAt: Date? = Date()) {
        self.host = host.lowercased()
        self.port = port
        self.derBase64 = derBase64
        self.subject = subject
        self.issuer = issuer
        self.notAfter = notAfter
        self.addedAt = addedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Via the normalizing init — otherwise decode would be a second,
        // un-normalized write path (the finding that shaped KnownHostKey).
        self.init(
            host: try container.decode(String.self, forKey: .host),
            port: try container.decode(Int.self, forKey: .port),
            derBase64: try container.decode(String.self, forKey: .derBase64),
            subject: try container.decode(String.self, forKey: .subject),
            issuer: try container.decode(String.self, forKey: .issuer),
            notAfter: try container.decodeIfPresent(Date.self, forKey: .notAfter),
            addedAt: try container.decodeIfPresent(Date.self, forKey: .addedAt))
    }

    private enum CodingKeys: String, CodingKey {
        case host, port, derBase64, subject, issuer, notAfter, addedAt
    }

    public var fingerprintSHA256: String {
        ServerCertificateFingerprint.sha256(ofDERBase64: derBase64) ?? "SHA256:?"
    }
}

/// JSON persistence of trusted server certificates. Same pattern as
/// `KnownHostsStore`: stateless, atomic writes, single-app assumption.
public struct TrustedCertificateStore: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private var fileURL: URL {
        directory.appendingPathComponent("trusted-certificates.json")
    }

    public func find(host: String, port: Int) throws -> TrustedCertificate? {
        let wanted = host.lowercased()
        return try allCertificates().first { $0.host == wanted && $0.port == port }
    }

    public func upsert(_ certificate: TrustedCertificate) throws {
        var all = try allCertificates()
        all.removeAll { $0.host == certificate.host && $0.port == certificate.port }
        all.append(certificate)
        try write(all)
    }

    public func allCertificates() throws -> [TrustedCertificate] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([TrustedCertificate].self, from: data)
    }

    public func remove(host: String, port: Int) throws {
        let wanted = host.lowercased()
        var all = try allCertificates()
        all.removeAll { $0.host == wanted && $0.port == port }
        try write(all)
    }

    private func write(_ certificates: [TrustedCertificate]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(certificates).write(to: fileURL, options: .atomic)
    }
}
