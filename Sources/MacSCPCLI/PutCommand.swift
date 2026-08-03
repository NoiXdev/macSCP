import ArgumentParser
import Foundation
import macSCPCore

/// Uploads a single local file into a remote directory, keeping the local
/// file's own name — see `GetCommand`'s doc comment for why renaming a file
/// in flight is not supported (M20 Task 10).
struct PutCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "put", abstract: "Upload a local file into a remote directory.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Local source file") var source: String
    @Argument(help: "Remote destination directory, e.g. prod:/tmp/") var destination: String

    @Option(name: .long, help: "What to do if the destination exists: fail, skip or overwrite.")
    var onConflict: ConflictAction = .fail

    func run() async throws {
        let reference = SessionReference.parse(destination)
        try await withConnection(to: reference, options: options) { fs in
            let localFS = LocalFileSystem()
            let sourceItem = try await localFS.stat(path: source)
            try TransferSourceGuard.checkNotDirectory(sourceItem)

            let targetPath = RemotePath.join(reference.path, sourceItem.name)
            let exists = try await remoteFileExists(fs, path: targetPath)
            let jobs = try TransferPlan.jobs(
                source: source, destinationDirectory: reference.path,
                destinationExists: exists, action: onConflict)
            guard let job = jobs.first else {
                if options.verbose { OutputFormatter.note("skipped: \(targetPath)") }
                return
            }
            try await TransferEngine.copyFile(
                from: localFS, sourcePath: job.source,
                to: fs, destinationDirectory: reference.path,
                fileName: sourceItem.name
            ) { _ in }
            if options.verbose { OutputFormatter.note("uploaded to \(job.destination)") }
        }
    }

    /// `stat`-based existence check rather than listing the whole directory
    /// and matching a name: one round trip, and it checks the EXACT path the
    /// transfer will write to, not merely a name match against a directory
    /// listing.
    private func remoteFileExists(_ fs: any RemoteFileSystem, path: String) async throws -> Bool {
        do {
            _ = try await fs.stat(path: path)
            return true
        } catch RemoteFSError.notFound {
            return false
        }
    }
}
