import Foundation
import MacSCPTestSupport
import NIOCore
import NIOPosix
import Testing

@testable import macSCPCore

/// The dynamic-forward listener end to end on loopback, with a FAKE
/// `direct-tcpip` factory — the same shape `LocalForwardListenerTests` uses:
/// instead of an SSH child channel the factory hands back a plain connection
/// to an echo server this file hosts. What is measured here is the whole
/// accept path with the SOCKS5 handshake in front of it, driven by a
/// hand-written client that speaks the protocol in bytes.
///
/// Every listener binds port 0 and every wait is an `await`; nothing here
/// holds a fixed port or a wall-clock bound of its own.
@Suite("SOCKS5Listener", .timeLimit(.minutes(1)))
struct SOCKS5ListenerTests {

    /// Greeting, CONNECT, the two replies, then ordinary bytes through the
    /// pump — the whole conversation a SOCKS client has.
    @Test func aSOCKS5ConnectIsFollowedByPumpedBytes() async throws {
        let echo = try await EchoServer.start()
        let listener = SOCKS5Listener()
        let asked = DestinationRecorder()
        do {
            let port = try await listener.start(
                bind: "127.0.0.1", localPort: 0,
                directTCPIPFactory: { host, port in
                    asked.record(host: host, port: port)
                    return try await echo.connect()
                })
            #expect(port > 0)

            let inbox = ByteInbox()
            let client = try await connectClient(port: port, inbox: inbox)

            try await awaitCancellably(client.writeAndFlush(ByteBuffer(bytes: [0x05, 0x01, 0x00])))
            try await pollUntil("the method selection comes back") { inbox.bytes.count >= 2 }
            #expect(Array(inbox.bytes.prefix(2)) == [0x05, 0x00])

            try await awaitCancellably(
                client.writeAndFlush(ByteBuffer(bytes: connectToADomain)))
            try await pollUntil("the success reply comes back") { inbox.bytes.count >= 12 }
            #expect(Array(inbox.bytes[2..<12]) == [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
            #expect(asked.destinations == [DestinationRecorder.Asked(host: "echo.example", port: 7)])

            try await awaitCancellably(client.writeAndFlush(ByteBuffer(string: "hello")))
            try await pollUntil("the echo comes back through the dynamic forward") {
                inbox.bytes.count >= 17
            }
            #expect(String(decoding: inbox.bytes[12...], as: UTF8.self) == "hello")

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

    /// A client that pipelines its payload into the SAME write as the
    /// CONNECT request: the bytes reach the listener before there is anywhere
    /// to put them, and must still come out of the far end.
    @Test func aPayloadPipelinedBehindConnectIsNotLost() async throws {
        let echo = try await EchoServer.start()
        let listener = SOCKS5Listener()
        do {
            let port = try await listener.start(
                bind: "127.0.0.1", localPort: 0,
                directTCPIPFactory: { _, _ in try await echo.connect() })

            let inbox = ByteInbox()
            let client = try await connectClient(port: port, inbox: inbox)
            try await awaitCancellably(client.writeAndFlush(ByteBuffer(bytes: [0x05, 0x01, 0x00])))
            try await pollUntil("the method selection comes back") { inbox.bytes.count >= 2 }

            try await awaitCancellably(
                client.writeAndFlush(ByteBuffer(bytes: connectToADomain + Array("pipelined".utf8))))
            try await pollUntil("the pipelined payload is echoed back") {
                inbox.bytes.count >= 12 + 9
            }
            #expect(String(decoding: inbox.bytes[12...], as: UTF8.self) == "pipelined")

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

    /// A factory that refuses answers the SOCKS client with a failure reply
    /// before the connection closes, and reports the failure to the tunnel —
    /// both, not one or the other.
    ///
    /// Parameterised over WHICH failure, because since
    /// `LocalForwardListener.acceptFailure` passes a `TunnelFailure` through
    /// unchanged, the code the client reads is the one the factory's own case
    /// chose. A foreign error stands in for "anything the listener had to map
    /// itself". The reason strings are deliberately different from each other
    /// and never asserted on: the mapping reads the case, and a test that
    /// read the text would licence a mapping that did.
    @Test(arguments: [
        SOCKS5RefusalCase(
            label: "a foreign error before the factory answers",
            failure: nil, expected: 0x01),
        SOCKS5RefusalCase(
            label: "channelOpenFailed, as openDirectTCPIP raises it",
            failure: .channelOpenFailed(reason: "the server refuses forwarding"), expected: 0x01),
        SOCKS5RefusalCase(
            label: "connectFailed, the one case with a code of its own",
            failure: .connectFailed(reason: "nothing listening there"), expected: 0x05),
        SOCKS5RefusalCase(
            label: "pumpFailed, raised after the channel is open",
            failure: .pumpFailed(reason: "the pump did not install"), expected: 0x01),
    ])
    func aRefusedChannelAnswersTheClientAndReportsTheFailure(_ refusal: SOCKS5RefusalCase) async throws {
        let listener = SOCKS5Listener()
        let failures = FailureRecorder()
        do {
            let raised = refusal.failure
            let port = try await listener.start(
                bind: "127.0.0.1", localPort: 0,
                directTCPIPFactory: { _, _ in
                    if let raised { throw raised }
                    throw FactoryRefusedTheChannel()
                },
                onFailure: { failures.record($0) })

            let inbox = ByteInbox()
            let client = try await connectClient(port: port, inbox: inbox)
            try await awaitCancellably(
                client.writeAndFlush(ByteBuffer(bytes: [0x05, 0x01, 0x00] + connectToADomain)))
            try await pollUntil("the method selection and the failure reply come back") {
                inbox.bytes.count >= 12
            }
            try await awaitCancellably(client.closeFuture)

            #expect(Array(inbox.bytes.prefix(2)) == [0x05, 0x00])
            #expect(
                Array(inbox.bytes[2..<12])
                    == [0x05, refusal.expected, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
            try await pollUntil("the failure is reported") { failures.failures.count == 1 }
            let reported = try #require(failures.failures.first)
            if let raised {
                // Passed through unchanged: the factory's own case is what
                // chose the reply code above.
                #expect(reported == raised)
            } else {
                #expect(
                    reported
                        == .channelOpenFailed(
                            reason: DialSupport.reason(for: FactoryRefusedTheChannel())))
            }
        } catch {
            await listener.stop()
            throw error
        }
        await listener.stop()
    }

    /// A client that never says anything SOCKS5 is dropped, and this is NOT
    /// reported as a tunnel failure: the tunnel is fine, the client is not.
    @Test func aClientThatIsNotSpeakingSOCKS5IsDroppedWithoutAFailure() async throws {
        let listener = SOCKS5Listener()
        let failures = FailureRecorder()
        do {
            let port = try await listener.start(
                bind: "127.0.0.1", localPort: 0,
                directTCPIPFactory: { _, _ in
                    Issue.record("the factory must not be reached")
                    throw FactoryRefusedTheChannel()
                },
                onFailure: { failures.record($0) })

            let client = try await connectClient(port: port, inbox: ByteInbox())
            try await awaitCancellably(client.writeAndFlush(ByteBuffer(string: "GET / HTTP/1.1\r\n")))
            try await awaitCancellably(client.closeFuture)
            #expect(failures.failures.isEmpty)
        } catch {
            await listener.stop()
            throw error
        }
        await listener.stop()
    }

    private func connectClient(port: Int, inbox: ByteInbox) async throws -> Channel {
        try await awaitCancellably(
            ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(ByteCollector(inbox: inbox))
                }
                .connect(host: "127.0.0.1", port: port))
    }
}

// MARK: - Fixtures and helpers

/// `05 01 00 03 0c "echo.example" 00 07` — CONNECT echo.example:7. The
/// destination is never dialled (the factory ignores it); it is asserted on,
/// which is what makes the decoding measurable from outside.
private let connectToADomain: [UInt8] = [
    0x05, 0x01, 0x00, 0x03, 0x0C,
    101, 99, 104, 111, 46, 101, 120, 97, 109, 112, 108, 101,
    0x00, 0x07,
]

private struct FactoryRefusedTheChannel: Error {}

/// One way a `direct-tcpip` factory can refuse, and the SOCKS5 code the
/// client must read for it. `failure: nil` means "throw something that is not
/// a `TunnelFailure` at all", which is the arm the listener maps itself.
struct SOCKS5RefusalCase: Sendable, CustomStringConvertible {
    let label: String
    let failure: TunnelFailure?
    let expected: UInt8

    var description: String { label }
}

private struct EchoServer {
    let channel: Channel

    static func start() async throws -> EchoServer {
        let channel = try await awaitCancellably(
            ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(EchoBack())
                }
                .bind(host: "127.0.0.1", port: 0))
        return EchoServer(channel: channel)
    }

    /// One fresh connection to the echo server, handed back with `autoRead`
    /// off — the contract `LocalForwardListener.DirectTCPIPFactory` states.
    func connect() async throws -> Channel {
        let port = channel.localAddress?.port ?? 0
        return try await awaitCancellably(
            ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelOption(ChannelOptions.autoRead, value: false)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .connect(host: "127.0.0.1", port: port))
    }

    func stop() async {
        channel.close(promise: nil)
        try? await awaitCancellably(channel.closeFuture)
    }
}

private final class EchoBack: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.write(wrapOutboundOut(unwrapInboundIn(data)), promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }
}

private final class ByteInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [UInt8] = []

    var bytes: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func append(_ chunk: [UInt8]) {
        lock.lock()
        collected += chunk
        lock.unlock()
    }
}

private final class ByteCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let inbox: ByteInbox

    init(inbox: ByteInbox) { self.inbox = inbox }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        inbox.append(buffer.readBytes(length: buffer.readableBytes) ?? [])
    }
}

private final class DestinationRecorder: @unchecked Sendable {
    struct Asked: Equatable, Sendable {
        let host: String
        let port: Int
    }

    private let lock = NSLock()
    private var recorded: [Asked] = []

    var destinations: [Asked] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(host: String, port: Int) {
        lock.lock()
        recorded.append(Asked(host: host, port: port))
        lock.unlock()
    }
}

private final class FailureRecorder: @unchecked Sendable {
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
