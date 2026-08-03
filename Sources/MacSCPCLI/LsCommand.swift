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
        try await withConnection(to: reference, options: options) { fs in
            let items = try await fs.list(path: reference.path)
            OutputFormatter.print(items: items, asJSON: options.json)
        }
    }
}
