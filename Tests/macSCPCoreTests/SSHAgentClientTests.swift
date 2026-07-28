import Foundation
import Testing
@testable import macSCPCore

/// Records the request frames it receives and replays canned responses in
/// order. `Task 2` reuses this exact mock pattern for its own tests.
final class MockAgentTransport: SSHAgentTransport, @unchecked Sendable {
    private(set) var requests: [Data] = []
    private var responses: [Result<Data, Error>]
    private(set) var closeCallCount = 0

    init(responses: [Result<Data, Error>]) {
        self.responses = responses
    }

    convenience init(response: Data) {
        self.init(responses: [.success(response)])
    }

    convenience init(throwing error: Error) {
        self.init(responses: [.failure(error)])
    }

    func roundTrip(_ request: Data) async throws -> Data {
        requests.append(request)
        guard !responses.isEmpty else {
            throw AgentError.protocolError(reason: "mock transport exhausted")
        }
        let result = responses.removeFirst()
        return try result.get()
    }

    func close() async {
        closeCallCount += 1
    }
}

@Suite("SSHAgentClient")
struct SSHAgentClientTests {
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

    private static func frame(type: UInt8, payload: [UInt8] = []) -> Data {
        let body = [type] + payload
        return Data(uint32BE(UInt32(body.count)) + body)
    }

    private static func twoIdentitiesAnswerFrame() -> Data {
        let blob1 = sshString("ssh-ed25519") + sshString([0x01, 0x02])
        let blob2 = sshString("ssh-ed25519") + sshString([0x03, 0x04])
        var payload = uint32BE(2)
        payload += sshString(blob1) + sshString("key one")
        payload += sshString(blob2) + sshString("key two")
        return frame(type: 12, payload: payload)
    }

    @Test func listIdentitiesSendsRequestAndParses() async throws {
        let transport = MockAgentTransport(response: Self.twoIdentitiesAnswerFrame())
        let client = SSHAgentClient(transport: transport)

        let identities = try await client.listIdentities()

        #expect(transport.requests.count == 1)
        #expect(transport.requests[0] == SSHAgentCodec.requestIdentitiesFrame())
        #expect(identities.count == 2)
    }

    @Test func signSendsCorrectFrame() async throws {
        let signature = Self.sshString("ssh-ed25519") + Self.sshString([0x0a, 0x0b])
        let responseFrame = Self.frame(type: 14, payload: Self.sshString(signature))
        let transport = MockAgentTransport(response: responseFrame)
        let client = SSHAgentClient(transport: transport)

        let blob = Data("some-blob".utf8)
        let payload = Data("some-data".utf8)
        let result = try await client.sign(publicKeyBlob: blob, data: payload, flags: 2)

        #expect(transport.requests.count == 1)
        #expect(transport.requests[0] == SSHAgentCodec.signRequestFrame(
            publicKeyBlob: blob, data: payload, flags: 2))
        #expect(result == Data(signature))
    }

    /// A transport error during an in-flight round trip (list/sign) is a
    /// protocol-level problem for an already-established connection, NOT a
    /// "no agent" condition — it maps to `.protocolError`, distinct from the
    /// `.socketUnavailable` that only `connect(socketPath:)` produces.
    @Test func transportErrorMapsToProtocolErrorDuringOperation() async {
        struct SomeTransportFailure: Error {}
        let transport = MockAgentTransport(throwing: SomeTransportFailure())
        let client = SSHAgentClient(transport: transport)

        await #expect(throws: AgentError.self) {
            _ = try await client.listIdentities()
        }
        do {
            _ = try await client.listIdentities()
            Issue.record("expected listIdentities to throw")
        } catch let error as AgentError {
            guard case .protocolError = error else {
                Issue.record("expected .protocolError, got \(error)")
                return
            }
        } catch {
            Issue.record("expected AgentError, got \(error)")
        }
    }

    @Test func deadSocketPathThrowsSocketUnavailable() async {
        await #expect(throws: AgentError.socketUnavailable) {
            _ = try await SSHAgentClient.connect(socketPath: "/nonexistent/macscp-agent-test.sock")
        }
    }

    @Test func closeDelegatesToTransport() async {
        let transport = MockAgentTransport(response: Data())
        let client = SSHAgentClient(transport: transport)
        await client.close()
        #expect(transport.closeCallCount == 1)
    }
}
