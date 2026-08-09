import Foundation
import Testing
@testable import macSCPCore

@Suite("LegacyJumpSecretSweep")
struct LegacyJumpSecretSweepTests {

    /// The three real stores, all pointed at one throwaway directory --
    /// exactly how the app lays them out. Nothing is written here: which of
    /// the four files exists, and whether it decodes, is precisely what every
    /// decision below turns on, so each test puts them there itself.
    private struct Stores {
        let directory: URL
        let sessions: SessionStore
        let loginSets: LoginSetStore
        let keys: ManagedKeyStore
    }

    private func makeStores() throws -> Stores {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Stores(
            directory: dir,
            sessions: SessionStore(directory: dir),
            loginSets: LoginSetStore(directory: dir),
            keys: ManagedKeyStore(directory: dir))
    }

    private func sweep(_ stores: Stores, _ secrets: any SecretStore) -> LegacyJumpSecretSweep {
        LegacyJumpSecretSweep(
            sessions: stores.sessions, loginSets: stores.loginSets,
            keys: stores.keys, secrets: secrets)
    }

    /// The value stored under a slot. Never asserted on and never printed:
    /// these tests only ever ask WHICH ids a store holds, never what is in
    /// them.
    private static let storedValue = "placeholder"

    /// Puts `sessions-v2.json` on disk, with one SSH session per `claiming`
    /// id carrying that id as its jump `secretID`.
    ///
    /// Call this BEFORE writing the legacy file. `SessionStore.load()` reads
    /// `sessions-v2.json` when it exists and only migrates `sessions.json`
    /// otherwise -- and a migration would carry every legacy SSH jump into
    /// the new file, so every candidate would come back claimed and there
    /// would be nothing to sweep.
    ///
    /// The jumpless session is always written so the file exists even when
    /// nothing is claimed.
    private func seedMigratedSessions(_ store: SessionStore, claiming: [UUID] = []) throws {
        try store.upsert(StoredSession(
            name: "plain", kind: .ssh,
            ssh: StoredSSHConfig(host: "example.com", username: "tim")))
        for secretID in claiming {
            try store.upsert(StoredSession(
                name: "with-jump", kind: .ssh,
                ssh: StoredSSHConfig(
                    host: "example.com", username: "tim",
                    jump: StoredSession.JumpSpec(
                        host: "bastion.example.com", username: "tim", secretID: secretID))))
        }
    }

    /// The preserved pre-M23 file, in the container shape nearly every real
    /// install carries. The fixture is `SessionStoreTests`' -- the same bytes
    /// Task 1's reader is tested against, so the two halves of M27 cannot
    /// drift apart on what a legacy file looks like.
    private func writeLegacyFile(_ directory: URL, jumpSecretIDs: [UUID?]) throws {
        try SessionStoreTests.legacyContainerFixture(withJumpSecretIDs: jumpSecretIDs)
            .write(to: directory.appendingPathComponent("sessions.json"))
    }

    /// Bytes that are not JSON, so the store reading this file throws.
    private func writeUndecodableFile(_ url: URL) throws {
        try Data("{ not json".utf8).write(to: url)
    }

    private func managedKey(id: UUID) -> ManagedKey {
        ManagedKey(
            id: id, name: "key", comment: "", type: .ed25519,
            fingerprint: "SHA256:test", publicKeyOpenSSH: "ssh-ed25519 AAAA",
            createdAt: Date(timeIntervalSince1970: 0), hasPassphrase: false,
            fileName: "\(id.uuidString).key")
    }

    /// The whole point: an id the legacy file names and nothing claims today
    /// is removed.
    @Test func removesAJumpSecretNoRecordClaimsAnyMore() throws {
        let stores = try makeStores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        try seedMigratedSessions(stores.sessions)
        let orphan = UUID()
        try writeLegacyFile(stores.directory, jumpSecretIDs: [orphan])
        let secrets = InMemorySecretStore()
        try secrets.savePassword(Self.storedValue, for: orphan)

        let result = try sweep(stores, secrets).run()

        #expect(result == LegacyJumpSecretSweep.Result(removed: 1, failed: 0))
        #expect(secrets.storedIDs.isEmpty)
    }

    /// The counterpart, and the more important half: an SSH session kept its
    /// jump through the migration, so its secretID appears in BOTH files.
    @Test func keepsAJumpSecretThatASessionStillClaims() throws {
        let stores = try makeStores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        let kept = UUID(), orphan = UUID()
        try seedMigratedSessions(stores.sessions, claiming: [kept])
        try writeLegacyFile(stores.directory, jumpSecretIDs: [kept, orphan])
        let secrets = InMemorySecretStore()
        try secrets.savePassword(Self.storedValue, for: kept)
        try secrets.savePassword(Self.storedValue, for: orphan)

        let result = try sweep(stores, secrets).run()

        #expect(result == LegacyJumpSecretSweep.Result(removed: 1, failed: 0))
        #expect(secrets.storedIDs == [kept])
    }

    /// Not "the id we asked about is gone" but "nothing is gone anywhere".
    /// `storedIDs` exists on the double for exactly this.
    @Test func removesNothingElseFromTheSecretStore() throws {
        let stores = try makeStores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        try seedMigratedSessions(stores.sessions)
        let loginSetID = UUID(), keyID = UUID(), unrelated = UUID()
        try stores.loginSets.upsert(LoginSet(id: loginSetID, name: "set", username: "tim"))
        try stores.keys.add(managedKey(id: keyID))
        let orphan = UUID()
        try writeLegacyFile(stores.directory, jumpSecretIDs: [orphan])
        let secrets = InMemorySecretStore()
        for id in [orphan, loginSetID, keyID, unrelated] {
            try secrets.savePassword(Self.storedValue, for: id)
        }

        _ = try sweep(stores, secrets).run()

        #expect(secrets.storedIDs == [loginSetID, keyID, unrelated])
    }

    /// The catastrophic case. A session file that cannot be read must not
    /// read as "no session claims anything" -- that would make every live
    /// jump secret a candidate.
    @Test func anUnreadableSessionFileDeletesNothingAndThrows() throws {
        let stores = try makeStores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        let orphan = UUID()
        try writeLegacyFile(stores.directory, jumpSecretIDs: [orphan])
        try writeUndecodableFile(stores.directory.appendingPathComponent("sessions-v2.json"))
        let secrets = InMemorySecretStore()
        try secrets.savePassword(Self.storedValue, for: orphan)

        #expect(throws: (any Error).self) { try sweep(stores, secrets).run() }
        #expect(secrets.storedIDs == [orphan])
    }

    @Test func anUnreadableLoginSetFileDeletesNothingAndThrows() throws {
        let stores = try makeStores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        try seedMigratedSessions(stores.sessions)
        let orphan = UUID()
        try writeLegacyFile(stores.directory, jumpSecretIDs: [orphan])
        try writeUndecodableFile(stores.directory.appendingPathComponent("logins.json"))
        let secrets = InMemorySecretStore()
        try secrets.savePassword(Self.storedValue, for: orphan)

        #expect(throws: (any Error).self) { try sweep(stores, secrets).run() }
        #expect(secrets.storedIDs == [orphan])
    }

    @Test func anUnreadableManagedKeyFileDeletesNothingAndThrows() throws {
        let stores = try makeStores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        try seedMigratedSessions(stores.sessions)
        let orphan = UUID()
        try writeLegacyFile(stores.directory, jumpSecretIDs: [orphan])
        try writeUndecodableFile(stores.directory.appendingPathComponent("managed_keys.json"))
        let secrets = InMemorySecretStore()
        try secrets.savePassword(Self.storedValue, for: orphan)

        #expect(throws: (any Error).self) { try sweep(stores, secrets).run() }
        #expect(secrets.storedIDs == [orphan])
    }

    @Test func anUnreadableLegacyFileDeletesNothingAndThrows() throws {
        let stores = try makeStores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        try seedMigratedSessions(stores.sessions)
        try writeUndecodableFile(stores.directory.appendingPathComponent("sessions.json"))
        let secrets = InMemorySecretStore()
        let existing = UUID()
        try secrets.savePassword(Self.storedValue, for: existing)

        #expect(throws: (any Error).self) { try sweep(stores, secrets).run() }
        #expect(secrets.storedIDs == [existing])
    }

    /// No legacy file at all is a clean install, not an error.
    @Test func aMissingLegacyFileIsNotAnError() throws {
        let stores = try makeStores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        try seedMigratedSessions(stores.sessions)
        let secrets = InMemorySecretStore()
        let existing = UUID()
        try secrets.savePassword(Self.storedValue, for: existing)

        let result = try sweep(stores, secrets).run()

        #expect(result == LegacyJumpSecretSweep.Result(removed: 0, failed: 0))
        #expect(secrets.storedIDs == [existing])
    }

    /// House rule: one failure does not stop the rest (same shape as
    /// removing several known hosts).
    @Test func aFailingDeleteIsCountedAndTheRestStillRun() throws {
        let stores = try makeStores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        try seedMigratedSessions(stores.sessions)
        let stubborn = UUID(), reachable = UUID()
        try writeLegacyFile(stores.directory, jumpSecretIDs: [stubborn, reachable])
        let secrets = SelectivelyFailingSecretStore(failingDeletes: [stubborn])
        try secrets.savePassword(Self.storedValue, for: stubborn)
        try secrets.savePassword(Self.storedValue, for: reachable)

        let result = try sweep(stores, secrets).run()

        #expect(result == LegacyJumpSecretSweep.Result(removed: 1, failed: 1))
        #expect(secrets.storedIDs == [stubborn])
    }

    /// The sweep must never read a secret -- no access prompts, and no
    /// decision resting on a read that proves nothing when it fails.
    @Test func theSweepNeverReadsASecret() throws {
        let stores = try makeStores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        let kept = UUID(), orphan = UUID()
        try seedMigratedSessions(stores.sessions, claiming: [kept])
        try writeLegacyFile(stores.directory, jumpSecretIDs: [kept, orphan])

        let result = try sweep(stores, ReadForbiddenSecretStore()).run()

        #expect(result == LegacyJumpSecretSweep.Result(removed: 1, failed: 0))
    }

    /// A second run touches nothing it did not already touch. It does NOT
    /// report zero, and cannot: `deletePassword` succeeds on a slot that is
    /// already gone (`KeychainSecretStore` maps `errSecItemNotFound` to
    /// success), the legacy file stays on disk as M23's downgrade snapshot so
    /// the candidates are the same ones, and the sweep never reads -- so
    /// `removed` counts successful deletes, not entries that existed. Task
    /// 2's brief prescribed `asecondRunReportsNothingRemoved` and that
    /// expectation is unreachable without a read.
    @Test func asecondRunChangesNothingAndReportsNoFailures() throws {
        let stores = try makeStores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        let kept = UUID(), orphan = UUID()
        try seedMigratedSessions(stores.sessions, claiming: [kept])
        try writeLegacyFile(stores.directory, jumpSecretIDs: [kept, orphan])
        let secrets = InMemorySecretStore()
        try secrets.savePassword(Self.storedValue, for: kept)
        try secrets.savePassword(Self.storedValue, for: orphan)

        _ = try sweep(stores, secrets).run()
        let second = try sweep(stores, secrets).run()

        #expect(second.failed == 0)
        #expect(secrets.storedIDs == [kept])
    }
}

/// Test double for a Keychain that refuses to delete SOME entries -- the
/// per-item ACL case, where one slot prompts or errors and its neighbours do
/// not. `UnreliableSecretStore` fails every delete, which cannot show that a
/// failure and a success in the same run are both counted.
private final class SelectivelyFailingSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]
    private let failingDeletes: Set<UUID>

    init(failingDeletes: Set<UUID>) { self.failingDeletes = failingDeletes }

    func savePassword(_ password: String, for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = password
    }

    func password(for sessionID: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[sessionID]
    }

    func deletePassword(for sessionID: UUID) throws {
        if failingDeletes.contains(sessionID) { throw KeychainError(status: -25308) }
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = nil
    }

    /// See `InMemorySecretStore.storedIDs`.
    var storedIDs: Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        return Set(storage.keys)
    }
}

/// Test double proving the sweep never reads: `password(for:)` fails the test
/// if it is called at all. Same pattern as `LoginResolverTests`' agent double.
private final class ReadForbiddenSecretStore: SecretStore, @unchecked Sendable {
    func savePassword(_ password: String, for sessionID: UUID) throws {}
    func password(for sessionID: UUID) throws -> String? {
        Issue.record("the sweep must not read a secret")
        return nil
    }
    func deletePassword(for sessionID: UUID) throws {}
}
