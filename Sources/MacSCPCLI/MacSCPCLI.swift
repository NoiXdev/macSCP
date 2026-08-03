import ArgumentParser
import Foundation
import macSCPCore

/// Root dispatcher: subcommands do the work, this type just lists them.
/// `get`/`put` landed in M20 Task 10; `rm`/`mkdir` complete the set in
/// M20 Task 11.
@main
struct MacSCPCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macscp-cli",
        abstract: "Work with stored macSCP sessions over SFTP and S3.",
        subcommands: [
            LsCommand.self, GetCommand.self, PutCommand.self,
            RmCommand.self, MkdirCommand.self,
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
