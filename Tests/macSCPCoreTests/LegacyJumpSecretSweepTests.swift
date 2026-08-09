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
    /// otherwise, so writing it first is what keeps the migration out of
    /// these tests and lets each of them state its claimed set outright.
    ///
    /// Skipping the migration is not the same as skipping nothing.
    /// `LegacyStoredSession.upgraded()` treats the two kinds of legacy record
    /// differently: an `.ssh` record's jump is carried into the new file and
    /// comes back claimed, a non-SSH record's jump is dropped and stays a
    /// candidate -- that dropped one is the orphan M27 exists for. The
    /// records `legacyRecords` writes carry no `kind` key and therefore
    /// upgrade as `.ssh`, so for THESE fixtures a migration would leave
    /// nothing to sweep. `sweepsOnlyTheJumpTheMigrationDropsWhenItRunsOnFirstLaunch`
    /// is the one test that lets the migration run and pins that difference.
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
    private func writeLegacyFile(
        _ directory: URL, jumpSecretIDs: [UUID?], kinds: [ConnectionKind?] = []
    ) throws {
        try SessionStoreTests.legacyContainerFixture(
            withJumpSecretIDs: jumpSecretIDs, kinds: kinds)
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

    /// The milestone in one test, and the only one that runs the path a real
    /// user takes: `sessions-v2.json` does not exist yet, so the migration
    /// runs INSIDE `claimedIDs()` and decides the claimed set as it goes.
    ///
    /// Two legacy records, one jump each. `upgraded()` keeps the jump of the
    /// `.ssh` record, whose secretID therefore comes back claimed; it drops
    /// the jump of the `.webdav` record, which is precisely the entry M23
    /// orphaned and this sweep exists to remove. That asymmetry is what makes
    /// the sweep safe, and every other test here bypasses it by writing
    /// `sessions-v2.json` first.
    @Test func sweepsOnlyTheJumpTheMigrationDropsWhenItRunsOnFirstLaunch() throws {
        let stores = try makeStores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        let carried = UUID(), dropped = UUID()
        try writeLegacyFile(
            stores.directory, jumpSecretIDs: [carried, dropped], kinds: [.ssh, .webdav])
        #expect(!FileManager.default.fileExists(
            atPath: stores.directory.appendingPathComponent("sessions-v2.json")
                .path(percentEncoded: false)))
        let secrets = InMemorySecretStore()
        try secrets.savePassword(Self.storedValue, for: carried)
        try secrets.savePassword(Self.storedValue, for: dropped)

        let result = try sweep(stores, secrets).run()

        #expect(result == LegacyJumpSecretSweep.Result(removed: 1, failed: 0))
        #expect(secrets.storedIDs == [carried])
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

    /// The weakest of the four abort tests, and unavoidably so: reading the
    /// legacy file is the FIRST statement of `run()`, so there is no way to
    /// arrange a candidate the sweep already knows about. The store here holds
    /// an id that was never a candidate, which means the `storedIDs`
    /// assertion would hold for any implementation that throws at all -- the
    /// throw is what this one proves. Its three siblings carry the ordering
    /// proof, because there the candidates are already in hand when the
    /// failing read happens.
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

    /// The same rule with NO candidates at all: no legacy file, and a
    /// `sessions-v2.json` that cannot be read. Nothing could be deleted here
    /// whatever the sweep did, which is why this was easy to miss -- but a
    /// run that reports success has told the user their leftover credentials
    /// were checked when the file that decides what is claimed never opened.
    /// An unreadable store aborts, candidates or none.
    @Test func anUnreadableSessionFileThrowsEvenWithNoCandidates() throws {
        let stores = try makeStores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        try writeUndecodableFile(stores.directory.appendingPathComponent("sessions-v2.json"))
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

        let first = try sweep(stores, secrets).run()
        let second = try sweep(stores, secrets).run()

        // The whole result, not just `failed`: `removed: 1` a second time is
        // the claim above made checkable. `InMemorySecretStore.deletePassword`
        // cannot throw, so asserting only `failed == 0` would hold for any
        // implementation at all.
        #expect(first == LegacyJumpSecretSweep.Result(removed: 1, failed: 0))
        #expect(second == LegacyJumpSecretSweep.Result(removed: 1, failed: 0))
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
