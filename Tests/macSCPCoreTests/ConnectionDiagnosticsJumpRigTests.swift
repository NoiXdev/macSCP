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
    @Test func everyJumpStepAndTheChannelThroughItAreOk() async throws {
        let (directory, knownHosts) = try await Self.rigStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = await Self.diagnostics(
            target: "sshd2", port: 2222, knownHosts: knownHosts
        ).run()

        #expect(report.steps.map(\.id) == [
            DiagnosticStepID.jumpResolve, DiagnosticStepID.jumpTCP, DiagnosticStepID.jumpICMP,
            DiagnosticStepID.jumpDial, DiagnosticStepID.jumpTrace,
            DiagnosticStepID.targetTCPViaJump, DiagnosticStepID.targetDialViaJump,
        ])
        for step in report.steps {
            #expect(step.outcome == .ok, "\(step.id): \(step.outcome.label) — \(step.detail)")
        }
        #expect(report.jump == Endpoint(host: "127.0.0.1", port: 2222))
    }

    /// The same target without its jump: this Mac cannot even resolve it.
    /// The positive half of the case above — the rows there are `ok` because
    /// the walk went through the jump, not because `sshd2` answers from here.
    @Test func withoutItsJumpTheTargetDoesNotResolveFromHere() async throws {
        var values = Self.targetValues(host: "sshd2", port: 2222)
        values[SSHField.authKind] = StoredSession.AuthKind.password.rawValue
        let report = await ConnectionDiagnostics(
            descriptor: .descriptor(for: .ssh), values: values, secrets: nil, jump: nil
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

    private static func diagnostics(
        target host: String, port: Int, knownHosts: KnownHostsStore
    ) -> ConnectionDiagnostics {
        ConnectionDiagnostics(
            descriptor: .descriptor(for: .ssh), values: targetValues(host: host, port: port),
            secrets: RigSecretSource(), sessionID: UUID(),
            jump: DiagnosticJump(
                endpoint: Endpoint(host: "127.0.0.1", port: 2222),
                login: .init(username: "testuser", authKind: .password, keyPath: nil),
                secret: { RigSecretSource.password }),
            jumpDialer: .live(knownHosts: knownHosts),
            stepTimeout: .seconds(20), appVersion: "test")
    }
}

/// The rig's one password, for the target's login.
private struct RigSecretSource: SecretSource {
    static let password = "testpass"
    let label = "rig"
    func secret(for _: UUID) throws -> String? { Self.password }
}
