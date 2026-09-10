import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH
import Testing
import macSCPCore

/// The `openssh-key-v1` container the decoder's RSA components are handed to.
///
/// Citadel exposes no way to build an `Insecure.RSA.PrivateKey` from
/// components outside its own module (design, "what the library stack
/// offers"), so the route into a connection is a container its own parser
/// reads. This suite is that parser used as the oracle: what it reads back
/// must name the same public key `ssh-keygen -y` names for the source file.
///
/// `.timeLimit(.minutes(2))`: the padding case runs `ssh-keygen` eight
/// times. The trait bounds a hang, not a duration — nothing here reads a
/// clock.
@Suite("OpenSSHKeyContainer", .timeLimit(.minutes(2)))
struct OpenSSHKeyContainerTests {
    /// Decodes a fresh `-m PEM` RSA key and returns its components with the
    /// public key line OpenSSH derives from the same file.
    private func rsaFixture(in dir: URL)
        async throws -> (components: PEMPrivateKeyDecoder.RSAPrivateKeyComponents, blob: Data) {
        let path = try await PEMFixtures.sshKeygen(type: "rsa", bits: 2048, format: .pem,
                                                   passphrase: nil, in: dir)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let decoded = try PEMPrivateKeyDecoder.decode(text, passphrase: nil)
        guard case .rsa(let components) = decoded else {
            throw DecodedTheWrongKind(what: "\(decoded)")
        }
        let line = try await PEMFixtures.publicKeyLine(ofKeyAt: path, passphrase: nil)
        guard let blob = PEMFixtures.blob(ofPublicKeyLine: line) else {
            throw DecodedTheWrongKind(what: "a public key line without a base64 field")
        }
        return (components, blob)
    }

    private struct DecodedTheWrongKind: Error, CustomStringConvertible {
        let what: String
        var description: String { "expected an RSA key, got \(what)" }
    }

    /// The blob `ssh-keygen -y` prints is `string "ssh-rsa" ‖ mpint e ‖
    /// mpint n`. Citadel's `Insecure.RSA.PublicKey.write(to:)` — the
    /// `NIOSSHPublicKeyProtocol` requirement — writes the two mpints ONLY
    /// (`Algorithms/RSA.swift:191`, read 2026-09-10); the type field is
    /// written by whatever wraps it. So the field is written here, once,
    /// rather than assumed.
    private func blob(of publicKey: NIOSSHPublicKeyProtocol) -> Data {
        var buffer = ByteBuffer()
        _ = publicKey.write(to: &buffer)
        let mpints = Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
        return PEMFixtures.sshString(Data("ssh-rsa".utf8)) + mpints
    }

    /// The public-key blob the container itself carries.
    ///
    /// Citadel's `init(sshRsa:)` DISCARDS the public blob it parses and
    /// rebuilds the public key from the PRIVATE section instead
    /// (`SSHCert.swift:135-149`, read 2026-09-10), so a container whose
    /// public half is wrong parses without complaint. Measured: swapping `e`
    /// and `n` in the public blob left the suite GREEN until this read the
    /// field out of the container directly.
    private func publicBlob(inContainer container: String) throws -> Data {
        let body = container.split(separator: "\n").filter { $0.hasPrefix("-----") == false }.joined()
        let bytes = try #require(Data(base64Encoded: body, options: [.ignoreUnknownCharacters]))
        // `openssh-key-v1\0` is 15 bytes; then cipher, kdfname and kdfoptions
        // as SSH strings, then a uint32 key count, then the public blob.
        let afterMagic = Data(bytes.dropFirst(15))
        let head = try #require(PEMFixtures.sshStrings(in: afterMagic, count: 3))
        let consumed = head.reduce(0) { $0 + 4 + $1.count }
        let afterCount = Data(afterMagic.dropFirst(consumed + 4))
        return try #require(PEMFixtures.sshStrings(in: afterCount, count: 1)).first ?? Data()
    }

    @Test("the container parses through Citadel and names the same public key")
    func theContainerNamesTheSamePublicKey() async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try await rsaFixture(in: dir)

        let container = OpenSSHKeyContainer.unencryptedRSA(fixture.components, comment: "fixture")
        #expect(container.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
        let parsed = try Insecure.RSA.PrivateKey(sshRsa: container)
        // The private half, through Citadel's parser...
        #expect(blob(of: parsed.publicKey) == fixture.blob)
        // ...and the public half, which that parser never looks at.
        #expect(try publicBlob(inContainer: container) == fixture.blob)
    }

    /// `n` and `e` are the whole of what a public blob comparison can see, and
    /// the container also carries `d`. A signature the parsed private key
    /// makes, verified by a public key built from the ORACLE's blob, is what
    /// measures that `d` belongs to that modulus.
    ///
    /// `p`, `q` and `iqmp` stay unmeasured here: Citadel's reader consumes
    /// them and keeps only `n`, `e` and `d` (`OpenSSHKey.swift:26-50`, read
    /// 2026-09-10), so nothing it exposes can tell a right `q` from a wrong
    /// one.
    @Test("the private exponent in the container belongs to the public key OpenSSH names")
    func thePrivateExponentBelongsToThatModulus() async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try await rsaFixture(in: dir)

        let container = OpenSSHKeyContainer.unencryptedRSA(fixture.components, comment: "fixture")
        let parsed = try Insecure.RSA.PrivateKey(sshRsa: container)

        var oracle = ByteBuffer(bytes: fixture.blob)
        _ = oracle.readSlice(length: 4 + "ssh-rsa".utf8.count)   // the type field
        let oraclePublicKey = try Insecure.RSA.PublicKey.read(from: &oracle)

        let message = Data("macscp pem container fixture".utf8)
        // Named, because Citadel vends two `signature(for:)` overloads that
        // differ only in return type (`Signature` and `NIOSSHSignatureProtocol`).
        let signature: Insecure.RSA.Signature = try parsed.signature(for: message)
        #expect(oraclePublicKey.isValidSignature(signature, for: message))
    }

    /// Citadel's parser requires `paddingLength < cipher.blockSize`, which is
    /// 8 for cipher `none` (`OpenSSHKey.swift`, read 2026-09-10). A writer
    /// that pads an already-aligned section with a full block writes a file
    /// its own parser refuses. Walking the comment length through 0…7 walks
    /// the private section through all eight alignments, so exactly one of
    /// these eight cases is the aligned one — and it is red if the writer
    /// ever pads 8.
    @Test("the padding is shorter than the block for every remainder", arguments: 0..<8)
    func thePaddingStaysUnderTheBlock(_ extra: Int) async throws {
        let dir = try PEMFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try await rsaFixture(in: dir)

        let comment = "fixture" + String(repeating: "x", count: extra)
        let container = OpenSSHKeyContainer.unencryptedRSA(fixture.components, comment: comment)
        let parsed = try Insecure.RSA.PrivateKey(sshRsa: container)
        #expect(blob(of: parsed.publicKey) == fixture.blob)
    }
}
