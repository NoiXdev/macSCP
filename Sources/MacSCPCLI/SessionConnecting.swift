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
    // Since M22/T10 the backend opens its OWN connection (no central
    // dispatcher): SSH keeps its TOFU host-key decider, and the certificate
    // decider refuses by default — the CLI has no interactive certificate
    // prompt, and an unknown server certificate must never be trusted
    // silently.
    //
    // The CLI reads no user settings at all (no `settings.json` of its
    // own), so it uses the settings default rather than a live,
    // user-configured value.
    return try await BackendDescriptor.openConnection(
        config, hostKey: makeDecider(policy: options.hostKeyPolicy), certificate: .refusing,
        timeoutSeconds: SettingsStore.defaultConnectTimeoutSeconds)
}

/// Connects to `reference`, runs `body`, and awaits `fs.disconnect()` on
/// every exit path — `body` returning normally (including an early `return`
/// inside it), `body` throwing, or the connect itself throwing before
/// `body` ever runs. Every subcommand needs this exact shape (M20 Task 10
/// had three copies by hand; this is the extraction the Task 10 review
/// flagged once a fourth command arrived). NOT a `Task { }` in a `defer`:
/// this process exits right after a subcommand's `run()` returns, and a
/// detached task has no guarantee of completing before that happens.
func withConnection(
    to reference: SessionReference,
    options: GlobalOptions,
    _ body: (any RemoteFileSystem) async throws -> Void
) async throws {
    let fs = try await connect(to: reference, options: options)
    do {
        try await body(fs)
        await fs.disconnect()
    } catch {
        await fs.disconnect()
        throw error
    }
}

/// Builds the decider for UNKNOWN host keys. A mismatch never reaches this:
/// `HostKeyValidation` stops it first, and this function has no branch that
/// could accept one.
///
/// The body below is what `HostKeyDecider.asking` means for a terminal: the
/// policy and `CLIEnvironment.hasTTY` choose between announcing, refusing and
/// actually asking, and the question itself goes to `stderr`. All three stay
/// on this side of the boundary — Core has no terminal to write to and no
/// policy flag to read.
func makeDecider(policy: HostKeyPolicy) -> HostKeyDecider {
    .asking { candidate in
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
