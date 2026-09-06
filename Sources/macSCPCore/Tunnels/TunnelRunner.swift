import Foundation

/// One profile, driven through its whole lifecycle: dial, forward, carry,
/// notice the connection dropping, back off, dial again — until `stop()`.
///
/// An actor per profile. `TunnelManager` (Task 6) owns a collection of these
/// and knows nothing about SSH; everything below is what the runner does with
/// ONE profile.
///
/// **The state is `TunnelStatePlan`'s, never this type's.** Every transition
/// goes through `TunnelStatePlan.next(_:on:)`; nothing here assigns a state
/// directly. What this type owns is the mapping from real events — a dial
/// throwing, a listener binding, a disconnect handler firing, a backoff
/// elapsing — to the `TunnelEvent` values that table understands.
///
/// **`retryDue` is fed when a retry's dial has produced a live forward, not
/// when the backoff timer fires**, and that is the one place the runner reads
/// the plan's table against the grain of an event name. The reason is the
/// table itself: `reconnecting(k) + connectionLost → reconnecting(k+1)` is
/// the ONLY row that increments an attempt, and it is reachable only while
/// the state is still `reconnecting`. Feeding `retryDue` at the timer would
/// move the state to `connecting` first, so a failed retry would take
/// `connecting + connectionLost → reconnecting(1)` instead and reset the
/// counter on every attempt — turning the documented 2, 4, 8, 16 … series
/// into 2, 2, 2, 2 …. So a reconnect stays `reconnecting(k)` across its own
/// dial (which is also what the user should see: "reconnecting, attempt 3",
/// not a `connecting` that hides which attempt this is), and `retryDue`
/// immediately precedes the `listening` that makes it `active` again.
/// `aFailedRetryKeepsClimbing` pins the climbing series (2, 4, 8 across
/// three consecutive failed retries); `aLossAfterAHealthyPeriodStartsTheBackoffOver`
/// pins the other half of the same table — a loss AFTER the tunnel was
/// active again starts at `reconnecting(1)`, so a long-lived tunnel's first
/// blip never inherits an old attempt count.
///
/// **Nothing is leaked.** Every exit from an attempt — a loss, a failure, a
/// cancellation — runs the same teardown, runtime first and connection
/// second (the nesting order `TunnelRigITests`' own teardown uses), and both
/// are awaited. A reconnect therefore builds its new connection only after
/// the old one is actually gone, which is what the single-use contract on
/// all three forward types requires.
public actor TunnelRunner {
    /// Dials this profile's session. Takes the host-key decider so the same
    /// runner can be started from a window (a decider that may prompt) or by
    /// autostart (`.refusing`).
    ///
    /// Production passes a closure around `TunnelConnection.connect(session:
    /// secrets:knownHosts:decider:)`; the App layer holds the stores that
    /// call needs, so the runner takes the dial rather than the stores.
    public typealias Connect = @Sendable (HostKeyDecider) async throws -> any TunnelSSHConnection

    /// The backoff wait. Injected so a test measures what the runner ASKED
    /// for instead of waiting for it — CLAUDE.md, "A wall-clock ceiling in a
    /// test measures the runner". **Must be cancellable**: `stop()` cancels
    /// the run task, and a sleeper that ignores cancellation would hold the
    /// quit sequence for up to a minute.
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    public let profile: TunnelProfile

    private let connect: Connect
    private let runtimes: any TunnelRuntimeFactory
    private let sleeper: Sleeper

    /// The current state, as the plan last computed it. Read by the App for
    /// the sidebar glyph; the stream below is what it observes changes
    /// through.
    public private(set) var state: TunnelState = .stopped

    /// Every state the runner has published, in order.
    ///
    /// **Single consumer**, like every `AsyncStream`: Task 6's manager is
    /// that consumer, and it re-publishes to the UI. Buffered without bound
    /// (`AsyncStream.makeStream()`'s default), so a consumer that starts
    /// iterating after the runner has already moved misses nothing.
    ///
    /// `nonisolated` so a consumer can hold the stream without awaiting the
    /// actor, and never finished by the runner itself: a stopped tunnel can
    /// be started again, and a finished stream could not carry that.
    public nonisolated let states: AsyncStream<TunnelState>
    private let publish: AsyncStream<TunnelState>.Continuation

    private var task: Task<Void, Never>?
    private var connection: (any TunnelSSHConnection)?
    private var runtime: (any TunnelRuntime)?

    /// The port the running forward actually bound — a LOCAL port for
    /// `.local`/`.dynamic`, the SERVER's for `.remote`. `nil` whenever no
    /// forward is up, which includes the whole of a reconnect.
    ///
    /// The answer for a profile configured on port 0, and the number the
    /// `active port=…` line carries. Read rather than stored, so it cannot
    /// outlive the runtime it describes.
    public var boundPort: Int? { runtime?.boundPort }

    public init(
        profile: TunnelProfile,
        connect: @escaping Connect,
        runtimes: any TunnelRuntimeFactory = LiveTunnelRuntimeFactory(),
        sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.profile = profile
        self.connect = connect
        self.runtimes = runtimes
        self.sleeper = sleeper
        (states, publish) = AsyncStream.makeStream(of: TunnelState.self)
    }

    // MARK: - The two commands

    /// Starts the tunnel, if it is not already running.
    ///
    /// Returns as soon as the run task is scheduled — the connect, the bind
    /// and every retry happen inside it. A caller that wants to know when
    /// the tunnel is up reads `states`.
    public func start(decider: HostKeyDecider) {
        guard task == nil else { return }
        apply(.start)
        log(.info, "tunnel \(profile.name) start")
        task = Task { [weak self] in
            await self?.run(decider: decider)
        }
    }

    /// Stops the tunnel and returns once the connection and the forward are
    /// actually gone.
    ///
    /// Cancelling the run task is what ends a backoff sleep, a dial in
    /// flight, and `RemoteForward`'s own `cancel-tcpip-forward`. The
    /// teardown is repeated here rather than left to the cancelled task,
    /// because a task cancelled between two `await`s may return without
    /// reaching its own teardown — and a caller of `stop()` is entitled to
    /// a tunnel that is gone when the call returns.
    public func stop() async {
        let running = task
        task = nil
        running?.cancel()
        await running?.value
        await releaseCurrent()
        guard state != .stopped else { return }
        apply(.stop)
        log(.info, "tunnel \(profile.name) stop")
    }

    // MARK: - The run loop

    /// What one attempt produced.
    private enum AttemptOutcome {
        /// The connection (or the forward) is gone and the profile may want
        /// it back.
        case lost
        /// The run ends here, with the mapped reason.
        case failed(reason: String)
        /// A person has to connect this session once, by hand.
        case needsConfirmation(reason: String)
        /// `stop()` happened.
        case cancelled
    }

    private func run(decider: HostKeyDecider) async {
        var isRetry = false
        while !Task.isCancelled {
            let outcome = await attempt(decider: decider, isRetry: isRetry)
            await releaseCurrent()
            switch outcome {
            case .cancelled:
                return

            case .failed(let reason):
                apply(.failed(reason: reason))
                log(.info, "tunnel \(profile.name) failed \(reason)")
                return

            case .needsConfirmation(let reason):
                apply(.needsConfirmation)
                log(.info, "tunnel \(profile.name) needs confirmation \(reason)")
                return

            case .lost:
                apply(.connectionLost(reconnects: profile.reconnects))
                guard case .reconnecting(let attempt) = state else {
                    // The plan routed the loss to `failed` — the profile
                    // does not reconnect. Its own sentence, not one written
                    // here, so the state and the line cannot disagree.
                    if case .failed(let reason) = state {
                        log(.info, "tunnel \(profile.name) failed \(reason)")
                    }
                    return
                }
                log(.info, "tunnel \(profile.name) reconnecting attempt=\(attempt)")
                do {
                    try await sleeper(BackoffPlan.delay(attempt: attempt))
                } catch {
                    // The only thing that ends the sleep early is `stop()`
                    // cancelling the task. `stop()` publishes `.stopped`
                    // itself.
                    return
                }
                isRetry = true
            }
        }
    }

    /// One dial plus one forward, then a wait for whichever comes first: the
    /// connection dropping, the forward ending by itself, or cancellation.
    private func attempt(decider: HostKeyDecider, isRetry: Bool) async -> AttemptOutcome {
        // Created BEFORE the dial, so a connection that drops between the
        // handler's registration and the wait below cannot slip through the
        // gap: the yield is buffered and the wait returns at once.
        let (dropped, reportDrop) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))

        let opened: any TunnelSSHConnection
        do {
            opened = try await connect(decider)
        } catch {
            return outcome(for: error, isRetry: isRetry)
        }
        connection = opened
        opened.onDisconnect { reportDrop.yield(()) }
        apply(.connected)

        if Task.isCancelled { return .cancelled }

        let started: any TunnelRuntime
        do {
            started = try await runtimes.start(
                profile.kind, over: opened,
                observer: { [weak self] event in
                    Task { await self?.connectionEvent(event) }
                },
                onEnded: { reportDrop.yield(()) })
        } catch {
            return outcome(for: error, isRetry: isRetry)
        }
        runtime = started

        // A retry is announced as `retryDue` only now — see this type's own
        // doc comment for why that is not at the timer.
        if case .reconnecting = state { apply(.retryDue) }
        apply(.listening)
        let portText = started.boundPort.map(String.init) ?? "-"
        log(.info, "tunnel \(profile.name) active port=\(portText)")

        // Cancellation ends this iteration too: `AsyncStream`'s own
        // iteration answers it, which is why this is not a bare
        // continuation.
        for await _ in dropped { break }
        return Task.isCancelled ? .cancelled : .lost
    }

    /// What a dial or a forward-start failure means.
    ///
    /// Three answers, and the split is the architecture invariant plus one
    /// judgement:
    ///
    /// - An unknown host key the decider refused, or a session with no
    ///   stored secret, is `needsConfirmation` — resolvable only by
    ///   connecting that session once, by hand, in a window. A key MISMATCH
    ///   is NOT here: it is a hard stop and falls through to `failed`.
    /// - On a RETRY, anything else is treated as another loss, so the
    ///   backoff keeps climbing. The configuration demonstrably worked once
    ///   (the tunnel was active), so a refused dial or a port that is still
    ///   held is a condition to wait out, not a reason to give up on a
    ///   profile the user asked to reconnect.
    /// - On the FIRST attempt, anything else is `failed`, with the mapped
    ///   sentence. Nothing has worked yet, so there is nothing to recover,
    ///   and the user needs to read what went wrong rather than watch it be
    ///   retried forever.
    private func outcome(for error: any Error, isRetry: Bool) -> AttemptOutcome {
        let reason = DialSupport.reason(for: error)
        if Self.needsAPerson(error) { return .needsConfirmation(reason: reason) }
        if Task.isCancelled || error is CancellationError { return .cancelled }
        return isRetry ? .lost : .failed(reason: reason)
    }

    /// The two errors a person, not a retry, resolves.
    ///
    /// `HostKeyError.mismatch` is deliberately absent — TOFU's hard stop is
    /// never a prompt (`CLAUDE.md`, "Architecture invariants"), and
    /// `aHostKeyMismatchFailsAndIsNeverAConfirmation` is the negative that
    /// holds this arm to it.
    private static func needsAPerson(_ error: any Error) -> Bool {
        if case .rejectedByUser = error as? HostKeyError { return true }
        if case .secretRequired = error as? StoredSessionConnectionError { return true }
        return false
    }

    /// Releases whatever this attempt held: the forward first, then the
    /// connection carrying it. Idempotent — `stop()` and the run loop both
    /// call it, and the second call finds nothing.
    private func releaseCurrent() async {
        let held = runtime
        let dialled = connection
        runtime = nil
        connection = nil
        await held?.stop()
        await dialled?.disconnect()
    }

    // MARK: - Per-connection accounting

    /// One tunnelled connection opening or closing, from `BytePump`'s
    /// counters.
    ///
    /// The `debug` lines are per connection and carry the destination as the
    /// SSH SERVER reaches it. A `.dynamic` forward's destination is
    /// negotiated per connection and `TunnelConnectionEvent` does not carry
    /// it, so that kind logs `negotiated` rather than a host this code would
    /// have to invent.
    private func connectionEvent(_ event: TunnelConnectionEvent) {
        switch event {
        case .opened:
            apply(.connectionAccepted)
            log(.debug, "tunnel \(profile.name) connection opened to \(destinationText)")
        case .closed(let bytesIn, let bytesOut, let duration):
            apply(.connectionClosed)
            log(
                .debug,
                "tunnel \(profile.name) connection closed to \(destinationText) "
                    + "in=\(bytesIn) out=\(bytesOut) ms=\(milliseconds(duration))")
        }
    }

    /// Where this profile's connections go, as one printable field.
    /// `nonisolated` because `log`'s message is an `@autoclosure
    /// @Sendable` — the whole point of which is that a `.debug` line costs
    /// nothing when the level drops it — and a Sendable closure cannot reach
    /// actor-isolated state. It reads only `profile`, a `let` of a `Sendable`
    /// value, so there is nothing to isolate.
    private nonisolated var destinationText: String {
        switch profile.kind {
        case .local(_, _, let host, let remotePort): return "\(host):\(remotePort)"
        case .remote(_, _, let localHost, let localPort): return "\(localHost):\(localPort)"
        case .dynamic: return "negotiated"
        }
    }

    /// `nonisolated` for the same reason as `destinationText` above: pure
    /// arithmetic, read from inside the log autoclosure.
    private nonisolated func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }

    // MARK: - The plan, and the log

    /// Feeds one event through `TunnelStatePlan` and publishes the result —
    /// only when it actually CHANGED, so a no-op event (`connected`, which
    /// the plan documents as one) does not put a duplicate on the stream.
    private func apply(_ event: TunnelEvent) {
        let next = TunnelStatePlan.next(state, on: event)
        guard next != state else { return }
        state = next
        publish.yield(next)
    }

    /// The tunnel category's one writer.
    ///
    /// `DiagnosticLog.shared` directly, like `TunnelStore` and
    /// `CitadelFileSystem` — the house pattern, and what keeps
    /// `DiagnosticLogSecrecyGuardTests`' scan able to see these call sites at
    /// all (it matches the literal text `DiagnosticLog.shared.log(`). The
    /// tests that read these lines therefore live in
    /// `DiagnosticLogSharedSinkTests`, the one `.serialized` suite allowed to
    /// touch the process-wide sink.
    ///
    /// **No `reason=` is ever written here by hand**, which is why a failure
    /// line carries the plan's own mapped sentence as plain text instead: the
    /// mapping through `DialSupport.reason(for:)` has already happened in
    /// `outcome(for:isRetry:)`, and re-wrapping a `String` in an error just
    /// to reach the `reason:` overload would add a second spelling of the
    /// same sentence.
    private func log(_ level: DiagnosticLogLevel, _ message: @autoclosure @Sendable () -> String) {
        DiagnosticLog.shared.log(level, "tunnel", message())
    }
}
