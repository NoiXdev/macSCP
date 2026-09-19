import Foundation

/// What `macscp-cli diagnose --scope throughput` does with Ctrl-C — the one
/// scope that writes to the user's server, and so the one whose cleanup a
/// signal must not skip.
///
/// Without this, SIGINT and SIGTERM took their default disposition and ended
/// the process mid-transfer: the test file stayed on the server, its removal
/// never ran, and nothing named it (Task 2 fix round 1 of the 2026-09-19
/// plan, I2). The command now hands its signals to `drive` as
/// `TunnelStartCommand.interrupts()`'s stream — the same handler `tunnels
/// start` installs, not a second one.
///
/// In Core, not in the command's own file, for the reason
/// `TunnelForegroundRun` gives: the command-line target has no test target,
/// and the ordering here is what a reader wants measured.
public enum DiagnoseForegroundRun {
    /// How a run ended.
    public enum Ending: Sendable {
        /// The diagnosis returned its report — on its own, or after the first
        /// signal cancelled it and its cleanup ran.
        case finished(DiagnosticReport)
        /// A second signal arrived while the first one's cancellation was
        /// still running, and the run left without its report.
        case abandoned
    }

    private enum Event: Sendable {
        case finished(DiagnosticReport)
        case abandon
    }

    /// Runs `diagnosis` until it returns or a signal ends it.
    ///
    /// **Two signals mean two different things**, as they do for `tunnels
    /// start` (`TunnelForegroundRun.drive`). The first CANCELS the diagnosis
    /// and waits for it: the walk's cleanup runs — the throughput test's
    /// removal, out of the cancellation's reach and under its own backstop
    /// (`ThroughputProbe.remove`) — and the report it hands back, which
    /// names the file if the removal did not confirm, is what the command
    /// prints. The second leaves at once, so a removal stuck on a server
    /// that stopped answering cannot trap a person in their terminal. The
    /// signal stream is consumed throughout, which is what lets the second
    /// element arrive at all.
    public static func drive(
        stops: AsyncStream<Void>,
        _ diagnosis: @escaping @Sendable () async -> DiagnosticReport
    ) async -> Ending {
        let (events, publish) = AsyncStream.makeStream(of: Event.self)
        let run = Task { publish.yield(.finished(await diagnosis())) }
        let signals = Task {
            var seen = 0
            for await _ in stops {
                seen += 1
                guard seen == 1 else {
                    publish.yield(.abandon)
                    return
                }
                run.cancel()
            }
        }
        defer { signals.cancel() }
        for await event in events {
            switch event {
            case .finished(let report): return .finished(report)
            case .abandon: return .abandoned
            }
        }
        // `events` never finishes without an element — both producers yield
        // before they end — but a loop over a stream has to say what its end
        // means, and a run that said nothing is one that was abandoned.
        return .abandoned
    }

    /// The line for standard error when the run's test file may remain on
    /// the server, or `nil` when it was removed — or never written.
    ///
    /// A finished run says so in its throughput row
    /// (`ThroughputProbe.mayHaveLeftAFile(_:)`), which the rows already
    /// printed; this repeats it where a script's stdout parser does not
    /// swallow it. An abandoned run said nothing, and whether its file was
    /// ever written is not known here — so the line is hedged, and names
    /// the file the run was given (`DiagnosticThroughputSettings.fileName`).
    public static func leftoverNote(for ending: Ending, fileName: String) -> String? {
        switch ending {
        case .finished(let report):
            guard report.steps.contains(where: ThroughputProbe.mayHaveLeftAFile) else {
                return nil
            }
            return "note: the throughput test file \(fileName) may remain in the "
                + "session's start folder; its removal was not confirmed"
        case .abandoned:
            return "note: the run was left before its cleanup finished; the throughput "
                + "test file \(fileName) may remain in the session's start folder"
        }
    }

    /// The exit an ending earns.
    ///
    /// A finished run — interrupted or not — exits by its report, as every
    /// diagnosis does (`DiagnoseRendering.exitCode(for:)`): 0 when the rows
    /// it kept are ok, 16 when one failed, and a row that says the file may
    /// remain is a failed one. That is `tunnels start`'s rule for a signal
    /// too: the person asked for the run to end, it ended, and the signal is
    /// not itself a failure — never 130, the shell's code for a process the
    /// signal KILLED.
    ///
    /// An abandoned run is the one departure from that rule. `tunnels
    /// start` exits 0 when abandoned, because its tunnel ended either way;
    /// this run's removal did not confirm, and a file of this app's may be
    /// on the user's server, which is the thing 16 exists to say.
    public static func exitCode(for ending: Ending) -> CLIExitCode {
        switch ending {
        case .finished(let report): return DiagnoseRendering.exitCode(for: report)
        case .abandoned: return .diagnosis
        }
    }
}
