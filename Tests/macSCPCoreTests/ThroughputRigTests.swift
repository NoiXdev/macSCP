import Foundation
import Testing

@testable import macSCPCore

/// The throughput test against the Docker rig's `sshd` (127.0.0.1:2222,
/// `testuser`/`testpass`), over the real SFTP backend: the step ends with no
/// file of its own left on the server — after a finished run, and after a
/// run cancelled mid-upload — and its sweep removes an earlier run's file
/// while leaving a name that only looks like one.
///
/// The connection is `CitadelFileSystem.connect` — the browser's own SFTP
/// file system — over a store holding the rig's recorded host keys and the
/// refusing decider, as `ConnectionDiagnosticsJumpRigTests` dials. No rate
/// is asserted; the row is only required to be `ok`.
@Suite(
    "The throughput test, against the rig",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized,
    .timeLimit(.minutes(3))
)
struct ThroughputRigTests {
    @Test func aFinishedRunLeavesNoFileAndSweepsOnlyAnEarlierRunsFile() async throws {
        let (directory, knownHosts) = try await Self.rigStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fs = try await Self.connect(knownHosts)
        let home = try await fs.homeDirectoryPath()
        let leftover = RemotePath.join(
            home, ThroughputProbe.fileName(for: UUID()))
        let lookalike = RemotePath.join(home, ThroughputProbe.namePrefix + "notes-\(UUID())")
        try await fs.write(path: leftover, contents: Self.bytes("an earlier run"))
        try await fs.write(path: lookalike, contents: Self.bytes("the user's own"))

        let report = await Self.diagnostics(knownHosts).run(scope: .throughput)

        let step = try #require(report.steps.last)
        #expect(step.id == DiagnosticStepID.throughput)
        #expect(step.outcome == .ok, "\(step.outcome.label) — \(step.detail)")
        #expect(step.detail.contains("1 leftover from an earlier run removed"), "\(step.detail)")
        let names = try await fs.list(path: home).map(\.name)
        let testFiles = names.filter { $0.hasPrefix(ThroughputProbe.namePrefix) }
        #expect(testFiles == [String(lookalike.split(separator: "/").last ?? "")], """
            the rig's home holds \(testFiles) after the run
            """)
        try await fs.delete(path: lookalike)
        await fs.disconnect()
    }

    /// Cancelled with one chunk on the server: the upload's bucket takes its
    /// first chunk, then parks in its sleep until the cancellation reaches
    /// it. The removal runs over the same SFTP session after the cancel.
    @Test func aRunCancelledMidUploadLeavesNoFile() async throws {
        let (directory, knownHosts) = try await Self.rigStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reached = AsyncSignal()
        let fixed = ContinuousClock.now
        let parkingBucket = BandwidthBucket(
            bytesPerSecond: TransferChunk.size, now: { fixed },
            sleep: { _ in
                reached.signal()
                _ = await AsyncSignal().wait()
                throw CancellationError()
            })
        let diagnostics = Self.diagnostics(knownHosts, uploadThrottle: parkingBucket)

        let run = Task { await diagnostics.run(scope: .throughput) }
        #expect(await reached.wait() == .signalled)
        run.cancel()
        let report = await run.value

        #expect(report.completion == .cancelled(afterSteps: 1))
        let fs = try await Self.connect(knownHosts)
        let home = try await fs.homeDirectoryPath()
        let testFiles = try await fs.list(path: home).map(\.name)
            .filter { $0.hasPrefix(ThroughputProbe.namePrefix) }
        #expect(testFiles.isEmpty, "the rig's home holds \(testFiles) after the cancel")
        await fs.disconnect()
    }

    // MARK: - Fixtures

    private static let password = "testpass"

    private static func rigStore() async throws -> (URL, KnownHostsStore) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-throughput-\(UUID().uuidString)")
        let store = try await CitadelFileSystemIntegrationTests.rigKnownHosts(in: directory)
        return (directory, store)
    }

    private static func connect(_ knownHosts: KnownHostsStore) async throws -> CitadelFileSystem {
        try await CitadelFileSystem.connect(
            config: SSHConnectionConfig(
                host: "127.0.0.1", port: 2222, username: "testuser",
                auth: .password(password)),
            connectTimeout: .seconds(20), knownHosts: knownHosts, onUnknownHostKey: .refusing)
    }

    private static func diagnostics(
        _ knownHosts: KnownHostsStore, uploadThrottle: BandwidthBucket? = nil
    ) -> ConnectionDiagnostics {
        var values = SSHFieldSchema.defaults
        values[SSHField.host] = "127.0.0.1"
        values[SSHField.port] = "2222"
        values[SSHField.username] = "testuser"
        values[SSHField.authKind] = StoredSession.AuthKind.password.rawValue
        return ConnectionDiagnostics(
            descriptor: .descriptor(for: .ssh), values: values,
            secrets: ThroughputRigSecretSource(), sessionID: UUID(), jump: nil,
            jumpDialer: .live(knownHosts: knownHosts),
            throughput: DiagnosticThroughputSettings(
                payloadMiB: 1, uploadThrottle: uploadThrottle),
            throughputOpener: DiagnosticThroughputOpener { config, seconds in
                guard case .ssh(let ssh) = config else {
                    throw RemoteFSError.protocolError(reason: "not an SSH config")
                }
                return try await CitadelFileSystem.connect(
                    config: ssh, connectTimeout: .seconds(Int64(seconds)),
                    knownHosts: knownHosts, onUnknownHostKey: .refusing)
            },
            internetSpeedTransport: .neverAsked,
            stepTimeout: .seconds(20), appVersion: "test")
    }

    private static func bytes(_ text: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data(text.utf8))
            continuation.finish()
        }
    }
}

/// The rig's one password.
private struct ThroughputRigSecretSource: SecretSource {
    let label = "rig"
    func secret(for _: UUID) throws -> String? { "testpass" }
}
