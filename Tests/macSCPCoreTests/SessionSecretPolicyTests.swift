import Foundation
import Testing
@testable import macSCPCore

@Suite("SessionSecretPolicy")
struct SessionSecretPolicyTests {
    private func emptyStores() throws -> (ManagedKeyStore, InMemorySecretStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ManagedKeyStore(directory: dir), InMemorySecretStore())
    }

    /// Registers a managed key in `keys` and returns its id and the resolved
    /// path `key(forPath:)` will match it against — the shared fixture the
    /// "managed key with/without a slot" tests below build on.
    private func registerManagedKey(
        in keys: ManagedKeyStore, fileName: String = "kf"
    ) throws -> (id: UUID, path: String) {
        let key = ManagedKey(
            name: "k", comment: "", type: .ed25519, fingerprint: "SHA256:x",
            publicKeyOpenSSH: "ssh-ed25519 AAAA", createdAt: Date(),
            hasPassphrase: true, fileName: fileName)
        try keys.add(key)
        return (key.id, keys.keyDirectory.appendingPathComponent(fileName).path)
    }

    /// A password login has no managed key involved at all, so its own
    /// secret is what gets persisted.
    @Test func aPasswordLoginPersistsItsOwnSecret() throws {
        let (keys, secrets) = try emptyStores()

        let value = SessionSecretPolicy.valueToPersist(
            resolvedSecret: "s3cret", kind: .ssh, authChoice: .password,
            keyPath: "", keys: keys, secrets: secrets)

        let matches = value == "s3cret"
        #expect(matches)
    }

    /// An agent login holds no secret at all; nothing is written.
    @Test func anAgentLoginPersistsNothing() throws {
        let (keys, secrets) = try emptyStores()

        let isEmpty = SessionSecretPolicy.valueToPersist(
            resolvedSecret: "", kind: .ssh, authChoice: .agent,
            keyPath: "", keys: keys, secrets: secrets).isEmpty
        #expect(isEmpty)
    }

    /// A private-key login whose key is NOT managed here still persists its
    /// own passphrase — the exemption is only for keys whose passphrase this
    /// app already keeps under the key's own identifier.
    @Test func anUnmanagedKeyPersistsItsOwnPassphrase() throws {
        let (keys, secrets) = try emptyStores()

        let isEmpty = SessionSecretPolicy.valueToPersist(
            resolvedSecret: "passphrase", kind: .ssh, authChoice: .privateKey,
            keyPath: "/nowhere/id_ed25519", keys: keys, secrets: secrets).isEmpty
        #expect(isEmpty == false)
    }

    /// The actual exemption this type exists to grant: a managed key that
    /// ALREADY has a passphrase under its own `key.id` slot must not get a
    /// second copy written into the session's/set's own slot. A policy that
    /// always answered `false` here would still pass every other test in
    /// this file — this is the one that catches it.
    @Test func aManagedKeyWithAStoredPassphraseIsExemptFromPersisting() throws {
        let (keys, secrets) = try emptyStores()
        let (id, path) = try registerManagedKey(in: keys)
        try secrets.savePassword("already-stored", for: id)

        let usesStored = SessionSecretPolicy.usesStoredManagedPassphrase(
            kind: .ssh, authChoice: .privateKey, keyPath: path, keys: keys, secrets: secrets)
        #expect(usesStored)

        let isEmpty = SessionSecretPolicy.valueToPersist(
            resolvedSecret: "typed-again", kind: .ssh, authChoice: .privateKey,
            keyPath: path, keys: keys, secrets: secrets).isEmpty
        #expect(isEmpty)
    }

    /// M19: a Keychain read that fails outright (locked, denied, transient)
    /// is not evidence that no slot exists. The probe
    /// (`ManagedKeyPassphrase.hasStoredPassphrase`) throws, and the `catch`
    /// in `usesStoredManagedPassphrase` answers "treat as already stored" —
    /// so `valueToPersist` still declines to write, rather than duplicating
    /// a passphrase that, for all this call knows, is already sitting under
    /// the key's own slot.
    @Test func anUnreadableKeychainIsTreatedAsAlreadyStored() throws {
        let (keys, _) = try emptyStores()
        let (_, path) = try registerManagedKey(in: keys)
        let unreadable = UnreliableSecretStore(failsReads: true)

        let usesStored = SessionSecretPolicy.usesStoredManagedPassphrase(
            kind: .ssh, authChoice: .privateKey, keyPath: path, keys: keys, secrets: unreadable)
        #expect(usesStored)

        let isEmpty = SessionSecretPolicy.valueToPersist(
            resolvedSecret: "typed", kind: .ssh, authChoice: .privateKey,
            keyPath: path, keys: keys, secrets: unreadable).isEmpty
        #expect(isEmpty)
    }

    /// The whitespace around a pasted path must not decide the answer — a
    /// trailing space would otherwise make a managed key look unmanaged and
    /// duplicate its passphrase into a second keychain slot. The key is
    /// registered at the TRIMMED path on purpose: `key(forPath:)` does no
    /// trimming of its own, so the padded lookup can only succeed if
    /// `usesStoredManagedPassphrase` trims first. Against an empty store
    /// both sides would agree vacuously (both `false`) whether or not
    /// trimming happens — this fixture is what makes the assertion able to
    /// fail.
    @Test func aPaddedKeyPathAnswersLikeItsTrimmedForm() throws {
        let (keys, secrets) = try emptyStores()
        let (id, path) = try registerManagedKey(in: keys)
        try secrets.savePassword("stored-pp", for: id)
        let padded = "  \(path)  "

        let paddedAnswer = SessionSecretPolicy.usesStoredManagedPassphrase(
            kind: .ssh, authChoice: .privateKey, keyPath: padded, keys: keys, secrets: secrets)
        let trimmedAnswer = SessionSecretPolicy.usesStoredManagedPassphrase(
            kind: .ssh, authChoice: .privateKey, keyPath: path, keys: keys, secrets: secrets)

        // Pinned separately from the equality below: without this, a policy
        // that stopped trimming would make both sides `false` and the
        // equality would still pass.
        #expect(paddedAnswer)
        #expect(paddedAnswer == trimmedAnswer)
    }
}

/// The edit-save path used to write `secrets.savePassword` unconditionally,
/// so editing a private-key login in place duplicated a passphrase that
/// already lived under the managed key's own slot into the session's slot as
/// well. `SessionSecretPolicy`'s own doc comment named that gap; these pin
/// that `updateSession` now asks the same question the new-session path does.
@Suite("updateSession honours the managed-key slot")
@MainActor
struct UpdateSessionManagedPassphraseTests {
    private func fixture() throws -> (dir: URL, keys: ManagedKeyStore, secrets: InMemorySecretStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, ManagedKeyStore(directory: dir), InMemorySecretStore())
    }

    private func managedKey(in keys: ManagedKeyStore) throws -> String {
        let key = ManagedKey(
            name: "k", comment: "", type: .ed25519, fingerprint: "SHA256:x",
            publicKeyOpenSSH: "ssh-ed25519 AAAA", createdAt: Date(),
            hasPassphrase: true, fileName: "kf")
        try keys.add(key)
        return keys.keyDirectory.appendingPathComponent("kf").path
    }

    /// Uses the suite-wide `sshSession` fixture rather than building the
    /// block by hand, so a later change to `StoredSSHConfig` reaches this
    /// test the same way it reaches every other.
    private func privateKeySession(keyPath: String) -> StoredSession {
        sshSession(name: "s", authKind: .privateKey, keyPath: keyPath)
    }

    @Test func aPassphraseAlreadyUnderTheKeysSlotIsNotCopiedIntoTheSessions() throws {
        let (dir, keys, secrets) = try fixture()
        let keyPath = try managedKey(in: keys)
        let store = SessionStore(directory: dir)
        let vm = SessionListViewModel(
            store: store, secrets: secrets, auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: keys)

        var session = privateKeySession(keyPath: keyPath)
        try store.upsert(session)
        // The key's OWN slot already holds it -- that is what makes this the
        // duplication case rather than an ordinary first write.
        let keyID = try #require(keys.all().first?.id)
        try secrets.savePassword("from-the-key", for: keyID)

        session.name = "renamed"
        vm.updateSession(session, newSecret: "typed-again")

        let sessionSlot = try? secrets.password(for: session.id)
        #expect(sessionSlot == nil, "the session's own slot must stay empty")
    }

    @Test func aManagedKeyWithoutAStoredPassphraseStillGetsTheSessionSlot() throws {
        let (dir, keys, secrets) = try fixture()
        let keyPath = try managedKey(in: keys)
        let store = SessionStore(directory: dir)
        let vm = SessionListViewModel(
            store: store, secrets: secrets, auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: keys)

        var session = privateKeySession(keyPath: keyPath)
        try store.upsert(session)
        // No slot under the key: the passphrase has nowhere else to live.

        session.name = "renamed"
        vm.updateSession(session, newSecret: "typed-again")

        let sessionSlot = try? secrets.password(for: session.id)
        #expect(sessionSlot == "typed-again")
    }
}
