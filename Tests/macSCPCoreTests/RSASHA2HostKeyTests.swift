import Foundation
import NIOCore
import NIOSSH
import Testing
@testable import macSCPCore

/// Ungated proof for `RSASHA2HostKey` — the type that lets macSCP verify an
/// RFC 8332 RSA host key.
///
/// The gated rig test (`HostKeyTypeIntegrationTests`) drives the same code
/// through a real handshake, but only when Docker is up. These tests need
/// nothing beyond `ssh-keygen` and `openssl`, both of which ship with macOS,
/// and they exercise every step that handshake would: the blob parse, the
/// byte-exact re-serialization NIOSSH performs while building the exchange
/// hash, and the signature check itself.
///
/// The key material is generated per test into a temporary directory that is
/// removed again before the fixture is returned; nothing here is stored in
/// the repository.
@Suite("rsa-sha2-512 host-key verification")
struct RSASHA2HostKeyTests {
    // MARK: - Fixture

    /// One throwaway RSA key pair plus signatures over known data, all made
    /// by the system tools at test time.
    private struct Fixture {
        /// The line `ssh-keygen` wrote to `id_rsa.pub`, minus its comment:
        /// `"ssh-rsa AAAA…"`.
        let openSSHPublicKey: String
        /// The host key blob itself: `string "ssh-rsa"`, `mpint e`, `mpint n`.
        let publicKeyBlob: Data
        /// The bytes both signatures below were made over.
        let signedData: Data
        /// PKCS#1 v1.5 over SHA-512 — what an `rsa-sha2-512` signature blob
        /// carries.
        let sha512Signature: Data
        /// PKCS#1 v1.5 over SHA-256 — the same padding over the wrong
        /// digest, i.e. what `rsa-sha2-256` would carry.
        let sha256Signature: Data
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func makeFixture() throws -> Fixture {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-rsa-hostkey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let keyPath = dir.appendingPathComponent("id_rsa").path(percentEncoded: false)
        // `-m PEM` only changes how the PRIVATE key file is written, so that
        // `openssl dgst -sign` can read it; `id_rsa.pub` is the ordinary
        // OpenSSH blob either way, and it is the only half this suite parses.
        let keygenStatus = try run(
            "/usr/bin/ssh-keygen",
            ["-t", "rsa", "-b", "2048", "-m", "PEM", "-N", "", "-q",
             "-C", "macscp-rsa-hostkey-test", "-f", keyPath])
        #expect(keygenStatus == 0)

        let publicKeyLine = try String(contentsOfFile: keyPath + ".pub", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = publicKeyLine.split(separator: " ", omittingEmptySubsequences: true)
        let blob = try #require(Data(base64Encoded: String(fields[1])))

        let signedData = Data("macSCP rsa-sha2-512 host-key verification fixture".utf8)
        let dataPath = dir.appendingPathComponent("payload.bin").path(percentEncoded: false)
        try signedData.write(to: URL(fileURLWithPath: dataPath))

        func sign(digest: String, into name: String) throws -> Data {
            let signaturePath = dir.appendingPathComponent(name).path(percentEncoded: false)
            let status = try run(
                "/usr/bin/openssl",
                ["dgst", digest, "-sign", keyPath, "-out", signaturePath, dataPath])
            #expect(status == 0)
            return try Data(contentsOf: URL(fileURLWithPath: signaturePath))
        }

        return Fixture(
            openSSHPublicKey: fields[0...1].joined(separator: " "),
            publicKeyBlob: blob,
            signedData: signedData,
            sha512Signature: try sign(digest: "-sha512", into: "payload.sha512.sig"),
            sha256Signature: try sign(digest: "-sha256", into: "payload.sha256.sig"))
    }

    /// Splits a host key blob the way NIOSSH does before dispatching to a
    /// registered type: the leading `string` identifier is consumed by
    /// `readSSHHostKey`, and `read(from:)` sees only what follows.
    private static func parse(_ blob: Data) throws -> (identifier: String, key: RSASHA2HostKey) {
        let identifier = try #require(AgentWireFormat.leadingSSHString(from: blob))
        var body = ByteBuffer(bytes: AgentWireFormat.stripLeadingSSHString(from: blob))
        return (identifier, try RSASHA2HostKey.read(from: &body))
    }

    /// A signature blob typed as the SHA-1 algorithm, carrying bytes that do
    /// verify — the exact shape a downgrade would take. Its prefix is read
    /// off the key's blob prefix rather than spelled again: `ssh-rsa` names
    /// both the blob type and the SHA-1 signature algorithm, and that
    /// coincidence is the whole reason RFC 8332 needed a separate algorithm
    /// name. This type is never registered; the tests hand it to
    /// `isValidSignature` directly.
    private struct SHA1TypedSignature: NIOSSHSignatureProtocol {
        static var signaturePrefix: String { RSASHA2HostKey.publicKeyPrefix }

        struct NeverRead: Error {}

        let rawRepresentation: Data

        func write(to buffer: inout ByteBuffer) -> Int {
            buffer.writeBytes(rawRepresentation)
        }

        static func read(from buffer: inout ByteBuffer) throws -> SHA1TypedSignature {
            throw NeverRead()
        }
    }

    // MARK: - Identifiers

    /// The split the fork's `hostKeyAlgorithmNames` exists for: the key is
    /// NEGOTIATED under the SHA-2 name and its blob is TYPED with the RSA
    /// prefix. The negative assertion (the blob prefix is not an algorithm
    /// name) sits beside positive ones so it cannot go quiet if the names
    /// ever come back empty.
    @Test func theKeyIsOfferedUnderTheSHA2NameWhileItsBlobKeepsTheRSAPrefix() {
        let names = RSASHA2HostKey.hostKeyAlgorithmNames
        #expect(names == [RSASHA2Signature.signaturePrefix])
        #expect(names.count == 1)
        #expect(RSASHA2HostKey.publicKeyPrefix == "ssh-rsa")
        #expect(RSASHA2Signature.signaturePrefix == "rsa-sha2-512")
        #expect(names.contains(RSASHA2HostKey.publicKeyPrefix) == false)
    }

    // MARK: - Parsing and re-serialization

    @Test func theBlobsOwnIdentifierIsTheRSAPrefixAndItsBodyParses() throws {
        let fixture = try Self.makeFixture()
        let parsed = try Self.parse(fixture.publicKeyBlob)

        #expect(parsed.identifier == RSASHA2HostKey.publicKeyPrefix)
        // 2048-bit modulus: `mpint n` is 257 bytes (256 plus the leading
        // zero an mpint takes when the top bit is set), `mpint e` 3.
        #expect(parsed.key.rawRepresentation.count == 4 + 3 + 4 + 257)
    }

    /// The re-serialization NIOSSH performs while computing the exchange
    /// hash: `writeSSHHostKey` writes the blob prefix and then calls
    /// `write(to:)`, and the result must be byte-identical to what the
    /// server sent, or the hash — and with it the whole handshake — fails.
    /// Driven here through NIOSSH's own public round trip rather than the
    /// type's, so what is measured is the path the handshake takes.
    @Test func theBlobSurvivesTheRoundTripThatBuildsTheExchangeHash() throws {
        let fixture = try Self.makeFixture()
        HostKeyAlgorithms.registerOnce()

        let key = try NIOSSHPublicKey(openSSHPublicKey: fixture.openSSHPublicKey)

        #expect(String(openSSHPublicKey: key) == fixture.openSSHPublicKey)
    }

    @Test func aBlobWithoutItsModulusIsRejected() throws {
        let fixture = try Self.makeFixture()
        let body = [UInt8](AgentWireFormat.stripLeadingSSHString(from: fixture.publicKeyBlob))
        try #require(body.count > 4)
        // Keep `mpint e` — its own uint32 length prefix plus that many
        // bytes — and drop `mpint n` entirely.
        let exponentLength = body.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        var truncated = ByteBuffer(bytes: body.prefix(4 + exponentLength))

        #expect(throws: (any Error).self) {
            _ = try RSASHA2HostKey.read(from: &truncated)
        }
    }

    // MARK: - Verification

    @Test func aParsedHostKeyVerifiesTheSignatureItsPrivateHalfMade() throws {
        let fixture = try Self.makeFixture()
        let key = try Self.parse(fixture.publicKeyBlob).key

        let signature = RSASHA2Signature(rawRepresentation: fixture.sha512Signature)

        #expect(key.isValidSignature(signature, for: fixture.signedData))
    }

    @Test func oneFlippedSignatureByteFailsVerification() throws {
        let fixture = try Self.makeFixture()
        let key = try Self.parse(fixture.publicKeyBlob).key
        var tampered = fixture.sha512Signature
        tampered[tampered.startIndex] ^= 0x01

        let signature = RSASHA2Signature(rawRepresentation: tampered)

        #expect(key.isValidSignature(signature, for: fixture.signedData) == false)
        // Positive control beside the negative one: the untouched signature
        // over the same data verifies, so a `false` above is the flipped bit
        // and not a fixture that never verified at all.
        #expect(key.isValidSignature(
            RSASHA2Signature(rawRepresentation: fixture.sha512Signature),
            for: fixture.signedData))
    }

    @Test func oneFlippedDataByteFailsVerification() throws {
        let fixture = try Self.makeFixture()
        let key = try Self.parse(fixture.publicKeyBlob).key
        var tampered = fixture.signedData
        tampered[tampered.startIndex] ^= 0x01
        let signature = RSASHA2Signature(rawRepresentation: fixture.sha512Signature)

        #expect(key.isValidSignature(signature, for: tampered) == false)
        #expect(key.isValidSignature(signature, for: fixture.signedData))
    }

    /// Pins the digest. The same key, the same data, the same PKCS#1 v1.5
    /// padding — only SHA-256 instead of SHA-512, which is what an
    /// `rsa-sha2-256` signature carries. A verifier that hashed with
    /// anything but SHA-512 would accept it.
    @Test func aSHA256SignatureIsRejectedByTheSHA512Verifier() throws {
        let fixture = try Self.makeFixture()
        let key = try Self.parse(fixture.publicKeyBlob).key

        #expect(key.isValidSignature(
            RSASHA2Signature(rawRepresentation: fixture.sha256Signature),
            for: fixture.signedData) == false)
        #expect(key.isValidSignature(
            RSASHA2Signature(rawRepresentation: fixture.sha512Signature),
            for: fixture.signedData))
    }

    /// The SHA-1 route stays closed by construction: a signature typed
    /// `ssh-rsa` is refused even when its bytes are the very ones that
    /// verify. macSCP registers no `ssh-rsa` signature type, so NIOSSH would
    /// reject such a blob before this point — this is the second lock, on
    /// the type itself.
    @Test func aSignatureTypedForSHA1IsRejectedEvenThoughItsBytesAreValid() throws {
        let fixture = try Self.makeFixture()
        let key = try Self.parse(fixture.publicKeyBlob).key

        #expect(key.isValidSignature(
            SHA1TypedSignature(rawRepresentation: fixture.sha512Signature),
            for: fixture.signedData) == false)
        #expect(key.isValidSignature(
            RSASHA2Signature(rawRepresentation: fixture.sha512Signature),
            for: fixture.signedData))
    }
}
