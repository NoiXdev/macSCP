import ArgumentParser
import Foundation
import macSCPCore

/// Root dispatcher: subcommands do the work, this type just lists them.
/// Only `ls` exists so far (M20 Task 8) — `get`/`put`/`rm`/`mkdir` are added
/// to `subcommands` in the tasks that create them (M20 Task 10/11), per the
/// implementation plan.
@main
struct MacSCPCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macscp-cli",
        abstract: "Work with stored macSCP sessions over SFTP and S3.",
        subcommands: [LsCommand.self]
    )
}
