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
public final class SOCKS5Listener: @unchecked Sendable {
    private let listener: LocalForwardListener

    /// The port the listener actually bound, once it has — the answer for a
    /// forward configured on port 0, and `nil` before `start` and after
    /// `stop`.
    public var boundPort: Int? { listener.boundPort }

    public init(group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        listener = LocalForwardListener(group: group)
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
        try await listener.start(
            bind: bind, localPort: localPort,
            destination: .negotiated { channel in
                try await SOCKS5Handshake.negotiate(on: channel)
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
