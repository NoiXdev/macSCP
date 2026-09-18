import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// The SSH side of a remote forward (`-R`), as the one thing `RemoteForward`
/// needs from a connection.
///
/// A seam for the same reason `LocalForwardListener.DirectTCPIPFactory` is
/// one: the `SSHClient` stays private to `SSHForwardingConnection`, so a tunnel
/// gets channels and never the client that made them — and the whole forward
/// can then be measured on loopback with no server at all.
public protocol RemoteForwardTransport: Sendable {
    /// Asks the server to listen on `bind:port` and runs until the calling
    /// task is cancelled, at which point the forward is cancelled on the
    /// server too.
    ///
    /// - Parameters:
    ///   - port: the port the SERVER listens on. **`0` — "let the server
    ///     pick" — is refused by the only transport there is**; see
    ///     `SSHForwardingConnection.withRemotePortForward`, which carries the
    ///     measurement. The protocol still takes an `Int` rather than
    ///     forbidding zero in the type, because the refusal belongs to that
    ///     transport's dependency and not to this seam. `onOpen` fires
    ///     exactly once, before any connection, with the port the server
    ///     confirmed.
    ///   - handleChannel: called for every connection the server accepts on
    ///     the bound port, with a channel that speaks `ByteBuffer` in both
    ///     directions and has not been read from yet. **Throwing refuses
    ///     that one connection** — the SSH transport answers the server with
    ///     a channel-open failure instead of a confirmation — and does not
    ///     end the forward.
    func withRemotePortForward(
        bind: String, port: Int,
        onOpen: @escaping @Sendable (Int) -> Void,
        handleChannel: @escaping @Sendable (Channel) async throws -> Void
    ) async throws
}

/// A remote forward (`-R`): the SERVER listens on `bind:remotePort`, and every
/// connection it accepts there is carried back over the SSH connection as a
/// `forwarded-tcpip` channel, connected to `localHost:localPort` on this
/// machine and pumped.
///
/// The mirror image of `LocalForwardListener`, and deliberately shaped like
/// it: one instance is one forward, `start` binds once, `stop()` closes
/// everything and returns only when it is closed, and a connection that fails
/// is reported per connection rather than failing the tunnel.
///
/// There is no `ServerBootstrap` here because there is no listener on this
/// machine — the listening socket belongs to the server, which is the whole
/// point of the direction. What takes its place is a long-lived task inside
/// `withRemotePortForward`: the global request is sent when it starts, and
/// `cancel-tcpip-forward` when it is cancelled.
public final class RemoteForward: @unchecked Sendable {
    /// Reports one connection that could not be served, with the tunnel
    /// itself unaffected. Per connection, not per tunnel: the local target
    /// may well be listening again by the time the next one arrives.
    public typealias ConnectionFailureObserver = @Sendable (TunnelFailure) -> Void

    private let transport: any RemoteForwardTransport
    private let open = OpenPairs()
    private let cancellationBoundSeconds: Int
    private let localConnected: LocalConnectedHook?

    /// Runs after an inbound connection's local target has answered and
    /// before the new local channel is tracked — the one moment `serve`'s
    /// second stop race needs a stop to land in, and one no other seam of
    /// this type reaches: the local dial is a loopback connect that
    /// completes in microseconds. Module-internal and `nil` in production.
    typealias LocalConnectedHook = @Sendable () async -> Void

    /// The port the SERVER confirmed, once it has — `nil` before `start`
    /// and after `stop`. It is the port that was ASKED for: a forward cannot
    /// ask the server to choose (see `start`), so this never carries a
    /// number the caller did not already know.
    public var boundPort: Int? { open.boundPort }

    public convenience init(transport: any RemoteForwardTransport) {
        self.init(transport: transport, cancellationBoundSeconds: Self.cancellationBound)
    }

    /// The teardown bound as an argument, so a test can measure the
    /// abandonment in `stop()` without spending the production number on
    /// every run. Module-internal: production has exactly one value for it.
    init(
        transport: any RemoteForwardTransport, cancellationBoundSeconds: Int,
        localConnected: LocalConnectedHook? = nil
    ) {
        self.transport = transport
        self.cancellationBoundSeconds = cancellationBoundSeconds
        self.localConnected = localConnected
    }

    /// Asks the server to listen, and returns the port it bound.
    ///
    /// **One forward starts once.** A second `start` — including one after
    /// `stop()` — throws `TunnelFailure.alreadyStarted`, the contract
    /// `LocalForwardListener.start` states and for the same reason: a
    /// reconnect builds a fresh SSH connection, so it builds a fresh forward
    /// with it.
    ///
    /// Returns only once the server has answered: the request is sent from a
    /// long-lived task, and this waits for either the bound port or the
    /// failure that came instead. A refusal the transport raised itself
    /// travels through unchanged — `remoteBindRefused`'s
    /// `needsGatewayPorts` is the only thing that says why a non-loopback
    /// bind was turned down — while a foreign error is mapped to
    /// `bindFailed`.
    ///
    /// **That wait is bounded and cancellable**, because the thing being
    /// waited for is a server's reply to a global request and a server that
    /// never answers is not a hypothetical. `tcpip-forward` is sent with
    /// `wantReply`, and Citadel completes its promise only from the reply;
    /// nothing underneath times it out. So: `answerBound` elapsing stops the
    /// forward and throws `remoteForwardUnanswered`, and cancelling the calling task
    /// throws `CancellationError` rather than parking forever. The default
    /// bound is `SettingsStore.defaultConnectTimeoutSeconds`, the same
    /// number `TunnelConnection.connect` uses by default (the App may dial
    /// with `settingsStore.connectTimeoutSeconds` instead) — one round
    /// trip on a connection that is already established cannot reasonably
    /// need longer than the connect itself was given.
    ///
    /// - Parameters:
    ///   - bind, remotePort: the address the SERVER listens on. `0.0.0.0`
    ///     needs the server's `GatewayPorts`. **`remotePort` must name a
    ///     port**: the SSH transport refuses `0`; see
    ///     `SSHForwardingConnection.withRemotePortForward` for why, and for what
    ///     would have to change to allow it.
    ///   - localHost, localPort: where each inbound connection is connected
    ///     to on THIS machine.
    ///   - onConnectionFailure: one call per inbound connection that could
    ///     not be served.
    ///   - answerBound: how long the server has to answer the forwarding
    ///     request. Production passes the default; a test passes a small one
    ///     so the bound is measured rather than spent.
    @discardableResult
    public func start(
        bind: String, remotePort: Int, localHost: String, localPort: Int,
        observer: TunnelConnectionObserver? = nil,
        onConnectionFailure: ConnectionFailureObserver? = nil,
        answerBound: Duration = .seconds(SettingsStore.defaultConnectTimeoutSeconds)
    ) async throws -> Int {
        let open = self.open
        guard open.claimStart() else { throw TunnelFailure.alreadyStarted }
        let opened = OpenPortBox()
        let transport = self.transport
        let localConnected = self.localConnected
        let task = Task {
            do {
                try await transport.withRemotePortForward(
                    bind: bind, port: remotePort,
                    onOpen: { port in
                        open.bound(port: port)
                        opened.resolve(.success(port))
                    },
                    handleChannel: { inbound in
                        try await Self.serve(
                            inbound, localHost: localHost, localPort: localPort,
                            observer: observer, onConnectionFailure: onConnectionFailure,
                            open: open, localConnected: localConnected)
                    })
                // Citadel's wrapper returns only when its sleep ends, which
                // nothing but cancellation does. Resolving here covers the
                // case where a transport returns without ever naming a port;
                // a box already resolved ignores this.
                opened.resolve(
                    .failure(
                        TunnelFailure.bindFailed(
                            reason: "the forward ended before the server named a port")))
            } catch {
                opened.resolve(.failure(Self.startFailure(error)))
            }
        }
        open.running(task)
        // The bound is a task of its own resolving the same once-latch,
        // rather than a `withTaskGroup` race: a group awaits every child
        // before its scope returns, even a cancelled one, and the child here
        // is a transport that by construction does not finish early. It is
        // the argument `BoundedClose`'s doc comment makes, applied to a
        // latch that already exists.
        let deadline = Task {
            try? await Task.sleep(for: answerBound)
            opened.resolve(
                .failure(TunnelFailure.remoteForwardUnanswered))
        }
        defer { deadline.cancel() }
        do {
            return try await opened.wait()
        } catch {
            // Everything that reaches here — the transport's refusal, the
            // bound elapsing, the caller's own cancellation — leaves a
            // forward that must not stay half-started: the task may still be
            // running, and on the bound-elapsed path the server may yet
            // answer and begin sending connections to a forward nobody is
            // holding. `stop()` cancels it, which is also what sends
            // `cancel-tcpip-forward`, and closes anything already open.
            await stop()
            throw error
        }
    }

    /// How long `stop()` waits for the cancelled forward to finish before
    /// abandoning it.
    ///
    /// Five seconds, the same number and the same argument as
    /// `BoundedSFTPSession.closeBoundSeconds`: what is being waited for is
    /// one round trip to a server that may already be gone — enough for a
    /// real one, not enough to be a hang. A copy of the number rather than a
    /// reference to it, because the two bounds are for different round trips
    /// and one moving is no reason for the other to.
    private static let cancellationBound = 5

    /// Cancels the forward on the server, closes every pair still open, and
    /// returns once each of those channels has actually closed and the
    /// forward's task is over or has been abandoned.
    ///
    /// Cancelling is what sends `cancel-tcpip-forward`: Citadel's wrapper
    /// sleeps until the task is cancelled and sends the cancellation from
    /// there. Final — this forward cannot be started again (see `start`).
    ///
    /// **The wait for the task is BOUNDED**, and that is not caution but a
    /// measurement. `Task<Void, Never>.value` ignores the awaiting task's
    /// own cancellation, so an unbounded `await task.value` cannot be
    /// interrupted by anything — observed on 2026-09-06 while planting a
    /// mutation here: with the `cancel()` above removed, the test bundle sat
    /// for **10 minutes 44 seconds** under a one-minute `.timeLimit`, which
    /// recorded its issue and then could not end the test. What the real
    /// code waits on is Citadel's `cancel-tcpip-forward`, an
    /// `EventLoopFuture.get()` on a promise only a SERVER REPLY completes
    /// (`RemotePortForward+Client.swift:118-131`) — exactly the shape
    /// `BoundedClose`'s own doc comment names as the reason it exists. On a
    /// dropped connection that reply never comes, and without this bound
    /// Task 5's `stopAll()` would hang the quit sequence.
    ///
    /// Abandoning it is safe in the way that matters: the task is already
    /// cancelled, every channel is already closed and awaited above, and the
    /// SSH connection's own teardown ends what is left.
    public func stop() async {
        let (task, channels) = open.drain()
        task?.cancel()
        for channel in channels {
            channel.close(promise: nil)
        }
        for channel in channels {
            try? await channel.closeFuture.get()
        }
        guard let task else { return }
        _ = await BoundedClose.run(boundSeconds: cancellationBoundSeconds) {
            await task.value
        }
    }

    /// One inbound connection: dial the local target, glue the two together,
    /// and let both start reading.
    ///
    /// `static` and taking everything it needs as arguments so the closure
    /// the transport holds captures the shared state and not the forward.
    ///
    /// **The local channel is dialled on the INBOUND channel's own event
    /// loop.** Two reasons, in order: the pair then shares one loop, so
    /// every cross-channel call `BytePumpHandler` makes runs inline instead
    /// of hopping (it is written to survive the hop — see `BytePump` — but
    /// nothing here needs to pay for it); and it needs no group of its own to
    /// own and shut down, because that loop belongs to the SSH connection,
    /// whose life strictly contains every channel forwarded over it.
    /// `ClientBootstrap`'s name resolution does not run on the loop
    /// (`GetaddrinfoResolver` offloads `getaddrinfo` to a `DispatchQueue`),
    /// so a local host that needs looking up cannot stall the connection.
    ///
    /// **Nothing here starts the reads.** `BytePumpHandler` does it itself,
    /// from each channel's own lifecycle, the moment it is added — this file
    /// carried a `ReadStarter` handler of its own until Task 2's round 2
    /// moved that work into the pump, and round 1 of this task deleted the
    /// duplicate. Which of the pump's two arms fires depends on the
    /// channel, and both are reachable here. The local channel takes
    /// `channelActive`: its handler is installed from the bootstrap's
    /// `channelInitializer`, before the channel is registered. The inbound
    /// channel takes `channelActive` too on the SSH transport — a
    /// `forwarded-tcpip` child channel does not activate until the
    /// initializer's future completes, and that future is the closure this
    /// runs inside — and `handlerAdded` on a transport that hands over an
    /// already connected socket, which is what `RemoteForwardTests` does.
    /// Neither case starts a read from this task, which is the property
    /// that matters.
    ///
    /// A failure to reach the local target **throws**, which the transport
    /// turns into a channel-open failure for the server, AND closes the
    /// inbound channel here. Both, because the two halves are needed by
    /// different transports: NIOSSH answers the server from the throw, and a
    /// transport that is a plain socket learns nothing from it.
    ///
    /// **A stop is never a connection failure.** Two places find the
    /// forward already stopped — the inbound channel arriving after
    /// `stop()`, and the local channel coming up after it — and both throw
    /// (the server is still owed a refusal) without calling
    /// `onConnectionFailure`. Until 2026-09-18 the second one threw from
    /// inside the pair's `do` and was counted as a failure while the first
    /// was not (`RemoteForwardTests.aStopWhileTheLocalTargetAnswersIsNotAFailure`).
    private static func serve(
        _ inbound: Channel, localHost: String, localPort: Int,
        observer: TunnelConnectionObserver?,
        onConnectionFailure: ConnectionFailureObserver?,
        open: OpenPairs, localConnected: LocalConnectedHook?
    ) async throws {
        guard open.track(inbound) else {
            inbound.close(promise: nil)
            throw TunnelFailure.connectFailed(reason: "the forward has been stopped")
        }
        let counters = BytePumpCounters(observer: observer)
        let local: Channel
        do {
            local = try await ClientBootstrap(group: inbound.eventLoop)
                // Nothing may be read before the pump is in place, and the
                // pump owns the option from then on — as its backpressure
                // control, and as the thing that turns it back on. The
                // handler added below does that from this channel's own
                // lifecycle: `handlerAdded` if it is somehow already active,
                // `channelActive` otherwise, exactly one of the two.
                .channelOption(ChannelOptions.autoRead, value: false)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .channelInitializer { channel in
                    // The pump's local half is installed HERE, before the
                    // channel is ever registered, so no byte can be read
                    // before there is somewhere to put it. Its peer already
                    // exists: an inbound connection is what brought us here.
                    channel.pipeline.addHandler(
                        BytePumpHandler(peer: inbound, side: .local, counters: counters))
                }
                .connect(host: localHost, port: localPort)
                .get()
        } catch {
            let failure = TunnelFailure.connectFailed(reason: DialSupport.reason(for: error))
            inbound.close(promise: nil)
            onConnectionFailure?(failure)
            throw failure
        }
        await localConnected?()
        // The second stop race, answered exactly like the first one above:
        // outside the `do` below, whose `catch` reports, because a stop is
        // never a connection failure — the user asked for the forward to be
        // gone, and nothing about this connection failed.
        guard open.track(local) else {
            local.close(promise: nil)
            inbound.close(promise: nil)
            throw TunnelFailure.connectFailed(reason: "the forward has been stopped")
        }
        do {
            try await inbound.pipeline.addHandler(
                BytePumpHandler(peer: local, side: .remote, counters: counters)).get()
        } catch {
            let failure = Self.pairFailure(error)
            local.close(promise: nil)
            inbound.close(promise: nil)
            onConnectionFailure?(failure)
            throw failure
        }
        // Arms the close report only once both halves are in place, so an
        // observer never sees a `closed` it has no `opened` for.
        counters.opened(local: local, remote: inbound)
    }

    /// What `start` reports. A `TunnelFailure` the transport raised itself
    /// travels through unchanged, for the reason
    /// `LocalForwardListener.acceptFailure` gives at length: re-mapping one
    /// through `DialSupport.reason(for:)` replaces its sentence with a case
    /// index, and here the case is `remoteBindRefused` with its
    /// `needsGatewayPorts`, or `remotePortZeroRefused`. Only a foreign error
    /// is mapped.
    private static func startFailure(_ error: any Error) -> TunnelFailure {
        if let failure = error as? TunnelFailure { return failure }
        return .bindFailed(reason: DialSupport.reason(for: error))
    }

    private static func pairFailure(_ error: any Error) -> TunnelFailure {
        if let failure = error as? TunnelFailure { return failure }
        return .pumpFailed(reason: DialSupport.reason(for: error))
    }
}

/// Everything a running remote forward has to be able to close: the task
/// carrying the forward, and both channels of every pair currently open.
///
/// A type of its own rather than fields on `RemoteForward` because the
/// per-connection closure needs it and must not need the forward. `NSLock`
/// rather than an actor for the reason `BytePumpCounters` gives: the
/// mutations happen inside close callbacks on event loops, where there is no
/// `await`.
private final class OpenPairs: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var port: Int?
    private var channels: [ObjectIdentifier: Channel] = [:]
    private var started = false
    private var stopped = false

    var boundPort: Int? {
        lock.lock()
        defer { lock.unlock() }
        return port
    }

    /// Takes this forward's one and only start. `false` on every call after
    /// the first, whether or not that first one went on to bind.
    func claimStart() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return false }
        started = true
        return true
    }

    func running(_ task: Task<Void, Never>) {
        lock.lock()
        let alreadyStopped = stopped
        if !alreadyStopped { self.task = task }
        lock.unlock()
        // `stop()` between the start and here would otherwise leave this
        // task running with nothing holding it.
        if alreadyStopped { task.cancel() }
    }

    func bound(port: Int) {
        lock.lock()
        if !stopped { self.port = port }
        lock.unlock()
    }

    /// Remembers a channel so `stop()` can close it, and arranges for it to
    /// be forgotten again when it closes on its own. `false` means the
    /// forward has already been stopped and the caller should close what it
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

    /// Hands out everything to end and marks the forward stopped, in one
    /// step: a connection arriving after this returns finds `track` refusing
    /// and closes itself.
    func drain() -> (task: Task<Void, Never>?, channels: [Channel]) {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        let taken = (task, Array(channels.values))
        task = nil
        port = nil
        channels.removeAll()
        return taken
    }
}

/// The bound port, or the failure that came instead — published once, from
/// the forward's task, to the `start` that is waiting for it.
///
/// An `NSLock` and at most one continuation rather than an `AsyncStream`: the
/// value is delivered exactly once and never again, which a stream would let
/// a later edit violate silently. A second `resolve` is dropped, so the three
/// paths that can reach it — the transport naming a port, the task ending,
/// and the answer bound elapsing — cannot resume a continuation twice.
///
/// **`wait()` answers task cancellation.** A bare
/// `withCheckedThrowingContinuation` does not: it parks until somebody
/// resumes it, so a cancelled `start` would sit here forever while its
/// caller believed the cancellation had taken. That is the defect
/// `docs/BACKLOG.md`'s "A test parked on a bare continuation outlives its
/// time limit" records for the test suite, in production. The shape is
/// `Tests/MacSCPTestSupport/AwaitResumption.swift`'s and
/// `AwaitCancellably.swift`'s: `withTaskCancellationHandler` around the
/// continuation, and ONE latch — `settled` — deciding which of the two
/// racing sides gets to resume it. `onCancel` can run before the
/// continuation has even been stored, which is why `cancel()` records the
/// outcome whether or not there is a waiter to hand it to.
private final class OpenPortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var settled: Result<Int, any Error>?
    private var waiter: CheckedContinuation<Int, any Error>?

    func resolve(_ outcome: Result<Int, any Error>) {
        lock.lock()
        let waiting: CheckedContinuation<Int, any Error>?
        if settled == nil {
            settled = outcome
            waiting = waiter
            waiter = nil
        } else {
            waiting = nil
        }
        lock.unlock()
        waiting?.resume(with: outcome)
    }

    func wait() async throws -> Int {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Int, any Error>) in
                lock.lock()
                let already = settled
                if already == nil { waiter = continuation }
                lock.unlock()
                if let already { continuation.resume(with: already) }
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }
}
