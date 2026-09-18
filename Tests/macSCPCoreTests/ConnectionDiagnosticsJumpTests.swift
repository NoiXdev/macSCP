import Foundation
import Synchronization
import Testing

@testable import macSCPCore

/// A session behind a jump host is diagnosed through the jump: the jump is
/// checked first, from this Mac, and the target is reached THROUGH it
/// (2026-09-18, the New-features row "Diagnostics ignore the jump host").
///
/// **What is real and what is injected.** The jump's resolve, TCP ping, echo
/// and trace are the universal probes, pointed at a loopback socket this
/// suite owns — the only packets these cases send. The jump's dial, the
/// channel open through it and the target's dial are the seam
/// (`DiagnosticJumpDialer`): a fake that records what was asked of it and
/// whether the connection it handed out was closed. The rig case at the end
/// (`ConnectionDiagnosticsJumpRigTests`) runs the real dials.
///
/// No case waits on a clock: a dial that has to be in flight is parked on an
/// `AsyncSignal` and released by the case.
@Suite("ConnectionDiagnostics through a jump host")
struct ConnectionDiagnosticsJumpTests {
    /// The jump's secret in the cases that give it one. Named, and never
    /// written into an expectation: `#expect` prints the source text of what
    /// it checks (CLAUDE.md, "A value a test must not leak has two exits").
    private static let jumpSecret = "diagnostics-jump-test-passphrase"

    /// The target, as the jump would reach it. A reserved name (RFC 2606):
    /// nothing here resolves it — the fake dials never leave the process.
    private static let targetHost = "target.invalid"
    private static let targetPort = 2222

    private static let everyJumpStep = [
        DiagnosticStepID.jumpResolve, DiagnosticStepID.jumpTCP, DiagnosticStepID.jumpICMP,
        DiagnosticStepID.jumpDial, DiagnosticStepID.jumpTrace,
        DiagnosticStepID.targetTCPViaJump, DiagnosticStepID.targetResolveOnJump,
        DiagnosticStepID.targetICMPFromJump, DiagnosticStepID.targetDialViaJump,
        DiagnosticStepID.targetTraceFromJump,
    ]

    /// The target's host as each probe on the jump host hands it over: one
    /// single-quoted argument.
    private static let quotedTarget = "'\(targetHost)'"

    // MARK: - The order

    @Test func aJumpSessionIsWalkedJumpFirstThenTheTargetThroughIt() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        let log = RunEvents()

        let report = await Self.diagnostics(jumpPort: listener.port, rig: rig).run(
            scope: .complete,
            observer: DiagnosticRunObserver(
                onStepStarted: { id, _ in log.record("start \(id)") },
                onStep: { step in log.record("row \(step.id)") }))

        #expect(report.steps.map(\.id) == Self.everyJumpStep)
        #expect(report.steps.map(\.outcome) == Array(repeating: .ok, count: 10), """
            \(report.plainText())
            """)
        // The channel was opened to the TARGET, over the jump connection; the
        // three probes ran ON the jump host, each naming the target once,
        // quoted; and the target's dial carried the jump.
        #expect(rig.events == [
            "connect 127.0.0.1:\(listener.port)",
            "probe \(Self.targetHost):\(Self.targetPort)",
            "exec getent hosts \(Self.quotedTarget)",
            "exec ping -w 3 \(Self.quotedTarget)",
            "dialTarget \(Self.targetHost):\(Self.targetPort) via 127.0.0.1:\(listener.port)",
            "exec traceroute -n -q 1 -w 1 -m 17 \(Self.quotedTarget)",
            "disconnect",
        ])
        // Every step announced itself before its row, the jump's as much as
        // the universal ones.
        let expectedEvents = Self.everyJumpStep.flatMap { ["start \($0)", "row \($0)"] }
        #expect(log.events == expectedEvents)
        #expect(report.endpoint == Endpoint(host: Self.targetHost, port: Self.targetPort))
        #expect(report.jump == Endpoint(host: "127.0.0.1", port: listener.port))
    }

    /// Each scope, mapped onto both halves. The three the brief names —
    /// `.ping`, `.trace`, `.dial` — plus the two that were already there.
    ///
    /// `.ping` opens the jump connection even though it measures no login:
    /// `target.tcpViaJump` is how "is anything there" is asked of a target
    /// behind a bastion, and the channel it opens needs an authenticated
    /// connection to the jump. The dial row says so rather than the ping
    /// opening a connection nobody sees.
    @Test(arguments: DiagnosticScope.allCases)
    func eachScopeRunsItsStepsOnBothHalves(scope: DiagnosticScope) async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        let contributions = Ticker()

        let report = await Self.diagnostics(
            jumpPort: listener.port, rig: rig, contribution: contributions
        ).run(scope: scope)

        let expected: [String]
        switch scope {
        case .complete:
            expected = Self.everyJumpStep + [Self.contributionID]
        case .ping:
            expected = [
                DiagnosticStepID.jumpResolve, DiagnosticStepID.jumpTCP, DiagnosticStepID.jumpICMP,
                DiagnosticStepID.jumpDial, DiagnosticStepID.targetTCPViaJump,
                DiagnosticStepID.targetResolveOnJump, DiagnosticStepID.targetICMPFromJump,
            ]
        case .trace:
            // The trace from the jump host runs over the jump connection, so
            // `.trace` dials the jump too.
            expected = [
                DiagnosticStepID.jumpResolve, DiagnosticStepID.jumpDial,
                DiagnosticStepID.jumpTrace, DiagnosticStepID.targetTraceFromJump,
            ]
        case .dial:
            expected = [
                DiagnosticStepID.jumpResolve, DiagnosticStepID.jumpDial,
                DiagnosticStepID.targetDialViaJump,
            ]
        case .contributions:
            expected = [DiagnosticStepID.jumpResolve, Self.contributionID]
        }
        #expect(report.steps.map(\.id) == expected, "\(scope.rawValue): \(report.steps.map(\.id))")
        #expect(report.scope == scope)

        // A connection is opened exactly when a step needs one, and every one
        // that was opened was closed.
        let opensAConnection = expected.contains(DiagnosticStepID.jumpDial)
        #expect(rig.count("connect") == (opensAConnection ? 1 : 0))
        #expect(rig.count("disconnect") == rig.count("connect"))
        #expect(await contributions.count == (expected.contains(Self.contributionID) ? 1 : 0))
    }

    /// A session without a jump is the walk it always was, and never touches
    /// a jump dial.
    @Test func aSessionWithoutAJumpKeepsTheWalkItHad() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        var values = Self.targetValues()
        values[SSHField.host] = "127.0.0.1"
        values[SSHField.port] = String(listener.port)

        let report = await ConnectionDiagnostics(
            descriptor: Self.descriptor(dial: Self.okDial()), values: values, secrets: nil,
            jump: nil, jumpDialer: rig.dialer, appVersion: "test"
        ).run()

        #expect(report.steps.map(\.id) == [
            DiagnosticStepID.resolve, DiagnosticStepID.tcp, DiagnosticStepID.icmp,
            DiagnosticStepID.dial, DiagnosticStepID.trace,
        ])
        #expect(rig.events.isEmpty, "a walk without a jump dialled one: \(rig.events)")
        #expect(report.jump == nil)
        #expect(!report.plainText().contains("Jump host"))
    }

    // MARK: - The jump not reached

    /// Every way the jump can fail to be reached leaves every `target.` step
    /// `skipped` with a reason naming the jump — the target was not measured,
    /// and a row that said `failed` would be a finding about a machine
    /// nobody reached.
    @Test(arguments: JumpFailure.allCases)
    func whenTheJumpIsNotReachedEveryTargetStepIsSkippedNamingTheJump(
        failure: JumpFailure
    ) async throws {
        let listener = try #require(LoopbackSocket.listening())
        let closedPort = try #require(LoopbackSocket.closedPort())
        defer { listener.close() }
        let rig = JumpRig()
        var jump = Self.agentJump(port: listener.port)
        switch failure {
        case .jumpDialFails:
            rig.connectError = RemoteFSError.authenticationFailed
        case .jumpPortRefused:
            jump = Self.agentJump(port: closedPort)
        case .jumpUnresolvable:
            jump = .unresolvable()
        case .jumpSecretMissing:
            jump = DiagnosticJump(
                endpoint: Endpoint(host: "127.0.0.1", port: listener.port),
                login: .init(username: "testuser", authKind: .password, keyPath: nil),
                secret: { nil })
        }

        let report = await Self.diagnostics(jump: jump, rig: rig).run()

        let targetSteps = report.steps.filter { $0.id.hasPrefix("target.") }
        #expect(targetSteps.map(\.id) == [
            DiagnosticStepID.targetTCPViaJump, DiagnosticStepID.targetResolveOnJump,
            DiagnosticStepID.targetICMPFromJump, DiagnosticStepID.targetDialViaJump,
            DiagnosticStepID.targetTraceFromJump,
        ], "\(failure): \(report.steps.map(\.id))")
        for step in targetSteps {
            #expect(step.outcome == .skipped(DiagnosticReason.jumpNotReached), """
                \(failure): \(step.id) came back \(step.outcome)
                """)
        }
        // Nothing went through a jump that was not reached.
        #expect(rig.count("probe") == 0)
        #expect(rig.count("exec") == 0)
        #expect(rig.count("dialTarget") == 0)
        #expect(rig.count("disconnect") == rig.count("connect"), "\(failure): \(rig.events)")

        switch failure {
        case .jumpDialFails:
            let dial = try #require(report.steps.first { $0.id == DiagnosticStepID.jumpDial })
            #expect(dial.outcome == .failed(DialSupport.reason(for: RemoteFSError.authenticationFailed)))
        case .jumpPortRefused:
            let tcp = try #require(report.steps.first { $0.id == DiagnosticStepID.jumpTCP })
            #expect(tcp.outcome == .failed("refused"))
        case .jumpUnresolvable:
            #expect(report.steps.first?.id == DiagnosticStepID.jumpResolve)
            #expect(report.steps.first?.outcome == .unavailable(DiagnosticReason.jumpUnresolvable))
            #expect(rig.count("connect") == 0)
            #expect(report.jump == nil)
        case .jumpSecretMissing:
            let dial = try #require(report.steps.first { $0.id == DiagnosticStepID.jumpDial })
            #expect(dial.outcome == .skipped(DiagnosticReason.noJumpSecret))
            #expect(rig.count("connect") == 0)
        }
    }

    enum JumpFailure: String, CaseIterable, CustomTestStringConvertible {
        case jumpDialFails, jumpPortRefused, jumpUnresolvable, jumpSecretMissing
        var testDescription: String { rawValue }
    }

    /// A refused channel is the target's finding, not the jump's: the dial
    /// through the jump still runs, and the connection is still closed.
    @Test func aRefusedChannelIsReportedAndTheTargetDialStillRuns() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        rig.probeError = RemoteFSError.connectionFailed(reason: "refused")

        let report = await Self.diagnostics(jumpPort: listener.port, rig: rig).run()

        let tcp = try #require(report.steps.first { $0.id == DiagnosticStepID.targetTCPViaJump })
        #expect(tcp.outcome == .failed(DialSupport.reason(for: RemoteFSError.connectionFailed(reason: ""))))
        #expect(rig.count("dialTarget") == 1)
        #expect(rig.events.last == "disconnect")
    }

    // MARK: - The connection closed on every path

    /// Cancelled while the target's dial is in flight: the report stops
    /// there, and the jump connection is closed before `run` returns.
    // `.timeLimit` as a hang bound only (CLAUDE.md, "A wall-clock ceiling
    // in a test measures the runner"): nothing below asserts on elapsed
    // time, and a signal that is never raised must end the case rather
    // than the run.
    @Test(.timeLimit(.minutes(1)))
    func aCancelledWalkStillClosesTheJumpConnection() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        let release = AsyncSignal()
        rig.parkTargetDial(until: release)
        defer { release.signal() }
        let diagnostics = Self.diagnostics(jumpPort: listener.port, rig: rig, stepTimeout: .seconds(60))

        let task = Task { await diagnostics.run() }
        #expect(await rig.targetDialEntered.wait() == .signalled)
        task.cancel()
        let report = await task.value

        // Read before the park is released, so nothing the abandoned dial
        // does afterwards can make these true (CLAUDE.md, "Tests that watch
        // a defect heal").
        let closedBeforeReturn = rig.count("disconnect")
        #expect(closedBeforeReturn == 1, "\(rig.events)")
        #expect(report.completion == .cancelled(afterSteps: 8))
        #expect(report.steps.map(\.id) == Array(Self.everyJumpStep.prefix(8)))
    }

    /// The jump's dial loses its deadline, and its connection arrives after
    /// the walk has moved on: nobody is left to use it, so it is closed the
    /// moment it arrives rather than held open until the process exits.
    // `.timeLimit` as a hang bound only (CLAUDE.md, "A wall-clock ceiling
    // in a test measures the runner"): nothing below asserts on elapsed
    // time, and a signal that is never raised must end the case rather
    // than the run.
    @Test(.timeLimit(.minutes(1)))
    func aJumpConnectionThatArrivesAfterItsDeadlineIsClosed() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        let release = AsyncSignal()
        rig.parkJumpDial(until: release)

        let report = await Self.diagnostics(
            jumpPort: listener.port, rig: rig, stepTimeout: .milliseconds(200)
        ).run(scope: .dial)

        let dial = try #require(report.steps.first { $0.id == DiagnosticStepID.jumpDial })
        #expect(dial.outcome == .timedOut)
        #expect(report.steps.last?.outcome == .skipped(DiagnosticReason.jumpNotReached))
        // Snapshot before the late connection is let through.
        let closedBeforeArrival = rig.count("disconnect")
        #expect(closedBeforeArrival == 0)

        release.signal()
        #expect(await rig.disconnected.wait() == .signalled)
        #expect(rig.count("disconnect") == 1)
        #expect(rig.count("dialTarget") == 0)
    }

    // MARK: - The probes run on the jump host

    /// A jump host that runs no command — it refuses the channel or the
    /// `exec` request, as a bastion that only forwards does — leaves each of
    /// the three probes `unavailable`, and never `failed`: nothing was learnt
    /// about the target. The channel and the dial through the jump are
    /// measured as ever, and the trace does not try its second tool on a
    /// host that runs none.
    @Test func aProbeTheJumpHostWillNotRunIsUnavailableNeverAFailure() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        for tool in JumpProbeCommand.Tool.allCases {
            rig.answer(tool, with: .failure(RemoteFSError.connectionFailed(reason: "refused")))
        }

        let report = await Self.diagnostics(jumpPort: listener.port, rig: rig).run()

        #expect(Self.outcomes(of: report) == [
            DiagnosticStepID.targetTCPViaJump: .ok,
            DiagnosticStepID.targetResolveOnJump: .unavailable(DiagnosticReason.jumpExecRefused),
            DiagnosticStepID.targetICMPFromJump: .unavailable(DiagnosticReason.jumpExecRefused),
            DiagnosticStepID.targetDialViaJump: .ok,
            DiagnosticStepID.targetTraceFromJump: .unavailable(DiagnosticReason.jumpExecRefused),
        ])
        #expect(rig.count("exec") == 3, "\(rig.events)")
        #expect(rig.events.last == "disconnect")
    }

    /// Exit status 127 is the shell saying it found no such tool. The trace
    /// tries `tracepath` after `traceroute`, and names neither's absence
    /// until both are gone.
    @Test func aToolTheJumpHostDoesNotHaveIsUnavailable() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        for tool in JumpProbeCommand.Tool.allCases {
            rig.answer(tool, with: .output(RemoteCommandOutput(standardOutput: "", exitStatus: 127)))
        }

        let report = await Self.diagnostics(jumpPort: listener.port, rig: rig).run()

        #expect(Self.outcomes(of: report) == [
            DiagnosticStepID.targetTCPViaJump: .ok,
            DiagnosticStepID.targetResolveOnJump: .unavailable(DiagnosticReason.jumpHasNoGetent),
            DiagnosticStepID.targetICMPFromJump: .unavailable(DiagnosticReason.jumpHasNoPing),
            DiagnosticStepID.targetDialViaJump: .ok,
            DiagnosticStepID.targetTraceFromJump:
                .unavailable(DiagnosticReason.jumpHasNoTraceTool),
        ])
        #expect(rig.events.contains("exec tracepath -n \(Self.quotedTarget)"), "\(rig.events)")
    }

    /// The rig's own answer (`JumpProbeSamples`): BusyBox `traceroute` is
    /// there but not permitted for the login, and there is no `tracepath`.
    /// Unavailable, naming the exit status of each attempt in the detail.
    @Test func aTraceNeitherToolCouldAnswerIsUnavailableNamingBoth() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        rig.answer(.traceroute, with: .output(JumpProbeSamples.rigTracerouteAsTestuserOverSSH))
        rig.answer(.tracepath, with: .output(JumpProbeSamples.rigTracepathOverSSH))

        let report = await Self.diagnostics(jumpPort: listener.port, rig: rig).run(scope: .trace)

        let trace = try #require(
            report.steps.first { $0.id == DiagnosticStepID.targetTraceFromJump })
        #expect(trace.outcome == .unavailable(DiagnosticReason.jumpTraceUnreadable))
        #expect(trace.detail == "traceroute exited with status 1; tracepath exited with status 127")
        #expect(trace.table == nil)
    }

    /// `traceroute` missing, `tracepath` there: the trace is `tracepath`'s,
    /// and the row says which tool measured it.
    @Test func tracepathIsTriedWhenTracerouteIsMissing() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        rig.answer(.traceroute, with: .output(RemoteCommandOutput(standardOutput: "", exitStatus: 127)))
        rig.answer(.tracepath, with: .output(JumpProbeSamples.constructedTracepathReached))

        let report = await Self.diagnostics(jumpPort: listener.port, rig: rig).run(scope: .trace)

        let trace = try #require(
            report.steps.first { $0.id == DiagnosticStepID.targetTraceFromJump })
        #expect(trace.outcome == .ok, "\(trace.outcome.label)")
        #expect(trace.detail == "measured with tracepath")
        #expect(trace.table?.rows.count == 3)
    }

    /// Output that is not the tool's answer — a forced command's banner here,
    /// carrying a URL with userinfo and a secret — is `unavailable`, and none
    /// of it reaches the report: the probes keep addresses and numbers they
    /// read, never the jump host's words.
    @Test func outputThatDoesNotParseIsUnavailableAndNeverCopied() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        let secret = Self.jumpSecret
        let banner = RemoteCommandOutput(
            standardOutput: "Restricted. See https://ops:\(secret)@wiki.invalid/bastion\n",
            exitStatus: 0)
        for tool in JumpProbeCommand.Tool.allCases { rig.answer(tool, with: .output(banner)) }

        let report = await Self.diagnostics(jumpPort: listener.port, rig: rig).run()

        #expect(Self.outcomes(of: report) == [
            DiagnosticStepID.targetTCPViaJump: .ok,
            DiagnosticStepID.targetResolveOnJump:
                .unavailable(DiagnosticReason.jumpResolveUnreadable),
            DiagnosticStepID.targetICMPFromJump: .unavailable(DiagnosticReason.jumpPingUnreadable),
            DiagnosticStepID.targetDialViaJump: .ok,
            DiagnosticStepID.targetTraceFromJump:
                .unavailable(DiagnosticReason.jumpTraceUnreadable),
        ])
        let resolve = try #require(
            report.steps.first { $0.id == DiagnosticStepID.targetResolveOnJump })
        #expect(resolve.detail == "getent exited with status 0")
        let inPlainText = report.plainText().contains(secret)
        let inMarkdown = report.markdown().contains(secret)
        let bannerCopied = report.plainText().contains("wiki.invalid")
        #expect(inPlainText == false)
        #expect(inMarkdown == false)
        #expect(bannerCopied == false)
    }

    /// An answer past the byte bound is no answer — unreadable, not refused:
    /// the jump host did run the command.
    @Test func anAnswerPastTheBoundIsUnreadable() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        rig.answer(
            .ping,
            with: .failure(RemoteCommandOutputTooLarge(limit: JumpProbeCommand.maxStandardOutputBytes)))

        let report = await Self.diagnostics(jumpPort: listener.port, rig: rig).run(scope: .ping)

        let ping = try #require(report.steps.first { $0.id == DiagnosticStepID.targetICMPFromJump })
        #expect(ping.outcome == .unavailable(DiagnosticReason.jumpPingUnreadable))
    }

    /// A target host that is neither a host name nor an IP literal is refused
    /// before any channel opens: the three probes say so, no command reaches
    /// the jump host, and the steps that hand the host to no shell — the
    /// channel and the dial — run as ever.
    @Test(arguments: [
        "target.invalid;id", "$(id)", "`id`", "a'b", "a b", "-oProxyCommand=id", "a|b",
    ])
    func aHostileTargetHostIsRefusedBeforeAnyCommandRuns(host: String) async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        var values = Self.targetValues()
        values[SSHField.host] = host

        let report = await Self.diagnostics(
            jump: Self.agentJump(port: listener.port), rig: rig, values: values
        ).run()

        for id in [
            DiagnosticStepID.targetResolveOnJump, DiagnosticStepID.targetICMPFromJump,
            DiagnosticStepID.targetTraceFromJump,
        ] {
            let step = try #require(report.steps.first { $0.id == id })
            #expect(step.outcome == .unavailable(DiagnosticReason.jumpProbeHostRefused), """
                \(host.debugDescription): \(id) came back \(step.outcome)
                """)
        }
        #expect(rig.count("exec") == 0, "\(rig.events)")
        #expect(rig.count("probe") == 1)
    }

    /// `getent` exit status 2 is the jump host saying the name is not known
    /// there: a finding about the target, and the one probe answer that is
    /// `failed`.
    @Test func aNameTheJumpHostCannotResolveIsAFinding() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        rig.answer(.getent, with: .output(JumpProbeSamples.rigGetentMissing))

        let report = await Self.diagnostics(jumpPort: listener.port, rig: rig).run(scope: .ping)

        let resolve = try #require(
            report.steps.first { $0.id == DiagnosticStepID.targetResolveOnJump })
        #expect(resolve.outcome == .failed(DiagnosticReason.jumpCouldNotResolve))
    }

    /// The rows an ordinary answer produces, read from the rig's recorded
    /// output: the address the jump host resolved, and the ping's summary in
    /// the words the local echo's row uses.
    @Test func theProbesRowsCarryWhatTheToolsMeasured() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()

        let report = await Self.diagnostics(jumpPort: listener.port, rig: rig).run()

        let resolve = try #require(
            report.steps.first { $0.id == DiagnosticStepID.targetResolveOnJump })
        #expect(resolve.detail == "IPv4 172.20.0.2")
        let ping = try #require(report.steps.first { $0.id == DiagnosticStepID.targetICMPFromJump })
        #expect(ping.detail == "172.20.0.2 3/3 replies, min 0.0 ms, avg 0.2 ms, max 0.4 ms")
        let trace = try #require(
            report.steps.first { $0.id == DiagnosticStepID.targetTraceFromJump })
        #expect(trace.detail == "measured with traceroute")
        #expect(trace.table?.rows == [
            ["1", "172.20.0.2", "0.0 ms", DiagnosticTraceColumn.destination]
        ])
    }

    /// Silence is `timedOut`, as the local echo reports it: a firewall that
    /// drops ICMP says nothing about whether the target serves.
    @Test func aPingThatHeardNothingIsTimedOut() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        rig.answer(.ping, with: .output(JumpProbeSamples.rigPingSilent))

        let report = await Self.diagnostics(jumpPort: listener.port, rig: rig).run(scope: .ping)

        let ping = try #require(report.steps.first { $0.id == DiagnosticStepID.targetICMPFromJump })
        #expect(ping.outcome == .timedOut)
        #expect(ping.detail == "192.0.2.1 0/3 replies")
    }

    /// A target named by an address has no name to resolve on the jump host;
    /// the ping and the trace still run, with the address quoted.
    @Test func aTargetNamedByAnAddressHasNoNameToResolveThere() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        var values = Self.targetValues()
        values[SSHField.host] = "10.0.0.5"

        let report = await Self.diagnostics(
            jump: Self.agentJump(port: listener.port), rig: rig, values: values
        ).run()

        let resolve = try #require(
            report.steps.first { $0.id == DiagnosticStepID.targetResolveOnJump })
        #expect(resolve.outcome == .skipped(DiagnosticReason.targetIsAnAddress))
        #expect(rig.count("exec getent") == 0)
        #expect(rig.events.contains("exec ping -w 3 '10.0.0.5'"), "\(rig.events)")
        #expect(rig.events.contains("exec traceroute -n -q 1 -w 1 -m 17 '10.0.0.5'"), "\(rig.events)")
    }

    /// The trace from the jump host is raced against the TRACE budget, not
    /// the step budget: its command is still running after the step budget
    /// has run out, and its answer is the row.
    ///
    /// A floor, not a ceiling (CLAUDE.md, "A wall-clock ceiling in a test
    /// measures the runner"): the answer is released no sooner than a second
    /// past the step budget, and nothing asserts how long anything took. A
    /// walk that raced the step budget comes back `timedOut` before the
    /// release; a slow machine can only make that race later, which makes
    /// this case green where it should be red — never red where it should
    /// be green. `.timeLimit` is a hang bound only.
    @Test(.timeLimit(.minutes(1)))
    func theTraceFromTheJumpIsRacedAgainstTheTraceBudget() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        let release = AsyncSignal()
        defer { release.signal() }
        rig.park(.traceroute, until: release)
        let stepBudget = Duration.seconds(2)
        let diagnostics = ConnectionDiagnostics(
            descriptor: Self.descriptor(dial: Self.okDial()), values: Self.targetValues(),
            secrets: nil, jump: Self.agentJump(port: listener.port), jumpDialer: rig.dialer,
            stepTimeout: stepBudget, traceTimeout: .seconds(50), appVersion: "test")

        let run = Task { await diagnostics.run(scope: .trace) }
        #expect(await rig.execParked.wait() == .signalled)
        try await Task.sleep(for: stepBudget + .seconds(1))
        release.signal()
        let report = await run.value

        let trace = try #require(
            report.steps.first { $0.id == DiagnosticStepID.targetTraceFromJump })
        #expect(trace.outcome == .ok, "\(trace.outcome.label)")
    }

    // MARK: - Fix round 1: deadlines, and what a cut step keeps

    /// A ping that lost packets reports them (fix round 1, the review's
    /// Important finding): the deadline ends it inside the budget, and its
    /// row is `ok` with the count, where it used to be a bare `timedOut`.
    @Test func aPingThatLostAPacketReportsItsReplies() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        rig.answer(.ping, with: .output(JumpProbeSamples.busyBoxPingPartialLoss))
        // Like the real tools, this ping lingers past any budget when it is
        // given no deadline — the 12.1 s measured on the rig, here forever.
        let linger = AsyncSignal()
        defer { linger.signal() }
        rig.lingerWithoutADeadline(until: linger)

        let report = await Self.diagnostics(jumpPort: listener.port, rig: rig).run(scope: .ping)

        let ping = try #require(report.steps.first { $0.id == DiagnosticStepID.targetICMPFromJump })
        #expect(ping.outcome == .ok)
        #expect(ping.detail == "172.17.0.5 3/5 replies, min 0.1 ms, avg 0.1 ms, max 0.1 ms")
    }

    /// `-w` first; `-t` only after `-w` came back as a usage error with
    /// nothing printed — BSD's answer (`JumpProbeSamples.macOSPingUnknownOption`).
    @Test func pingFallsBackToTheBSDDeadlineOnlyOnAUsageError() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        rig.answer(.ping, with: [
            .output(JumpProbeSamples.macOSPingUnknownOption),
            .output(JumpProbeSamples.macOSPingTimeoutLoopback),
        ])

        let report = await Self.diagnostics(jumpPort: listener.port, rig: rig).run(scope: .ping)

        #expect(rig.events.filter { $0.hasPrefix("exec ping") } == [
            "exec ping -w 3 \(Self.quotedTarget)", "exec ping -t 3 \(Self.quotedTarget)",
        ])
        let ping = try #require(report.steps.first { $0.id == DiagnosticStepID.targetICMPFromJump })
        #expect(ping.outcome == .ok)
        #expect(ping.detail.hasPrefix("127.0.0.1 4/4 replies"), "\(ping.detail)")
    }

    /// Any other failure is not a reason to try `-t` — which iputils and
    /// BusyBox read as the TTL. iputils with no route exits 2 with nothing
    /// printed (`debianPingNoRoute`): one attempt, unreadable.
    @Test func pingDoesNotTryTheBSDDeadlineAfterAnyOtherFailure() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        rig.answer(.ping, with: .output(JumpProbeSamples.debianPingNoRoute))

        let report = await Self.diagnostics(jumpPort: listener.port, rig: rig).run(scope: .ping)

        #expect(rig.events.filter { $0.hasPrefix("exec ping") } == [
            "exec ping -w 3 \(Self.quotedTarget)"
        ])
        let ping = try #require(report.steps.first { $0.id == DiagnosticStepID.targetICMPFromJump })
        #expect(ping.outcome == .unavailable(DiagnosticReason.jumpPingUnreadable))
        #expect(ping.detail == "ping exited with status 2")
    }

    /// The step hands its reader the hop limit its own command carried (fix
    /// round 2): a header-less walk (BSD's header goes to standard error)
    /// that stops on an answered hop at `-m 17` is the hop limit, not an
    /// arrival at the target. CONSTRUCTED in the recorded BSD row shape.
    @Test func aHeaderlessTraceAtTheCommandsHopLimitIsNotAnArrival() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        let maxHops = JumpProbeCommand.tracerouteMaxHops(budget: .seconds(20))
        let rows = (1...maxHops).map { " \($0)  10.9.\($0).1  0.4\($0) ms" }
        rig.answer(
            .traceroute,
            with: .output(
                RemoteCommandOutput(
                    standardOutput: rows.joined(separator: "\n") + "\n", exitStatus: 0)))

        let report = await Self.diagnostics(jumpPort: listener.port, rig: rig).run(scope: .trace)

        #expect(rig.events.contains(
            "exec traceroute -n -q 1 -w 1 -m \(maxHops) \(Self.quotedTarget)"), "\(rig.events)")
        let trace = try #require(
            report.steps.first { $0.id == DiagnosticStepID.targetTraceFromJump })
        #expect(trace.detail == "measured with traceroute; "
            + DiagnosticReason.traceHopLimitReached(afterHop: maxHops))
        #expect(trace.table?.rows.last?.last == DiagnosticTraceColumn.answered)
    }

    /// A step its budget cuts off reports what it had collected: the race
    /// hands the step's own `cut` the step's transcript. Deterministic
    /// because the transcript is filled HERE, before the race, by a step
    /// whose measurement never answers — so what is read does not depend on
    /// whether the abandoned probe ever got a thread.
    @Test(arguments: CutStep.allCases)
    func aStepCutByItsBudgetReportsWhatItHadCollected(step kind: CutStep) async throws {
        let rig = JumpRig()
        let never = AsyncSignal()
        defer { never.signal() }
        let context = Self.stepContext(rig: rig, budget: .milliseconds(100))
        let template: DiagnosticJumpStep
        switch kind {
        case .tracepath:
            // `tracepath` runs without `-m`: a walk that neither arrived nor
            // said it ran out of hops stopped LOOKING.
            template = .traceFromJump
            context.transcript.begin(.tracepath)
            context.transcript.append(Array("""
                 1?: [LOCALHOST]                      pmtu 1500
                 1:  10.0.0.1                                              0.402ms
                 2:  no reply

                """.utf8))
        case .traceroute:
            // Header-less, as BSD prints it. Under this 100 ms budget the
            // command would have carried `-m 1` (`tracerouteMaxHops`), and
            // the cut reads that same limit: hop 1 is the limit, not the
            // target (fix round 2).
            template = .traceFromJump
            context.transcript.begin(.traceroute)
            context.transcript.append(Array(" 1  10.0.0.1  0.412 ms\n".utf8))
        case .ping:
            template = .icmpFromJump
            context.transcript.begin(.ping)
            context.transcript.append(Array("""
                PING 10.0.0.5 (10.0.0.5): 56 data bytes
                64 bytes from 10.0.0.5: seq=0 ttl=64 time=0.412 ms

                """.utf8))
        }
        let parked = DiagnosticJumpStep(
            id: template.id, phase: template.phase, budget: template.budget, cut: template.cut
        ) { _, timer in
            _ = await never.wait()
            return timer.finish(.failed("answered after all"), "")
        }

        let row = await ConnectionDiagnostics.race(
            parked, context,
            timer: DiagnosticStepTimer(id: template.id, titleKey: "diagnostics.step.probe"))

        switch kind {
        case .tracepath:
            #expect(row.outcome == .ok, "\(row.outcome.label)")
            #expect(row.detail == "measured with tracepath; "
                + DiagnosticReason.traceStoppedByBudget(afterHop: 2))
            #expect(row.table?.rows.count == 2)
        case .traceroute:
            #expect(JumpProbeCommand.tracerouteMaxHops(budget: context.budget) == 1)
            #expect(row.detail == "measured with traceroute; "
                + DiagnosticReason.traceHopLimitReached(afterHop: 1))
            #expect(row.table?.rows == [
                ["1", "10.0.0.1", "0.4 ms", DiagnosticTraceColumn.answered]
            ])
        case .ping:
            #expect(row.outcome == .ok, "\(row.outcome.label)")
            #expect(row.detail.hasPrefix("10.0.0.5 1 replies before the step's budget ran out"),
                "\(row.detail)")
        }
    }

    enum CutStep: String, CaseIterable, CustomTestStringConvertible {
        case tracepath, traceroute, ping
        var testDescription: String { rawValue }
    }

    /// And the transcript the race reads is the one the step's commands
    /// write: what the tool printed is there once the measurement ran.
    @Test func aStepsCommandsWriteIntoItsTranscript() async throws {
        let rig = JumpRig()
        let context = Self.stepContext(rig: rig, budget: .seconds(20))

        _ = await DiagnosticJumpStep.traceFromJump.measure(
            context, DiagnosticStepTimer(id: "t", titleKey: "diagnostics.step.probe"))

        let current = context.transcript.current
        #expect(current?.tool == .traceroute)
        #expect(current?.standardOutput == JumpProbeSamples.rigTracerouteToSshd2.standardOutput)
    }

    // MARK: - The dial carries the jump

    /// `SSHFieldSchema.makeConfig` returns a config whose jump is always nil
    /// — it takes one secret, and a jump has a second — so the target's dial
    /// through the jump is only a dial through the jump if the hop is
    /// attached after it. Pinned twice: on the builder, and on what the walk
    /// actually hands its dialer.
    @Test func theTargetDialThroughAJumpCarriesTheJump() async throws {
        var values = Self.targetValues()
        values[SSHField.authKind] = StoredSession.AuthKind.password.rawValue
        let jump = DiagnosticJump(
            endpoint: Endpoint(host: "127.0.0.1", port: 2222),
            login: .init(username: "jumpuser", authKind: .password, keyPath: nil),
            secret: { Self.jumpSecret })

        let config = try jump.targetConfig(
            values: values, targetSecret: "target", jumpSecret: Self.jumpSecret)

        let hop = try #require(config.jump, "the target's dial config dropped the jump")
        #expect(hop.host == "127.0.0.1")
        #expect(hop.port == 2222)
        #expect(hop.username == "jumpuser")
        let carriesTheJumpSecret: Bool
        if case .password(let secret) = hop.auth { carriesTheJumpSecret = secret == Self.jumpSecret }
        else { carriesTheJumpSecret = false }
        #expect(carriesTheJumpSecret)
        #expect(config.host == Self.targetHost)
        #expect(config.port == Self.targetPort)

        // And through the walk: what the dialer was handed.
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        _ = await Self.diagnostics(jumpPort: listener.port, rig: rig).run(scope: .dial)
        #expect(rig.targetDialJumps == ["127.0.0.1:\(listener.port)"])
    }

    /// The jump's own dial fails against a port nothing listens on, with a
    /// password secret in hand. Neither the rows nor either rendering may
    /// carry it. The real dials, not the fake: the secret has to have been
    /// handed to a transport for its absence to mean anything.
    @Test func theJumpsSecretNeverReachesTheReport() async throws {
        let closedPort = try #require(LoopbackSocket.closedPort())
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-diag-jump-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = Self.jumpSecret
        let jump = DiagnosticJump(
            endpoint: Endpoint(host: "127.0.0.1", port: closedPort),
            login: .init(username: "testuser", authKind: .password, keyPath: nil),
            secret: { secret })

        let report = await ConnectionDiagnostics(
            descriptor: .descriptor(for: .ssh), values: Self.targetValues(), secrets: nil,
            jump: jump, jumpDialer: .live(knownHosts: KnownHostsStore(directory: directory)),
            stepTimeout: .seconds(10), appVersion: "test"
        ).run(scope: .dial)

        let dial = try #require(report.steps.first { $0.id == DiagnosticStepID.jumpDial })
        guard case .failed = dial.outcome else {
            Issue.record("a closed port did not fail the jump's dial: \(dial.outcome)")
            return
        }
        let inStep = report.steps.contains { step in
            step.detail.contains(secret) || step.outcome.label.contains(secret)
        }
        let inPlainText = report.plainText().contains(secret)
        let inMarkdown = report.markdown().contains(secret)
        #expect(inStep == false)
        #expect(inPlainText == false)
        #expect(inMarkdown == false)
    }

    // MARK: - A refused channel, read

    @Test func aRefusalsReasonCodeIsReadOutOfNIOSSHsDescription() {
        #expect(DirectTCPIPRejection.reasonCode(
            inDescription: "NIOSSHError.channelSetupRejected: Reason: 1 open failed") == 1)
        #expect(DirectTCPIPRejection.reasonCode(
            inDescription: "NIOSSHError.channelSetupRejected: Reason: 2 Connection refused") == 2)
        #expect(DirectTCPIPRejection.reasonCode(
            inDescription: "NIOSSHError.channelSetupRejected: Reason: 4 ") == 4)
        #expect(DirectTCPIPRejection.reasonCode(inDescription: "NIOSSHError.protocolViolation") == nil)
        // An error that is not a refused channel is no rejection at all.
        #expect(DirectTCPIPRejection(RemoteFSError.authenticationFailed) == nil)
    }

    /// Each code the row can meet, and the sentence it gets: the two a user
    /// can act on are told apart, any other is named by its number, and an
    /// error that is not a refusal is rendered the way every dial error is.
    ///
    /// The codes are literals, RFC 4254 §5.1's own numbers, and not the
    /// type's constants: a case that read the constants would stay green
    /// with the two swapped (measured — only the rig case went red).
    @Test func aRefusedChannelIsReportedByItsReasonCode() {
        let prohibited = DirectTCPIPRejection(reasonCode: 1)
        let unreachable = DirectTCPIPRejection(reasonCode: 2)
        #expect(DirectTCPIPRefusal.reason(for: prohibited) == DiagnosticReason.jumpForwardingProhibited)
        #expect(DirectTCPIPRefusal.reason(for: unreachable) == DiagnosticReason.jumpCouldNotConnect)
        #expect(DirectTCPIPRefusal.reason(for: DirectTCPIPRejection(reasonCode: 4))
            == DiagnosticReason.jumpRefusedChannel(code: 4))
        let other = RemoteFSError.authenticationFailed
        #expect(DirectTCPIPRefusal.reason(for: other) == DialSupport.reason(for: other))
    }

    // MARK: - Where the jump comes from

    /// A stored session's jump, in each of its three modes, resolved without
    /// reading a secret until the dial asks — and then reading the slot the
    /// connect reads.
    @Test func aStoredJumpIsResolvedAsTheConnectResolvesItAndReadsItsSlotOnlyWhenAsked() throws {
        let store = CountingSecretStore()
        let keys = ManagedKeyStore(
            directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("macscp-keys-diag-\(UUID().uuidString)"))
        let secretID = UUID()
        store.put(Self.jumpSecret, for: secretID)
        let manual = StoredSession(
            id: UUID(), name: "behind",
            ssh: StoredSSHConfig(
                host: Self.targetHost, username: "testuser",
                jump: .init(host: "bastion.invalid", port: 2200, username: "hop", secretID: secretID)))

        let jump = try #require(DiagnosticJump.stored(
            for: manual, sets: [], sessions: [manual], secrets: store, keys: keys))
        #expect(jump.endpoint == Endpoint(host: "bastion.invalid", port: 2200))
        #expect(jump.login == .init(username: "hop", authKind: .password, keyPath: nil))
        #expect(store.reads == 0, "building the jump read a secret")
        let answered = try jump.secret() == Self.jumpSecret
        #expect(answered)
        #expect(store.readSlots == [secretID])

        // Session mode: the referenced saved connection's host and slot.
        let bastion = StoredSession(
            id: UUID(), name: "bastion",
            ssh: StoredSSHConfig(host: "jump.invalid", port: 2022, username: "ops"))
        store.put(Self.jumpSecret, for: bastion.id)
        let referencing = StoredSession(
            id: UUID(), name: "via",
            ssh: StoredSSHConfig(
                host: Self.targetHost, username: "testuser",
                jump: .init(host: "", username: "", sessionID: bastion.id)))
        let viaSession = try #require(DiagnosticJump.stored(
            for: referencing, sets: [], sessions: [bastion, referencing], secrets: store, keys: keys))
        #expect(viaSession.endpoint == Endpoint(host: "jump.invalid", port: 2022))
        #expect(viaSession.login.username == "ops")
        _ = try viaSession.secret()
        #expect(store.readSlots.last == bastion.id)

        // A reference to a connection that is gone: unresolvable, not a
        // direct dial.
        let dangling = try #require(DiagnosticJump.stored(
            for: referencing, sets: [], sessions: [referencing], secrets: store, keys: keys))
        #expect(dangling.endpoint == nil)

        // No jump, no jump.
        let direct = StoredSession(
            id: UUID(), name: "direct", ssh: StoredSSHConfig(host: Self.targetHost, username: "u"))
        #expect(DiagnosticJump.stored(
            for: direct, sets: [], sessions: [direct], secrets: store, keys: keys) == nil)
    }

    /// A tab's jump: where and who from the form, the secret from the stored
    /// session behind it — never the form's typed one.
    @Test func aFormsJumpTakesItsFieldsFromTheFormAndItsSecretFromTheStoredJump() throws {
        var values = Self.targetValues()
        values[SSHField.jump, SSHJumpField.host] = " bastion.invalid "
        values[SSHField.jump, SSHJumpField.port] = "2200"
        values[SSHField.jump, SSHJumpField.username] = "hop"
        values[SSHField.jump, SSHJumpField.authKind] = StoredSession.AuthKind.password.rawValue
        values[SSHField.jump, SSHJumpField.password] = "typed-into-the-form"

        #expect(DiagnosticJump.form(values, isEnabled: false, stored: nil) == nil)

        let stored = DiagnosticJump(
            endpoint: Endpoint(host: "bastion.invalid", port: 2200),
            login: .init(username: "hop", authKind: .password, keyPath: nil),
            secret: { Self.jumpSecret })
        let jump = try #require(DiagnosticJump.form(values, isEnabled: true, stored: stored))
        #expect(jump.endpoint == Endpoint(host: "bastion.invalid", port: 2200))
        #expect(jump.login == .init(username: "hop", authKind: .password, keyPath: nil))
        let fromStored = try jump.secret() == Self.jumpSecret
        #expect(fromStored)

        let unsaved = try #require(DiagnosticJump.form(values, isEnabled: true, stored: nil))
        let noSecret = try unsaved.secret() == nil
        #expect(noSecret, "a tab with no stored jump read the form's typed secret")
    }

    /// The stored jump's secret goes only to the stored jump (fix round 1 of
    /// Task 6, the coordinator's ruling on the review's Minor 4).
    ///
    /// The form's jump can be edited and not saved — another host, port,
    /// user or auth kind — while the secret still comes from the stored
    /// session's slot. Sent as it was, the stored bastion's password would go
    /// to whatever host the form now names. So it is handed over only when
    /// all four equal the stored jump's, and otherwise the jump has no secret
    /// to offer, which its dial reports as `noJumpSecret`.
    ///
    /// Whether the secret came back is computed into a `Bool` before any
    /// expectation reads it: the value itself is never in an expression
    /// `#expect` could print.
    @Test(arguments: FormJumpEdit.allCases)
    func aFormsJumpGetsTheStoredSecretOnlyWhenItIsTheStoredJump(edit: FormJumpEdit) throws {
        var values = Self.targetValues()
        values[SSHField.jump, SSHJumpField.host] = "bastion.invalid"
        values[SSHField.jump, SSHJumpField.port] = "2200"
        values[SSHField.jump, SSHJumpField.username] = "hop"
        values[SSHField.jump, SSHJumpField.authKind] = StoredSession.AuthKind.password.rawValue
        switch edit {
        case .none: break
        case .host: values[SSHField.jump, SSHJumpField.host] = "elsewhere.invalid"
        case .port: values[SSHField.jump, SSHJumpField.port] = "2201"
        case .username: values[SSHField.jump, SSHJumpField.username] = "someone-else"
        case .authKind:
            values[SSHField.jump, SSHJumpField.authKind] =
                StoredSession.AuthKind.privateKey.rawValue
            values[SSHField.jump, SSHJumpField.keyPath] = "/tmp/key.invalid"
        }
        let secret = Self.jumpSecret
        let stored = DiagnosticJump(
            endpoint: Endpoint(host: "bastion.invalid", port: 2200),
            login: .init(username: "hop", authKind: .password, keyPath: nil),
            secret: { secret })

        let jump = try #require(DiagnosticJump.form(values, isEnabled: true, stored: stored))

        let answered = try jump.secret()
        let gotTheStoredSecret = answered == secret
        let gotNothing = answered == nil
        if edit == .none {
            #expect(gotTheStoredSecret, "the form names the stored jump, and got no secret")
        } else {
            #expect(gotNothing, "the form's jump differs in its \(edit), and got a secret")
        }
    }

    enum FormJumpEdit: String, CaseIterable, CustomTestStringConvertible {
        case none, host, port, username, authKind
        var testDescription: String { rawValue }
    }

    /// The same rule through the walk: a form whose jump differs from the
    /// stored one dials nothing, and the jump's login row says there was no
    /// secret for it — the reason a missing secret has always had.
    @Test func aFormsEditedJumpIsNotDialledWithTheStoredSecret() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        var values = Self.targetValues()
        values[SSHField.jump, SSHJumpField.host] = "127.0.0.1"
        values[SSHField.jump, SSHJumpField.port] = String(listener.port)
        values[SSHField.jump, SSHJumpField.username] = "edited-not-saved"
        values[SSHField.jump, SSHJumpField.authKind] = StoredSession.AuthKind.password.rawValue
        let secret = Self.jumpSecret
        let stored = DiagnosticJump(
            endpoint: Endpoint(host: "127.0.0.1", port: listener.port),
            login: .init(username: "testuser", authKind: .password, keyPath: nil),
            secret: { secret })
        let jump = try #require(DiagnosticJump.form(values, isEnabled: true, stored: stored))
        let rig = JumpRig()

        let report = await Self.diagnostics(jump: jump, rig: rig).run(scope: .dial)

        let dial = try #require(report.steps.first { $0.id == DiagnosticStepID.jumpDial })
        #expect(dial.outcome == .skipped(DiagnosticReason.noJumpSecret))
        #expect(rig.count("connect") == 0, "\(rig.events)")
    }

    // MARK: - The report names both halves

    @Test func theReportNamesTheJumpInBothRenderingsAndTheJSON() throws {
        let step = DiagnosticStepTimer(
            id: DiagnosticStepID.jumpDial,
            titleKey: DiagnosticStepID.titleKey(for: DiagnosticStepID.jumpDial)
        ).finish(.ok, "")
        let report = DiagnosticReport(
            endpoint: Endpoint(host: Self.targetHost, port: Self.targetPort),
            jump: Endpoint(host: "127.0.0.1", port: 2222), steps: [step], appVersion: "test")

        #expect(report.plainText().contains("Jump host: 127.0.0.1:2222"), "\(report.plainText())")
        #expect(report.markdown().contains("- **Jump host:** `127.0.0.1:2222`"), "\(report.markdown())")
        let summary = DiagnoseRendering.jsonSummary(for: report)
        let jump = try #require(summary["jump"] as? [String: Any])
        #expect(jump["host"] as? String == "127.0.0.1")
        #expect(jump["port"] as? Int == 2222)
        // The keys it had before are all still there.
        #expect(Set(summary.keys).isSuperset(of: ["completion", "endpoint", "steps"]))

        let direct = DiagnosticReport(endpoint: nil, steps: [step], appVersion: "test")
        #expect(DiagnoseRendering.jsonSummary(for: direct)["jump"] is NSNull)
    }

    // MARK: - Fixtures

    private static let contributionID = "probe-contribution"

    /// The target's field values: agent auth, so no case needs the target's
    /// secret unless it sets one.
    private static func targetValues() -> FieldValues {
        var values = SSHFieldSchema.defaults
        values[SSHField.host] = targetHost
        values[SSHField.port] = String(targetPort)
        values[SSHField.username] = "testuser"
        values[SSHField.authKind] = StoredSession.AuthKind.agent.rawValue
        return values
    }

    /// A jump on loopback, logging in through the agent — nothing to look up.
    private static func agentJump(port: Int) -> DiagnosticJump {
        DiagnosticJump(
            endpoint: Endpoint(host: "127.0.0.1", port: port),
            login: .init(username: "testuser", authKind: .agent, keyPath: nil),
            secret: { nil })
    }

    private static func diagnostics(
        jumpPort: Int, rig: JumpRig, contribution: Ticker? = nil,
        stepTimeout: Duration = .seconds(5)
    ) -> ConnectionDiagnostics {
        diagnostics(
            jump: agentJump(port: jumpPort), rig: rig, contribution: contribution,
            stepTimeout: stepTimeout)
    }

    private static func diagnostics(
        jump: DiagnosticJump, rig: JumpRig, contribution: Ticker? = nil,
        values: FieldValues = targetValues(), stepTimeout: Duration = .seconds(5)
    ) -> ConnectionDiagnostics {
        ConnectionDiagnostics(
            descriptor: descriptor(
                dial: okDial(),
                diagnostics: contribution.map { [recordingContribution(ticker: $0)] } ?? []),
            values: values, secrets: nil, jump: jump, jumpDialer: rig.dialer,
            stepTimeout: stepTimeout, appVersion: "test")
    }

    /// One target-half step's context over the fake connection, with its own
    /// budget and an empty transcript.
    private static func stepContext(rig: JumpRig, budget: Duration) -> DiagnosticJumpStep.Context {
        DiagnosticJumpStep.Context(
            connection: FakeJumpConnection(rig: rig), jump: agentJump(port: 1),
            target: Endpoint(host: targetHost, port: targetPort), values: targetValues(),
            diagnostic: DiagnosticContext(secrets: nil, sessionID: nil, timeout: .seconds(5)),
            dialer: rig.dialer, budget: budget, transcript: JumpProbeTranscript())
    }

    /// Each `target.` row's outcome, by id.
    private static func outcomes(of report: DiagnosticReport) -> [String: DiagnosticOutcome] {
        Dictionary(
            uniqueKeysWithValues: report.steps.filter { $0.id.hasPrefix("target.") }
                .map { ($0.id, $0.outcome) })
    }

    /// SSH's own endpoint, and a dial and contributions the case chooses. A
    /// walk through a jump must not run this dial — `target.dialViaJump` is
    /// its dial — which the order cases would show as an extra `dial` row.
    private static func descriptor(
        dial: DiagnosticContribution?, diagnostics: [DiagnosticContribution] = []
    ) -> BackendDescriptor {
        let ssh = BackendDescriptor.descriptor(for: .ssh)
        return BackendDescriptor(
            kind: .ssh, capabilities: ssh.capabilities,
            connectionSchema: ssh.connectionSchema, credentialSchema: ssh.credentialSchema,
            makeConfig: ssh.makeConfig, displaySummary: ssh.displaySummary, apply: ssh.apply,
            connect: { _, _, _, _ in throw RemoteFSError.protocolError(reason: "unused") },
            badgeLabelKey: "b", badgeLabelDefault: "B",
            secretEnvironmentVariable: nil, requiresSecret: { _ in false },
            fileActions: [],
            endpoint: ssh.endpoint, dial: dial, diagnostics: diagnostics)
    }

    private static func okDial() -> DiagnosticContribution {
        DiagnosticContribution(id: DiagnosticStepID.dial, titleKey: "diagnostics.step.probe") { _, _ in
            DiagnosticStepTimer(id: DiagnosticStepID.dial, titleKey: "diagnostics.step.probe")
                .finish(.ok, "")
        }
    }

    private static func recordingContribution(ticker: Ticker) -> DiagnosticContribution {
        DiagnosticContribution(id: contributionID, titleKey: "diagnostics.step.probe") { _, _ in
            let timer = DiagnosticStepTimer(id: contributionID, titleKey: "diagnostics.step.probe")
            await ticker.tick()
            return timer.finish(.ok, "")
        }
    }
}

// MARK: - The fake jump

/// The seam's fake: hands out a connection that records what it is asked,
/// and records what the walk dialled. Every event lands in one list, in the
/// order it happened, so "closed after the last step" is an assertion about
/// the list rather than two counters.
final class JumpRig: Sendable {
    private struct State {
        var events: [String] = []
        var targetDialJumps: [String] = []
        var connectError: (any Error)?
        var probeError: (any Error)?
        var jumpDialPark: AsyncSignal?
        var targetDialPark: AsyncSignal?
        /// What each probe command answers. By default, what the rig's own
        /// tools printed (`JumpProbeSamples`) — `traceroute` as root, the
        /// one answer that is ok — so a walk that asks for nothing else
        /// comes back all ok.
        /// Consumed in order, the last one repeating.
        var execAnswers: [JumpProbeCommand.Tool: [ExecAnswer]] = [
            .getent: [.output(JumpProbeSamples.rigGetentOverSSH)],
            .ping: [.output(JumpProbeSamples.rigPingOverSSH)],
            .traceroute: [.output(JumpProbeSamples.rigTracerouteToSshd2)],
            .tracepath: [.output(JumpProbeSamples.rigTracepathOverSSH)],
        ]
        var execParks: [JumpProbeCommand.Tool: AsyncSignal] = [:]
        var linger: AsyncSignal?
    }

    /// How a probe command is answered.
    enum ExecAnswer {
        case output(RemoteCommandOutput)
        case failure(any Error)
    }

    private let state = Mutex(State())
    /// Raised when the target's dial is entered — the moment a cancelling
    /// case cancels.
    let targetDialEntered = AsyncSignal()
    /// Raised when a connection this rig handed out is closed.
    let disconnected = AsyncSignal()
    /// Raised when a probe command the case parked has been entered.
    let execParked = AsyncSignal()

    var events: [String] { state.withLock { $0.events } }
    var targetDialJumps: [String] { state.withLock { $0.targetDialJumps } }

    var connectError: (any Error)? {
        get { state.withLock { $0.connectError } }
        set { state.withLock { $0.connectError = newValue } }
    }

    var probeError: (any Error)? {
        get { state.withLock { $0.probeError } }
        set { state.withLock { $0.probeError = newValue } }
    }

    func count(_ prefix: String) -> Int {
        events.filter { $0 == prefix || $0.hasPrefix(prefix + " ") }.count
    }

    func record(_ event: String) { state.withLock { $0.events.append(event) } }

    func parkJumpDial(until signal: AsyncSignal) { state.withLock { $0.jumpDialPark = signal } }

    func answer(_ tool: JumpProbeCommand.Tool, with answer: ExecAnswer) {
        state.withLock { $0.execAnswers[tool] = [answer] }
    }

    /// A `ping` given no deadline option (`-w`, `-t`) waits on `signal`
    /// before it answers — the linger the real tools have after their last
    /// request when an answer is missing.
    func lingerWithoutADeadline(until signal: AsyncSignal) {
        state.withLock { $0.linger = signal }
    }

    /// Answers in this order, one per command, the last repeating.
    func answer(_ tool: JumpProbeCommand.Tool, with answers: [ExecAnswer]) {
        state.withLock { $0.execAnswers[tool] = answers }
    }

    func park(_ tool: JumpProbeCommand.Tool, until signal: AsyncSignal) {
        state.withLock { $0.execParks[tool] = signal }
    }

    /// What the fake connection's `run(_:into:)` does: records the command
    /// line exactly as production would send it, then answers — writing the
    /// answer's standard output into the transcript first, as the real
    /// plumbing does chunk by chunk.
    func exec(
        _ command: JumpProbeCommand, into transcript: JumpProbeTranscript
    ) async throws -> RemoteCommandOutput {
        record("exec \(command.text)")
        if let park = state.withLock({ $0.execParks[command.tool] }) {
            execParked.signal()
            _ = await park.wait()
        }
        if command.tool == .ping, !command.text.contains(" -w "), !command.text.contains(" -t "),
            let linger = state.withLock({ $0.linger })
        {
            _ = await linger.wait()
        }
        let answer: ExecAnswer? = state.withLock { state in
            guard var queue = state.execAnswers[command.tool], let first = queue.first else {
                return nil
            }
            if queue.count > 1 {
                queue.removeFirst()
                state.execAnswers[command.tool] = queue
            }
            return first
        }
        switch answer {
        case .output(let output):
            transcript.append(Array(output.standardOutput.utf8))
            return output
        case .failure(let failure): throw failure
        case nil: return RemoteCommandOutput(standardOutput: "", exitStatus: 127)
        }
    }
    func parkTargetDial(until signal: AsyncSignal) { state.withLock { $0.targetDialPark = signal } }

    var dialer: DiagnosticJumpDialer {
        DiagnosticJumpDialer(
            connectJump: { config, _ in
                // Parked in an unstructured task, so the wait does NOT
                // honour the dial's cancellation: the shape of a transport
                // that finishes its connect whatever the caller wanted,
                // which is what makes a late connection possible at all.
                if let park = self.state.withLock({ $0.jumpDialPark }) {
                    await Task { _ = await park.wait() }.value
                }
                if let error = self.connectError { throw error }
                self.record("connect \(config.host):\(config.port)")
                return FakeJumpConnection(rig: self)
            },
            dialTarget: { config, _ in
                let hop = config.jump.map { "\($0.host):\($0.port)" } ?? "none"
                self.state.withLock { $0.targetDialJumps.append(hop) }
                self.record("dialTarget \(config.host):\(config.port) via \(hop)")
                self.targetDialEntered.signal()
                if let park = self.state.withLock({ $0.targetDialPark }) { _ = await park.wait() }
            })
    }
}

private struct FakeJumpConnection: DiagnosticJumpConnection {
    let rig: JumpRig

    func probeDirectTCPIP(host: String, port: Int) async throws {
        rig.record("probe \(host):\(port)")
        if let error = rig.probeError { throw error }
    }

    func run(
        _ command: JumpProbeCommand, into transcript: JumpProbeTranscript
    ) async throws -> RemoteCommandOutput {
        try await rig.exec(command, into: transcript)
    }

    func disconnect() async {
        rig.record("disconnect")
        rig.disconnected.signal()
    }
}

/// Collects observer events in the order they came.
private final class RunEvents: Sendable {
    private let state = Mutex<[String]>([])
    var events: [String] { state.withLock { $0 } }
    func record(_ event: String) { state.withLock { $0.append(event) } }
}

private actor Ticker {
    private(set) var count = 0
    func tick() { count += 1 }
}

/// A `SecretStore` that holds what the case puts in it and records every slot
/// read, so "no secret is read until the dial asks" is a count.
private final class CountingSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]
    private var slots: [UUID] = []

    var reads: Int { lock.withLock { slots.count } }
    var readSlots: [UUID] { lock.withLock { slots } }

    func put(_ value: String, for id: UUID) { lock.withLock { values[id] = value } }

    func savePassword(_ password: String, for sessionID: UUID) throws {
        lock.withLock { values[sessionID] = password }
    }

    func password(for sessionID: UUID) throws -> String? {
        lock.withLock {
            slots.append(sessionID)
            return values[sessionID]
        }
    }

    func deletePassword(for sessionID: UUID) throws {
        _ = lock.withLock { values.removeValue(forKey: sessionID) }
    }
}
