import Foundation
import Testing

/// The CLI wiring for `name:` shell completion — everything that is
/// actually CLI-specific about it, which is only that
/// `--generate-completion-script` emits a script naming every subcommand.
///
/// The decision logic itself (prefix filtering, sorting, the `"name:"`
/// formatting, the store-opening convenience) lives in `macSCPCore` as
/// `SessionNameCompleter` and is tested directly there
/// (`SessionNameCompleterTests`) — moved out of this file in the fix round
/// after `ae0078c`'s review (Important finding I-2): decision logic belongs
/// in Core, the CLI stays wiring, and `macSCPCoreTests` has no business
/// depending on the `MacSCPCLI` executable target to test a pure function.
/// This file is left with exactly what remains CLI-only: whether the
/// generated script actually wires the completer's subcommands in, proven
/// against the real built binary rather than assumed.
@Suite("CLI session name completion")
struct CLISessionNameCompletionTests {
    // MARK: - Binary-level: the generated script names every subcommand

    /// `swift-argument-parser`'s generator writes the static half of
    /// completion (subcommands and flags) straight from the command tree —
    /// nothing in this task touches it — so this is a smoke test that the
    /// build actually wires all seven subcommands into `MacSCPCLI`, run
    /// against the real built binary the same way
    /// `CLISessionsJSONRoundtripTests` does (bundle-relative lookup, no
    /// dependency on a `swift build` this test would trigger itself).
    @Test func theGeneratedZshScriptNamesEverySubcommand() async throws {
        let binary = try Self.locateCLIBinary()
        let result = try await Self.runProcess(binary, ["--generate-completion-script", "zsh"])
        #expect(result.status == 0, "--generate-completion-script zsh failed: \(result.stderr)")
        for name in ["sessions", "ls", "get", "put", "rm", "mkdir"] {
            #expect(result.stdout.contains(name), "zsh completion script does not name '\(name)'")
        }
    }

    // MARK: - Binary-level harness (self-contained rather than shared —
    // see `CLISessionsJSONRoundtripTests`'s doc comment for why each
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
