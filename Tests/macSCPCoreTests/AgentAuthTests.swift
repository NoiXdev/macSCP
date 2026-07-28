import Citadel
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing
@testable import macSCPCore

/// Mock-transport-driven tests for the NIOSSH integration (M10d Task 2):
/// `AgentBackedPrivateKey`'s custom signer trio, `AgentAuthDelegate`'s
/// identity-order/exhaustion behavior, and the `.agent` connect-path error
/// mapping (`socketUnavailable`/`noIdentities`, typed — never a stringified
/// `connectionFailed`). Reuses `MockAgentTransport` from
/// `SSHAgentClientTests.swift` (same target, same mock pattern).
///
/// `.serialized`: `emptyAgentThrowsNoIdentities`/`deadSocketThrowsSocketUnavailable`
/// temporarily mutate the process-wide `SSH_AUTH_SOCK` environment variable
/// (restored in each test) — serializing avoids any cross-test interleaving
/// on that shared, process-global state.
@Suite("AgentAuth", .serialized)
struct AgentAuthTests {
    // MARK: - Fixtures

    private static func uint32BE(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff),
         UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }

    private static func sshBytes(_ bytes: [UInt8]) -> [UInt8] {
        uint32BE(UInt32(bytes.count)) + bytes
    }

    private static func sshBytes(_ string: String) -> [UInt8] {
        sshBytes(Array(string.utf8))
    }

    private static func frame(type: UInt8, payload: [UInt8] = []) -> Data {
        let body = [type] + payload
        return Data(uint32BE(UInt32(body.count)) + body)
    }

    private static func makeIdentity(
        keyType: String, material: [UInt8], comment: String
    ) -> AgentIdentity {
        let blob = Data(sshBytes(keyType) + material)
        return AgentIdentity(
            publicKeyBlob: blob, comment: comment, keyType: keyType,
            fingerprintSHA256: "SHA256:test-\(comment)")
    }

    private static func emptyIdentitiesAnswerFrame() -> Data {
        frame(type: 12, payload: uint32BE(0))
    }

    /// Drives `AgentAuthDelegate.nextAuthenticationType` through a real
    /// `EventLoopPromise` (the actual protocol method, not a test-only seam).
    private func nextOffer(
        _ delegate: AgentAuthDelegate, group: MultiThreadedEventLoopGroup
    ) async throws -> NIOSSHUserAuthenticationOffer {
        let promise = group.next().makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .all, nextChallengePromise: promise)
        guard let offer = try await promise.futureResult.get() else {
            struct NoOffer: Error {}
            throw NoOffer()
        }
        return offer
    }

    // MARK: - Step 1 tests

    /// Two identities are offered in list order (round-tripped VERBATIM —
    /// the offered key's OpenSSH string reconstructs byte-identical to the
    /// original agent blob); the third call (identities exhausted) fails
    /// the promise with `allAuthenticationOptionsFailed`.
    @Test func agentAuthOffersIdentitiesInOrder() async throws {
        let identity1 = Self.makeIdentity(
            keyType: "ssh-ed25519", material: Self.sshBytes([0x01, 0x02]), comment: "one")
        let identity2 = Self.makeIdentity(
            keyType: "ssh-ed25519", material: Self.sshBytes([0x03, 0x04]), comment: "two")
        let client = SSHAgentClient(transport: MockAgentTransport(responses: []))
        let delegate = AgentAuthDelegate(
            username: "tester", identities: [identity1, identity2], client: client)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let offer1 = try await nextOffer(delegate, group: group)
        guard case .privateKey(let pk1) = offer1.offer else {
            Issue.record("expected a privateKey offer for the first identity")
            return
        }
        #expect(offer1.username == "tester")
        #expect(String(openSSHPublicKey: pk1.publicKey)
            == "\(identity1.keyType) \(identity1.publicKeyBlob.base64EncodedString())")

        let offer2 = try await nextOffer(delegate, group: group)
        guard case .privateKey(let pk2) = offer2.offer else {
            Issue.record("expected a privateKey offer for the second identity")
            return
        }
        #expect(String(openSSHPublicKey: pk2.publicKey)
            == "\(identity2.keyType) \(identity2.publicKeyBlob.base64EncodedString())")

        do {
            _ = try await nextOffer(delegate, group: group)
            Issue.record("expected the third call (no identities left) to fail")
        } catch let error as SSHClientError {
            guard case .allAuthenticationOptionsFailed = error else {
                Issue.record("expected allAuthenticationOptionsFailed, got \(error)")
                return
            }
        }
    }

    /// `AgentBackedPrivateKey.signature(for:)` sends a SIGN_REQUEST with
    /// EXACTLY the payload NIOSSH hands it, and the agent's response bytes
    /// land VERBATIM in `AgentSignature.write(to:)` (only the leading
    /// algorithm-name string is stripped — NIOSSH re-adds its own via
    /// `signaturePrefix`).
    @Test func signatureForwardsBlobToAgent() async throws {
        let identity = Self.makeIdentity(
            keyType: "ssh-ed25519", material: Self.sshBytes([0xaa]), comment: "sign-test")
        let sigBlob: [UInt8] = [0x0a, 0x0b, 0x0c]
        let rawSignature = Self.sshBytes("ssh-ed25519") + Self.sshBytes(sigBlob)
        let responseFrame = Self.frame(type: 14, payload: Self.sshBytes(rawSignature))
        let transport = MockAgentTransport(response: responseFrame)
        let client = SSHAgentClient(transport: transport)
        let key = AgentBackedPrivateKey<AgentAlgorithm.Ed25519>(identity: identity, client: client)

        let payload = Data("exact-payload-bytes".utf8)
        let signature = try key.signature(for: payload)

        #expect(transport.requests.count == 1)
        #expect(transport.requests[0] == SSHAgentCodec.signRequestFrame(
            publicKeyBlob: identity.publicKeyBlob, data: payload, flags: 0))

        var buffer = ByteBuffer()
        _ = signature.write(to: &buffer)
        let written = Data(buffer.readableBytesView)
        #expect(written == Data(Self.sshBytes(sigBlob)))
    }

    /// An `ssh-rsa`-blob identity signs with `SSH_AGENT_RSA_SHA2_512` (4);
    /// an ed25519 identity signs with flags 0 — the RSA risk's sign-side
    /// half (the wire-tag half is covered by the gated `agentAuthConnectsRSA`
    /// integration test).
    @Test func rsaBlobUsesSha2Flags() async throws {
        let rsaIdentity = Self.makeIdentity(
            keyType: "ssh-rsa", material: Self.sshBytes([0x01]) + Self.sshBytes([0x02]),
            comment: "rsa")
        let sigBlob: [UInt8] = [0x01, 0x02, 0x03]
        let rawSignature = Self.sshBytes("rsa-sha2-512") + Self.sshBytes(sigBlob)
        let responseFrame = Self.frame(type: 14, payload: Self.sshBytes(rawSignature))
        let rsaTransport = MockAgentTransport(response: responseFrame)
        let rsaClient = SSHAgentClient(transport: rsaTransport)
        let rsaKey = AgentBackedPrivateKey<AgentAlgorithm.RSASha512>(
            identity: rsaIdentity, client: rsaClient)
        _ = try rsaKey.signature(for: Data("payload".utf8))

        #expect(rsaTransport.requests[0] == SSHAgentCodec.signRequestFrame(
            publicKeyBlob: rsaIdentity.publicKeyBlob, data: Data("payload".utf8),
            flags: SSHAgentCodec.rsaSHA2_512))
        #expect(SSHAgentCodec.rsaSHA2_512 == 4)

        let edIdentity = Self.makeIdentity(
            keyType: "ssh-ed25519", material: Self.sshBytes([0x03]), comment: "ed")
        let edRawSignature = Self.sshBytes("ssh-ed25519") + Self.sshBytes(sigBlob)
        let edResponseFrame = Self.frame(type: 14, payload: Self.sshBytes(edRawSignature))
        let edTransport = MockAgentTransport(response: edResponseFrame)
        let edClient = SSHAgentClient(transport: edTransport)
        let edKey = AgentBackedPrivateKey<AgentAlgorithm.Ed25519>(identity: edIdentity, client: edClient)
        _ = try edKey.signature(for: Data("payload".utf8))

        #expect(edTransport.requests[0] == SSHAgentCodec.signRequestFrame(
            publicKeyBlob: edIdentity.publicKeyBlob, data: Data("payload".utf8), flags: 0))
    }

    // MARK: - Connect-path error mapping (typed, not stringified)

    private func withTemporarySSHAuthSock(_ value: String, _ body: () async throws -> Void) async rethrows {
        let original = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        setenv("SSH_AUTH_SOCK", value, 1)
        defer {
            if let original {
                setenv("SSH_AUTH_SOCK", original, 1)
            } else {
                unsetenv("SSH_AUTH_SOCK")
            }
        }
        try await body()
    }

    private func agentConfig() throws -> SSHConnectionConfig {
        try SSHConnectionConfig(host: "example.invalid", username: "tester", auth: .agent)
    }

    private func freshKnownHostsStore() -> KnownHostsStore {
        KnownHostsStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-agent-\(UUID().uuidString)"))
    }

    /// An agent reachable but reporting zero identities surfaces as the
    /// TYPED `AgentError.noIdentities` — never a stringified
    /// `connectionFailed` — via the mock-factory injection hook
    /// (`CitadelFileSystem.AgentClientFactory`, a `@TaskLocal` override so
    /// `connect()`'s own signature stays unchanged per the brief).
    @Test func emptyAgentThrowsNoIdentities() async throws {
        try await withTemporarySSHAuthSock("/tmp/macscp-agent-unit-test-\(UUID().uuidString).sock") {
            let config = try agentConfig()
            let store = freshKnownHostsStore()
            await #expect(throws: AgentError.noIdentities) {
                try await CitadelFileSystem.AgentClientFactory.$override.withValue({ _ in
                    SSHAgentClient(transport: MockAgentTransport(response: Self.emptyIdentitiesAnswerFrame()))
                }) {
                    _ = try await CitadelFileSystem.connect(
                        config: config, knownHosts: store, onUnknownHostKey: { _ in true })
                }
            }
        }
    }

    /// A dead/nonexistent `SSH_AUTH_SOCK` path surfaces as the TYPED
    /// `AgentError.socketUnavailable` — exercised through the REAL
    /// `SSHAgentClient.connect(socketPath:)` (no mock factory override),
    /// proving the failure is caught before any TCP connection is even
    /// attempted.
    @Test func deadSocketThrowsSocketUnavailable() async throws {
        try await withTemporarySSHAuthSock("/nonexistent/macscp-agent-unit-test.sock") {
            let config = try agentConfig()
            let store = freshKnownHostsStore()
            await #expect(throws: AgentError.socketUnavailable) {
                _ = try await CitadelFileSystem.connect(
                    config: config, knownHosts: store, onUnknownHostKey: { _ in true })
            }
        }
    }
}
