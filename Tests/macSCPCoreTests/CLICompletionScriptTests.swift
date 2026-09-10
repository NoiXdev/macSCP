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
/// usual Homebrew prefixes.
///
/// Where it is not installed, the case still MEASURES something: it asserts
/// that the shell that went missing is fish (zsh and bash absent would be a
/// broken lookup, not a machine without them) and that
/// `fishCandidates(inPATH:)` — the pure function the lookup itself is built
/// out of — really finds nothing on this machine's `PATH`. So "fish is not
/// installed here" is a reading, not a silent skip.
/// `theFishLookupFindsAPlantedExecutableAndOnlyThen` runs that same function
/// against a fish planted in a temporary directory, so its ability to find
/// one is measured even where none exists, and
/// `theInterpreterLookupFindsTheTwoShellsMacOSAlwaysShips` keeps the other
/// two honest.
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
        let binary = try CLIMatrix.binaryPath()
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
    /// completion is REGISTERED afterwards. Exit status alone cannot say
    /// so — `source <(cmd)` and `cmd | source` return 0 when `cmd` fails
    /// (an empty file sources cleanly; measured 2026-09-10 with
    /// `/usr/bin/false --bogus` in zsh and bash, both 0) — so each run
    /// ends in the shell's own registration probe: zsh
    /// `(( ${+_comps[macscp-cli]} ))`, bash `complete -p macscp-cli`, fish
    /// `complete -C 'macscp-cli ' | string length -q`. The same probe is
    /// what caught bash 3.2 registering nothing from `source <(…)`, which
    /// is why bash's line is the `eval "$(…)"` form.
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
        guard let interpreter = Self.interpreter(for: shell) else {
            Self.recordTheAbsenceOf(shell)
            return
        }
        let binary = try CLIMatrix.binaryPath()
        let line = ShellCompletionRecipe.line(
            for: shell, tool: ShellCompletionRecipe.quotedForShell(binary))
        let probe: String
        switch shell {
        case .zsh: probe = "(( ${+_comps[macscp-cli]} ))"
        case .bash: probe = "complete -p macscp-cli >/dev/null"
        case .fish: probe = "complete -C 'macscp-cli ' | string length -q"
        }
        let prefix = shell == .zsh ? "autoload -Uz compinit && compinit -D && " : ""
        let command = "\(prefix)\(line) && \(probe)"
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
        guard let interpreter = Self.interpreter(for: shell) else {
            Self.recordTheAbsenceOf(shell)
            return
        }
        let path = "/Applications/mac SCP's copy.app/Contents/MacOS/macscp-cli"
        let result = try await Self.runProcess(
            interpreter, ["-c", "/bin/echo -n \(ShellCompletionRecipe.quotedForShell(path))"])
        #expect(result.status == 0, "\(interpreter) -c exited \(result.status): \(result.stderr)")
        #expect(result.stdout == path, """
            \(interpreter) turned the quoted path into \(result.stdout)
            """)
    }

    /// The positive beside the two early returns above (CLAUDE.md, "a
    /// negative check needs a positive check beside it"): a lookup that had
    /// gone blind — a wrong path, a broken PATH split — would make both
    /// tests return without measuring anything and still report green. zsh
    /// and bash ship with macOS, so their absence is a broken lookup, not a
    /// machine without them.
    @Test func theInterpreterLookupFindsTheTwoShellsMacOSAlwaysShips() {
        #expect(Self.interpreter(for: .zsh) == "/bin/zsh")
        #expect(Self.interpreter(for: .bash) == "/bin/bash")
    }

    /// The fish branch, measured on a machine that may well not have fish:
    /// a `fish` planted in a temporary directory is found when that
    /// directory is on the `PATH` handed in, and is not found when it is
    /// not. Both directions, because "finds everything" and "finds nothing"
    /// are the two ways a lookup can be useless.
    @Test func theFishLookupFindsAPlantedExecutableAndOnlyThen() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-fish-lookup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A directory URL's path carries a trailing slash, and a PATH entry
        // does not; the difference is invisible to the file system but not
        // to a string comparison.
        var pathEntry = directory.path(percentEncoded: false)
        if pathEntry.hasSuffix("/") { pathEntry.removeLast() }
        let planted = "\(pathEntry)/fish"
        #expect(FileManager.default.createFile(
            atPath: planted,
            contents: Data("#!/bin/sh\nexit 0\n".utf8),
            attributes: [.posixPermissions: 0o755]))

        let onPATH = Self.fishCandidates(inPATH: "\(pathEntry):/nonexistent")
        #expect(onPATH.first == planted, """
            a fish planted at \(planted) was not the first candidate; the \
            lookup found \(onPATH)
            """)

        let offPATH = Self.fishCandidates(inPATH: "/nonexistent")
        #expect(!offPATH.contains(planted), """
            the lookup found \(planted) with its directory off the PATH -- it \
            is not reading the PATH it was handed
            """)
    }

    // MARK: - Harness

    /// The interpreter to run a shell's line in, or `nil` when this machine
    /// has none. zsh and bash are at their macOS paths; fish goes through
    /// `fishCandidates(inPATH:)` below.
    static func interpreter(for shell: ShellCompletionRecipe.Shell) -> String? {
        switch shell {
        case .zsh: return executable("/bin/zsh")
        case .bash: return executable("/bin/bash")
        case .fish: return fishCandidates(inPATH: currentPATH).first
        }
    }

    static var currentPATH: String { ProcessInfo.processInfo.environment["PATH"] ?? "" }

    /// Every `fish` the lookup can actually see, in the order it would take
    /// them: one per `PATH` entry, then the two usual Homebrew prefixes. A
    /// file check rather than a `which` subprocess, which keeps this
    /// synchronous and out of the way of the cooperative pool.
    ///
    /// Pure and parameterised on `PATH` on purpose. The fish branch is the
    /// only one that may legitimately come back empty, which used to make it
    /// the only one whose correctness was never measured on a machine
    /// without fish — the branch could have been searching nothing and read
    /// exactly like "not installed here" (Task 1 review, 2026-09-10). With
    /// the `PATH` passed in, a test plants a fish of its own and reads the
    /// decision back.
    static func fishCandidates(inPATH path: String) -> [String] {
        let fromPATH = path
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { "\($0)/fish" }
        return (fromPATH + ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"])
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// What the two interpreter-level cases assert INSTEAD of running, on a
    /// machine that has no fish. Both halves are real claims: only fish may
    /// be missing, and the same pure lookup the guard used must agree that
    /// there is nothing to find.
    static func recordTheAbsenceOf(_ shell: ShellCompletionRecipe.Shell) {
        #expect(shell == .fish, """
            no interpreter was found for \(shell.rawValue), which macOS ships \
            at a fixed path -- that is a broken lookup, not a machine without \
            the shell
            """)
        let found = fishCandidates(inPATH: currentPATH)
        #expect(found.isEmpty, """
            interpreter(for: .fish) came back nil while fishCandidates(inPATH:) \
            finds \(found) -- the two disagree, so the skip above is not the \
            measurement it claims to be
            """)
    }

    private static func executable(_ path: String) -> String? {
        FileManager.default.isExecutableFile(atPath: path) ? path : nil
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

}
