import Foundation
import MacSCPTestSupport
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
@testable import macSCPCore

/// The reading end of a control connection: an async iterator kept in a class
/// because an actor cannot call a mutating async method on a stored property.
/// Only the owning client reads from it, one reply at a time.
final class LoopbackLineSource: @unchecked Sendable {
    private var iterator: AsyncStream<ByteBuffer>.Iterator

    init(_ stream: AsyncStream<ByteBuffer>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> ByteBuffer? {
        await iterator.next()
    }
}

/// What a `LoopbackFTPClient` can fail with.
enum LoopbackFTPClientError: Error, Equatable {
    /// The peer closed the connection before a whole reply arrived.
    case connectionClosed
    /// The TLS handshake did not complete.
    case handshakeFailed
}

/// A minimal FTP client for the loopback server's own tests: just enough
/// protocol to drive the server, and deliberately NOT the production client.
/// It makes no attempt to be robust, to resume a TLS session, or to verify a
/// certificate — a test that wants any of those has found something the
/// production client (Task 5) owns.
///
/// It parses replies with the production `FTPReplyAccumulator`, so a stray or
/// malformed line from a hostile seam surfaces here the way it will there.
actor LoopbackFTPClient {
    private let channel: Channel
    private let lines: LoopbackLineSource
    private let handshake: LoopbackClientHandshake

    private init(
        channel: Channel, lines: AsyncStream<ByteBuffer>, handshake: LoopbackClientHandshake
    ) {
        self.channel = channel
        self.lines = LoopbackLineSource(lines)
        self.handshake = handshake
    }

    /// Connects to `host:port`. With `implicitTLS` the TLS handshake starts at
    /// once, as an implicit-FTPS client's does; the greeting is then the first
    /// thing `readReply()` returns.
    static func connect(host: String, port: Int, implicitTLS: Bool = false) async throws -> LoopbackFTPClient {
        let (lines, continuation) = AsyncStream.makeStream(of: ByteBuffer.self)
        let handshake = LoopbackClientHandshake()
        let tlsContext = implicitTLS ? try Self.makeContext() : nil

        let channel = try await awaitCancellably(
            ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let pipeline = channel.pipeline.syncOperations
                        if let tlsContext {
                            try pipeline.addHandler(
                                NIOSSLClientHandler(context: tlsContext, serverHostname: nil))
                        }
                        try pipeline.addHandler(ByteToMessageHandler(CRLFLineDecoder()))
                        try pipeline.addHandler(
                            LoopbackClientSink(deliver: continuation, handshake: handshake))
                    }
                }
                .connect(host: host, port: port))
        let client = LoopbackFTPClient(channel: channel, lines: lines, handshake: handshake)
        if implicitTLS { try await client.waitForHandshake() }
        return client
    }

    /// A client-side context that accepts any certificate: the server's is
    /// self-signed, minted for the run.
    fileprivate static func makeContext() throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = .none
        return try NIOSSLContext(configuration: configuration)
    }

    // MARK: Control connection

    func send(_ command: String) async throws {
        try await awaitCancellably(channel.writeAndFlush(ByteBuffer(string: command + "\r\n")))
    }

    /// Reads one complete reply, joining a multiline one.
    func readReply() async throws -> FTPReply {
        var partial: [String] = []
        while let buffer = await lines.next() {
            if let reply = try FTPReplyAccumulator.feed(String(buffer: buffer), into: &partial) {
                return reply
            }
        }
        throw LoopbackFTPClientError.connectionClosed
    }

    /// `send` then `readReply`.
    func command(_ command: String) async throws -> FTPReply {
        try await send(command)
        return try await readReply()
    }

    /// Wraps the open control connection in TLS. Call it after a `234`.
    func startTLS() async throws {
        let context = try Self.makeContext()
        let channel = self.channel
        try await awaitCancellably(
            channel.eventLoop.submit {
                try channel.pipeline.syncOperations.addHandler(
                    NIOSSLClientHandler(context: context, serverHostname: nil), position: .first)
            })
        try await waitForHandshake()
    }

    private func waitForHandshake() async throws {
        guard await handshake.wait() else { throw LoopbackFTPClientError.handshakeFailed }
    }

    /// Logs in with the credentials; returns the reply to `PASS`.
    func login(_ credentials: LoopbackFTPCredentials) async throws -> FTPReply {
        _ = try await command("USER \(credentials.username)")
        return try await command("PASS \(credentials.password)")
    }

    /// Ends the connection. Idempotent.
    func close() async {
        _ = try? await awaitCancellably(channel.close())
    }

    // MARK: Data connections

    /// Opens a data connection to `host:port`. With `protected` the connection
    /// starts a FRESH TLS handshake — it never offers the control connection's
    /// session, because swift-nio-ssl has no way to (see the dependency record,
    /// "swift-nio-ssl").
    func openData(host: String, port: Int, protected: Bool) async throws -> LoopbackFTPClientData {
        let (chunks, continuation) = AsyncStream.makeStream(of: ByteBuffer.self)
        let handshake = LoopbackClientHandshake()
        let tlsContext = protected ? try Self.makeContext() : nil
        let channel = try await awaitCancellably(
            ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let pipeline = channel.pipeline.syncOperations
                        if let tlsContext {
                            try pipeline.addHandler(
                                NIOSSLClientHandler(context: tlsContext, serverHostname: nil))
                        }
                        try pipeline.addHandler(
                            LoopbackClientSink(deliver: continuation, handshake: handshake))
                    }
                }
                .connect(host: host, port: port))
        return LoopbackFTPClientData(
            channel: channel, chunks: chunks, handshake: handshake, isProtected: protected)
    }
}

/// The client end of one data connection.
struct LoopbackFTPClientData: Sendable {
    fileprivate let channel: Channel
    fileprivate let chunks: AsyncStream<ByteBuffer>
    fileprivate let handshake: LoopbackClientHandshake
    let isProtected: Bool

    /// True once the TLS handshake finished; false if the connection ended
    /// first. Meaningful for a protected connection only.
    func handshakeCompleted() async -> Bool { await handshake.wait() }

    /// Reads until the server closes the connection.
    func readToEnd() async -> Data {
        var data = Data()
        for await chunk in chunks { data.append(contentsOf: chunk.readableBytesView) }
        return data
    }

    func write(_ data: Data) async throws {
        try await awaitCancellably(channel.writeAndFlush(ByteBuffer(bytes: data)))
    }

    func close() async {
        _ = try? await awaitCancellably(channel.close())
    }
}

/// Settles once, with whether a TLS handshake completed.
final class LoopbackClientHandshake: Sendable {
    private let signal = AsyncSignal()
    private let outcome = NIOLockedValueBox<Bool?>(nil)

    func settle(_ completed: Bool) {
        let first = outcome.withLockedValue { value -> Bool in
            guard value == nil else { return false }
            value = completed
            return true
        }
        if first { signal.signal() }
    }

    /// Waits for the handshake to complete or the connection to end.
    func wait() async -> Bool {
        _ = await signal.wait()
        return outcome.withLockedValue { $0 } ?? false
    }
}

/// Hands whatever reaches the end of the client pipeline to a stream, and
/// reports the TLS handshake.
final class LoopbackClientSink: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let deliver: AsyncStream<ByteBuffer>.Continuation
    private let handshake: LoopbackClientHandshake

    init(deliver: AsyncStream<ByteBuffer>.Continuation, handshake: LoopbackClientHandshake) {
        self.deliver = deliver
        self.handshake = handshake
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        deliver.yield(unwrapInboundIn(data))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tls = event as? TLSUserEvent, case .handshakeCompleted = tls {
            handshake.settle(true)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        handshake.settle(false)
        deliver.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        handshake.settle(false)
        deliver.finish()
        context.close(promise: nil)
    }
}
