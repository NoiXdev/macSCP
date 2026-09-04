import Foundation
import Testing
@testable import macSCPCore

/// `sessions --json` reads the store only — no rig, no connection, no
/// `--accept-new` — so unlike `CLIRoundtripITests` this suite is UNGATED
/// (no `MACSCP_ITEST`): it seeds a session straight into a temp store and
/// runs the built `macscp-cli` binary as a subprocess against it, the same
/// way `CLIRoundtripITests` drives every other subcommand. This test used
/// to live inside `CLIRoundtripITests` (gated behind the Docker rig) even
/// though it never touches the rig — it moved out once `locateCLIBinary()`
/// became bundle-relative (final-branch-review finding, 2026-09-02) rather
/// than a third copy of the old repo-root-relative lookup.
@Suite("CLI sessions --json roundtrip")
struct CLISessionsJSONRoundtripTests {
    /// Confirms the whole path end to end through the real subprocess: the
    /// tag and group filters, and that `--json` emits one line whose fields
    /// match what was stored.
    @Test func sessionsJSONListsAStoredSessionWithItsGroupAndTags() async throws {
        let binary = try Self.locateCLIBinary()
        let storageDirectory = try Self.makeTempDirectory(prefix: "macscp-cli-sessions-storage")
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let store = SessionStore(directory: storageDirectory)
        let group = StoredGroup(name: "Work")
        try store.upsertGroup(group)
        var session = sshSession(
            name: "m2-sessions-list", host: "example.org", port: 2200,
            username: "alice", groupID: group.id)
        session.tags = ["prod"]
        try store.upsert(session)

        let result = try await Self.runCLI(
            binary, ["sessions", "--json"], storageDirectory: storageDirectory)
        #expect(result.status == 0, "sessions failed: \(result.stderr)")

        let lines = result.stdout.split(separator: "\n")
        #expect(lines.count == 1, "expected exactly one session line, got \(lines.count)")
        guard let line = lines.first,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            Issue.record("sessions --json did not emit a parseable JSON line: \(result.stdout)")
            return
        }
        #expect(object["name"] as? String == "m2-sessions-list")
        #expect(object["kind"] as? String == "ssh")
        #expect(object["target"] as? String == "alice@example.org:2200")
        #expect(object["group"] as? String == "Work")
        #expect(object["tags"] as? [String] == ["prod"])
    }

    // MARK: - Test harness (still self-contained, not yet folded into
    // `CLIMatrix.binaryURL()`: `CLIRoundtripITests` and every suite in
    // `CLIMatrixITests.swift` call through that shared lookup, but this
    // suite, `CLIRootHelpTests` and `CLISessionNameCompletionTests` still
    // each carry their own small copy of it — `CLISessionsKindHelpTextTests`
    // did the same before it was deleted, for the same reason stated
    // there).

    /// Exists only so `locateCLIBinary()` has a class defined in THIS file
    /// to hand `Bundle(for:)`.
    private final class TestBundleAnchor {}

    private static func makeTempDirectory(prefix: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Locates the already-built `macscp-cli` binary, bundle-relative —
    /// see `CLIMatrix.binaryURL()` for why: it deliberately does not run
    /// `swift build` (that would deadlock on SwiftPM's `.build` lock), and
    /// reading a repo-root-relative `.build/debug` path instead of the test
    /// bundle's own sibling breaks under `--scratch-path` and `-c release`.
    /// (`CLIRoundtripITests` used to carry this same lookup under this same
    /// name; it now calls through `CLIMatrix.binaryURL()` instead, folded
    /// there when Task 4 of the CLI test matrix plan closed out.)
    private static func locateCLIBinary() throws -> String {
        if let override = ProcessInfo.processInfo.environment["MACSCP_CLI_BINARY"],
           !override.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw HarnessError("MACSCP_CLI_BINARY is set to \(override), which is not executable")
            }
            return override
        }
        let productsDirectory = Bundle(for: TestBundleAnchor.self).bundleURL
            .deletingLastPathComponent()
        let binaryPath = productsDirectory
            .appendingPathComponent("macscp-cli")
            .path(percentEncoded: false)
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw HarnessError("""
                macscp-cli not found at \(binaryPath).
                Build it before running this suite:
                  swift build --product macscp-cli
                or point MACSCP_CLI_BINARY at an existing binary.
                """)
        }
        return binaryPath
    }

    /// Runs the built CLI binary as a subprocess with an isolated storage
    /// directory and no controlling terminal (stdin is the null device).
    /// Draining, the bound and the kill escalation all live in
    /// `SubprocessRunner`, which awaits the child instead of parking a
    /// cooperative-pool thread on it — see that type's doc comment, and
    /// CLAUDE.md's "Tests never block the cooperative pool".
    private static func runCLI(
        _ binary: String, _ arguments: [String], storageDirectory: URL
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        var environment = ProcessInfo.processInfo.environment
        environment["MACSCP_STORAGE_DIRECTORY"] = storageDirectory.path(percentEncoded: false)
        let result = try await SubprocessRunner.run(
            URL(fileURLWithPath: binary), arguments: arguments, environment: environment)
        return (result.status, result.stdoutText, result.stderrText)
    }

    private struct HarnessError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
