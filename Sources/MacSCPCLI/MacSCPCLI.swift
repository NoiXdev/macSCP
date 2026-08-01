import ArgumentParser
import Foundation
import macSCPCore

@main
struct MacSCPCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macscp-cli",
        abstract: "Lists a remote directory over SFTP (M1 driver)."
    )

    @Option(name: .long, help: "SSH host") var host: String
    @Option(name: .long, help: "SSH port") var port: Int = 22
    @Option(name: .long, help: "Username") var user: String
    @Argument(help: "Remote path") var path: String = "/"

    func run() async throws {
        guard let password = ProcessInfo.processInfo.environment["MACSCP_PASSWORD"],
              !password.isEmpty else {
            throw ValidationError("Set the password via the MACSCP_PASSWORD environment variable.")
        }

        let config = try SSHConnectionConfig(host: host, port: port, username: user, auth: .password(password))
        let fs = try await BackendConnector.connect(
            .ssh(config),
            // CLI driver: automatically trust unknown host keys and print the
            // fingerprint to stderr for traceability.
            decider: { candidate in
                FileHandle.standardError.write(Data(
                    "Host key \(candidate.fingerprintSHA256) trusted automatically (CLI driver)\n".utf8))
                return true
            }
        )

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
