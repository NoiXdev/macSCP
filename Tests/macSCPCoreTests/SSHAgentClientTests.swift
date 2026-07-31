import Foundation
import NIOCore
import NIOEmbedded
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
    /// M11e/T2: a SINGLE queued transport failure must map to
    /// `AgentError.protocolError` — the ORIGINAL version of this test called
    /// `listIdentities()` twice against a one-element queue, so the second
    /// call actually hit the mock's OWN "queue exhausted" fallback
    /// (`MockAgentTransport.roundTrip`'s `guard !responses.isEmpty else`
    /// branch) rather than the real transport-error mapping in
    /// `SSHAgentClient.performRoundTrip` — both happen to produce a
    /// `.protocolError` case, so the assertion passed without ever
    /// exercising the mapping it claimed to test. One do/catch, one queued
    /// failure, and asserting the `reason` carries the underlying error's
    /// own description closes that gap.
    @Test func transportErrorMapsToProtocolErrorDuringOperation() async {
        struct SomeTransportFailure: Error, CustomStringConvertible {
            var description: String { "boom-from-transport" }
        }
        let transport = MockAgentTransport(throwing: SomeTransportFailure())
        let client = SSHAgentClient(transport: transport)

        do {
            _ = try await client.listIdentities()
            Issue.record("expected listIdentities to throw")
        } catch let error as AgentError {
            guard case .protocolError(let reason) = error else {
                Issue.record("expected .protocolError, got \(error)")
                return
            }
            #expect(reason.contains("boom-from-transport"))
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

    // MARK: - M11e/T1 point 1: frame length cap

    /// The accumulator rejects a declared frame length beyond
    /// `FrameAccumulatingHandler.maxFrameLength` the MOMENT the 4-byte
    /// length prefix itself is readable -- before buffering any of the
    /// (possibly-never-arriving) rest of the claimed frame, and without
    /// waiting for the transport's response deadline. Driven directly
    /// through an `EmbeddedChannel` (not `MockAgentTransport`, which
    /// bypasses framing entirely) since production framing lives in this
    /// handler, not in `SSHAgentClient` itself.
    ///
    /// Deliberately never calls `advanceTime`/`run` past "now": on
    /// `EmbeddedEventLoop` a scheduled deadline task only ever fires once
    /// the virtual clock is explicitly advanced past it, so this test
    /// passing at all is itself proof the rejection did not wait for the
    /// deadline -- a wrong implementation that only checks size after a
    /// full frame is buffered would leave the promise pending forever here,
    /// not eventually time out.
    @Test func oversizedFrameThrowsProtocolError() throws {
        let channel = EmbeddedChannel()
        let handler = FrameAccumulatingHandler()
        try channel.pipeline.addHandler(handler).wait()

        let future = handler.send(Data([0xAA]), over: channel, deadline: .seconds(30))
        channel.embeddedEventLoop.run()  // flush the `execute` block that arms the promise / writes the request

        let oversizedLength = FrameAccumulatingHandler.maxFrameLength + 1
        var lengthPrefix = channel.allocator.buffer(capacity: 4)
        lengthPrefix.writeInteger(oversizedLength)
        try channel.writeInbound(lengthPrefix)

        do {
            _ = try future.wait()
            Issue.record("expected the oversized declared length to throw")
        } catch let error as AgentError {
            guard case .protocolError(let reason) = error else {
                Issue.record("expected .protocolError, got \(error)")
                return
            }
            #expect(reason.contains("\(oversizedLength)"))
        } catch {
            Issue.record("expected AgentError, got \(error)")
        }
    }

    /// The boundary is INCLUSIVE (spec §2 point 1): a declared length of
    /// EXACTLY `maxFrameLength`, carrying a genuinely valid
    /// IDENTITIES_ANSWER payload padded to that exact size, still parses
    /// normally end to end -- both the accumulator's own cap and
    /// `SSHAgentCodec`'s parsing.
    @Test func maxAllowedFrameStillParses() throws {
        let channel = EmbeddedChannel()
        let handler = FrameAccumulatingHandler()
        try channel.pipeline.addHandler(handler).wait()

        let maxLength = Int(FrameAccumulatingHandler.maxFrameLength)
        let blob = Self.sshString("ssh-ed25519") + Self.sshString([0x01])
        // type(1) + count(4) + outer-string(blob) + outer-string(comment)
        let fixedOverhead = 1 + 4 + (4 + blob.count) + 4
        let commentLength = maxLength - fixedOverhead
        #expect(commentLength > 0)
        let comment = String(repeating: "a", count: commentLength)
        var body: [UInt8] = [12] + Self.uint32BE(1)
        body += Self.sshString(blob) + Self.sshString(comment)
        #expect(body.count == maxLength)
        let frameData = Data(Self.uint32BE(UInt32(maxLength)) + body)

        let future = handler.send(Data([0xAA]), over: channel, deadline: .seconds(30))
        channel.embeddedEventLoop.run()

        var frameBuffer = channel.allocator.buffer(capacity: frameData.count)
        frameBuffer.writeBytes(frameData)
        try channel.writeInbound(frameBuffer)

        let response = try future.wait()
        let identities = try SSHAgentCodec.parseIdentitiesAnswer(response)
        #expect(identities.count == 1)
        #expect(identities[0].keyType == "ssh-ed25519")
        #expect(identities[0].comment == comment)
    }
}
