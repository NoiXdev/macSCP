import Foundation
import Testing
@testable import macSCPCore

@Suite("PasswordCommandSecretSource")
struct PasswordCommandSecretSourceTests {
    @Test func returnsTheCommandsOutputWithTrailingNewlineStripped() throws {
        let source = PasswordCommandSecretSource(command: "echo hunter2")
        #expect(try source.secret(for: UUID()) == "hunter2")
    }

    @Test func labelNamesTheSourceForVerboseDiagnostics() {
        #expect(PasswordCommandSecretSource(command: "echo x").label == "--password-command")
    }

    /// A non-zero exit aborts with a typed error carrying only the exit
    /// code — never the command's stdout, even when that stdout looks like
    /// it could be (or contain) a secret.
    @Test func aNonZeroExitThrowsWithoutCarryingTheOutput() {
        let source = PasswordCommandSecretSource(command: "echo hunter2; exit 1")
        #expect(throws: PasswordCommandError.commandFailed(status: 1)) {
            try source.secret(for: UUID())
        }
    }

    /// The error type itself is structurally incapable of carrying the
    /// command's output or input — this pins that invariant so a future
    /// edit can't quietly add an associated value that leaks it.
    @Test func theFailureCasesCarryNoStringPayload() {
        let cases: [PasswordCommandError] = [
            .launchFailed, .commandFailed(status: 1), .unreadableOutput, .timedOut(after: 0.05),
        ]
        for failure in cases {
            let description = String(describing: failure)
            #expect(!description.contains("hunter2"))
        }
    }

    @Test func unreadableOutputThrows() {
        // A byte sequence that is not valid UTF-8.
        let source = PasswordCommandSecretSource(command: "printf '\\xff\\xfe'")
        #expect(throws: PasswordCommandError.unreadableOutput) {
            try source.secret(for: UUID())
        }
    }

    @Test func emptyOutputIsReturnedAsEmptyNotThrown() throws {
        // "did not deliver" is `SecretResolver`'s job to interpret (an empty
        // value counts as no value) — this source just reports what the
        // command actually printed.
        let source = PasswordCommandSecretSource(command: "true")
        #expect(try source.secret(for: UUID()) == "")
    }

    /// A helper that stalls forever (a broken script, a hung network call,
    /// an unanswered prompt with nowhere to answer since stdin is the null
    /// device) must not hang the CLI forever — it must be bounded and
    /// throw. `timeout` is injected as a tiny value so this test itself
    /// finishes quickly rather than waiting out a real-world duration.
    @Test func aCommandThatOutlivesTheTimeoutThrowsInsteadOfHangingForever() throws {
        let source = PasswordCommandSecretSource(command: "sleep 30", timeout: 0.05)
        let started = Date()
        #expect(throws: PasswordCommandError.timedOut(after: 0.05)) {
            try source.secret(for: UUID())
        }
        // The whole point: this test must finish quickly, not after 30s.
        #expect(Date().timeIntervalSince(started) < 5)
    }

    /// The timed-out child must actually be gone, not left running in the
    /// background consuming resources or holding a lock the next invocation
    /// might need. Proven by having the command report its own PID before
    /// stalling, then checking that PID is no longer alive afterward.
    @Test func aTimedOutCommandsChildProcessDoesNotSurvive() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-timeout-test-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let source = PasswordCommandSecretSource(
            command: "echo $$ > \(pidFile.path); sleep 30", timeout: 0.05)
        #expect(throws: PasswordCommandError.timedOut(after: 0.05)) {
            try source.secret(for: UUID())
        }
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(pid_t(pidText))
        // Signal 0 sends nothing but checks liveness; ESRCH (-1) means gone.
        #expect(kill(pid, 0) == -1)
    }
}

@Suite("EnvironmentSecretSource")
struct EnvironmentSecretSourceTests {
    @Test func returnsTheVariablesValueWhenSet() throws {
        let source = EnvironmentSecretSource(
            variableName: "MACSCP_PASSWORD", environment: ["MACSCP_PASSWORD": "s3cr3t"])
        #expect(try source.secret(for: UUID()) == "s3cr3t")
    }

    @Test func returnsNilWhenUnset() throws {
        let source = EnvironmentSecretSource(variableName: "MACSCP_PASSWORD", environment: [:])
        #expect(try source.secret(for: UUID()) == nil)
    }

    @Test func labelNamesTheVariableForVerboseDiagnostics() {
        let source = EnvironmentSecretSource(variableName: "AWS_SECRET_ACCESS_KEY", environment: [:])
        #expect(source.label.contains("AWS_SECRET_ACCESS_KEY"))
    }
}

@Suite("KeychainSecretSource")
struct KeychainSecretSourceTests {
    @Test func delegatesToTheUnderlyingStore() throws {
        let store = InMemorySecretStore()
        let sessionID = UUID()
        try store.savePassword("from-keychain", for: sessionID)
        let source = KeychainSecretSource(store: store)
        #expect(try source.secret(for: sessionID) == "from-keychain")
    }

    @Test func propagatesAReadFailureInsteadOfSwallowingIt() {
        let source = KeychainSecretSource(store: UnreliableSecretStore(failsReads: true))
        #expect(throws: KeychainError.self) {
            try source.secret(for: UUID())
        }
    }

    @Test func labelIsKeychain() {
        #expect(KeychainSecretSource(store: InMemorySecretStore()).label == "keychain")
    }
}

/// Pins the composition the CLI relies on: the FIXED source order
/// (`--password-command` → environment variable → Keychain) and the
/// agent-auth guard (an SSH session authenticating via the local ssh-agent
/// needs no secret at all, so the chain is empty). This used to live in
/// `Sources/MacSCPCLI/SessionConnecting.swift`, a target with no test
/// target — a swapped append or a dropped guard would have compiled and
/// passed the whole suite. Asserting on `label` sequences, not just count,
/// is what makes a swap fail.
@Suite("secretSources(for:passwordCommand:keychainStore:) composition")
struct SecretSourcesCompositionTests {
    private func makeSession(
        kind: ConnectionKind, authKind: StoredSession.AuthKind = .password
    ) -> StoredSession {
        StoredSession(
            name: "test", host: "example.test", username: "user",
            authKind: authKind, kind: kind,
            s3: kind == .s3
                ? StoredS3Config(
                    accessKeyID: "id", region: "r", endpoint: "https://example.test",
                    bucket: "b", usePathStyle: true)
                : nil)
    }

    @Test func sshOrderIsPasswordCommandThenEnvironmentThenKeychain() {
        let session = makeSession(kind: .ssh)
        let sources = secretSources(
            for: session, passwordCommand: "echo x", keychainStore: InMemorySecretStore())
        #expect(sources.map(\.label) == [
            "--password-command", "environment variable MACSCP_PASSWORD", "keychain",
        ])
    }

    @Test func sshWithoutPasswordCommandSkipsStraightToEnvironmentThenKeychain() {
        let session = makeSession(kind: .ssh)
        let sources = secretSources(
            for: session, passwordCommand: nil, keychainStore: InMemorySecretStore())
        #expect(sources.map(\.label) == [
            "environment variable MACSCP_PASSWORD", "keychain",
        ])
    }

    @Test func s3OrderUsesTheAWSConventionalVariableName() {
        let session = makeSession(kind: .s3)
        let sources = secretSources(
            for: session, passwordCommand: "echo x", keychainStore: InMemorySecretStore())
        #expect(sources.map(\.label) == [
            "--password-command", "environment variable AWS_SECRET_ACCESS_KEY", "keychain",
        ])
    }

    /// The agent is an authentication METHOD, not a secret source (M20
    /// design): an agent-auth session needs nothing resolved, so an
    /// unrelated broken `--password-command` must never be consulted for
    /// it, let alone fail the connect.
    @Test func agentAuthSSHSessionYieldsAnEmptyChainEvenWithPasswordCommandSet() {
        let session = makeSession(kind: .ssh, authKind: .agent)
        let sources = secretSources(
            for: session, passwordCommand: "echo x", keychainStore: InMemorySecretStore())
        #expect(sources.isEmpty)
    }

    /// The guard is keyed on `kind`/`authKind`, not merely "is agent set
    /// somewhere": an S3 session always needs its secret access key,
    /// regardless of what `authKind` happens to hold (S3 sessions don't use
    /// it, but the guard must not accidentally key off a field that isn't
    /// meaningful for this kind).
    @Test func s3SessionAlwaysNeedsASecretRegardlessOfAuthKind() {
        let session = makeSession(kind: .s3, authKind: .agent)
        let sources = secretSources(
            for: session, passwordCommand: nil, keychainStore: InMemorySecretStore())
        #expect(!sources.isEmpty)
    }
}
