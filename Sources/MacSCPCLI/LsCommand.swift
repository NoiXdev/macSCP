import ArgumentParser
import Foundation
import macSCPCore

struct LsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List a remote directory.")

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Session reference, e.g. prod:/var/www") var target: String

    func run() async throws {
        let reference = SessionReference.parse(target)
        let fs = try await connect(to: reference, options: options)
        // Awaited disconnect, not a fire-and-forget `Task { }` in a `defer`:
        // this process exits right after `run()` returns, and a detached
        // task has no guarantee of running before that happens. Mirrors the
        // M1 driver's own do/catch-disconnect-rethrow shape.
        do {
            let items = try await fs.list(path: reference.path)
            await fs.disconnect()
            OutputFormatter.print(items: items, asJSON: options.json)
        } catch {
            await fs.disconnect()
            throw error
        }
    }
}
