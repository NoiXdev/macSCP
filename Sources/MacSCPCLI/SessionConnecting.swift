import ArgumentParser
import Foundation
import macSCPCore

struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Emit one JSON object per line instead of columns.")
    var json = false

    @Flag(name: .long, help: "Report which secret source answered, and other diagnostics.")
    var verbose = false

    @Flag(name: .long, help: "Never prompt; fail instead.")
    var nonInteractive = false

    @Flag(name: .long, help: "Trust unknown host keys without asking. Never affects mismatches.")
    var acceptNew = false

    @Option(name: .long, help: "Command whose stdout is the secret. Wins over all other sources.")
    var passwordCommand: String?

    var hostKeyPolicy: HostKeyPolicy {
        if acceptNew { return .acceptNew }
        return nonInteractive ? .reject : .ask
    }

    init() {}
}

/// Resolves a reference to a stored session, gathers its secret and
/// connects. The CLI does none of the deciding itself — it hands the pieces
/// to Core.
func connect(
    to reference: SessionReference,
    options: GlobalOptions
) async throws -> any RemoteFileSystem {
    let store = SessionStore(directory: SessionStore.defaultDirectory)
    let session = try reference.resolve(in: try store.all())
    // `secretSources(for:passwordCommand:)` (Core) already encodes the
    // agent-auth guard: an agent-auth SSH session yields an empty chain, and
    // `SecretResolver` walking an empty chain harmlessly resolves to `nil` —
    // so this call site is pure argument plumbing, no branching of its own.
    let sources = secretSources(for: session, passwordCommand: options.passwordCommand)
    let secret = try SecretResolver(sources: sources).resolve(for: session.id)
    if options.verbose, let secret {
        OutputFormatter.note("secret source: \(secret.sourceLabel)")
    }
    let config = try StoredSessionConnectionConfig.build(for: session, secret: secret?.value)
    return try await BackendConnector.connect(
        config, decider: makeDecider(policy: options.hostKeyPolicy))
}

/// Builds the decider for UNKNOWN host keys. A mismatch never reaches this:
/// `HostKeyValidation` stops it first, and this function has no branch that
/// could accept one. Moved here, unchanged, from the M1 driver being
/// replaced in this task.
func makeDecider(policy: HostKeyPolicy) -> HostKeyDecider {
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
