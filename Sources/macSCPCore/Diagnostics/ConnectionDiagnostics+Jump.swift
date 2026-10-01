import Foundation

// The target half of a walk through a jump host, and the two small classes
// that carry the jump's connection between the walk and its dial. Split out of
// `ConnectionDiagnostics.swift` on 2026-10-01 with its text unchanged; the
// universal steps the jump half also runs went to
// `ConnectionDiagnostics+UniversalSteps.swift` in the same commit.

extension ConnectionDiagnostics {
    // MARK: - Through a jump host

    /// The steps measured THROUGH the jump connection, in the order they run
    /// once the jump has been reached — the target half of a jump walk.
    ///
    /// Adding one is an entry in this list, and a requirement on
    /// `DiagnosticJumpConnection` if it needs one. Its phase decides which
    /// scope runs it, its budget which deadline it races (`bounded(_:_:_:)`),
    /// and the jump connection is opened whenever any entry in scope needs it
    /// (`needsJumpConnection(_:)`).
    ///
    /// The channel first, then the jump host's own resolve and ping of the
    /// target (`JumpProbes.swift`), then the dial through the jump, then the
    /// trace from the jump host — the slowest and least likely to change a
    /// verdict, last, as the direct walk orders its own trace.
    static let targetHalf: [DiagnosticJumpStep] = [
        .tcpViaJump, .resolveOnJump, .icmpFromJump, .dialViaJump, .traceFromJump,
    ]

    /// Whether `scope` runs a step that needs the jump connection open: the
    /// jump's own dial, or any step of the target half.
    ///
    /// So `.ping` opens it too — `target.tcpViaJump` is how "is anything
    /// there" is asked of a target behind a bastion, and a channel needs an
    /// authenticated connection to be opened on. The `jump.dial` row then
    /// says the connection was made, rather than a ping opening one nobody
    /// sees. And `.trace` opens it as well: `target.traceFromJump` runs its
    /// command on the jump host over it, so a trace-only walk now dials the
    /// jump host and reads its secret, where until 2026-09-18 it measured the
    /// jump's trace from this Mac and opened nothing.
    static func needsJumpConnection(_ scope: DiagnosticScope) -> Bool {
        scope.runs(.dial) || targetHalf.contains { scope.runs($0.phase) }
    }

    /// The walk of a session behind a jump host, and the one place its jump
    /// connection is closed.
    ///
    /// Every way out of `walkThroughJump` — the natural end, each
    /// cancellation, a jump that was never reached — comes back here, and the
    /// connection is closed before the report is handed back: a diagnosis
    /// that left a login open on the bastion would be the one probe that
    /// changes what it measures.
    func runThroughJump(
        _ jump: DiagnosticJump, to endpoint: Endpoint, scope: DiagnosticScope,
        observer: DiagnosticRunObserver
    ) async -> DiagnosticReport {
        let held = HeldJumpConnection()
        let report = await walkThroughJump(
            jump, to: endpoint, scope: scope, observer: observer, holding: held)
        await held.release()?.disconnect()
        return report
    }

    /// The jump first, from this Mac — its resolve, TCP ping, echo, dial and
    /// trace — then the target through it (`targetHalf`), then the backend's
    /// contributions.
    ///
    /// **When the target half is skipped.** If any jump step up to and
    /// including its dial FAILED, or the dial opened no connection (it was
    /// skipped for a missing secret, timed out, never started, or was never
    /// asked for), every target step in scope is `skipped` naming the jump
    /// (`DiagnosticReason.jumpNotReached`). `failed` only: an echo that heard
    /// nothing is `timedOut`, and a firewall that drops ICMP says nothing
    /// about whether the bastion forwards. The jump's trace runs after its
    /// dial and before the target half, and does not count — it is measured
    /// from this Mac, and a router that refuses a probe is not a bastion that
    /// refuses a login.
    ///
    /// **Where `notStarted` falls, stated rather than left to the reader**
    /// (added with the case, 2026-09-27). It is NOT `failed`, for the reason
    /// `timedOut` is not: a probe this Mac never gave a thread has said
    /// nothing at all about the bastion, and it says even less than a probe
    /// that ran and overran. So a `notStarted` jump.resolve, jump.tcp or
    /// jump.icmp leaves `reached` alone. A `notStarted` jump.DIAL still skips
    /// the target half — not through the outcome but through
    /// `held.connection`, which is nil because no dial happened. Both halves
    /// of that fall out of the rule below unchanged; what changed is that
    /// there is now a sixth outcome for it to be read against, and this is
    /// where that reading is written down.
    private func walkThroughJump(
        _ jump: DiagnosticJump, to endpoint: Endpoint, scope: DiagnosticScope,
        observer: DiagnosticRunObserver, holding held: HeldJumpConnection
    ) async -> DiagnosticReport {
        var walk = Walk(
            endpoint: endpoint, jump: jump.endpoint, appVersion: appVersion, scope: scope,
            observer: observer)

        guard let jumpEndpoint = jump.endpoint else {
            // The `noHost` row's counterpart, and unannounced for the same
            // reason: nothing is measured, so no start is captioned. The
            // target half still reports itself, so the reader sees the
            // target was not measured rather than finding its rows missing.
            let step = Self.timer(for: DiagnosticStepID.jumpResolve)
                .finish(.unavailable(DiagnosticReason.jumpUnresolvable), "")
            await walk.append(step)
            return await skippingTargetHalf(scope, observer, into: &walk)
        }

        guard !Task.isCancelled else { return walk.cancelled() }
        let (resolveStep, addresses) = await resolve(
            jumpEndpoint, as: DiagnosticStepID.jumpResolve, observer)
        guard !Task.isCancelled else { return walk.cancelled() }
        await walk.append(resolveStep)

        if scope.runs(.tcp) {
            guard !Task.isCancelled else { return walk.cancelled() }
            let step = await ping(
                addresses, port: jumpEndpoint.port, as: DiagnosticStepID.jumpTCP, observer)
            guard !Task.isCancelled else { return walk.cancelled() }
            await walk.append(step)
        }

        if scope.runs(.icmp) {
            guard !Task.isCancelled else { return walk.cancelled() }
            let step = await echo(addresses, as: DiagnosticStepID.jumpICMP, observer)
            guard !Task.isCancelled else { return walk.cancelled() }
            await walk.append(step)
        }

        if Self.needsJumpConnection(scope) {
            guard !Task.isCancelled else { return walk.cancelled() }
            let step = await dialJump(jump, observer, holding: held)
            guard !Task.isCancelled else { return walk.cancelled() }
            await walk.append(step)
        }
        let reached =
            held.connection != nil
            && !walk.steps.contains { step in
                if case .failed = step.outcome { return true } else { return false }
            }

        if scope.runs(.trace) {
            guard !Task.isCancelled else { return walk.cancelled() }
            let step = await trace(addresses, as: DiagnosticStepID.jumpTrace, observer)
            guard !Task.isCancelled else { return walk.cancelled() }
            await walk.append(step)
        }

        guard reached, let connection = held.connection else {
            return await skippingTargetHalf(scope, observer, into: &walk)
        }
        let context = DiagnosticJumpStep.Context(
            connection: connection, jump: jump, target: endpoint, values: values,
            diagnostic: DiagnosticContext(
                secrets: secrets, sessionID: sessionID, timeout: stepTimeout),
            dialer: jumpDialer, budget: stepTimeout, transcript: JumpProbeTranscript())
        for step in Self.targetHalf where scope.runs(step.phase) {
            guard !Task.isCancelled else { return walk.cancelled() }
            let row = await bounded(step, context, observer)
            guard !Task.isCancelled else { return walk.cancelled() }
            await walk.append(row)
        }
        return await contributions(scope, observer, into: &walk)
    }

    /// Every target step in scope as `skipped`, naming the jump, then the
    /// contributions. Each skipped row announces itself first, the way a ping
    /// with no address to probe does: the step was asked for, and the row
    /// says why it could not be measured.
    private func skippingTargetHalf(
        _ scope: DiagnosticScope, _ observer: DiagnosticRunObserver, into walk: inout Walk
    ) async -> DiagnosticReport {
        for step in Self.targetHalf where scope.runs(step.phase) {
            guard !Task.isCancelled else { return walk.cancelled() }
            let timer = await Self.starting(step.id, announcedTo: observer)
            await walk.append(timer.finish(.skipped(DiagnosticReason.jumpNotReached), ""))
        }
        return await contributions(scope, observer, into: &walk)
    }

    /// `jump.dial`: the jump's transport, host key and login, and the
    /// connection it opens handed to `held` for the target half.
    ///
    /// Raced against the step budget by `DetachedProbe`, like every dial
    /// here — so a budget that expires before the pool starts the dial reads
    /// `notStarted` rather than `timedOut`, and the target half is skipped
    /// either way, because no connection was opened. Unlike the other dials
    /// it has to deal with a connection that arrives AFTER the deadline: the
    /// probe is abandoned, not stopped, and a transport that finishes its
    /// connect anyway would leave a login open on the bastion with nobody
    /// holding it. `JumpHandoff` is the one place the
    /// connection changes hands; whichever side comes second closes it.
    private func dialJump(
        _ jump: DiagnosticJump, _ observer: DiagnosticRunObserver,
        holding held: HeldJumpConnection
    ) async -> DiagnosticStep {
        let timer = await Self.starting(DiagnosticStepID.jumpDial, announcedTo: observer)
        let secret: String
        switch DialSupport.dialSecret(
            usesAgent: jump.login.authKind == .agent, missing: jump.missingSecretReason,
            jump.secret)
        {
        case .secret(let resolved): secret = resolved
        case .unanswered(let outcome): return timer.finish(outcome, "")
        }
        let config: SSHConnectionConfig
        do {
            config = try jump.jumpConfig(secret: secret)
        } catch {
            return timer.finish(.failed(DialSupport.reason(for: error)), "")
        }
        let handoff = JumpHandoff()
        let dialer = jumpDialer
        let seconds = DialSupport.connectSeconds(stepTimeout)
        let answer = await DetachedProbe.run(timeout: stepTimeout, launch: jumpDialLaunch) {
            do {
                let connection = try await dialer.connectJump(config, seconds)
                guard handoff.offer(connection) else {
                    await connection.disconnect()
                    return timer.finish(.timedOut, "")
                }
                return timer.finish(.ok, "transport, host key and authentication")
            } catch {
                return timer.finish(.failed(DialSupport.reason(for: error)), "")
            }
        }
        // Closes the handoff: an offer after this line is refused, and the
        // probe closes what it brought.
        let connection = handoff.take()
        let step: DiagnosticStep
        switch answer {
        case .answered(let finished): step = finished
        case .unanswered(let start): step = timer.finish(Self.outcome(forUnanswered: start), "")
        }
        guard step.outcome == .ok, let connection else {
            // A connection that won the race by a hair while its row did not
            // — the deadline or a cancellation landed between the offer and
            // the answer — is not one the walk may use.
            await connection?.disconnect()
            return step
        }
        held.connection = connection
        return step
    }

    /// Runs one step of the target half, held from outside to the budget the
    /// step names (`DiagnosticJumpStep.budget`) exactly as `bounded(_:_:)`
    /// holds a contribution to the step budget: the step budget for one
    /// probe, the trace budget for `target.traceFromJump`.
    private func bounded(
        _ step: DiagnosticJumpStep, _ context: DiagnosticJumpStep.Context,
        _ observer: DiagnosticRunObserver
    ) async -> DiagnosticStep {
        let timer = await Self.starting(step.id, announcedTo: observer)
        let budget = step.budget.duration(step: stepTimeout, trace: traceTimeout)
        return await Self.race(step, context.forStep(budget: budget), timer: timer)
    }

    /// One target-half step against its budget (`context.budget`): its own
    /// row when it finishes in time, otherwise what its `cut` makes of the
    /// output it had collected — a trace cut short still reports the hops it
    /// measured — or a plain `timedOut` for a step with nothing to salvage,
    /// or `notStarted` for a probe this Mac never began.
    ///
    /// Static, and handed the context rather than building it, so the suite
    /// can race a step against a transcript it filled itself: the cut is
    /// then read from known output whether or not the abandoned probe ever
    /// got a thread (`aStepCutByItsBudgetReportsWhatItHadCollected`).
    /// `launch` is the same seam one layer down — production's
    /// `Task.detached` by default, and a launcher that HOLDS the body when
    /// the suite needs a probe that never began.
    static func race(
        _ step: DiagnosticJumpStep, _ context: DiagnosticJumpStep.Context,
        timer: DiagnosticStepTimer, launch: DetachedProbe.Launch = DetachedProbe.detach
    ) async -> DiagnosticStep {
        let answer = await DetachedProbe.run(timeout: context.budget, launch: launch) {
            await step.measure(context, timer)
        }
        switch answer {
        case .answered(let finished): return finished
        case .unanswered(let start):
            // The `cut` reads what the probe COLLECTED, so it is offered
            // only to a probe that collected something. A body the pool
            // never started opened no channel and ran no command; both cuts
            // answer `timedOut` over an empty transcript (their own first
            // `guard`), which is a sentence about the far end for a
            // measurement that never left this Mac. The condition is the
            // transcript and not `start`, because a probe that DID begin and
            // was cut before its first byte is a timeout too, and reads as
            // one through the line below.
            //
            // **This reads `current` as "THIS step collected something", and
            // that holds on ONE invariant kept elsewhere**: every step is
            // raced against a transcript of its own, because
            // `bounded(_:_:_:)` hands this function a
            // `context.forStep(budget:)` and `forStep` builds a fresh
            // `JumpProbeTranscript`. `JumpProbeTranscript.begin(_:)` sets
            // `tool` and never clears it, so a transcript SHARED across the
            // target half would be permanently non-nil from the first remote
            // command on, and a later step the pool never started would be
            // handed a cut over a stale tool — `timedOut` again, in the
            // commonest loaded-machine path. The invariant was incidental
            // until 2026-09-27 (the cut was offered unconditionally) and is
            // load-bearing now, so it is pinned by a test at the level where
            // it decides a row:
            // `anEarlierStepsOutputDoesNotTurnALaterNeverStartedStepIntoATimeout`,
            // measured red against a `forStep` that reuses the transcript.
            if let cut = step.cut, context.transcript.current != nil {
                return cut(context, timer)
            }
            return timer.finish(Self.outcome(forUnanswered: start), "")
        }
    }

    /// The outcome a step reports when its probe did not answer: the
    /// deadline's own `timedOut` for a body that ran and overran, and
    /// `notStarted` for one this Mac never gave a thread.
    ///
    /// Spelled ONCE, and read from three places (counted 2026-09-27:
    /// `dialJump`, `race` above, and `bounded(_:_:)` for a contribution), so
    /// the three cannot come to disagree about what a probe that never began
    /// says to a reader.
    static func outcome(forUnanswered start: ProbeStart) -> DiagnosticOutcome {
        switch start {
        case .began: return .timedOut
        case .neverBegan: return .notStarted(DiagnosticReason.probeNotStarted)
        }
    }
}

/// The jump connection a walk holds open for its target half — set by
/// `jump.dial`, closed by `runThroughJump` on every way out.
///
/// A class, so the walk and its dial share one without threading an `inout`
/// through every return site. It never leaves the actor: it is made, filled
/// and emptied inside one `run`, and has no `async` member that would carry
/// it off the actor to be awaited — the connection is taken out first, and
/// the connection is what gets awaited.
private final class HeldJumpConnection {
    var connection: (any DiagnosticJumpConnection)?

    /// The connection, and nothing held after this.
    func release() -> (any DiagnosticJumpConnection)? {
        defer { connection = nil }
        return connection
    }
}

/// Where the jump's dial hands its connection over, and where a late one is
/// turned away.
///
/// The probe OFFERS what it connected; the walk TAKES once the race is over.
/// Whichever comes second decides: an offer after the take is refused, and
/// the probe closes the connection itself — the walk has moved on and will
/// never close it.
private final class JumpHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var offered: (any DiagnosticJumpConnection)?
    private var isTaken = false

    /// `false` when the walk already took — the caller must close
    /// `connection` itself.
    func offer(_ connection: any DiagnosticJumpConnection) -> Bool {
        lock.withLock {
            guard !isTaken else { return false }
            offered = connection
            return true
        }
    }

    /// Whatever was offered so far, and no more offers after this.
    func take() -> (any DiagnosticJumpConnection)? {
        lock.withLock {
            isTaken = true
            defer { offered = nil }
            return offered
        }
    }
}
