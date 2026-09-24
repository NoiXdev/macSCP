import Foundation

/// Which of the diagnosis's steps a run is asked to measure.
///
/// The panel's Run button used to mean all of them, and all of them costs
/// whatever the slowest one costs — a firewalled path spends the trace's
/// whole 20 s budget walking silence, for a reader who only wanted to know
/// whether anything answers on the port. A scope is that reader saying so.
///
/// The resolve step is in every scope that measures the session, and is not
/// listed below: every other step of such a walk probes an ADDRESS, so a
/// scope that skipped the lookup would have nothing to point at. `.internet`
/// is the one scope that measures no session, and it runs no resolve either
/// (`measuresTheSession`).
///
/// **Through a jump host** each scope covers both halves: the jump's own
/// steps under the phase they share with a direct walk, and each `target.`
/// step under its own phase (`DiagnosticJumpStep.phase`). The resolve is the
/// jump's. And a scope that runs any `target.` step also dials the jump
/// (`ConnectionDiagnostics.needsJumpConnection(_:)`), because every one of
/// them is measured over that connection — so `.ping` there runs
/// `jump.dial` beside `target.tcpViaJump`, and `.trace` runs it beside
/// `target.traceFromJump` (since 2026-09-18, when the trace ON the jump host
/// joined the target half). Both therefore look up the jump's secret.
///
/// `rawValue` is the stable spelling the App builds its catalogue keys from
/// (`diagnostics.scope.<rawValue>`), which is why the cases are named for
/// what the user picks rather than for the step ids they expand into.
///
/// **Two scopes are not in `.complete`, and for two different reasons.**
/// `.throughput` WRITES a file to the user's server, moves up to 256 MiB
/// each way, and removes it again — decided for the maintainer in the plan
/// of 2026-09-19: something that moves data on the user's server runs only
/// when it is chosen by name, never as part of "everything". `.internet`
/// talks to a THIRD PARTY, which is the other thing nobody should be given
/// without asking for it. Counted 2026-09-20: two, and `runs(_:)`'s
/// `.complete` arm names exactly those two.
public enum DiagnosticScope: String, CaseIterable, Sendable {
    /// Everything that only reads THIS SESSION: the resolve, the TCP
    /// connection attempt, the ICMP echo, the backend's own dial, the
    /// network trace and the backend's contributions. Neither the
    /// throughput test nor the internet speed test (see above).
    case complete
    /// Is anything there: the resolve, the TCP connection attempt and the
    /// ICMP echo. Behind a jump host it also dials the jump and reads the
    /// jump's secret, because the target's TCP attempt and echo are asked
    /// over that connection (`ConnectionDiagnostics.needsJumpConnection(_:)`).
    case ping
    /// Where does the path stop: the resolve and the network trace. Behind a
    /// jump host it too dials the jump and reads the jump's secret, because
    /// the target's trace runs as a command on the jump host.
    case trace
    /// Does the protocol get in: the resolve and the backend's own dial.
    case dial
    /// What does the server say: the resolve and the backend's contributions.
    case contributions
    /// How fast does it move data: the resolve and the throughput test — a
    /// payload written to the session's start folder over the session's own
    /// protocol, read back, compared and removed (`ThroughputProbe`). It
    /// authenticates, so it reads the session's secret; behind a jump host
    /// it reads the jump's too, because its connection goes through it.
    case throughput
    /// How fast is this Mac's line: the internet speed test, and NOTHING
    /// else — not even the resolve every other scope runs. It measures the
    /// link between this Mac and a service named in Settings
    /// (`InternetSpeedProbe`), so a lookup of the session's host would be a
    /// measurement of something this scope is not about, and a host name in
    /// a report that gets pasted into a public issue for a run that never
    /// touched it. Reads no secret, opens no connection to the server, and
    /// sends nothing of the session anywhere.
    case internet

    /// A step a scope is allowed to leave out.
    ///
    /// Not `DiagnosticStepID`, which is a set of `String` constants that also
    /// has to name a contribution's own id: a scope decides between PHASES of
    /// the walk, and a switch over them is exhaustive where a string
    /// comparison is a guess. The resolve has no case here because there is
    /// no scope that omits it — a case that can never be false would be a
    /// choice the walk pretends to make.
    enum OptionalStep {
        case tcp
        case icmp
        case dial
        case trace
        case contributions
        case throughput
        case internet
    }

    /// Whether this scope runs a step that resolves a secret — the dial, the
    /// contributions and the throughput test, the three that authenticate.
    /// Derived from
    /// `runs(_:)`, so a scope added to this enum answers by construction
    /// rather than by being remembered here.
    ///
    /// The SESSION's secret, through the source the runner was handed. A
    /// walk through a jump host also looks the jump's own secret up when it
    /// dials the jump — under `.ping` and `.trace` too — but through the
    /// jump's lookup (`DiagnosticJump`), not through that source, so this
    /// answer and what `--verbose` reports about the source are unchanged by
    /// it.
    ///
    /// Public because the CLI asks it and `runs(_:)`/`OptionalStep` are
    /// internal: `macscp-cli diagnose --verbose` reports which secret source
    /// answered, and a scope that asked for none would otherwise print
    /// `secret source: none` — a line that reads as a finding about the
    /// session when it only means nothing looked.
    public var resolvesASecret: Bool {
        runs(.dial) || runs(.contributions) || runs(.throughput)
    }

    /// Whether this scope measures that step.
    func runs(_ step: OptionalStep) -> Bool {
        switch self {
        case .complete:
            return step != .throughput && step != .internet
        case .ping:
            return step == .tcp || step == .icmp
        case .trace:
            return step == .trace
        case .dial:
            return step == .dial
        case .contributions:
            return step == .contributions
        case .throughput:
            return step == .throughput
        case .internet:
            return step == .internet
        }
    }

    /// Whether this scope measures the SESSION at all.
    ///
    /// True for every scope but one. `.internet` measures this Mac's link
    /// to a third-party service and nothing else, which is why it is the
    /// one scope that does not run the resolve step — the step whose
    /// absence from `OptionalStep` says "there is no scope that omits it".
    ///
    /// DERIVED from `runs(.internet)` rather than written as
    /// `self != .internet`, and that is not a stylistic choice. The walk
    /// branches on THIS property and never on `runs(.internet)`, so with
    /// the two written separately `runs(.internet)` governed nothing:
    /// measured 2026-09-20 with a probe that made `.complete` run the
    /// internet step, which turned the enumeration red and left
    /// `theCompleteScopeSendsNoRequestToAnySpeedService` — the case that is
    /// actually about the Run button — green over a walk that still sent
    /// nothing. Derived, a scope that gains the internet step gains the
    /// branch that runs it, and that case is the one that fails.
    ///
    /// It says, as a consequence, that a scope cannot both run the internet
    /// step and measure the session. That is the design: the step sends
    /// nothing of the session anywhere, and a walk that mixed the two would
    /// put a server's name in the header of a row about somebody's
    /// broadband.
    public var measuresTheSession: Bool { !runs(.internet) }
}

/// The trace table's four columns — as catalogue keys, which is what a
/// `DiagnosticTable` carries — and the words its cells are written in.
///
/// The keys are here rather than in the App because the table is Core's, the
/// same rule `DiagnosticStepID.titleKey(for:)` and `DiagnosticReason`'s table
/// already keep: Core names a row, the App resolves the name, and no catalog
/// is read on this side.
///
/// The CELL words are English and unlocalized in Core, like every other word
/// the report prints (`DiagnosticOutcome.label` states why); the panel maps
/// them through `diagnostics.trace.outcome.*`. They are constants and not
/// literals at all three arms of `traceTable(_:)`'s switch — `.forwarded`,
/// `.unreachable` and `.timedOut` — for the same reason the reasons are: a
/// reworded word has to break the mapping loudly rather than quietly stop
/// matching.
public enum DiagnosticTraceColumn {
    public static let hop = "diagnostics.trace.column.hop"
    public static let address = "diagnostics.trace.column.address"
    public static let rtt = "diagnostics.trace.column.rtt"
    public static let outcome = "diagnostics.trace.column.outcome"

    /// Every column key, in the order the cells are written, so a catalogue
    /// check can require all four without enumerating them a second time.
    public static let all = [hop, address, rtt, outcome]

    /// A router on the path answered, and the walk went on past it.
    public static let answered = "answered"
    /// The hop was given its full `NetworkTrace.hopTimeout` and answered
    /// nothing. It is a measurement, not a gap — see `TraceHopOutcome
    /// .timedOut`, which is the only thing that produces this row.
    public static let silent = "silent"
    /// The address the trace was aimed at answered: the path ends here.
    public static let destination = "destination"

    /// Anything else that answered destination-unreachable, naming the code
    /// it sent — a policy block most often, and a finding about the path.
    public static func unreachable(code: UInt8) -> String { "unreachable (code \(code))" }

    /// What the address column says for a hop that answered nothing. The
    /// traceroute spelling, and the one this project's hop rows have always
    /// used.
    public static let noAddress = "*"
    /// What the RTT column says for the same hop: there is no round trip to
    /// report, and an empty cell reads as a number that went missing.
    public static let noRTT = "—"
}

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
    private let values: FieldValues
    private let secrets: (any SecretSource)?
    private let sessionID: UUID?
    private let stepTimeout: Duration
    private let traceTimeout: Duration
    private let appVersion: String
    private let jump: DiagnosticJump?
    private let jumpDialer: DiagnosticJumpDialer
    private let lookups: ResolveLookups
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
    init(
        descriptor: BackendDescriptor,
        values: FieldValues,
        secrets: (any SecretSource)?,
        sessionID: UUID? = nil,
        jump: DiagnosticJump?,
        jumpDialer: DiagnosticJumpDialer,
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
    private func contributions(
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
    private func runThroughJump(
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
    /// skipped for a missing secret, timed out, or was never asked for), every
    /// target step in scope is `skipped` naming the jump
    /// (`DiagnosticReason.jumpNotReached`). `failed` only: an echo that heard
    /// nothing is `timedOut`, and a firewall that drops ICMP says nothing
    /// about whether the bastion forwards. The jump's trace runs after its
    /// dial and before the target half, and does not count — it is measured
    /// from this Mac, and a router that refuses a probe is not a bastion that
    /// refuses a login.
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
    /// here — and so, unlike them, it has to deal with a connection that
    /// arrives AFTER the deadline: the probe is abandoned, not stopped, and a
    /// transport that finishes its connect anyway would leave a login open on
    /// the bastion with nobody holding it. `JumpHandoff` is the one place the
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
        let finished = await DetachedProbe.run(timeout: stepTimeout) {
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
        let step = finished ?? timer.finish(.timedOut, "")
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
    /// measured — or a plain `timedOut` for a step with nothing to salvage.
    ///
    /// Static, and handed the context rather than building it, so the suite
    /// can race a step against a transcript it filled itself: the cut is
    /// then read from known output whether or not the abandoned probe ever
    /// got a thread (`aStepCutByItsBudgetReportsWhatItHadCollected`).
    static func race(
        _ step: DiagnosticJumpStep, _ context: DiagnosticJumpStep.Context,
        timer: DiagnosticStepTimer
    ) async -> DiagnosticStep {
        let finished = await DetachedProbe.run(timeout: context.budget) {
            await step.measure(context, timer)
        }
        if let finished { return finished }
        return step.cut?(context, timer) ?? timer.finish(.timedOut, "")
    }

    // MARK: - The universal steps

    /// The resolve step — this Mac's lookup of `endpoint`, as `resolve` or
    /// as `jump.resolve` — and then each address it found named
    /// (`ResolveLookups`): a reverse lookup, and a forward lookup of that
    /// name to see whether it leads back.
    ///
    /// **One budget for all of it.** The naming gets what the host lookup
    /// left of `stepTimeout`, measured on the step's own clock, so a
    /// resolve row never takes longer than a resolve row always could. A
    /// lookup that does not answer inside it is a `no answer` cell and not
    /// a `timedOut` row: the addresses were found, and they are what every
    /// later step probes.
    ///
    /// **Never a verdict.** The row is `ok` whatever the names say — the
    /// table beside the detail line reports them (`DiagnosticNameColumn`).
    /// The detail line is the one it always was, so nothing that read it
    /// reads anything new.
    private func resolve(
        _ endpoint: Endpoint, as id: String = DiagnosticStepID.resolve,
        _ observer: DiagnosticRunObserver
    ) async -> (DiagnosticStep, [ResolvedAddress]) {
        let timer = await Self.starting(id, announcedTo: observer)
        let clock = ContinuousClock()
        let begun = clock.now
        let outcome = await lookups.host(endpoint.host, endpoint.port, stepTimeout)
        switch outcome {
        case .resolved(let addresses):
            let detail = addresses
                .map { "\($0.family.rawValue) \($0.text)" }
                .joined(separator: ", ")
            let left = stepTimeout - begun.duration(to: clock.now)
            let names = await lookups.name(addresses, within: left)
            return (timer.finish(.ok, detail, table: Self.namesTable(names)), addresses)
        case .failed(let reason):
            return (timer.finish(.failed(reason), ""), [])
        case .timedOut:
            return (timer.finish(.timedOut, ""), [])
        }
    }

    private func ping(
        _ addresses: [ResolvedAddress], port: Int, as id: String = DiagnosticStepID.tcp,
        _ observer: DiagnosticRunObserver
    ) async -> DiagnosticStep {
        let timer = await Self.starting(id, announcedTo: observer)
        guard !addresses.isEmpty else {
            return timer.finish(.skipped(DiagnosticReason.nothingToProbe), "")
        }
        let results = await TCPPing.probeAll(addresses: addresses, timeout: stepTimeout)
        let detail = results.map { result -> String in
            let target = Endpoint(host: result.address.text, port: port).text
            guard let elapsed = result.outcome.elapsed else {
                return "\(target) \(result.outcome.label)"
            }
            return "\(target) \(result.outcome.label) in \(DurationText.milliseconds(elapsed))"
        }.joined(separator: "; ")

        // The first address that ACCEPTS decides the step: a host with an
        // AAAA nothing listens on and an A that answers is a working
        // connection, and a row that reported the IPv6 refusal as the verdict
        // would send the user after a problem they do not have.
        if results.contains(where: { if case .accepted = $0.outcome { return true } else { return false } }) {
            return timer.finish(.ok, detail)
        }
        if results.contains(where: { if case .refused = $0.outcome { return true } else { return false } }) {
            return timer.finish(.failed("refused"), detail)
        }
        if results.allSatisfy({ $0.outcome == .timedOut }) {
            return timer.finish(.timedOut, detail)
        }
        let firstFailure = results.compactMap { result -> String? in
            if case .failed(let reason) = result.outcome { return reason }
            return nil
        }.first
        return timer.finish(.failed(firstFailure ?? "no address accepted"), detail)
    }

    /// The ICMP echo step: `ICMPEcho.defaultProbeCount` requests per resolved
    /// address, and the three round-trip numbers a reader expects of a ping.
    ///
    /// Silence is NOT `failed`. An ordinary firewall drops ICMP while the
    /// service behind it accepts connections perfectly well, and a row that
    /// called that a server fault would send the user after a problem they do
    /// not have — the same reasoning the TCP step's "first acceptance wins"
    /// rule rests on. What silence gets is `timedOut`, the deadline's answer.
    private func echo(
        _ addresses: [ResolvedAddress], as id: String = DiagnosticStepID.icmp,
        _ observer: DiagnosticRunObserver
    ) async -> DiagnosticStep {
        let timer = await Self.starting(id, announcedTo: observer)
        guard !addresses.isEmpty else {
            return timer.finish(.skipped(DiagnosticReason.nothingToProbe), "")
        }
        let results = await ICMPEcho.probeAll(addresses: addresses, timeout: stepTimeout)
        let detail = results.map(Self.line).joined(separator: "; ")

        if results.contains(where: { !$0.outcome.replies.isEmpty }) {
            return timer.finish(.ok, detail)
        }
        // Every address unreachable from here — no socket, no route — is
        // about this machine, so the step says so rather than reporting a
        // silence it never measured.
        let localReasons = results.compactMap { result -> String? in
            if case .unavailable(let reason) = result.outcome { return reason }
            return nil
        }
        if localReasons.count == results.count, let reason = localReasons.first {
            return timer.finish(.unavailable(reason), detail)
        }
        return timer.finish(.timedOut, detail)
    }

    /// The network trace step: an IPv4 hop-by-hop walk toward the endpoint,
    /// one row per hop.
    ///
    /// Only the FIRST IPv4 address is traced. A trace measures the path, and a
    /// host's second A record normally shares almost all of it; walking every
    /// address would multiply the slowest step in the report by the length of
    /// the resolve list for an answer that repeats itself.
    ///
    /// A host that resolves only to IPv6 gets `unavailable` with the sentence
    /// design §5 verdict (c) earned — the IPv6 trace was never measured,
    /// because the machine that measured everything else had no route to try
    /// it on. Not `failed`: nobody observed a failure.
    ///
    /// The walk runs against `traceTimeout`, not `stepTimeout`: see the
    /// initializer's note.
    private func trace(
        _ addresses: [ResolvedAddress], as id: String = DiagnosticStepID.trace,
        _ observer: DiagnosticRunObserver
    ) async -> DiagnosticStep {
        let timer = await Self.starting(id, announcedTo: observer)
        guard !addresses.isEmpty else {
            return timer.finish(.skipped(DiagnosticReason.nothingToProbe), "")
        }
        guard let target = addresses.first(where: { $0.family == .ipv4 }) else {
            return timer.finish(.unavailable(NetworkTrace.ipv6UnmeasuredReason), "")
        }
        let outcome = await NetworkTrace.trace(address: target, timeout: traceTimeout)
        return timer.finish(
            Self.traceOutcome(outcome), Self.traceDetail(outcome),
            table: Self.traceTable(outcome))
    }

    /// The trace step's detail line: the marker that says the walk stopped
    /// LOOKING, and nothing else.
    ///
    /// The hops themselves moved to `traceTable(_:)` on 2026-09-03, on the
    /// maintainer's finding about the dev build: eight hops joined with `; `
    /// is one line nobody reads. What stays here is what is not a hop —
    /// a marker for each of the two ways the trace stops looking, its budget
    /// and its hop limit, and none for the two ways the walk actually ends
    /// (a hop answered, or the kernel refused, which the outcome carries as
    /// `failed` with the sentence). An ordinary arrival therefore has an
    /// EMPTY detail: the table is the whole measurement.
    ///
    /// The line keeps its `; ` join for the day a second marker joins the
    /// two, and because `DiagnosticsPresentation.detail(of:)` splits on it to
    /// localize what it finds.
    ///
    /// The hop is named by the last row's own `ttl`, never by `hops.count`.
    /// They are the same number today, because hops are appended for
    /// consecutive `ttl`s and the only dropped row is the walk's last act —
    /// but this file has a row-dropping rule, and a second one would make a
    /// count name the wrong hop in the artifact people paste, with no fixture
    /// able to see it.
    static func traceDetail(_ outcome: NetworkTraceOutcome) -> String {
        var rows: [String] = []
        let lastHop = outcome.hops.last?.ttl ?? 0
        switch outcome.ending {
        case .budget:
            rows.append(DiagnosticReason.traceStoppedByBudget(afterHop: lastHop))
        case .hopLimit:
            rows.append(DiagnosticReason.traceHopLimitReached(afterHop: lastHop))
        case .answered, .refused, nil:
            break
        }
        return rows.joined(separator: "; ")
    }

    /// The trace step's hops, as the four columns a reader compares them by,
    /// or `nil` when there is nothing to tabulate.
    ///
    /// `nil` rather than an empty table for a walk that measured no hop at
    /// all — a machine that could not trace, or a budget that ran out before
    /// the first second — because a header drawn over no rows is a grid that
    /// claims a measurement nobody made.
    ///
    /// A `static func` over a value, like `traceDetail(_:)` beside it and for
    /// the same reason: none of the rows worth pinning can be provoked on
    /// loopback, where the only address that answers is the destination and
    /// the only code it sends is 3.
    ///
    /// The outcome word is decided HERE and not on `NetworkTraceHop`, because
    /// two of the four need the destination the walk was aimed at, which the
    /// hop does not carry — the same reason `reachedDestination` lives on the
    /// outcome. The two are `destination` and `unreachable (code …)`, and the
    /// `.unreachable` arm below tells them apart by that comparison AND the
    /// code — both halves of a conjunction, not the address alone; `answered`
    /// and `silent` never consult the destination at all.
    ///
    /// `destination` means what it means there: the answering
    /// address is the address the trace was aimed at. Anything else that
    /// answered destination-unreachable is reported as what it is, a refusal
    /// naming its code, whether or not the code is port-unreachable.
    ///
    /// The words are English, like every other word the report prints
    /// (`DiagnosticOutcome.label` states the precedent); the panel maps them
    /// through its own catalogs.
    static func traceTable(_ outcome: NetworkTraceOutcome) -> DiagnosticTable? {
        guard case .measured(let hops, let destination, _) = outcome, !hops.isEmpty else {
            return nil
        }
        return DiagnosticTable(
            columns: [
                DiagnosticTraceColumn.hop, DiagnosticTraceColumn.address,
                DiagnosticTraceColumn.rtt, DiagnosticTraceColumn.outcome,
            ],
            rows: hops.map { hop in
                switch hop.outcome {
                case .forwarded(let address, let rtt):
                    return [
                        "\(hop.ttl)", address, DurationText.milliseconds(rtt),
                        DiagnosticTraceColumn.answered,
                    ]
                case .unreachable(let address, let rtt, let code):
                    let word =
                        address == destination && code == NetworkTrace.portUnreachableCode
                        ? DiagnosticTraceColumn.destination
                        : DiagnosticTraceColumn.unreachable(code: code)
                    return ["\(hop.ttl)", address, DurationText.milliseconds(rtt), word]
                case .timedOut:
                    return [
                        "\(hop.ttl)", DiagnosticTraceColumn.noAddress,
                        DiagnosticTraceColumn.noRTT, DiagnosticTraceColumn.silent,
                    ]
                }
            })
    }

    /// The trace step's outcome, and the order the questions are asked in.
    ///
    /// - **This machine could not trace at all** → `unavailable`.
    /// - **The kernel refused a hop mid-walk** → `failed` with `strerror`'s
    ///   sentence. A route that changed under the walk, a descriptor the
    ///   kernel would not give, a receiving socket that failed: none of it is
    ///   about the server, and all of it has to reach the reader instead of
    ///   being laundered into a timeout.
    /// - **The destination answered** → `ok`, whatever happened on the way.
    /// - **A router refused** — destination-unreachable with a code that is
    ///   not port-unreachable — → `failed`, naming the code and the hop. A
    ///   corporate firewall answering admin-prohibited at hop 4 is a finding
    ///   about the path, and badging it `timed out` sends the user after a
    ///   slow network they do not have.
    ///
    ///   **This is asked BEFORE the budget**, and the ordering is load-bearing
    ///   for exactly one path: `NetworkTrace.run`'s fallback labels an
    ///   abandoned walk `.budget` from the collector, so a walk that had
    ///   already ended at a refusal and then lost the outer margin arrives
    ///   here with both. Asking the budget first badged that policy block
    ///   `ok`.
    /// - **The trace stopped looking** — its budget or its hop limit ran out
    ///   → `ok` when a hop answered, `timedOut` when none did. A walk cut
    ///   short after measuring six hops MEASURED six hops; calling that a
    ///   timeout would report the trace's own limits as a fact about the
    ///   network. What it is not allowed to do is stay silent about the cut,
    ///   and `traceDetail`'s markers are where it says so.
    /// - **Anything else** — a last hop nobody answered → `timedOut`.
    static func traceOutcome(_ outcome: NetworkTraceOutcome) -> DiagnosticOutcome {
        if case .unavailable(let reason) = outcome { return .unavailable(reason) }
        if case .refused(let reason) = outcome.ending { return .failed(reason) }
        if outcome.reachedDestination { return .ok }
        if case .unreachable(_, _, let code) = outcome.hops.last?.outcome,
            code != NetworkTrace.portUnreachableCode
        {
            let hop = outcome.hops.last?.ttl ?? outcome.hops.count
            return .failed(DiagnosticReason.traceHopUnreachable(code: code, hop: hop))
        }
        if outcome.ending == .budget || outcome.ending == .hopLimit {
            return outcome.answeredAnyHop ? .ok : .timedOut
        }
        return .timedOut
    }

    /// One address's contribution to the echo step's detail line.
    private static func line(
        _ result: (address: ResolvedAddress, outcome: ICMPEchoOutcome)
    ) -> String {
        switch result.outcome {
        case .unavailable(let reason):
            return "\(result.address.text) \(reason)"
        case .measured(let sent, let replies):
            let times = replies.map(\.rtt)
            guard let low = times.min(), let high = times.max() else {
                return "\(result.address.text) 0/\(sent) replies"
            }
            let average = times.reduce(Duration.zero, +) / times.count
            return "\(result.address.text) \(replies.count)/\(sent) replies, "
                + "min \(DurationText.milliseconds(low)), "
                + "avg \(DurationText.milliseconds(average)), "
                + "max \(DurationText.milliseconds(high))"
        }
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
    /// A step the deadline wins is reported `timedOut` with the elapsed time
    /// measured here, never with whatever the abandoned probe eventually
    /// says — that answer is dropped (see `DetachedProbe`).
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
        let finished = await DetachedProbe.run(timeout: stepTimeout) {
            await contribution.run(values, context)
        }
        // A cancellation lands here as `nil` too; `run()` re-reads
        // `Task.isCancelled` and never appends the step, so a cancelled run
        // cannot report a timeout it did not measure.
        return finished ?? timer.finish(.timedOut, "")
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
    private static func starting(
        _ id: String, announcedTo observer: DiagnosticRunObserver
    ) async -> DiagnosticStepTimer {
        let titleKey = DiagnosticStepID.titleKey(for: id)
        await observer.onStepStarted(id, titleKey)
        return DiagnosticStepTimer(id: id, titleKey: titleKey)
    }

    private static func timer(for id: String) -> DiagnosticStepTimer {
        DiagnosticStepTimer(id: id, titleKey: DiagnosticStepID.titleKey(for: id))
    }
}

/// The rows a walk has measured so far, and the report they make.
///
/// One value both walks — the direct one and the one through a jump — carry,
/// so the rules below are stated once for every return site either has.
private struct Walk {
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
