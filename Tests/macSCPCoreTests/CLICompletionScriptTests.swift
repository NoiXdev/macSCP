import Foundation
import Testing
@testable import macSCPCore

/// The other half of `ShellCompletionRecipeTests`: that the lines the
/// recipe spells actually WORK — the built `macscp-cli` really generates a
/// script for every shell in `ShellCompletionRecipe.Shell`, and a real
/// interpreter really loads it.
///
/// Ungated (no `MACSCP_ITEST`): nothing here connects anywhere, it only
/// runs the already-built binary the way `CLISessionsJSONRoundtripTests`
/// does. `swift-argument-parser`'s generator is what produces the scripts;
/// this suite is the proof that the app's picker cannot offer a shell the
/// CLI has no script for.
///
/// **Which interpreters are measured depends on the machine.** `/bin/zsh`
/// and `/bin/bash` ship with macOS, so those two are always run. **fish is
/// run only where it is installed** — looked up on `PATH` and in the two
/// usual Homebrew prefixes — and where it is not, that shell's case
/// returns having asserted nothing rather than recording a pass it did not
/// measure. `theInterpreterLookupFindsTheTwoShellsMacOSAlwaysShips` below
/// keeps the lookup itself honest, so "not installed" cannot quietly
/// become "never looked".
///
/// Bounded by the suite's `.timeLimit` alone — no elapsed-time assertion
/// (CLAUDE.md, "A wall-clock ceiling in a test measures the runner").
@Suite("CLI completion script", .timeLimit(.minutes(2)))
struct CLICompletionScriptTests {
    // MARK: - The binary generates a script for every shell in the enum

    /// The first line each shell's generator emits, measured on the debug
    /// binary on 2026-09-08: zsh 429 lines starting `#compdef macscp-cli`,
    /// bash 653 starting `#!/bin/bash`, fish 262 starting with the
    /// `function __macscp-cli…` helper. Only the first line is asserted —
    /// the line counts are a measurement, not a contract, and pinning them
    /// would go red on every swift-argument-parser update.
    @Test(arguments: ShellCompletionRecipe.Shell.allCases)
    func theBinaryGeneratesACompletionScriptForEveryShellInTheEnum(
        shell: ShellCompletionRecipe.Shell
    ) async throws {
        let binary = try Self.locateCLIBinary()
        let result = try await Self.runProcess(
            binary, ["--generate-completion-script", shell.rawValue])
        #expect(result.status == 0, """
            --generate-completion-script \(shell.rawValue) exited \
            \(result.status): \(result.stderr)
            """)
        #expect(!result.stdout.isEmpty, """
            --generate-completion-script \(shell.rawValue) printed nothing
            """)
        let firstLine = String(result.stdout.split(separator: "\n", omittingEmptySubsequences: false)[0])
        switch shell {
        case .zsh:
            #expect(firstLine == "#compdef macscp-cli", "zsh script starts: \(firstLine)")
        case .bash:
            #expect(firstLine == "#!/bin/bash", "bash script starts: \(firstLine)")
        case .fish:
            #expect(firstLine.contains("function __macscp-cli"), "fish script starts: \(firstLine)")
        }
    }

    // MARK: - The recipe's line loads in a real interpreter

    /// The whole point of the section: paste the line into a shell and the
    /// completion loads without an error. Run non-interactively with `-c`,
    /// so a broken script shows up as a non-zero status instead of a
    /// message nobody reads.
    ///
    /// zsh gets `autoload -Uz compinit && compinit -D && ` in front,
    /// because `#compdef` is a no-op — and `compdef` an unknown command —
    /// until the completion system is initialised. That is exactly the
    /// clause the section states to the user; `-D` keeps the run from
    /// writing a dump file into the home directory.
    ///
    /// The tool token is the built binary's own path, quoted through
    /// `quotedForShell`, so this also exercises the quoting in the three
    /// real parsers rather than only against an expected string.
    @Test(arguments: ShellCompletionRecipe.Shell.allCases)
    func theRecipesLineLoadsTheCompletionInThatShell(
        shell: ShellCompletionRecipe.Shell
    ) async throws {
        guard let interpreter = Self.interpreter(for: shell) else { return }
        let binary = try Self.locateCLIBinary()
        let line = ShellCompletionRecipe.line(
            for: shell, tool: ShellCompletionRecipe.quotedForShell(binary))
        let command = shell == .zsh ? "autoload -Uz compinit && compinit -D && \(line)" : line
        let result = try await Self.runProcess(interpreter, ["-c", command])
        #expect(result.status == 0, """
            \(interpreter) -c exited \(result.status) on the \(shell.rawValue) \
            line: \(result.stderr)
            """)
    }

    /// The quoting, proven in the parsers rather than against an expected
    /// string: a path carrying both a space and an apostrophe comes back
    /// out of the shell byte for byte. `/bin/echo` rather than a builtin,
    /// so all three shells run the same program.
    @Test(arguments: ShellCompletionRecipe.Shell.allCases)
    func theQuotedFormSurvivesAPathWithASpaceAndAnApostrophe(
        shell: ShellCompletionRecipe.Shell
    ) async throws {
        guard let interpreter = Self.interpreter(for: shell) else { return }
        let path = "/Applications/mac SCP's copy.app/Contents/MacOS/macscp-cli"
        let result = try await Self.runProcess(
            interpreter, ["-c", "/bin/echo -n \(ShellCompletionRecipe.quotedForShell(path))"])
        #expect(result.status == 0, "\(interpreter) -c exited \(result.status): \(result.stderr)")
        #expect(result.stdout == path, """
            \(interpreter) turned the quoted path into \(result.stdout)
            """)
    }

    /// The positive beside the two `guard let interpreter … else { return }`
    /// above (CLAUDE.md, "a negative check needs a positive check beside
    /// it"): a lookup that had gone blind — a wrong path, a broken PATH
    /// split — would make both tests return without measuring anything and
    /// still report green. zsh and bash ship with macOS, so their absence
    /// is a broken lookup, not a machine without them.
    @Test func theInterpreterLookupFindsTheTwoShellsMacOSAlwaysShips() {
        #expect(Self.interpreter(for: .zsh) == "/bin/zsh")
        #expect(Self.interpreter(for: .bash) == "/bin/bash")
    }

    // MARK: - Harness

    /// The interpreter to run a shell's line in, or `nil` when this machine
    /// has none. zsh and bash are at their macOS paths; fish is searched
    /// on `PATH` and in the two Homebrew prefixes — a file check rather
    /// than a `which` subprocess, which keeps this synchronous and out of
    /// the way of the cooperative pool.
    static func interpreter(for shell: ShellCompletionRecipe.Shell) -> String? {
        switch shell {
        case .zsh: return executable("/bin/zsh")
        case .bash: return executable("/bin/bash")
        case .fish:
            let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":", omittingEmptySubsequences: true)
                .map(String.init)
            let candidates = pathDirectories.map { "\($0)/fish" }
                + ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
            return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        }
    }

    private static func executable(_ path: String) -> String? {
        FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Exists only so `locateCLIBinary()` has a class defined in THIS file
    /// to hand `Bundle(for:)`.
    private final class TestBundleAnchor {}

    /// Locates the already-built `macscp-cli` binary, bundle-relative —
    /// see `CLISessionsJSONRoundtripTests.locateCLIBinary` for why: it
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
