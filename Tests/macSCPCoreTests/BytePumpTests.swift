import Foundation
import MacSCPTestSupport
import NIOCore
import NIOEmbedded
import NIOPosix
import Testing

@testable import macSCPCore

/// The byte pump on its own, without a listener or an SSH connection above
/// it.
///
/// Two shapes are pinned here, and they are different measurements:
///
/// 1. **Same loop, `EmbeddedChannel` pairs.** Every inbound event is fired
///    by hand, so ordering is exact and nothing depends on scheduling.
///    These tests are SYNCHRONOUS on purpose: `EmbeddedEventLoop` may only
///    be used from the thread that created it, and an `await` in a Swift
///    Testing body can resume on a different one.
/// 2. **Two loops, `MultiThreadedEventLoopGroup(numberOfThreads: 2)`.** In
///    production the accepted socket lives on the listener's group and the
///    `direct-tcpip` child channel lives on the SSH client's, so the pump's
///    two sides are routinely on DIFFERENT event loops. The cross-loop case
///    gets its own test, and that test asserts the two channels really are
///    on different loops before it asserts anything else — without that a
///    same-loop run would pass while proving nothing.
@Suite("BytePump", .timeLimit(.minutes(1)))
struct BytePumpTests {

    // MARK: - Same loop: EmbeddedChannel pairs

    @Test func bytesReadOnOneSideAreWrittenToTheOtherInOrder() throws {
        let (local, remote) = try activeEmbeddedPair()
        try installPump(local: local, remote: remote)

        try local.writeInbound(buffer("one"))
        try local.writeInbound(buffer("two"))
        #expect(try drainText(remote) == "onetwo")

        try remote.writeInbound(buffer("back"))
        try remote.writeInbound(buffer("wards"))
        #expect(try drainText(local) == "backwards")

        finish(local, remote)
    }

    /// The pump writes on `channelRead` and flushes on `channelReadComplete`
    /// — one syscall's worth of writes per read burst rather than one per
    /// buffer. `EmbeddedChannel.readOutbound` only ever returns FLUSHED
    /// writes, so the `nil` below is the honest observation of "written but
    /// not yet flushed", and the text after it is the positive check beside
    /// that negative one.
    @Test func writesAreFlushedOncePerReadBurst() throws {
        let (local, remote) = try activeEmbeddedPair()
        try installPump(local: local, remote: remote)

        local.pipeline.fireChannelRead(buffer("half"))
        #expect(try remote.readOutbound(as: ByteBuffer.self) == nil)

        local.pipeline.fireChannelRead(buffer("way"))
        #expect(try remote.readOutbound(as: ByteBuffer.self) == nil)

        local.pipeline.fireChannelReadComplete()
        #expect(try drainText(remote) == "halfway")

        finish(local, remote)
    }

    /// Backpressure: when the channel the pump WRITES into stops being
    /// writable, the channel it READS from must stop reading. The option is
    /// read back off `EmbeddedChannel.options` rather than `getOption`,
    /// because `EmbeddedChannel.getOption(ChannelOptions.autoRead)` is
    /// hardcoded to `true` (`Embedded.swift`, `getOptionSync`) and would
    /// answer the same whether or not the pump had touched it.
    ///
    /// The RESUME is measured with a read recorder as well as with the
    /// option, and that is the half a socket-only test cannot see: a socket
    /// starts reading again when `autoRead` flips, an SSH child channel does
    /// not (`SSHChildChannel.setOption0` only assigns the flag), and
    /// `EmbeddedChannel` behaves like the SSH child channel. Zero reads
    /// while throttled is the negative; at least one after the resume is the
    /// positive beside it.
    @Test func anUnwritablePeerStopsTheOtherSideFromReading() throws {
        let (local, remote) = try activeEmbeddedPair()
        let localReads = ReadRecorder()
        try local.pipeline.syncOperations.addHandler(localReads)
        try installPump(local: local, remote: remote)

        // The pair is active, so installing already started reading — the
        // baseline the throttle is measured against, not zero.
        #expect(autoRead(of: local) == true)
        let readsBeforeThrottling = localReads.count
        #expect(readsBeforeThrottling >= 1)

        remote.isWritable = false
        remote.pipeline.fireChannelWritabilityChanged()
        #expect(autoRead(of: local) == false)
        #expect(
            localReads.count == readsBeforeThrottling,
            "a throttled peer must not be told to read")

        remote.isWritable = true
        remote.pipeline.fireChannelWritabilityChanged()
        #expect(autoRead(of: local) == true)
        #expect(localReads.count > readsBeforeThrottling, "a resumed peer must be read again")

        finish(local, remote)
    }

    /// Half-close: one side saying "I will send no more" must reach the
    /// other side as an output close, not as a full close — otherwise a
    /// client that shuts down its write side (`nc -N`, an HTTP request
    /// followed by a read) never gets the response.
    ///
    /// The mode is observed with an outbound recorder rather than by
    /// inspecting the channel afterwards: `EmbeddedChannel`'s core ignores
    /// `CloseMode` entirely (`Embedded.swift`, `close0`) and closes the
    /// whole channel whatever it is asked for, so reading `isActive` back
    /// could not tell an output close from a full one.
    ///
    /// The FIRST close is what is asserted, not the only one, and that is a
    /// consequence of the same limitation: because the embedded core turns
    /// the output close into a full one, the peer goes inactive, which walks
    /// back through the pair and closes this channel a second time with
    /// `.all`. On a real socket a half-close fires no `channelInactive` and
    /// there is no second close — measured against the rig in
    /// `TunnelRigITests`, where a whole SSH session runs through one pair.
    @Test func inputClosedOnOneSideClosesTheOthersOutput() throws {
        let (local, remote) = try activeEmbeddedPair()
        let closes = CloseModeRecorder()
        try remote.pipeline.syncOperations.addHandler(closes)
        try installPump(local: local, remote: remote)

        local.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        #expect(closes.modes.first == "output")

        finish(local, remote)
    }

    @Test func oneSideGoingInactiveClosesTheOther() throws {
        let (local, remote) = try activeEmbeddedPair()
        try installPump(local: local, remote: remote)
        #expect(remote.isActive)

        local.pipeline.fireChannelInactive()

        #expect(remote.isActive == false)

        finish(local, remote)
    }

    /// The observer seam Task 5 counts connections with: `opened` once when
    /// the pair is glued, `closed` once when BOTH channels are gone, with
    /// the byte counts of the two directions.
    @Test func theObserverReportsTheOpenAndTheByteCounts() throws {
        let (local, remote) = try activeEmbeddedPair()
        let seen = EventRecorder()
        try installPump(local: local, remote: remote, observer: { seen.record($0) })

        #expect(seen.events == [.opened])

        try local.writeInbound(buffer("abc"))
        try remote.writeInbound(buffer("wxyz"))
        _ = try drainText(remote)
        _ = try drainText(local)

        local.close(promise: nil)
        finish(local, remote)

        #expect(seen.events == [.opened, .closed(bytesIn: 4, bytesOut: 3)])
    }

    /// Added BEFORE activation: nothing at all until `channelActive`, then
    /// one read on each side.
    ///
    /// The `autoRead` assertion before activation is not decoration. Setting
    /// the option early is half of what hangs a real socket — `setOption0`
    /// only kicks a read when the channel is pre-registered, and a `read()`
    /// that lands before registration latches `readPending` so that the
    /// post-activation `readIfNeeded0` skips its own read. A handler that
    /// "only" set the option early would look harmless here and hang there.
    @Test func aHandlerAddedBeforeActivationWaitsForIt() throws {
        // NOT `activeEmbeddedPair()`: a bare `EmbeddedChannel` is registered
        // and not active, which is the state this test is about.
        let local = EmbeddedChannel()
        let remote = EmbeddedChannel()
        let localReads = ReadRecorder()
        let remoteReads = ReadRecorder()
        try local.pipeline.syncOperations.addHandler(localReads)
        try remote.pipeline.syncOperations.addHandler(remoteReads)
        try installPump(local: local, remote: remote)

        #expect(local.isActive == false)
        #expect(autoRead(of: local) == nil, "autoRead must not be set before activation")
        #expect(autoRead(of: remote) == nil)
        #expect(localReads.count == 0)
        #expect(remoteReads.count == 0)

        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        local.connect(to: address, promise: nil)
        remote.connect(to: address, promise: nil)

        #expect(autoRead(of: local) == true)
        #expect(autoRead(of: remote) == true)
        #expect(localReads.count == 1, "exactly one arm fires")
        #expect(remoteReads.count == 1)

        finish(local, remote)
    }

    /// Added AFTER activation: one read from `handlerAdded`, on both sides,
    /// and no second one — the other arm can no longer fire, because a
    /// channel that is already active will never see another `channelActive`.
    ///
    /// Both sides matter, and for different reasons. The local side is a
    /// socket in production and would half-work on the option alone; the
    /// remote side is an `SSHChildChannel`, whose `setOption0` assigns the
    /// flag and issues no read at all. `EmbeddedChannel` behaves like the
    /// latter, so this is the cheap place to pin the explicit `read()`.
    @Test func aHandlerAddedAfterActivationReadsAtOnce() throws {
        let (local, remote) = try activeEmbeddedPair()
        let localReads = ReadRecorder()
        let remoteReads = ReadRecorder()
        try local.pipeline.syncOperations.addHandler(localReads)
        try remote.pipeline.syncOperations.addHandler(remoteReads)
        try installPump(local: local, remote: remote)

        #expect(autoRead(of: local) == true)
        #expect(autoRead(of: remote) == true)
        #expect(localReads.count == 1, "exactly one arm fires")
        #expect(remoteReads.count == 1)

        finish(local, remote)
    }

    /// A gated remote side reads NOTHING — not even the option — until the
    /// gate opens, and then reads once.
    ///
    /// The local side beside it is the control: it is never gated, so it
    /// shows that installation did happen and that the gate holds one side
    /// rather than stalling the pair.
    @Test func aGatedRemoteSideWaitsForTheGate() throws {
        let (local, remote) = try activeEmbeddedPair()
        let localReads = ReadRecorder()
        let remoteReads = ReadRecorder()
        try local.pipeline.syncOperations.addHandler(localReads)
        try remote.pipeline.syncOperations.addHandler(remoteReads)
        let gate = BytePumpReadGate()
        try completing(
            BytePump.install(local: local, remote: remote, remoteReadGate: gate))

        #expect(autoRead(of: remote) == nil, "a gated side must not even set the option")
        #expect(remoteReads.count == 0)
        #expect(autoRead(of: local) == true, "the ungated side started as usual")
        #expect(localReads.count == 1)

        gate.open()
        // The release is queued onto the gated channel's OWN loop, which an
        // `EmbeddedEventLoop` only drains when told to.
        remote.embeddedEventLoop.run()

        #expect(autoRead(of: remote) == true)
        #expect(remoteReads.count == 1)
        #expect(localReads.count == 1, "opening the gate must not read the other side again")

        finish(local, remote)
    }

    /// Order-free: a gate opened before the handler ever asks releases the
    /// first read anyway. Without this the accept path would have a race of
    /// its own — `open()` runs on the accept task, the lifecycle callback on
    /// the channel's loop, and nothing orders the two.
    @Test func aGateOpenedFirstStillReleasesTheRead() throws {
        let (local, remote) = try activeEmbeddedPair()
        let remoteReads = ReadRecorder()
        try remote.pipeline.syncOperations.addHandler(remoteReads)
        let gate = BytePumpReadGate()
        gate.open()

        try completing(
            BytePump.install(local: local, remote: remote, remoteReadGate: gate))
        remote.embeddedEventLoop.run()

        #expect(autoRead(of: remote) == true)
        #expect(remoteReads.count == 1)

        finish(local, remote)
    }

    // MARK: - Two loops

    /// The production shape: the two pumped channels are on different event
    /// loops of the same group, exactly as an accepted socket and an SSH
    /// child channel are.
    ///
    /// The rig is one loopback server plus two clients pinned to explicit
    /// loops (`group.next()` twice, round-robin over two threads). The
    /// PUMPED pair is the two client channels; the server's two accepted
    /// channels are the test's own ends, one per direction, so writing into
    /// the first accepted channel must come back out of the second.
    @Test func aPairOnTwoEventLoopsPumpsBothWays() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        do {
            try await runTwoLoopPump(on: group)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        try await group.shutdownGracefully()
    }

    private func runTwoLoopPump(on group: MultiThreadedEventLoopGroup) async throws {
        let accepted = AcceptedChannels()
        let server = try await awaitCancellably(
            ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    let inbox = TextInbox()
                    accepted.add(channel, inbox: inbox)
                    return channel.pipeline.addHandler(TextCollector(inbox: inbox))
                }
                .bind(host: "127.0.0.1", port: 0))
        let serverPort = try #require(server.localAddress?.port)

        let firstLoop = group.next()
        let secondLoop = group.next()
        #expect(firstLoop !== secondLoop, "two loops are what this test is about")

        let first = try await connectClient(on: firstLoop, port: serverPort)
        try await pollUntil("the first connection is accepted") { accepted.count == 1 }
        let second = try await connectClient(on: secondLoop, port: serverPort)
        try await pollUntil("the second connection is accepted") { accepted.count == 2 }

        #expect(first.eventLoop !== second.eventLoop)

        // No `setOption` here on purpose: both channels were connected with
        // `autoRead` off, and the pump's own handlers are what turn it back
        // on. If they did not, the polls below would never come true.
        try await awaitCancellably(BytePump.install(local: first, remote: second))

        let intoFirst = try #require(accepted.channel(0))
        let outOfSecond = try #require(accepted.inbox(1))
        let intoSecond = try #require(accepted.channel(1))
        let outOfFirst = try #require(accepted.inbox(0))

        try await awaitCancellably(intoFirst.writeAndFlush(buffer("towards the remote")))
        try await pollUntil("the local side's bytes reach the remote side") {
            outOfSecond.text == "towards the remote"
        }

        try await awaitCancellably(intoSecond.writeAndFlush(buffer("and back again")))
        try await pollUntil("the remote side's bytes reach the local side") {
            outOfFirst.text == "and back again"
        }

        first.close(promise: nil)
        try await awaitCancellably(first.closeFuture)
        try await awaitCancellably(second.closeFuture)
        server.close(promise: nil)
        try await awaitCancellably(server.closeFuture)
    }

    private func connectClient(on loop: EventLoop, port: Int) async throws -> Channel {
        try await awaitCancellably(
            ClientBootstrap(group: loop)
                .channelOption(ChannelOptions.autoRead, value: false)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .connect(host: "127.0.0.1", port: port))
    }
}

// MARK: - Helpers

private func buffer(_ text: String) -> ByteBuffer {
    ByteBuffer(string: text)
}

private func drainText(_ channel: EmbeddedChannel) throws -> String {
    var text = ""
    while let chunk = try channel.readOutbound(as: ByteBuffer.self) {
        text += String(buffer: chunk)
    }
    return text
}

/// Two `EmbeddedChannel`s that are ACTIVE. A bare `EmbeddedChannel()` is
/// registered but never activated — `isActive` is false and firing
/// `channelInactive` at it would be a lie — so both are fake-connected to a
/// loopback address, which is what `EmbeddedChannelCore.connect0` treats as
/// the activation.
private func activeEmbeddedPair() throws -> (local: EmbeddedChannel, remote: EmbeddedChannel) {
    let local = EmbeddedChannel()
    let remote = EmbeddedChannel()
    let address = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
    local.connect(to: address, promise: nil)
    remote.connect(to: address, promise: nil)
    return (local, remote)
}

private func autoRead(of channel: EmbeddedChannel) -> Bool? {
    channel.options.first { $0.option is ChannelOptions.Types.AutoReadOption }?.value as? Bool
}

/// Installs the pump on a same-thread pair and asserts the installation
/// itself completed. `EmbeddedChannel.pipeline.addHandler` adds
/// synchronously when it is on its own loop — which `EmbeddedEventLoop`
/// always claims to be — so the future handed back is already resolved and
/// the callback below runs inline.
private func installPump(
    local: EmbeddedChannel, remote: EmbeddedChannel,
    observer: TunnelConnectionObserver? = nil
) throws {
    try completing(BytePump.install(local: local, remote: remote, observer: observer))
}

/// Asserts that a pump operation on an embedded pair finished, and rethrows
/// what it finished with. Not an `await`: see the suite's own comment on why
/// these tests stay synchronous.
private func completing(_ work: EventLoopFuture<Void>) throws {
    let outcome = InstallOutcome()
    work.whenComplete { outcome.record($0) }
    try outcome.unwrap()
}

/// Runs both embedded loops so the close promises the pump observes are
/// actually fulfilled, and drops the channels. Both may already be closed —
/// closing one closes the other, which is the point of several tests above.
private func finish(_ channels: EmbeddedChannel...) {
    for channel in channels {
        _ = try? channel.finish(acceptAlreadyClosed: true)
    }
}

private struct PumpInstallNeverCompleted: Error {}

private final class InstallOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Void, any Error>?

    func record(_ result: Result<Void, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        outcome = result
    }

    func unwrap() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let outcome else { throw PumpInstallNeverCompleted() }
        try outcome.get()
    }
}

/// Records the `CloseMode` of every outbound close that passes it.
/// `CloseMode` is `Sendable` but not `Equatable`, so the mode is recorded as
/// its name through an exhaustive `switch` — a case added to NIO's enum
/// stops compiling here rather than being silently misrecorded.
private final class CloseModeRecorder: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer

    private let lock = NSLock()
    private var recorded: [String] = []

    var modes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        let name: String
        switch mode {
        case .output: name = "output"
        case .input: name = "input"
        case .all: name = "all"
        }
        lock.lock()
        recorded.append(name)
        lock.unlock()
        context.close(mode: mode, promise: promise)
    }
}

/// Counts the outbound `read()` events that pass it.
private final class ReadRecorder: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer

    private let lock = NSLock()
    private var reads = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func read(context: ChannelHandlerContext) {
        lock.lock()
        reads += 1
        lock.unlock()
        context.read()
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

/// Accumulates everything read on one channel, as text.
final class TextInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var collected = ""

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func append(_ chunk: String) {
        lock.lock()
        collected += chunk
        lock.unlock()
    }
}

final class TextCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let inbox: TextInbox

    init(inbox: TextInbox) { self.inbox = inbox }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        inbox.append(String(buffer: unwrapInboundIn(data)))
    }
}

private final class AcceptedChannels: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [(channel: Channel, inbox: TextInbox)] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return channels.count
    }

    func add(_ channel: Channel, inbox: TextInbox) {
        lock.lock()
        channels.append((channel, inbox))
        lock.unlock()
    }

    func channel(_ index: Int) -> Channel? {
        lock.lock()
        defer { lock.unlock() }
        return channels.indices.contains(index) ? channels[index].channel : nil
    }

    func inbox(_ index: Int) -> TextInbox? {
        lock.lock()
        defer { lock.unlock() }
        return channels.indices.contains(index) ? channels[index].inbox : nil
    }
}
