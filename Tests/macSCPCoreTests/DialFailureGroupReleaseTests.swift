import Crypto
import Foundation
import MacSCPTestSupport
import NIOCore
import NIOPosix
// `@preconcurrency` for the reason `SSHForwardingConnectionTests.swift`
// gives: the NIOSSH fork this project pins carries no `Sendable`
// conformances, and the server below captures its host key in NIO's
// `@Sendable` child-channel initializer and completes auth outcomes through
// an `EventLoopPromise`. The key is never mutated after it is generated, and
// each promise is completed on the connection's own event loop.
@preconcurrency import NIOSSH
import Testing

@testable import macSCPCore

/// A dial that fails partway releases its dedicated event-loop group through
/// `CitadelFileSystem.releaseAfterCitadelTimer`, outliving Citadel's login
/// timer, and never shuts it down at once.
///
/// Citadel's `ClientHandshakeHandler.init` schedules a 10-second login
/// timeout on the connection's event loop, once per hop, and never cancels
/// it (`CitadelFileSystem.citadelLoginTimer`). A host-key rejection or an
/// auth failure happens after that handler exists, so a group shut down at
/// once would cut the pending task off — the shape the success paths
/// already wait out.
///
/// Only `.agent` auth creates a dedicated group, so every dial here is an
/// agent dial: `CitadelFileSystem.AgentClientFactory` hands in an agent that
/// holds one Ed25519 identity and answers one signature request with a
/// signature nobody can verify. The server is in-process, on loopback, with
/// a host key generated per test; it offers `publickey` and nothing else.
///
/// The release is observed through `CitadelFileSystem.GroupReleaseObserver`,
/// which leaves the delayed release itself in place. An immediate shutdown
/// is not a call of the delayed release, so the spy sees nothing for it; the
/// source guard `DialGroupReleaseGuardTests` pins that no such shutdown is
/// written in the dial's files at all.
@Suite("Dial failure group release", .timeLimit(.minutes(1)))
struct DialFailureGroupReleaseTests {
    enum Path: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case forwarding
        case tab

        var testDescription: String { rawValue }
    }

    enum Failure: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// An unknown host key the decider refuses.
        case hostKeyRejected
        /// A known host key, and a server that turns the agent's key down.
        case authenticationFailed

        var testDescription: String { rawValue }
    }

    @Test(arguments: Path.allCases, Failure.allCases)
    func aFailedDialReleasesItsGroupOnlyAfterTheLoginTimer(
        _ path: Path, _ failure: Failure
    ) async throws {
        let server = try await PublicKeyRefusingServer.start()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-dial-release-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownHostsStore(directory: directory)
        if failure == .authenticationFailed {
            try store.upsert(KnownHostKey(
                host: "127.0.0.1", port: server.port,
                keyType: server.hostKey.keyType,
                publicKeyBase64: server.hostKey.publicKeyBase64))
        }

        let releases = ReleaseSpy()
        let raised = try await AgentEnvLock.shared.run {
            try await Self.withAuthSock("/tmp/macscp-dial-release-\(UUID().uuidString).sock") {
                await CitadelFileSystem.AgentClientFactory.$override.withValue({ _ in
                    SSHAgentClient(transport: MockAgentTransport(
                        responses: [.success(Self.identitiesAnswer), .success(Self.signAnswer)]))
                }) {
                    await CitadelFileSystem.GroupReleaseObserver.$observe.withValue({ _, timer in
                        releases.record(timer)
                    }) {
                        await Self.dialError(path, port: server.port, store: store)
                    }
                }
            }
        }
        await server.close()

        switch failure {
        case .hostKeyRejected:
            #expect(raised as? HostKeyError == .rejectedByUser)
        case .authenticationFailed:
            #expect(raised as? RemoteFSError == .authenticationFailed)
        }
        let timers = releases.timers
        #expect(timers.count == 1, "the group was not handed to the delayed release exactly once")
        #expect(timers.allSatisfy { $0 >= CitadelFileSystem.citadelLoginTimer })
    }

    private static func dialError(
        _ path: Path, port: Int, store: KnownHostsStore
    ) async -> (any Error)? {
        do {
            let config = try SSHConnectionConfig(
                host: "127.0.0.1", port: port, username: "unit", auth: .agent)
            switch path {
            case .forwarding:
                let connection = try await SSHForwardingConnection.connect(
                    config: config, connectTimeout: .seconds(30),
                    knownHosts: store, onUnknownHostKey: .refusing)
                await connection.disconnect()
            case .tab:
                let fileSystem = try await CitadelFileSystem.connect(
                    config: config, connectTimeout: .seconds(30),
                    knownHosts: store, onUnknownHostKey: .refusing)
                await fileSystem.disconnect()
            }
            return nil
        } catch {
            return error
        }
    }

    /// Points `SSH_AUTH_SOCK` at `value` for `body` and restores it. The
    /// caller holds `AgentEnvLock`, which serialises every suite that
    /// touches that process-wide variable.
    private static func withAuthSock<T>(
        _ value: String, _ body: () async throws -> T
    ) async throws -> T {
        let original = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        setenv("SSH_AUTH_SOCK", value, 1)
        defer {
            if let original {
                setenv("SSH_AUTH_SOCK", original, 1)
            } else {
                unsetenv("SSH_AUTH_SOCK")
            }
        }
        return try await body()
    }

    // MARK: - The agent's two answers

    private static func uint32BE(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff),
         UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }

    private static func sshString(_ bytes: [UInt8]) -> [UInt8] {
        uint32BE(UInt32(bytes.count)) + bytes
    }

    private static func frame(type: UInt8, payload: [UInt8]) -> Data {
        let body = [type] + payload
        return Data(uint32BE(UInt32(body.count)) + body)
    }

    /// IDENTITIES_ANSWER with one Ed25519 identity, generated here.
    private static let identitiesAnswer: Data = {
        let publicKey = Array(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let blob = sshString(Array("ssh-ed25519".utf8)) + sshString(publicKey)
        return frame(type: 12, payload: uint32BE(1) + sshString(blob) + sshString(Array("unit".utf8)))
    }()

    /// SIGN_RESPONSE carrying a well-formed Ed25519 signature of zeros: the
    /// client sends it, and the server's verification turns it down.
    private static let signAnswer: Data = {
        let signature = sshString(Array("ssh-ed25519".utf8)) + sshString([UInt8](repeating: 0, count: 64))
        return frame(type: 14, payload: sshString(signature))
    }()
}

/// Records the timer every observed release was handed.
private final class ReleaseSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []

    var timers: [Duration] { lock.withLock { recorded } }

    func record(_ timer: Duration) {
        lock.withLock { recorded.append(timer) }
    }
}

/// An SSH server on an ephemeral loopback port that offers `publickey` only
/// and turns every request down.
///
/// NIOSSH checks a public-key request's signature before the delegate is
/// asked, so the zeros above are refused before it runs; the delegate
/// refuses whatever does reach it.
private final class PublicKeyRefusingServer: @unchecked Sendable {
    let port: Int
    let hostKey: HostKeyCandidate
    private let channel: Channel

    private init(port: Int, hostKey: HostKeyCandidate, channel: Channel) {
        self.port = port
        self.hostKey = hostKey
        self.channel = channel
    }

    static func start() async throws -> PublicKeyRefusingServer {
        let privateKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let delegate = RefusingDelegate()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { child in
                child.eventLoop.makeCompletedFuture {
                    let handler = NIOSSHHandler(
                        role: .server(SSHServerConfiguration(
                            hostKeys: [privateKey], userAuthDelegate: delegate)),
                        allocator: child.allocator,
                        inboundChildChannelInitializer: { sshChild, _ in
                            sshChild.eventLoop.makeFailedFuture(Refused())
                        })
                    try child.pipeline.syncOperations.addHandler(handler)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        guard let port = channel.localAddress?.port else {
            try await channel.close()
            throw Refused()
        }
        let hostKey = HostKeyCandidate(host: "127.0.0.1", port: port, publicKey: privateKey.publicKey)
        return PublicKeyRefusingServer(port: port, hostKey: hostKey, channel: channel)
    }

    func close() async {
        try? await channel.close()
    }

    private struct Refused: Error {}

    private final class RefusingDelegate: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
        var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }

        func requestReceived(
            request: NIOSSHUserAuthenticationRequest,
            responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
        ) {
            responsePromise.succeed(.failure)
        }
    }
}
