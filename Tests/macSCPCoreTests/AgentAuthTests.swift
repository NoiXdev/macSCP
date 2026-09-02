import Citadel
// `Insecure` is Crypto's namespace; Citadel hangs its `RSA` types off it, and
// `theRSAAgentKeyTypesItsBlobSshRsaAndOffersItAsSHA2` reads its blob prefix
// from `Insecure.RSA.PublicKey` rather than spelling `ssh-rsa`.
import Crypto
import Foundation
import NIOCore
import NIOPosix
// The SSH transport reaches this suite through a fork of swift-nio-ssh that
// branched before Apple adopted `Sendable`, so `NIOSSHUserAuthenticationOffer`
// carries no conformance to state — the same reason
// `AgentBackedPrivateKey` carries this import. What stops being checked here
// is every `Sendable`-related crossing of a NIOSSH type in this file: the
// offer that `nextOffer` awaits off an `EventLoopPromise`, and the promise
// itself. Both are built in this file, handed straight to NIOSSH, and never
// retained on this side.
@preconcurrency import NIOSSH
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

    /// An IDENTITIES_ANSWER reporting one identity per `keyTypes`, each with
    /// distinguishable dummy material/comment. Used by
    /// `allUnsupportedIdentitiesThrowNoUsableIdentities` to simulate an
    /// agent that answered with identities, none of which
    /// `AgentPrivateKeyFactory.supports` recognizes.
    private static func identitiesAnswerFrame(keyTypes: [String]) -> Data {
        var payload = uint32BE(UInt32(keyTypes.count))
        for (index, keyType) in keyTypes.enumerated() {
            let blob = sshBytes(keyType) + sshBytes([UInt8(index)])
            payload += sshBytes(blob) + sshBytes("identity-\(index)")
        }
        return frame(type: 12, payload: payload)
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

    /// Runs `body` with its own event-loop group and shuts that group down
    /// afterwards, whether the body returns or throws.
    ///
    /// The shutdown has to happen here rather than in a `defer` at the call
    /// site: `syncShutdownGracefully` parks the calling thread until the
    /// loops are down, which an `async` function must not do, and its
    /// awaitable counterpart cannot be awaited from a `defer`. The errors
    /// are swallowed exactly as the `defer` swallowed them — a group that
    /// refuses to shut down is not what the test is about.
    private func withEventLoopGroup(
        _ body: (MultiThreadedEventLoopGroup) async throws -> Void
    ) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            try await body(group)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        try? await group.shutdownGracefully()
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

        try await withEventLoopGroup { group in
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

    /// The wire-tag half of THE RSA RISK, ungated — the identifiers an RSA
    /// agent identity puts on the wire, read off the offer the production
    /// delegate produces.
    ///
    /// RFC 8332 §3 gives the request three identifiers: the blob is typed
    /// `ssh-rsa`, while `pkalg` and the signature say `rsa-sha2-512`. Both
    /// halves are needed and neither is enough: with only the blob retyped,
    /// OpenSSH and SFTPGo alike refuse the offer; with only the algorithm
    /// name, a Go-based server drops the connection.
    ///
    /// Those two failures are measured against real servers by
    /// `CitadelFileSystemIntegrationTests.agentAuthConnectsRSA` and
    /// `GoServerRSAIntegrationTests.rsaAgentIdentityConnects` — both of which
    /// need `MACSCP_ITEST=1` and the Docker rig, which CI does not run.
    /// Deleting either member left the whole ungated suite green until this
    /// test existed; it is the same gap
    /// `CitadelFileSystemHostKeyAlgorithmWiringGuardTests` was written for.
    ///
    /// No identifier is spelled here: each is read off the type that owns it,
    /// so a rename moves the expectation with the code. The last assertion is
    /// the positive that makes the blob check more than a string comparison —
    /// the offered key reconstructs the agent's OWN blob byte for byte, which
    /// it can only do while the prefix NIOSSH writes is the one the agent
    /// reported.
    @Test func theRSAAgentKeyTypesItsBlobSshRsaAndOffersItAsSHA2() async throws {
        typealias RSAKey = AgentBackedPublicKey<AgentAlgorithm.RSASha512>
        #expect(RSAKey.publicKeyPrefix == Insecure.RSA.PublicKey.publicKeyPrefix)
        #expect(RSAKey.userAuthAlgorithmName == RSASHA2Signature.signaturePrefix)
        // The split itself: one type, two different identifiers.
        #expect(RSAKey.publicKeyPrefix != RSAKey.userAuthAlgorithmName)

        let identity = Self.makeIdentity(
            keyType: Insecure.RSA.PublicKey.publicKeyPrefix,
            material: Self.sshBytes([0x01]) + Self.sshBytes([0x02]), comment: "rsa")
        let client = SSHAgentClient(transport: MockAgentTransport(responses: []))
        let delegate = AgentAuthDelegate(
            username: "tester", identities: [identity], client: client)

        try await withEventLoopGroup { group in
            let offer = try await nextOffer(delegate, group: group)
            guard case .privateKey(let offered) = offer.offer else {
                Issue.record("expected a privateKey offer for the RSA identity")
                return
            }
            // The bytes NIOSSH would put on the wire, not the static that is
            // supposed to produce them: a key blob opens with an SSH string
            // naming its type.
            var buffer = ByteBuffer()
            offered.publicKey.write(to: &buffer)
            guard let length = buffer.readInteger(as: UInt32.self),
                  let blobType = buffer.readString(length: Int(length))
            else {
                Issue.record("the serialized offer carries no leading SSH string")
                return
            }
            #expect(blobType == RSAKey.publicKeyPrefix)
            #expect(String(openSSHPublicKey: offered.publicKey)
                == "\(identity.keyType) \(identity.publicKeyBlob.base64EncodedString())")
        }
    }

    /// An `ssh-rsa`-blob identity signs with `SSH_AGENT_RSA_SHA2_512` (4);
    /// an ed25519 identity signs with flags 0 — the RSA risk's sign-side
    /// half. Its wire-tag half is the test above, and the two servers'
    /// verdicts on the same offer are the gated `agentAuthConnectsRSA` and
    /// `rsaAgentIdentityConnects`.
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

    /// The algorithm-mismatch refusal, and what its message is made of. The
    /// name the agent self-reports is decoded from arbitrary bytes of its
    /// answer — its length is bounded by the frame and nothing else — and
    /// the `reason` it lands in is shown to a person. A recognized name is
    /// repeated back, because naming which legacy algorithm the agent
    /// substituted IS the diagnosis; anything else is replaced, so the
    /// agent cannot write the text.
    @Test func mismatchedAlgorithmNamesOnlyNamesItIfMacSCPKnowsIt() async throws {
        func signExpectingRefusal(reporting reported: String) throws -> String {
            let identity = Self.makeIdentity(
                keyType: "ssh-rsa", material: Self.sshBytes([0x01]) + Self.sshBytes([0x02]),
                comment: "rsa")
            let rawSignature = Self.sshBytes(reported) + Self.sshBytes([0x01, 0x02])
            let client = SSHAgentClient(transport: MockAgentTransport(
                response: Self.frame(type: 14, payload: Self.sshBytes(rawSignature))))
            let key = AgentBackedPrivateKey<AgentAlgorithm.RSASha512>(
                identity: identity, client: client)
            do {
                _ = try key.signature(for: Data("payload".utf8))
                Issue.record("expected the mismatched algorithm name to be refused")
                return ""
            } catch let error as AgentError {
                guard case .protocolError(let reason) = error else {
                    Issue.record("expected a protocolError, got \(error)")
                    return ""
                }
                return reason
            }
        }

        // The realistic misbehaviour: an agent that ignored the SHA2 flags
        // and signed with legacy SHA-1. Named, because it is macSCP's own
        // string.
        #expect(try signExpectingRefusal(reporting: "ssh-rsa")
            == "agent signature algorithm mismatch: expected rsa-sha2-512, got ssh-rsa")

        // Free text the agent chose. It must reach neither the error nor
        // anything rendered from it, at any length.
        let injected = "attacker-chosen-\(String(repeating: "A", count: 512))"
        let reason = try signExpectingRefusal(reporting: injected)
        #expect(!reason.contains("attacker-chosen"))
        #expect(!reason.contains("AAAA"))
        #expect(reason.hasSuffix("got an unrecognized algorithm name"))
    }

    /// M11e/T1 point 2: the semaphore wait in `signature(for:)` has its own
    /// wall-clock ceiling, independent of `NIOUnixSocketAgentTransport`'s own
    /// 10s response deadline — that transport-level deadline only fires
    /// while its round-trip `Task` is actually running; this covers the
    /// (rarer, but real) case where the `Task`'s promise is never fulfilled
    /// at all. The mock transport below suspends forever and never resumes
    /// its continuation — a stand-in for exactly that scenario — so only the
    /// injected (short) `signTimeout` can ever end the wait; this is why the
    /// timeout needed to become an injectable parameter (default 15s) rather
    /// than a hardcoded constant.
    @Test func signTimesOutWithProtocolError() {
        final class NeverRespondingTransport: SSHAgentTransport, @unchecked Sendable {
            func roundTrip(_ request: Data) async throws -> Data {
                // An hour comfortably outlasts the test's own process; this
                // is a well-behaved suspension (unlike an unresumed
                // `checkedContinuation`, which the runtime flags as a leak)
                // that simply never completes before `signTimeout` below does.
                try await Task.sleep(for: .seconds(3600))
                return Data()
            }
            func close() async {}
        }
        let identity = Self.makeIdentity(
            keyType: "ssh-ed25519", material: Self.sshBytes([0x01]), comment: "never-responds")
        let client = SSHAgentClient(transport: NeverRespondingTransport())
        let key = AgentBackedPrivateKey<AgentAlgorithm.Ed25519>(
            identity: identity, client: client, signTimeout: 0.05)

        #expect(throws: AgentError.protocolError(reason: "agent sign timed out")) {
            _ = try key.signature(for: Data("payload".utf8))
        }
    }

    // MARK: - Connect-path error mapping (typed, not stringified)

    /// `AgentEnvLock` (M11e/T2, see its doc comment) serializes this against
    /// the gated agent tests in `CitadelFileSystemIntegrationTests`, which
    /// mutate the same process-global `SSH_AUTH_SOCK` — `.serialized` above
    /// only protects against interleaving WITHIN this suite.
    private func withTemporarySSHAuthSock(_ value: String, _ body: () async throws -> Void) async rethrows {
        try await AgentEnvLock.shared.run {
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
    }

    private func agentConfig() throws -> SSHConnectionConfig {
        try SSHConnectionConfig(host: "example.invalid", username: "tester", auth: .agent)
    }

    /// Returns a store on a fresh temp directory PLUS that directory, so the
    /// caller can `defer` its removal (M11e/T3: these four call sites used to
    /// leak one directory per run, mirroring the leak already swept from
    /// `CitadelFileSystemIntegrationTests`).
    private func freshKnownHostsStore() -> (store: KnownHostsStore, directory: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-agent-\(UUID().uuidString)")
        return (KnownHostsStore(directory: directory), directory)
    }

    /// An agent reachable but reporting zero identities surfaces as the
    /// TYPED `AgentError.noIdentities` — never a stringified
    /// `connectionFailed` — via the mock-factory injection hook
    /// (`CitadelFileSystem.AgentClientFactory`, a `@TaskLocal` override so
    /// `connect()`'s own signature stays unchanged per the brief).
    @Test func emptyAgentThrowsNoIdentities() async throws {
        try await withTemporarySSHAuthSock("/tmp/macscp-agent-unit-test-\(UUID().uuidString).sock") {
            let config = try agentConfig()
            let (store, knownHostsDirectory) = freshKnownHostsStore()
            defer { try? FileManager.default.removeItem(at: knownHostsDirectory) }
            await #expect(throws: AgentError.noIdentities) {
                try await CitadelFileSystem.AgentClientFactory.$override.withValue({ _ in
                    SSHAgentClient(transport: MockAgentTransport(response: Self.emptyIdentitiesAnswerFrame()))
                }) {
                    _ = try await CitadelFileSystem.connect(
                        config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
                }
            }
        }
    }

    /// M11e/T1 point 3: the agent DID answer with identities, but NONE of
    /// their key types survive `AgentPrivateKeyFactory.supports` (both
    /// report the unsupported `ssh-dss` here) — the connect throws the
    /// distinct, typed `AgentError.noUsableIdentities`, NOT `.noIdentities`
    /// (which stays reserved for an agent reporting zero identities at all,
    /// see `emptyAgentThrowsNoIdentities` above). Like that test, this never
    /// touches the network: the guard in `CitadelFileSystem.connectHop`
    /// fires before the first `connectOnce`/`SSHClient.connect` call.
    @Test func allUnsupportedIdentitiesThrowNoUsableIdentities() async throws {
        try await withTemporarySSHAuthSock("/tmp/macscp-agent-unsupported-\(UUID().uuidString).sock") {
            let config = try agentConfig()
            let (store, knownHostsDirectory) = freshKnownHostsStore()
            defer { try? FileManager.default.removeItem(at: knownHostsDirectory) }
            await #expect(throws: AgentError.noUsableIdentities) {
                try await CitadelFileSystem.AgentClientFactory.$override.withValue({ _ in
                    SSHAgentClient(transport: MockAgentTransport(
                        response: Self.identitiesAnswerFrame(keyTypes: ["ssh-dss", "ssh-dss"])))
                }) {
                    _ = try await CitadelFileSystem.connect(
                        config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
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
            let (store, knownHostsDirectory) = freshKnownHostsStore()
            defer { try? FileManager.default.removeItem(at: knownHostsDirectory) }
            await #expect(throws: AgentError.socketUnavailable) {
                _ = try await CitadelFileSystem.connect(
                    config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
            }
        }
    }

    /// I-3(b), mock-level half: a typed `AgentError` raised while
    /// establishing the JUMP hop's OWN agent connection must survive
    /// `CitadelFileSystem`'s stage-aware error mapping (`mapStageAware`) AS
    /// an `AgentError` — never downgraded to a stringified
    /// `RemoteFSError.connectionFailed`. `emptyAgentThrowsNoIdentities`/
    /// `deadSocketThrowsSocketUnavailable` above already prove the
    /// pass-through for the TARGET hop (`mapConnectError`); this proves the
    /// same discipline holds for the JUMP hop's distinct mapping path. No
    /// network is ever touched: the factory override throws before
    /// `AgentAuthContext.connect()` gets anywhere near a socket.
    @Test func agentErrorSurvivesJumpStageMapping() async throws {
        try await withTemporarySSHAuthSock("/tmp/macscp-agent-jumpstage-\(UUID().uuidString).sock") {
            let config = try SSHConnectionConfig(
                host: "example.invalid", username: "tester", auth: .password("irrelevant"),
                jump: .init(host: "jump.invalid", username: "tester", auth: .agent))
            let (store, knownHostsDirectory) = freshKnownHostsStore()
            defer { try? FileManager.default.removeItem(at: knownHostsDirectory) }
            let failingFactory: @Sendable (String) async throws -> SSHAgentClient = { _ in
                throw AgentError.protocolError(reason: "boom")
            }
            await #expect(throws: AgentError.protocolError(reason: "boom")) {
                try await CitadelFileSystem.AgentClientFactory.$override.withValue(failingFactory) {
                    _ = try await CitadelFileSystem.connect(
                        config: config, connectTimeout: .seconds(30), knownHosts: store, onUnknownHostKey: .asking { _ in true })
                }
            }
        }
    }
}
