import Foundation
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// What a diagnosis resolves its secret through (final review of the
/// 2026-09-16 plan): the session's slot, then — for a private-key connection
/// only — the managed key's.
///
/// **No secret value is written into an expectation** (CLAUDE.md, "A value a
/// test must not leak has two exits"): the fixture values live in named
/// constants and every check computes its `Bool` first.
@Suite("Diagnostics secret sources")
struct DiagnosticsSecretSourcesTests {

    /// An in-memory `SecretStore`, private to this file like the other fakes
    /// in this target.
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

    /// A managed, encrypted key's record in a temporary store, and the path a
    /// session points at.
    private struct Rig {
        let directory: URL
        let keys: ManagedKeyStore
        let secrets: InMemorySecrets
        let keyID: UUID
        let keyPath: String

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("diagnostics-secrets-\(UUID().uuidString)")
            keys = ManagedKeyStore(directory: directory)
            secrets = InMemorySecrets()
            let key = ManagedKey(
                name: "diagnosed key", comment: "", type: .ed25519,
                fingerprint: "SHA256:diagnostics-secret-test",
                publicKeyOpenSSH: "ssh-ed25519 AAAAdiagnosticssecrettest", createdAt: Date(),
                hasPassphrase: true, fileName: "diagnostics-secret-test-key")
            try keys.add(key)
            keyID = key.id
            keyPath = keys.keyDirectory.appendingPathComponent("diagnostics-secret-test-key")
                .path(percentEncoded: false)
        }

        func tearDown() { try? FileManager.default.removeItem(at: directory) }

        /// The field values a diagnosis target carries for a stored session.
        func values(authKind: StoredSession.AuthKind) -> (id: UUID, values: FieldValues) {
            let session = StoredSession(
                name: "diagnosed", kind: .ssh,
                ssh: StoredSSHConfig(
                    host: "example.invalid", username: "tester", authKind: authKind,
                    keyPath: authKind == .privateKey ? keyPath : nil))
            return (session.id, BackendDescriptor.descriptor(for: .ssh).sessionValues(session))
        }
    }

    private static let keyPassphrase = "fixture-key-passphrase-not-a-real-secret"
    private static let sessionSecret = "fixture-session-secret-not-a-real-secret"

    /// The case the review found: the session's slot is empty — dropped
    /// because the managed key's slot holds the passphrase — and the diagnosis
    /// still reaches the passphrase.
    @Test func aDroppedSessionSlotResolvesTheManagedKeysPassphrase() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try rig.secrets.savePassword(Self.keyPassphrase, for: rig.keyID)
        let target = rig.values(authKind: .privateKey)

        let source = DiagnosticsSecretSources.source(
            kind: .ssh, values: target.values, keys: rig.keys, secrets: rig.secrets)
        let resolved = try source.secret(for: target.id)

        let isTheKeyPassphrase = resolved == Self.keyPassphrase
        #expect(isTheKeyPassphrase, "the managed key's stored passphrase did not reach the diagnosis")
    }

    /// The session's own slot comes first, as in every other chain.
    @Test func theSessionsOwnSlotOutranksTheKeys() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try rig.secrets.savePassword(Self.keyPassphrase, for: rig.keyID)
        let target = rig.values(authKind: .privateKey)
        try rig.secrets.savePassword(Self.sessionSecret, for: target.id)

        let source = DiagnosticsSecretSources.source(
            kind: .ssh, values: target.values, keys: rig.keys, secrets: rig.secrets)
        let resolved = try source.secret(for: target.id)

        let isTheSessionSecret = resolved == Self.sessionSecret
        #expect(isTheSessionSecret, "the session's own slot did not win over the managed key's")
    }

    /// A password connection has no key path, so the managed link is absent:
    /// the chain is the session's slot alone, and a key passphrase in the
    /// store is not handed to it.
    @Test func aPasswordSessionReadsOnlyItsOwnSlot() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try rig.secrets.savePassword(Self.keyPassphrase, for: rig.keyID)
        let target = rig.values(authKind: .password)

        let labels = DiagnosticsSecretSources.chain(
            kind: .ssh, values: target.values, keys: rig.keys, secrets: rig.secrets
        ).map(\.label)
        #expect(labels == [KeychainSecretSource(store: rig.secrets).label])

        let resolved = try DiagnosticsSecretSources.source(
            kind: .ssh, values: target.values, keys: rig.keys, secrets: rig.secrets
        ).secret(for: target.id)
        #expect(resolved == nil)
    }

    /// The positive beside the label check above: a private-key connection's
    /// chain carries both links, the managed one last.
    @Test func aPrivateKeySessionsChainEndsInTheManagedKeysSlot() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let target = rig.values(authKind: .privateKey)
        let managedLabel = ManagedKeyPassphraseSecretSource(
            keyPath: rig.keyPath, keys: rig.keys, secrets: rig.secrets
        ).label

        let labels = DiagnosticsSecretSources.chain(
            kind: .ssh, values: target.values, keys: rig.keys, secrets: rig.secrets
        ).map(\.label)
        #expect(labels == [KeychainSecretSource(store: rig.secrets).label, managedLabel])
    }
}
