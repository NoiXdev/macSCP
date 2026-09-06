import Foundation
import NIOCore
import Synchronization

/// The SSH connection a tunnel is carried over, as `TunnelRunner` needs it.
///
/// A seam for the same reason `LocalForwardListener.DirectTCPIPFactory` and
/// `RemoteForwardTransport` are seams: the `SSHClient` stays private to
/// `CitadelFileSystem`, so the runner gets channels and a disconnect signal
/// and never the client that made them — and the whole lifecycle can then be
/// measured with no server at all.
///
/// It inherits `RemoteForwardTransport` rather than restating
/// `withRemotePortForward`: a remote forward already speaks to a connection
/// through exactly that protocol, and `CitadelFileSystem` already conforms.
public protocol TunnelSSHConnection: RemoteForwardTransport {
    /// Registers the one handler called when this connection's transport
    /// drops — the signal `TunnelRunner` turns into
    /// `TunnelEvent.connectionLost`.
    ///
    /// **One handler, not a list**, because the underlying `SSHClient` holds
    /// exactly one: a second registration replaces the first. A tunnel owns
    /// its connection outright (`TunnelConnection`'s doc comment: a tunnel
    /// does not borrow a tab's), so the runner is the only registrant there
    /// is.
    func onDisconnect(_ handler: @escaping @Sendable () -> Void)

    /// Opens one channel to `host:port` as the far side reaches it, with
    /// `autoRead` off — `LocalForwardListener.DirectTCPIPFactory`'s
    /// contract.
    func openDirectTCPIP(host: String, port: Int) async throws -> Channel

    /// Ends the connection. Awaited: the runner must not build the next
    /// one until this one is actually gone.
    func disconnect() async
}

extension CitadelFileSystem: TunnelSSHConnection {}

/// One STARTED forward, whichever of the three kinds it is — what the runner
/// holds between `active` and `stop`.
///
/// Deliberately tiny. The runner does not care whether it is holding a
/// `ServerBootstrap`, a SOCKS5 conversation or a global request on the
/// server; it cares about the port to log and the teardown to await.
public protocol TunnelRuntime: Sendable {
    /// The port the forward actually bound — a LOCAL port for `.local` and
    /// `.dynamic`, the SERVER's port for `.remote`. `nil` before the start
    /// completed and after `stop()`.
    var boundPort: Int? { get }

    /// Closes everything this forward holds, and returns only once it is
    /// closed. Bounded by the underlying forward (`RemoteForward.stop()`
    /// spends at most five seconds per forward), never unbounded.
    func stop() async
}

/// Builds the runtime for one profile kind over one connection.
///
/// A seam so `TunnelRunnerTests` can drive the whole lifecycle — connect,
/// forward, loss, backoff, stop — without binding a port or dialling a
/// server. `LiveTunnelRuntimeFactory` below is the one production
/// implementation.
public protocol TunnelRuntimeFactory: Sendable {
    /// - Parameters:
    ///   - observer: the per-connection counter the runner feeds
    ///     `active(connections:)` from.
    ///   - onEnded: called when the forward ends BY ITSELF, with the SSH
    ///     connection still up — the shape Task 4 handed off as reporting to
    ///     nobody (a remote forward whose transport returns or throws after
    ///     the server confirmed it). Never called for a cancellation, which
    ///     is how `stop()` ends a forward normally.
    func start(
        _ kind: TunnelProfile.Kind, over connection: any TunnelSSHConnection,
        observer: @escaping TunnelConnectionObserver,
        onEnded: @escaping @Sendable () -> Void
    ) async throws -> any TunnelRuntime
}

/// The production factory: a `LocalForwardListener` for `.local`, a
/// `SOCKS5Listener` for `.dynamic`, a `RemoteForward` for `.remote`.
///
/// **Every one of the three is single-use** (each type's own `start` throws
/// `TunnelFailure.alreadyStarted` on a second call), which is why this is a
/// factory rather than a stored object: a reconnect asks for a new runtime
/// over a new connection, and gets genuinely new instances.
public struct LiveTunnelRuntimeFactory: TunnelRuntimeFactory {
    public init() {}

    public func start(
        _ kind: TunnelProfile.Kind, over connection: any TunnelSSHConnection,
        observer: @escaping TunnelConnectionObserver,
        onEnded: @escaping @Sendable () -> Void
    ) async throws -> any TunnelRuntime {
        switch kind {
        case .local(let bind, let localPort, let host, let remotePort):
            let listener = LocalForwardListener()
            do {
                _ = try await listener.start(
                    bind: bind, localPort: localPort, host: host, remotePort: remotePort,
                    directTCPIPFactory: { host, port in
                        try await connection.openDirectTCPIP(host: host, port: port)
                    },
                    observer: observer)
            } catch {
                // A listener whose bind failed holds no socket, but one
                // whose `start` failed AFTER binding would — and only
                // `stop()` knows which. Cheap, and it is the difference
                // between a failed attempt and a leaked port.
                await listener.stop()
                throw error
            }
            return LocalForwardRuntime(listener: listener)

        case .dynamic(let bind, let localPort):
            let listener = SOCKS5Listener()
            do {
                _ = try await listener.start(
                    bind: bind, localPort: localPort,
                    directTCPIPFactory: { host, port in
                        try await connection.openDirectTCPIP(host: host, port: port)
                    },
                    observer: observer)
            } catch {
                await listener.stop()
                throw error
            }
            return DynamicForwardRuntime(listener: listener)

        case .remote(let bind, let remotePort, let localHost, let localPort):
            let forward = RemoteForward(
                transport: EndReportingTransport(wrapped: connection, onEnded: onEnded))
            // `RemoteForward.start` stops itself on every failure path (see
            // its own `catch`), so there is no `stop()` to add here.
            _ = try await forward.start(
                bind: bind, remotePort: remotePort, localHost: localHost, localPort: localPort,
                observer: observer)
            return RemoteForwardRuntime(forward: forward)
        }
    }
}

/// `-L`. A wrapper rather than a conformance on `LocalForwardListener`
/// itself, so `TunnelRuntime` — a protocol the runner defines for its own
/// convenience — does not become part of the listener's published contract.
private struct LocalForwardRuntime: TunnelRuntime {
    let listener: LocalForwardListener
    var boundPort: Int? { listener.boundPort }
    func stop() async { await listener.stop() }
}

/// `-D`.
private struct DynamicForwardRuntime: TunnelRuntime {
    let listener: SOCKS5Listener
    var boundPort: Int? { listener.boundPort }
    func stop() async { await listener.stop() }
}

/// `-R`.
private struct RemoteForwardRuntime: TunnelRuntime {
    let forward: RemoteForward
    var boundPort: Int? { forward.boundPort }
    func stop() async { await forward.stop() }
}

/// Reports a remote forward that ended after the server had already
/// confirmed it.
///
/// Task 4's hand-off named the hole: `RemoteForward` reports a per-connection
/// failure through `onConnectionFailure`, and reports the START failure
/// through `start`'s own throw — but a transport that returns or throws
/// AFTER `onOpen` has fired reports to nobody at all. The forward looks
/// healthy and carries nothing.
///
/// Closed here rather than inside `RemoteForward`, because the seam it needs
/// is the transport's own return, and this is the layer that owns the
/// transport: the runner asks for a forward over a connection, and this
/// decorator is what the forward is given instead of the connection.
///
/// **A cancellation is not an ending.** `RemoteForward.stop()` cancels the
/// task carrying the forward — that is how `cancel-tcpip-forward` gets sent
/// — so a `CancellationError` here is the normal, asked-for teardown and
/// must not wake the runner's reconnect.
///
/// **`onOpen` gates the report.** A transport that throws BEFORE naming a
/// port has failed the start, and `start` throws that error to the factory's
/// caller; reporting an ending as well would drive a reconnect for a forward
/// that never existed.
/// Module-internal rather than `private` so `TunnelRuntimeTests` can drive
/// its three cases directly — a `.remote` runtime is otherwise only
/// reachable through a live SSH connection, and a mutation probe on the
/// cancellation gate below came back GREEN for exactly that reason
/// (2026-09-06).
struct EndReportingTransport: RemoteForwardTransport {
    let wrapped: any TunnelSSHConnection
    let onEnded: @Sendable () -> Void

    func withRemotePortForward(
        bind: String, port: Int, onOpen: @escaping @Sendable (Int) -> Void,
        handleChannel: @escaping @Sendable (Channel) async throws -> Void
    ) async throws {
        let opened = Mutex(false)
        func report() {
            guard opened.withLock({ $0 }), !Task.isCancelled else { return }
            onEnded()
        }
        do {
            try await wrapped.withRemotePortForward(
                bind: bind, port: port,
                onOpen: { boundPort in
                    opened.withLock { $0 = true }
                    onOpen(boundPort)
                },
                handleChannel: handleChannel)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            report()
            throw error
        }
        report()
    }
}
