import BigInt
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
/// `.timeLimit(.minutes(2))`: the widest test is `decodesEveryShape`, which
/// expands to 16 cases — `PEMFixtures.Shape.all` is eight, times plain and
/// encrypted — and every case generates one key with `ssh-keygen` and reads it
/// back with `ssh-keygen -y`: 16 keys, 32 process starts, four of them
/// 2048-bit RSA and four P-521. Counted against `Shape.all` and the body of
/// that test on 2026-09-10. The trait is a bound on a HANG, not an assertion
/// about speed — no test here reads a clock.
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

    /// `p`, `q` and `iqmp` are in NO public key, so `ssh-keygen -y` — the
    /// oracle every other component here is measured against — cannot see
    /// them at all. The arithmetic can, and it needs no external producer:
    /// RFC 8017 §3.2 says `n = p·q` and, for the CRT coefficient OpenSSH
    /// calls `iqmp`, `q⁻¹ mod p`, i.e. `iqmp·q ≡ 1 (mod p)`.
    ///
    /// Together the two identities pin which INTEGER of the PKCS#1 SEQUENCE
    /// each field was read from: the first is red if `p` or `q` came from the
    /// wrong index, and the second is red for a swap of the two (which the
    /// first cannot see, since `p·q = q·p`) and for `dq` read as `iqmp`.
    ///
    /// Each expectation is a `Bool` computed first: `#expect` reports the
    /// values of what it compares, and these three are private key material.
    private func expectTheFactorsBelongTo(_ components: PEMPrivateKeyDecoder.RSAPrivateKeyComponents,
                                          sourceLocation: SourceLocation = #_sourceLocation) {
        let n = BigUInt(components.n)
        let p = BigUInt(components.p)
        let q = BigUInt(components.q)
        let iqmp = BigUInt(components.iqmp)
        let primesMultiplyToTheModulus = p * q == n
        #expect(primesMultiplyToTheModulus, sourceLocation: sourceLocation)
        let coefficientInvertsQModuloP = p > 0 && (iqmp * q) % p == 1
        #expect(coefficientInvertsQModuloP, sourceLocation: sourceLocation)
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
        // Bool first, here and below: `#expect` reports the source text AND the
        // values of what it checks, and `text` is a private key file.
        let readsAsPEM = PEMPrivateKeyDecoder.isPEM(text)
        #expect(readsAsPEM)

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
            expectTheFactorsBelongTo(components)
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
            Issue.record("expected an Ed25519 key, got \(PEMFixtures.kind(of: decoded))")
            return
        }
        let seedIsTheGeneratorSeed = seed == generator.rawRepresentation
        #expect(seedIsTheGeneratorSeed)
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
            Issue.record("expected an ECDSA key, got \(PEMFixtures.kind(of: decoded))")
            return
        }
        #expect(curve == .p256)
        let line = try await PEMFixtures.publicKeyLine(ofKeyAt: path, passphrase: nil)
        let blob = try #require(PEMFixtures.blob(ofPublicKeyLine: line))
        let fields = try #require(PEMFixtures.sshStrings(in: blob, count: 3))
        // The point is built in a `let` so the scalar it is built FROM is not
        // a subexpression of the expectation.
        let point = try P256.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation
        #expect(fields[2] == point)
    }

    // MARK: - 3b: PKCS#8 whose OUTER parameters name no curve

    /// A PKCS#8 `PrivateKeyInfo` around a SEC1 `ECPrivateKey`, with the outer
    /// `AlgorithmIdentifier` parameters written as `NULL`. No producer on this
    /// machine writes that shape, so it is built here; it is the file that
    /// separates "the outer parameters are not a curve this reader names" from
    /// "nothing in this file says which curve it is".
    private func pkcs8PEM(aroundECPrivateKey der: Data) throws -> String {
        let idEcPublicKey: ASN1ObjectIdentifier = [1, 2, 840, 10_045, 2, 1]
        var serializer = DER.Serializer()
        try serializer.appendConstructedNode(identifier: .sequence) { outer in
            try outer.serialize(Int(0))                       // version
            try outer.appendConstructedNode(identifier: .sequence) { algorithm in
                try algorithm.serialize(idEcPublicKey)
                try algorithm.serialize(ASN1Null())           // not a curve
            }
            try outer.serialize(ASN1OctetString(contentBytes: ArraySlice(der)))
        }
        let wrapped = Data(serializer.serializedBytes)
        return "-----BEGIN PRIVATE KEY-----\n"
            + wrapped.base64EncodedString(options: [.lineLength64Characters])
            + "\n-----END PRIVATE KEY-----\n"
    }

    /// ssh-keygen writes the EC domain parameters in exactly ONE of the two
    /// places, and which one depends on the format. Measured 2026-09-10 with
    /// `openssl asn1parse` against this machine's ssh-keygen: `-m PKCS8` puts
    /// the `SpecifiedECDomain` in the OUTER `AlgorithmIdentifier` and writes an
    /// inner `ECPrivateKey` with NO `[0] parameters`, while `-m PEM` writes the
    /// SEC1 structure alone with the domain inside its own `[0]`. So an outer
    /// `AlgorithmIdentifier` this reader cannot turn into a curve is not a
    /// refusal by itself — the inner structure may still say which curve it is,
    /// and it is the one SEC1 prefers when both are there.
    @Test("a PKCS#8 EC key whose outer parameters name no curve reads the inner ones")
    func readsTheInnerParametersWhenTheOuterOnesNameNoCurve() async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try await PEMFixtures.sshKeygen(type: "ecdsa", bits: 256, format: .pem,
                                                   passphrase: nil, in: dir)
        let sec1Text = try String(contentsOfFile: path, encoding: .utf8)
        let sec1DER = try #require(PEMFixtures.der(ofPEM: sec1Text))

        // The positive check beside the point of the test: this file only
        // measures the fallback while the inner structure really does carry
        // parameters of its own. If ssh-keygen ever stops writing them, this
        // goes red rather than passing about nothing.
        let sec1Node = try DER.parse(Array(sec1DER))
        guard case .constructed(let sec1Children) = sec1Node.content else {
            Issue.record("the SEC1 body is not a SEQUENCE")
            return
        }
        let innerCarriesItsOwnParameters = sec1Children.contains {
            $0.identifier.tagClass == .contextSpecific && $0.identifier.tagNumber == 0
        }
        #expect(innerCarriesItsOwnParameters)

        let wrapped = try pkcs8PEM(aroundECPrivateKey: sec1DER)
        let fromWrapped = try PEMPrivateKeyDecoder.decode(wrapped, passphrase: nil)
        let fromSEC1 = try PEMPrivateKeyDecoder.decode(sec1Text, passphrase: nil)
        guard case .ecdsa(let curve, _) = fromWrapped else {
            Issue.record("expected an ECDSA key, got \(PEMFixtures.kind(of: fromWrapped))")
            return
        }
        #expect(curve == .p256)
        // Bool first: `DecodedPrivateKey` carries the scalar, and `#expect`
        // reports the values of what it compares.
        let bothReadTheSameKey = fromWrapped == fromSEC1
        #expect(bothReadTheSameKey)
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
        // Bool first: `encryptedText` is the encrypted key file, and
        // `DecodedPrivateKey` carries `d`, `p` and `q`.
        let headerNamesAES256 = encryptedText.contains("AES-256-CBC")
        #expect(headerNamesAES256)
        let fromPlain = try PEMPrivateKeyDecoder.decode(plainText, passphrase: nil)
        let fromEncrypted = try PEMPrivateKeyDecoder.decode(encryptedText, passphrase: Self.passphrase)
        let bothReadTheSameKey = fromPlain == fromEncrypted
        #expect(bothReadTheSameKey)
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

    // MARK: - 8b: what is not a PEM file at all

    /// `.notPEM` is the answer for a file this decoder does not own, and it
    /// has two sources: OpenSSH's own container, which Citadel reads and which
    /// `decode` hands back by LABEL, and text that carries no `-----BEGIN`
    /// boundary at all, which `PEMArmor.parse` refuses before any label
    /// exists. Both are here because neither was measured before.
    @Test("an OpenSSH container is handed back rather than read")
    func namesAnOpenSSHContainerAsNotPEM() async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // No `-m`: this is ssh-keygen's default output, `openssh-key-v1`.
        let path = try await PEMFixtures.sshKeygen(type: "ed25519", bits: nil, format: nil,
                                                   passphrase: nil, in: dir)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        // The positive check beside the two negative ones: without it, a
        // fixture that stopped producing an OpenSSH container would leave
        // `isPEM == false` and `.notPEM` true for an entirely different
        // reason, and this test would pass about nothing. Bool first — `text`
        // is a private key file.
        let isAnOpenSSHContainer = text.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----")
        #expect(isAnOpenSSHContainer)
        let readsAsPEM = PEMPrivateKeyDecoder.isPEM(text)
        #expect(readsAsPEM == false)

        var caught: PEMPrivateKeyDecoder.DecodeError?
        do {
            _ = try PEMPrivateKeyDecoder.decode(text, passphrase: nil)
        } catch let error as PEMPrivateKeyDecoder.DecodeError {
            caught = error
        }
        #expect(caught == .notPEM)
    }

    @Test("text without a PEM boundary is not PEM",
          arguments: ["ssh-ed25519 AAAAC3Nz fixture\n", "", "\n   \n\t\n", "not a key at all\n"])
    func namesNoiseAsNotPEM(_ noise: String) {
        #expect(PEMPrivateKeyDecoder.isPEM(noise) == false)
        #expect(throws: PEMPrivateKeyDecoder.DecodeError.notPEM) {
            try PEMPrivateKeyDecoder.decode(noise, passphrase: nil)
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
        let bothReadTheSameKey = fromBuilt == fromPlain
        #expect(bothReadTheSameKey)
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
