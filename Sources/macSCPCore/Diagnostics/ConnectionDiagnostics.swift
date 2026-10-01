import Foundation

/// Told when a step STARTS as well as when it finishes.
///
/// Two halves rather than one callback with a state, because the two say
/// different things: a start names a step nothing has measured yet, and a
/// finish hands over a row. The panel draws the second and captions the
/// first, and a single event carrying both would make "which step is this
/// twenty seconds going into" a question about the last row rather than
/// about the walk.
///
/// A start carries the step's id and the catalogue key it will carry as a
/// row — the step's OWN key, never a second spelling of its name: whatever
/// the running line ends up saying, it says it under the key the finished row
/// will be titled with.
///
/// `onStepStarted` defaults to a no-op, so a caller that only wants the rows
/// writes what it always wrote (`run(scope:onStep:)`, the CLI's spelling).
public struct DiagnosticRunObserver: Sendable {
    /// A step is about to be measured, under this id and this catalogue key.
    /// `async` for the reason `DiagnosticStepObserver` is: the one real
    /// implementation is a `@MainActor` view model, and awaiting it means the
    /// walk cannot outrun the renderer.
    public var onStepStarted: @Sendable (_ id: String, _ titleKey: String) async -> Void
    /// A step has finished, and this is its row.
    public var onStep: DiagnosticStepObserver

    public init(
        onStepStarted: @escaping @Sendable (_ id: String, _ titleKey: String) async -> Void = {
            _, _ in
        },
        onStep: @escaping DiagnosticStepObserver = { _ in }
    ) {
        self.onStepStarted = onStepStarted
        self.onStep = onStep
    }
}

/// The universal half of the connection diagnosis, plus the seam the
/// protocols fill (design §§2–3).
///
/// Runs, in order and each under its own deadline: name resolution, one TCP
/// connection attempt per resolved address, an ICMP echo per resolved
/// address, the backend's own dial, an IPv4 network trace, and then whatever
/// the backend contributes — or the subset of those a `DiagnosticScope`
/// names, which is what a caller who wants one probe and not the whole walk
/// passes to `run(scope:observer:)`. The throughput test runs only under its
/// own scope, and is the one step not held to a deadline from outside
/// (`throughput(_:)` says why). A session behind a jump host is walked
/// through it instead — the jump first, then the target as the jump reaches
/// it (`DiagnosticJump`, `targetHalf`). Nothing here asks which protocol it is
/// looking at — the endpoint, the dial and the contributions all arrive through
/// `BackendDescriptor`, which is what keeps a fourth backend from having to
/// be mentioned in this file at all.
///
/// Every universal step — the resolve, the ping, the echo and the trace —
/// touches no credential. The dial and the contributions
/// may, and only through the source the connect path itself uses
/// (`DiagnosticContext.secret()`); no step ever writes one into a detail line
/// — pinned by `theSSHDialNeverPutsTheSecretInTheReport`.
///
/// Cancellable through the calling task: `run()` returns the report with the
/// steps that finished before the cancellation, and never a half-measured
/// row. That report says it was cancelled and after how many steps
/// (`DiagnosticReport.Completion`) — a partial measurement that presents
/// itself as a whole one is what makes a pasted report unreadable. One row
/// is the exception: a throughput row that says its test file may remain on
/// the server is kept on a cancelled walk too, because it is the only place
/// the file is named (`contributions(_:_:into:)`).
public actor ConnectionDiagnostics {
    private let descriptor: BackendDescriptor
    let values: FieldValues
    let secrets: (any SecretSource)?
    let sessionID: UUID?
    let stepTimeout: Duration
    let traceTimeout: Duration
    let appVersion: String
    private let jump: DiagnosticJump?
    let jumpDialer: DiagnosticJumpDialer
    let jumpDialLaunch: DetachedProbe.Launch
    let lookups: ResolveLookups
    private let throughputSettings: DiagnosticThroughputSettings
    private let throughputOpener: DiagnosticThroughputOpener
    private let internetSpeedSettings: DiagnosticInternetSpeedSettings
    private let internetSpeedTransport: InternetSpeedTransport
    private let internetSpeedClock: @Sendable () -> ContinuousClock.Instant

    /// - Parameters:
    ///   - secrets: where a contribution's credential comes from — the same
    ///     source the connect path resolves through. `nil` runs the universal
    ///     half and skips whatever needs a secret.
    ///   - sessionID: which session that source answers for. `SecretSource`
    ///     is keyed by session, so a source without this cannot answer and
    ///     the dial is skipped rather than dialled without a password.
    ///   - traceTimeout: the network trace's own budget, separate from
    ///     `stepTimeout` and much larger. A trace is not one probe but up to
    ///     `NetworkTrace.defaultMaxHops` of them at a second each, so under
    ///     the shared 5 s a path was cut off after its fifth silent hop —
    ///     hop 5 starts at t+4 s and still gets its full second, hop 6 never
    ///     starts — and `defaultMaxHops` was unreachable, a limit that could
    ///     never bind. 20 s is what a path of ordinary length needs; the row
    ///     says so when even that runs out.
    ///   - appVersion: what the report's build line says. Passed in because
    ///     Core does not read `Bundle.main` — the App owns that
    ///     (`SettingsView`), and Core carries no bundle assumption. The
    ///     default is not a placeholder nobody reaches: `macscp-cli
    ///     diagnose`, this initializer's second caller since 2026-09-04,
    ///     leaves it alone because the binary has no bundle and no
    ///     `--version` of its own. Nothing it prints carries the value —
    ///     only `DiagnosticReport.plainText()` and `markdown()` do, and the
    ///     CLI prints neither.
    ///   - jump: the jump host this session dials through, or `nil` for one
    ///     that dials its target directly. With one, the walk checks the jump
    ///     first and reaches the target through it (`run(scope:observer:)`);
    ///     without one, it is the walk it always was. REQUIRED, with no
    ///     default (fix round 1 of the 2026-09-18 plan's Task 6): a caller
    ///     that forgot it would compile and diagnose a bastion-only target
    ///     directly — the bug this parameter exists to end, one layer up. A
    ///     caller with no jump says so with `nil`.
    ///   - throughput: what the throughput test moves and the bandwidth
    ///     limits it moves it under (`DiagnosticThroughputSettings`).
    ///     REQUIRED, with no default, for `jump:`'s reason (Task 2 fix round
    ///     1 of the 2026-09-19 plan, M1): a caller that forgot it would
    ///     compile, and a `.throughput` run would then write to the user's
    ///     server ignoring their payload size and their bandwidth limits. The
    ///     panel passes its settings and the shared buckets, the CLI its
    ///     `--payload-mib`; a caller that never offers the scope says so with
    ///     `DiagnosticThroughputSettings()`.
    ///   - internetSpeed: which third-party service the internet speed test
    ///     measures against (`DiagnosticInternetSpeedSettings`). REQUIRED,
    ///     with no default, for `throughput:`'s reason and one more: the
    ///     default service is Cloudflare, so a caller that forgot this
    ///     parameter would compile and then talk to a third party a user
    ///     who chose `off` had switched off. The panel passes the service
    ///     from Settings, `macscp-cli diagnose` its `--speed-service`.
    public init(
        descriptor: BackendDescriptor,
        values: FieldValues,
        secrets: (any SecretSource)?,
        sessionID: UUID? = nil,
        jump: DiagnosticJump?,
        throughput: DiagnosticThroughputSettings,
        internetSpeed: DiagnosticInternetSpeedSettings,
        stepTimeout: Duration = .seconds(5),
        traceTimeout: Duration = .seconds(20),
        appVersion: String = "unknown"
    ) {
        self.init(
            descriptor: descriptor, values: values, secrets: secrets, sessionID: sessionID,
            jump: jump,
            jumpDialer: .live(knownHosts: KnownHostsStore(directory: SessionStore.defaultDirectory)),
            lookups: .live, throughput: throughput, throughputOpener: .live,
            internetSpeed: internetSpeed, internetSpeedTransport: .live,
            stepTimeout: stepTimeout, traceTimeout: traceTimeout, appVersion: appVersion)
    }

    /// The same, with the jump's two dials, the resolve step's lookups and
    /// the throughput step's connection injected — the suite's seams
    /// (`DiagnosticJumpDialer`, `ResolveLookups`,
    /// `DiagnosticThroughputOpener`). The public initializer hands the real
    /// ones: the dials over the known-hosts store the app's own connect
    /// reads, the machine's resolver, and the backend's own connect.
    /// `lookups` and `throughputOpener` default to those, so the cases that
    /// are not about the resolve or the throughput test keep the walk they
    /// always had.
    ///
    /// **Two parameters here are about not reaching the network from the
    /// suite, and they are deliberately asymmetric.** `internetSpeed`
    /// defaults to `.off`, where the public initializer requires the
    /// service to be named: a test that reaches `.internet` without saying
    /// which service would otherwise send two real requests to Cloudflare,
    /// and `DiagnosticScope.allCases` is iterated by four cases in this
    /// target alone. `internetSpeedTransport` has NO default at all —
    /// `.live` was one until the review of 2026-09-20, which is one-sided:
    /// a caller that names a service and forgets the transport reaches the
    /// network by omission, and omission is exactly what a default invites.
    /// Required, that cannot be written. The public initializer above is
    /// the one place `.live` is named.
    ///
    /// **`jumpDialLaunch`** is how `dialJump`'s probe body is put on a
    /// thread — `DetachedProbe.detach` in production, and a launcher the
    /// suite keeps the `Task` from in
    /// `aJumpConnectionThatArrivesAfterItsDeadlineIsClosed`. That case is
    /// about what the ABANDONED body does when its connection finally
    /// arrives, and the only other way to know it has done it is to wait
    /// for the close itself — which turns a MISSING close into "time limit
    /// exceeded" rather than into a red about the close (`docs/BACKLOG.md`,
    /// "The jump plan's deferred minors: diagnostics through the jump").
    /// With the task in hand the case awaits the body and then reads the
    /// ledger, so a body that closed nothing is red on the count.
    init(
        descriptor: BackendDescriptor,
        values: FieldValues,
        secrets: (any SecretSource)?,
        sessionID: UUID? = nil,
        jump: DiagnosticJump?,
        jumpDialer: DiagnosticJumpDialer,
        jumpDialLaunch: @escaping DetachedProbe.Launch = DetachedProbe.detach,
        lookups: ResolveLookups = .live,
        throughput: DiagnosticThroughputSettings = DiagnosticThroughputSettings(),
        throughputOpener: DiagnosticThroughputOpener = .live,
        internetSpeed: DiagnosticInternetSpeedSettings = DiagnosticInternetSpeedSettings(
            service: .off),
        internetSpeedTransport: InternetSpeedTransport,
        internetSpeedClock: @escaping @Sendable () -> ContinuousClock.Instant = {
            ContinuousClock().now
        },
        stepTimeout: Duration = .seconds(5),
        traceTimeout: Duration = .seconds(20),
        appVersion: String = "unknown"
    ) {
        self.descriptor = descriptor
        self.values = values
        self.secrets = secrets
        self.sessionID = sessionID
        self.jump = jump
        self.jumpDialer = jumpDialer
        self.jumpDialLaunch = jumpDialLaunch
        self.lookups = lookups
        self.throughputSettings = throughput
        self.throughputOpener = throughputOpener
        self.internetSpeedSettings = internetSpeed
        self.internetSpeedTransport = internetSpeedTransport
        self.internetSpeedClock = internetSpeedClock
        self.stepTimeout = stepTimeout
        self.traceTimeout = traceTimeout
        self.appVersion = appVersion
    }

    /// The diagnosis, with nothing to watch it happen.
    ///
    /// `run(scope:observer:)` is the real one; this is the spelling for a
    /// caller that only wants the finished report — the cases in
    /// `ConnectionDiagnosticsTests` that are about what was measured rather
    /// than when. Both callers that ship watch the walk: the panel through
    /// `run(scope:observer:)`, `macscp-cli diagnose` through
    /// `run(scope:onStep:)`.
    public func run(scope: DiagnosticScope = .complete) async -> DiagnosticReport {
        await run(scope: scope, observer: DiagnosticRunObserver())
    }

    /// The diagnosis, handing over each step as it finishes — the spelling
    /// for a caller that wants the rows and not the step in flight.
    ///
    /// One line over `run(scope:observer:)`, and kept because it is what the
    /// CLI's `DiagnoseCommand` calls (it prints a row as each one lands and
    /// has no line to caption) and what the cases in
    /// `ConnectionDiagnosticsTests` that are about the ROWS call.
    public func run(
        scope: DiagnosticScope = .complete, onStep: @escaping DiagnosticStepObserver
    ) async -> DiagnosticReport {
        await run(scope: scope, observer: DiagnosticRunObserver(onStep: onStep))
    }

    /// The diagnosis, handing over each step as it starts and again as it
    /// finishes, and running the steps `scope` names.
    ///
    /// `observer.onStep` is called with a step the moment it is appended,
    /// before the next one starts, and it is `async` so a `@MainActor`
    /// renderer can be awaited rather than hopped to and forgotten.
    /// `observer.onStepStarted` is called before the step's clocks are read,
    /// so nothing measured is spent on the announcement.
    ///
    /// **Why the seam exists.** The report used to be one value returned at
    /// the end, and the trace's budget is 20 s: an internet-facing host whose
    /// last hops are firewalled finishes resolve, TCP, echo and dial in under
    /// a second, then spends twenty more walking silence. The reader saw a
    /// spinner for 21+ seconds with four finished rows sitting in the local
    /// below, and cancelling cost them those rows as well.
    ///
    /// **Why the START half exists.** The rows fixed the first half of that
    /// and left the second: the line under them still read "Measuring…" for
    /// the whole walk, so the twenty seconds the trace spends looked exactly
    /// like a resolve that had hung (maintainer's finding on the dev build,
    /// 2026-09-04). Every step announces itself here — the resolve, the TCP
    /// ping, the echo, the trace and, through `bounded(_:_:)`, the dial and
    /// each contribution, and the throughput test; on a walk through a jump
    /// host, the `jump.` steps and every `target.` step too, measured or
    /// skipped.
    ///
    /// **A session behind a jump host** (`jump` non-nil) is walked through it
    /// (`walkThroughJump`): the jump first, from this Mac, then the target as
    /// the jump reaches it, then the contributions. A session without one is
    /// the walk below, unchanged.
    public func run(
        scope: DiagnosticScope = .complete, observer: DiagnosticRunObserver
    ) async -> DiagnosticReport {
        // BEFORE the endpoint is read, and before the jump branch: the
        // internet scope measures this Mac's link to a third-party service
        // and nothing of the session, so a session with no host runs it
        // exactly as a session with one does, and a session behind a jump
        // host does not reach the jump for it.
        if !scope.measuresTheSession {
            return await internetSpeedWalk(scope, observer)
        }

        guard let endpoint = descriptor.endpoint(values) else {
            // Not `failed`: nothing was measured and nothing is wrong with
            // the server. The form is incomplete, and the row has to say that
            // rather than report a lookup that never happened.
            //
            // And no `onStepStarted`, which is what separates this row from
            // every other one: a start says a step is BEING measured, and a
            // running line that named a resolve here would be captioning a
            // lookup nothing performed.
            let timer = Self.timer(for: DiagnosticStepID.resolve)
            let step = timer.finish(.unavailable(DiagnosticReason.noHost), "")
            await observer.onStep(step)
            // No endpoint, and the report says so by carrying none. Until
            // 2026-09-03 this handed `DiagnosticReport` an
            // `Endpoint(host: "", port: 0)`, and the two renderers printed
            // the header `Endpoint: :0` — a host and a port nobody measured,
            // in the text a user pastes into a bug report. The panel never
            // showed it (it reads its own endpoint, which is nil here), so
            // the only way to see it was to press Copy.
            return DiagnosticReport(
                endpoint: nil, steps: [step], appVersion: appVersion, scope: scope)
        }

        if let jump {
            return await runThroughJump(jump, to: endpoint, scope: scope, observer: observer)
        }

        var walk = Walk(
            endpoint: endpoint, jump: nil, appVersion: appVersion, scope: scope,
            observer: observer)

        guard !Task.isCancelled else { return walk.cancelled() }
        let (resolveStep, addresses) = await resolve(endpoint, observer)
        guard !Task.isCancelled else { return walk.cancelled() }
        await walk.append(resolveStep)

        // A step outside the scope produces NO row, rather than a `skipped`
        // one. `skipped` already means "asked for, and could not be measured"
        // — the ping with no address to probe — and a scoped report whose
        // unasked-for steps arrived under the same label would put "you did
        // not ask for this" and "this could not be answered" in one column of
        // a text somebody pastes into an issue. What the report says instead
        // is which scope it was: one line, once, in the header.
        if scope.runs(.tcp) {
            guard !Task.isCancelled else { return walk.cancelled() }
            let tcpStep = await ping(addresses, port: endpoint.port, observer)
            guard !Task.isCancelled else { return walk.cancelled() }
            await walk.append(tcpStep)
        }

        if scope.runs(.icmp) {
            guard !Task.isCancelled else { return walk.cancelled() }
            let icmpStep = await echo(addresses, observer)
            guard !Task.isCancelled else { return walk.cancelled() }
            await walk.append(icmpStep)
        }

        if scope.runs(.dial), let dial = descriptor.dial {
            guard !Task.isCancelled else { return walk.cancelled() }
            let step = await bounded(dial, observer)
            guard !Task.isCancelled else { return walk.cancelled() }
            await walk.append(step)
        }

        // After the dial and before the contributions, and now that IS what
        // the reader gets: the trace is the slowest universal step and the
        // least likely to change a verdict, so the rows somebody looks at
        // first — did it resolve, did anything accept, did the dial get in —
        // are on screen through `onStep` while it walks.
        //
        // The comment here said exactly this before `onStep` existed, when
        // `run()` returned one value at the end and the panel's own comment
        // said so in as many words. Two comments in one feature, each
        // asserting the negation of the other; this round made the claim true
        // rather than deleting it.
        if scope.runs(.trace) {
            guard !Task.isCancelled else { return walk.cancelled() }
            let traceStep = await trace(addresses, observer)
            guard !Task.isCancelled else { return walk.cancelled() }
            await walk.append(traceStep)
        }

        return await contributions(scope, observer, into: &walk)
    }

    /// The backend's contributions and the throughput test, when the scope
    /// asks for them, and the walk's natural end — shared by the direct walk
    /// and the one through a jump, which both finish here.
    ///
    /// The throughput test comes last. It is the one step that writes, the
    /// one that takes as long as its payload does, and no scope runs it
    /// beside anything but the resolve today — last is where it would stay
    /// out of every other row's way if one ever did.
    ///
    /// Through a jump host it runs whether or not the walk reached the jump:
    /// it opens its own connection through the jump the way a tab does, as
    /// `target.dialViaJump` does, and a jump it cannot reach is its own
    /// connect failing.
    func contributions(
        _ scope: DiagnosticScope, _ observer: DiagnosticRunObserver, into walk: inout Walk
    ) async -> DiagnosticReport {
        if scope.runs(.contributions) {
            for contribution in descriptor.diagnostics {
                guard !Task.isCancelled else { return walk.cancelled() }
                let step = await bounded(contribution, observer)
                guard !Task.isCancelled else { return walk.cancelled() }
                await walk.append(step)
            }
        }
        if scope.runs(.throughput) {
            guard !Task.isCancelled else { return walk.cancelled() }
            let step = await throughput(observer)
            guard !Task.isCancelled else {
                // The one row a cancel keeps. Every other step's row is
                // dropped so a cut-short measurement is never reported —
                // but this row, when it says the test file may remain, is
                // not a measurement: it is the only place the file is named,
                // and the step's cleanup is already over when it returns.
                if ThroughputProbe.mayHaveLeftAFile(step) { await walk.append(step) }
                return walk.cancelled()
            }
            await walk.append(step)
        }
        return walk.report(.complete)
    }

    // MARK: - The internet speed test

    /// The whole of a `.internet` walk: one step, and no `Walk`.
    ///
    /// No `Walk` because `Walk` carries an endpoint, and this report has
    /// none to carry — deliberately. The report is the artifact a user
    /// pastes into a public issue, and this run measured nothing about the
    /// session: naming its host and its jump host in the header of a
    /// measurement that never touched either would put somebody's server
    /// name into an issue about their broadband. `DiagnosticReport` already
    /// renders a missing endpoint by omitting the line, and the `Scope:
    /// internet` line says why it is missing.
    ///
    /// The cancellation shape is the walk's own: the row is published only
    /// if the task is still alive when the step returns, so a cut-short
    /// measurement is never reported. Nothing of this step lives past it —
    /// there is no file on anybody's server to name — so, unlike the
    /// throughput row, there is no row a cancel keeps.
    private func internetSpeedWalk(
        _ scope: DiagnosticScope, _ observer: DiagnosticRunObserver
    ) async -> DiagnosticReport {
        func report(_ steps: [DiagnosticStep], _ completion: DiagnosticReport.Completion)
            -> DiagnosticReport
        {
            DiagnosticReport(
                endpoint: nil, jump: nil, steps: steps, appVersion: appVersion,
                completion: completion, scope: scope)
        }
        guard !Task.isCancelled else { return report([], .cancelled(afterSteps: 0)) }
        let timer = await Self.starting(DiagnosticStepID.internet, announcedTo: observer)
        let step = await InternetSpeedProbe.measure(
            settings: internetSpeedSettings, transport: internetSpeedTransport,
            now: internetSpeedClock, timer: timer)
        guard !Task.isCancelled else { return report([], .cancelled(afterSteps: 0)) }
        await observer.onStep(step)
        return report([step], .complete)
    }

    // MARK: - The throughput test

    /// The throughput step: the session's own connection opened, the
    /// payload measured over it (`ThroughputProbe.measure`), and the
    /// connection closed.
    ///
    /// **Not raced against a deadline**, unlike every other step that
    /// dials. `DetachedProbe` abandons what it races, and an abandoned
    /// throughput test is a file left on the user's server by a task nobody
    /// holds. So the step runs in the walk's own task, from the connect to
    /// the removal: the connect is bounded by the transport's own timeout
    /// (`DialSupport.connectSeconds(stepTimeout)`, the dial's), the transfer
    /// by the payload size and the limits, and the whole of it by the
    /// user's Cancel — after which the removal and the close still run, out
    /// of the cancellation's reach and under their own backstop
    /// (`ThroughputProbe.cleanupBoundSeconds`).
    ///
    /// The secret is looked up as the session's dial looks it up: only when
    /// the backend says the values need one (`requiresSecret`, false for an
    /// SSH agent login), through the source the connect itself uses. Behind
    /// a jump host the jump's secret is looked up too, and the connection is
    /// the two-stage one a tab makes (`DiagnosticJump.targetConfig`).
    private func throughput(_ observer: DiagnosticRunObserver) async -> DiagnosticStep {
        let timer = await Self.starting(DiagnosticStepID.throughput, announcedTo: observer)
        let context = DiagnosticContext(
            secrets: secrets, sessionID: sessionID, timeout: stepTimeout)
        let secret: String
        switch DialSupport.dialSecret(
            usesAgent: !descriptor.requiresSecret(values),
            missing: DialSupport.missingSecretReason(DiagnosticReason.noSecret, secrets: secrets),
            context.secret)
        {
        case .secret(let resolved): secret = resolved
        case .unanswered(let outcome): return timer.finish(outcome, "")
        }
        let config: ConnectionConfig
        do {
            if let jump {
                let jumpSecret: String
                switch DialSupport.dialSecret(
                    usesAgent: jump.login.authKind == .agent,
                    missing: jump.missingSecretReason, jump.secret)
                {
                case .secret(let resolved): jumpSecret = resolved
                case .unanswered(let outcome): return timer.finish(outcome, "")
                }
                config = .ssh(
                    try jump.targetConfig(
                        values: values, targetSecret: secret, jumpSecret: jumpSecret))
            } else {
                config = try descriptor.makeConfig(values, secret)
            }
        } catch {
            return timer.finish(.failed(DialSupport.reason(for: error)), "")
        }
        let fileSystem: any RemoteFileSystem
        do {
            fileSystem = try await throughputOpener.open(
                config, DialSupport.connectSeconds(stepTimeout))
        } catch {
            return timer.finish(.failed(DialSupport.reason(for: error)), "")
        }
        let step = await ThroughputProbe.measure(
            on: fileSystem, payloadBytes: throughputSettings.payloadBytes,
            uploadThrottle: throughputSettings.uploadThrottle,
            downloadThrottle: throughputSettings.downloadThrottle,
            id: throughputSettings.fileID,
            cleanupBoundSeconds: throughputSettings.cleanupBoundSeconds, timer: timer)
        await ThroughputProbe.close(fileSystem, within: throughputSettings.cleanupBoundSeconds)
        return step
    }

    // MARK: - The seam

    /// Runs one contribution and holds it to the step timeout from outside.
    ///
    /// The contribution is told the same budget (`DiagnosticContext.timeout`)
    /// so its own transport can stop itself, AND is raced against that budget
    /// by `DetachedProbe`, which stops waiting once the deadline fires —
    /// whether or not the probe honoured its cancellation — and then returns
    /// as soon as it gets a cooperative-pool thread back. The timer itself is
    /// punctual; the RETURN costs whatever resumption costs, measured at
    /// 0.7 s, 1.4 s and once 5.9 s under the full suite. That is still the
    /// half that bounds the wall clock rather than only the reported row: an
    /// SSH dial against a wedged server carries Citadel's uncancellable 15 s
    /// `openSFTP` timer, and a task group would have waited all of it out.
    ///
    /// A step the deadline wins is reported with the elapsed time measured
    /// here, never with whatever the abandoned probe eventually says — that
    /// answer is dropped (see `DetachedProbe`). Which outcome it is reported
    /// as, `outcome(forUnanswered:)` decides: `timedOut` for a probe that
    /// ran, `notStarted` for one the pool never started.
    private func bounded(
        _ contribution: DiagnosticContribution, _ observer: DiagnosticRunObserver
    ) async -> DiagnosticStep {
        // The dial's start AND every contribution's, because both arrive here:
        // they are the two kinds of step that come through the seam, and the
        // two a reader waits longest for.
        await observer.onStepStarted(contribution.id, contribution.titleKey)
        let timer = DiagnosticStepTimer(id: contribution.id, titleKey: contribution.titleKey)
        let context = DiagnosticContext(
            secrets: secrets, sessionID: sessionID, timeout: stepTimeout)
        let values = self.values
        let answer = await DetachedProbe.run(timeout: stepTimeout) {
            await contribution.run(values, context)
        }
        // A cancellation lands here as `unanswered` too; `run()` re-reads
        // `Task.isCancelled` and never appends the step, so a cancelled run
        // cannot report a timeout it did not measure.
        switch answer {
        case .answered(let finished): return finished
        case .unanswered(let start): return timer.finish(Self.outcome(forUnanswered: start), "")
        }
    }

    /// A universal step's timer, with its start announced first.
    ///
    /// The announcement is made HERE rather than at each of its eight call
    /// sites (counted 2026-09-19: `resolve`, `ping`, `echo` and `trace`, each
    /// for both walks' ids; `dialJump`; the target half's
    /// `bounded(_:_:_:)`; `skippingTargetHalf`; `throughput`), so the id is spelled once
    /// per step: a start announced beside the call and a timer built inside
    /// the step would be two copies of one name, drifting the moment either
    /// moved.
    ///
    /// Announced BEFORE the timer is constructed, because the timer reads both
    /// clocks at construction — an observer that took a millisecond would
    /// otherwise be charged to the step it was told about.
    static func starting(
        _ id: String, announcedTo observer: DiagnosticRunObserver
    ) async -> DiagnosticStepTimer {
        let titleKey = DiagnosticStepID.titleKey(for: id)
        await observer.onStepStarted(id, titleKey)
        return DiagnosticStepTimer(id: id, titleKey: titleKey)
    }

    static func timer(for id: String) -> DiagnosticStepTimer {
        DiagnosticStepTimer(id: id, titleKey: DiagnosticStepID.titleKey(for: id))
    }
}

/// The rows a walk has measured so far, and the report they make.
///
/// One value both walks — the direct one and the one through a jump — carry,
/// so the rules below are stated once for every return site either has.
struct Walk {
    let endpoint: Endpoint
    let jump: Endpoint?
    let appVersion: String
    let scope: DiagnosticScope
    let observer: DiagnosticRunObserver
    private(set) var steps: [DiagnosticStep] = []

    init(
        endpoint: Endpoint, jump: Endpoint?, appVersion: String, scope: DiagnosticScope,
        observer: DiagnosticRunObserver
    ) {
        self.endpoint = endpoint
        self.jump = jump
        self.appVersion = appVersion
        self.scope = scope
        self.observer = observer
    }

    /// Hands a finished step to the observer, then keeps it — the publish
    /// and the append as one call at every site, in that order, so the
    /// observer is told about a row before the next step starts.
    mutating func append(_ step: DiagnosticStep) async {
        await observer.onStep(step)
        steps.append(step)
    }

    /// The report as it stands, labelled with how the walk ended.
    ///
    /// The label has NO default, and that is the whole point of its shape.
    /// This helper used to take none and always produce a complete report,
    /// so every cancellation return handed back a cut-short measurement that
    /// claimed, at the type level, to be a finished one — and
    /// `DiagnosticReport.Completion`'s marker, which exists precisely so a
    /// pasted partial cannot be read as "these steps were measured and found
    /// absent", never appeared on the one path a user reaches with the Cancel
    /// button. A required argument is what makes the next return site decide
    /// instead of inherit.
    func report(_ completion: DiagnosticReport.Completion) -> DiagnosticReport {
        DiagnosticReport(
            endpoint: endpoint, jump: jump, steps: steps, appVersion: appVersion,
            completion: completion, scope: scope)
    }

    /// What every cancellation guard returns.
    ///
    /// The count is read here rather than derived from `Task.isCancelled`
    /// inside `report(_:)`: a cancellation that arrives after the last step
    /// has been appended — while the walk is on its way to its natural return
    /// — would make a finished measurement label itself cancelled, which is
    /// the same misreading in the other direction. Where the walk stopped is
    /// known at the site that stops it.
    func cancelled() -> DiagnosticReport {
        report(.cancelled(afterSteps: steps.count))
    }
}
