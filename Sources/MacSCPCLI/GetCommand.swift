import ArgumentParser
import Foundation
import macSCPCore

/// Downloads a single remote file into a local directory, keeping the
/// remote file's own name. `TransferPlan`/`TransferEngine` do not support
/// renaming a file in flight (`TransferPlan.jobs` always derives the target
/// name from the SOURCE's basename), so `destination` here is always a
/// directory, never an exact target file path — pretending otherwise would
/// mean silently ignoring a requested rename instead of doing it (M20
/// Task 10).
struct GetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get", abstract: "Download a remote file into a local directory.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Remote source file, e.g. prod:/var/log/app.log") var source: String
    @Argument(help: "Local destination directory (the file keeps its remote name)")
    var destination: String

    @Option(name: .long, help: "What to do if the destination exists: fail, skip or overwrite.")
    var onConflict: ConflictAction = .fail

    func run() async throws {
        let reference = SessionReference.parse(source)
        let fs = try await connect(to: reference, options: options)
        // Awaited disconnect on every path (success, skip, and error) —
        // mirrors `LsCommand`: the process exits right after `run()`
        // returns, so a detached `Task` in a `defer` has no guarantee of
        // running before that happens.
        do {
            let sourceItem = try await fs.stat(path: reference.path)
            try TransferSourceGuard.checkNotDirectory(sourceItem)

            let targetPath = RemotePath.join(destination, sourceItem.name)
            let exists = FileManager.default.fileExists(atPath: targetPath)
            let jobs = try TransferPlan.jobs(
                source: reference.path, destinationDirectory: destination,
                destinationExists: exists, action: onConflict)
            guard let job = jobs.first else {
                if options.verbose { OutputFormatter.note("skipped: \(targetPath)") }
                await fs.disconnect()
                return
            }
            try await TransferEngine.copyFile(
                from: fs, sourcePath: job.source,
                to: LocalFileSystem(), destinationDirectory: destination,
                fileName: sourceItem.name
            ) { _ in }
            await fs.disconnect()
            if options.verbose { OutputFormatter.note("downloaded to \(job.destination)") }
        } catch {
            await fs.disconnect()
            throw error
        }
    }
}
