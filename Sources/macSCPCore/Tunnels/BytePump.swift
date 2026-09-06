import Foundation
import NIOCore

/// What one tunnelled connection did, reported to whoever is counting.
///
/// `bytesOut` is what travelled from the local side toward the far side
/// (a client's request); `bytesIn` is what came back. The two names are
/// stated relative to THIS machine because that is the direction the app
/// shows: a local forward's "out" is the user's own upload.
public enum TunnelConnectionEvent: Sendable, Equatable {
    case opened
    /// `duration` is how long the PAIR was open — measured on a
    /// `ContinuousClock` from the moment `BytePumpCounters.opened(local:
    /// remote:)` armed the close report (both handlers installed) to the
    /// moment the second of the two channels closed. Monotonic, so a system
    /// clock change cannot make it negative, and it is the only way a
    /// caller can time one tunnelled connection: nothing else in this file
    /// correlates an `opened` with the `closed` that answers it.
    case closed(bytesIn: Int, bytesOut: Int, duration: Duration)
}

/// The seam a running tunnel counts its connections through. Deliberately a
/// closure rather than a protocol: the only implementation is a counter, and
/// the closure is `@Sendable` because it is called from whichever event loop
/// happens to close last.
public typealias TunnelConnectionObserver = @Sendable (TunnelConnectionEvent) -> Void

/// Glues two channels together so that everything read on one is written to
/// the other, in both directions, with read/write backpressure and
/// half-close propagated.
///
/// **The two channels are not assumed to share an event loop.** In
/// production they never do: the accepted socket belongs to the listener's
/// group, and the `direct-tcpip` child channel belongs to the SSH client's
/// (which, for an agent-authenticated connection, is a dedicated group of
/// its own — see `CitadelFileSystem`'s `dedicatedGroup`). Every cross-channel
/// call this file makes therefore goes through the `Channel` API —
/// `write(_:promise:)`, `flush()`, `close(mode:promise:)`,
/// `setOption(_:value:)` — and never through a `ChannelHandlerContext`,
/// because those four hop to the peer's own loop when called from another
/// one (`ChannelPipeline.write` and its neighbours test `inEventLoop` and
/// otherwise `eventLoop.execute`), while a context's equivalents must be
/// called on the loop they belong to. Ordering survives the hop: every write
/// for one direction is submitted from the SAME source loop, and
/// `EventLoop.execute` runs what one thread submits in the order it was
/// submitted.
public enum BytePump {
    /// Installs the pump on both channels and returns once both handlers are
    /// in place — on `local`'s event loop, whichever loop `remote` is on.
    ///
    /// Installing IS starting, for every side without a gate: each handler
    /// turns its own channel's `autoRead` on and asks for its first read
    /// from the channel's own lifecycle
    /// (`BytePumpHandler.handlerAdded`/`channelActive`), never from the
    /// task that called this. The long comment on those two methods is the
    /// reason, and it is a measured one. A gated remote side (below)
    /// registers its intent from the same two arms and only defers the
    /// moment of the first `read()` until the gate opens.
    ///
    /// For an ungated side there is no second, read-starting step after
    /// this one. Round 2 of
    /// this file moved the work into the handlers and left the old
    /// task-driven `BytePump.startReading` behind as an empty function,
    /// because comments in three other files described the accept path in
    /// terms of it. Task 4's round 1 reworded every one of them and deleted
    /// it: a function that does nothing, kept so that prose about it stays
    /// resolvable, is a worse anchor than prose that says what actually
    /// happens. (`BytePumpHandler.startReading` below is a different,
    /// private thing — the per-channel body both lifecycle arms call.)
    ///
    /// `remoteReadGate` holds the REMOTE side's first read until someone
    /// opens it. `nil` — the default, and what the `.fixed` path passes; a
    /// remote forward builds its handlers directly and takes the same
    /// default — means the remote side starts with the local one. A
    /// NEGOTIATED forward passes a gate and opens it after its reply is
    /// written; `BytePumpReadGate` says why.
    public static func install(
        local: Channel, remote: Channel, observer: TunnelConnectionObserver? = nil,
        remoteReadGate: BytePumpReadGate? = nil
    ) -> EventLoopFuture<Void> {
        let counters = BytePumpCounters(observer: observer)
        let localInstalled = local.pipeline.addHandler(
            BytePumpHandler(peer: remote, side: .local, counters: counters))
        let remoteInstalled = remote.pipeline.addHandler(
            BytePumpHandler(
                peer: local, side: .remote, counters: counters, readGate: remoteReadGate))
        // `and` hops the second future onto the first's loop, so the callback
        // below runs on `local.eventLoop` regardless of where `remote` lives.
        return localInstalled.and(remoteInstalled).map { _ in
            counters.opened(local: local, remote: remote)
        }
    }
}

/// Holds one side of a pump shut until the caller says the other side has
/// finished speaking for itself.
///
/// A negotiated forward needs this and a fixed one does not. `SOCKS5Handshake
/// .succeed` writes `05 00 …` on the LOCAL channel, and a SOCKS5 client
/// parses the first ten bytes after its CONNECT as that reply. The pump
/// starts reading when its handler is installed, and `install` runs BEFORE
/// `confirm` — so on a target that greets first (sshd's `SSH-2.0…`, SMTP,
/// IMAP, MySQL) the banner arrives on the child channel's first read and is
/// written to the client across an event-loop hop, racing the reply. Measured
/// 2026-09-06 against a loopback greeter: **1 of 10 runs** handed the client
/// `SSH-` where its reply frame belonged.
///
/// Why gate only the remote side, when round 2 argued that reads must start
/// from the channel's lifecycle: the registration race round 2 fixed is a
/// property of the ACCEPTED SOCKET, which NIO registers asynchronously after
/// the child-channel initializer runs. The remote side is an SSH child
/// channel that is already active when `install` adds its handler — the
/// handler still registers its intent from `handlerAdded`/`channelActive`,
/// so nothing is asked of an unregistered channel; only the moment of the
/// first `read()` is deferred, and it is deferred onto that channel's own
/// event loop.
///
/// One-shot and order-free: opening before anyone waits is remembered, so a
/// gate opened between `install` and the handler's lifecycle callback still
/// releases it.
public final class BytePumpReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [@Sendable () -> Void] = []

    public init() {}

    /// Lets the gated side read. Safe from any thread; each waiter is
    /// released exactly once.
    public func open() {
        let released: [@Sendable () -> Void] = {
            lock.lock()
            defer { lock.unlock() }
            guard !isOpen else { return [] }
            isOpen = true
            let taken = waiting
            waiting = []
            return taken
        }()
        for release in released { release() }
    }

    /// Runs `release` now if the gate is already open, otherwise when it is.
    func whenOpen(_ release: @escaping @Sendable () -> Void) {
        let now: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if isOpen { return true }
            waiting.append(release)
            return false
        }()
        if now { release() }
    }
}

/// Which end of a pair a handler sits on. Only the byte counters care: the
/// forwarding itself is symmetric.
enum BytePumpSide: Sendable {
    case local
    case remote
}

/// The counters and the one-shot `closed` report, shared by both handlers of
/// a pair.
///
/// `@unchecked Sendable` with an `NSLock`, not an actor: every mutation
/// happens inside a `channelRead` or a close callback on one of two event
/// loops, where an `await` is not available.
final class BytePumpCounters: @unchecked Sendable {
    private let lock = NSLock()
    private let observer: TunnelConnectionObserver?
    private var bytesIn = 0
    private var bytesOut = 0
    private var stillOpen = 2
    private var reportedClosed = false
    /// Set by `opened(local:remote:)`, read once by `oneSideClosed()`.
    /// `ContinuousClock` rather than `Date`: the number is a duration, and
    /// a wall clock that steps backwards would otherwise produce a negative
    /// one.
    private var openedAt: ContinuousClock.Instant?

    init(observer: TunnelConnectionObserver?) {
        self.observer = observer
    }

    /// Reports the open and arms the close report. Called once per pair,
    /// after both handlers are installed — so an observer never sees a
    /// `closed` it has no `opened` for.
    func opened(local: Channel, remote: Channel) {
        lock.lock()
        openedAt = ContinuousClock.now
        lock.unlock()
        observer?(.opened)
        local.closeFuture.whenComplete { [self] _ in oneSideClosed() }
        remote.closeFuture.whenComplete { [self] _ in oneSideClosed() }
    }

    func count(_ side: BytePumpSide, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        switch side {
        case .local: bytesOut += bytes
        case .remote: bytesIn += bytes
        }
    }

    private func oneSideClosed() {
        let report: TunnelConnectionEvent? = {
            lock.lock()
            defer { lock.unlock() }
            stillOpen -= 1
            guard stillOpen <= 0, !reportedClosed else { return nil }
            reportedClosed = true
            let duration = openedAt.map { ContinuousClock.now - $0 } ?? .zero
            return .closed(bytesIn: bytesIn, bytesOut: bytesOut, duration: duration)
        }()
        if let report { observer?(report) }
    }
}

/// One side of a pair. Inbound only: everything it produces is produced on
/// the PEER channel, so there is no outbound path through this handler to
/// intercept.
///
/// `@unchecked Sendable` because `ChannelPipeline.addHandler` requires it and
/// this type holds only immutable stored properties — a `Channel` (itself
/// `Sendable`), a case, and the lock-protected counters.
final class BytePumpHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let peer: Channel
    private let side: BytePumpSide
    private let counters: BytePumpCounters
    private let readGate: BytePumpReadGate?

    init(
        peer: Channel, side: BytePumpSide, counters: BytePumpCounters,
        readGate: BytePumpReadGate? = nil
    ) {
        self.peer = peer
        self.side = side
        self.counters = counters
        self.readGate = readGate
    }

    /// Reading starts HERE, from this channel's own lifecycle, and never
    /// from the task that installed the pump.
    ///
    /// Both listeners accept with `autoRead` off — nothing may be read
    /// before there is somewhere to put it — and `openDirectTCPIP` hands
    /// back its child channel the same way, so something has to turn it
    /// back on. Doing that from the accept task races NIO's registration of
    /// the accepted channel, and the race is not theoretical: Task 3
    /// measured this exact shape hanging 3 of 7 runs, on a different test
    /// each time, with every selector thread parked in `kevent` and no
    /// frame of ours in the sample — an accepted channel that was open,
    /// active, and registered for no read interest at all.
    ///
    /// The mechanism, in swift-nio 2.101.2's `BaseSocketChannel.swift`:
    /// `setOption0` only kicks a read when `lifecycleManager
    /// .isPreRegistered` (`:694-707`); `read0` latches `readPending = true`
    /// and registers interest only if pre-registered (`:833-844`);
    /// registration itself asks for `[.reset, .error]` and never consults
    /// `readPending` (`becomeFullyRegistered0`, `:1390-1398`); and the
    /// `readIfNeeded0` that follows activation (`:755-765`) skips its
    /// `pipeline.read()` precisely BECAUSE `readPending` is already true.
    /// An `await` in front of the option does not order any of it: the
    /// accepted channel's registration is enqueued by
    /// `ServerSocketChannel.channelRead0` through `eventLoop.execute`, on a
    /// loop that need not be the server's.
    ///
    /// Both entry points below run on the event loop and both imply
    /// registration, and EXACTLY ONE of them fires: a handler added before
    /// activation sees `isActive == false`, does nothing — it must not even
    /// set the option — and gets `channelActive` later; a handler added
    /// after activation sees `isActive == true` and will never get another
    /// `channelActive`.
    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { startReading(context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        startReading(context)
        context.fireChannelActive()
    }

    /// The option AND the read, in that order, on the loop.
    ///
    /// The `read()` is not redundant beside the option. A socket channel
    /// kicks its own read when `autoRead` flips, but an `SSHChildChannel`
    /// does not — `setOption0` there only assigns the flag, and its reads
    /// come from `unsatisfiedRead`, which nothing sets until `read()` is
    /// called. The remote side of every local and dynamic forward is such a
    /// channel, and without this it never delivers a byte.
    ///
    /// The failure arm is empty for the reason
    /// `channelWritabilityChanged`'s is: a channel that has already closed
    /// cannot take the option, and its own close ends the pair anyway.
    ///
    /// With a gate, the intent is still registered HERE — from a lifecycle
    /// callback, so the channel is registered and active — and only the
    /// option and the read itself wait. They then run on this channel's own
    /// event loop, never on the opener's, which is why the deferred form is
    /// spelled with the channel rather than with this context: a
    /// `ChannelHandlerContext` is valid only on the loop and only while the
    /// handler is in the pipeline, and neither holds once the work is
    /// queued.
    private func startReading(_ context: ChannelHandlerContext) {
        guard let readGate else {
            context.channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
            context.read()
            return
        }
        let channel = context.channel
        readGate.whenOpen {
            channel.eventLoop.execute {
                channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
                channel.read()
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        counters.count(side, bytes: buffer.readableBytes)
        peer.write(buffer, promise: nil)
    }

    /// One flush per read burst, not one per buffer: the reads of a single
    /// `poll` wake-up are coalesced into a single write to the peer.
    func channelReadComplete(context: ChannelHandlerContext) {
        peer.flush()
        context.fireChannelReadComplete()
    }

    /// Backpressure. When THIS channel — the one the peer's bytes are
    /// written into — stops being writable, the peer must stop reading, and
    /// start again when it drains.
    ///
    /// The `read()` on the RESUME is the same necessity `startReading`
    /// above documents, and for the same reason: turning `autoRead` back on is
    /// enough for a socket, which kicks the read itself on the transition,
    /// and does nothing at all for an SSH child channel, whose
    /// `setOption0` only assigns the flag. Without it a pair that has been
    /// throttled ONCE never reads from the server again — every bulk
    /// download to a client slower than the tunnel crosses the 64 KiB
    /// high-water mark, so this was not a corner case but the ordinary end
    /// of a large transfer.
    ///
    /// The failure arm is empty on purpose: a channel that has already
    /// closed cannot take the option, and its own close is about to tear the
    /// pair down anyway.
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        let writable = context.channel.isWritable
        let peer = self.peer
        peer.setOption(ChannelOptions.autoRead, value: writable).whenComplete { outcome in
            guard case .success = outcome, writable else { return }
            peer.read()
        }
        context.fireChannelWritabilityChanged()
    }

    /// Half-close. `ChannelEvent.inputClosed` means this side will send
    /// nothing more, which the peer must learn as an OUTPUT close so it can
    /// still answer — a client that shuts its write side down and waits for
    /// a reply is the ordinary shape of this, and a full close would drop
    /// that reply.
    ///
    /// Not every channel supports it (`CloseMode.output` is documented as
    /// optional). When the peer refuses, the pair is closed outright rather
    /// than left half-shut on one side only.
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let channelEvent = event as? ChannelEvent, channelEvent == .inputClosed {
            let peer = self.peer
            peer.flush()
            let closed = peer.eventLoop.makePromise(of: Void.self)
            peer.close(mode: .output, promise: closed)
            closed.futureResult.whenFailure { _ in peer.close(promise: nil) }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.flush()
        peer.close(promise: nil)
        context.fireChannelInactive()
    }

    /// A read or write error on either side ends that side; the
    /// `channelInactive` above then ends the other. The error is not
    /// reported outward from here — the pump has no observer for it, and a
    /// per-connection transport error is not a tunnel failure.
    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
