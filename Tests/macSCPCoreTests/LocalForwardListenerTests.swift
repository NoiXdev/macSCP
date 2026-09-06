import Foundation
import MacSCPTestSupport
import NIOCore
import NIOPosix
import Testing

@testable import macSCPCore

/// The local-forward listener with a FAKE `direct-tcpip` factory: instead of
/// an SSH child channel, the factory hands back a plain loopback connection
/// to an echo server this test hosts. That keeps everything here on
/// 127.0.0.1 with no server, no container and no credentials, while still
/// exercising the real `ServerBootstrap`, the real accept path and the real
/// `BytePump` — the SSH half is proven separately, against the rig, in
/// `TunnelRigITests`.
///
/// Every listener binds port 0 and every wait is an `await`; nothing here
/// holds a fixed port or a wall-clock bound of its own (the suite's
/// `.timeLimit` is the only deadline).
@Suite("LocalForwardListener", .timeLimit(.minutes(1)))
struct LocalForwardListenerTests {

    @Test func bytesTravelToTheFactorysChannelAndBack() async throws {
        let echo = try await EchoServer.start()
        let listener = LocalForwardListener()
        let seen = TunnelEventRecorder()
        do {
            let port = try await listener.start(
                bind: "127.0.0.1", localPort: 0, host: "irrelevant.example", remotePort: 1,
                directTCPIPFactory: echo.factory(), observer: { seen.record($0) })
            #expect(port > 0)

            let inbox = TextInbox()
            let client = try await connectClient(port: port, inbox: inbox)
            try await awaitCancellably(client.writeAndFlush(ByteBuffer(string: "through the tunnel")))
            try await pollUntil("the echo comes back through the forward") {
                inbox.text == "through the tunnel"
            }
            try await pollUntil("the connection is reported open") { seen.events.contains(.opened) }

            client.close(promise: nil)
            try await awaitCancellably(client.closeFuture)
        } catch {
            await listener.stop()
            await echo.stop()
            throw error
        }
        await listener.stop()
        await echo.stop()
    }

    /// The listener's own port is reported after the bind, and a second
    /// listener asking for that same port is refused with the port in the
    /// failure — the sentence a user needs to free it.
    @Test func bindingAPortThatIsAlreadyBoundReportsItInUse() async throws {
        let echo = try await EchoServer.start()
        let first = LocalForwardListener()
        let second = LocalForwardListener()
        do {
            let port = try await first.start(
                bind: "127.0.0.1", localPort: 0, host: "irrelevant.example", remotePort: 1,
                directTCPIPFactory: echo.factory())
            #expect(first.boundPort == port)

            await #expect(throws: TunnelFailure.portInUse(port: port)) {
                _ = try await second.start(
                    bind: "127.0.0.1", localPort: port, host: "irrelevant.example", remotePort: 1,
                    directTCPIPFactory: echo.factory())
            }
            #expect(second.boundPort == nil)
        } catch {
            await second.stop()
            await first.stop()
            await echo.stop()
            throw error
        }
        await second.stop()
        await first.stop()
        await echo.stop()
    }

    /// `stop()` closes the server channel AND every pair it accepted, and
    /// returns only once they are gone — so the connected client sees its
    /// own channel close.
    @Test func stopClosesAnAcceptedPair() async throws {
        let echo = try await EchoServer.start()
        let listener = LocalForwardListener()
        let seen = TunnelEventRecorder()
        do {
            let port = try await listener.start(
                bind: "127.0.0.1", localPort: 0, host: "irrelevant.example", remotePort: 1,
                directTCPIPFactory: echo.factory(), observer: { seen.record($0) })

            let inbox = TextInbox()
            let client = try await connectClient(port: port, inbox: inbox)
            try await awaitCancellably(client.writeAndFlush(ByteBuffer(string: "hold this open")))
            try await pollUntil("the echo proves the pair is glued") {
                inbox.text == "hold this open"
            }

            await listener.stop()

            try await awaitCancellably(client.closeFuture)
            #expect(listener.boundPort == nil)
            let closed = seen.events.contains { event in
                if case .closed = event { return true }
                return false
            }
            #expect(closed)
        } catch {
            await listener.stop()
            await echo.stop()
            throw error
        }
        await echo.stop()
    }

    /// A factory that cannot open the channel — the server refusing
    /// `direct-tcpip`, the destination unreachable behind it — closes the
    /// connection it was accepted for and reports `channelOpenFailed`.
    ///
    /// The reason is the mapped one. `FactoryRefused` carries the
    /// destination in a stored property precisely so that a
    /// `String(describing:)` mapping would put it in the reason; the
    /// expectation below is that it does not.
    @Test func aFactoryFailureClosesTheConnectionAndReportsIt() async throws {
        let listener = LocalForwardListener()
        let failures = TunnelFailureRecorder()
        do {
            let port = try await listener.start(
                bind: "127.0.0.1", localPort: 0, host: "irrelevant.example", remotePort: 1,
                directTCPIPFactory: { _, _ in throw FactoryRefused() },
                onFailure: { failures.record($0) })

            let client = try await connectClient(port: port, inbox: TextInbox())
            try await awaitCancellably(client.closeFuture)
            try await pollUntil("the failure is reported") { failures.failures.count == 1 }

            let reported = try #require(failures.failures.first)
            #expect(reported == .channelOpenFailed(reason: DialSupport.reason(for: FactoryRefused())))
            guard case .channelOpenFailed(let reason) = reported else { return }
            let describesStoredProperties = reason.contains(FactoryRefused.destination)
            #expect(describesStoredProperties == false)
        } catch {
            await listener.stop()
            throw error
        }
        await listener.stop()
    }

    /// A `TunnelFailure` the factory raises itself travels OUT unchanged.
    ///
    /// It used to be re-mapped through `DialSupport.reason(for:)`, whose
    /// default arm reduces an error it does not spell out to
    /// `localizedDescription` — and `TunnelFailure` is not a
    /// `LocalizedError`, so what came out was "The operation couldn't be
    /// completed. (macSCPCore.TunnelFailure error 2.)". The factory's
    /// sentence is the only one that says why the SERVER refused, and it was
    /// replaced by a case index.
    @Test func aFactorysOwnTunnelFailureKeepsItsReason() async throws {
        let refusal = "the server refuses forwarding"
        let listener = LocalForwardListener()
        let failures = TunnelFailureRecorder()
        do {
            let port = try await listener.start(
                bind: "127.0.0.1", localPort: 0, host: "irrelevant.example", remotePort: 1,
                directTCPIPFactory: { _, _ in
                    throw TunnelFailure.channelOpenFailed(reason: refusal)
                },
                onFailure: { failures.record($0) })

            let client = try await connectClient(port: port, inbox: TextInbox())
            try await awaitCancellably(client.closeFuture)
            try await pollUntil("the failure is reported") { failures.failures.count == 1 }

            #expect(failures.failures.first == .channelOpenFailed(reason: refusal))
        } catch {
            await listener.stop()
            throw error
        }
        await listener.stop()
    }

    /// A failure AFTER the factory answered closes the channel it opened, and
    /// says so: `pumpFailed`, not `channelOpenFailed` — the server was
    /// willing, and there is something of its to clean up.
    ///
    /// The failure is provoked through the `.negotiated` seam: the
    /// negotiation closes the accepted connection and then names a
    /// destination anyway, so the factory opens a live channel and
    /// `BytePump.install` then fails on the closed local side. That is the
    /// shape that actually leaks — with the pump not glued, the remote
    /// channel learns nothing from the local one closing, and only the
    /// catch's own `close` reaches it.
    @Test func aFailureAfterTheOpenClosesTheOpenedChannelAndSaysSo() async throws {
        let echo = try await EchoServer.start()
        let listener = LocalForwardListener()
        let failures = TunnelFailureRecorder()
        let opened = OpenedChannelBox()
        let echoFactory = echo.factory()
        do {
            let port = try await listener.start(
                bind: "127.0.0.1", localPort: 0,
                destination: .negotiated { channel in
                    // Close the accepted side, and WAIT for it, so the
                    // failure below is the pipeline being gone rather than a
                    // race with it.
                    channel.close(promise: nil)
                    try await awaitCancellably(channel.closeFuture)
                    return ClosingNegotiation()
                },
                directTCPIPFactory: { host, port in
                    let channel = try await echoFactory(host, port)
                    opened.set(channel)
                    return channel
                },
                onFailure: { failures.record($0) })

            let client = try await connectClient(port: port, inbox: TextInbox())
            try await awaitCancellably(client.closeFuture)
            try await pollUntil("the failure is reported") { failures.failures.count == 1 }

            let reported = try #require(failures.failures.first)
            let isPumpFailure: Bool
            if case .pumpFailed = reported { isPumpFailure = true } else { isPumpFailure = false }
            #expect(isPumpFailure, "\(reported)")

            let throughTheServer = try #require(opened.channel)
            try await awaitCancellably(throughTheServer.closeFuture)
            #expect(throughTheServer.isActive == false)
        } catch {
            await listener.stop()
            await echo.stop()
            throw error
        }
        await listener.stop()
        await echo.stop()
    }

    /// One listener binds once. A second `start` — with or without a `stop()`
    /// in between — is refused rather than silently binding a port whose
    /// connections `OpenForwards` would then drop on the floor.
    @Test func aListenerCannotBeStartedTwice() async throws {
        let echo = try await EchoServer.start()
        let listener = LocalForwardListener()
        do {
            let port = try await listener.start(
                bind: "127.0.0.1", localPort: 0, host: "irrelevant.example", remotePort: 1,
                directTCPIPFactory: echo.factory())
            #expect(port > 0)

            await #expect(throws: TunnelFailure.alreadyStarted) {
                _ = try await listener.start(
                    bind: "127.0.0.1", localPort: 0, host: "irrelevant.example", remotePort: 1,
                    directTCPIPFactory: echo.factory())
            }

            await listener.stop()

            await #expect(throws: TunnelFailure.alreadyStarted) {
                _ = try await listener.start(
                    bind: "127.0.0.1", localPort: 0, host: "irrelevant.example", remotePort: 1,
                    directTCPIPFactory: echo.factory())
            }
        } catch {
            await listener.stop()
            await echo.stop()
            throw error
        }
        await echo.stop()
    }

    private func connectClient(port: Int, inbox: TextInbox) async throws -> Channel {
        try await awaitCancellably(
            ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(TextCollector(inbox: inbox))
                }
                .connect(host: "127.0.0.1", port: port))
    }
}

// MARK: - Helpers

/// A negotiation that names a destination and does nothing else. Its
/// `confirm` and `reject` are no-ops because the test that uses it never
/// gets that far — the accept path fails between the factory and them.
private struct ClosingNegotiation: ForwardNegotiation {
    let host = "irrelevant.example"
    let port = 1

    func confirm(on channel: Channel) async throws {}
    func reject(_ failure: TunnelFailure, on channel: Channel) async {}
}

private final class OpenedChannelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Channel?

    var channel: Channel? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ channel: Channel) {
        lock.lock()
        stored = channel
        lock.unlock()
    }
}

private struct FactoryRefused: Error {
    static let destination = "10.0.0.9:5432"
    let target = FactoryRefused.destination
}

/// A loopback echo server standing in for "the destination behind the SSH
/// server". The listener's factory hands back a fresh connection to it for
/// every accepted forward.
private struct EchoServer {
    let channel: Channel

    static func start() async throws -> EchoServer {
        let channel = try await awaitCancellably(
            ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(EchoHandler())
                }
                .bind(host: "127.0.0.1", port: 0))
        return EchoServer(channel: channel)
    }

    func factory() -> LocalForwardListener.DirectTCPIPFactory {
        let port = channel.localAddress?.port ?? 0
        return { _, _ in
            try await awaitCancellably(
                ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .channelOption(ChannelOptions.autoRead, value: false)
                    .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    .connect(host: "127.0.0.1", port: port))
        }
    }

    func stop() async {
        channel.close(promise: nil)
        try? await awaitCancellably(channel.closeFuture)
    }
}

private final class EchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.write(wrapOutboundOut(unwrapInboundIn(data)), promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }
}

private final class TunnelEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TunnelConnectionEvent] = []

    var events: [TunnelConnectionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ event: TunnelConnectionEvent) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }
}

private final class TunnelFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TunnelFailure] = []

    var failures: [TunnelFailure] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ failure: TunnelFailure) {
        lock.lock()
        recorded.append(failure)
        lock.unlock()
    }
}
