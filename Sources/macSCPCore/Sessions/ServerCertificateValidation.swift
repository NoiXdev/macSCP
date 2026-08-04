import Crypto
import Foundation

/// A TLS certificate presented by a server, as a plain value — for the TOFU
/// decision and the prompt. `derBase64` is the leaf certificate's DER
/// encoding, from which the fingerprint is derived.
public struct ServerCertificateCandidate: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let derBase64: String
    public let subject: String
    public let issuer: String
    public let notAfter: Date?

    public init(host: String, port: Int, derBase64: String,
                subject: String, issuer: String, notAfter: Date?) {
        self.host = host
        self.port = port
        self.derBase64 = derBase64
        self.subject = subject
        self.issuer = issuer
        self.notAfter = notAfter
    }

    public var fingerprintSHA256: String {
        ServerCertificateFingerprint.sha256(ofDERBase64: derBase64) ?? "SHA256:?"
    }
}

/// SHA-256 over the DER bytes, formatted like the host-key fingerprints so
/// both prompts read the same.
public enum ServerCertificateFingerprint {
    public static func sha256(ofDERBase64 derBase64: String) -> String? {
        guard let der = Data(base64Encoded: derBase64) else { return nil }
        let digest = SHA256.hash(data: der)
        return "SHA256:" + Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

/// Errors from certificate verification. `mismatch` is a hard stop with no
/// override — same contract as `HostKeyError.mismatch`.
public enum ServerCertificateError: Error, Equatable, Sendable {
    case mismatch(host: String, expected: String, presented: String)
    case rejectedByUser
}

/// Pure, testable TOFU decision logic for server certificates. Mirrors
/// `HostKeyValidation` case for case, deliberately: it is the same question,
/// and a reader who knows one should recognise the other immediately.
public enum ServerCertificateValidation {
    public enum Outcome: Equatable {
        case accept
        case askUser
        case mismatch(expected: String)
    }

    /// - unknown (`known == nil`) → `.askUser`
    /// - known & identical → `.accept`
    /// - known & different → `.mismatch` (the decider is NEVER asked)
    public static func evaluate(
        candidate: ServerCertificateCandidate, known: TrustedCertificate?
    ) -> Outcome {
        guard let known else { return .askUser }
        if known.fingerprintSHA256 == candidate.fingerprintSHA256 { return .accept }
        return .mismatch(expected: known.fingerprintSHA256)
    }
}
