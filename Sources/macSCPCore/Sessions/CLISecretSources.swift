import Foundation

/// Reads a secret from the stdout of an external command (`--password-command`,
/// M20). Runs through `/bin/sh -c` so the caller can use the same quoting,
/// pipes, and substitutions they would at a shell prompt (e.g. a password
/// manager's CLI). Always ordered FIRST in the CLI's chain — explicit beats
/// implicit.
public struct PasswordCommandSecretSource: SecretSource {
    public let label = "--password-command"
    private let command: String

    public init(command: String) {
        self.command = command
    }

    /// A failure here names the COMMAND's failure only: an exit code, or
    /// "output unreadable" — never a byte of what the command printed or was
    /// given. That is a hard requirement (M20 design): a leaked error message
    /// must never be the way a secret gets disclosed. `sessionID` is unused —
    /// the command has no notion of which session it is being asked for; the
    /// CLI runs one resolve per connect and expects the command to print the
    /// one secret that connect needs.
    public func secret(for sessionID: UUID) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        do {
            try process.run()
        } catch {
            throw PasswordCommandError.launchFailed
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PasswordCommandError.commandFailed(status: process.terminationStatus)
        }
        guard let output = String(data: data, encoding: .utf8) else {
            throw PasswordCommandError.unreadableOutput
        }
        // Trailing newline stripped the same way shell command substitution
        // does — most password helpers (`pass`, `op read`, …) end their
        // output with one.
        return output.trimmingCharacters(in: .newlines)
    }
}

/// Thrown by `PasswordCommandSecretSource`. Deliberately carries no trace of
/// the command's input or output — only what kind of failure happened — so a
/// logged or printed error can never disclose a secret typed into, or printed
/// by, the helper command.
public enum PasswordCommandError: Error, Equatable, Sendable {
    case launchFailed
    case commandFailed(status: Int32)
    case unreadableOutput
}

/// Reads a secret from a named environment variable — the CI path (M20).
/// Returns `nil` (never throws) when the variable is unset or empty;
/// `SecretResolver` already treats an empty value as "this source did not
/// deliver" and moves on to the next one.
public struct EnvironmentSecretSource: SecretSource {
    public let label: String
    private let variableName: String
    private let environment: [String: String]

    /// `environment` is injectable so tests never have to mutate the real
    /// process environment to exercise this.
    public init(
        variableName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.variableName = variableName
        self.environment = environment
        self.label = "environment variable \(variableName)"
    }

    public func secret(for sessionID: UUID) throws -> String? {
        environment[variableName]
    }
}

/// Adapts a `SecretStore` (the Keychain in production) to `SecretSource`, so
/// the CLI's staged chain can fall through to it exactly like the App does —
/// the workstation default, last in line (M20).
public struct KeychainSecretSource: SecretSource {
    public let label = "keychain"
    private let store: any SecretStore

    public init(store: any SecretStore) {
        self.store = store
    }

    public func secret(for sessionID: UUID) throws -> String? {
        try store.password(for: sessionID)
    }
}

/// Builds the staged secret sources for a stored session, in the ORDER the
/// M20 design fixes as a security decision: an explicit `--password-command`
/// wins over everything; the environment variable is the CI path (the
/// S3-conventional `AWS_SECRET_ACCESS_KEY` for an S3 session, so existing
/// pipelines don't have to relearn a name; `MACSCP_PASSWORD` for SSH, the
/// name the M1 driver already used); the Keychain is the workstation
/// default, last in line. `SecretResolver` is what actually enforces "empty
/// means did not deliver" and "a throwing source aborts the whole attempt"
/// — this function only has to get the order, the variable names, and the
/// agent-auth guard right.
///
/// This used to live in the CLI target as `secretSources(options:kind:)`
/// (`Sources/MacSCPCLI/SessionConnecting.swift`) — a target with NO test
/// target. A future edit swapping two appends, or dropping the agent-auth
/// guard below, would have compiled and passed the entire suite without
/// this file's tests noticing. Moved here, alongside the source types, so
/// the order and the guard are both pinned.
///
/// An SSH agent-auth session needs no secret at all (M20 design): the agent
/// is an authentication METHOD, not a secret source. Consulting
/// `--password-command`/the environment/Keychain anyway would mean an
/// unrelated broken credential helper could fail an agent-auth connect that
/// never needed a secret in the first place — so this returns an EMPTY
/// chain for that case. `SecretResolver` walking an empty chain harmlessly
/// resolves to `nil`, so callers don't need a separate "does this session
/// need a secret" branch of their own.
public func secretSources(
    for session: StoredSession,
    passwordCommand: String?,
    keychainStore: any SecretStore = KeychainSecretStore()
) -> [any SecretSource] {
    let needsSecret = session.kind == .s3
        || (session.kind == .ssh && session.authKind != .agent)
    guard needsSecret else { return [] }

    var sources: [any SecretSource] = []
    if let command = passwordCommand {
        sources.append(PasswordCommandSecretSource(command: command))
    }
    switch session.kind {
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
    sources.append(KeychainSecretSource(store: keychainStore))
    return sources
}
