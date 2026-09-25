import Foundation
import Testing
@testable import macSCPCore

@Suite("PasswordCommandSecretSource", .timeLimit(.minutes(1)))
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
        // The whole point: this test must finish quickly, not after 30s — but
        // "quickly" is an upper bound on the RUNNER, not on `secret(for:)`
        // (CLAUDE.md, "A wall-clock ceiling in a test measures the runner"):
        // a starved machine can make the escalation itself (`terminate`,
        // `SIGKILL`, `waitUntilExit`) take longer than any fixed ceiling
        // here would allow, without the production timeout having been
        // ignored. What ends this test when it is not honoured is the
        // suite's own `.timeLimit`. The floor stays: it proves the call did
        // not return instantly, i.e. that the injected `timeout` was
        // actually read rather than skipped.
        #expect(Date().timeIntervalSince(started) >= 0.05)
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
/// (`--password-command` → environment variable → Keychain, and for a
/// private-key session the managed key's slot after that —
/// `SecretSourcesManagedKeyTests` below) and the
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
            name: "test", kind: kind,
            // SSH's fields only for an SSH session (M23/T8) — `authKind` is
            // what the agent guard reads.
            ssh: kind == .ssh
                ? StoredSSHConfig(
                    host: "example.test", username: "user", authKind: authKind)
                : nil,
            s3: kind == .s3
                ? StoredS3Config(
                    accessKeyID: "id", region: "r", endpoint: "https://example.test",
                    bucket: "b", usePathStyle: true)
                : nil)
    }

    @Test func sshOrderIsPasswordCommandThenEnvironmentThenKeychain() {
        let session = makeSession(kind: .ssh)
        let chain = secretSources(
            for: session, passwordCommand: "echo x", keychainStore: InMemorySecretStore())
        #expect(chain.sources.map(\.label) == [
            "--password-command", "environment variable MACSCP_PASSWORD", "keychain",
        ])
        // `.kinds` alongside `.sources` — the two are built in lockstep
        // (`SecretChain`, fix round 2), so this is what a `.secretRequired`
        // refusal for this exact chain would name as "checked".
        #expect(chain.kinds == [.passwordCommand, .environment, .keychain])
    }

    @Test func sshWithoutPasswordCommandSkipsStraightToEnvironmentThenKeychain() {
        let session = makeSession(kind: .ssh)
        let chain = secretSources(
            for: session, passwordCommand: nil, keychainStore: InMemorySecretStore())
        #expect(chain.sources.map(\.label) == [
            "environment variable MACSCP_PASSWORD", "keychain",
        ])
        #expect(chain.kinds == [.environment, .keychain])
    }

    @Test func s3OrderUsesTheAWSConventionalVariableName() {
        let session = makeSession(kind: .s3)
        let chain = secretSources(
            for: session, passwordCommand: "echo x", keychainStore: InMemorySecretStore())
        #expect(chain.sources.map(\.label) == [
            "--password-command", "environment variable AWS_SECRET_ACCESS_KEY", "keychain",
        ])
        #expect(chain.kinds == [.passwordCommand, .environment, .keychain])
    }

    /// The agent is an authentication METHOD, not a secret source (M20
    /// design): an agent-auth session needs nothing resolved, so an
    /// unrelated broken `--password-command` must never be consulted for
    /// it, let alone fail the connect.
    @Test func agentAuthSSHSessionYieldsAnEmptyChainEvenWithPasswordCommandSet() {
        let session = makeSession(kind: .ssh, authKind: .agent)
        let chain = secretSources(
            for: session, passwordCommand: "echo x", keychainStore: InMemorySecretStore())
        // Asserted on `label`, never on the sources themselves: a failing
        // `#expect` renders the whole expression into the message, and an
        // `EnvironmentSecretSource` carries `ProcessInfo.processInfo.environment`
        // by default -- so `#expect(sources.isEmpty)` would print the machine's
        // AWS_SECRET_ACCESS_KEY into an archived public CI log the one time it
        // ever goes red. `label` is structurally incapable of carrying a value.
        #expect(chain.sources.map(\.label).isEmpty)
        #expect(chain.kinds.isEmpty)
    }

    /// The guard is keyed on `kind`/`authKind`, not merely "is agent set
    /// somewhere": an S3 session always needs its secret access key,
    /// regardless of what `authKind` happens to hold (S3 sessions don't use
    /// it, but the guard must not accidentally key off a field that isn't
    /// meaningful for this kind).
    @Test func s3SessionAlwaysNeedsASecretRegardlessOfAuthKind() {
        let session = makeSession(kind: .s3, authKind: .agent)
        let chain = secretSources(
            for: session, passwordCommand: nil, keychainStore: InMemorySecretStore())
        // Same reason as above: `label`, never the sources themselves.
        #expect(!chain.sources.map(\.label).isEmpty)
        #expect(!chain.kinds.isEmpty)
    }
}

/// `ChainedSecretSource` re-applies `SecretResolver`'s "first non-empty
/// wins" rule as a `SecretSource` of its own, for `ConnectionDiagnostics` to
/// hold as a single reusable source.
@Suite("ChainedSecretSource")
struct ChainedSecretSourceTests {
    /// Counts its own invocations — the fake that lets a case assert on how
    /// many times the underlying source was actually asked, rather than only
    /// on what it answered. `@unchecked Sendable` with an `NSLock`, the same
    /// shape `CLISecretSources.swift`'s own `AnsweredLabel` and
    /// `CollectedOutput` use, since `SecretSource` requires `Sendable` and
    /// `secret(for:)` is non-mutating.
    private final class CountingSecretSource: SecretSource, @unchecked Sendable {
        let label = "counting"
        private let lock = NSLock()
        private let value: String?
        private var invocations = 0

        init(value: String?) { self.value = value }

        var callCount: Int { lock.withLock { invocations } }

        func secret(for sessionID: UUID) throws -> String? {
            lock.withLock { invocations += 1 }
            return value
        }
    }

    private struct StubSecretSource: SecretSource {
        let label: String
        let value: String?
        func secret(for sessionID: UUID) throws -> String? { value }
    }

    /// The value under test never reaches the expectation's own source text
    /// (CLAUDE.md, "a test that holds a value it must not leak computes its
    /// Bools before the expectation") — `theSecret` is compared to the
    /// result off to the side, and only the resulting `Bool`s are handed to
    /// `#expect`.
    @Test func theChainAnswersTheFirstNonEmptySourceAndSkipsAnEmptyOne() throws {
        let theSecret = "hunter2"
        let chain = ChainedSecretSource([
            StubSecretSource(label: "empty", value: ""),
            StubSecretSource(label: "winner", value: theSecret),
            StubSecretSource(label: "unreached", value: "should-not-be-read"),
        ])
        let resolved = try chain.secret(for: UUID())
        let resolvedTheSecret = resolved == theSecret
        let labelIsTheWinningSource = chain.label == "winner"
        #expect(resolvedTheSecret)
        #expect(labelIsTheWinningSource)
    }

    @Test func aNilAnsweringSourceIsSkippedLikeAnEmptyOne() throws {
        let theSecret = "s3cr3t"
        let chain = ChainedSecretSource([
            StubSecretSource(label: "nothing-here", value: nil),
            StubSecretSource(label: "winner", value: theSecret),
        ])
        let resolved = try chain.secret(for: UUID())
        // Same rule as the sibling above, and it was missed here: `#expect`
        // reports the SOURCE TEXT of what it checks alongside the values, so
        // `resolved == theSecret` puts the fixture secret in a failure
        // message (CLAUDE.md, "A value a test must not leak has two exits,
        // not one"). The Bools are computed first; neither the value nor its
        // spelling reaches the output.
        let resolvedTheSecret = resolved == theSecret
        let labelIsTheWinningSource = chain.label == "winner"
        #expect(resolvedTheSecret)
        #expect(labelIsTheWinningSource)
    }

    @Test func labelIsNoneBeforeAnySourceHasAnswered() {
        #expect(ChainedSecretSource([]).label == "none")
    }

    @Test func anEmptyChainResolvesToNil() throws {
        #expect(try ChainedSecretSource([]).secret(for: UUID()) == nil)
    }

    /// `ConnectionDiagnostics` calls `secret(for:)` once per authenticating
    /// step against the SAME session id — the dial, then S3/WebDAV's own
    /// contribution probe on `--scope complete` — and without memoizing,
    /// re-walking the chain on the second call means a `--password-command`
    /// helper is spawned twice for one diagnosis. Counted on the fake
    /// itself, and the secret named once as a constant with the Bools
    /// computed before the expectations (CLAUDE.md, "A value a test must
    /// not leak has two exits, not one").
    @Test func aSecondCallForTheSameSessionDoesNotAskTheSourceAgain() throws {
        let theSecret = "hunter2"
        let source = CountingSecretSource(value: theSecret)
        let chain = ChainedSecretSource([source])
        let sessionID = UUID()

        let first = try chain.secret(for: sessionID)
        let second = try chain.secret(for: sessionID)

        let firstIsTheSecret = first == theSecret
        let secondIsTheSecret = second == theSecret
        #expect(firstIsTheSecret)
        #expect(secondIsTheSecret)
        #expect(source.callCount == 1, "the source was asked \(source.callCount) time(s), not once")
    }

    /// A different session id is a different question, and gets its own
    /// answer: the memo is keyed by session id, so the SAME chain instance
    /// asked about a second id must not be served the first id's cached
    /// answer, or skip asking its source at all.
    @Test func aDifferentSessionIDOnTheSameChainIsNotServedFromTheOtherOnesMemo() throws {
        let theSecret = "hunter2"
        let source = CountingSecretSource(value: theSecret)
        let chain = ChainedSecretSource([source])

        let first = try chain.secret(for: UUID())
        let second = try chain.secret(for: UUID())

        let firstIsTheSecret = first == theSecret
        let secondIsTheSecret = second == theSecret
        #expect(firstIsTheSecret)
        #expect(secondIsTheSecret)
        #expect(source.callCount == 2, "a second session id was answered from the wrong memo")
    }
}

/// The CLI chain's last link for a key the app manages (Task 2 fix round 2):
/// a manual private-key session whose own slot was dropped, because the
/// managed key's slot holds the passphrase, must still resolve on the
/// command line — the App's form and the forwarding chain already read that
/// slot.
///
/// The values are resolved with the ENVIRONMENT source filtered out by its
/// label: `secretSources` builds it over the real process environment, and a
/// `MACSCP_PASSWORD` set on the machine running the suite would otherwise
/// answer first. The order itself is pinned on labels, environment included.
///
/// No secret value is written into an expectation (CLAUDE.md, "A value a
/// test must not leak has two exits"): named constants, `Bool`s computed first.
@Suite("secretSources — a managed key's own passphrase")
struct SecretSourcesManagedKeyTests {
    private static let keyPassphrase = "fixture-key-passphrase-not-a-real-secret"
    private static let sessionSecret = "fixture-session-secret-not-a-real-secret"
    private static let managedLabel = "managed key passphrase"

    /// Records every slot id it is asked for, so a case can show a slot was
    /// never read.
    private final class RecordingSecretStore: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [UUID: String] = [:]
        private var reads: [UUID] = []
        private var failing: Set<UUID> = []

        var readIDs: [UUID] { lock.withLock { reads } }

        /// Makes every read of `id` throw a `KeychainError` — what a denied
        /// or locked Keychain item answers.
        func failReads(of id: UUID) { lock.withLock { _ = failing.insert(id) } }

        func savePassword(_ password: String, for sessionID: UUID) throws {
            lock.withLock { storage[sessionID] = password }
        }

        func password(for sessionID: UUID) throws -> String? {
            try lock.withLock {
                reads.append(sessionID)
                if failing.contains(sessionID) { throw KeychainError(status: errSecAuthFailed) }
                return storage[sessionID]
            }
        }

        func deletePassword(for sessionID: UUID) throws {
            lock.withLock { storage[sessionID] = nil }
        }
    }

    private struct Rig {
        let directory: URL
        let keys: ManagedKeyStore
        let secrets = RecordingSecretStore()
        let keyID: UUID
        let managedPath: String

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cli-managed-key-\(UUID().uuidString)")
            keys = ManagedKeyStore(directory: directory)
            let key = ManagedKey(
                name: "cli key", comment: "", type: .ed25519, fingerprint: "SHA256:cli-test",
                publicKeyOpenSSH: "ssh-ed25519 AAAAclitest", createdAt: Date(),
                hasPassphrase: true, fileName: "cli-test-key")
            try keys.add(key)
            keyID = key.id
            managedPath = keys.keyDirectory.appendingPathComponent("cli-test-key")
                .path(percentEncoded: false)
        }

        func tearDown() { try? FileManager.default.removeItem(at: directory) }

        func session(authKind: StoredSession.AuthKind, keyPath: String?) -> StoredSession {
            StoredSession(
                name: "web", kind: .ssh,
                ssh: StoredSSHConfig(
                    host: "example.invalid", username: "tester", authKind: authKind,
                    keyPath: keyPath))
        }

        func resolve(_ session: StoredSession) throws -> ResolvedSecret? {
            let sources = secretSources(
                for: session, passwordCommand: nil, keychainStore: secrets, keyStore: keys)
                .sources
                .filter { !$0.label.hasPrefix("environment variable") }
            return try SecretResolver(sources: sources).resolve(for: session.id)
        }
    }

    /// The chain's FOUR-link shape — `--password-command` given, a
    /// private-key session with a managed key path — asserted end to end:
    /// the real `secretSources(...)` builder's `.kinds`, and the sentence
    /// `CLIErrorMapping` renders from them. This is the coverage fix round 2
    /// asked for: every other place that pins the rendered sentence
    /// (`CLIErrorMappingTests`) hand-builds its `[SecretSourceKind]`
    /// literal, so none of them would have caught a builder that appended
    /// the wrong kind for a link, or the reviewer's own planted violation
    /// (`EnvironmentSecretSource -> .managedKeyPassphrase`) — this test
    /// walks the actual builder instead.
    ///
    /// Red first, recorded: temporarily changed this file's
    /// `secretSources(...)`, in `CLISecretSources.swift`, so the
    /// environment link's `kinds.append(.environment)` read
    /// `kinds.append(.managedKeyPassphrase)` instead (the direct equivalent
    /// of the reviewer's planted mismatch, applied where kinds are now
    /// actually tagged). Reran this test: failed —
    /// `chain.kinds == [.passwordCommand, .managedKeyPassphrase, .keychain,
    /// .managedKeyPassphrase]` against the expected four DISTINCT kinds, and
    /// the message assertion failed too (`"the managed key's passphrase"`
    /// appearing twice, `"the environment"` not at all). Reverted; reran
    /// green.
    @Test func aPrivateKeySessionsChainEndsWithTheManagedKeysSlot() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let chain = secretSources(
            for: rig.session(authKind: .privateKey, keyPath: rig.managedPath),
            passwordCommand: "echo x", keychainStore: rig.secrets, keyStore: rig.keys)
        #expect(chain.sources.map(\.label) == [
            "--password-command", "environment variable MACSCP_PASSWORD", "keychain", Self.managedLabel,
        ])
        #expect(chain.kinds == [.passwordCommand, .environment, .keychain, .managedKeyPassphrase])

        let message = CLIErrorMapping.message(
            for: StoredSessionConnectionError.secretRequired(checked: chain.kinds))
        #expect(message == "Error: no secret available (checked --password-command, "
            + "the environment, the keychain, and the managed key's passphrase)")
    }

    @Test func theSessionsOwnSlotAnswersFirst() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let session = rig.session(authKind: .privateKey, keyPath: rig.managedPath)
        try rig.secrets.savePassword(Self.sessionSecret, for: session.id)
        try rig.secrets.savePassword(Self.keyPassphrase, for: rig.keyID)
        let resolved = try rig.resolve(session)
        let isTheSessionSecret = resolved?.value == Self.sessionSecret
        #expect(isTheSessionSecret, "the session's own slot did not win")
        #expect(resolved?.sourceLabel == "keychain")
    }

    @Test func aDroppedSessionSlotFallsBackToTheManagedKeysSlot() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let session = rig.session(authKind: .privateKey, keyPath: rig.managedPath)
        try rig.secrets.savePassword(Self.keyPassphrase, for: rig.keyID)
        let resolved = try rig.resolve(session)
        let isTheKeyPassphrase = resolved?.value == Self.keyPassphrase
        #expect(isTheKeyPassphrase, "the managed key's stored passphrase did not reach the CLI dial")
        #expect(resolved?.sourceLabel == Self.managedLabel)
    }

    @Test func aKeyTheAppDoesNotManageResolvesNothing() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try rig.secrets.savePassword(Self.keyPassphrase, for: rig.keyID)
        let session = rig.session(authKind: .privateKey, keyPath: "/tmp/not-a-managed-key")
        let resolvedNothing = try rig.resolve(session) == nil
        #expect(resolvedNothing, "an unmanaged key path resolved a secret")
    }

    /// Task 2 fix round 3: a Keychain error on the KEY's slot propagates, the
    /// way `KeychainSecretSource` lets one on the session's slot propagate.
    /// Swallowed, a denied item read as "no secret" and the dial failed later
    /// at authentication with nothing pointing at the Keychain.
    @Test func aKeychainErrorOnTheKeysSlotIsThrownNotSwallowed() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.secrets.failReads(of: rig.keyID)
        let source = ManagedKeyPassphraseSecretSource(
            keyPath: rig.managedPath, keys: rig.keys, secrets: rig.secrets)
        let session = rig.session(authKind: .privateKey, keyPath: rig.managedPath)
        #expect(throws: KeychainError.self) { try source.secret(for: session.id) }
        // And through the chain: the resolver stops at it instead of
        // answering nil.
        #expect(throws: KeychainError.self) { try rig.resolve(session) }
    }

    /// Task 2 fix round 4: an unreadable `managed_keys.json` answers "no
    /// managed key is known" instead of throwing. The store is decoded whole
    /// before the path can be matched, so a throw here stopped every
    /// private-key session, including those whose key the store does not
    /// manage. No Keychain slot is read for any id.
    @Test func anUnreadableKeyStoreAnswersNotManaged() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try Data("not json".utf8).write(to: rig.directory.appendingPathComponent("managed_keys.json"))
        let source = ManagedKeyPassphraseSecretSource(
            keyPath: rig.managedPath, keys: rig.keys, secrets: rig.secrets)
        let answeredNothing = try source.secret(for: UUID()) == nil
        #expect(answeredNothing, "an unreadable key store did not answer nil")
        #expect(rig.secrets.readIDs.isEmpty, "a Keychain slot was read behind an unreadable key store")
    }

    /// The defect round 4 fixes, through the whole CLI chain: a private-key
    /// session with an unmanaged key and an empty own slot resolves nil over
    /// a corrupt key store, and so continues, instead of stopping the resolver.
    @Test func aCorruptKeyStoreDoesNotStopAnUnmanagedKeysChain() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try Data("not json".utf8).write(to: rig.directory.appendingPathComponent("managed_keys.json"))
        let session = rig.session(authKind: .privateKey, keyPath: "/tmp/not-a-managed-key")
        let resolvedNothing = try rig.resolve(session) == nil
        #expect(resolvedNothing, "a corrupt key store resolved a secret")
        #expect(rig.secrets.readIDs == [session.id], "only the session's own slot should be read")
    }

    /// An unencrypted managed key has nothing to ask the Keychain for, so its
    /// slot is never read — no consent prompt for a passphrase that does not
    /// exist.
    @Test func anUnencryptedManagedKeyReadsNoSlot() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let plain = ManagedKey(
            name: "plain", comment: "", type: .ed25519, fingerprint: "SHA256:plain",
            publicKeyOpenSSH: "ssh-ed25519 AAAAplain", createdAt: Date(),
            hasPassphrase: false, fileName: "plain-key")
        try rig.keys.add(plain)
        let path = rig.keys.keyDirectory.appendingPathComponent("plain-key").path(percentEncoded: false)
        rig.secrets.failReads(of: plain.id)
        let source = ManagedKeyPassphraseSecretSource(keyPath: path, keys: rig.keys, secrets: rig.secrets)
        let answeredNothing = try source.secret(for: UUID()) == nil
        #expect(answeredNothing)
        #expect(rig.secrets.readIDs.contains(plain.id) == false)
    }

    @Test func aPasswordSessionNeverConsultsTheManagedKey() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try rig.secrets.savePassword(Self.keyPassphrase, for: rig.keyID)
        // A password session carrying a stale key path must still not reach it.
        let session = rig.session(authKind: .password, keyPath: rig.managedPath)
        let chain = secretSources(
            for: session, passwordCommand: nil, keychainStore: rig.secrets, keyStore: rig.keys)
        #expect(chain.sources.map(\.label).contains(Self.managedLabel) == false)
        #expect(chain.kinds.contains(.managedKeyPassphrase) == false)
        let resolvedNothing = try rig.resolve(session) == nil
        #expect(resolvedNothing, "a password session resolved the managed key's passphrase")
        #expect(rig.secrets.readIDs.contains(rig.keyID) == false, "the managed key's slot was read")
    }

    /// How many DIFFERENT Keychain items one command-line run reads, pinned
    /// as a count of slot ids rather than described in a comment (the
    /// measurement of 2026-09-25, `docs/superpowers/specs/
    /// 2026-09-25-cli-keychain-consent-measurement.md`).
    ///
    /// Each item carries its own ACL, so each is its own consent decision for
    /// a binary that is not on it — two items read means two grants, and
    /// answering for one grants nothing for the other. The property that
    /// keeps the second item out of a run that does not need it is the
    /// resolver's short circuit (`SecretResolver.resolve`, which `continue`s
    /// only past a nil-or-empty source): the managed key's slot is reached
    /// ONLY when the session's own slot produced nothing.
    ///
    /// Whole-array equality, so the check is positive and negative at once
    /// (CLAUDE.md, "Guards that name what they watch"): it names the ids that
    /// MUST be read as well as forbidding any other.
    ///
    /// Sensitivity measured 2026-09-25 by mutation: `SecretResolver.resolve`
    /// was changed to keep walking after its first non-empty answer, holding
    /// that answer in a `var hit` and returning it at the end — so the SAME
    /// secret is resolved from the SAME source, and only the reading stops
    /// being short. That turned the first case red on
    /// `answered.secrets.readIDs == [withOwnSecret.id]` in 3 of 3 filtered
    /// runs; a whole mutated `swift test` — 6513 tests in 557 suites —
    /// recorded that ONE issue and no other. Reverted; green again. The
    /// mutation is the one that matters here: it leaves the resolution
    /// correct (same secret, same source label) and only the READ COUNT
    /// wrong, which is exactly what this case exists to catch and what
    /// nothing else in the tree catches.
    ///
    /// An own slot holding the EMPTY string is a real shape, not a
    /// hypothetical: `SessionListViewModel.upsert` writes
    /// `savePassword(password, for: session.id)` for every session whose
    /// backend `requiresSecret` — true for SSH unless the auth kind is
    /// `.agent` — so a private-key session saved with a blank passphrase
    /// field gets one. Measured against the real Keychain on 2026-09-25
    /// (`MACSCP_KEYCHAIN=1`): such a save creates a full item, which reads
    /// back as the empty string and which `KeychainSecretPresence` reports
    /// as present.
    @Test func theManagedKeysSlotIsReadOnlyWhenTheSessionsOwnSlotAnswersNothing() throws {
        let answered = try Rig()
        defer { answered.tearDown() }
        let withOwnSecret = answered.session(authKind: .privateKey, keyPath: answered.managedPath)
        try answered.secrets.savePassword(Self.sessionSecret, for: withOwnSecret.id)
        try answered.secrets.savePassword(Self.keyPassphrase, for: answered.keyID)
        _ = try answered.resolve(withOwnSecret)
        #expect(
            answered.secrets.readIDs == [withOwnSecret.id],
            "an answering own slot did not stop the walk before the managed key's slot")

        let empty = try Rig()
        defer { empty.tearDown() }
        let withEmptyOwnSlot = empty.session(authKind: .privateKey, keyPath: empty.managedPath)
        try empty.secrets.savePassword("", for: withEmptyOwnSlot.id)
        try empty.secrets.savePassword(Self.keyPassphrase, for: empty.keyID)
        _ = try empty.resolve(withEmptyOwnSlot)
        #expect(
            empty.secrets.readIDs == [withEmptyOwnSlot.id, empty.keyID],
            "an own slot holding nothing did not fall through to the managed key's slot")

        let absent = try Rig()
        defer { absent.tearDown() }
        let withoutOwnSlot = absent.session(authKind: .privateKey, keyPath: absent.managedPath)
        try absent.secrets.savePassword(Self.keyPassphrase, for: absent.keyID)
        _ = try absent.resolve(withoutOwnSlot)
        #expect(
            absent.secrets.readIDs == [withoutOwnSlot.id, absent.keyID],
            "a session with no own slot did not fall through to the managed key's slot")
    }
}
