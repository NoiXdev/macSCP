import Crypto
import Foundation
import SwiftASN1
import _CryptoExtras

/// The two ways a PEM private key is encrypted on disk: the legacy RFC 1421
/// headers OpenSSL wrote before PKCS#8, and PBES2 (RFC 8018).
///
/// Both end in AES-CBC, which is the only symmetric cipher the stack carries
/// for this (design, "what the library stack offers"); everything else is
/// NAMED rather than attempted, because a user whose key is 3DES needs to be
/// told that, not told their passphrase was wrong.
enum PEMEncryption {
    typealias Failure = PEMPrivateKeyDecoder.DecodeError

    /// The refusal ceiling on PBKDF2 iterations. A hostile file must not be
    /// able to pin a core for minutes; every producer in the design table
    /// writes 2048.
    static let iterationCeiling = 10_000_000

    // MARK: - Legacy (Proc-Type / DEK-Info)

    /// `DEK-Info: <cipher>,<hex IV>` with `Proc-Type: 4,ENCRYPTED`.
    ///
    /// The key is OpenSSL's `EVP_BytesToKey` with MD5 and one iteration; the
    /// salt is the first 8 bytes of the IV.
    static func legacyDecrypt(body: Data, cipherName: String, ivHex: String,
                              passphrase: String?) throws(Failure) -> Data {
        let keyLength = try aesKeyLength(forCipherNamed: cipherName)
        guard let passphrase else { throw Failure.passphraseRequired }
        guard let iv = hexBytes(ivHex), iv.count == 16 else { throw Failure.notReadable(.malformed) }

        let secret = Data(passphrase.utf8)
        let salt = iv.prefix(8)
        var key = Data()
        var previous = Data()
        while key.count < keyLength {
            previous = Data(Insecure.MD5.hash(data: previous + secret + salt))
            key += previous
        }
        do {
            return try AES._CBC.decrypt(body,
                                        using: SymmetricKey(data: key.prefix(keyLength)),
                                        iv: try AES._CBC.IV(ivBytes: iv))
        } catch {
            // Neither legacy PEM nor PBES2 carries a MAC, so a bad key shows
            // up here as a PKCS#7 padding failure — indistinguishable from
            // any other reason the plaintext is not a plaintext.
            throw Failure.wrongPassphrase
        }
    }

    /// The cipher named in a `DEK-Info` header, as an AES key length.
    ///
    /// Every string thrown here is a literal in this switch, never the file's
    /// own bytes: a header can claim any cipher name, and the payload ends up
    /// in a user-visible message.
    private static func aesKeyLength(forCipherNamed name: String) throws(Failure) -> Int {
        switch name.uppercased() {
        case "AES-128-CBC": return 16
        case "AES-192-CBC": return 24
        case "AES-256-CBC": return 32
        case "DES-CBC": throw Failure.notReadable(.cipher("DES-CBC"))
        case "DES-EDE3-CBC": throw Failure.notReadable(.cipher("DES-EDE3-CBC"))
        case "RC2-CBC": throw Failure.notReadable(.cipher("RC2-CBC"))
        default: throw Failure.notReadable(.cipher("unknown"))
        }
    }

    private static func hexBytes(_ text: String) -> Data? {
        let characters = Array(text.utf8)
        guard characters.count % 2 == 0, characters.isEmpty == false else { return nil }
        var bytes = Data()
        var index = 0
        while index < characters.count {
            guard let high = nibble(characters[index]), let low = nibble(characters[index + 1]) else {
                return nil
            }
            bytes.append(high << 4 | low)
            index += 2
        }
        return bytes
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return character - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    // MARK: - PBES2 (RFC 8018)

    static let pbes2: ASN1ObjectIdentifier = [1, 2, 840, 113_549, 1, 5, 13]
    static let pbkdf2: ASN1ObjectIdentifier = [1, 2, 840, 113_549, 1, 5, 12]
    static let scrypt: ASN1ObjectIdentifier = [1, 3, 6, 1, 4, 1, 11_591, 4, 11]
    static let desEDE3CBC: ASN1ObjectIdentifier = [1, 2, 840, 113_549, 3, 7]
    static let rc2CBC: ASN1ObjectIdentifier = [1, 2, 840, 113_549, 3, 2]
    static let aes128CBC: ASN1ObjectIdentifier = [2, 16, 840, 1, 101, 3, 4, 1, 2]
    static let aes192CBC: ASN1ObjectIdentifier = [2, 16, 840, 1, 101, 3, 4, 1, 22]
    static let aes256CBC: ASN1ObjectIdentifier = [2, 16, 840, 1, 101, 3, 4, 1, 42]
    /// PBES1 (RFC 8018 appendix A.3) — six OIDs under `pkcs-5`.
    static let pbes1: [ASN1ObjectIdentifier] = [1, 3, 4, 6, 10, 11].map { [1, 2, 840, 113_549, 1, 5, $0] }
    /// The PKCS#12 password-based schemes all sit under this arc.
    static let pkcs12PBEArc: [UInt] = [1, 2, 840, 113_549, 1, 12, 1]

    /// `EncryptedPrivateKeyInfo ::= SEQUENCE { AlgorithmIdentifier,
    /// OCTET STRING }`, decrypted to the PKCS#8 `PrivateKeyInfo` DER inside.
    static func pbes2Decrypt(encryptedPrivateKeyInfo node: ASN1Node,
                             passphrase: String?) throws(Failure) -> Data {
        let outer = try PEMDER.children(node)
        guard outer.count >= 2 else { throw Failure.notReadable(.malformed) }
        let algorithm = try PEMDER.children(outer[0])
        guard let schemeOID = algorithm.first else { throw Failure.notReadable(.malformed) }
        try requirePBES2(try PEMDER.oid(schemeOID))
        guard algorithm.count >= 2 else { throw Failure.notReadable(.malformed) }

        let parameters = try PEMDER.children(algorithm[1])
        guard parameters.count >= 2 else { throw Failure.notReadable(.malformed) }
        let derivation = try pbkdf2Parameters(parameters[0])
        let cipher = try cipherParameters(parameters[1])

        guard let passphrase else { throw Failure.passphraseRequired }
        let key: SymmetricKey
        do {
            key = try KDF.Insecure.PBKDF2.deriveKey(
                from: Data(passphrase.utf8), salt: derivation.salt, using: derivation.hash,
                // `rounds:` refuses anything under 210 000 (swift-crypto
                // 3.15.1). Every producer in the design table writes 2048, so
                // the checked entry point cannot read a real file; the
                // ceiling above is this reader's own bound instead.
                outputByteCount: cipher.keyLength, unsafeUncheckedRounds: derivation.rounds)
        } catch {
            throw Failure.notReadable(.malformed)
        }
        do {
            return try AES._CBC.decrypt(try PEMDER.octets(outer[1]),
                                        using: key, iv: try AES._CBC.IV(ivBytes: cipher.iv))
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.wrongPassphrase
        }
    }

    private static func requirePBES2(_ oid: ASN1ObjectIdentifier) throws(Failure) {
        if oid == pbes2 { return }
        if pbes1.contains(oid) { throw Failure.notReadable(.scheme("PBES1")) }
        if oid.oidComponents.starts(with: pkcs12PBEArc) { throw Failure.notReadable(.scheme("PKCS#12")) }
        throw Failure.notReadable(.scheme("unknown"))
    }

    private struct Derivation {
        let salt: Data
        let rounds: Int
        let hash: KDF.Insecure.PBKDF2.HashFunction
    }

    /// `PBKDF2-params ::= SEQUENCE { salt, iterationCount, keyLength
    /// OPTIONAL, prf AlgorithmIdentifier DEFAULT hmacWithSHA1 }`.
    private static func pbkdf2Parameters(_ node: ASN1Node) throws(Failure) -> Derivation {
        let algorithm = try PEMDER.children(node)
        guard let kdfOID = algorithm.first else { throw Failure.notReadable(.malformed) }
        switch try PEMDER.oid(kdfOID) {
        case pbkdf2: break
        case scrypt: throw Failure.notReadable(.scheme("scrypt"))
        default: throw Failure.notReadable(.scheme("unknown"))
        }
        guard algorithm.count >= 2 else { throw Failure.notReadable(.malformed) }
        let parameters = try PEMDER.children(algorithm[1])
        guard parameters.count >= 2 else { throw Failure.notReadable(.malformed) }
        let salt = try PEMDER.octets(parameters[0])
        let rounds = try PEMDER.integer(parameters[1])
        guard rounds > 0, rounds <= iterationCeiling else { throw Failure.notReadable(.malformed) }

        // The optional keyLength INTEGER may sit between the count and the
        // PRF; the cipher's own key length is what is used either way, so it
        // is skipped rather than read.
        var hash = KDF.Insecure.PBKDF2.HashFunction.insecureSHA1
        for parameter in parameters.dropFirst(2) where parameter.identifier == .sequence {
            let prf = try PEMDER.children(parameter)
            guard let prfOID = prf.first else { throw Failure.notReadable(.malformed) }
            hash = try hashFunction(forPRF: try PEMDER.oid(prfOID))
        }
        return Derivation(salt: salt, rounds: rounds, hash: hash)
    }

    /// RFC 8018 appendix B.1.2: the `hmacWith*` OIDs under `digestAlgorithm`.
    /// Absent means SHA-1 by the ASN.1 DEFAULT, which is what every producer
    /// in the design table relies on.
    private static func hashFunction(forPRF oid: ASN1ObjectIdentifier)
        throws(Failure) -> KDF.Insecure.PBKDF2.HashFunction {
        switch oid {
        case [1, 2, 840, 113_549, 2, 7]: return .insecureSHA1
        case [1, 2, 840, 113_549, 2, 9]: return .sha256
        case [1, 2, 840, 113_549, 2, 10]: return .sha384
        case [1, 2, 840, 113_549, 2, 11]: return .sha512
        default: throw Failure.notReadable(.scheme("unknown"))
        }
    }

    private struct CipherParameters {
        let keyLength: Int
        let iv: Data
    }

    private static func cipherParameters(_ node: ASN1Node) throws(Failure) -> CipherParameters {
        let algorithm = try PEMDER.children(node)
        guard let cipherOID = algorithm.first else { throw Failure.notReadable(.malformed) }
        let keyLength: Int
        switch try PEMDER.oid(cipherOID) {
        case aes128CBC: keyLength = 16
        case aes192CBC: keyLength = 24
        case aes256CBC: keyLength = 32
        case desEDE3CBC: throw Failure.notReadable(.cipher("DES-EDE3-CBC"))
        case rc2CBC: throw Failure.notReadable(.cipher("RC2-CBC"))
        default: throw Failure.notReadable(.cipher("unknown"))
        }
        guard algorithm.count >= 2 else { throw Failure.notReadable(.malformed) }
        let iv = try PEMDER.octets(algorithm[1])
        guard iv.count == 16 else { throw Failure.notReadable(.malformed) }
        return CipherParameters(keyLength: keyLength, iv: iv)
    }
}
