import Foundation
import Testing
@testable import macSCPCore

@Suite("SessionExportCodec")
struct SessionExportCodecTests {
    private func samplePayload(includesSecrets: Bool = false) -> SessionExportPayload {
        let groupID = UUID()
        return SessionExportPayload(
            includesSecrets: includesSecrets,
            groups: [ExportedGroup(id: groupID, name: "Prod")],
            sessions: [ExportedSession(
                id: UUID(), name: "wärter-01 🚀", host: "Web-01.example.COM",
                port: 2222, username: "deploy", authKind: .privateKey,
                keyPath: "/Users/x/.ssh/id_ed25519", groupID: groupID,
                password: includesSecrets ? "geh€im🔑" : nil)])
    }

    @Test func clearRoundtripPreservesPayload() throws {
        let payload = samplePayload()
        let data = try SessionExportCodec.encode(payload, password: nil)
        #expect(try SessionExportCodec.probe(data) == false)
        #expect(try SessionExportCodec.decode(data, password: nil) == payload)
    }

    @Test func encryptedRoundtripPreservesPayloadIncludingSecrets() throws {
        let payload = samplePayload(includesSecrets: true)
        let data = try SessionExportCodec.encode(payload, password: "päss wörd 🔒")
        #expect(try SessionExportCodec.probe(data) == true)
        let decoded = try SessionExportCodec.decode(data, password: "päss wörd 🔒")
        #expect(decoded == payload)
        // Plaintext must not leak into the encrypted file.
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("deploy"))
        #expect(!text.contains("geh€im"))
    }

    @Test func wrongPasswordFailsWithoutOracle() throws {
        let data = try SessionExportCodec.encode(samplePayload(), password: "right")
        #expect(throws: SessionExportError.wrongPasswordOrCorrupted) {
            _ = try SessionExportCodec.decode(data, password: "wrong")
        }
    }

    @Test func tamperedCiphertextFailsWithSameError() throws {
        let data = try SessionExportCodec.encode(samplePayload(), password: "pw")
        var envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var ciphertext = Data(base64Encoded: envelope["ciphertext"] as! String)!
        ciphertext[ciphertext.count / 2] ^= 0xFF
        envelope["ciphertext"] = ciphertext.base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: envelope)
        #expect(throws: SessionExportError.wrongPasswordOrCorrupted) {
            _ = try SessionExportCodec.decode(tampered, password: "pw")
        }
    }

    @Test func encryptedFileWithoutPasswordAsksForOne() throws {
        let data = try SessionExportCodec.encode(samplePayload(), password: "pw")
        #expect(throws: SessionExportError.passwordRequired) {
            _ = try SessionExportCodec.decode(data, password: nil)
        }
    }

    @Test func garbageAndForeignJSONAreRejected() throws {
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try SessionExportCodec.probe(Data("not json at all".utf8))
        }
        let foreign = Data(#"{"something":"else"}"#.utf8)
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try SessionExportCodec.decode(foreign, password: nil)
        }
    }

    @Test func newerVersionIsRejectedWithItsNumber() throws {
        let future = Data(#"{"format":"macscp-sessions","version":99,"encrypted":false,"payload":{}}"#.utf8)
        #expect(throws: SessionExportError.unsupportedVersion(99)) {
            _ = try SessionExportCodec.probe(future)
        }
    }

    /// Builds a syntactically well-formed encrypted envelope with the given
    /// `iterations` override, the same way `tamperedCiphertextFailsWithSameError`
    /// tampers the ciphertext — via `JSONSerialization` on a real encoded
    /// envelope, so salt/ciphertext stay well-formed and only `iterations`
    /// is hostile.
    private func envelopeData(iterationsOverride: Any) throws -> Data {
        let data = try SessionExportCodec.encode(samplePayload(), password: "pw")
        var envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        envelope["iterations"] = iterationsOverride
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    // MARK: - Hostile `iterations` (M9a final review, Finding 1 — critical)
    //
    // `decode` used to pass the file's `iterations` straight to
    // `CCKeyDerivationPBKDF` unchecked. A negative or absurdly large value
    // traps the process (reproduced: signal 5); an in-range multi-billion
    // value freezes the main thread for minutes. These three prove the
    // fixed `decode` rejects all of them up front as a structurally invalid
    // envelope — password-independent, so no oracle is introduced.

    @Test func negativeIterationsIsRejectedAsNotAnExportFile() throws {
        let data = try envelopeData(iterationsOverride: -1)
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try SessionExportCodec.decode(data, password: "pw")
        }
    }

    @Test func zeroIterationsIsRejectedAsNotAnExportFile() throws {
        let data = try envelopeData(iterationsOverride: 0)
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try SessionExportCodec.decode(data, password: "pw")
        }
    }

    @Test func absurdlyLargeIterationsIsRejectedAsNotAnExportFile() throws {
        let data = try envelopeData(iterationsOverride: 5_000_000_000)
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try SessionExportCodec.decode(data, password: "pw")
        }
    }

    @Test func inRangeVersionGarbageBodyIsRejectedAsNotAnExportFile() throws {
        let garbage = Data(#"{"format":"macscp-sessions","version":1,"encrypted":"yes"}"#.utf8)
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try SessionExportCodec.decode(garbage, password: nil)
        }
    }

    /// Table test: a grab-bag of structurally malformed encrypted envelopes
    /// — bad salt length, wrong-typed fields, truncated ciphertext base64 —
    /// each must throw a typed `SessionExportError`, never trap.
    @Test func malformedEncryptedEnvelopesAlwaysThrowATypedError() throws {
        let base = try JSONSerialization.jsonObject(
            with: SessionExportCodec.encode(samplePayload(), password: "pw")) as! [String: Any]

        var wrongSaltLength = base
        wrongSaltLength["salt"] = Data([0x01, 0x02]).base64EncodedString() // too short for AES-GCM key derivation
        var wrongTypedIterations = base
        wrongTypedIterations["iterations"] = "600000" // string, not a number
        var truncatedCiphertext = base
        let ciphertext = Data(base64Encoded: base["ciphertext"] as! String)!
        truncatedCiphertext["ciphertext"] = ciphertext.prefix(4).base64EncodedString()
        var nonBase64Salt = base
        nonBase64Salt["salt"] = "not-base64!!!"

        for malformed in [wrongSaltLength, wrongTypedIterations, truncatedCiphertext, nonBase64Salt] {
            let data = try JSONSerialization.data(withJSONObject: malformed)
            #expect(throws: SessionExportError.self) {
                _ = try SessionExportCodec.decode(data, password: "pw")
            }
        }
    }
}
