import CommonCrypto
import CryptoKit
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

    public init(
        id: UUID, name: String, host: String, port: Int, username: String,
        authKind: StoredSession.AuthKind, keyPath: String?, groupID: UUID?,
        password: String?
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
    }
}

public enum SessionExportError: Error, Equatable {
    case notAnExportFile
    case unsupportedVersion(Int)
    case passwordRequired
    /// Deliberately indistinguishable (spec M9a §1): GCM authentication
    /// fails the same way for a wrong password and a tampered file — no
    /// oracle for attackers, one honest message for users.
    case wrongPasswordOrCorrupted
}

/// Versioned envelope codec for `.macscpsessions` files (spec M9a §1+§2.1).
/// Pure functions — no file system, no keychain — so every branch is unit
/// testable.
public enum SessionExportCodec {
    static let formatName = "macscp-sessions"
    static let currentVersion = 1
    /// OWASP-aligned for PBKDF2-HMAC-SHA256. Stored in the file, so future
    /// increases keep old files decodable.
    static let iterations = 600_000

    private struct Envelope: Codable {
        var format: String
        var version: Int
        var encrypted: Bool
        var payload: SessionExportPayload?
        var salt: Data?
        var iterations: Int?
        var ciphertext: Data?
    }

    public static func encode(_ payload: SessionExportPayload, password: String?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let password else {
            return try encoder.encode(Envelope(
                format: formatName, version: currentVersion, encrypted: false,
                payload: payload))
        }
        var salt = Data(count: 16)
        let saltResult = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        precondition(saltResult == errSecSuccess, "SecRandomCopyBytes failed")
        let key = try derivedKey(password: password, salt: salt, iterations: iterations)
        let plaintext = try JSONEncoder().encode(payload)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        return try encoder.encode(Envelope(
            format: formatName, version: currentVersion, encrypted: true,
            salt: salt, iterations: iterations, ciphertext: sealed.combined))
    }

    /// True = encrypted. Lets the UI decide whether to ask for a password
    /// without attempting decryption.
    public static func probe(_ data: Data) throws -> Bool {
        try envelope(from: data).encrypted
    }

    public static func decode(_ data: Data, password: String?) throws -> SessionExportPayload {
        let envelope = try envelope(from: data)
        if !envelope.encrypted {
            guard let payload = envelope.payload else { throw SessionExportError.notAnExportFile }
            return payload
        }
        guard let password else { throw SessionExportError.passwordRequired }
        guard let salt = envelope.salt, let iterations = envelope.iterations,
              let ciphertext = envelope.ciphertext else {
            throw SessionExportError.notAnExportFile
        }
        let key = try derivedKey(password: password, salt: salt, iterations: iterations)
        do {
            let sealed = try AES.GCM.SealedBox(combined: ciphertext)
            let plaintext = try AES.GCM.open(sealed, using: key)
            return try JSONDecoder().decode(SessionExportPayload.self, from: plaintext)
        } catch {
            throw SessionExportError.wrongPasswordOrCorrupted
        }
    }

    /// Just enough of the envelope to validate format/version before we
    /// attempt to decode `payload` — a payload shape from a newer version
    /// may not decode as `SessionExportPayload` at all, and that must report
    /// `unsupportedVersion`, not `notAnExportFile`.
    private struct EnvelopeHeader: Decodable {
        var format: String
        var version: Int
    }

    private static func envelope(from data: Data) throws -> Envelope {
        guard let header = try? JSONDecoder().decode(EnvelopeHeader.self, from: data),
              header.format == formatName else {
            throw SessionExportError.notAnExportFile
        }
        guard header.version <= currentVersion else {
            throw SessionExportError.unsupportedVersion(header.version)
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw SessionExportError.notAnExportFile
        }
        return envelope
    }

    private static func derivedKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordBytes = Array(password.utf8)
        var keyBytes = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltPtr in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                password, passwordBytes.count,
                saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                &keyBytes, keyBytes.count)
        }
        guard status == kCCSuccess else { throw SessionExportError.wrongPasswordOrCorrupted }
        return SymmetricKey(data: Data(keyBytes))
    }
}
