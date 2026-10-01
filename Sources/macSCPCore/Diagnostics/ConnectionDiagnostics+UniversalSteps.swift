// The steps every walk measures — the resolve, the TCP connection attempt, the
// ICMP echo and the network trace — each run both directly and, with its own
// step id, through a jump host. Split out of `ConnectionDiagnostics.swift` on
// 2026-10-01 with its text unchanged.

extension ConnectionDiagnostics {
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
    func resolve(
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

    func ping(
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
    func echo(
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
    func trace(
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
}
