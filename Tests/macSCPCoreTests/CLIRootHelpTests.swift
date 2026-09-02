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
        let binary = try Self.locateCLIBinary()
        let result = try await Self.runProcess(binary, ["--help"])
        #expect(result.status == 0, "--help failed: \(result.stderr)")
        #expect(result.stdout.contains("name:/path"), "root help does not mention name:/path")
        #expect(result.stdout.contains("sessions"), "root help does not mention sessions")
    }

    // MARK: - Binary-level harness (self-contained rather than shared — see
    // `CLISessionsJSONRoundtripTests`'s doc comment for why each
    // gated/ungated suite here carries its own small copy)

    /// Exists only so `locateCLIBinary()` has a class defined in THIS file
    /// to hand `Bundle(for:)`.
    private final class TestBundleAnchor {}

    /// Locates the already-built `macscp-cli` binary, bundle-relative — see
    /// `CLISessionsJSONRoundtripTests.locateCLIBinary` for why: it
    /// deliberately does not run `swift build` (that would deadlock on
    /// SwiftPM's `.build` lock), and reading a repo-root-relative
    /// `.build/debug` path instead of the test bundle's own sibling breaks
    /// under `--scratch-path` and `-c release`.
    private static func locateCLIBinary() throws -> String {
        if let override = ProcessInfo.processInfo.environment["MACSCP_CLI_BINARY"],
           !override.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw HarnessError(
                    "MACSCP_CLI_BINARY is set to \(override), which is not executable")
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

    private struct HarnessError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
