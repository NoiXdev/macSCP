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
    /// build actually wires EVERY subcommand into `MacSCPCLI`, run against
    /// the real built binary the same way `CLISessionsJSONRoundtripTests`
    /// does (bundle-relative lookup, no dependency on a `swift build` this
    /// test would trigger itself).
    ///
    /// The names are READ from the binary's own `--help`
    /// (`CLIMatrix.subcommands(binary:)`) rather than listed here. A list
    /// written out goes one behind the day a subcommand is added and keeps
    /// passing — which is exactly what it did: this loop still named six on
    /// 2026-09-04, when `diagnose` had made it seven, while the sentence
    /// above it claimed all of them. There is no number in this comment for
    /// the same reason.
    ///
    /// The two positives beside the loop are what stop it from asserting
    /// nothing: the set is non-empty, and it carries a name that has been
    /// there since the first subcommand.
    @Test func theGeneratedZshScriptNamesEverySubcommand() async throws {
        let binary = try CLIMatrix.binaryPath()
        let names = try await CLIMatrix.subcommands(binary: URL(fileURLWithPath: binary))
        #expect(!names.isEmpty, "the binary offers no subcommands at all")
        #expect(names.contains("ls"), "the binary offers no ls: \(names)")

        let result = try await Self.runProcess(binary, ["--generate-completion-script", "zsh"])
        #expect(result.status == 0, "--generate-completion-script zsh failed: \(result.stderr)")
        for name in names {
            #expect(result.stdout.contains(name), "zsh completion script does not name '\(name)'")
        }
    }

    /// `--group` and `--tag`'s VALUE completion (`GroupTagCompletion`,
    /// docs/BACKLOG.md's "CLI: completion, help, host list", the item left
    /// open after session-name completion shipped): `swift-argument-parser`
    /// wires a `.custom` completion into the generated zsh script as a call
    /// to `__<binary>_custom_complete ---completion <command path> --
    /// <option>`, so the positive proof that these two options actually get
    /// DYNAMIC completion (not the generator's static fallback) is that exact
    /// call, present in the real generated script — the same binary-level
    /// proof `theGeneratedZshScriptNamesEverySubcommand` uses for
    /// subcommands, one level down.
    ///
    /// The command PATH in that call is the one the option really sits on,
    /// and neither half of it is written here any more. It used to be the
    /// literal `sessions`, and it went stale the moment `sessions` became a
    /// group (2026-09-06): the options moved onto its verbs, the generated
    /// call became `---completion sessions list -- --group`, and the literal
    /// matched nothing. So both sides are READ from the binary: which verbs
    /// the group offers, and which of them advertise the option — then the
    /// wired set must equal the advertising set, in both directions. A verb
    /// that offers `--group` without dynamic completion is red, and so is a
    /// wiring left behind on a verb that no longer takes the option.
    @Test func theGeneratedZshScriptWiresCustomCompletionForGroupAndTag() async throws {
        let binary = try CLIMatrix.binaryPath()
        let script = try await Self.runProcess(binary, ["--generate-completion-script", "zsh"])
        #expect(script.status == 0, "--generate-completion-script zsh failed: \(script.stderr)")

        let groupHelp = try await Self.runProcess(binary, ["help", "sessions"])
        #expect(groupHelp.status == 0, "help sessions failed: \(groupHelp.stderr)")
        let verbs = CLIMatrix.parseSubcommands(groupHelp.stdout)
        #expect(!verbs.isEmpty, "the sessions group offers no verbs at all")

        // One help run per verb, not one per verb per option: the options
        // are read out of the same text, and launching the binary again for
        // the second one buys nothing.
        var optionsByVerb: [String: Set<String>] = [:]
        for verb in verbs {
            let help = try await Self.runProcess(binary, ["help", "sessions", verb])
            #expect(help.status == 0, "help sessions \(verb) failed: \(help.stderr)")
            optionsByVerb[verb] = CLIMatrix.parseOptionNames(help.stdout)
        }

        for option in ["--group", "--tag"] {
            let advertising = verbs.filter { optionsByVerb[$0]?.contains(option) == true }
            let wired = verbs.filter {
                script.stdout.contains("---completion sessions \($0) -- \(option)")
            }
            #expect(
                !advertising.isEmpty,
                "no verb of the sessions group advertises \(option) at all")
            // The listing verb by name, as the one anchor that has carried
            // both options since before the group existed: an option scan
            // that had gone blind would satisfy the set equality below with
            // two empty sets, and `advertising` being non-empty alone does
            // not say WHICH verb was found.
            #expect(
                advertising.contains("list"),
                "the listing verb advertises no \(option): \(advertising)")
            #expect(
                wired.sorted() == advertising.sorted(),
                """
                \(option) is advertised by \(advertising.sorted()) and given \
                custom completion on \(wired.sorted())
                """)
        }
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
