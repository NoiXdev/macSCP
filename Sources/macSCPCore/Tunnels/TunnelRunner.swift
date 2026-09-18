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
/// `aFailedRetryKeepsClimbing` pins the climbing series — 2, 4, 8 across
/// one loss and the TWO consecutive failed retries that follow it (counted
/// 2026-09-06 against that test's own `failAttempts([2, 3])`: the 2 s is the
/// initial loss's own backoff, and only the 4 s and the 8 s are retries
/// failing); `aLossAfterAHealthyPeriodStartsTheBackoffOver`
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
    /// **Single consumer**, like every `AsyncStream`: in the app that is
    /// `TunnelManager`, which re-publishes to the UI, and in `macscp-cli
    /// tunnels start` it is the foreground loop that prints a line per
    /// state and exits on the first terminal one. One runner, one reader,
    /// either way. Buffered without bound
    /// (`AsyncStream.makeStream()`'s default), so a consumer that starts
    /// iterating after the runner has already moved misses nothing.
    ///
    /// `nonisolated` so a consumer can hold the stream without awaiting the
    /// actor, and never finished by the runner itself: a stopped tunnel can
    /// be started again, and a finished stream could not carry that.
    public nonisolated let states: AsyncStream<TunnelState>
    private let publish: AsyncStream<TunnelState>.Continuation

    private var task: Task<Void, Never>?
    /// The last command queued on this runner — the tail of the chain
    /// `command(_:)` builds. See that method: this one field is what makes
    /// `start` and `stop` take effect in the order they reached the actor.
    private var lastCommand: Task<Void, Never>?
    /// Identifies one run, so a run that ends by itself clears `task` only
    /// if `task` is still ITS task.
    private var runID = 0

    /// How many commands have ever been queued on this runner.
    ///
    /// `internal`, and the only member here that exists for the tests: the
    /// two race tests have to place a command ON the chain before releasing
    /// the one in front of it, and every other signal they could poll —
    /// "the task body began", "some yields have happened" — proves only that
    /// a Swift `Task` started running, not that it reached the actor and
    /// took its place in the chain. Round 2's tests used a 50× `Task.yield()`
    /// loop for that and the reviewer was right to call it no proof at all.
    /// Bumped in `command(_:)` in the same actor step that appends to the
    /// chain, so a test that sees this number sees a queued command.
    private(set) var queuedCommands = 0
    private var connection: (any TunnelSSHConnection)?
    private var runtime: (any TunnelRuntime)?
    /// The current attempt's per-connection report stream — see
    /// `attempt(decider:isRetry:)` for why the reports travel through one.
    /// Finished by `releaseCurrent()` once the forward is stopped.
    private var connectionReports: AsyncStream<ConnectionReport>.Continuation?
    /// The task reading `connectionReports`. `releaseCurrent()` awaits it
    /// after finishing the stream, so no report of an attempt that is over
    /// can reach the next one.
    private var connectionReportReader: Task<Void, Never>?

    /// How many report readers have started and not yet ended.
    ///
    /// `internal`, and for the tests, like `queuedCommands`: whether a
    /// stopped attempt's reader is really over is otherwise invisible until
    /// a stale report happens to land in the next attempt.
    private(set) var reportReaders = 0

    /// Set while `performStop()` runs: from its first statement until the
    /// attempt it stops has released everything. A report that reaches
    /// `connectionReport(_:)` inside that span is dropped — it describes a
    /// forward the user has just asked to be gone, and applying it would
    /// publish an `.active` between the stop and its `.stopped`. Cleared
    /// before `performStop()` returns, so the next attempt's reports count
    /// again.
    private var isStopping = false

    /// The port the current attempt's forward bound, captured when it
    /// started — the number its `active port=…` line carries.
    ///
    /// Separate from `boundPort` because it has to outlive the runtime:
    /// `releaseCurrent()` lets go of the runtime BEFORE it awaits the report
    /// reader, so a failure the reader delivers during that drain found no
    /// runtime to ask and logged `port=-`. This is cleared only once the
    /// reader has been awaited.
    private var startedPort: Int?

    /// The port the running forward actually bound — a LOCAL port for
    /// `.local`/`.dynamic`, the SERVER's for `.remote`. `nil` whenever no
    /// forward is up, which includes the whole of a reconnect.
    ///
    /// The answer for a profile configured on port 0. Read rather than
    /// stored, so it cannot outlive the runtime it describes — which is
    /// why the log lines read `startedPort` instead: they are written
    /// during `releaseCurrent()`'s drain too, after the runtime is gone.
    public var boundPort: Int? { runtime?.boundPort }

    /// The English sentence of the failure the state carries — the text the
    /// `tunnel … failed` log line wrote — or `nil` whenever the state is not
    /// `.failed`.
    ///
    /// Beside the state rather than in it: `TunnelState.failed` carries a
    /// `TunnelFailureKind`, which holds no foreign error's text, and the App
    /// translates that. The command line prints English and has no
    /// diagnostic log a user reads, so `macscp-cli tunnels start` takes this
    /// sentence instead — which keeps the detail a free-text
    /// `TunnelFailure` payload carries (a transport error's text, the
    /// server's own reason for refusing a remote bind) on its stderr, where
    /// the kind alone would have said "the forward could not start
    /// listening".
    public var failureReason: String? {
        guard case .failed = state else { return nil }
        return lastFailureReason
    }

    /// Written in the same actor step as the `.failed` state it describes.
    private var lastFailureReason: String?

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
    /// Returns once the command has taken effect — every command queued
    /// before it included. The connect, the bind and every retry then happen
    /// inside the run task; a caller that wants to know when the tunnel is up
    /// reads `states`.
    public func start(decider: HostKeyDecider) async {
        await command { runner in
            await runner.performStart(decider: decider)
        }
    }

    /// Stops the tunnel and returns once the connection and the forward are
    /// actually gone — and once every command queued before this one has
    /// taken effect.
    ///
    /// Cancelling the run task is what ends a backoff sleep, a dial in
    /// flight, and `RemoteForward`'s own `cancel-tcpip-forward`. The
    /// teardown is repeated in `performStop()` rather than left to the
    /// cancelled task, because a task cancelled between two `await`s may
    /// return without reaching its own teardown — and a caller of `stop()` is
    /// entitled to a tunnel that is gone when the call returns.
    public func stop() async {
        await command { runner in
            await runner.performStop()
        }
    }

    /// Runs `body` after every command already queued on this runner, and
    /// returns when it has run.
    ///
    /// **The commands are a chain, not a flag**, and two rounds of review
    /// were spent learning why. Both `start` and `stop` suspend in the
    /// middle — `stop` on the run task's own teardown, `start` on whatever
    /// stands before it — and each suspension leaves the actor free with the
    /// runner's fields in an intermediate shape. Anything that looks at
    /// those fields to decide whether it may proceed is reading a state
    /// nobody is in:
    ///
    /// - Round 1's CRITICAL: `stop()` cleared `task` and then suspended, so
    ///   a `start` landing there saw `task == nil` and began a second run
    ///   that the resuming `stop()` tore down — publishing `.stopped` over a
    ///   tunnel that was up, and leaving a live SSH connection behind.
    /// - Round 2's CRITICAL, the mirror: a `stop` that coalesced onto a stop
    ///   already in flight returned as soon as THAT one finished, without
    ///   noticing the `start` parked between them. The parked start then
    ///   dialled, so the tunnel was up after the caller's last command was
    ///   stop.
    ///
    /// A chain has no such window because it does not ask a question at all.
    /// Each command captures the current tail, appends itself, and runs only
    /// once its predecessor is over — so commands take effect in the order
    /// they reached the actor, and the last one really is the last word. Two
    /// stops in a row still cost nothing: `performStop()` on an already
    /// stopped runner finds no task, releases nothing and publishes nothing.
    ///
    /// `lastCommand` is cleared only by the command that is still the tail
    /// when it finishes, so a chain that has grown behind this one is left
    /// intact.
    private func command(_ body: @escaping @Sendable (TunnelRunner) async -> Void) async {
        let previous = lastCommand
        let mine = Task<Void, Never> { [weak self] in
            await previous?.value
            guard let self else { return }
            await body(self)
        }
        lastCommand = mine
        queuedCommands += 1
        await mine.value
        if lastCommand == mine { lastCommand = nil }
    }

    /// The start itself, run from the command chain.
    ///
    /// A start that finds a run already going is a no-op — the tunnel the
    /// caller asked for is the tunnel that is running.
    private func performStart(decider: HostKeyDecider) async {
        guard task == nil else { return }
        runID += 1
        let id = runID
        apply(.start)
        log(.info, "tunnel \(profile.name) start")
        task = Task { [weak self] in
            await self?.run(decider: decider, id: id)
        }
    }

    /// The stop itself, run from the command chain.
    ///
    /// **`await running?.value` is not itself cancellable**, and that is the
    /// shape `RemoteForward.stop()`'s own doc comment warns about:
    /// `Task<Void, Never>.value` ignores the awaiting task's cancellation,
    /// so this returns only when the run task actually ends. What makes it
    /// safe is that every `await` the run task can be parked on is bounded
    /// or answers cancellation — the `AsyncStream` iteration it waits for a
    /// drop on, the injected `Sleeper` (whose contract says so), the dial
    /// (bounded by the connect timeout), the runtime start (`RemoteForward
    /// .start` bounds the server's answer, a bind does not wait), and
    /// `releaseCurrent()` (bounded per forward by `BoundedClose`). It is
    /// NOT bounded with a `BoundedClose` of its own on purpose: abandoning
    /// the run task here would leave a task that can still enter this actor
    /// and publish a state after `.stopped`, which is a worse failure than
    /// waiting. Measured 2026-09-06 by planting the removal of the
    /// `cancel()` below — the suite then hung rather than going red, which
    /// is exactly what this paragraph describes.
    ///
    /// Idempotent: on a runner that is already stopped there is no task to
    /// cancel, nothing to release and nothing to publish. That is what lets
    /// `command(_:)` queue a second stop unconditionally instead of asking
    /// whether one is needed.
    private func performStop() async {
        isStopping = true
        defer { isStopping = false }
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
        /// The run ends here. The ERROR travels, not its mapped text: the
        /// state needs `DialSupport.failureKind(for:)`'s kind and the log
        /// line needs the error itself, because `DiagnosticLog
        /// .log(_:_:_:reason:)` is the only sanctioned way to write a
        /// `reason=` key and it takes an `Error`.
        case failed(error: any Error)
        /// A person has to connect this session once, by hand. Carries the
        /// error for the same reason.
        case needsConfirmation(error: any Error)
        /// `stop()` happened.
        case cancelled
    }

    private func run(decider: HostKeyDecider, id: Int) async {
        defer { runEnded(id) }
        var isRetry = false
        while !Task.isCancelled {
            let outcome = await attempt(decider: decider, isRetry: isRetry)
            await releaseCurrent()
            switch outcome {
            case .cancelled:
                return

            case .failed(let error):
                lastFailureReason = DialSupport.reason(for: error)
                apply(.failed(DialSupport.failureKind(for: error)))
                log(.info, "tunnel \(profile.name) failed", reason: error)
                return

            case .needsConfirmation(let error):
                apply(.needsConfirmation)
                log(.info, "tunnel \(profile.name) needs confirmation", reason: error)
                return

            case .lost:
                apply(.connectionLost(reconnects: profile.reconnects))
                guard case .reconnecting(let attempt) = state else {
                    // The plan routed the loss to `failed` — the profile
                    // does not reconnect. The kind's own sentence, not one
                    // written here, so the state and the line cannot
                    // disagree.
                    if case .failed(let kind) = state {
                        lastFailureReason = kind.sentence
                        log(.info, "tunnel \(profile.name) failed \(kind.sentence)")
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

    /// Clears `task` when a run ends BY ITSELF — a terminal `.failed`, a
    /// terminal `.needsConfirmation`, or a loss on a profile that does not
    /// reconnect.
    ///
    /// Without it `task` stayed set forever after a terminal state and
    /// `start(decider:)` was a silent no-op: no state, no log line, no dial
    /// (fix round 1, IMPORTANT). That made this task's whole
    /// `.needsConfirmation` story — connect the session once by hand, then
    /// start the tunnel again — unreachable unless the caller happened to
    /// call `stop()` first.
    ///
    /// The identity check is what keeps it from clobbering a LATER run's
    /// task. It cannot fire today — commands run one after another on
    /// `command(_:)`'s chain, so a second run cannot begin while a first one
    /// is still going — and it is kept because that is an invariant of the
    /// chain, not of this method.
    private func runEnded(_ id: Int) {
        guard id == runID else { return }
        task = nil
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

        // One stream and one reader for every per-connection report, rather
        // than a `Task` per report: separate tasks reach the actor in no
        // guaranteed order, and the failure count depends on order — an
        // `opened` resets it, so a failure reported just after an `opened`
        // (a SOCKS5 hand-over whose own handler removal failed once the pump
        // was in) would be erased if the `opened` overtook it. A stream's
        // `yield`s are delivered in the order they were made.
        let (reports, report) = AsyncStream.makeStream(of: ConnectionReport.self)
        connectionReports = report
        reportReaders += 1
        connectionReportReader = Task { [weak self] in
            for await next in reports {
                await self?.connectionReport(next)
            }
            await self?.reportReaderEnded()
        }

        let started: any TunnelRuntime
        do {
            started = try await runtimes.start(
                profile.kind, over: opened,
                observer: { event in report.yield(.event(event)) },
                onConnectionFailure: { failure in report.yield(.failed(failure)) },
                onEnded: { reportDrop.yield(()) })
        } catch {
            return outcome(for: error, isRetry: isRetry)
        }
        runtime = started
        startedPort = started.boundPort

        // A retry is announced as `retryDue` only now — see this type's own
        // doc comment for why that is not at the timer.
        if case .reconnecting = state { apply(.retryDue) }
        apply(.listening)
        let portText = startedPort.map(String.init) ?? "-"
        log(.info, "tunnel \(profile.name) active port=\(portText)")

        // Cancellation ends this iteration too: `AsyncStream`'s own
        // iteration answers it, which is why this is not a bare
        // continuation.
        for await _ in dropped { break }
        return Task.isCancelled ? .cancelled : .lost
    }

    /// What a dial or a forward-start failure means.
    ///
    /// Four answers, and the split is the architecture invariant plus one
    /// judgement:
    ///
    /// - **Cancellation is read FIRST**, before anything else is
    ///   classified. `stop()` cancels the run task, and a dial that was in
    ///   flight then fails with whatever its own path produces — for a
    ///   `.refusing` decider that is `HostKeyError.rejectedByUser`, which
    ///   used to be classified before the cancellation and published
    ///   `.needsConfirmation` plus a `needs confirmation` line on the way
    ///   out of a stop the user had just asked for (fix round 1,
    ///   IMPORTANT). Nothing a cancelled attempt reports is news about the
    ///   tunnel.
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
        if Task.isCancelled || error is CancellationError { return .cancelled }
        if Self.needsAPerson(error) { return .needsConfirmation(error: error) }
        return isRetry ? .lost : .failed(error: error)
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
    ///
    /// The report stream is finished only after the forward has stopped, so
    /// the `closed` reports its teardown produces still reach the log — on
    /// a LOSS. Under `stop()` they do not: every report arriving once the
    /// stop has begun is dropped (`isStopping`, next build of 2026-09-17,
    /// Task 2), buffered ones included.
    ///
    /// **And its reader is awaited.** Finishing a stream does not discard
    /// what is buffered: the reader goes on delivering it. Without the wait
    /// a stopped attempt's reports kept arriving after the next attempt was
    /// `active` — measured in review of `b9ee7d22`: 20,000 failures, stop,
    /// start, and the new `active` read `failedConnections: 26`
    /// (`reportsFromAStoppedAttemptDoNotReachTheNext`). The wait is bounded:
    /// the stream is finished, so the reader ends once the buffer is empty,
    /// and the actor is re-entrant, so the reader's own hops onto it are not
    /// blocked by this suspension. Under a loss, whatever it delivers lands
    /// before the caller's next state (`reconnecting`); under a stop it
    /// delivers into `connectionReport(_:)`'s drop, so nothing lands between
    /// the stop and its `.stopped`
    /// (`reportsBufferedWhileStoppingAreDroppedNotPublished`). A failure
    /// delivered under a loss is logged and not counted: `connection` is
    /// already `nil`, so the attempt is no longer live
    /// (`connectionFailed(_:)`), and the `.reconnecting` that follows is
    /// what describes it.
    ///
    /// `startedPort` is cleared LAST, after the reader has been awaited, so
    /// a failure drained here still logs the port its forward had.
    private func releaseCurrent() async {
        let held = runtime
        let dialled = connection
        let reports = connectionReports
        let reader = connectionReportReader
        runtime = nil
        connection = nil
        connectionReports = nil
        connectionReportReader = nil
        await held?.stop()
        reports?.finish()
        await reader?.value
        startedPort = nil
        await dialled?.disconnect()
    }

    // MARK: - Per-connection accounting

    /// What a running forward reports about one of its connections.
    private enum ConnectionReport: Sendable {
        /// `BytePump`'s counters: a pair opened, or closed.
        case event(TunnelConnectionEvent)
        /// A connection the forward could not carry — the listeners'
        /// `onFailure`, the remote forward's `onConnectionFailure`.
        case failed(TunnelFailure)
    }

    private func reportReaderEnded() {
        reportReaders -= 1
    }

    /// Applies one report — unless a stop has begun, in which case the
    /// report is dropped (see `isStopping`). The reader still consumes it,
    /// so the buffer still empties and `releaseCurrent()`'s wait on the
    /// reader still ends; it only publishes nothing and logs nothing.
    private func connectionReport(_ report: ConnectionReport) {
        guard !isStopping else { return }
        switch report {
        case .event(let event): connectionEvent(event)
        case .failed(let failure): connectionFailed(failure)
        }
    }

    /// One connection the forward could not carry: counted in the state
    /// while the attempt is live, the tunnel left up, one `debug` line
    /// either way.
    ///
    /// **Counted only while the attempt is live** — its connection still
    /// held and still up (`attemptIsLive`). A connection that fails because
    /// the SSH connection dropped under it is the LOSS's failure, not the
    /// forward's, and counting it published "1 connection failed" just
    /// before the `.reconnecting` the drop produced. The runner cannot tell
    /// the two apart by order: the failure travels on the report stream,
    /// the drop on its own signal (Citadel fires it from a `Task` of its
    /// own), and either can arrive first. What it CAN know is whether the
    /// connection is still up when the failure arrives — and a real drop
    /// answers `false` before any failure it causes exists
    /// (`TunnelSSHConnection.isConnected`). A genuine failure that happens
    /// to be read after a drop is not counted either; the reconnect would
    /// have cleared it a moment later. No new state: the count simply does
    /// not move.
    ///
    /// The line carries the kind's own English sentence and the port the
    /// forward bound when it started (`startedPort`, which outlives the
    /// runtime through `releaseCurrent()`'s drain), and nothing the
    /// failure's `reason:` payload holds — that text can be a foreign
    /// error's, and nothing about the client that connected is in it
    /// either. A SOCKS5 client that never named a destination, or was gone
    /// before its reply reached it, never gets here: `LocalForwardListener`
    /// does not report it, because that is the client's failure, not the
    /// tunnel's.
    private func connectionFailed(_ failure: TunnelFailure) {
        let kind = TunnelFailureKind(failure)
        if attemptIsLive { apply(.connectionFailed(kind)) }
        let portText = startedPort.map(String.init) ?? "-"
        log(.debug, "tunnel \(profile.name) connection failed port=\(portText) \(kind.sentence)")
    }

    /// Whether the current attempt can still be carrying connections: its
    /// connection is still held — `releaseCurrent()` has not begun — and
    /// still reports itself up.
    private var attemptIsLive: Bool {
        guard let connection else { return false }
        return connection.isConnected
    }

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
    /// `CitadelFileSystem` — the house pattern. The tests that read these
    /// lines therefore live in `DiagnosticLogSharedSinkTests`, the one
    /// `.serialized` suite allowed to touch the process-wide sink.
    ///
    /// **This wrapper used to hide every tunnel line from the secrecy
    /// guard**, and this comment used to claim the opposite. The guard
    /// matches the literal text `DiagnosticLog.shared.log(` and reads the
    /// `\(…)` inside that call's arguments; routed through here, the only
    /// arguments it ever saw were `level, "tunnel", message()` — no
    /// interpolation at all — so its negative check passed for the whole
    /// category by finding nothing to look at, exactly the way CLAUDE.md's
    /// "only a NEGATIVE check can go stale in silence" describes. Found in
    /// review, 2026-09-06. `DiagnosticLogSecrecyGuardTests` now also walks a
    /// file's own wrapper (structurally: any function whose body contains
    /// the marker) and scans ITS call sites, with a positive beside the
    /// negative asserting that the `tunnel` category contributes more than
    /// zero scanned interpolations. So a wrapper is safe to keep — but it is
    /// safe because the guard was taught about it, not because of anything
    /// this file does.
    ///
    /// **No `reason=` is ever written here by hand.** Where an error is in
    /// hand — a failed dial, a failed forward start, a refused host key — the
    /// `reason:` overload below writes the key, and it runs
    /// `DialSupport.reason(for:)` itself.
    ///
    /// TWO lines carry no `reason=`. The loss of a connection on a profile
    /// that does not reconnect cannot: there is no error there — a
    /// disconnect signal carries none — and the sentence is the
    /// `.connectionLost` kind's own, taken from the state the plan just
    /// computed so that the line and the state cannot disagree.
    /// Inventing an error to wrap it would put a second spelling of that
    /// sentence in this file; recorded as a limit instead (Task 5 report,
    /// round 1). A connection the forward could not carry
    /// (`connectionFailed(_:)`) does have an error, and deliberately does
    /// not pass it: its `reason:` payload can be a foreign error's text, so
    /// the line writes the kind's own sentence, the same value the state
    /// carries.
    private func log(_ level: DiagnosticLogLevel, _ message: @autoclosure @Sendable () -> String) {
        DiagnosticLog.shared.log(level, "tunnel", message())
    }

    /// The same, with the error appended as `reason=<mapped sentence>`.
    ///
    /// `DiagnosticLog.log(_:_:_:reason:)` is the ONLY sanctioned way that
    /// key is written: it runs `DialSupport.reason(for:)` itself, so no call
    /// site can format an unaudited one. The line's state counterpart runs
    /// `DialSupport.failureKind(for:)` — the same switch — on the same error,
    /// which is what keeps `TunnelState.failed` and the log line from ever
    /// describing two different failures.
    private func log(
        _ level: DiagnosticLogLevel, _ message: @autoclosure @Sendable () -> String,
        reason error: any Error
    ) {
        DiagnosticLog.shared.log(level, "tunnel", message(), reason: error)
    }
}
