import ArgumentParser
import Foundation
import macSCPCore

/// Creates a remote directory. `createDirectory(at:)` is idempotent — an
/// already-existing directory at the path is not an error — so this command
/// has no conflict handling to worry about (M20 Task 11).
struct MkdirCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mkdir", abstract: "Create a remote directory.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Remote path, e.g. prod:/var/www/new") var target: String

    func run() async throws {
        let reference = SessionReference.parse(target)
        try await withConnection(to: reference, options: options) { fs in
            try await fs.createDirectory(at: reference.path)
        }
    }
}
