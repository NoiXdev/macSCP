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
    /// The connection failed with an error rather than closing. The text is the
    /// transport's own description, never anything the server sent.
    case connectionFailed(String)
    /// The TLS handshake did not complete.
    case handshakeFailed
    /// Nothing that ended the wait arrived within the client's hang bound.
    case noReplyWithin(milliseconds: Int64)
}

/// Why a client's stream ended, when it was not the peer closing cleanly:
/// a transport error, or the hang bound firing. Written from event-loop
/// callbacks, read by the awaiting side; without it a swallowed error and a
/// quiet stream look the same from where the test is waiting.
final class LoopbackClientEnd: Sendable {
    enum Cause: Sendable, Equatable {
        case none
        case failed(String)
        case timedOut
    }

    private let cause = NIOLockedValueBox(Cause.none)

    var value: Cause { cause.withLockedValue { $0 } }

    func noteError(_ error: Error) {
        cause.withLockedValue { if $0 == .none { $0 = .failed("\(error)") } }
    }

    func noteTimeout() {
        cause.withLockedValue { if $0 == .none { $0 = .timedOut } }
    }
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
    private let deliver: AsyncStream<ByteBuffer>.Continuation
    private let handshake: LoopbackClientHandshake
    private let end: LoopbackClientEnd
    private let replyBound: TimeAmount

    private init(
        channel: Channel, lines: AsyncStream<ByteBuffer>,
        deliver: AsyncStream<ByteBuffer>.Continuation, handshake: LoopbackClientHandshake,
        end: LoopbackClientEnd, replyBound: TimeAmount
    ) {
        self.channel = channel
        self.lines = LoopbackLineSource(lines)
        self.deliver = deliver
        self.handshake = handshake
        self.end = end
        self.replyBound = replyBound
    }

    /// Connects to `host:port`. With `implicitTLS` the TLS handshake starts at
    /// once, as an implicit-FTPS client's does; the greeting is then the first
    /// thing `readReply()` returns.
    ///
    /// `replyBound` is a HANG bound, not an assertion about speed: a wait that
    /// outlasts it throws `noReplyWithin` instead of parking the test. Nothing
    /// asserts how long a reply took, so it is not the wall-clock ceiling the
    /// project forbids; it exists because `LoopbackFTPServerTests.running` stops
    /// the server only after its body returns, so a parked read never reaches
    /// the thing that would unblock it, and a `.timeLimit` that fires on a
    /// saturated runner loses the test's name (CLAUDE.md, the 2026-10-30
    /// update). The default sits under the suites' five-minute limit so the
    /// named error arrives first, and above the 131 s a whole saturated suite
    /// took on the three-core runner, so it measures a hang and not load.
    static func connect(
        host: String, port: Int, implicitTLS: Bool = false,
        replyBound: TimeAmount = .seconds(180)
    ) async throws -> LoopbackFTPClient {
        let (lines, continuation) = AsyncStream.makeStream(of: ByteBuffer.self)
        let handshake = LoopbackClientHandshake()
        let end = LoopbackClientEnd()
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
                            LoopbackClientSink(deliver: continuation, handshake: handshake, end: end))
                    }
                }
                .connect(host: host, port: port))
        let client = LoopbackFTPClient(
            channel: channel, lines: lines, deliver: continuation, handshake: handshake,
            end: end, replyBound: replyBound)
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
        let end = self.end
        let deliver = self.deliver
        let timer = channel.eventLoop.scheduleTask(in: replyBound) {
            end.noteTimeout()
            deliver.finish()
        }
        defer { timer.cancel() }

        var partial: [String] = []
        while let buffer = await lines.next() {
            if let reply = try FTPReplyAccumulator.feed(String(buffer: buffer), into: &partial) {
                return reply
            }
        }
        throw Self.explain(end.value, bound: replyBound)
    }

    /// The error for a stream that ended: what ended it.
    fileprivate static func explain(
        _ cause: LoopbackClientEnd.Cause, bound: TimeAmount
    ) -> LoopbackFTPClientError {
        switch cause {
        case .none: return .connectionClosed
        case .failed(let text): return .connectionFailed(text)
        case .timedOut: return .noReplyWithin(milliseconds: bound.nanoseconds / 1_000_000)
        }
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
        let end = self.end
        let handshake = self.handshake
        let timer = channel.eventLoop.scheduleTask(in: replyBound) {
            end.noteTimeout()
            handshake.settle(false)
        }
        defer { timer.cancel() }
        guard await handshake.wait() else {
            if end.value == .timedOut {
                throw Self.explain(.timedOut, bound: replyBound)
            }
            throw LoopbackFTPClientError.handshakeFailed
        }
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
        // A data connection's handshake is observed from the server's side;
        // the sink still wants an object to report to.
        let handshake = LoopbackClientHandshake()
        let end = LoopbackClientEnd()
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
                            LoopbackClientSink(deliver: continuation, handshake: handshake, end: end))
                    }
                }
                .connect(host: host, port: port))
        return LoopbackFTPClientData(
            channel: channel, chunks: chunks, deliver: continuation, end: end, bound: replyBound)
    }
}

/// The client end of one data connection.
struct LoopbackFTPClientData: Sendable {
    fileprivate let channel: Channel
    fileprivate let chunks: AsyncStream<ByteBuffer>
    fileprivate let deliver: AsyncStream<ByteBuffer>.Continuation
    fileprivate let end: LoopbackClientEnd
    fileprivate let bound: TimeAmount

    /// Reads until the server closes the connection. Throws if the connection
    /// failed rather than closed, or if the client's hang bound passed first.
    func readToEnd() async throws -> Data {
        let end = self.end
        let deliver = self.deliver
        let timer = channel.eventLoop.scheduleTask(in: bound) {
            end.noteTimeout()
            deliver.finish()
        }
        defer { timer.cancel() }

        var data = Data()
        for await chunk in chunks { data.append(contentsOf: chunk.readableBytesView) }
        if end.value != .none { throw LoopbackFTPClient.explain(end.value, bound: bound) }
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
    private let end: LoopbackClientEnd

    init(
        deliver: AsyncStream<ByteBuffer>.Continuation, handshake: LoopbackClientHandshake,
        end: LoopbackClientEnd
    ) {
        self.deliver = deliver
        self.handshake = handshake
        self.end = end
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
        // Recorded where the awaiting side can read it: swallowed, this is the
        // same unattributable hang as a missing hang bound, by another route.
        end.noteError(error)
        handshake.settle(false)
        deliver.finish()
        context.close(promise: nil)
    }
}
