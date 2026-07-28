import Crypto
import Foundation
import Testing
@testable import macSCPCore

/// Pure wire-format tests for the ssh-agent protocol (draft-miller). All
/// fixtures are hand-built byte arrays — no live agent involved.
@Suite("SSHAgentCodec")
struct SSHAgentCodecTests {
    // MARK: - Hand-built wire fixtures

    private static func uint32BE(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff),
         UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }

    private static func sshString(_ bytes: [UInt8]) -> [UInt8] {
        uint32BE(UInt32(bytes.count)) + bytes
    }

    private static func sshString(_ string: String) -> [UInt8] {
        sshString(Array(string.utf8))
    }

    /// Builds a full length-prefixed frame: uint32 length + [type] + payload.
    private static func frame(type: UInt8, payload: [UInt8] = []) -> Data {
        let body = [type] + payload
        return Data(uint32BE(UInt32(body.count)) + body)
    }

    /// A plausible (structurally valid, not cryptographically real) OpenSSH
    /// public-key blob: `string key-type` + `string key-data`.
    private static func fakeBlob(keyType: String, keyData: [UInt8]) -> [UInt8] {
        sshString(keyType) + sshString(keyData)
    }

    private static func expectedFingerprint(ofBlob blob: [UInt8]) -> String {
        let digest = SHA256.hash(data: Data(blob))
        let b64 = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:" + b64
    }

    // MARK: - Request builders

    @Test func requestIdentitiesFrameBytes() {
        let frame = SSHAgentCodec.requestIdentitiesFrame()
        #expect(Array(frame) == [0, 0, 0, 1, 11])
    }

    @Test func signRequestFrameLayout() {
        let blob = Data("AB".utf8)
        let payload = Data("XYZ".utf8)
        let frame = SSHAgentCodec.signRequestFrame(publicKeyBlob: blob, data: payload, flags: 4)

        let expectedBody: [UInt8] = [13]
            + Self.sshString(Array(blob))
            + Self.sshString(Array(payload))
            + Self.uint32BE(4)
        let expected = Data(Self.uint32BE(UInt32(expectedBody.count)) + expectedBody)

        #expect(frame == expected)
    }

    // MARK: - parseIdentitiesAnswer

    @Test func parseIdentitiesTwoKeys() throws {
        let blob1 = Self.fakeBlob(keyType: "ssh-ed25519", keyData: [0x01, 0x02, 0x03])
        let blob2 = Self.fakeBlob(keyType: "ssh-ed25519", keyData: [0x04, 0x05, 0x06, 0x07])

        var payload = Self.uint32BE(2)
        payload += Self.sshString(blob1) + Self.sshString("first comment")
        payload += Self.sshString(blob2) + Self.sshString("second comment")

        let frame = Self.frame(type: 12, payload: payload)
        let identities = try SSHAgentCodec.parseIdentitiesAnswer(frame)

        #expect(identities.count == 2)
        #expect(identities[0].publicKeyBlob == Data(blob1))
        #expect(identities[0].comment == "first comment")
        #expect(identities[0].keyType == "ssh-ed25519")
        #expect(identities[0].fingerprintSHA256 == Self.expectedFingerprint(ofBlob: blob1))

        #expect(identities[1].publicKeyBlob == Data(blob2))
        #expect(identities[1].comment == "second comment")
        #expect(identities[1].keyType == "ssh-ed25519")
        #expect(identities[1].fingerprintSHA256 == Self.expectedFingerprint(ofBlob: blob2))
    }

    @Test func parseIdentitiesEmpty() throws {
        let frame = Self.frame(type: 12, payload: Self.uint32BE(0))
        let identities = try SSHAgentCodec.parseIdentitiesAnswer(frame)
        #expect(identities.isEmpty)
    }

    // MARK: - parseSignResponse

    @Test func parseSignResponseReturnsRawSignatureString() throws {
        let signature = Self.sshString("ssh-ed25519") + Self.sshString([0x0a, 0x0b, 0x0c])
        let frame = Self.frame(type: 14, payload: Self.sshString(signature))
        let result = try SSHAgentCodec.parseSignResponse(frame)
        #expect(result == Data(signature))
    }

    // MARK: - FAILURE and garbage

    @Test func failureFrameThrowsRefusedFromIdentities() {
        let frame = Self.frame(type: 5)
        #expect(throws: AgentError.refused) {
            _ = try SSHAgentCodec.parseIdentitiesAnswer(frame)
        }
    }

    @Test func failureFrameThrowsRefusedFromSignResponse() {
        let frame = Self.frame(type: 5)
        #expect(throws: AgentError.refused) {
            _ = try SSHAgentCodec.parseSignResponse(frame)
        }
    }

    /// Three ways a frame can be garbage: too short to contain a length
    /// prefix, a wrong/unexpected message type, and an outer length that
    /// lies about how many body bytes actually follow.
    @Test(
        "garbage frames throw protocolError",
        arguments: [
            Data(),
            Self.frame(type: 12), // identities-answer type, fed to the sign-response parser
            Data([0, 0, 0, 10, 14, 0, 0, 0, 0]), // declared length (10) exceeds actual body (5)
        ]
    )
    func garbageThrowsProtocolError(_ frame: Data) {
        #expect(throws: AgentError.self) {
            _ = try SSHAgentCodec.parseSignResponse(frame)
        }
        do {
            _ = try SSHAgentCodec.parseSignResponse(frame)
            Issue.record("expected parseSignResponse to throw for garbage frame")
        } catch let error as AgentError {
            guard case .protocolError = error else {
                Issue.record("expected .protocolError, got \(error)")
                return
            }
        } catch {
            Issue.record("expected AgentError, got \(error)")
        }
    }

    // MARK: - Flag constants

    @Test func flagConstants() {
        #expect(SSHAgentCodec.rsaSHA2_256 == 2)
        #expect(SSHAgentCodec.rsaSHA2_512 == 4)
    }
}
