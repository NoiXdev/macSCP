import Foundation

/// Which of the diagnosis's steps a run is asked to measure.
///
/// The panel's Run button used to mean all of them, and all of them costs
/// whatever the slowest one costs — a firewalled path spends the trace's
/// whole 20 s budget walking silence, for a reader who only wanted to know
/// whether anything answers on the port. A scope is that reader saying so.
///
/// The resolve step is in every scope and is not listed below: every other
/// step probes an ADDRESS, so a scope that skipped the lookup would have
/// nothing to point at.
///
/// `rawValue` is the stable spelling the App builds its catalogue keys from
/// (`diagnostics.scope.<rawValue>`), which is why the cases are named for
/// what the user picks rather than for the step ids they expand into.
public enum DiagnosticScope: String, CaseIterable, Sendable {
    /// Everything: the resolve, the TCP connection attempt, the ICMP echo,
    /// the backend's own dial, the network trace and the backend's
    /// contributions.
    case complete
    /// Is anything there: the resolve, the TCP connection attempt and the
    /// ICMP echo.
    case ping
    /// Where does the path stop: the resolve and the network trace.
    case trace
    /// Does the protocol get in: the resolve and the backend's own dial.
    case dial
    /// What does the server say: the resolve and the backend's contributions.
    case contributions

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
    }

    /// Whether this scope measures that step.
    func runs(_ step: OptionalStep) -> Bool {
        switch self {
        case .complete:
            return true
        case .ping:
            return step == .tcp || step == .icmp
        case .trace:
            return step == .trace
        case .dial:
            return step == .dial
        case .contributions:
            return step == .contributions
        }
    }
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
/// literals at the two switch arms for the same reason the reasons are: a
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

/// The universal half of the connection diagnosis, plus the seam the
/// protocols fill (design §§2–3).
///
/// Runs, in order and each under its own deadline: name resolution, one TCP
/// connection attempt per resolved address, an ICMP echo per resolved
/// address, the backend's own dial, an IPv4 network trace, and then whatever
/// the backend contributes — or the subset of those a `DiagnosticScope`
/// names, which is what a caller who wants one probe and not the whole walk
/// passes to `run(scope:onStep:)`. Nothing here asks which protocol it is looking at
/// — the endpoint, the dial and the contributions all arrive through
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
/// itself as a whole one is what makes a pasted report unreadable.
public actor ConnectionDiagnostics {
    private let descriptor: BackendDescriptor
    private let values: FieldValues
    private let secrets: (any SecretSource)?
    private let sessionID: UUID?
    private let stepTimeout: Duration
    private let traceTimeout: Duration
    private let appVersion: String

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
    ///     (`SettingsView`), and Core carries no bundle assumption.
    public init(
        descriptor: BackendDescriptor,
        values: FieldValues,
        secrets: (any SecretSource)?,
        sessionID: UUID? = nil,
        stepTimeout: Duration = .seconds(5),
        traceTimeout: Duration = .seconds(20),
        appVersion: String = "unknown"
    ) {
        self.descriptor = descriptor
        self.values = values
        self.secrets = secrets
        self.sessionID = sessionID
        self.stepTimeout = stepTimeout
        self.traceTimeout = traceTimeout
        self.appVersion = appVersion
    }

    /// The diagnosis, with nothing to watch it happen.
    ///
    /// `run(scope:onStep:)` is the real one; this is the spelling for a
    /// caller that only wants the finished report — the CLI, and every test
    /// that is about what was measured rather than when.
    public func run(scope: DiagnosticScope = .complete) async -> DiagnosticReport {
        await run(scope: scope, onStep: { _ in })
    }

    /// The diagnosis, handing over each step as it finishes, and running the
    /// steps `scope` names.
    ///
    /// `onStep` is called with a step the moment it is appended, before the
    /// next one starts, and it is `async` so a `@MainActor` renderer can be
    /// awaited rather than hopped to and forgotten.
    ///
    /// **Why the seam exists.** The report used to be one value returned at
    /// the end, and the trace's budget is 20 s: an internet-facing host whose
    /// last hops are firewalled finishes resolve, TCP, echo and dial in under
    /// a second, then spends twenty more walking silence. The reader saw a
    /// spinner for 21+ seconds with four finished rows sitting in the local
    /// below, and cancelling cost them those rows as well.
    public func run(
        scope: DiagnosticScope = .complete, onStep: @escaping DiagnosticStepObserver
    ) async -> DiagnosticReport {
        guard let endpoint = descriptor.endpoint(values) else {
            // Not `failed`: nothing was measured and nothing is wrong with
            // the server. The form is incomplete, and the row has to say that
            // rather than report a lookup that never happened.
            let timer = Self.timer(for: DiagnosticStepID.resolve)
            let step = timer.finish(.unavailable(DiagnosticReason.noHost), "")
            await onStep(step)
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

        var steps: [DiagnosticStep] = []
        /// The report as it stands, labelled with how the walk ended.
        ///
        /// The label has NO default, and that is the whole point of its
        /// shape. This helper used to take none and always produce a complete
        /// report, so the twelve cancellation returns below handed back a
        /// cut-short measurement that claimed, at the type level, to be a
        /// finished one — and `DiagnosticReport.Completion`'s marker, which
        /// exists precisely so a pasted partial cannot be read as "these
        /// steps were measured and found absent", never appeared on the one
        /// path a user reaches with the Cancel button. A required argument is
        /// what makes the next return site decide instead of inherit.
        func report(_ completion: DiagnosticReport.Completion) -> DiagnosticReport {
            DiagnosticReport(
                endpoint: endpoint, steps: steps, appVersion: appVersion,
                completion: completion, scope: scope)
        }
        /// What every cancellation guard below returns.
        ///
        /// The count is read here rather than derived from `Task.isCancelled`
        /// inside `report(_:)`: a cancellation that arrives after the last
        /// step has been appended — while the walk is on its way to its
        /// natural return — would make a finished measurement label itself
        /// cancelled, which is the same misreading in the other direction.
        /// Where the walk stopped is known at the site that stops it.
        func cancelled() -> DiagnosticReport {
            report(.cancelled(afterSteps: steps.count))
        }
        /// Hands a finished step to the observer and gives it back, so the
        /// publish and the append read as one expression at every site.
        ///
        /// Shaped as "publish, then return" rather than as a function that
        /// appends: a nested function capturing `steps` and awaiting inside it
        /// is sending a mutable local across a suspension, which Swift 6
        /// refuses — correctly, since the observer it awaits is `@Sendable`
        /// and could be anything.
        func published(_ step: DiagnosticStep) async -> DiagnosticStep {
            await onStep(step)
            return step
        }

        guard !Task.isCancelled else { return cancelled() }
        let (resolveStep, addresses) = await resolve(endpoint)
        guard !Task.isCancelled else { return cancelled() }
        steps.append(await published(resolveStep))

        // A step outside the scope produces NO row, rather than a `skipped`
        // one. `skipped` already means "asked for, and could not be measured"
        // — the ping with no address to probe — and a scoped report whose
        // unasked-for steps arrived under the same label would put "you did
        // not ask for this" and "this could not be answered" in one column of
        // a text somebody pastes into an issue. What the report says instead
        // is which scope it was: one line, once, in the header.
        if scope.runs(.tcp) {
            guard !Task.isCancelled else { return cancelled() }
            let tcpStep = await ping(addresses, port: endpoint.port)
            guard !Task.isCancelled else { return cancelled() }
            steps.append(await published(tcpStep))
        }

        if scope.runs(.icmp) {
            guard !Task.isCancelled else { return cancelled() }
            let icmpStep = await echo(addresses)
            guard !Task.isCancelled else { return cancelled() }
            steps.append(await published(icmpStep))
        }

        if scope.runs(.dial), let dial = descriptor.dial {
            guard !Task.isCancelled else { return cancelled() }
            let step = await bounded(dial)
            guard !Task.isCancelled else { return cancelled() }
            steps.append(await published(step))
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
            guard !Task.isCancelled else { return cancelled() }
            let traceStep = await trace(addresses)
            guard !Task.isCancelled else { return cancelled() }
            steps.append(await published(traceStep))
        }

        if scope.runs(.contributions) {
            for contribution in descriptor.diagnostics {
                guard !Task.isCancelled else { return cancelled() }
                let step = await bounded(contribution)
                guard !Task.isCancelled else { return cancelled() }
                steps.append(await published(step))
            }
        }
        return report(.complete)
    }

    // MARK: - The universal steps

    private func resolve(_ endpoint: Endpoint) async -> (DiagnosticStep, [ResolvedAddress]) {
        let timer = Self.timer(for: DiagnosticStepID.resolve)
        let outcome = await HostResolver.resolve(
            host: endpoint.host, port: endpoint.port, timeout: stepTimeout)
        switch outcome {
        case .resolved(let addresses):
            let detail = addresses
                .map { "\($0.family.rawValue) \($0.text)" }
                .joined(separator: ", ")
            return (timer.finish(.ok, detail), addresses)
        case .failed(let reason):
            return (timer.finish(.failed(reason), ""), [])
        case .timedOut:
            return (timer.finish(.timedOut, ""), [])
        }
    }

    private func ping(_ addresses: [ResolvedAddress], port: Int) async -> DiagnosticStep {
        let timer = Self.timer(for: DiagnosticStepID.tcp)
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
    private func echo(_ addresses: [ResolvedAddress]) async -> DiagnosticStep {
        let timer = Self.timer(for: DiagnosticStepID.icmp)
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
    private func trace(_ addresses: [ResolvedAddress]) async -> DiagnosticStep {
        let timer = Self.timer(for: DiagnosticStepID.trace)
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
    /// three of the four need the destination the walk was aimed at, which
    /// the hop does not carry — the same reason `reachedDestination` lives on
    /// the outcome. `destination` means what it means there: the answering
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
    private func bounded(_ contribution: DiagnosticContribution) async -> DiagnosticStep {
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

    private static func timer(for id: String) -> DiagnosticStepTimer {
        DiagnosticStepTimer(id: id, titleKey: DiagnosticStepID.titleKey(for: id))
    }
}
