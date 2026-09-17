import Crypto
import Foundation
import MacSCPTestSupport
import NIOCore
import NIOPosix
// `@preconcurrency` for the reason `CitadelFileSystem.swift` gives: the
// NIOSSH fork this project pins carries no `Sendable` conformances, and the
// server below captures its host key in NIO's `@Sendable` child-channel
// initializer and completes auth outcomes through an `EventLoopPromise`.
// The key is never mutated after it is generated, and each promise is
// completed on the connection's own event loop.
@preconcurrency import NIOSSH
import Testing

@testable import macSCPCore

/// What a forwarding's dial shares with a tab's, measured without the Docker
/// rig: an in-process SSH server on loopback, with a host key generated per
/// test and a password delegate, that REFUSES every channel a client asks to
/// open and counts the requests.
///
/// That server is the seam. A dial that opened SFTP would have to open a
/// session channel first, so "no channel was requested" is "no SFTP was
/// opened", read from the far side rather than from the code under test. And
/// because the server holds a host key the test controls, the TOFU verdicts
/// can be driven on both paths — `SSHForwardingConnection.connect` and
/// `CitadelFileSystem.connect` — and compared.
///
/// The gated twin, against a real OpenSSH without the SFTP subsystem, is
/// `ForwardingWithoutSFTPITests`.
@Suite("SSHForwardingConnection", .timeLimit(.minutes(1)))
struct SSHForwardingConnectionTests {
    enum Path: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case forwarding
        case tab

        var testDescription: String { rawValue }
    }

    /// A known host presenting a different key is `HostKeyError.mismatch` on
    /// both paths, the decider is never asked, and the pinned key is left as
    /// it was — the hard stop is one piece of code, whichever caller dialled.
    @Test(arguments: Path.allCases)
    func aMismatchIsAHardStopAndNeverReachesTheDecider(_ path: Path) async throws {
        let server = try await RefusingSSHServer.start()
        let directory = throwawayDirectory("mismatch")
        defer { try? FileManager.default.removeItem(at: directory) }

        let otherKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let pinned = HostKeyCandidate(host: "127.0.0.1", port: server.port, publicKey: otherKey)
        let store = KnownHostsStore(directory: directory)
        try store.upsert(KnownHostKey(
            host: pinned.host, port: pinned.port,
            keyType: pinned.keyType, publicKeyBase64: pinned.publicKeyBase64))

        let asked = UnitAskCounter()
        let raised = await dialError(
            path, port: server.port, store: store,
            decider: .asking { _ in
                asked.increment()
                return true
            })
        await server.close()

        guard case .mismatch(let host, let expected, let presented)? = raised as? HostKeyError else {
            Issue.record("expected HostKeyError.mismatch, got \(String(describing: raised))")
            return
        }
        #expect(host == "127.0.0.1")
        #expect(expected == pinned.fingerprintSHA256)
        #expect(presented == server.hostKey.fingerprintSHA256)
        #expect(asked.count == 0)
        #expect(try store.find(host: "127.0.0.1", port: server.port)?.publicKeyBase64
            == pinned.publicKeyBase64)
        #expect(server.channelRequests == 0)
    }

    /// An unknown key the decider refuses is `rejectedByUser` on both paths,
    /// asked exactly once, with nothing remembered.
    @Test(arguments: Path.allCases)
    func anUnknownKeyTheDeciderRefusesIsRejected(_ path: Path) async throws {
        let server = try await RefusingSSHServer.start()
        let directory = throwawayDirectory("unknown")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownHostsStore(directory: directory)

        let asked = UnitAskCounter()
        let raised = await dialError(
            path, port: server.port, store: store,
            decider: .asking { _ in
                asked.increment()
                return false
            })
        await server.close()

        #expect(raised as? HostKeyError == .rejectedByUser)
        #expect(asked.count == 1)
        #expect(try store.find(host: "127.0.0.1", port: server.port) == nil)
    }

    /// `.refusing` — the decider autostart hands in — on the forwarding
    /// path: an unknown key is `rejectedByUser`, nothing is remembered, and
    /// no channel is ever requested.
    @Test func anUnknownKeyUnderTheRefusingDeciderIsRejectedOnTheForwardingPath() async throws {
        let server = try await RefusingSSHServer.start()
        let directory = throwawayDirectory("refusing")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownHostsStore(directory: directory)

        let raised = await dialError(.forwarding, port: server.port, store: store, decider: .refusing)
        let requests = server.channelRequests
        await server.close()

        #expect(raised as? HostKeyError == .rejectedByUser)
        #expect(try store.find(host: "127.0.0.1", port: server.port) == nil)
        #expect(requests == 0)
    }

    /// The forwarding path authenticates and stops: the server that refuses
    /// every channel is asked for none, and the dial succeeds. The tab path
    /// against the same server asks for one — which is what proves the
    /// server's count is a real measurement — and fails, because that
    /// channel is its SFTP.
    @Test func theForwardingPathOpensNoChannelWhereTheTabPathOpensOne() async throws {
        let server = try await RefusingSSHServer.start()
        let directory = throwawayDirectory("channels")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownHostsStore(directory: directory)
        try store.upsert(KnownHostKey(
            host: "127.0.0.1", port: server.port,
            keyType: server.hostKey.keyType, publicKeyBase64: server.hostKey.publicKeyBase64))

        let forwarding = try await SSHForwardingConnection.connect(
            config: config(port: server.port), connectTimeout: .seconds(30),
            knownHosts: store, onUnknownHostKey: .refusing)
        let requestsAfterForwarding = server.channelRequests
        await forwarding.disconnect()

        let tabError = await dialError(.tab, port: server.port, store: store, decider: .refusing)
        let requestsAfterTab = server.channelRequests
        await server.close()

        #expect(requestsAfterForwarding == 0)
        #expect(tabError != nil)
        #expect(!(tabError is HostKeyError))
        #expect(requestsAfterTab == 1)
    }

    private func dialError(
        _ path: Path, port: Int, store: KnownHostsStore, decider: HostKeyDecider
    ) async -> (any Error)? {
        do {
            switch path {
            case .forwarding:
                let connection = try await SSHForwardingConnection.connect(
                    config: try config(port: port), connectTimeout: .seconds(30),
                    knownHosts: store, onUnknownHostKey: decider)
                await connection.disconnect()
            case .tab:
                let fileSystem = try await CitadelFileSystem.connect(
                    config: try config(port: port), connectTimeout: .seconds(30),
                    knownHosts: store, onUnknownHostKey: decider)
                await fileSystem.disconnect()
            }
            return nil
        } catch {
            return error
        }
    }

    private func config(port: Int) throws -> SSHConnectionConfig {
        try SSHConnectionConfig(
            host: "127.0.0.1", port: port, username: RefusingSSHServer.username,
            auth: .password(RefusingSSHServer.password))
    }
}

/// An SSH server on an ephemeral loopback port that authenticates one
/// username/password pair and refuses every channel open, counting them.
///
/// The host key is generated per server and never written anywhere. The
/// password is a fixture for this in-process server, not a credential.
private final class RefusingSSHServer: @unchecked Sendable {
    static let username = "unit"
    static let password = "unit-fixture"

    let port: Int
    let hostKey: HostKeyCandidate
    private let channel: Channel
    private let requests: UnitAskCounter

    var channelRequests: Int { requests.count }

    private init(port: Int, hostKey: HostKeyCandidate, channel: Channel, requests: UnitAskCounter) {
        self.port = port
        self.hostKey = hostKey
        self.channel = channel
        self.requests = requests
    }

    static func start() async throws -> RefusingSSHServer {
        let privateKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let requests = UnitAskCounter()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { child in
                child.eventLoop.makeCompletedFuture {
                    let handler = NIOSSHHandler(
                        role: .server(SSHServerConfiguration(
                            hostKeys: [privateKey], userAuthDelegate: PasswordDelegate())),
                        allocator: child.allocator,
                        inboundChildChannelInitializer: { sshChild, _ in
                            requests.increment()
                            return sshChild.eventLoop.makeFailedFuture(ChannelRefused())
                        })
                    try child.pipeline.syncOperations.addHandler(handler)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        guard let port = channel.localAddress?.port else {
            try await channel.close()
            throw ChannelRefused()
        }
        let hostKey = HostKeyCandidate(host: "127.0.0.1", port: port, publicKey: privateKey.publicKey)
        return RefusingSSHServer(port: port, hostKey: hostKey, channel: channel, requests: requests)
    }

    func close() async {
        try? await channel.close()
    }

    private struct ChannelRefused: Error {}

    private final class PasswordDelegate: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
        var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }

        func requestReceived(
            request: NIOSSHUserAuthenticationRequest,
            responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
        ) {
            guard request.username == RefusingSSHServer.username,
                case .password(let offered) = request.request,
                offered.password == RefusingSSHServer.password
            else {
                responsePromise.succeed(.failure)
                return
            }
            responsePromise.succeed(.success)
        }
    }
}

private final class UnitAskCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

private func throwawayDirectory(_ role: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macscp-kh-forwarding-unit-\(role)-\(UUID().uuidString)")
}
