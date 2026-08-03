import ArgumentParser
import Foundation
import macSCPCore

/// Deletes a single remote file, or — with `--recursive` — a whole subtree.
/// No confirmation prompt: the CLI must stay scriptable, and the flag is the
/// only guard (M20 Task 11).
struct RmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm", abstract: "Delete a remote file or directory.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Remote path, e.g. prod:/tmp/old.log") var target: String

    /// Recursive deletion is opt-in. `deleteTree(at:)` walks a whole
    /// subtree, and that is not something a typo should be able to trigger.
    @Flag(name: .shortAndLong, help: "Delete directories and their contents.")
    var recursive = false

    func run() async throws {
        let reference = SessionReference.parse(target)
        try await withConnection(to: reference, options: options) { fs in
            if recursive {
                try await fs.deleteTree(at: reference.path)
            } else {
                // `delete(path:)` itself throws a raw `RemoteFSError
                // .protocolError` for a directory target — a `stat` plus
                // this guard turns that into a clear, actionable message
                // ("pass --recursive") instead.
                let item = try await fs.stat(path: reference.path)
                try TransferSourceGuard.checkDeletable(item, recursive: recursive)
                try await fs.delete(path: reference.path)
            }
        }
    }
}
