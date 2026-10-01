import Foundation

// The three steps of a jump walk that are measured ON the jump host rather
// than through it: the jump host's name resolution of the target, its ping,
// and its trace — each a command run there over an `exec` channel on the
// connection `jump.dial` opened (Task 7 of the 2026-09-18 jump-and-groups
// plan). Everything a command line is built from lives in
// `JumpProbeCommand.swift`, and everything its output is read into in
// `JumpProbeReading.swift` — both split out of this file on 2026-10-01 — so
// the rule for all three is stated once, here, beside the steps that run
// them.
//
// **When a command runs at all.** Only inside a diagnosis the user started:
// these steps are entries in `ConnectionDiagnostics.targetHalf`, walked by
// `run(scope:observer:)` and nothing else, and only once the jump was
// reached.
//
// **What reaches the jump host's shell.** A fixed tool and fixed options,
// then the target's host — validated first (`JumpProbeHost`), then passed as
// ONE single-quoted word (`PosixQuoting.singleQuoted`). A host that fails the
// check is refused before any channel opens, and the row says so.
//
// **What comes back into the report.** Only what a reader in
// `JumpProbeReading.swift` parsed out of standard output: IP literals, counts
// and round-trip times, each checked on the way in. The jump host's own words
// — a banner, an error, a forced command's message — reach no row; an output
// that does not parse is `unavailable`, and its detail names the exit status
// and nothing else. What does reach a row passes `DiagnosticStep.init`'s
// userinfo filter like every other row, and an error is rendered through
// `DialSupport.reason(for:)`, the report's one credential-free sentence per
// error.

// MARK: - The three steps

extension DiagnosticJumpStep {
    /// The jump host's own resolver, asked for the target's name.
    ///
    /// Beside `target.tcpViaJump` in the `.tcp` phase — so under `.ping` as
    /// well as `.complete` — because that step's one refusal,
    /// `jumpCouldNotConnect`, cannot say whether the name failed there or the
    /// port; this row can. `failed` only for the one answer that is a finding
    /// about the name, `getent`'s exit status 2. Nothing to salvage when the
    /// budget cuts it: a half-printed address table is no answer.
    static let resolveOnJump = DiagnosticJumpStep(
        id: DiagnosticStepID.targetResolveOnJump, phase: .tcp
    ) { context, timer in
        guard let host = JumpProbeHost(context.target.host) else {
            return timer.finish(.unavailable(DiagnosticReason.jumpProbeHostRefused), "")
        }
        guard host.kind == .name else {
            return timer.finish(.skipped(DiagnosticReason.targetIsAnAddress), "")
        }
        let output: RemoteCommandOutput
        switch await JumpProbeRun.run(.resolve(host), in: context) {
        case .answered(let answered): output = answered
        case .overran(let detail):
            return timer.finish(.unavailable(DiagnosticReason.jumpResolveUnreadable), detail)
        case .notRun(let detail):
            return timer.finish(.unavailable(DiagnosticReason.jumpExecRefused), detail)
        }
        if output.exitStatus == JumpProbeRun.commandNotFound {
            return timer.finish(.unavailable(DiagnosticReason.jumpHasNoGetent), "")
        }
        if output.exitStatus == 0,
            let addresses = JumpProbeReading.addresses(inGetentOutput: output.standardOutput)
        {
            let detail = addresses.map { "\($0.family.rawValue) \($0.text)" }
                .joined(separator: ", ")
            return timer.finish(.ok, detail)
        }
        // `getent`'s own status for "not found in the database". Only with
        // nothing printed: a status 2 above an answer is not that answer.
        if output.exitStatus == 2,
            output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return timer.finish(.failed(DiagnosticReason.jumpCouldNotResolve), "")
        }
        return timer.finish(
            .unavailable(DiagnosticReason.jumpResolveUnreadable),
            JumpProbeRun.exitDetail(.getent, output.exitStatus))
    }

    /// Echo requests from the jump host until a deadline inside the step
    /// budget (`JumpProbeCommand.pingDeadlineSeconds(budget:)`): `-w`
    /// first, and `-t` only when `-w` came back as a usage error — BSD's
    /// `ping`, which has no `-w` (`JumpProbeCommand.PingDeadline`).
    ///
    /// Chosen by trying rather than by asking the jump host what it runs:
    /// the tool's own answer is the one thing that says which options it
    /// takes, a system name would not (a Linux jump host may run BusyBox's
    /// `ping` or iputils', and `uname` says nothing about which), and only a
    /// BSD jump host pays the second exec.
    ///
    /// Any reply is `ok` — the target answers from there, and a lost packet
    /// is in the detail as `2/3 replies`. Silence is `timedOut`, as the local
    /// echo reports it: a firewall that drops ICMP says nothing about whether
    /// the target serves. The detail line is the local echo's shape, with
    /// the tool's own figures. Cut by the budget, it reports the replies it
    /// had printed (`cut`).
    static let icmpFromJump = DiagnosticJumpStep(
        id: DiagnosticStepID.targetICMPFromJump, phase: .icmp,
        cut: { context, timer in
            guard let (tool, printed) = context.transcript.current, tool == .ping,
                let host = JumpProbeHost(context.target.host)
            else { return timer.finish(.timedOut, "") }
            if let summary = JumpProbeReading.ping(printed) {
                return JumpProbeRun.pingRow(summary, host: host, timer: timer)
            }
            guard let partial = JumpProbeReading.pingReplies(inPartialOutput: printed),
                !partial.replies.isEmpty
            else { return timer.finish(.timedOut, "") }
            let times = partial.replies
            let average = times.reduce(Duration.zero, +) / times.count
            return timer.finish(
                .ok,
                "\(partial.address ?? host.text) \(times.count) replies before the step's "
                    + "budget ran out, min \(DurationText.milliseconds(times.min() ?? .zero)), "
                    + "avg \(DurationText.milliseconds(average)), "
                    + "max \(DurationText.milliseconds(times.max() ?? .zero))")
        }
    ) { context, timer in
        guard let host = JumpProbeHost(context.target.host) else {
            return timer.finish(.unavailable(DiagnosticReason.jumpProbeHostRefused), "")
        }
        let seconds = JumpProbeCommand.pingDeadlineSeconds(budget: context.budget)
        var output = RemoteCommandOutput(standardOutput: "", exitStatus: 0)
        for flag in [JumpProbeCommand.PingDeadline.w, .t] {
            let command = JumpProbeCommand.ping(host, deadlineSeconds: seconds, flag: flag)
            switch await JumpProbeRun.run(command, in: context) {
            case .answered(let answered): output = answered
            case .overran(let detail):
                return timer.finish(.unavailable(DiagnosticReason.jumpPingUnreadable), detail)
            case .notRun(let detail):
                return timer.finish(.unavailable(DiagnosticReason.jumpExecRefused), detail)
            }
            let refusedTheOption =
                output.exitStatus == JumpProbeCommand.usageExitStatus
                && output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            if !refusedTheOption { break }
        }
        if output.exitStatus == JumpProbeRun.commandNotFound {
            return timer.finish(.unavailable(DiagnosticReason.jumpHasNoPing), "")
        }
        guard let summary = JumpProbeReading.ping(output.standardOutput) else {
            return timer.finish(
                .unavailable(DiagnosticReason.jumpPingUnreadable),
                JumpProbeRun.exitDetail(.ping, output.exitStatus))
        }
        return JumpProbeRun.pingRow(summary, host: host, timer: timer)
    }

    /// The path from the jump host to the target: `traceroute`, limited to
    /// the hops its budget can hold (`JumpProbeCommand
    /// .tracerouteMaxHops(budget:)`), and `tracepath` when `traceroute` is
    /// missing or gave no answer this can read. Raced against the TRACE
    /// budget (`Budget.trace`), as `jump.trace` is. Its row is
    /// `jump.trace`'s: the same outcome rules, the same hop table and
    /// markers (`ConnectionDiagnostics.traceOutcome`, `traceTable`,
    /// `traceDetail`), and a first detail line naming the tool. Cut by the
    /// budget, it reports the hops it had printed, marked as stopped by the
    /// budget (`cut`).
    ///
    /// In the `.trace` phase — so the `.trace` scope now dials the jump
    /// host, where before it measured only from this Mac
    /// (`ConnectionDiagnostics.needsJumpConnection(_:)`).
    static let traceFromJump = DiagnosticJumpStep(
        id: DiagnosticStepID.targetTraceFromJump, phase: .trace, budget: .trace,
        cut: { context, timer in
            guard let (tool, printed) = context.transcript.current,
                let host = JumpProbeHost(context.target.host),
                let outcome = JumpProbeRun.readTrace(
                    printed, by: tool, target: host,
                    maxHops: JumpProbeCommand.tracerouteMaxHops(budget: context.budget),
                    completion: .cut)
            else { return timer.finish(.timedOut, "") }
            return JumpProbeRun.traceRow(outcome, by: tool, timer: timer)
        }
    ) { context, timer in
        guard let host = JumpProbeHost(context.target.host) else {
            return timer.finish(.unavailable(DiagnosticReason.jumpProbeHostRefused), "")
        }
        var attempts: [String] = []
        var anyToolThere = false
        let maxHops = JumpProbeCommand.tracerouteMaxHops(budget: context.budget)
        for command in [JumpProbeCommand.traceroute(host, maxHops: maxHops), .tracepath(host)] {
            let output: RemoteCommandOutput
            switch await JumpProbeRun.run(command, in: context) {
            case .answered(let answered): output = answered
            case .overran(let detail):
                // A tool that printed too much is a tool that is there.
                anyToolThere = true
                attempts.append(detail)
                continue
            case .notRun(let detail):
                // A jump host that runs no command runs neither.
                return timer.finish(.unavailable(DiagnosticReason.jumpExecRefused), detail)
            }
            if let outcome = JumpProbeRun.readTrace(
                output.standardOutput, by: command.tool, target: host, maxHops: maxHops,
                completion: .exited(output.exitStatus))
            {
                return JumpProbeRun.traceRow(outcome, by: command.tool, timer: timer)
            }
            if output.exitStatus != JumpProbeRun.commandNotFound { anyToolThere = true }
            attempts.append(JumpProbeRun.exitDetail(command.tool, output.exitStatus))
        }
        return timer.finish(
            .unavailable(
                anyToolThere
                    ? DiagnosticReason.jumpTraceUnreadable : DiagnosticReason.jumpHasNoTraceTool),
            attempts.joined(separator: "; "))
    }
}

/// Running one probe command over the jump connection, what its failure to
/// answer means for a row, and the rows two steps share between finishing
/// and being cut — stated once for the three steps above.
private enum JumpProbeRun {
    /// POSIX shells' exit status for a command they could not find, whatever
    /// their wording (`ChecksumCommandExitFailure` measures the same).
    static let commandNotFound = 127

    /// What running a command came to, each with the detail its row
    /// carries.
    enum Result {
        /// The command ran; its output and exit status are there to read.
        case answered(RemoteCommandOutput)
        /// The command ran and printed past `JumpProbeCommand
        /// .maxStandardOutputBytes`: the tool is there, and gave no answer
        /// this can read. The step's own "unreadable" reason.
        case overran(String)
        /// The jump host did not run it — it refused the channel or the
        /// `exec` request, or the connection failed under it.
        /// `jumpExecRefused`, and not the tool's fault or the target's.
        ///
        /// The payload names the tool either way, and says what the refusal
        /// was only when this project has a sentence for it; `run`'s catch
        /// arm carries the argument.
        case notRun(String)
    }

    /// Runs `command` over the step's connection, its output going into the
    /// step's transcript as it arrives.
    static func run(
        _ command: JumpProbeCommand, in context: DiagnosticJumpStep.Context
    ) async -> Result {
        context.transcript.begin(command.tool)
        do {
            return .answered(try await context.connection.run(command, into: context.transcript))
        } catch is RemoteCommandOutputTooLarge {
            return .overran(
                "\(command.tool.rawValue) printed more than "
                    + "\(JumpProbeCommand.maxStandardOutputBytes) bytes")
        } catch {
            // The row's REASON already says the jump host did not run the
            // command (`DiagnosticReason.jumpExecRefused`); the detail's job
            // is to say WHICH command, and why. Until 2026-09-27 it said
            // neither: Citadel's `channelFailure` conforms to no
            // `LocalizedError`, so `DialSupport.reason(for:)`'s default arm
            // rendered it as "The operation couldn't be completed.
            // (Citadel.CitadelError error N.)" — safe, and a case index
            // (`docs/BACKLOG.md`, "The jump plan's deferred minors: the
            // jump-host probes").
            //
            // The tool is named from `command`, never from the error. The
            // transport's sentence is appended only when `DialSupport` WROTE
            // one, which its default arm tells us by returning exactly
            // `localizedDescription`: a reason that differs from it came out
            // of an arm somebody wrote here and is worth carrying.
            //
            // What the comparison guarantees, exactly: THIS error's own
            // `localizedDescription` is read here and kept nowhere — nothing
            // on this path renders, logs or returns that string. It does NOT
            // guarantee that the reason it lets through carries no foreign
            // text at all. Five arms of `DialSupport.reason(for:)` return a
            // `TunnelFailure` payload rather than a sentence of their own —
            // `bindFailed`, `channelOpenFailed`, `connectFailed`, `pumpFailed`
            // and `remoteBindRefused`, counted 2026-09-27 against that
            // function's switch — and several of the throw sites build that
            // payload out of `DialSupport.reason(for:)` itself (its own
            // counted comment enumerates them), so a foreign error's
            // description could arrive nested one level down and differ from
            // the `localizedDescription` compared here. None of the five can
            // be thrown by an SSH `exec`, which is the only thing this
            // function runs, so none reaches this line today; a caller that
            // ran something else through here would need that checked again.
            let reason = DialSupport.reason(for: error)
            guard reason != (error as NSError).localizedDescription else {
                return .notRun(
                    "the jump host refused to run \(command.tool.rawValue) "
                        + "and gave no reason of its own")
            }
            return .notRun("\(command.tool.rawValue): \(reason)")
        }
    }

    static func exitDetail(_ tool: JumpProbeCommand.Tool, _ status: Int) -> String {
        "\(tool.rawValue) exited with status \(status)"
    }

    /// A ping's row from its statistics: `ok` on any reply, `timedOut` on
    /// none.
    static func pingRow(
        _ summary: JumpPingSummary, host: JumpProbeHost, timer: DiagnosticStepTimer
    ) -> DiagnosticStep {
        var detail = "\(summary.address ?? host.text) \(summary.received)/\(summary.sent) replies"
        if let low = summary.min, let average = summary.average, let high = summary.max {
            detail += ", min \(DurationText.milliseconds(low))"
                + ", avg \(DurationText.milliseconds(average))"
                + ", max \(DurationText.milliseconds(high))"
        }
        return timer.finish(summary.received > 0 ? .ok : .timedOut, detail)
    }

    /// The trace tool's output read by its own reader; `nil` for a tool that
    /// is not a trace tool.
    static func readTrace(
        _ output: String, by tool: JumpProbeCommand.Tool, target: JumpProbeHost,
        maxHops: Int, completion: JumpProbeCompletion
    ) -> NetworkTraceOutcome? {
        switch tool {
        case .traceroute:
            return JumpProbeReading.traceroute(
                output, target: target, maxHops: maxHops, completion: completion)
        case .tracepath:
            return JumpProbeReading.tracepath(output, target: target, completion: completion)
        case .getent, .ping:
            return nil
        }
    }

    /// A trace's row, `jump.trace`'s own shape, with the tool named first.
    static func traceRow(
        _ outcome: NetworkTraceOutcome, by tool: JumpProbeCommand.Tool,
        timer: DiagnosticStepTimer
    ) -> DiagnosticStep {
        let marker = ConnectionDiagnostics.traceDetail(outcome)
        let detail = (["measured with \(tool.rawValue)"] + [marker])
            .filter { !$0.isEmpty }.joined(separator: "; ")
        return timer.finish(
            ConnectionDiagnostics.traceOutcome(outcome), detail,
            table: ConnectionDiagnostics.traceTable(outcome))
    }
}
