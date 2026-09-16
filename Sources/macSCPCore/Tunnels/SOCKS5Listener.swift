import Foundation
import NIOCore
import NIOPosix

/// The listening half of a dynamic forward (`-D`): a loopback (by default)
/// SOCKS5 server, and for every connection it accepts, one channel through
/// the SSH server to wherever that connection asked to go.
///
/// It is `LocalForwardListener` with a different `ForwardDestination` — the
/// same `ServerBootstrap`, the same pair tracking, the same `BytePump`, the
/// same teardown — rather than a second bootstrap of its own. What is new
/// here is only the conversation in front of the pump, which lives in
/// `SOCKS5Handshake.swift`.
///
/// **SOCKS5 without authentication, CONNECT only** (the design's "Limits").
/// A client offering no `00` method is answered `05 FF`; BIND and UDP
/// ASSOCIATE are answered `05 07`.
///
/// **Handshakes are bounded** — `socks5HandshakeDeadline` per handshake and
/// `socks5ParkedHandshakeLimit` handshakes parked at once; a client that
/// stalls past the first is closed, and one that arrives beyond the second
/// is closed without being read (`SOCKS5Handshake.negotiate(on:limits:)`).
public final class SOCKS5Listener: @unchecked Sendable {
    private let listener: LocalForwardListener
    private let limits: SOCKS5HandshakeLimits

    /// How long an accepted client has to name a destination before it is
    /// closed. **Thirty seconds, and this app's own number**: a SOCKS5
    /// greeting plus CONNECT is a few dozen bytes that a working client
    /// sends at once, so the bound only ever meets a client that has
    /// stalled; `ssh -D`, which this forward imitates, has no such deadline
    /// at all. Generous rather than tight because the listener binds
    /// loopback by default — the clients are local processes, and one that
    /// is merely slow (a debugger, a suspended app) should not be cut off.
    static let socks5HandshakeDeadline: Duration = .seconds(30)

    /// How many handshakes may be parked at once before a new connection is
    /// refused. **Sixty-four, and again this app's own number** — `ssh -D`
    /// has no cap. Each parked handshake holds a socket and a task; a
    /// browser opens a handful of connections per origin, so 64 is far above
    /// what legitimate local use reaches while still bounding what a
    /// misbehaving local process can hold for up to the deadline.
    static let socks5ParkedHandshakeLimit = 64

    /// The deadline this listener's handshakes are held to.
    var handshakeDeadline: Duration { limits.deadline }

    /// The cap this listener's parked handshakes are held to.
    var parkedHandshakeLimit: Int { limits.parked.limit }

    /// Handshakes currently parked — accepted, admitted under the cap, and
    /// not yet settled. What the tests observe the cap and `stop()` through.
    var parkedHandshakes: Int { limits.parked.count }

    /// The port the listener actually bound, once it has — the answer for a
    /// forward configured on port 0, and `nil` before `start` and after
    /// `stop`.
    public var boundPort: Int? { listener.boundPort }

    /// A listener held to the production handshake limits above.
    public convenience init(group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.init(
            group: group, handshakeDeadline: Self.socks5HandshakeDeadline,
            parkedHandshakeLimit: Self.socks5ParkedHandshakeLimit,
            deadlineSleeper: { try await Task.sleep(for: $0) })
    }

    /// The seam the handshake limits are injected through. Module-internal:
    /// production uses the two named constants above via `init(group:)`, and
    /// a test passes a sleeper it fires by hand.
    init(
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        handshakeDeadline: Duration, parkedHandshakeLimit: Int,
        deadlineSleeper: @escaping TunnelRunner.Sleeper
    ) {
        listener = LocalForwardListener(group: group)
        limits = SOCKS5HandshakeLimits(
            deadline: handshakeDeadline, sleeper: deadlineSleeper,
            parked: SOCKS5ParkedHandshakes(limit: parkedHandshakeLimit))
    }

    /// Binds `bind:localPort` as a SOCKS5 server and returns the port
    /// actually bound.
    ///
    /// **One listener binds once.** A second `start` — including one after
    /// `stop()` — throws `TunnelFailure.alreadyStarted`, inherited from the
    /// `LocalForwardListener` underneath and stated here because it is this
    /// type's contract too: `LiveTunnelRuntimeFactory` asserts it for all
    /// three runtimes on their behalf, and the two siblings
    /// (`LocalForwardListener.start`, `RemoteForward.start`) each say it
    /// themselves. A reconnect builds a fresh SSH connection, so it builds a
    /// fresh listener with it.
    ///
    /// - Parameters:
    ///   - localPort: `0` asks the kernel for an ephemeral port; the answer
    ///     is the return value and `boundPort`.
    ///   - directTCPIPFactory: takes the destination the SOCKS client named,
    ///     unresolved — a domain name in a CONNECT request is for the SSH
    ///     server to resolve, which is the point of a dynamic forward.
    ///   - onFailure: called for each accepted connection whose channel
    ///     through the server could not be opened. A client that fails the
    ///     SOCKS5 conversation itself is NOT reported here: it is turned away
    ///     with a reply frame and the tunnel stays healthy.
    @discardableResult
    public func start(
        bind: String, localPort: Int,
        directTCPIPFactory: @escaping LocalForwardListener.DirectTCPIPFactory,
        observer: TunnelConnectionObserver? = nil,
        onFailure: (@Sendable (TunnelFailure) -> Void)? = nil
    ) async throws -> Int {
        let limits = self.limits
        return try await listener.start(
            bind: bind, localPort: localPort,
            destination: .negotiated { channel in
                try await SOCKS5Handshake.negotiate(on: channel, limits: limits)
            },
            directTCPIPFactory: directTCPIPFactory, observer: observer, onFailure: onFailure)
    }

    /// Closes the server socket and every pair still open, and returns only
    /// once each of them has actually closed. Final: this listener cannot be
    /// started again (see `start`).
    public func stop() async {
        await listener.stop()
    }
}
