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
    case closed(bytesIn: Int, bytesOut: Int)
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
    /// Neither channel's `autoRead` is touched here. The caller decides when
    /// reading may start (`LocalForwardListener` accepts with `autoRead`
    /// off, so that nothing is read from the client before there is anywhere
    /// to put it), and from then on the pump owns the option as its
    /// backpressure control.
    public static func install(
        local: Channel, remote: Channel, observer: TunnelConnectionObserver? = nil
    ) -> EventLoopFuture<Void> {
        let counters = BytePumpCounters(observer: observer)
        let localInstalled = local.pipeline.addHandler(
            BytePumpHandler(peer: remote, side: .local, counters: counters))
        let remoteInstalled = remote.pipeline.addHandler(
            BytePumpHandler(peer: local, side: .remote, counters: counters))
        // `and` hops the second future onto the first's loop, so the callback
        // below runs on `local.eventLoop` regardless of where `remote` lives.
        return localInstalled.and(remoteInstalled).map { _ in
            counters.opened(local: local, remote: remote)
        }
    }

    /// Turns reading on for both sides, once the pump is in place.
    ///
    /// The explicit `read()` beside the option is NOT redundant, and this is
    /// the measurement that says so (2026-09-06, against the Docker rig): a
    /// socket channel's `setOption(autoRead, true)` issues the first read
    /// itself (`BaseSocketChannel.setOption0` calls `read0()` on the
    /// transition), but NIOSSH's `SSHChildChannel.setOption0` only assigns
    /// the flag. Its reads are driven by `unsatisfiedRead`, which nothing
    /// sets until someone calls `read()`, and its `tryToAutoRead` only
    /// recurses AFTER a delivery — so a child channel activated with
    /// `autoRead` off never delivers a byte, however true the flag is made
    /// afterwards. Without this line the rig test hung until the SSH
    /// handshake through the tunnel timed out.
    ///
    /// A second `read()` on a channel that is already reading is harmless,
    /// so the same call covers both kinds.
    public static func startReading(local: Channel, remote: Channel) -> EventLoopFuture<Void> {
        let localReading = local.setOption(ChannelOptions.autoRead, value: true)
            .map { local.read() }
        let remoteReading = remote.setOption(ChannelOptions.autoRead, value: true)
            .map { remote.read() }
        return localReading.and(remoteReading).map { _ in }
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

    init(observer: TunnelConnectionObserver?) {
        self.observer = observer
    }

    /// Reports the open and arms the close report. Called once per pair,
    /// after both handlers are installed — so an observer never sees a
    /// `closed` it has no `opened` for.
    func opened(local: Channel, remote: Channel) {
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
            return .closed(bytesIn: bytesIn, bytesOut: bytesOut)
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

    init(peer: Channel, side: BytePumpSide, counters: BytePumpCounters) {
        self.peer = peer
        self.side = side
        self.counters = counters
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
    /// start again when it drains. The failure arm is empty on purpose: a
    /// channel that has already closed cannot take the option, and its own
    /// close is about to tear the pair down anyway.
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        let writable = context.channel.isWritable
        peer.setOption(ChannelOptions.autoRead, value: writable).whenFailure { _ in }
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
