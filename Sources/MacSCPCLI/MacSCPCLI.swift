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

    @Flag(name: .long, help: "Trust unknown host keys without asking. Never affects mismatches.")
    var acceptNew = false

    @Flag(name: .long, help: "Never prompt; fail instead.")
    var nonInteractive = false

    private var hostKeyPolicy: HostKeyPolicy {
        if acceptNew { return .acceptNew }
        return nonInteractive ? .reject : .ask
    }

    func run() async throws {
        guard let password = ProcessInfo.processInfo.environment["MACSCP_PASSWORD"],
              !password.isEmpty else {
            throw ValidationError("Set the password via the MACSCP_PASSWORD environment variable.")
        }

        let config = try SSHConnectionConfig(host: host, port: port, username: user, auth: .password(password))
        let fs = try await BackendConnector.connect(
            .ssh(config),
            decider: makeDecider(policy: hostKeyPolicy)
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

    /// Builds the decider for UNKNOWN host keys. A mismatch never gets here:
    /// `HostKeyValidation` stops it first, and this function has no branch
    /// that could accept one. The M1 driver used to trust everything — that
    /// path is gone (M20).
    private func makeDecider(policy: HostKeyPolicy) -> HostKeyDecider {
        { candidate in
            switch HostKeyPolicy.decision(for: policy, hasTTY: CLIEnvironment.hasTTY) {
            case .accept:
                FileHandle.standardError.write(Data(
                    "Trusting new host key \(candidate.fingerprintSHA256) (--accept-new)\n".utf8))
                return true
            case .reject:
                FileHandle.standardError.write(Data("""
                    Unknown host key for \(candidate.host):\(candidate.port)
                      \(candidate.keyType) \(candidate.fingerprintSHA256)
                    Confirm it interactively, or pass --accept-new to trust new hosts.

                    """.utf8))
                return false
            case .prompt:
                FileHandle.standardError.write(Data("""
                    Unknown host key for \(candidate.host):\(candidate.port)
                      \(candidate.keyType) \(candidate.fingerprintSHA256)
                    Trust this host? [y/N]
                    """.utf8))
                guard let line = readLine(strippingNewline: true) else { return false }
                return line.lowercased() == "y" || line.lowercased() == "yes"
            }
        }
    }
}
