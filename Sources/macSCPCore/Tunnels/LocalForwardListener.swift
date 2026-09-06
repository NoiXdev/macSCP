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
        let open = self.open
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
                    channel, host: host, remotePort: remotePort,
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
    /// once each of them has actually closed.
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

    /// One accepted connection: open the channel through the server, glue the
    /// two together, then let both start reading.
    ///
    /// `static` and taking everything it needs as arguments so the
    /// bootstrap's child initializer captures the shared state and not the
    /// listener — the listener is then free of the retain cycle that
    /// `listener → server channel → pipeline → closure → listener` would
    /// otherwise be.
    private static func accepted(
        _ channel: Channel, host: String, remotePort: Int,
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
            do {
                let throughTheServer = try await directTCPIPFactory(host, remotePort)
                guard open.track(throughTheServer) else {
                    throughTheServer.close(promise: nil)
                    channel.close(promise: nil)
                    return
                }
                try await BytePump.install(
                    local: channel, remote: throughTheServer, observer: observer).get()
                try await BytePump.startReading(
                    local: channel, remote: throughTheServer).get()
            } catch {
                channel.close(promise: nil)
                onFailure?(.channelOpenFailed(reason: DialSupport.reason(for: error)))
            }
        }
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
    private var stopped = false

    var boundPort: Int? {
        lock.lock()
        defer { lock.unlock() }
        return port
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
