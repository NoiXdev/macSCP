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
}
