import Foundation

/// Reads a PEM private key file into key material.
///
/// Pure: text and passphrase in, components out. No file system, no
/// subprocess, no clock. The loader calls it when a key file begins with a
/// PEM boundary other than OpenSSH's — exactly where it refused such a file
/// unread until 2026-09-10.
///
/// What it cannot open it NAMES: a 3DES file is `.cipher("DES-EDE3-CBC")`,
/// not a wrong passphrase, so the message can carry the one command that
/// converts it. The design of 2026-09-10 has the table of what each producer
/// on this machine writes.
public enum PEMPrivateKeyDecoder {
    public enum Curve: Equatable, Sendable { case p256, p384, p521 }

    /// Big-endian magnitudes without a leading zero byte — what an SSH
    /// `mpint` carries once its sign byte is off.
    public struct RSAPrivateKeyComponents: Equatable, Sendable {
        public let n: Data, e: Data, d: Data, p: Data, q: Data, iqmp: Data

        public init(n: Data, e: Data, d: Data, p: Data, q: Data, iqmp: Data) {
            self.n = n
            self.e = e
            self.d = d
            self.p = p
            self.q = q
            self.iqmp = iqmp
        }
    }

    public enum DecodedPrivateKey: Equatable, Sendable {
        case rsa(RSAPrivateKeyComponents)
        /// The scalar, left-padded to 32 / 48 / 66 bytes.
        case ecdsa(curve: Curve, scalar: Data)
        /// The 32-byte seed.
        case ed25519(seed: Data)
    }

    public enum DecodeError: Error, Equatable, Sendable {
        /// Not a PEM file this decoder handles — including OpenSSH's own
        /// container, which Citadel reads.
        case notPEM
        case passphraseRequired
        case wrongPassphrase
        case notReadable(PEMReadFailure)
    }

    /// The one label this decoder hands back rather than reads.
    static let openSSHLabel = "OPENSSH PRIVATE KEY"

    /// True for `-----BEGIN <label>-----` with any label but OpenSSH's, and
    /// for a PuTTY file — which is not PEM, but is a key file this decoder
    /// can at least name.
    public static func isPEM(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(PEMArmor.puttyPrefix) { return true }
        return trimmed.hasPrefix("-----BEGIN ")
            && trimmed.hasPrefix("-----BEGIN \(openSSHLabel)-----") == false
    }

    public static func decode(_ text: String, passphrase: String?) throws -> DecodedPrivateKey {
        let armor = try PEMArmor.parse(text)
        guard armor.label != openSSHLabel else { throw DecodeError.notPEM }

        // Whether the DER below came out of a decryption. It is the only
        // thing that separates "this file is broken" from "that was the wrong
        // passphrase": neither legacy PEM nor PBES2 carries a MAC, so a wrong
        // key that happens to survive the padding check hands the parser
        // noise, and noise is `.malformed` everywhere else.
        let decrypted: Bool
        let der: Data
        switch armor.label {
        case "ENCRYPTED PRIVATE KEY":
            der = try PEMEncryption.pbes2Decrypt(
                encryptedPrivateKeyInfo: try PEMDER.parse(armor.body), passphrase: passphrase)
            decrypted = true
        case "RSA PRIVATE KEY", "EC PRIVATE KEY", "PRIVATE KEY":
            if armor.isLegacyEncrypted {
                let fields = (armor.headers["DEK-Info"] ?? "").split(separator: ",", maxSplits: 1)
                guard fields.count == 2 else { throw DecodeError.notReadable(.malformed) }
                der = try PEMEncryption.legacyDecrypt(
                    body: armor.body,
                    cipherName: fields[0].trimmingCharacters(in: .whitespaces),
                    ivHex: fields[1].trimmingCharacters(in: .whitespaces),
                    passphrase: passphrase)
                decrypted = true
            } else {
                der = armor.body
                decrypted = false
            }
        default:
            throw DecodeError.notReadable(.keyType("unknown"))
        }

        do {
            return try structure(der, label: armor.label)
        } catch {
            if decrypted, error == .notReadable(.malformed) { throw DecodeError.wrongPassphrase }
            throw error
        }
    }

    /// The DER, once any encryption is off it, by the label that named it.
    ///
    /// It is a separate function for a toolchain reason, not a design one, so
    /// do not inline it back: `decode` needs to turn a `.malformed` into a
    /// `.wrongPassphrase` only when the DER came out of a decryption, and
    /// writing that as `catch let error as DecodeError where decrypted && …`
    /// on a `do` block whose thrown type Swift has already INFERRED as
    /// `DecodeError` crashes Apple Swift 6.3.3 (swiftlang-6.3.3.1.3) with
    /// `Found ownership error?!` and `compile command failed due to signal 6`
    /// — an ownership-verifier assertion, not a diagnostic. With the switch
    /// behind a `throws(DecodeError)` function the caller's `catch` needs no
    /// `as` and no `where`, and the same code compiles.
    private static func structure(_ der: Data, label: String) throws(DecodeError) -> DecodedPrivateKey {
        switch label {
        case "RSA PRIVATE KEY":
            return .rsa(try PEMKeyStructures.rsaPKCS1(der))
        case "EC PRIVATE KEY":
            let (curve, scalar) = try PEMKeyStructures.ecSEC1(der, outerCurve: nil)
            return .ecdsa(curve: curve, scalar: scalar)
        default:
            // `PRIVATE KEY` and `ENCRYPTED PRIVATE KEY`; every other label has
            // already been refused by `decode`'s own switch.
            return try PEMKeyStructures.pkcs8(der)
        }
    }
}
