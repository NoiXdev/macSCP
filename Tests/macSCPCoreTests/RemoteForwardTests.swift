import Foundation
import MacSCPTestSupport
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

@testable import macSCPCore

/// The remote forward (`-R`) end to end on loopback, with a FAKE transport in
/// place of the SSH connection — the same shape `LocalForwardListenerTests`
/// and `SOCKS5ListenerTests` use for the other two directions.
///
/// What the fake stands in for is `CitadelFileSystem.withRemotePortForward`:
/// it names a bound port through `onOpen`, keeps the `handleChannel` closure,
/// sleeps until it is cancelled (exactly as Citadel's own wrapper does), and
/// lets a test hand in an inbound connection whenever it likes.
///
/// The inbound channels are REAL loopback sockets rather than
/// `EmbeddedChannel`s, and that is deliberate: the forward connects its local
/// side with a `ClientBootstrap` **on the inbound channel's own event loop**,
/// which an `EmbeddedEventLoop` cannot serve. Each inbound channel is
/// connected with `autoRead` off, because that is how an SSH child channel
/// reaches `handleChannel` — nothing may be read from it before the pump is
/// in place.
///
/// Every port on THIS machine is 0 — bound by the kernel — and every wait is
/// an `await`; nothing here holds a fixed local port or a wall-clock bound of
/// its own. The remote port is named, and the fake answers with a DIFFERENT
/// number, so `start` is measured to return what `onOpen` said rather than
/// what it was asked for.
@Suite("RemoteForward", .timeLimit(.minutes(1)))
struct RemoteForwardTests {

    /// The whole path: the server names a port, an inbound connection is
    /// handed in, and bytes travel in both directions between the machine
    /// that opened it and the local target.
    @Test func bytesTravelBothWaysBetweenAnInboundChannelAndTheLocalTarget() async throws {
        let target = try await RecordingServer.start()
        let origin = try await RecordingServer.start()
        let fake = FakeRemoteForwardTransport(boundPort: 45_000)
        let forward = RemoteForward(transport: fake)
        let seen = EventRecorder()
        do {
            let port = try await forward.start(
                bind: "127.0.0.1", remotePort: 8080,
                localHost: "127.0.0.1", localPort: target.port,
                observer: { seen.record($0) })
            #expect(port == 45_000)
            #expect(forward.boundPort == 45_000)

            let inbound = try await origin.connectWithAutoReadOff()
            try await fake.deliver(inbound)
            try await pollUntil("the origin's own end of the inbound connection") {
                origin.accepted.count == 1
            }
            let fromTheServer = try #require(origin.accepted.first)

            try await awaitCancellably(fromTheServer.writeAndFlush(ByteBuffer(string: "ping")))
            try await pollUntil("the bytes to reach the local target") {
                target.text == "ping"
            }
            try await pollUntil("the local target's own end") { target.accepted.count == 1 }
            let atTheTarget = try #require(target.accepted.first)
            try await awaitCancellably(atTheTarget.writeAndFlush(ByteBuffer(string: "pong")))
            try await pollUntil("the answer to reach the far side") { origin.text == "pong" }

            #expect(seen.events.contains(.opened))

            // Read BEFORE the teardown heals anything: `stop()` closes the
            // pair, and a `closed` report read afterwards would be one
            // `stop()` produced rather than one the pump did.
            let closedBeforeStop = seen.events.contains { event in
                if case .closed = event { return true }
                return false
            }
            #expect(closedBeforeStop == false)

            await forward.stop()
            try await awaitCancellably(inbound.closeFuture)
            #expect(inbound.isActive == false)
            let closedAfterStop = seen.events.contains { event in
                if case .closed(let bytesIn, let bytesOut, _) = event {
                    return bytesIn == 4 && bytesOut == 4
                }
                return false
            }
            #expect(closedAfterStop)
        } catch {
            await forward.stop()
            await target.stop()
            await origin.stop()
            throw error
        }
        await target.stop()
        await origin.stop()
    }

    /// A local target that refuses the connection is ONE connection's
    /// failure, not the tunnel's: the inbound channel is closed, exactly one
    /// `connectFailed` is reported, and the forward is still bound
    /// afterwards.
    @Test func aRefusedLocalConnectClosesTheInboundSideAndCountsOneFailure() async throws {
        let closedPort = try await portNothingIsListeningOn()
        let origin = try await RecordingServer.start()
        let fake = FakeRemoteForwardTransport(boundPort: 45_001)
        let forward = RemoteForward(transport: fake)
        let failures = FailureRecorder()
        let seen = EventRecorder()
        do {
            let port = try await forward.start(
                bind: "127.0.0.1", remotePort: 8080,
                localHost: "127.0.0.1", localPort: closedPort,
                observer: { seen.record($0) },
                onConnectionFailure: { failures.record($0) })
            #expect(port == 45_001)

            let inbound = try await origin.connectWithAutoReadOff()
            // `deliver` rethrows whatever `handleChannel` threw, which is how
            // the SSH transport learns to answer the server with a channel
            // open failure rather than a confirmation.
            await #expect(throws: TunnelFailure.self) { try await fake.deliver(inbound) }
            try await awaitCancellably(inbound.closeFuture)
            #expect(inbound.isActive == false)

            #expect(failures.failures.count == 1)
            let isConnectFailure: Bool = {
                guard case .connectFailed = failures.failures.first else { return false }
                return true
            }()
            #expect(isConnectFailure)
            // No pair was ever glued, so nothing is counted for it.
            #expect(seen.events.isEmpty)
            // The tunnel itself is untouched: still bound, still running.
            #expect(forward.boundPort == 45_001)
            #expect(fake.sawCancellation == false)
        } catch {
            await forward.stop()
            await origin.stop()
            throw error
        }
        await forward.stop()
        await origin.stop()
    }

    /// `stop()` before any connection arrives: the long-lived task is
    /// cancelled, which is what makes Citadel send `cancel-tcpip-forward`,
    /// and `stop()` only returns once that task is over.
    @Test func stopBeforeAnyInboundCancelsTheForward() async throws {
        let fake = FakeRemoteForwardTransport(boundPort: 45_002)
        let forward = RemoteForward(transport: fake)
        let port = try await forward.start(
            bind: "127.0.0.1", remotePort: 8080, localHost: "127.0.0.1", localPort: 1)
        #expect(port == 45_002)
        #expect(fake.sawCancellation == false)

        await forward.stop()

        #expect(fake.sawCancellation)
        #expect(forward.boundPort == nil)
    }

    /// A transport that does NOT end when it is cancelled must not hold
    /// `stop()` — Citadel's cancellation is a round trip to a server that
    /// may already be gone, and Task 5 calls this from the quit sequence.
    ///
    /// The forward is built to abandon after one second rather than the
    /// production five, so the bound is measured without spending it. There
    /// is no ceiling on how long `stop()` took: what is asserted is that it
    /// RETURNED while the transport was demonstrably still running, which a
    /// slow machine cannot fake.
    ///
    /// The transport is read BEFORE it is released, for the reason
    /// CLAUDE.md's "Tests that watch a defect heal" gives: reading after the
    /// release would find exactly the state the test wants, defect or not.
    @Test func stopIsNotHeldByATransportThatIgnoresItsCancellation() async throws {
        let fake = StubbornTransport(boundPort: 45_006)
        let forward = RemoteForward(transport: fake, cancellationBoundSeconds: 1)
        _ = try await forward.start(
            bind: "127.0.0.1", remotePort: 8080, localHost: "127.0.0.1", localPort: 1)

        await forward.stop()

        #expect(fake.isRunning)
        fake.release()
        try await pollUntil("the abandoned transport to end") { !fake.isRunning }
    }

    /// A server that never answers `tcpip-forward` must not park `start`
    /// forever. The bound is the code under test, not a ceiling on the test:
    /// it is injected small, and what is asserted is the FAILURE the bound
    /// produces and the state it leaves behind — a slow machine can make
    /// this take longer, and cannot make it pass.
    ///
    /// The forward is read as stopped afterwards, which is the second half
    /// of the contract: a `tcpip-forward` the server has not answered may
    /// still be answered, and a forward nobody holds would then be a
    /// listener on the server with no reader on this side.
    @Test func aServerThatNeverAnswersEndsTheStartAndStopsTheForward() async throws {
        let fake = SilentTransport()
        let forward = RemoteForward(transport: fake, cancellationBoundSeconds: 1)

        let raised: (any Error)?
        do {
            _ = try await forward.start(
                bind: "127.0.0.1", remotePort: 8080, localHost: "127.0.0.1", localPort: 1,
                answerBound: .milliseconds(50))
            raised = nil
        } catch {
            raised = error
        }

        let isBindFailure: Bool = {
            guard case .bindFailed = raised as? TunnelFailure else { return false }
            return true
        }()
        #expect(isBindFailure)
        #expect(forward.boundPort == nil)
        #expect(fake.sawCancellation)
    }

    /// A cancelled `start` throws `CancellationError` instead of parking on
    /// the box's continuation.
    ///
    /// The bound is deliberately far away (a minute) so that nothing but the
    /// cancellation can end this wait — with a small bound the test would
    /// pass on the bound's failure and prove nothing about cancellation.
    /// That is a FLOOR, not a ceiling: a slow machine cannot reach it.
    @Test func aCancelledStartThrowsCancellationRatherThanParking() async throws {
        let fake = SilentTransport()
        let forward = RemoteForward(transport: fake, cancellationBoundSeconds: 1)

        let started = Task { () -> (any Error)? in
            do {
                _ = try await forward.start(
                    bind: "127.0.0.1", remotePort: 8080, localHost: "127.0.0.1", localPort: 1,
                    answerBound: .seconds(60))
                return nil
            } catch {
                return error
            }
        }
        // Cancel only once the transport is demonstrably inside the request,
        // so this measures a cancellation of the WAIT and not of a task that
        // had not begun it.
        try await pollUntil("the transport to be asked for the forward") { fake.isRunning }
        started.cancel()

        let raised = await started.value
        #expect(raised is CancellationError)
        #expect(forward.boundPort == nil)
    }

    /// A server that refuses the global request fails the START, and the
    /// failure it raised itself reaches the caller unchanged — the reason
    /// naming `GatewayPorts` is the only thing that says why a `0.0.0.0`
    /// bind was turned down, and re-mapping it would replace that sentence
    /// with a case index.
    @Test func aRefusedForwardFailsTheStartWithItsOwnReason() async throws {
        let refusal = TunnelFailure.bindFailed(reason: "the server refuses to listen")
        let fake = FakeRemoteForwardTransport(boundPort: 45_003, refusal: refusal)
        let forward = RemoteForward(transport: fake)
        await #expect(throws: refusal) {
            try await forward.start(
                bind: "0.0.0.0", remotePort: 8080, localHost: "127.0.0.1", localPort: 1)
        }
        #expect(forward.boundPort == nil)
    }

    /// A foreign error from the transport is MAPPED rather than passed
    /// through, so the caller always gets a `TunnelFailure` from `start`.
    @Test func aForeignRefusalIsMappedToABindFailure() async throws {
        struct Refused: Error {}
        let fake = FakeRemoteForwardTransport(boundPort: 45_004, refusal: Refused())
        let forward = RemoteForward(transport: fake)
        let raised: (any Error)?
        do {
            _ = try await forward.start(
                bind: "127.0.0.1", remotePort: 8080, localHost: "127.0.0.1", localPort: 1)
            raised = nil
        } catch {
            raised = error
        }
        let isBindFailure: Bool = {
            guard case .bindFailed = raised as? TunnelFailure else { return false }
            return true
        }()
        #expect(isBindFailure)
    }

    /// One forward starts once, exactly like `LocalForwardListener`. A
    /// reconnect builds a fresh SSH connection, so it builds a fresh forward
    /// with it.
    @Test func aForwardCannotBeStartedTwice() async throws {
        let fake = FakeRemoteForwardTransport(boundPort: 45_005)
        let forward = RemoteForward(transport: fake)
        _ = try await forward.start(
            bind: "127.0.0.1", remotePort: 8080, localHost: "127.0.0.1", localPort: 1)
        await #expect(throws: TunnelFailure.alreadyStarted) {
            try await forward.start(
                bind: "127.0.0.1", remotePort: 8080, localHost: "127.0.0.1", localPort: 1)
        }
        await forward.stop()
        await #expect(throws: TunnelFailure.alreadyStarted) {
            try await forward.start(
                bind: "127.0.0.1", remotePort: 8080, localHost: "127.0.0.1", localPort: 1)
        }
    }
}

// MARK: - The transport seam

/// Stands in for `CitadelFileSystem.withRemotePortForward`, in the same three
/// moments Citadel's own wrapper has: it names the bound port, it keeps the
/// per-connection closure, and it sleeps until the task is cancelled.
private final class FakeRemoteForwardTransport: RemoteForwardTransport, Sendable {
    /// `NIOLockedValueBox` rather than an `NSLock` the methods take by hand:
    /// both of the methods below are `async`, where `NSLock.lock()` is
    /// unavailable.
    private struct State {
        var handler: (@Sendable (Channel) async throws -> Void)?
        var cancelled = false
    }

    private let state = NIOLockedValueBox(State())
    private let boundPort: Int
    private let refusal: (any Error)?

    init(boundPort: Int, refusal: (any Error)? = nil) {
        self.boundPort = boundPort
        self.refusal = refusal
    }

    /// Whether the forward was ended by a cancellation — the observable half
    /// of "Citadel sent `cancel-tcpip-forward`".
    var sawCancellation: Bool { state.withLockedValue { $0.cancelled } }

    func withRemotePortForward(
        bind: String, port: Int,
        onOpen: @escaping @Sendable (Int) -> Void,
        handleChannel: @escaping @Sendable (Channel) async throws -> Void
    ) async throws {
        if let refusal { throw refusal }
        state.withLockedValue { $0.handler = handleChannel }
        onOpen(boundPort)
        do {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(3600))
            }
        } catch {
            // Citadel's own wrapper sends `cancel-tcpip-forward` here and
            // rethrows; this records the same moment.
            state.withLockedValue { $0.cancelled = true }
            throw error
        }
        state.withLockedValue { $0.cancelled = true }
    }

    /// Hands one inbound connection to whatever `RemoteForward` registered,
    /// and rethrows what that closure threw — the transport's own view of a
    /// connection it could not serve.
    func deliver(_ channel: Channel) async throws {
        let registered = state.withLockedValue { $0.handler }
        guard let registered else { throw NoHandlerRegistered() }
        try await registered(channel)
    }

    struct NoHandlerRegistered: Error {}
}

/// A transport that parks on a continuation instead of ending when it is
/// cancelled — which is what Citadel does while it waits for the server to
/// acknowledge `cancel-tcpip-forward`, and what a dead connection turns into
/// forever. A continuation is the honest shape for it: unlike a sleep loop it
/// does not spin, and unlike a cancellable wait it genuinely ignores
/// cancellation.
private final class StubbornTransport: RemoteForwardTransport, Sendable {
    private struct State {
        var parked: CheckedContinuation<Void, Never>?
        var released = false
        var running = false
    }

    private let state = NIOLockedValueBox(State())
    private let boundPort: Int

    init(boundPort: Int) { self.boundPort = boundPort }

    var isRunning: Bool { state.withLockedValue { $0.running } }

    func withRemotePortForward(
        bind: String, port: Int,
        onOpen: @escaping @Sendable (Int) -> Void,
        handleChannel: @escaping @Sendable (Channel) async throws -> Void
    ) async throws {
        state.withLockedValue { $0.running = true }
        onOpen(boundPort)
        // A bare continuation, deliberately, because
        // the continuation IS the API under test here.
        // What this models is a transport that does not end when its task is
        // cancelled, and a continuation is the only wait in Swift that
        // genuinely ignores cancellation — `awaitResumption` resumes with a
        // `CancellationError`, which is the opposite of the property being
        // measured. Bounded by construction: `release()` resumes it before
        // the test returns, and the test then waits for `isRunning` to go
        // false.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyReleased: Bool = state.withLockedValue { current in
                guard !current.released else { return true }
                current.parked = continuation
                return false
            }
            if alreadyReleased { continuation.resume() }
        }
        state.withLockedValue { $0.running = false }
    }

    /// Lets the parked call finish, so the test leaves no task behind.
    func release() {
        let parked: CheckedContinuation<Void, Never>? = state.withLockedValue { current in
            current.released = true
            let taken = current.parked
            current.parked = nil
            return taken
        }
        parked?.resume()
    }
}

/// A transport that accepts the request and then says nothing — never calls
/// `onOpen`, never returns — which is what a server that does not answer
/// `tcpip-forward` looks like from this side. It ends when its task is
/// cancelled, so both `start`'s bound and `stop()` can be measured against
/// it.
private final class SilentTransport: RemoteForwardTransport, Sendable {
    private struct State {
        var running = false
        var cancelled = false
    }

    private let state = NIOLockedValueBox(State())

    var isRunning: Bool { state.withLockedValue { $0.running } }
    var sawCancellation: Bool { state.withLockedValue { $0.cancelled } }

    func withRemotePortForward(
        bind: String, port: Int,
        onOpen: @escaping @Sendable (Int) -> Void,
        handleChannel: @escaping @Sendable (Channel) async throws -> Void
    ) async throws {
        state.withLockedValue { $0.running = true }
        do {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(3600))
            }
        } catch {
            state.withLockedValue {
                $0.cancelled = true
                $0.running = false
            }
            throw error
        }
        state.withLockedValue {
            $0.cancelled = true
            $0.running = false
        }
    }
}

// MARK: - Helpers

/// A loopback port with nothing behind it: bound to find a free number, then
/// closed again before it is used. A connection to it is refused.
private func portNothingIsListeningOn() async throws -> Int {
    let probe = try await awaitCancellably(
        ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0))
    let port = probe.localAddress?.port ?? 0
    probe.close(promise: nil)
    try await awaitCancellably(probe.closeFuture)
    return port
}

/// A loopback server that keeps every channel it accepts and everything read
/// on them. Used twice per test: once as the local target the forward dials,
/// and once as the far side an inbound connection comes from.
private final class RecordingServer: @unchecked Sendable {
    private let channel: Channel
    private let inbox: ByteInbox
    private let channels: ChannelBox

    var port: Int { channel.localAddress?.port ?? 0 }
    var text: String { String(decoding: inbox.bytes, as: UTF8.self) }
    var accepted: [Channel] { channels.channels }

    private init(channel: Channel, inbox: ByteInbox, channels: ChannelBox) {
        self.channel = channel
        self.inbox = inbox
        self.channels = channels
    }

    /// The two boxes are made before the bind, because the bootstrap's child
    /// initializer captures them.
    static func start() async throws -> RecordingServer {
        let inbox = ByteInbox()
        let channels = ChannelBox()
        let channel = try await awaitCancellably(
            ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { accepted in
                    channels.add(accepted)
                    return accepted.pipeline.addHandler(ByteCollector(inbox: inbox))
                }
                .bind(host: "127.0.0.1", port: 0))
        return RecordingServer(channel: channel, inbox: inbox, channels: channels)
    }

    /// One connection into this server, handed back with `autoRead` off —
    /// how an SSH child channel reaches `handleChannel`.
    func connectWithAutoReadOff() async throws -> Channel {
        try await awaitCancellably(
            ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelOption(ChannelOptions.autoRead, value: false)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .connect(host: "127.0.0.1", port: port))
    }

    func stop() async {
        for accepted in channels.channels {
            accepted.close(promise: nil)
        }
        channel.close(promise: nil)
        try? await awaitCancellably(channel.closeFuture)
    }
}

private final class ChannelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [Channel] = []

    var channels: [Channel] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func add(_ channel: Channel) {
        lock.lock()
        collected.append(channel)
        lock.unlock()
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

private final class EventRecorder: @unchecked Sendable {
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
