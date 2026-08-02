import CommonCrypto
import CryptoKit
import Foundation

/// Errors of every macSCP export/import format. Named after the first format
/// that used it (`macscp-sessions`, spec M9a); since M19 the login-set format
/// shares the same envelope, the same crypto, and therefore the same error
/// cases. Kept under its original name deliberately — renaming would be a
/// public API change with no benefit for callers.
public enum SessionExportError: Error, Equatable {
    case notAnExportFile
    case unsupportedVersion(Int)
    case passwordRequired
    /// Deliberately indistinguishable (spec M9a §1): GCM authentication
    /// fails the same way for a wrong password and a tampered file — no
    /// oracle for attackers, one honest message for users.
    case wrongPasswordOrCorrupted
    /// `SecRandomCopyBytes` failed while generating the export salt. Not
    /// password-related; surfaced through the same generic encode-failure
    /// message the UI already shows.
    case randomnessUnavailable
}

/// The versioned, optionally password-encrypted envelope every macSCP export
/// file is wrapped in (spec M9a §1+§2.1, made payload-agnostic in M19).
/// Pure functions — no file system, no keychain — so every branch is unit
/// testable.
///
/// A concrete format supplies only three things: its `format` discriminator,
/// its `currentVersion`, and the payload type. Everything security-relevant
/// (key derivation, AES-GCM, the structural envelope checks) lives here
/// exactly once, so a fix reaches every format at the same time.
public enum ExportEnvelopeCodec {
    /// OWASP-aligned for PBKDF2-HMAC-SHA256. Stored in the file, so future
    /// increases keep old files decodable.
    static let iterations = 600_000

    /// Generic over the payload rather than carrying it as pre-encoded
    /// `Data`: `JSONEncoder` writes `Data` as a base64 string, which would
    /// have turned the nested `payload` object into an opaque blob and
    /// changed every byte of the existing `.macscpsessions` format. As a
    /// type parameter the payload keeps encoding as a nested object, so the
    /// on-disk bytes are unchanged.
    private struct Envelope<P: Codable>: Codable {
        var format: String
        var version: Int
        var encrypted: Bool
        var payload: P?
        var salt: Data?
        var iterations: Int?
        var ciphertext: Data?
    }

    public static func encode<P: Codable>(
        _ payload: P, format: String, version: Int, password: String?
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let password else {
            return try encoder.encode(Envelope(
                format: format, version: version, encrypted: false,
                payload: payload))
        }
        var salt = Data(count: 16)
        let saltResult = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard saltResult == errSecSuccess else { throw SessionExportError.randomnessUnavailable }
        let key = try derivedKey(password: password, salt: salt, iterations: iterations)
        let plaintext = try JSONEncoder().encode(payload)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        return try encoder.encode(Envelope<P>(
            format: format, version: version, encrypted: true,
            salt: salt, iterations: iterations, ciphertext: sealed.combined))
    }

    /// True = encrypted. Lets the UI decide whether to ask for a password
    /// without attempting decryption. Takes the payload type (and validates
    /// format and version) so that probing is exactly as strict as decoding
    /// — a file the UI accepts here must not fail structurally later.
    public static func probe<P: Codable>(
        _ data: Data, as _: P.Type, format: String, currentVersion: Int
    ) throws -> Bool {
        try envelope(from: data, as: P.self, format: format,
                     currentVersion: currentVersion).encrypted
    }

    public static func decode<P: Codable>(
        _ data: Data, as _: P.Type, format: String, currentVersion: Int, password: String?
    ) throws -> P {
        let envelope = try envelope(from: data, as: P.self, format: format,
                                    currentVersion: currentVersion)
        if !envelope.encrypted {
            guard let payload = envelope.payload else { throw SessionExportError.notAnExportFile }
            return payload
        }
        guard let password else { throw SessionExportError.passwordRequired }
        guard let salt = envelope.salt, let iterations = envelope.iterations,
              let ciphertext = envelope.ciphertext else {
            throw SessionExportError.notAnExportFile
        }
        // A hostile or corrupt file can carry an out-of-range iteration
        // count (negative, zero, or absurdly large) that would otherwise
        // reach CommonCrypto: negative/huge values there trap the process,
        // and merely-large in-range values freeze the main thread for
        // minutes. This is a structural envelope check, not a password
        // check — it rejects before key derivation, so it adds no oracle.
        guard iterations > 0, iterations <= 10_000_000 else {
            throw SessionExportError.notAnExportFile
        }
        let key = try derivedKey(password: password, salt: salt, iterations: iterations)
        do {
            let sealed = try AES.GCM.SealedBox(combined: ciphertext)
            let plaintext = try AES.GCM.open(sealed, using: key)
            return try JSONDecoder().decode(P.self, from: plaintext)
        } catch {
            throw SessionExportError.wrongPasswordOrCorrupted
        }
    }

    /// Just enough of the envelope to validate format/version before we
    /// attempt to decode `payload` — a payload shape from a newer version
    /// may not decode as `P` at all, and that must report
    /// `unsupportedVersion`, not `notAnExportFile`.
    private struct EnvelopeHeader: Decodable {
        var format: String
        var version: Int
    }

    private static func envelope<P: Codable>(
        from data: Data, as _: P.Type, format: String, currentVersion: Int
    ) throws -> Envelope<P> {
        guard let header = try? JSONDecoder().decode(EnvelopeHeader.self, from: data),
              header.format == format else {
            throw SessionExportError.notAnExportFile
        }
        guard header.version <= currentVersion else {
            throw SessionExportError.unsupportedVersion(header.version)
        }
        guard let envelope = try? JSONDecoder().decode(Envelope<P>.self, from: data) else {
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
