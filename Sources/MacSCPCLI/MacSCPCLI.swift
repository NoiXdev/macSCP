// `@preconcurrency` because `asyncParseAsRoot()` hands back an
// `any ParsableCommand`, and ArgumentParser does not declare that
// existential `Sendable`. Returning it across the await therefore counts as
// sending a non-Sendable value out of a nonisolated context.
//
// The toolchain used to build this locally accepts it and the older one CI
// builds with rejects it, so the plain import compiles here and breaks
// there -- the same divergence recorded in
// `docs/superpowers/specs/2026-08-26-backlog-toolchain-deviation.md`.
//
// What stops being checked: Sendable violations involving ArgumentParser's
// types are no longer diagnosed in this file. That is affordable precisely
// here and nowhere else -- the value never leaves this function. It is
// parsed, run, and dropped, all within `main()`, with no concurrency of our
// own anywhere near it. An edit that stores the command, hands it to a task,
// or returns it would break that argument without breaking the build.
@preconcurrency import ArgumentParser
import Foundation
import macSCPCore

/// Root dispatcher: subcommands do the work, this type just lists them.
/// `get`/`put` landed in M20 Task 10; `rm`/`mkdir` complete the set in
/// M20 Task 11; `sessions` (2026-09-02 CLI-sessions-list plan, Task 2) is
/// the sixth and the only one that opens no connection at all; `diagnose`
/// (2026-09-04 CLI-diagnose plan, Task 2) is the seventh, and opens one
/// only when the scope it was given includes the dial. Seven subcommands
/// total — recount this comment on the next addition.
@main
struct MacSCPCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macscp-cli",
        abstract: "Work with stored macSCP sessions over SFTP, S3 and WebDAV.",
        discussion: """
            Every command below addresses its target as name:/path: name is \
            a session saved in the app, the one shown in the sidebar, and \
            everything after the first colon is the path, passed through \
            as-is — write name: alone, with nothing after the colon, for \
            the session's root. Run sessions to see the names on file, or \
            start typing one and press Tab: --generate-completion-script \
            zsh|bash|fish wires that into your shell once, and this binary \
            offers the rest from the session store afterward.
            """,
        subcommands: [
            LsCommand.self, GetCommand.self, PutCommand.self,
            RmCommand.self, MkdirCommand.self, SessionsCommand.self,
            DiagnoseCommand.self,
        ]
    )

    /// Overrides `AsyncParsableCommand`'s default `main()` so an error
    /// thrown by a subcommand's `run()` exits with `CLIErrorMapping`'s code
    /// and prints `CLIErrorMapping.message(for:)`, instead of ArgumentParser's
    /// own handling, which would flatten every non-`ArgumentParser` error to
    /// exit code 1 and print a bare `Error: <case name>` (M20 Task 10).
    ///
    /// Parse-time errors (usage validation, unknown flags) are thrown by
    /// `asyncParseAsRoot` itself, BEFORE `run()` is ever reached — they land
    /// in the OUTER catch below and fall through to ArgumentParser's own
    /// `exit(withError:)`, unchanged.
    ///
    /// A HELP REQUEST (`--help`, on the root or any subcommand) is NOT a
    /// parse-time error, despite what the M20 Task 10 version of this
    /// comment claimed: `asyncParseAsRoot` parses it into a normal
    /// `HelpCommand` instance, and it is THAT command's `run()` that throws
    /// (an ArgumentParser-internal `CommandError` wrapping
    /// `.helpRequested`) — landing in the INNER catch below, same as any of
    /// our own commands' errors. Left unhandled, that made `--help` print
    /// `CLIErrorMapping`'s generic fallback text and exit 13 instead of
    /// printing the help screen and exiting 0 (M20 Task 11 fix). The type
    /// doing the throwing is internal to ArgumentParser and not nameable
    /// here, so the inner catch distinguishes it indirectly: ArgumentParser's
    /// own `exitCode(for:)` maps any help/version/completion request to
    /// `.success`, while every error `CLIErrorMapping` knows about maps to a
    /// non-zero `CLIExitCode` — so `.success` here can only mean "hand this
    /// to ArgumentParser's own handling", never one of our own errors.
    ///
    /// Explicitly `nonisolated`: an `@main` type's `static func main()` is
    /// otherwise treated like top-level code in a `main.swift` file and
    /// implicitly runs on the main actor. `asyncParseAsRoot()` itself is a
    /// nonisolated `AsyncParsableCommand` extension method, so without this
    /// annotation the `await` below would resume on the main actor and hand
    /// the non-Sendable `any ParsableCommand` it returns across that
    /// isolation boundary — the warning this annotation removes (measured
    /// on CI, Swift 6.1.2: `MacSCPCLI.swift:82:37`, "non-sendable result
    /// type 'any ParsableCommand' cannot be sent from nonisolated context in
    /// call to static method 'asyncParseAsRoot'"; the local 6.3.3 toolchain
    /// does not diagnose it). Marking `main()` nonisolated instead keeps
    /// parsing and running in the same, already-nonisolated context the
    /// value is produced in, so it never crosses an isolation boundary at
    /// all — nothing here needs `Sendable` or an unsafe opt-out.
    nonisolated static func main() async {
        if let name = unrecognizedHelpSubcommand(in: CommandLine.arguments) {
            OutputFormatter.note("Unknown subcommand '\(name)'")
            Foundation.exit(CLIExitCode.usage.rawValue)
        }
        do {
            var command = try await asyncParseAsRoot()
            do {
                if var asyncCommand = command as? AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
            } catch {
                if exitCode(for: error) == .success {
                    exit(withError: error)
                }
                OutputFormatter.note(CLIErrorMapping.message(for: error))
                Foundation.exit(CLIErrorMapping.exitCode(for: error).rawValue)
            }
        } catch {
            exit(withError: error)
        }
    }

    /// Detects `macscp-cli help <name>` where `<name>` names no configured
    /// subcommand, so `main()` can refuse it as a usage error BEFORE
    /// `asyncParseAsRoot()` ever reaches ArgumentParser's built-in
    /// `HelpCommand`.
    ///
    /// Left alone, that built-in command's `buildCommandStack(with:)` walks
    /// as far into the subcommand tree as the given names match and stops
    /// wherever they stop matching — for a first name that matches nothing,
    /// that is the ROOT, so `help <unknown>` printed the root help and
    /// exited 0 exactly as `help` alone does (measured 2026-09-04: `help
    /// definitely-not-a-subcommand` → exit 0, root `OVERVIEW`/`USAGE`
    /// printed), indistinguishable from a real subcommand's help by exit
    /// code alone.
    ///
    /// Reads `arguments[1]` and `arguments[2]` only. `arguments[0]` is the
    /// executable path, which ArgumentParser itself never sees this way;
    /// anything past index 2 (`help ls -v`, say) is a real subcommand's own
    /// trailing arguments, not a second name to weigh in on this check.
    /// `help` with nothing after it (`arguments.count == 2`) is left alone —
    /// that is the root help request, unaffected by this fix.
    static func unrecognizedHelpSubcommand(in arguments: [String]) -> String? {
        guard arguments.count >= 3, arguments[1] == "help" else { return nil }
        let name = arguments[2]
        let known = configuration.subcommands.map { $0._commandName }
        guard !known.contains(name) else { return nil }
        return name
    }
}
