import Crypto
import Foundation
import SwiftASN1
import Testing
import _CryptoExtras
import macSCPCore

/// The PEM reader, measured against the producers on this machine.
///
/// Every key is generated at RUNTIME into a temporary directory the test
/// removes — nothing here is checked in. The oracle for a decoded key is
/// `ssh-keygen -y`, which derives the public key from the same file: if the
/// decoder read the wrong bytes, the public key it can build from them does
/// not match the one OpenSSH builds.
///
/// `.timeLimit(.minutes(2))`: the widest case generates eight keys through
/// `ssh-keygen` (including a 2048-bit RSA and a P-521), each of which is a
/// process launch. The trait is a bound on the SUITE hanging, not an
/// assertion about speed — no test here reads a clock.
@Suite("PEMPrivateKeyDecoder", .timeLimit(.minutes(2)))
struct PEMPrivateKeyDecoderTests {
    /// Five characters at least: ssh-keygen refuses a shorter one.
    ///
    /// It reaches `ssh-keygen -N` / `-P` and `openssl -passout pass:` inside
    /// an argument array, and `PEMPrivateKeyDecoder.decode`. It is never
    /// written into an `#expect` expression: `#expect` reports the SOURCE
    /// TEXT of what it checks, so a literal there would leak through a
    /// failure message.
    private static let passphrase = "fixture-passphrase-2026"

    /// An SSH mpint carries a leading `0x00` when the magnitude's top bit is
    /// set; the decoder's components are magnitudes without it.
    private func strippingLeadingZero(_ value: Data) -> Data {
        (value.count > 1 && value.first == 0x00) ? Data(value.dropFirst()) : value
    }

    private func curve(forBits bits: Int) -> PEMPrivateKeyDecoder.Curve? {
        switch bits {
        case 256: return .p256
        case 384: return .p384
        case 521: return .p521
        default: return nil
        }
    }

    // MARK: - 1: the eight shapes, plain and encrypted

    @Test("RSA and ECDSA decode in both PEM formats, plain and encrypted",
          arguments: PEMFixtures.Shape.all, [false, true])
    func decodesEveryShape(_ shape: PEMFixtures.Shape, _ encrypted: Bool) async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret: String? = encrypted ? Self.passphrase : nil
        let path = try await PEMFixtures.sshKeygen(type: shape.type, bits: shape.bits,
                                                   format: shape.format, passphrase: secret, in: dir)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(PEMPrivateKeyDecoder.isPEM(text))

        let decoded = try PEMPrivateKeyDecoder.decode(text, passphrase: secret)
        let line = try await PEMFixtures.publicKeyLine(ofKeyAt: path, passphrase: secret)
        let blob = try #require(PEMFixtures.blob(ofPublicKeyLine: line))
        let fields = try #require(PEMFixtures.sshStrings(in: blob, count: 3))

        switch decoded {
        case .rsa(let components):
            #expect(shape.type == "rsa")
            #expect(String(decoding: fields[0], as: UTF8.self) == "ssh-rsa")
            #expect(strippingLeadingZero(fields[1]) == components.e)
            #expect(strippingLeadingZero(fields[2]) == components.n)
        case .ecdsa(let curve, let scalar):
            #expect(shape.type == "ecdsa")
            #expect(curve == self.curve(forBits: shape.bits))
            let point: Data
            switch curve {
            case .p256: point = try P256.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation
            case .p384: point = try P384.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation
            case .p521: point = try P521.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation
            }
            #expect(String(decoding: fields[0], as: UTF8.self) == "ecdsa-sha2-nistp\(shape.bits)")
            #expect(String(decoding: fields[1], as: UTF8.self) == "nistp\(shape.bits)")
            #expect(fields[2] == point)
        case .ed25519:
            Issue.record("ssh-keygen wrote an Ed25519 key for \(shape), which it refuses to do (design table)")
        }
    }

    // MARK: - 2: Ed25519 through PKCS#8

    @Test("an Ed25519 PKCS#8 key decodes to its seed")
    func decodesEd25519PKCS8() throws {
        let generator = Curve25519.Signing.PrivateKey()
        let text = PEMFixtures.ed25519PKCS8PEM(seed: generator.rawRepresentation)
        let decoded = try PEMPrivateKeyDecoder.decode(text, passphrase: nil)
        guard case .ed25519(let seed) = decoded else {
            Issue.record("expected an Ed25519 key, got \(decoded)")
            return
        }
        #expect(seed == generator.rawRepresentation)
        let rebuilt = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        #expect(rebuilt.publicKey.rawRepresentation == generator.publicKey.rawRepresentation)
    }

    // MARK: - 3: SEC1 with a NAMED curve

    /// ssh-keygen writes SEC1 with EXPLICIT domain parameters; openssl's
    /// `ecparam -genkey` writes a named-curve OID (design table). Both
    /// spellings are in the wild, so both are read.
    @Test("a named-curve SEC1 key decodes")
    func decodesNamedCurveSEC1() async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("named-p256.pem").path(percentEncoded: false)
        try await PEMFixtures.openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", path])
        try PEMFixtures.restrict(path)
        let text = try String(contentsOfFile: path, encoding: .utf8)

        let decoded = try PEMPrivateKeyDecoder.decode(text, passphrase: nil)
        guard case .ecdsa(let curve, let scalar) = decoded else {
            Issue.record("expected an ECDSA key, got \(decoded)")
            return
        }
        #expect(curve == .p256)
        let line = try await PEMFixtures.publicKeyLine(ofKeyAt: path, passphrase: nil)
        let blob = try #require(PEMFixtures.blob(ofPublicKeyLine: line))
        let fields = try #require(PEMFixtures.sshStrings(in: blob, count: 3))
        #expect(fields[2] == (try P256.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation))
    }

    // MARK: - 4: legacy AES-256

    /// ssh-keygen writes only `AES-128-CBC` in the legacy header on this
    /// machine (design table); AES-256 comes from openssl.
    @Test("legacy AES-256 decodes with the passphrase")
    func decodesLegacyAES256() async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plainPath = try await PEMFixtures.sshKeygen(type: "rsa", bits: 2048, format: .pem,
                                                        passphrase: nil, in: dir)
        let encryptedPath = dir.appendingPathComponent("legacy-aes256.pem").path(percentEncoded: false)
        try await PEMFixtures.openssl(["rsa", "-in", plainPath, "-aes256",
                                       "-passout", "pass:\(Self.passphrase)", "-out", encryptedPath])

        let plainText = try String(contentsOfFile: plainPath, encoding: .utf8)
        let encryptedText = try String(contentsOfFile: encryptedPath, encoding: .utf8)
        #expect(encryptedText.contains("AES-256-CBC"))
        let fromPlain = try PEMPrivateKeyDecoder.decode(plainText, passphrase: nil)
        let fromEncrypted = try PEMPrivateKeyDecoder.decode(encryptedText, passphrase: Self.passphrase)
        #expect(fromPlain == fromEncrypted)
    }

    // MARK: - 5 and 6: what a passphrase does and does not open

    @Test("an encrypted key without a passphrase asks for one",
          arguments: [PEMFixtures.Format.pem, .pkcs8])
    func namesTheMissingPassphrase(_ format: PEMFixtures.Format) async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try await PEMFixtures.sshKeygen(type: "rsa", bits: 2048, format: format,
                                                   passphrase: Self.passphrase, in: dir)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var caught: PEMPrivateKeyDecoder.DecodeError?
        do {
            _ = try PEMPrivateKeyDecoder.decode(text, passphrase: nil)
        } catch let error as PEMPrivateKeyDecoder.DecodeError {
            caught = error
        }
        #expect(caught == .passphraseRequired)
    }

    @Test("a wrong passphrase is reported as wrong, not as garbage",
          arguments: [PEMFixtures.Format.pem, .pkcs8])
    func namesTheWrongPassphrase(_ format: PEMFixtures.Format) async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try await PEMFixtures.sshKeygen(type: "rsa", bits: 2048, format: format,
                                                   passphrase: Self.passphrase, in: dir)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let wrong = "not-the-" + Self.passphrase
        var caught: PEMPrivateKeyDecoder.DecodeError?
        do {
            _ = try PEMPrivateKeyDecoder.decode(text, passphrase: wrong)
        } catch let error as PEMPrivateKeyDecoder.DecodeError {
            caught = error
        }
        #expect(caught == .wrongPassphrase)
    }

    // MARK: - 7: a cipher the stack does not carry

    /// swift-crypto has no DES (design, "what the library stack offers").
    /// Both spellings of a 3DES file — the legacy header and PBES2 — must
    /// name the cipher rather than fail as a bad passphrase.
    @Test("DES-EDE3 is named, not attempted", arguments: [PEMFixtures.Format.pem, .pkcs8])
    func namesDESEDE3(_ format: PEMFixtures.Format) async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plainPath = try await PEMFixtures.sshKeygen(type: "rsa", bits: 2048, format: .pem,
                                                        passphrase: nil, in: dir)
        let path = dir.appendingPathComponent("des3-\(format.rawValue).pem").path(percentEncoded: false)
        switch format {
        case .pem:
            try await PEMFixtures.openssl(["rsa", "-in", plainPath, "-des3",
                                           "-passout", "pass:\(Self.passphrase)", "-out", path])
        case .pkcs8:
            try await PEMFixtures.openssl(["pkcs8", "-topk8", "-v2", "des3", "-in", plainPath,
                                           "-passout", "pass:\(Self.passphrase)", "-out", path])
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var caught: PEMPrivateKeyDecoder.DecodeError?
        do {
            _ = try PEMPrivateKeyDecoder.decode(text, passphrase: Self.passphrase)
        } catch let error as PEMPrivateKeyDecoder.DecodeError {
            caught = error
        }
        #expect(caught == .notReadable(.cipher("DES-EDE3-CBC")))
    }

    // MARK: - 8: what is not a key this reader opens

    @Test("a PuTTY header is named")
    func namesPuTTY() {
        #expect(throws: PEMPrivateKeyDecoder.DecodeError.notReadable(.putty)) {
            try PEMPrivateKeyDecoder.decode("PuTTY-User-Key-File-3: ssh-ed25519\n", passphrase: nil)
        }
    }

    @Test("an unknown label is named")
    func namesAnUnknownLabel() {
        let text = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----"
        #expect(throws: PEMPrivateKeyDecoder.DecodeError.notReadable(.keyType("unknown"))) {
            try PEMPrivateKeyDecoder.decode(text, passphrase: nil)
        }
    }

    @Test("a body that is not DER is malformed")
    func namesAMalformedBody() {
        let text = "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----"
        #expect(throws: PEMPrivateKeyDecoder.DecodeError.notReadable(.malformed)) {
            try PEMPrivateKeyDecoder.decode(text, passphrase: nil)
        }
    }

    // MARK: - 9: the gate the loader asks

    @Test("isPEM tells PEM from OpenSSH and from noise")
    func isPEMSeparatesTheThreeCases() {
        #expect(PEMPrivateKeyDecoder.isPEM("-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----"))
        #expect(PEMPrivateKeyDecoder.isPEM("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----") == false)
        #expect(PEMPrivateKeyDecoder.isPEM("ssh-ed25519 AAAAC3Nz fixture") == false)
    }

    // MARK: - 10 and 11: a PBES2 file this machine's openssl cannot write

    /// LibreSSL 3.3.6 has neither `-v2prf` nor `-scrypt` (design table), so
    /// no producer here writes a PBES2 file with an EXPLICIT PRF. This test
    /// builds one. It therefore measures the decoder's OID table and its
    /// wiring — not an external producer, which is what every other case
    /// above measures.
    ///
    /// `declaredRounds` is what goes into the file; the key is always
    /// derived at `rounds`. They differ only for the ceiling case below,
    /// where the file is refused before any key is derived, so no key at the
    /// declared count is ever needed.
    private func pbes2SHA256PEM(pkcs8DER: Data, passphrase: String,
                                rounds: Int, declaredRounds: Int? = nil) throws -> String {
        let salt = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        let key = try KDF.Insecure.PBKDF2.deriveKey(
            from: Data(passphrase.utf8), salt: salt, using: .sha256,
            outputByteCount: 32, unsafeUncheckedRounds: rounds)
        let iv = AES._CBC.IV()
        let ciphertext = try AES._CBC.encrypt(pkcs8DER, using: key, iv: iv)

        let pbes2: ASN1ObjectIdentifier = [1, 2, 840, 113_549, 1, 5, 13]
        let pbkdf2: ASN1ObjectIdentifier = [1, 2, 840, 113_549, 1, 5, 12]
        let hmacSHA256: ASN1ObjectIdentifier = [1, 2, 840, 113_549, 2, 9]
        let aes256CBC: ASN1ObjectIdentifier = [2, 16, 840, 1, 101, 3, 4, 1, 42]

        var serializer = DER.Serializer()
        try serializer.appendConstructedNode(identifier: .sequence) { outer in
            try outer.appendConstructedNode(identifier: .sequence) { algorithm in
                try algorithm.serialize(pbes2)
                try algorithm.appendConstructedNode(identifier: .sequence) { parameters in
                    try parameters.appendConstructedNode(identifier: .sequence) { kdf in
                        try kdf.serialize(pbkdf2)
                        try kdf.appendConstructedNode(identifier: .sequence) { kdfParameters in
                            try kdfParameters.serialize(ASN1OctetString(contentBytes: ArraySlice(salt)))
                            try kdfParameters.serialize(declaredRounds ?? rounds)
                            try kdfParameters.appendConstructedNode(identifier: .sequence) { prf in
                                try prf.serialize(hmacSHA256)
                                try prf.serialize(ASN1Null())
                            }
                        }
                    }
                    try parameters.appendConstructedNode(identifier: .sequence) { scheme in
                        try scheme.serialize(aes256CBC)
                        try scheme.serialize(ASN1OctetString(contentBytes: ArraySlice(Data(iv))))
                    }
                }
            }
            try outer.serialize(ASN1OctetString(contentBytes: ArraySlice(ciphertext)))
        }
        let der = Data(serializer.serializedBytes)
        return "-----BEGIN ENCRYPTED PRIVATE KEY-----\n"
            + der.base64EncodedString(options: [.lineLength64Characters])
            + "\n-----END ENCRYPTED PRIVATE KEY-----\n"
    }

    @Test("a PBES2 file with an explicit SHA-256 PRF decodes")
    func decodesPBES2WithExplicitSHA256() async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plainPath = try await PEMFixtures.sshKeygen(type: "rsa", bits: 2048, format: .pkcs8,
                                                        passphrase: nil, in: dir)
        let plainText = try String(contentsOfFile: plainPath, encoding: .utf8)
        let plainDER = try #require(PEMFixtures.der(ofPEM: plainText))

        let built = try pbes2SHA256PEM(pkcs8DER: plainDER, passphrase: Self.passphrase, rounds: 2048)
        let fromBuilt = try PEMPrivateKeyDecoder.decode(built, passphrase: Self.passphrase)
        let fromPlain = try PEMPrivateKeyDecoder.decode(plainText, passphrase: nil)
        #expect(fromBuilt == fromPlain)
    }

    @Test("an iteration count above the ceiling is refused")
    func refusesAnAbsurdIterationCount() async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plainPath = try await PEMFixtures.sshKeygen(type: "rsa", bits: 2048, format: .pkcs8,
                                                        passphrase: nil, in: dir)
        let plainDER = try #require(PEMFixtures.der(ofPEM: try String(contentsOfFile: plainPath, encoding: .utf8)))
        let built = try pbes2SHA256PEM(pkcs8DER: plainDER, passphrase: Self.passphrase,
                                       rounds: 2048, declaredRounds: 10_000_001)
        var caught: PEMPrivateKeyDecoder.DecodeError?
        do {
            _ = try PEMPrivateKeyDecoder.decode(built, passphrase: Self.passphrase)
        } catch let error as PEMPrivateKeyDecoder.DecodeError {
            caught = error
        }
        #expect(caught == .notReadable(.malformed))
    }
}
