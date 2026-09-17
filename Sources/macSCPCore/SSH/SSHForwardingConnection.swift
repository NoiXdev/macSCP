// `@preconcurrency` for the reason `CitadelFileSystem.swift` gives in its
// opening comment: Citadel's `SSHClient` and the NIO stack under it carry no
// `Sendable` conformance this project could add. What this file does with
// them — store the client, open child channels on it, close it — is argued
// at each site below.
@preconcurrency import Citadel
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// An authenticated SSH connection with NO child channel opened on it — what
/// a port forwarding is carried over.
///
/// A forwarding needs a `direct-tcpip` channel per connection (`-L`, `-D`) or
/// a `tcpip-forward` global request (`-R`), and nothing else. Until
/// 2026-09-17 it dialled through `CitadelFileSystem.connect`, which opens the
/// SFTP subsystem on every connection: every tunnel paid a channel it never
/// read, and against a server without SFTP that dial does not fail, it hangs:
/// sshd refuses the subsystem and Citadel's `openSFTP` keeps waiting (a tab's
/// dial against the rig's `sshd-nosftp` was still suspended after more than
/// seven minutes, measured 2026-09-17; `ForwardingWithoutSFTPITests`).
///
/// **It is not a second connect path.** `connect` below calls
/// `CitadelFileSystem.connectAuthenticated`, the same function a tab's dial
/// calls: the same agent handling, jump hop, TOFU validator and accept-retry
/// loop, the same user authentication, timeout and error mapping. A host-key
/// MISMATCH is decided in there, before this type exists, and never reaches
/// the decider. What differs is only the step after authentication — a tab
/// opens SFTP, this opens nothing.
///
/// Owns what it is handed: the client, the jump client when there is one,
/// and the dedicated event-loop group `.agent` auth creates. `disconnect()`
/// releases all three.
final class SSHForwardingConnection: TunnelSSHConnection, @unchecked Sendable {
    private let client: SSHClient
    private let jumpClient: SSHClient?
    private let dedicatedGroup: MultiThreadedEventLoopGroup?

    private init(authenticated: CitadelFileSystem.AuthenticatedSSH) {
        self.client = authenticated.client
        self.jumpClient = authenticated.jumpClient
        self.dedicatedGroup = authenticated.dedicatedGroup
    }

    /// Dials `config` and stops once user authentication has succeeded.
    ///
    /// Same parameters, same errors and the same TOFU verdicts as
    /// `CitadelFileSystem.connect` — both are `connectAuthenticated` — minus
    /// the SFTP open, which is why the R-1 flag is never marked here. A
    /// failed dial therefore releases the dedicated group at once, exactly as
    /// a tab's dial that failed before `openSFTP` does — including with
    /// Citadel's login timer still pending (`CitadelFileSystem
    /// .citadelLoginTimer`), which that shared failure path does not wait
    /// out for either caller.
    static func connect(
        config: SSHConnectionConfig,
        connectTimeout: TimeAmount,
        knownHosts: KnownHostsStore,
        onUnknownHostKey: HostKeyDecider
    ) async throws -> SSHForwardingConnection {
        try await CitadelFileSystem.connectAuthenticated(
            config: config, connectTimeout: connectTimeout, knownHosts: knownHosts,
            onUnknownHostKey: onUnknownHostKey
        ) { authenticated, _ in
            SSHForwardingConnection(authenticated: authenticated)
        }
    }

    /// Closes the connection, then the jump connection it ran through, then
    /// releases the dedicated event-loop group both ran on.
    ///
    /// No SFTP close to bound, which is the step `CitadelFileSystem
    /// .disconnect()` bounds: `SSHClient.close()` against a frozen peer was
    /// measured returning in 0.051039125 s (`BoundedSFTPSession
    /// .closeBoundSeconds`' comment), so these closes stay plain awaits.
    ///
    /// The group is NOT shut down at once. Citadel schedules a 10-second
    /// login timeout on the connection's event loop, once per hop, and never
    /// cancels it (`CitadelFileSystem.citadelLoginTimer`), so a forwarding
    /// stopped soon after its dial — a refused `-R` bind, a quick stop after
    /// autostart — would cut that task off. The release waits the timer out,
    /// detached, the way a tab's waits out `openSFTP`'s longer one; nothing
    /// here called `openSFTP`, so the shorter wait is the one owed. Whether
    /// the immediate shutdown did observable harm was NOT measurable
    /// (2026-09-17: three agent-authenticated dials disconnected at once, no
    /// NIO "Cannot schedule tasks" line in twelve seconds after), so
    /// `SSHForwardingConnectionDisconnectGuardTests` pins the delay in the
    /// source.
    func disconnect() async {
        try? await client.close()
        try? await jumpClient?.close()
        if let dedicatedGroup {
            CitadelFileSystem.releaseAfterCitadelTimer(
                dedicatedGroup, outliving: CitadelFileSystem.citadelLoginTimer)
        }
    }
}

extension SSHForwardingConnection {
    /// Opens a `direct-tcpip` channel to `host:port` **as the far side
    /// reaches it** — the child channel a local or dynamic forward pumps
    /// bytes through.
    ///
    /// The `SSHClient` stays private to this class, so a tunnel gets a
    /// `Channel` and never the client that made it. Opening one does not
    /// disturb the connection or the other channels on it.
    ///
    /// The returned channel speaks `ByteBuffer` in both directions: Citadel
    /// installs its own `DataToBufferCodec` before this initializer runs
    /// (`DirectTCPIP+Client.swift`), which also turns remote half-closure on.
    ///
    /// `autoRead` is off on the way out. Nothing is pumping the channel yet,
    /// and bytes read before `BytePump` is installed would be fired at the
    /// end of a pipeline that drops them — see `LocalForwardListener
    /// .DirectTCPIPFactory`, whose contract this satisfies.
    ///
    /// The originator address is `127.0.0.1:0`. It is a courtesy field in the
    /// channel-open request (the server may log it); this app is the
    /// originator, and it names no port it is not actually listening on.
    public func openDirectTCPIP(host: String, port: Int) async throws -> Channel {
        do {
            let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            return try await client.createDirectTCPIPChannel(
                using: SSHChannelType.DirectTCPIP(
                    targetHost: host, targetPort: port, originatorAddress: originator)
            ) { channel in
                channel.setOption(ChannelOptions.autoRead, value: false)
            }
        } catch {
            throw TunnelFailure.channelOpenFailed(reason: DialSupport.reason(for: error))
        }
    }

    /// Registers the one handler called when this connection's transport
    /// drops — the signal a `TunnelRunner` turns into a reconnect.
    ///
    /// **One handler, not a list.** Citadel's `SSHClient` stores a single
    /// closure (`Client.swift`, `onDisconnect(perform:)`), so a second
    /// registration replaces the first. Nothing else in this project
    /// registers one, and a tunnel owns its connection outright
    /// (`TunnelConnection`'s doc comment), so the runner is the only
    /// registrant there is.
    ///
    /// Fired from the SSH channel's own `closeFuture`, which means it fires
    /// for a deliberate `disconnect()` as well as for a drop. The runner
    /// tears its stream down before disconnecting, so a self-inflicted call
    /// reaches nobody; a caller that cannot say the same has to tell the two
    /// apart itself.
    public func onDisconnect(_ handler: @escaping @Sendable () -> Void) {
        client.onDisconnect(perform: handler)
    }

    /// Asks the server to listen on `bind:port` and hands every connection it
    /// accepts there back as a channel — the `forwarded-tcpip` side of a
    /// remote forward (`-R`).
    ///
    /// Runs until the calling task is cancelled. Citadel's own wrapper sends
    /// `tcpip-forward`, reports the bound port, dispatches inbound channels,
    /// sleeps, and sends `cancel-tcpip-forward` when the sleep is cancelled
    /// (`RemotePortForward+Client.swift`), so cancelling the task is what
    /// takes the listener down on the server.
    ///
    /// **The codec is installed here, and that is a difference from
    /// `openDirectTCPIP`.** Citadel adds its own `DataToBufferCodec` to a
    /// channel it opens (`DirectTCPIP+Client.swift`), but an INBOUND child
    /// channel reaches `handleChannel` raw, straight from NIOSSH's
    /// `inboundChildChannelInitializer` — it speaks `SSHChannelData`, and a
    /// `BytePump` installed on it would unwrap the wrong type. Citadel's
    /// codec is `internal` to that package, so `ForwardedTCPIPCodec` below is
    /// this module's own; like Citadel's it also turns remote half-closure
    /// on, without which a far side that shuts down its write half would
    /// close the whole connection instead.
    ///
    /// Nothing is read from the channel before `handleChannel` returns: an
    /// inbound child channel does not ACTIVATE until the initializer's future
    /// completes (`SSHChildChannel.configure`), and that future is this
    /// closure. Which is also why `handleChannel` must return once the
    /// connection is wired rather than when it ends.
    ///
    /// A `handleChannel` that THROWS refuses that one connection: the
    /// initializer's failure makes NIOSSH answer the server with
    /// `SSH_MSG_CHANNEL_OPEN_FAILURE` and reason code 2, "connect failed",
    /// which is exactly what a local target that refused is. The forward
    /// itself is unaffected.
    ///
    /// A server that refuses the global request — `AllowTcpForwarding no`, or
    /// a non-loopback `bind` without `GatewayPorts`, a port already taken on
    /// the server — comes back as `TunnelFailure.remoteBindRefused`, with
    /// `needsGatewayPorts` true when the bind is not loopback, because the
    /// server does not say which it was and that is the one the user can do
    /// something about; the log's sentence and the App's message both name
    /// `GatewayPorts` then. A cancellation is NOT mapped: it is how a forward
    /// ends normally.
    ///
    /// **`port` 0 is refused**, and that is a limitation of the pinned
    /// Citadel rather than a decision. Measured against the rig on
    /// 2026-09-06: with port 0 the server binds and reports its port, and no
    /// connection ever arrives; with a named port the identical test passes
    /// in 0.1 s.
    ///
    /// The cause is a key mismatch in Citadel `0.12.1-noix.3`, and the key is
    /// the PAIR `(host, port)`, not the port alone.
    /// `SSHClientInboundChannelHandler.registerForwardedTCPIP`
    /// (`ClientSession.swift:19-31`) stores the handler under an
    /// `SSHRemotePortForward(host:boundPort:)` built from what was
    /// REQUESTED, before the request is even sent; the dispatch in
    /// `handleChannel` (`:47-60`) rebuilds that key from
    /// `forwardedTCPIP.listeningHost` and `.listeningPort` — what the server
    /// actually BOUND — and a miss fails the channel with
    /// `CitadelError.channelCreationFailed` inside the library, where nothing
    /// here can see it.
    ///
    /// So port 0 is one instance of a general hazard, and the HOST half is
    /// **unverified**: a server that echoes a `listeningHost` other than the
    /// string that was sent — `0.0.0.0` answered as `""`, or a name resolved
    /// to an address — would produce the identical silent swallow with a
    /// perfectly ordinary port. That was not measured, and could not be on
    /// this rig: `GatewayPorts` is off there, so a non-loopback bind cannot
    /// be exercised at all. It is stated rather than guarded because
    /// guessing which spellings a server may answer with would be a second
    /// unmeasured claim on top of the first.
    ///
    /// Refusing port 0 is the alternative to a forward that looks healthy and
    /// silently swallows every connection. What would retire the guard is a
    /// fork that registers the handler under the BOUND pair, after the reply,
    /// instead of under the requested one before it — written down as a debt
    /// in `docs/superpowers/specs/2026-08-20-backlog-dependencies.md`.
    /// `TunnelRigITests.aRemoteForwardOnPortZeroIsRefused` pins THIS guard,
    /// not Citadel's behaviour, so it cannot announce the fix: it must be
    /// removed together with the guard.
    public func withRemotePortForward(
        bind: String, port: Int,
        onOpen: @escaping @Sendable (Int) -> Void,
        handleChannel: @escaping @Sendable (Channel) async throws -> Void
    ) async throws {
        guard port != 0 else {
            // The sentence is `TunnelFailureKind.remotePortZeroRefused`'s,
            // rendered by `DialSupport.reason(for:)`.
            throw TunnelFailure.remotePortZeroRefused
        }
        do {
            try await client.withRemotePortForward(
                host: bind, port: port,
                onOpen: { forward in onOpen(forward.boundPort) },
                handleChannel: { channel, _ in
                    channel.eventLoop.makeFutureWithTask {
                        try await channel.pipeline.addHandler(ForwardedTCPIPCodec()).get()
                        try await handleChannel(channel)
                    }
                })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.remoteBindFailure(for: error, bind: bind)
        }
    }

    /// The server's refusal of a `tcpip-forward` request, typed.
    ///
    /// Loopback binds are the server's default and need no permission; every
    /// other bind address needs `GatewayPorts`, and a refusal that does not
    /// say so is a dead end for the user. So the refusal carries
    /// `needsGatewayPorts` as a fact, which the App translates, and the log's
    /// sentence (`DialSupport.reason(for:)`) appends the same clause this
    /// function used to append itself — `TunnelFailureKind
    /// .gatewayPortsClause`, byte for byte.
    static func remoteBindFailure(for error: any Error, bind: String) -> TunnelFailure {
        let loopback = ["127.0.0.1", "::1", "localhost"]
        return .remoteBindRefused(
            reason: DialSupport.reason(for: error), needsGatewayPorts: !loopback.contains(bind))
    }
}

/// `SSHChannelData` in, `ByteBuffer` out, on a `forwarded-tcpip` child
/// channel — the same translation Citadel installs on a channel IT opens,
/// written here because that type is `internal` to Citadel and an inbound
/// channel never passes through the code that adds it.
///
/// `allowRemoteHalfClosure` is turned on from `handlerAdded`, as Citadel's
/// does: without it NIOSSH turns a peer's EOF into a full close, and
/// `BytePumpHandler`'s half-close propagation — the shape a client that shuts
/// its write side down and waits for an answer depends on — never sees
/// `ChannelEvent.inputClosed`.
final class ForwardedTCPIPCodec: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func handlerAdded(context: ChannelHandlerContext) {
        // `syncOptions` rather than the future-returning `setOption`, which
        // would have to report a failure from a `@Sendable` closure that
        // cannot legally capture the context. `handlerAdded` runs on the
        // event loop, which is exactly the precondition `syncOptions` has.
        do {
            try context.channel.syncOptions?.setOption(
                ChannelOptions.allowRemoteHalfClosure, value: true)
        } catch {
            context.fireErrorCaught(error)
        }
    }

    /// Anything that is not ordinary channel data — an `extended` stream, or
    /// a payload NIOSSH did not deliver as a buffer — is an error rather than
    /// something to guess at. Citadel's own codec traps on the second of
    /// those; a tunnel closes the one connection instead.
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .channel = payload.type, case .byteBuffer(let bytes) = payload.data else {
            context.fireErrorCaught(SSHChannelError.invalidDataType)
            return
        }
        context.fireChannelRead(wrapInboundOut(bytes))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let bytes = unwrapOutboundIn(data)
        context.write(
            wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(bytes))),
            promise: promise)
    }
}
