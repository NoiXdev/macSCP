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
/// the sixth and, unlike the other five, opens no connection. Six
/// subcommands total — recount this comment on the next addition.
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
    static func main() async {
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
}
