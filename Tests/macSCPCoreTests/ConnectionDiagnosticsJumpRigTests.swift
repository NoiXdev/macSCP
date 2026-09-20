import Foundation
import Testing

@testable import macSCPCore

/// The jump walk against the Docker rig: `sshd2` reached through `sshd`.
///
/// `sshd2` is named by its service name and the container's internal port,
/// 2222 — the address only the jump host can reach, as
/// `CitadelFileSystemIntegrationTests.jumpConnectListsOverHop` names it. From
/// this Mac that name resolves to nothing, which is the point: a diagnosis
/// that went straight at the target could not report the target reached.
///
/// Every dial answers the host-key question with `HostKeyDecider.refusing`,
/// over a store holding the rig's own recorded keys
/// (`CitadelFileSystemIntegrationTests.rigKnownHosts(in:)`) — no accepting
/// decider anywhere. The jump's and the target's logins are the rig's
/// `testuser`/`testpass`.
@Suite(
    "ConnectionDiagnostics through a jump host, against the rig",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized
)
struct ConnectionDiagnosticsJumpRigTests {
    /// Every jump step, the channel and the dial through the jump are ok.
    /// The trace ON the jump host is the one row that is not, and
    /// `theProbesOnTheJumpHostAnswerWhatTheRigCarries` says why.
    @Test func everyJumpStepAndTheChannelThroughItAreOk() async throws {
        let (directory, knownHosts) = try await Self.rigStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = await Self.diagnostics(
            target: "sshd2", port: 2222, knownHosts: knownHosts
        ).run()

        #expect(report.steps.map(\.id) == [
            DiagnosticStepID.jumpResolve, DiagnosticStepID.jumpTCP, DiagnosticStepID.jumpICMP,
            DiagnosticStepID.jumpDial, DiagnosticStepID.jumpTrace,
            DiagnosticStepID.targetTCPViaJump, DiagnosticStepID.targetResolveOnJump,
            DiagnosticStepID.targetICMPFromJump, DiagnosticStepID.targetDialViaJump,
            DiagnosticStepID.targetTraceFromJump,
        ])
        for step in report.steps where step.id != DiagnosticStepID.targetTraceFromJump {
            #expect(step.outcome == .ok, "\(step.id): \(step.outcome.label) — \(step.detail)")
        }
        #expect(report.jump == Endpoint(host: "127.0.0.1", port: 2222))
    }

    /// The three probes run ON the jump host, asserted against what the rig
    /// image carries — read on 2026-09-18 with `command -v`, one tool at a
    /// time (BusyBox `sh` answers a multi-name `command -v` for the first
    /// name only), and confirmed over a real SSH `exec` as `testuser`:
    ///
    /// - `getent` (musl-utils): there, answers `sshd2`'s address → ok.
    /// - `ping` (BusyBox): there, and allowed for `testuser` → ok, 3 of 3.
    /// - `traceroute` (BusyBox): there, and NOT allowed — it needs a raw
    ///   socket (`socket(AF_INET,3,1): Operation not permitted`, exit 1,
    ///   nothing on standard output); `tracepath`: not there (exit 127). So
    ///   the trace is `unavailable`, naming both attempts.
    ///
    /// If the rig image changes what it carries, this is the case that says
    /// so — which is what it is for.
    @Test func theProbesOnTheJumpHostAnswerWhatTheRigCarries() async throws {
        let (directory, knownHosts) = try await Self.rigStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = await Self.diagnostics(
            target: "sshd2", port: 2222, knownHosts: knownHosts
        ).run()

        let resolve = try #require(
            report.steps.first { $0.id == DiagnosticStepID.targetResolveOnJump })
        #expect(resolve.outcome == .ok, "\(resolve.outcome.label)")
        // The address is Docker's to assign; that the jump host answered
        // with one IPv4 address is the measurement.
        #expect(resolve.detail.hasPrefix("IPv4 "), "\(resolve.detail)")
        #expect(!resolve.detail.contains(","), "\(resolve.detail)")

        let ping = try #require(report.steps.first { $0.id == DiagnosticStepID.targetICMPFromJump })
        #expect(ping.outcome == .ok, "\(ping.outcome.label) — \(ping.detail)")
        // BusyBox's `ping -w N` sends one request a second, N in all
        // (measured for N = 3, 4 and 18 on the rig).
        let sent = JumpProbeCommand.pingDeadlineSeconds(budget: Self.stepBudget)
        #expect(ping.detail.contains(" \(sent)/\(sent) replies, min "), "\(ping.detail)")

        let trace = try #require(
            report.steps.first { $0.id == DiagnosticStepID.targetTraceFromJump })
        #expect(trace.outcome == .unavailable(DiagnosticReason.jumpTraceUnreadable), """
            \(trace.outcome.label) — \(trace.detail)
            """)
        #expect(trace.detail == "traceroute exited with status 1; tracepath exited with status 127")
    }

    /// A ping from the jump host to an address nothing holds in the rig's
    /// Docker network (172.20.0.0/16; `172.20.255.254` is unassigned — read
    /// with `docker network inspect` on 2026-09-18). Before fix round 1,
    /// BusyBox's `ping -c 3` lingered 12.1 s there and the 5 s budget cut
    /// it into a bare `timedOut`. With its deadline (`-w 3`, measured over
    /// SSH three times at 3.08-3.11 s, each "3 packets transmitted, 0
    /// packets received") it ends inside the budget and the row carries its
    /// count. The outcome is `timedOut` all the same — silence, as the
    /// local echo reports it — and the detail is what tells the two apart:
    /// a budget cut carries none.
    @Test func aPingToASilentAddressEndsByItsDeadlineWithItsCount() async throws {
        let (directory, knownHosts) = try await Self.rigStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        // The product's own step budget, 5 s, rather than this suite's 20 s:
        // the budget the linger used to overrun.
        let report = await Self.diagnostics(
            target: "172.20.255.254", port: 2222, knownHosts: knownHosts,
            stepTimeout: .seconds(5)
        ).run(scope: .ping)

        let ping = try #require(report.steps.first { $0.id == DiagnosticStepID.targetICMPFromJump })
        #expect(ping.outcome == .timedOut, "\(ping.outcome.label)")
        #expect(ping.detail == "172.20.255.254 0/3 replies", "\(ping.detail)")
    }

    /// A name the jump host does not know: its `getent` says so (exit 2), a
    /// finding about the target — and the jump host's BusyBox `ping`, handed
    /// a name it cannot resolve, prints nothing on standard output, which is
    /// no answer.
    @Test func aNameTheJumpHostDoesNotKnowIsReportedByItsResolve() async throws {
        let (directory, knownHosts) = try await Self.rigStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = await Self.diagnostics(
            target: "nosuchhost.invalid", port: 2222, knownHosts: knownHosts
        ).run(scope: .ping)

        let resolve = try #require(
            report.steps.first { $0.id == DiagnosticStepID.targetResolveOnJump })
        #expect(resolve.outcome == .failed(DiagnosticReason.jumpCouldNotResolve), """
            \(resolve.outcome.label) — \(resolve.detail)
            """)
        let ping = try #require(report.steps.first { $0.id == DiagnosticStepID.targetICMPFromJump })
        #expect(ping.outcome == .unavailable(DiagnosticReason.jumpPingUnreadable), """
            \(ping.outcome.label) — \(ping.detail)
            """)
    }

    /// The same target without its jump: this Mac cannot even resolve it.
    /// The positive half of `everyJumpStepAndTheChannelThroughItAreOk` — the
    /// rows there are `ok` because the walk went through the jump, not
    /// because `sshd2` answers from here.
    @Test func withoutItsJumpTheTargetDoesNotResolveFromHere() async throws {
        var values = Self.targetValues(host: "sshd2", port: 2222)
        values[SSHField.authKind] = StoredSession.AuthKind.password.rawValue
        let report = await ConnectionDiagnostics(
            descriptor: .descriptor(for: .ssh), values: values, secrets: nil, jump: nil,
            throughput: DiagnosticThroughputSettings(),
            internetSpeed: DiagnosticInternetSpeedSettings(service: .off)
        ).run(scope: .ping)

        let resolve = try #require(report.steps.first)
        #expect(resolve.id == DiagnosticStepID.resolve)
        #expect(resolve.outcome != .ok, "sshd2 resolved from this Mac: \(resolve.detail)")
    }

    /// A port nothing listens on, and a name the jump cannot resolve: both
    /// are the jump host saying it could not connect — reason code 2 — and
    /// neither is the jump host refusing to forward.
    @Test(arguments: [("sshd2", 1), ("nosuchhost.invalid", 2222)])
    func aTargetTheJumpCannotReachIsReportedAsSuch(host: String, port: Int) async throws {
        let (directory, knownHosts) = try await Self.rigStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = await Self.diagnostics(
            target: host, port: port, knownHosts: knownHosts
        ).run(scope: .ping)

        let dial = try #require(report.steps.first { $0.id == DiagnosticStepID.jumpDial })
        #expect(dial.outcome == .ok, "\(dial.outcome.label)")
        let channel = try #require(
            report.steps.first { $0.id == DiagnosticStepID.targetTCPViaJump })
        #expect(channel.outcome == .failed(DiagnosticReason.jumpCouldNotConnect), """
            \(host):\(port): \(channel.outcome.label)
            """)
    }

    /// A jump host whose key this Mac has never recorded is refused, not
    /// trusted — and nothing is reached through it.
    @Test func anUnrecordedJumpKeyIsRefusedAndNothingIsReachedThroughIt() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-diag-jump-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let knownHosts = KnownHostsStore(directory: directory)

        let report = await Self.diagnostics(
            target: "sshd2", port: 2222, knownHosts: knownHosts
        ).run(scope: .dial)

        let dial = try #require(report.steps.first { $0.id == DiagnosticStepID.jumpDial })
        #expect(dial.outcome == .failed(DialSupport.reason(for: HostKeyError.rejectedByUser)))
        #expect(report.steps.last?.outcome == .skipped(DiagnosticReason.jumpNotReached))
        #expect(try knownHosts.find(host: "127.0.0.1", port: 2222) == nil, """
            the refusing decider wrote a key
            """)
    }

    // MARK: - Fixtures

    private static func rigStore() async throws -> (URL, KnownHostsStore) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-diag-jump-\(UUID().uuidString)")
        let store = try await CitadelFileSystemIntegrationTests.rigKnownHosts(in: directory)
        return (directory, store)
    }

    private static func targetValues(host: String, port: Int) -> FieldValues {
        var values = SSHFieldSchema.defaults
        values[SSHField.host] = host
        values[SSHField.port] = String(port)
        values[SSHField.username] = "testuser"
        values[SSHField.authKind] = StoredSession.AuthKind.password.rawValue
        return values
    }

    /// The step budget these cases run with: wide, for dials on a loaded
    /// machine.
    private static let stepBudget = Duration.seconds(20)

    private static func diagnostics(
        target host: String, port: Int, knownHosts: KnownHostsStore,
        stepTimeout: Duration = stepBudget
    ) -> ConnectionDiagnostics {
        ConnectionDiagnostics(
            descriptor: .descriptor(for: .ssh), values: targetValues(host: host, port: port),
            secrets: RigSecretSource(), sessionID: UUID(),
            jump: DiagnosticJump(
                endpoint: Endpoint(host: "127.0.0.1", port: 2222),
                login: .init(username: "testuser", authKind: .password, keyPath: nil),
                secret: { RigSecretSource.password }),
            jumpDialer: .live(knownHosts: knownHosts),
            internetSpeedTransport: .neverAsked,
            stepTimeout: stepTimeout, appVersion: "test")
    }
}

/// The rig's one password, for the target's login.
private struct RigSecretSource: SecretSource {
    static let password = "testpass"
    let label = "rig"
    func secret(for _: UUID) throws -> String? { Self.password }
}
