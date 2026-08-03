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

/// Builds the staged secret sources in the ORDER the M20 design fixes as a
/// security decision: an explicit `--password-command` wins over everything;
/// the environment variable is the CI path (the S3-conventional
/// `AWS_SECRET_ACCESS_KEY` for an S3 session, so existing pipelines don't
/// have to relearn a name; `MACSCP_PASSWORD` for SSH, the name the M1 driver
/// already used); the Keychain is the workstation default, last in line.
/// `SecretResolver` is what actually enforces "empty means did not deliver"
/// and "a throwing source aborts the whole attempt" — this function only has
/// to get the order and the variable names right.
func secretSources(options: GlobalOptions, kind: ConnectionKind) -> [any SecretSource] {
    var sources: [any SecretSource] = []
    if let command = options.passwordCommand {
        sources.append(PasswordCommandSecretSource(command: command))
    }
    switch kind {
    case .ssh:
        sources.append(EnvironmentSecretSource(variableName: "MACSCP_PASSWORD"))
    case .s3:
        sources.append(EnvironmentSecretSource(variableName: "AWS_SECRET_ACCESS_KEY"))
    }
    // No access group (M20 Task 7 wired the entitlements/signing but the App
    // itself still constructs `KeychainSecretStore()` with none — see
    // `ContentView`/`ConnectionFormView`/`SSHKeysSheet`); matching that
    // keeps the CLI reading the exact slot the App reads today rather than
    // inventing a group nothing else requests yet.
    sources.append(KeychainSecretSource(store: KeychainSecretStore()))
    return sources
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
    // The SSH agent is an authentication METHOD, not a secret source (M20
    // design): an agent session needs nothing resolved at all, and running
    // `--password-command`/reading the environment for it anyway would mean
    // an unrelated broken credential helper could fail an agent-auth connect
    // that never needed a secret in the first place.
    let needsSecret = session.kind == .s3
        || (session.kind == .ssh && session.authKind != .agent)
    var secret: ResolvedSecret?
    if needsSecret {
        let resolver = SecretResolver(sources: secretSources(options: options, kind: session.kind))
        secret = try resolver.resolve(for: session.id)
    }
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
