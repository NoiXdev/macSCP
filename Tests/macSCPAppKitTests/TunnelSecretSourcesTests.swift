import Foundation
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// What a forwarding's dial resolves its secret through (port-forwarding
/// plan, Task 6, fix round 1).
///
/// The chain is the App's, not the command line's, and the two differ in the
/// two ways this suite measures: the environment is never consulted, and a
/// MANAGED private key's passphrase — stored under the KEY's id, not the
/// session's — is reachable. Round 1 used `secretSources(for:passwordCommand:)`
/// and had neither property: a session whose tab connected fine failed
/// authentication as a forwarding, and `MACSCP_PASSWORD` outranked the saved
/// password.
///
/// **No secret value is written into an expectation** (CLAUDE.md, "A value a
/// test must not leak has two exits"): the fixture passphrase lives in a
/// named constant and every check computes its `Bool` first, so neither the
/// value nor its spelling can reach a failure message.
@Suite("Tunnel secret sources")
struct TunnelSecretSourcesTests {

    /// An in-memory `SecretStore`. This target's other fake is `private` to
    /// its own file, so this is a second one rather than a shared one.
    private final class InMemorySecrets: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [UUID: String] = [:]

        func savePassword(_ password: String, for sessionID: UUID) throws {
            lock.lock(); defer { lock.unlock() }
            storage[sessionID] = password
        }

        func password(for sessionID: UUID) throws -> String? {
            lock.lock(); defer { lock.unlock() }
            return storage[sessionID]
        }

        func deletePassword(for sessionID: UUID) throws {
            lock.lock(); defer { lock.unlock() }
            storage[sessionID] = nil
        }
    }

    /// A managed key on disk (its record, not its bytes — nothing here reads
    /// the file) plus the path a session would point at.
    private struct Rig {
        let directory: URL
        let keys: ManagedKeyStore
        let secrets: InMemorySecrets
        let keyID: UUID
        let keyPath: String

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("tunnel-secrets-\(UUID().uuidString)")
            keys = ManagedKeyStore(directory: directory)
            secrets = InMemorySecrets()
            let key = ManagedKey(
                name: "forwarding key", comment: "", type: .ed25519,
                fingerprint: "SHA256:tunnel-secret-test",
                publicKeyOpenSSH: "ssh-ed25519 AAAAtunnelsecrettest", createdAt: Date(),
                hasPassphrase: true, fileName: "tunnel-secret-test-key")
            try keys.add(key)
            keyID = key.id
            keyPath = keys.keyDirectory.appendingPathComponent("tunnel-secret-test-key")
                .path(percentEncoded: false)
        }

        func tearDown() { try? FileManager.default.removeItem(at: directory) }

        func session(authKind: StoredSession.AuthKind = .privateKey) -> StoredSession {
            StoredSession(
                name: "web", kind: .ssh,
                ssh: StoredSSHConfig(
                    host: "example.invalid", username: "tester", authKind: authKind,
                    keyPath: authKind == .privateKey ? keyPath : nil))
        }
    }

    /// The fixture passphrase, named once. Never written into an
    /// expectation — see this suite's header.
    private static let passphrase = "fixture-passphrase-not-a-real-secret"

    // MARK: - The managed key's own slot

    /// The case round 1 could not reach at all: nothing is in the session's
    /// slot, and the passphrase sits under the key's id.
    @Test func aManagedKeysPassphraseIsResolvedForAPrivateKeySession() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try rig.secrets.savePassword(Self.passphrase, for: rig.keyID)
        let session = rig.session()

        let chain = TunnelSecretSources.chain(
            for: session, keys: rig.keys, secrets: rig.secrets)
        let resolved = try SecretResolver(sources: chain.sources).resolve(for: session.id)

        let isThePassphrase = resolved?.value == Self.passphrase
        #expect(isThePassphrase, "the managed key's stored passphrase did not reach the dial")
        #expect(resolved?.sourceLabel == "managed key passphrase")
        #expect(chain.kinds == [.keychain, .managedKeyPassphrase])
    }

    /// The session's own slot comes first — the same precedence
    /// `ContentView.fillForm(_:from:)` applies, where a resolved session
    /// secret is passed to `ManagedKeyPassphrase.resolve` as `typed` and
    /// therefore wins.
    @Test func theSessionsOwnSlotOutranksTheKeys() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let session = rig.session()
        try rig.secrets.savePassword(Self.passphrase, for: rig.keyID)
        let sessionSecret = "fixture-session-secret-not-a-real-secret"
        try rig.secrets.savePassword(sessionSecret, for: session.id)

        let chain = TunnelSecretSources.chain(
            for: session, keys: rig.keys, secrets: rig.secrets)
        let resolved = try SecretResolver(sources: chain.sources).resolve(for: session.id)

        let isTheSessionSecret = resolved?.value == sessionSecret
        #expect(isTheSessionSecret)
        #expect(resolved?.sourceLabel == "keychain")
    }

    // MARK: - What is NOT in the chain

    /// The negative, with its positive beside it: the chain a GUI dial walks
    /// contains the Keychain and never the environment. `MACSCP_PASSWORD` is
    /// the command line's answer to "unattended, no keychain consent"; in
    /// the app it would silently outrank the password the user saved.
    @Test func theEnvironmentIsNeverConsulted() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let session = rig.session()
        let labels = TunnelSecretSources.chain(
            for: session, keys: rig.keys, secrets: rig.secrets
        ).sources.map(\.label)

        // The two forbidden labels are DERIVED from the source types
        // themselves, not spelled here (fix round 2): a renamed label would
        // otherwise leave this negative matching nothing while reading
        // exactly like a check that is satisfied. Both constructions are
        // inert — the environment source takes its environment injected, and
        // the password-command source runs nothing until `secret(for:)` is
        // called, which nothing here does. The variable name comes from the
        // backend descriptor, which is where the CLI chain gets it too.
        let descriptor = BackendDescriptor.descriptor(for: session.kind)
        let environmentLabel = EnvironmentSecretSource(
            variableName: descriptor.secretEnvironmentVariable ?? "MACSCP_PASSWORD",
            environment: [:]
        ).label
        let passwordCommandLabel = PasswordCommandSecretSource(command: "true").label
        let keychainLabel = KeychainSecretSource(store: rig.secrets).label

        #expect(labels.contains(keychainLabel), "the chain no longer reads the keychain at all")
        #expect(
            !labels.contains(environmentLabel),
            "a forwarding's dial consults the environment: \(labels)")
        #expect(
            !labels.contains(passwordCommandLabel),
            "a forwarding's dial runs a password command: \(labels)")
    }

    /// An agent login needs no secret, so nothing is asked for one — the
    /// same first question `secretSources(for:passwordCommand:)` asks, kept.
    @Test func anAgentSessionIsAskedForNoSecretAtAll() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let chain = TunnelSecretSources.chain(
            for: rig.session(authKind: .agent), keys: rig.keys, secrets: rig.secrets)
        #expect(chain.sources.isEmpty)
        // The positive beside the negative: `.kinds` is empty for the SAME
        // reason `.sources` is, not by coincidence — the two are built in
        // lockstep (`SecretChain`, `CLISecretSources.swift`).
        #expect(chain.kinds.isEmpty)
    }

    /// A password session has no key path, so no key source is built — the
    /// chain is the session's slot alone.
    @Test func aPasswordSessionReadsOnlyItsOwnSlot() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let chain = TunnelSecretSources.chain(
            for: rig.session(authKind: .password), keys: rig.keys, secrets: rig.secrets)
        #expect(chain.sources.map(\.label) == [KeychainSecretSource(store: rig.secrets).label])
        #expect(chain.kinds == [.keychain])
    }
}
