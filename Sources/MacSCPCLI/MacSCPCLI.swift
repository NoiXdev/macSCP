import ArgumentParser
import Foundation
import macSCPCore

/// Root dispatcher: subcommands do the work, this type just lists them.
/// `get`/`put` land in M20 Task 10 — `rm`/`mkdir` remain for a later task,
/// per the implementation plan.
@main
struct MacSCPCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macscp-cli",
        abstract: "Work with stored macSCP sessions over SFTP and S3.",
        subcommands: [LsCommand.self, GetCommand.self, PutCommand.self]
    )

    /// Overrides `AsyncParsableCommand`'s default `main()` so an error
    /// thrown by a subcommand's `run()` exits with `CLIErrorMapping`'s code
    /// and prints `CLIErrorMapping.message(for:)`, instead of ArgumentParser's
    /// own handling, which would flatten every non-`ArgumentParser` error to
    /// exit code 1 and print a bare `Error: <case name>` (M20 Task 10).
    ///
    /// Parse-time errors (help requests, usage validation, unknown flags)
    /// are thrown by `asyncParseAsRoot` itself, BEFORE `run()` is ever
    /// reached — they land in the OUTER catch below and fall through to
    /// ArgumentParser's own `exit(withError:)`, unchanged. Only an error
    /// thrown by `run()` — caught by the INNER catch — goes through
    /// `CLIErrorMapping`. This mirrors the library's own default
    /// implementation (`AsyncParsableCommand.main(_:)`) except for that one
    /// substitution.
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
                OutputFormatter.note(CLIErrorMapping.message(for: error))
                Foundation.exit(CLIErrorMapping.exitCode(for: error).rawValue)
            }
        } catch {
            exit(withError: error)
        }
    }
}
