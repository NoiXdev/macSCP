import Foundation
import NIOCore
import NIOPosix

/// What can go wrong while a tunnel is being carried — transport only.
///
/// Deliberately narrow: a missing secret, an unknown host key or a stored
/// session that cannot be turned into a configuration are NOT cases here.
/// Those already have typed errors of their own (`SecretSourceFailure`,
/// `HostKeyError`, `StoredSessionConnectionError`) and the App maps them to
/// `TunnelState.needsConfirmation`, which is a different answer from
/// `.failed` and must stay distinguishable.
///
/// Every `reason` is a MAPPED sentence — `DialSupport.reason(for:)`, never
/// `String(describing:)` — for the reason that function's own doc comment
/// gives: describing an arbitrary error prints its stored properties, and a
/// transport error is exactly the kind of value that carries the
/// configuration it was dialling with.
public enum TunnelFailure: Error, Sendable, Equatable {
    /// The local port a forward wants is taken. The port is carried because
    /// it is the one thing the user needs in order to free it.
    case portInUse(port: Int)
    /// Any other failure to bind the local listener — a bind address that is
    /// not on this machine, a privileged port without the privilege.
    case bindFailed(reason: String)
    /// The channel through the SSH server could not be opened: the server
    /// refuses forwarding (`AllowTcpForwarding no`), or the destination
    /// behind it is unreachable.
    case channelOpenFailed(reason: String)
    /// A connection this machine makes on a tunnel's behalf failed — the
    /// remote-forward direction, where an inbound channel from the server is
    /// connected to a local address.
    case connectFailed(reason: String)
    /// The channel through the server WAS opened, and gluing the two sides
    /// together then failed — installing the pump, answering the
    /// negotiation, or starting the reads.
    ///
    /// Distinct from `channelOpenFailed` because the two need different
    /// clean-up and say different things about the far side: after this one
    /// there is an open channel on the server to close, and the server is
    /// demonstrably willing to forward.
    case pumpFailed(reason: String)
    /// `start` was called on a listener that has already been started. One
    /// listener binds once; see `LocalForwardListener.start`.
    case alreadyStarted
}

/// What decides where an accepted connection is forwarded to.
///
/// The seam exists because the two local listeners differ in exactly one
/// place: a local forward (`-L`) knows the destination before it binds, and a
/// dynamic forward (`-D`) learns it from the connection itself. Everything
/// else — the bootstrap, the pair tracking, the pump, the teardown — is the
/// same code, so `SOCKS5Listener` is this enum's `.negotiated` arm rather
/// than a second `ServerBootstrap`.
enum ForwardDestination: Sendable {
    /// Every connection goes to the same place.
    case fixed(host: String, remotePort: Int)
    /// The connection names its own destination. The closure runs on the
    /// accepted channel, before the factory, and answers a negotiation the
    /// accept path then drives to its end.
    case negotiated(@Sendable (Channel) async throws -> any ForwardNegotiation)
}

/// One connection's negotiation, in the three moments the accept path has to
/// tell it about.
///
/// A protocol rather than a single closure returning `(host, port)`: the
/// negotiated arm has to be told how the attempt ENDED as well as what it
/// asked for — a SOCKS5 client is owed a reply frame either way — and those
/// two moments are on the far side of an `await` from the first.
protocol ForwardNegotiation: Sendable {
    /// Where the connection asked to go, as the SSH server will reach it.
    var host: String { get }
    var port: Int { get }
    /// The channel through the server is open and the pump is installed.
    /// Called before reading starts, so nothing can arrive between the
    /// negotiation's last word and the pump's first.
    func confirm(on channel: Channel) async throws
    /// The channel through the server could not be opened. Best effort: the
    /// connection may already be gone.
    func reject(_ failure: TunnelFailure, on channel: Channel) async
}

/// The listening half of a local forward (`-L`): a loopback (by default)
/// `ServerBootstrap`, and for every connection it accepts, one channel
/// through the SSH server plus a `BytePump` between the two.
///
/// The channel through the server arrives from a closure rather than from a
/// connection this type holds. That keeps the SSH client private to
/// `CitadelFileSystem` — the production factory is one call to
/// `openDirectTCPIP` — and it is what lets the whole accept path be measured
/// on loopback with no server at all.
public final class LocalForwardListener: @unchecked Sendable {
    /// Opens one channel to `host:port` **as the far side reaches it**.
    ///
    /// Contract, because it cannot be enforced by the type: the channel
    /// comes back with `autoRead` off. Nothing is pumping it yet, and a
    /// channel that reads before its pump is installed drops what it read.
    /// `CitadelFileSystem.openDirectTCPIP` satisfies this.
    public typealias DirectTCPIPFactory = @Sendable (String, Int) async throws -> Channel

    private let group: any EventLoopGroup
    private let open = OpenForwards()

    /// The port the listener actually bound, once it has — the answer for a
    /// forward configured on port 0, and `nil` before `start` and after
    /// `stop`.
    public var boundPort: Int? { open.boundPort }

    /// `MultiThreadedEventLoopGroup.singleton` by default: the listener never
    /// shuts its group down (it does not own it), and the process-wide
    /// singleton is the group NIO intends for exactly that.
    public init(group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.group = group
    }

    /// Binds `bind:localPort` and returns the port actually bound.
    ///
    /// **One listener binds once.** A second `start` — including one after
    /// `stop()` — throws `TunnelFailure.alreadyStarted`. Task 5's reconnect
    /// builds a fresh SSH connection per attempt and builds a fresh listener
    /// with it; that is the documented contract rather than an accident of
    /// this implementation.
    ///
    /// - Parameters:
    ///   - localPort: `0` asks the kernel for an ephemeral port; the answer
    ///     is the return value and `boundPort`.
    ///   - host, remotePort: the destination as the SSH SERVER reaches it,
    ///     handed to the factory unchanged.
    ///   - onFailure: called for each accepted connection whose channel
    ///     through the server could not be opened. Per connection, not per
    ///     tunnel: the listener stays up, since the next connection may well
    ///     succeed.
    @discardableResult
    public func start(
        bind: String, localPort: Int, host: String, remotePort: Int,
        directTCPIPFactory: @escaping DirectTCPIPFactory,
        observer: TunnelConnectionObserver? = nil,
        onFailure: (@Sendable (TunnelFailure) -> Void)? = nil
    ) async throws -> Int {
        try await start(
            bind: bind, localPort: localPort,
            destination: .fixed(host: host, remotePort: remotePort),
            directTCPIPFactory: directTCPIPFactory, observer: observer, onFailure: onFailure)
    }

    /// Binds `bind:localPort` for a `destination` that may be per-connection.
    ///
    /// Module-internal: `SOCKS5Listener` is the one caller, and the public
    /// face of a dynamic forward is that type rather than an argument here.
    @discardableResult
    func start(
        bind: String, localPort: Int, destination: ForwardDestination,
        directTCPIPFactory: @escaping DirectTCPIPFactory,
        observer: TunnelConnectionObserver? = nil,
        onFailure: (@Sendable (TunnelFailure) -> Void)? = nil
    ) async throws -> Int {
        let open = self.open
        // One listener binds once, successfully or not. `stop()` is final:
        // it marks the state stopped so that a connection accepted during
        // the teardown closes itself, and nothing resets that — a listener
        // restarted after `stop()` would bind a port and then silently drop
        // every connection on it. Refusing here is the alternative to a
        // reset, chosen because it is the contract the caller already wants:
        // a reconnect builds its own connection, so it builds its own
        // listener too.
        guard open.claimStart() else { throw TunnelFailure.alreadyStarted }
        let bootstrap = ServerBootstrap(group: group)
            // Lets the listener rebind a port whose previous connections are
            // still in TIME_WAIT. It does NOT let two listeners hold the same
            // address and port at once — that needs `SO_REUSEPORT`, which is
            // not set here — so the second bind of a live port still fails
            // with `EADDRINUSE`, which is what `portInUse` is mapped from.
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                Self.accepted(
                    channel, destination: destination,
                    directTCPIPFactory: directTCPIPFactory, observer: observer,
                    onFailure: onFailure, open: open)
                return channel.eventLoop.makeSucceededVoidFuture()
            }

        let server: Channel
        do {
            server = try await bootstrap.bind(host: bind, port: localPort).get()
        } catch {
            throw Self.bindFailure(error, port: localPort)
        }
        guard let port = server.localAddress?.port else {
            server.close(promise: nil)
            throw TunnelFailure.bindFailed(reason: "the bound socket reports no port")
        }
        open.bound(server, port: port)
        return port
    }

    /// Closes the server socket and every pair still open, and returns only
    /// once each of them has actually closed. Final: this listener cannot be
    /// started again (see `start`).
    ///
    /// A connection accepted while this runs, whose channel through the
    /// server is still being opened, is closed by the accept path itself
    /// when it finds the listener stopped — that one is not waited for here,
    /// since nothing yet holds it.
    public func stop() async {
        let (server, channels) = open.drain()
        if let server {
            server.close(promise: nil)
            try? await server.closeFuture.get()
        }
        for channel in channels {
            channel.close(promise: nil)
        }
        for channel in channels {
            try? await channel.closeFuture.get()
        }
    }

    /// One accepted connection: find out where it is going, open the channel
    /// through the server, glue the two together, then let both start
    /// reading.
    ///
    /// `static` and taking everything it needs as arguments so the
    /// bootstrap's child initializer captures the shared state and not the
    /// listener — the listener is then free of the retain cycle that
    /// `listener → server channel → pipeline → closure → listener` would
    /// otherwise be.
    private static func accepted(
        _ channel: Channel, destination: ForwardDestination,
        directTCPIPFactory: @escaping DirectTCPIPFactory,
        observer: TunnelConnectionObserver?,
        onFailure: (@Sendable (TunnelFailure) -> Void)?,
        open: OpenForwards
    ) {
        guard open.track(channel) else {
            channel.close(promise: nil)
            return
        }
        Task {
            let negotiation: (any ForwardNegotiation)?
            let host: String
            let remotePort: Int
            switch destination {
            case .fixed(let fixedHost, let fixedPort):
                negotiation = nil
                host = fixedHost
                remotePort = fixedPort
            case .negotiated(let negotiate):
                do {
                    let negotiated = try await negotiate(channel)
                    negotiation = negotiated
                    host = negotiated.host
                    remotePort = negotiated.port
                } catch {
                    // A conversation that never named a destination is the
                    // CLIENT's failure, not the tunnel's — a browser pointed
                    // at the SOCKS port, a client offering only
                    // username/password. The negotiation has already said so
                    // in its own protocol and is closing; `onFailure` is not
                    // called, because a tunnel that refuses one bad client is
                    // working exactly as intended.
                    channel.close(promise: nil)
                    return
                }
            }
            // Held outside the `do` so the catch can close it: once the
            // factory has answered, there is a channel open ON THE SERVER,
            // and a pump that then fails to install would otherwise leave it
            // there until `stop()`.
            var opened: Channel?
            do {
                let throughTheServer = try await directTCPIPFactory(host, remotePort)
                opened = throughTheServer
                guard open.track(throughTheServer) else {
                    throughTheServer.close(promise: nil)
                    channel.close(promise: nil)
                    return
                }
                try await BytePump.install(
                    local: channel, remote: throughTheServer, observer: observer).get()
                try await negotiation?.confirm(on: channel)
                // A no-op since round 2 — both sides began reading when
                // `install` added their handlers, from the channels' own
                // lifecycles rather than from this task, which is what
                // stopped it racing NIO's registration. Kept as a step
                // because `SOCKS5Handshake` and its tests describe this
                // path in terms of it running after `confirm`; see
                // `BytePump.startReading`.
                try await BytePump.startReading(
                    local: channel, remote: throughTheServer).get()
            } catch {
                let failure = Self.acceptFailure(error, afterOpen: opened != nil)
                await negotiation?.reject(failure, on: channel)
                opened?.close(promise: nil)
                channel.close(promise: nil)
                onFailure?(failure)
            }
        }
    }

    /// What to report for a failure on the accept path.
    ///
    /// A `TunnelFailure` travels through UNCHANGED. Re-mapping one through
    /// `DialSupport.reason(for:)` destroys it: that function spells out four
    /// error types and reduces everything else to `localizedDescription`,
    /// which for a `TunnelFailure` — no `LocalizedError` conformance — reads
    /// "The operation couldn't be completed. (macSCPCore.TunnelFailure error
    /// 2.)". The factory's own sentence, which is the only one that says why
    /// the server refused, would be replaced by a case index. Only a foreign
    /// error is mapped.
    ///
    /// `afterOpen` decides the case, not the error: everything up to the
    /// factory's answer is `channelOpenFailed`, everything after it is
    /// `pumpFailed`. A `TunnelFailure` the factory itself raised keeps its
    /// own case regardless — it knows better than this function does.
    private static func acceptFailure(_ error: any Error, afterOpen: Bool) -> TunnelFailure {
        if let failure = error as? TunnelFailure { return failure }
        let reason = DialSupport.reason(for: error)
        return afterOpen ? .pumpFailed(reason: reason) : .channelOpenFailed(reason: reason)
    }

    private static func bindFailure(_ error: any Error, port: Int) -> TunnelFailure {
        if let ioError = error as? IOError, ioError.errnoCode == EADDRINUSE {
            return .portInUse(port: port)
        }
        return .bindFailed(reason: DialSupport.reason(for: error))
    }
}

/// The listener's mutable state: the server channel, the channels of every
/// pair currently open, and whether the listener has been stopped.
///
/// A type of its own rather than fields on the listener because the accept
/// closure needs it and must not need the listener. `NSLock` rather than an
/// actor for the reason `BytePumpCounters` gives: the mutations happen inside
/// close callbacks on event loops, where there is no `await`.
private final class OpenForwards: @unchecked Sendable {
    private let lock = NSLock()
    private var server: Channel?
    private var port: Int?
    private var channels: [ObjectIdentifier: Channel] = [:]
    private var started = false
    private var stopped = false

    var boundPort: Int? {
        lock.lock()
        defer { lock.unlock() }
        return port
    }

    /// Takes this listener's one and only start. `false` on every call
    /// after the first, whether or not that first one went on to bind
    /// successfully — a listener is a single use, and a caller that wants to
    /// try again wants a new one.
    func claimStart() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return false }
        started = true
        return true
    }

    func bound(_ channel: Channel, port: Int) {
        lock.lock()
        server = channel
        self.port = port
        lock.unlock()
    }

    /// Remembers a channel so `stop()` can close it, and arranges for it to
    /// be forgotten again when it closes on its own. `false` means the
    /// listener has already been stopped and the caller should close what it
    /// has.
    func track(_ channel: Channel) -> Bool {
        lock.lock()
        let accepted = !stopped
        if accepted { channels[ObjectIdentifier(channel)] = channel }
        lock.unlock()
        guard accepted else { return false }
        channel.closeFuture.whenComplete { [self] _ in forget(channel) }
        return true
    }

    private func forget(_ channel: Channel) {
        lock.lock()
        channels[ObjectIdentifier(channel)] = nil
        lock.unlock()
    }

    /// Hands out everything to close and marks the listener stopped, in one
    /// step: a connection accepted after this returns finds `track` refusing
    /// and closes itself.
    func drain() -> (server: Channel?, channels: [Channel]) {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        let taken = (server, Array(channels.values))
        server = nil
        port = nil
        channels.removeAll()
        return taken
    }
}
