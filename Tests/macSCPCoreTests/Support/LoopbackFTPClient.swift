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
///
/// **Why `@unchecked Sendable` is sound here.** The iterator is the only
/// mutable state and every access to it is bracketed by `reader`, which traps
/// on overlap. An actor does NOT give that guarantee for free: it is
/// re-entrant at every `await`, so two concurrent `readReply()` calls on one
/// client would both reach this iterator. With the guard that is a named trap;
/// without it, a data race.
final class LoopbackLineSource: @unchecked Sendable {
    private var iterator: AsyncStream<ByteBuffer>.Iterator
    private let reader = LoopbackSingleReaderGuard()

    init(_ stream: AsyncStream<ByteBuffer>) {
        iterator = stream.makeAsyncIterator()
    }

    /// A read is in flight. For the tests that drive an overlap on purpose.
    var isReading: Bool { reader.isBusy }

    func next() async -> ByteBuffer? {
        reader.enter("control line source")
        defer { reader.leave() }
        return await iterator.next()
    }
}

/// The reading end of a data connection, with the same single iterator and the
/// same soundness argument as `LoopbackLineSource`. `readToEnd()` used to
/// iterate the stream directly, which makes a new iterator per call: a second
/// call, or two overlapping ones, is the latent trap that round 1 closed on
/// the server side only.
final class LoopbackChunkSource: @unchecked Sendable {
    private var iterator: AsyncStream<ByteBuffer>.Iterator
    private let reader = LoopbackSingleReaderGuard()

    init(_ stream: AsyncStream<ByteBuffer>) {
        iterator = stream.makeAsyncIterator()
    }

    /// A read is in flight. For the tests that drive an overlap on purpose.
    var isReading: Bool { reader.isBusy }

    /// Everything until the stream ends.
    func drain() async -> Data {
        reader.enter("data chunk source")
        defer { reader.leave() }
        var data = Data()
        while let chunk = await iterator.next() { data.append(contentsOf: chunk.readableBytesView) }
        return data
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
    private let bytes = NIOLockedValueBox(0)

    var value: Cause { cause.withLockedValue { $0 } }

    /// How many bytes the sink has delivered so far.
    var bytesDelivered: Int { bytes.withLockedValue { $0 } }

    func noteBytes(_ count: Int) {
        bytes.withLockedValue { $0 += count }
    }

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
    /// update). The default sits under a five-minute `.timeLimit` so the named
    /// error arrives first, and above the 131 s a whole saturated suite took on
    /// the three-core runner, so it measures a hang and not load.
    ///
    /// **A constraint on where this client may be used: a suite that uses it
    /// must be bounded ABOVE 180 s.** In a suite bounded below that, the
    /// `.timeLimit` fires first, the step may be killed and the test's name is
    /// lost -- the failure this bound exists to prevent.
    ///
    /// How many suites that is, measured 2026-11-05 on this tree. Withdrawn
    /// wording, verbatim: "so 29 suites sit below this bound". The 29 was a count
    /// of matching LINES (`/usr/bin/grep -rn -e 'timeLimit(\.minutes(2))' -e 'timeLimit(\.minutes(1))' Tests | wc -l`
    /// prints 29), not of suites: 18 of those lines carry an `@Suite`, 3 an
    /// `@Test`, 2 are continuation lines of a multi-line `@Suite(` and 6 are
    /// comments, which is 29. Suites, by two commands that do not overlap:
    /// `/usr/bin/grep -rn -e '@Suite(.*timeLimit(\.minutes([12]))' Tests | wc -l`
    /// prints 18, and
    /// `/usr/bin/grep -rn -B4 -e '^ *\.timeLimit(\.minutes([12]))' Tests | /usr/bin/grep -o '@Suite(' | wc -l`
    /// prints 2 (both gated behind `MACSCP_ITEST=1`), so **20 suites** sit below
    /// this bound, against 108 at five minutes
    /// (`/usr/bin/grep -rn -e '@Suite(.*timeLimit(\.minutes(5))' Tests | wc -l`).
    /// CLAUDE.md records the two-minute bounds as deliberately left alone, so
    /// this is a constraint on where the client may be used, not an argument for
    /// touching them.
    ///
    /// **2026-11-09: they were touched, and both counts above have expired.**
    /// The 19 ungated two-minute bounds were raised to five once the whole
    /// suite's own wall clock passed 120 s (CLAUDE.md, "A wall-clock ceiling in
    /// a test measures the runner", the 2026-11-09 update). Re-run the same
    /// day: the first command above prints 0, the second still prints 2 (both
    /// gated, left at two minutes), and the five-minute one prints 133. So the
    /// suites below this bound are those two gated ones only. The bound's
    /// other premise expired with it: the whole saturated suite took
    /// 212.296 s on CI run 42606504360, not the 131 s written above, so 180 s
    /// no longer sits above it. It was NOT raised here, because the window it
    /// is designed for -- above the suite's wall clock, below its five-minute
    /// `.timeLimit` -- is now 212.296 s to 300 s, and the right figure inside
    /// it is a decision this change does not make.
    ///
    /// The client is called today only from `LoopbackFTPServerTests`, which is
    /// bounded at five minutes: `/usr/bin/grep -rl 'LoopbackFTPClient\.connect(' Tests`
    /// prints that one file (the client's own file is not listed, because it
    /// defines `connect` and never spells the call). So the bound is attributable
    /// today, and this is the rule for the suites added later.
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

    /// The local port of this connection, which is the REMOTE port its peer sees:
    /// how a test names "my connection" among whatever else reaches a server.
    nonisolated var localPort: Int? { channel.localAddress?.port }

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
        try Self.throwIfCancelledWithoutACause(end)
        throw Self.explain(end.value, bound: replyBound)
    }

    /// **Three ways a wait ends without a reply, and they must stay three:** the
    /// peer closed (`connectionClosed`, or `connectionFailed` with the
    /// transport's words), the hang bound fired (`noReplyWithin`), or the
    /// awaiting task was cancelled (`CancellationError`, here).
    ///
    /// An `AsyncStream` iterator returns nil when its task is cancelled, which
    /// is indistinguishable from the stream having finished, so a cancelled read
    /// used to come out as `connectionClosed` with the peer still connected --
    /// measured on a bare stream in the re-review of fix round 2. Reporting a
    /// cancellation as a peer close makes every later hang in this client
    /// unattributable, which is what the bound exists to prevent. A recorded
    /// cause (an error, or the bound) outranks cancellation: it is the real end.
    /// That is two claims and each has its own test:
    /// `aFiredBoundOutranksCancellationWhenBothEndTheSameRead` holds the bound's
    /// half and `aRecordedErrorOutranksCancellationWhenBothEndTheSameRead` holds
    /// the error's. Withdrawn wording, verbatim:
    /// "`aFiredBoundOutranksCancellationWhenBothEndTheSameRead` holds that
    /// precedence" -- it holds half of it, measured in the re-review of fix
    /// round 4 by narrowing the condition below to `end.value != .timedOut`, so
    /// that a recorded ERROR no longer outranked cancellation: the suite stayed
    /// GREEN, 39 of 39 tests ran and none noticed. The error half has had a test
    /// since fix round 5.
    /// `aCancelledReadIsNotReportedAsAClosedConnection`,
    /// `aCancelledHandshakeWaitIsNotReportedAsAFailedHandshake` and
    /// `aCancelledDataReadThrowsInsteadOfReturningAPrefix` hold the three
    /// callers. Withdrawn wording, verbatim: "hold the two callers" -- there are
    /// three, counted with
    /// `/usr/bin/grep -rn 'throwIfCancelledWithoutACause' Tests Sources`, which
    /// prints EIGHT lines: this declaration, the three calls in this file
    /// (`readReply`, `waitForHandshake`, `readToEnd`), two direct calls from the
    /// two precedence tests, and two comments -- of which one is the command
    /// line just above, so running this command includes the sentence that
    /// describes it. It printed seven before that line existed, and the figure
    /// was corrected here after re-running: CLAUDE.md's "run it again after
    /// writing the sentence", arriving inside the correction of a comment that
    /// had miscounted the same symbol's callers.
    ///
    /// **A limit, not a guarantee: the three are distinct only while exactly
    /// one of them is true.** A clean close records NOTHING here --
    /// `LoopbackClientSink.channelInactive` finishes the stream and writes to
    /// `end` only through `noteError`, which a clean close never reaches -- so
    /// `end.value` is `.none` both for "the peer closed" and for "nothing has
    /// happened". A read whose peer has closed AND whose task is cancelled
    /// therefore answers `CancellationError`, and the close is not reported at
    /// all. That is deliberate (a cancelled read's caller is going away
    /// whatever the peer did) and it is the one combination no test pins,
    /// because there is nothing to tell the two apart by. The other direction, a
    /// recorded cause against a cancellation, is pinned in both halves: the
    /// cause wins. Withdrawn wording, verbatim: "The other direction, the bound
    /// against a cancellation, is pinned: the bound wins." -- true when it was
    /// written and the bound was the only half with a test.
    static func throwIfCancelledWithoutACause(_ end: LoopbackClientEnd) throws {
        if end.value == .none, Task.isCancelled { throw CancellationError() }
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

    /// Waits for the TLS handshake this connection is in the middle of.
    ///
    /// **Not `private`, so its own cancellation pin can call it.** Driven
    /// through `startTLS()` instead, the pin would have to cancel a task that
    /// is also inside `startTLS`'s `awaitCancellably(...)` of the pipeline
    /// edit, and that throws a `CancellationError` of its own: a client that
    /// had lost the check below entirely would still answer
    /// `CancellationError` often enough for the test to pass. The pin is
    /// `aCancelledHandshakeWaitIsNotReportedAsAFailedHandshake`; nothing else
    /// outside this type calls this.
    func waitForHandshake() async throws {
        let end = self.end
        let handshake = self.handshake
        let timer = channel.eventLoop.scheduleTask(in: replyBound) {
            end.noteTimeout()
            handshake.settle(false)
        }
        defer { timer.cancel() }
        guard await handshake.wait() else {
            try Self.throwIfCancelledWithoutACause(end)
            // The recorded cause first, as the other two waits do: a handshake
            // that failed with an error says which, and only a bare close
            // (nothing recorded) is the generic `handshakeFailed`.
            switch end.value {
            case .none: throw LoopbackFTPClientError.handshakeFailed
            case .failed, .timedOut: throw Self.explain(end.value, bound: replyBound)
            }
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
            channel: channel, chunks: LoopbackChunkSource(chunks), deliver: continuation, end: end,
            bound: replyBound)
    }
}

/// The error `injectTransportError()` raises.
struct LoopbackInjectedTransportError: Error {}

/// The client end of one data connection.
struct LoopbackFTPClientData: Sendable {
    fileprivate let channel: Channel
    fileprivate let chunks: LoopbackChunkSource
    fileprivate let deliver: AsyncStream<ByteBuffer>.Continuation
    fileprivate let end: LoopbackClientEnd
    fileprivate let bound: TimeAmount

    /// The local port of this connection (see `LoopbackFTPClient.localPort`).
    var localPort: Int? { channel.localAddress?.port }

    /// The transport error that ended the connection, if one did (read it after
    /// `readToEnd()`); nil for a clean close.
    var transportFailure: String? {
        if case .failed(let text) = end.value { return text }
        return nil
    }

    /// Reads until the server closes the connection, and returns what arrived.
    ///
    /// **The bytes win over a transport error.** A transfer that completed and
    /// was then reset, and one that was cut short, look the same from here (both
    /// end the stream), so throwing would discard a complete payload to report
    /// something that cannot be told apart from a truncation -- and a later
    /// assertion on the payload would fail with nothing to say why. The error
    /// is recorded instead (`transportFailure`). Only the hang bound throws:
    /// then no end was observed at all, and there is nothing to return.
    func readToEnd() async throws -> Data {
        let end = self.end
        let deliver = self.deliver
        let timer = channel.eventLoop.scheduleTask(in: bound) {
            end.noteTimeout()
            deliver.finish()
        }
        defer { timer.cancel() }

        let data = await chunks.drain()
        // A cancelled drain returns early with a PREFIX of the payload: that must
        // not come back as if it were the whole of it.
        try LoopbackFTPClient.throwIfCancelledWithoutACause(end)
        if end.value == .timedOut { throw LoopbackFTPClient.explain(.timedOut, bound: bound) }
        return data
    }

    /// Bytes the sink has delivered so far; a test waits on this instead of on
    /// time (see `injectTransportError()`).
    var bytesReceived: Int { end.bytesDelivered }

    /// A transport error on this connection, as if the socket had failed, for
    /// the test of what `readToEnd()` does when one follows delivered bytes.
    /// Fired on the connection's own event loop so it reaches the sink the way a
    /// real one would.
    func injectTransportError() {
        let channel = self.channel
        channel.eventLoop.execute {
            channel.pipeline.fireErrorCaught(LoopbackInjectedTransportError())
        }
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
        let buffer = unwrapInboundIn(data)
        end.noteBytes(buffer.readableBytes)
        deliver.yield(buffer)
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
