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
/// test and a password delegate, that accepts `session` channels, refuses
/// every other channel type, and records — per TCP connection — how many
/// channels were opened and what each session channel was asked to run.
///
/// That server is the seam. SFTP is a `subsystem` request named `sftp` on a
/// session channel, so "the server was asked for that subsystem zero times"
/// is "no SFTP was opened", read from the far side rather than from the code
/// under test — and an `exec` on a session channel, which the diagnosis's
/// jump probes run over a forwarding connection, is a different request the
/// server tallies apart. And because the server holds a host key the test
/// controls, the TOFU verdicts can be driven on both paths —
/// `SSHForwardingConnection.connect` and `CitadelFileSystem.connect` — and
/// compared.
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
        let server = try await RecordingSSHServer.start()
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
        #expect(server.channelOpens == 0)
    }

    /// An unknown key the decider refuses is `rejectedByUser` on both paths,
    /// asked exactly once, with nothing remembered.
    @Test(arguments: Path.allCases)
    func anUnknownKeyTheDeciderRefusesIsRejected(_ path: Path) async throws {
        let server = try await RecordingSSHServer.start()
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
        let server = try await RecordingSSHServer.start()
        let directory = throwawayDirectory("refusing")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownHostsStore(directory: directory)

        let raised = await dialError(.forwarding, port: server.port, store: store, decider: .refusing)
        let opens = server.channelOpens
        await server.close()

        #expect(raised as? HostKeyError == .rejectedByUser)
        #expect(try store.find(host: "127.0.0.1", port: server.port) == nil)
        #expect(opens == 0)
    }

    /// The forwarding path never asks for SFTP — including from a task its
    /// dial starts and nobody awaits. The tab path against the same server
    /// asks for it once, which is what proves the tally is a real
    /// measurement, and fails, because the server refuses the subsystem.
    ///
    /// **Read after ordering points, not after a race.** Measured on
    /// 2026-09-18 with an `openSFTP` planted in a background task in
    /// `SSHForwardingConnection.connect`, whose error nothing awaits: the
    /// previous version of this test was green in 10 of 10 runs. It read
    /// the server's count the moment the dial returned — 0 in 10 of 10
    /// instrumented runs — and then disconnected at once, and in 9 of those
    /// 10 the server never saw the planted open at all: the plant failed on
    /// the client (`NIOSSHError.tcpShutdown`, once
    /// `.creatingChannelAfterClosure`). Awaiting the server's observation of
    /// the close alone does not change that — red in 0 of 10 runs, no
    /// channel open seen — because the disconnect is what kills the plant.
    /// So the connection first does work of its own:
    ///
    /// 1. an `exec` round trip. The server answers it only after it has
    ///    processed everything the client wrote before the `exec` request.
    ///    Citadel writes a `subsystem` request from an event-loop callback
    ///    once its channel's open is confirmed (`SSHClient.openSFTP`), so an
    ///    SFTP open the server confirmed before answering the `exec` has
    ///    its `sftp` request written before the client handles that answer
    ///    — read from Citadel's source, not measured on its own;
    /// 2. then the disconnect, and an await on the server's own
    ///    observation of that TCP connection closing: messages on one
    ///    connection arrive in order, so everything the client wrote
    ///    before its close has been tallied by then.
    ///
    /// What no test can order against is a background task that has not
    /// reached the event loop by then. Against the plant above this test was
    /// red in 10 of 10 runs (2026-09-18): that is the measured sensitivity,
    /// not a proof.
    ///
    /// The `exec` doubles as the positive beside the negative: the tally
    /// sees requests on this connection, and counts that one as an `exec`,
    /// not as SFTP.
    @Test func theForwardingPathAsksForNoSFTPWhereTheTabPathAsksForIt() async throws {
        let server = try await RecordingSSHServer.start()
        let directory = throwawayDirectory("channels")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownHostsStore(directory: directory)
        try store.upsert(KnownHostKey(
            host: "127.0.0.1", port: server.port,
            keyType: server.hostKey.keyType, publicKeyBase64: server.hostKey.publicKeyBase64))
        let target = try #require(JumpProbeHost("target.invalid"))

        let forwarding = try await SSHForwardingConnection.connect(
            config: config(port: server.port), connectTimeout: .seconds(30),
            knownHosts: store, onUnknownHostKey: .refusing)
        let exec = try await forwarding.standardOutput(
            of: .resolve(target), into: JumpProbeTranscript())
        await forwarding.disconnect()
        try await server.closeObserved(onConnection: 0)
        let onForwarding = server.tally(onConnection: 0)

        let tabError = await dialError(.tab, port: server.port, store: store, decider: .refusing)
        try await server.closeObserved(onConnection: 1)
        let onTab = server.tally(onConnection: 1)
        await server.close()

        #expect(exec.exitStatus == 0)
        #expect(onForwarding.execRequests == 1)
        #expect(onForwarding.sftpSubsystemRequests == 0)
        #expect(tabError != nil)
        #expect(!(tabError is HostKeyError))
        #expect(onTab.sftpSubsystemRequests == 1)
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
            host: "127.0.0.1", port: port, username: RecordingSSHServer.username,
            auth: .password(RecordingSSHServer.password))
    }
}

/// An SSH server on an ephemeral loopback port that authenticates one
/// username/password pair, accepts `session` channels and refuses every
/// other channel type, and records per accepted TCP connection what it was
/// asked for.
///
/// A session channel's requests are told apart by the type NIOSSH decodes
/// them into: a `subsystem` request arrives as
/// `SSHChannelRequestEvent.SubsystemRequest` and counts as SFTP only when
/// its name is `sftp`; an `exec` arrives as `SSHChannelRequestEvent
/// .ExecRequest`. The server refuses the subsystem and closes that channel
/// (which fails the client's SFTP open), and answers an `exec` with success,
/// exit status 0 and a close — no output.
///
/// The host key is generated per server and never written anywhere. The
/// password is a fixture for this in-process server, not a credential.
private final class RecordingSSHServer: @unchecked Sendable {
    static let username = "unit"
    static let password = "unit-fixture"

    let port: Int
    let hostKey: HostKeyCandidate
    private let channel: Channel
    private let log: RequestLog

    /// Channels of any type the clients asked to open, over every connection.
    var channelOpens: Int { log.channelOpens }

    private init(port: Int, hostKey: HostKeyCandidate, channel: Channel, log: RequestLog) {
        self.port = port
        self.hostKey = hostKey
        self.channel = channel
        self.log = log
    }

    static func start() async throws -> RecordingSSHServer {
        let privateKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let log = RequestLog()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { child in
                child.eventLoop.makeCompletedFuture {
                    let connection = log.accept(closing: child.closeFuture)
                    let handler = NIOSSHHandler(
                        role: .server(SSHServerConfiguration(
                            hostKeys: [privateKey], userAuthDelegate: PasswordDelegate())),
                        allocator: child.allocator,
                        inboundChildChannelInitializer: { sshChild, type in
                            log.recordOpen(on: connection)
                            guard type == .session else {
                                return sshChild.eventLoop.makeFailedFuture(ChannelRefused())
                            }
                            return sshChild.eventLoop.makeCompletedFuture {
                                try sshChild.pipeline.syncOperations.addHandler(
                                    SessionRequestRecorder(log: log, connection: connection))
                            }
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
        return RecordingSSHServer(port: port, hostKey: hostKey, channel: channel, log: log)
    }

    /// Returns once the server has seen the `index`-th accepted connection
    /// (0-based, in accept order) close. Messages on one connection arrive
    /// in order, so everything that client wrote before its close has been
    /// tallied by then.
    func closeObserved(onConnection index: Int) async throws {
        guard let closing = log.closeFuture(ofConnection: index) else {
            throw NoSuchConnection(index: index)
        }
        try await closing.get()
    }

    func tally(onConnection index: Int) -> RequestLog.Tally {
        log.tally(ofConnection: index)
    }

    func close() async {
        try? await channel.close()
    }

    private struct ChannelRefused: Error {}

    private struct NoSuchConnection: Error {
        let index: Int
    }

    private final class PasswordDelegate: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
        var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }

        func requestReceived(
            request: NIOSSHUserAuthenticationRequest,
            responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
        ) {
            guard request.username == RecordingSSHServer.username,
                case .password(let offered) = request.request,
                offered.password == RecordingSSHServer.password
            else {
                responsePromise.succeed(.failure)
                return
            }
            responsePromise.succeed(.success)
        }
    }

    /// Tallies a session channel's requests and answers them — see the
    /// server's doc comment for which answer each gets.
    private final class SessionRequestRecorder: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = SSHChannelData

        private let log: RequestLog
        private let connection: Int

        init(log: RequestLog, connection: Int) {
            self.log = log
            self.connection = connection
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            switch event {
            case let request as SSHChannelRequestEvent.SubsystemRequest:
                log.recordSubsystem(named: request.subsystem, on: connection)
                if request.wantReply {
                    context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
                }
                context.close(promise: nil)
            case let request as SSHChannelRequestEvent.ExecRequest:
                log.recordExec(on: connection)
                if request.wantReply {
                    context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
                }
                context.triggerUserOutboundEvent(
                    SSHChannelRequestEvent.ExitStatus(exitStatus: 0), promise: nil)
                context.close(promise: nil)
            default:
                context.fireUserInboundEventTriggered(event)
            }
        }
    }
}

/// What `RecordingSSHServer` saw, per accepted TCP connection. Written from
/// the connections' event loop, read from the test, hence the lock.
private final class RequestLog: @unchecked Sendable {
    struct Tally: Equatable {
        var channelOpens = 0
        var sftpSubsystemRequests = 0
        var otherSubsystemRequests = 0
        var execRequests = 0
    }

    private let lock = NSLock()
    private var tallies: [Tally] = []
    private var closeFutures: [EventLoopFuture<Void>] = []

    /// Registers a newly accepted connection and returns its index.
    func accept(closing: EventLoopFuture<Void>) -> Int {
        lock.withLock {
            tallies.append(Tally())
            closeFutures.append(closing)
            return tallies.count - 1
        }
    }

    func recordOpen(on connection: Int) {
        lock.withLock { tallies[connection].channelOpens += 1 }
    }

    func recordSubsystem(named name: String, on connection: Int) {
        lock.withLock {
            if name == "sftp" {
                tallies[connection].sftpSubsystemRequests += 1
            } else {
                tallies[connection].otherSubsystemRequests += 1
            }
        }
    }

    func recordExec(on connection: Int) {
        lock.withLock { tallies[connection].execRequests += 1 }
    }

    var channelOpens: Int {
        lock.withLock { tallies.reduce(0) { $0 + $1.channelOpens } }
    }

    func tally(ofConnection index: Int) -> Tally {
        lock.withLock { tallies.indices.contains(index) ? tallies[index] : Tally() }
    }

    func closeFuture(ofConnection index: Int) -> EventLoopFuture<Void>? {
        lock.withLock { closeFutures.indices.contains(index) ? closeFutures[index] : nil }
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
