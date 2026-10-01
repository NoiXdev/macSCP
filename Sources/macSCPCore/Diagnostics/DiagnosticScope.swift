// Which steps a diagnosis run is asked to measure. Split out of
// `ConnectionDiagnostics.swift` on 2026-10-01 with its text unchanged.

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
