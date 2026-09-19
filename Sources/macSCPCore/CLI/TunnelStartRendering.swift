import Foundation

/// One line of what `macscp-cli tunnels start` prints while a forwarding is
/// held open: the state the runner just published, rendered for a person or
/// for `jq`.
///
/// No delta is computed here, and none is needed: `TunnelRunner` publishes
/// only states that actually CHANGED (`apply(_:)` compares before it
/// yields), so one line per element of `TunnelRunner.states` is already one
/// line per change — including the connection count climbing and falling
/// while the tunnel stays `active`.
///
/// Lives in Core rather than in `Sources/MacSCPCLI` for the reason
/// `CLIErrorMapping` states about itself: the command-line target is an
/// executable with no test target, so what decides the words a user reads
/// has to sit where a test can call it. The command's own file keeps the
/// wiring — the dial, the runner, the signal source, the process exit.
public enum TunnelStateLine {
    /// The name a `--json` consumer switches on. Spelled as the Swift case
    /// is, `needsConfirmation` and all, for the reason
    /// `DiagnoseRendering.outcomeKey` gives: a script's own enum can then
    /// mirror this one verbatim, where the column below is written for a
    /// person and says `needs confirmation`.
    private static func key(_ state: TunnelState) -> String {
        switch state {
        case .stopped: return "stopped"
        case .connecting: return "connecting"
        case .active: return "active"
        case .reconnecting: return "reconnecting"
        case .failed: return "failed"
        case .needsConfirmation: return "needsConfirmation"
        }
    }

    /// The line for one published state.
    ///
    /// - Parameters:
    ///   - port: the port the forward actually bound (`TunnelRunner
    ///     .boundPort`), or `nil` where nothing is bound. Rendered only on
    ///     the `active` line, because that is the only state where a bound
    ///     port exists — a remote forward's is the SERVER's port and is the
    ///     news a profile configured on port 0 was waiting for.
    ///   - reason: the English sentence of a `failed` state's failure
    ///     (`TunnelRunner.failureReason`), or `nil` to use the kind's own
    ///     sentence (`TunnelFailureKind.sentence`). Read only for `failed`.
    ///     The JSON form also carries `reasonIsGeneric`, which is `true`
    ///     exactly when this is `nil` — the runner held no sentence and the
    ///     line fell back to the kind's summary — and `false` whenever the
    ///     runner supplied one, even one whose text equals the kind's
    ///     sentence (coordinator ruling, 2026-09-18). A runner sentence is
    ///     the failure's own: for `portInUse`, `bindAddressUnavailable` and
    ///     `bindPermissionDenied` it IS the kind's sentence, and it names the
    ///     port, or the address and the errno.
    ///   - json: one JSON object instead of one column line. The two carry
    ///     the same facts; only `failed`'s reason differs in placement,
    ///     since the text form puts that sentence on stderr (where a person
    ///     reads it) and the JSON form carries it in the object (where a
    ///     script does) alongside `reasonIsGeneric`.
    public static func render(
        _ state: TunnelState, port: Int? = nil, reason: String? = nil, json: Bool
    ) -> String {
        json ? jsonLine(state, port: port, reason: reason) : textLine(state, port: port)
    }

    private static func textLine(_ state: TunnelState, port: Int?) -> String {
        switch state {
        case .stopped, .connecting, .failed:
            return key(state)
        case .needsConfirmation:
            return "needs confirmation"
        case .active(let connections, let failed, _):
            var line = "active"
            if let port { line += " port=\(port)" }
            if connections > 0 { line += " connections=\(connections)" }
            // A connection the forward could not carry is published as a
            // new `active` state; without the count its line would repeat
            // the previous one. The kind stays out: this is not a failure
            // of the tunnel, and the diagnostic log has the sentence.
            if failed > 0 { line += " failed=\(failed)" }
            // And once the last three in a row failed, the word for what
            // the count now means: up, and carrying nothing
            // (`TunnelState.isDegraded`, maintainer answer 2026-09-19). A
            // word rather than a threshold a script has to know, and the
            // same fact the `--json` form's `degraded` carries.
            if state.isDegraded { line += " degraded" }
            return line
        case .reconnecting(let attempt):
            return "reconnecting attempt=\(attempt)"
        }
    }

    private static func jsonLine(_ state: TunnelState, port: Int?, reason: String?) -> String {
        var object: [String: Any] = ["state": key(state)]
        switch state {
        case .stopped, .connecting, .needsConfirmation:
            break
        case .active(let connections, let failed, _):
            object["connections"] = connections
            if let port { object["port"] = port }
            if failed > 0 { object["failedConnections"] = failed }
            // An ADDED key, never a renamed one: a script reading
            // `failedConnections` goes on reading it, and one that wants
            // the app's own "this forwarding stopped reading healthy"
            // answer reads this instead of re-deriving the threshold.
            // Written only when true, like the count above it.
            if state.isDegraded { object["degraded"] = true }
        case .reconnecting(let attempt):
            object["attempt"] = attempt
        case .failed(let kind):
            // The fallback is decided here, where it happens, and the flag
            // records that decision — never a comparison of the two strings
            // afterwards, which read a runner sentence that equals the
            // kind's (a port in use, an address this machine lacks) as a
            // summary with nothing more to offer.
            if let reason {
                object["reason"] = reason
                object["reasonIsGeneric"] = false
            } else {
                object["reason"] = kind.sentence
                object["reasonIsGeneric"] = true
            }
        }
        // `.sortedKeys` so the line a script diffs is stable run to run;
        // JSON objects are unordered, so nothing about the shape depends on
        // it. The fallback cannot be reached — every value above is a
        // `String` or an `Int` — and is a bare object rather than a `try!`
        // for the reason `OutputFormatter.print(json:)` gives about its own
        // silence: a hypothetical future mistake should not crash a tunnel
        // that is up.
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]),
            let line = String(data: data, encoding: .utf8)
        else {
            return #"{"state":"\#(key(state))"}"#
        }
        return line
    }
}

/// How a `tunnels start` run ends: the process exit code, and the sentence
/// that goes to stderr on the way out.
///
/// Three states end a run and three do not, which is what makes `code(for:)`
/// optional: the command's loop prints every state and leaves on the first
/// one that answers.
public enum TunnelExit {
    /// The exit code a state earns on its own, or `nil` for a state the run
    /// continues through.
    ///
    /// - `stopped` is `success`: it is published by `TunnelRunner.stop()`,
    ///   which this command calls only because a signal asked it to.
    /// - `failed` is `connection` (13) — the design's code for a forwarding
    ///   that could not be held open.
    /// - `needsConfirmation` is `hostKeyUnknown` (11), the commoner of the
    ///   two things `TunnelRunner.needsAPerson` collects. The other, a
    ///   session with no stored secret, is told apart only by the dial's own
    ///   error — see `code(for:dialFailure:)`.
    public static func code(for state: TunnelState) -> CLIExitCode? {
        switch state {
        case .connecting, .active, .reconnecting: return nil
        case .stopped: return .success
        case .failed: return .connection
        case .needsConfirmation: return .hostKeyUnknown
        }
    }

    /// The four codes a dial's own error may contribute. A mapping written
    /// for file operations can answer `remote` (14) or `conflict` (15) —
    /// true of the error, and a statement about a path this command never
    /// touched — so anything outside this set leaves the state answering.
    ///
    /// The set is what makes 10 and 12 reachable at all: `auth` for a
    /// session with no secret behind a `needsConfirmation`, `hostKeyMismatch`
    /// for the hard stop that reaches `failed`.
    private static let codesADialCanContribute: Set<CLIExitCode> = [
        .auth, .hostKeyUnknown, .hostKeyMismatch, .connection,
    ]

    /// The same, refined by what the dial's own error mapped to through
    /// `CLIErrorMapping.exitCode(for:)`.
    ///
    /// A clean `stopped` is never refined: the user asked for the teardown,
    /// and a dial that failed during an earlier reconnect does not turn a
    /// requested stop into a failure.
    public static func code(
        for state: TunnelState, dialFailure: CLIExitCode?
    ) -> CLIExitCode? {
        guard let own = code(for: state) else { return nil }
        guard own != .success, let dialFailure,
              codesADialCanContribute.contains(dialFailure)
        else { return own }
        return dialFailure
    }

    /// What goes to stderr when the run ends, or `nil` where there is
    /// nothing to say.
    ///
    /// A `failed` keeps the runner's OWN reason — `reason`, which is
    /// `TunnelRunner.failureReason`: `DialSupport.reason(for:)` mapped the
    /// very error the dial threw, and it is the sentence the `reason=` of the
    /// diagnostic log line carries, so the two cannot disagree about the
    /// same failure. Without one, the kind's own English sentence
    /// (`TunnelFailureKind.sentence`). A `needsConfirmation` prefers
    /// `dialMessage` (`CLIErrorMapping.message(for:)`'s own sentence, prefix
    /// included) because the state alone cannot tell an unknown host key
    /// from a missing secret.
    ///
    /// The sentence written here when `dialMessage` is `nil` is a DEFENSIVE
    /// DEFAULT, not a case the command reaches today: `needsConfirmation` is
    /// published only for the two errors `TunnelRunner.needsAPerson`
    /// collects, both of them thrown by the dial, so the command's record
    /// always holds one by the time this is asked (counted 2026-09-06
    /// against `TunnelRunner.attempt(decider:isRetry:)` — the dial and the
    /// runtime start are its two throwing steps, and no `TunnelFailure` the
    /// second raises is a `needsAPerson`). It stays because a state with no
    /// sentence at all would exit 11 in silence, and because a second
    /// caller — a tunnel started with no record to consult — is a plausible
    /// thing to write. `anUnexplainedConfirmationNamesTheHostKeyAndTheFlag`
    /// is what pins the wording.
    public static func note(
        for state: TunnelState, dialMessage: String? = nil, reason: String? = nil
    ) -> String? {
        switch state {
        case .stopped, .connecting, .active, .reconnecting:
            return nil
        case .failed(let kind):
            return "Error: \(reason ?? kind.sentence)"
        case .needsConfirmation:
            return dialMessage ?? "Error: host key unknown; rerun with --accept-new"
        }
    }
}
