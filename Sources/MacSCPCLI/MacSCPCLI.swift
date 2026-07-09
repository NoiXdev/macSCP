import ArgumentParser
import Foundation
import macSCPCore

@main
struct MacSCPCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macscp-cli",
        abstract: "Listet ein Remote-Verzeichnis über SFTP (M1-Treiber)."
    )

    @Option(name: .long, help: "SSH-Host") var host: String
    @Option(name: .long, help: "SSH-Port") var port: Int = 22
    @Option(name: .long, help: "Benutzername") var user: String
    @Argument(help: "Remote-Pfad") var path: String = "/"

    func run() async throws {
        guard let password = ProcessInfo.processInfo.environment["MACSCP_PASSWORD"],
              !password.isEmpty else {
            throw ValidationError("Passwort über die Umgebungsvariable MACSCP_PASSWORD setzen.")
        }

        let config = try SSHConnectionConfig(host: host, port: port, username: user, auth: .password(password))
        let fs = try await CitadelFileSystem.connect(config: config)

        do {
            let items = try await fs.list(path: path)
            let formatter = ByteCountFormatter()
            for item in items {
                let size = item.isDirectory
                    ? "-"
                    : item.size.map { formatter.string(fromByteCount: Int64($0)) } ?? "-"
                let suffix = item.isDirectory ? "/" : ""
                print("\(item.name)\(suffix)\t\(size)")
            }
        } catch {
            await fs.disconnect()
            throw error
        }
        await fs.disconnect()
    }
}
