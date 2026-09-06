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
