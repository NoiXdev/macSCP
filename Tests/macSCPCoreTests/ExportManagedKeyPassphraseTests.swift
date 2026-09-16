import Foundation
import Testing
@testable import macSCPCore

/// The session export's "N passwords missing" count and a managed key's own
/// passphrase (technical backlog of 2026-09-16, Task 5).
///
/// A private-key login whose managed key's Keychain slot holds the passphrase
/// carries no copy of its own — the slot was dropped after a conversion, or
/// never written (`SessionSecretPolicy.usesStoredManagedPassphrase`). The
/// export read only the login's own slot and counted that login as missing a
/// passphrase it has. It now counts it as covered. What the export WRITES is
/// unchanged: the managed key's passphrase never travels as the session's
/// `password` or `jumpPassword`.
@Suite("Session export and managed-key passphrases")
@MainActor
struct ExportManagedKeyPassphraseTests {
    private static let managedPassphrase = "managed-slot-value"

    private struct Fixture {
        let vm: SessionListViewModel
        let secrets: InMemorySecretStore
        let dir: URL
        let keys: ManagedKeyStore
        /// A managed key whose own slot holds the passphrase.
        let coveredPath: String
        /// A managed, encrypted key with no slot (a login-set export without
        /// secrets materializes one).
        let uncoveredPath: String
    }

    private func makeFixture() throws -> Fixture {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-exportkey-\(UUID().uuidString)")
        let secrets = InMemorySecretStore()
        let keys = ManagedKeyStore(directory: dir)
        let covered = ManagedKey(
            name: "covered", comment: "", type: .ed25519, fingerprint: "SHA256:c",
            publicKeyOpenSSH: "ssh-ed25519 AAAA", createdAt: Date(timeIntervalSince1970: 0),
            hasPassphrase: true, fileName: "covered")
        let uncovered = ManagedKey(
            name: "uncovered", comment: "", type: .ed25519, fingerprint: "SHA256:u",
            publicKeyOpenSSH: "ssh-ed25519 AAAA", createdAt: Date(timeIntervalSince1970: 0),
            hasPassphrase: true, fileName: "uncovered")
        try keys.add(covered)
        try keys.add(uncovered)
        try secrets.savePassword(Self.managedPassphrase, for: covered.id)
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: keys)
        return Fixture(
            vm: vm, secrets: secrets, dir: dir, keys: keys,
            coveredPath: keys.keyDirectory.appendingPathComponent("covered").path,
            uncoveredPath: keys.keyDirectory.appendingPathComponent("uncovered").path)
    }

    /// A private-key session with NO slot of its own — the state a
    /// conversion's drop leaves (`save` writes even an empty passphrase, so
    /// the slot is dropped explicitly afterwards).
    private func keySession(_ fixture: Fixture, path: String) throws -> StoredSession {
        let session = try #require(fixture.vm.save(
            name: "key-\(UUID().uuidString)",
            values: sshValues(host: "target.invalid", username: "tim", authKind: .privateKey, keyPath: path),
            password: ""))
        fixture.vm.dropSessionSecret(for: session.id)
        let noSlot = try fixture.secrets.password(for: session.id) == nil
        #expect(noSlot, "the fixture left a slot on the session")
        return session
    }

    private func exportMissing(_ fixture: Fixture, _ session: StoredSession)
        -> (missing: Int, carriesNoSecret: Bool)
    {
        let result = fixture.vm.exportPayload(
            for: .single(session), includeGroups: false, includePasswords: true)
        let exported = result.payload.sessions.first
        let carriesNoSecret = exported?.password == nil && exported?.jumpPassword == nil
        return (result.missingPasswordCount, carriesNoSecret)
    }

    @Test func aSessionOnAManagedKeyWithAStoredPassphraseIsCovered() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let session = try keySession(fixture, path: fixture.coveredPath)

        let result = exportMissing(fixture, session)
        #expect(result.missing == 0, "a session whose managed key holds the passphrase was counted missing")
        #expect(result.carriesNoSecret, "the export wrote the managed key's passphrase into the session")
    }

    @Test func aSetBoundSessionOnAManagedKeyWithAStoredPassphraseIsCovered() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let set = LoginSet(name: "team", username: "u", authKind: .privateKey, keyPath: fixture.coveredPath)
        #expect(fixture.vm.saveLoginSet(set, secret: nil))
        let session = try #require(fixture.vm.save(
            name: "bound",
            values: sshValues(host: "target.invalid", username: "tim"),
            password: "", loginSetID: set.id))

        let result = exportMissing(fixture, session)
        #expect(result.missing == 0, "a set-bound session whose managed key holds the passphrase was counted missing")
        #expect(result.carriesNoSecret)
    }

    @Test func aJumpOnAManagedKeyWithAStoredPassphraseIsCovered() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let session = try #require(fixture.vm.save(
            name: "through-hop",
            values: sshValues(host: "target.invalid", username: "tim", authKind: .agent),
            password: "",
            jump: .init(
                host: "hop.invalid", username: "u", authKind: .privateKey,
                keyPath: fixture.coveredPath)))

        let result = exportMissing(fixture, session)
        #expect(result.missing == 0, "a jump whose managed key holds the passphrase was counted missing")
        #expect(result.carriesNoSecret)
    }

    /// The positives beside the checks above: a managed key WITHOUT a slot,
    /// and a key macSCP does not manage, are still missing a passphrase when
    /// the login's own slot is empty.
    @Test func aKeyWhoseSlotHoldsNothingIsStillMissing() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let uncovered = try keySession(fixture, path: fixture.uncoveredPath)
        let foreign = try keySession(fixture, path: fixture.dir.appendingPathComponent("foreign").path)

        #expect(exportMissing(fixture, uncovered).missing == 1)
        #expect(exportMissing(fixture, foreign).missing == 1)
    }
}
