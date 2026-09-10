import Foundation
import Testing

/// The root command's `--help` screen: whether it explains the `name:/path`
/// addressing scheme every other subcommand's `target` argument uses (Task 2
/// of the 2026-09-02 CLI-completion plan, item 3 of the CLI entry).
///
/// Run against the real built binary, the same bundle-relative way
/// `CLISessionsJSONRoundtripTests` and `CLISessionNameCompletionTests` do —
/// `--help` is dispatched through `MacSCPCLI.main()`'s own catch (see the
/// doc comment there on why a help request is not a parse-time error), so
/// asserting on the in-process `CommandConfiguration` would not exercise
/// that path at all.
@Suite("CLI root --help")
struct CLIRootHelpTests {
    @Test func theRootHelpExplainsNameColonPath() async throws {
        let binary = try CLIMatrix.binaryPath()
        let result = try await Self.runProcess(binary, ["--help"])
        #expect(result.status == 0, "--help failed: \(result.stderr)")
        #expect(result.stdout.contains("name:/path"), "root help does not mention name:/path")
        #expect(result.stdout.contains("sessions"), "root help does not mention sessions")
    }

    // MARK: - Binary-level harness (the binary itself is located by
    // `CLIMatrix.binaryPath()`, this target's one lookup)

    /// Draining, the bound and the kill escalation all live in
    /// `SubprocessRunner`, which awaits the child instead of parking a
    /// cooperative-pool thread on it — see that type's doc comment, and
    /// CLAUDE.md's "Tests never block the cooperative pool".
    private static func runProcess(
        _ executable: String, _ arguments: [String]
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        let result = try await SubprocessRunner.run(
            URL(fileURLWithPath: executable), arguments: arguments)
        return (result.status, result.stdoutText, result.stderrText)
    }

}
