import Foundation
import MacSCPTestSupport
import NIOCore
import NIOPosix
import Testing

@testable import macSCPCore

/// `LiveTunnelRuntimeFactory` hands each forward's per-connection failure
/// seam to its caller — the listeners' `onFailure`, the remote forward's
/// `onConnectionFailure`. The BACKLOG row "A local or dynamic forward's
/// per-connection failures are never reported" recorded that the factory
/// passed none of the three, which no test could see: the listeners' own
/// suites drive the seams directly, and `TunnelRunnerTests` replaces the
/// factory with a fake.
///
/// So everything here goes through the REAL factory: real loopback
/// listeners on port 0, a connection double standing in for the SSH server
/// and refusing every channel, no rig. The SSH half is measured against the
/// rig in `TunnelRigITests.aFailedConnectionIsCountedWhileTheForwardStaysUp`.
@Suite("Tunnel runtime factory wiring", .timeLimit(.minutes(1)))
struct TunnelRuntimeFactoryWiringTests {

    /// End to end through the runner: a `-L` whose server refuses the
    /// channel leaves the tunnel `active`, with the failure counted.
    @Test func aRefusedLocalChannelReachesTheRunnersState() async throws {
        let connection = RefusingConnection()
        let profile = TunnelProfile(
            sessionID: UUID(), name: "web",
            kind: .local(bind: "127.0.0.1", localPort: 0, host: "internal", remotePort: 80))
        let runner = TunnelRunner(
            profile: profile, connect: { _ in connection },
            runtimes: LiveTunnelRuntimeFactory(), sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)
        do {
            await runner.start(decider: .asking { _ in true })
            try await states.waitFor(.active(connections: 0))
            let port = try #require(await runner.boundPort)

            let client = try await connectClient(port: port)
            try await awaitCancellably(client.closeFuture)
            try await states.waitFor(
                .active(connections: 0, failedConnections: 1, lastFailure: .channelOpenFailed))
        } catch {
            await runner.stop()
            throw error
        }
        await runner.stop()
    }

    /// `-D`: a CONNECT the server refuses is reported; a client that never
    /// spoke SOCKS5 is not — it is the client's failure, not the tunnel's.
    /// The positive (one failure, from the second client) is what makes the
    /// negative (not two) mean something.
    @Test func aDynamicForwardReportsARefusedConnectAndNotABadClient() async throws {
        let failures = WiringFailureRecorder()
        let runtime = try await LiveTunnelRuntimeFactory().start(
            .dynamic(bind: "127.0.0.1", localPort: 0), over: RefusingConnection(),
            observer: { _ in }, onConnectionFailure: { failures.record($0) }, onEnded: {})
        do {
            let port = try #require(runtime.boundPort)

            let stranger = try await connectClient(port: port)
            try await awaitCancellably(
                stranger.writeAndFlush(ByteBuffer(string: "GET / HTTP/1.1\r\n")))
            try await awaitCancellably(stranger.closeFuture)

            let socks = try await connectClient(port: port)
            let host = Array("echo.example".utf8)
            let connect: [UInt8] =
                [0x05, 0x01, 0x00] + [0x05, 0x01, 0x00, 0x03, UInt8(host.count)] + host + [0x00, 0x07]
            try await awaitCancellably(socks.writeAndFlush(ByteBuffer(bytes: connect)))
            try await awaitCancellably(socks.closeFuture)

            // Waits for the SOCKS client's own failure — the connection's
            // refusal passes through unchanged, so its reason names it —
            // rather than for any failure: a stranger wrongly reported would
            // otherwise satisfy the wait and leave the count racing the
            // second report.
            try await pollUntil("the refused CONNECT is reported") {
                failures.failures.contains(RefusingConnection.refusal)
            }
            #expect(failures.failures == [RefusingConnection.refusal])
        } catch {
            await runtime.stop()
            throw error
        }
        await runtime.stop()
    }

    /// `-R`: an inbound connection whose local target refuses is reported.
    @Test func aRemoteForwardReportsAnUnreachableLocalTarget() async throws {
        let closedPort = try await loopbackPortNothingListensOn()
        let origin = try await AcceptingServer.start()
        let connection = RefusingConnection()
        let failures = WiringFailureRecorder()
        let runtime = try await LiveTunnelRuntimeFactory().start(
            .remote(
                bind: "127.0.0.1", remotePort: 45_000, localHost: "127.0.0.1",
                localPort: closedPort),
            over: connection,
            observer: { _ in }, onConnectionFailure: { failures.record($0) }, onEnded: {})
        do {
            let inbound = try await origin.connectWithAutoReadOff()
            await #expect(throws: TunnelFailure.self) { try await connection.deliver(inbound) }

            #expect(failures.failures.count == 1)
            let isConnectFailure: Bool = {
                guard case .connectFailed = failures.failures.first else { return false }
                return true
            }()
            #expect(isConnectFailure)
        } catch {
            await runtime.stop()
            await origin.stop()
            throw error
        }
        await runtime.stop()
        await origin.stop()
    }

    private func connectClient(port: Int) async throws -> Channel {
        try await awaitCancellably(
            ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connect(host: "127.0.0.1", port: port))
    }
}

// MARK: - Doubles

/// A server that refuses every `direct-tcpip` channel, and forwards
/// remotely by remembering the per-connection closure and parking until
/// cancelled — Citadel's own shape.
private final class RefusingConnection: TunnelSSHConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Channel) async throws -> Void)?

    /// Never drops: nothing here disconnects it.
    var isConnected: Bool { true }

    func onDisconnect(_ handler: @escaping @Sendable () -> Void) {}

    static let refusal = TunnelFailure.channelOpenFailed(reason: "administratively prohibited")

    func openDirectTCPIP(host: String, port: Int) async throws -> Channel {
        throw Self.refusal
    }

    func withRemotePortForward(
        bind: String, port: Int, onOpen: @escaping @Sendable (Int) -> Void,
        handleChannel: @escaping @Sendable (Channel) async throws -> Void
    ) async throws {
        lock.withLock { self.handler = handleChannel }
        onOpen(port)
        // Parks until `stop()` cancels the task; no deadline of its own.
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    /// Hands one inbound connection to the forward, rethrowing what its
    /// closure threw.
    func deliver(_ channel: Channel) async throws {
        let registered = lock.withLock { handler }
        guard let registered else {
            Issue.record("the forward registered no handler")
            return
        }
        try await registered(channel)
    }

    func disconnect() async {}
}

private final class WiringFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TunnelFailure] = []

    var failures: [TunnelFailure] { lock.withLock { recorded } }

    func record(_ failure: TunnelFailure) {
        lock.withLock { recorded.append(failure) }
    }
}

/// Bound to find a free loopback number, then closed before it is used.
private func loopbackPortNothingListensOn() async throws -> Int {
    let probe = try await awaitCancellably(
        ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0))
    let port = probe.localAddress?.port ?? 0
    probe.close(promise: nil)
    try await awaitCancellably(probe.closeFuture)
    return port
}

/// Where an "inbound" channel comes from: a loopback server that accepts and
/// holds. The client end, with `autoRead` off, is what an SSH child channel
/// looks like to `handleChannel`.
private struct AcceptingServer {
    let channel: Channel

    static func start() async throws -> AcceptingServer {
        let channel = try await awaitCancellably(
            ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: 0))
        return AcceptingServer(channel: channel)
    }

    func connectWithAutoReadOff() async throws -> Channel {
        try await awaitCancellably(
            ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelOption(ChannelOptions.autoRead, value: false)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .connect(host: "127.0.0.1", port: channel.localAddress?.port ?? 0))
    }

    func stop() async {
        channel.close(promise: nil)
        try? await awaitCancellably(channel.closeFuture)
    }
}
