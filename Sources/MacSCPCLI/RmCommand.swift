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
    @Argument(help: "Remote path, e.g. prod:/tmp/old.log", completion: SessionNameCompletion.kind)
    var target: String

    /// Recursive deletion is opt-in. `deleteTree(at:)` walks a whole
    /// subtree, and that is not something a typo should be able to trigger.
    @Flag(name: .shortAndLong, help: "Delete directories and their contents.")
    var recursive = false

    /// The escape hatch for the one case `--recursive` alone must not allow:
    /// deleting the session root. `SessionReference.parse` maps an empty
    /// path to "/", so a truncated or unquoted argument (`rm -r prod:`
    /// instead of `rm -r prod:/tmp/old`) would otherwise reach
    /// `deleteTree(at: "/")` — for an S3 session, every object in the
    /// bucket — with nothing standing in the way but the typo itself. A long,
    /// deliberately spelled-out flag name is the point: it is not something
    /// a mistyped path argument, or a second `-r`, could ever produce by
    /// accident (M20 final-review Finding A).
    @Flag(name: .long, help: "Required together with --recursive to delete a session root.")
    var allowRootDelete = false

    func run() async throws {
        let reference = SessionReference.parse(target)
        try await withConnection(to: reference, options: options) { fs in
            if recursive {
                let item = try await fs.stat(path: reference.path)
                try TransferSourceGuard.checkDeletable(
                    item, recursive: recursive, allowRoot: allowRootDelete)
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
