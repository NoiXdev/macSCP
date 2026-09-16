import Foundation
import Testing
@testable import macSCPCore

/// A jump hop's passphrase falls back to the managed key's own Keychain slot
/// when the slot the hop reads — the jump's own, its login set's, or the
/// referenced session's — is empty (technical backlog of 2026-09-16, Task 5).
///
/// Before this, the jump path ran no `ManagedKeyPassphrase.resolve` at all:
/// a slot dropped for the managed key's (one passphrase, one place) left any
/// jump hop added AFTER the drop with nothing to authenticate with.
///
/// Passphrases live in named constants and are compared into a `Bool` before
/// any expectation, so a failure message can carry neither the value nor its
/// spelling.
@Suite("Jump hop managed-key passphrase")
@MainActor
struct JumpManagedKeyPassphraseTests {
    private static let managedPassphrase = "managed-slot-value"
    private static let ownPassphrase = "own-slot-value"
    private static let targetSecret = "target-slot-value"

    private struct Fixture {
        let vm: SessionListViewModel
        let secrets: InMemorySecretStore
        let dir: URL
        /// The managed key's file path, as a session or set would store it.
        let keyPath: String
    }

    /// A view model whose key store manages one encrypted key with a stored
    /// passphrase. The key store is the view model's own directory, so
    /// `SessionListViewModel.keys` sees the key this adds.
    private func makeFixture() throws -> Fixture {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-jumpkey-\(UUID().uuidString)")
        let secrets = InMemorySecretStore()
        let keys = ManagedKeyStore(directory: dir)
        let key = ManagedKey(
            name: "hop-key", comment: "", type: .ed25519, fingerprint: "SHA256:x",
            publicKeyOpenSSH: "ssh-ed25519 AAAA", createdAt: Date(timeIntervalSince1970: 0),
            hasPassphrase: true, fileName: "hopkey")
        try keys.add(key)
        try secrets.savePassword(Self.managedPassphrase, for: key.id)
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: keys)
        let keyPath = keys.keyDirectory.appendingPathComponent("hopkey").path
        return Fixture(vm: vm, secrets: secrets, dir: dir, keyPath: keyPath)
    }

    /// A form whose target half is complete, so a resolution can only fail
    /// or succeed on the jump.
    private func makeForm() -> ConnectionViewModel {
        let form = ConnectionViewModel(connector: { _, _ in throw CancellationError() })
        form.host = "target.invalid"
        form.port = "22"
        form.username = "tim"
        form.password = Self.targetSecret
        form.jumpEnabled = true
        form.jumpHost = "hop.invalid"
        form.jumpPort = "22"
        return form
    }

    /// The jump auth the form resolves to, without dialing.
    private func resolvedJumpAuth(_ form: ConnectionViewModel) -> SSHConnectionConfig.AuthMethod? {
        guard case .resolved(let config) = form.resolveConfigWithoutDialing(),
              case .ssh(let ssh) = config
        else { return nil }
        return ssh.jump?.auth
    }

    // MARK: - The fallback reaches the jump config

    @Test func aJumpBoundToASetWithAnEmptySlotDialsWithTheManagedKeysPassphrase() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let set = LoginSet(name: "hop", username: "u", authKind: .privateKey, keyPath: fixture.keyPath)
        fixture.vm.saveLoginSet(set, secret: nil)

        let form = makeForm()
        form.jumpLoginMode = .set
        form.jumpSelectedLoginSetID = set.id

        #expect(fixture.vm.resolveJumpLoginSet(form: form) == nil)
        let reachesTheConfig = resolvedJumpAuth(form)
            == .privateKey(keyPath: fixture.keyPath, passphrase: Self.managedPassphrase)
        #expect(reachesTheConfig, """
            a jump bound to a private-key set with an empty slot did not carry the managed \
            key's passphrase into the jump config
            """)
    }

    @Test func aJumpThroughASessionWithAnEmptySlotDialsWithTheManagedKeysPassphrase() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let bastion = try #require(fixture.vm.save(
            name: "bastion",
            values: sshValues(
                host: "bastion.invalid", username: "u", authKind: .privateKey,
                keyPath: fixture.keyPath),
            password: ""))
        let bastionSlotIsEmpty = ((try fixture.secrets.password(for: bastion.id)) ?? "").isEmpty
        #expect(bastionSlotIsEmpty, "the fixture planted a passphrase in the bastion's own slot")

        let form = makeForm()
        form.jumpSourceMode = .session
        form.jumpSessionID = bastion.id

        #expect(fixture.vm.resolveJumpSession(form: form) == nil)
        let reachesTheConfig = resolvedJumpAuth(form)
            == .privateKey(keyPath: fixture.keyPath, passphrase: Self.managedPassphrase)
        #expect(reachesTheConfig, """
            a session-mode jump whose referenced session's slot is empty did not carry the \
            managed key's passphrase into the jump config
            """)
    }

    /// The two resolutions the App's stored-session fill reads
    /// (`ContentView.fillForm`), for a jump in its own mode with its own slot
    /// empty.
    @Test func aStoredJumpWithAnEmptyOwnSlotResolvesTheManagedKeysPassphrase() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let stored = StoredSession(
            name: "through-hop", kind: .ssh,
            ssh: StoredSSHConfig(
                host: "target.invalid", username: "tim",
                jump: .init(
                    host: "hop.invalid", username: "u", authKind: .privateKey,
                    keyPath: fixture.keyPath)))

        let viaLogin = try fixture.vm.resolvedJumpLogin(for: stored)?.secret == Self.managedPassphrase
        let viaJump = try fixture.vm.resolvedJump(for: stored)?.login.secret == Self.managedPassphrase
        #expect(viaLogin, "`resolvedJumpLogin(for:)` did not fall back to the managed key's slot")
        #expect(viaJump, "`resolvedJump(for:)` did not fall back to the managed key's slot")
    }

    // MARK: - What the fallback leaves alone

    /// `ManagedKeyPassphrase.resolve` answers the typed value first, and on
    /// the jump path the slot's value is what is typed.
    @Test func aJumpsOwnPassphraseStillWins() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let spec = StoredSession.JumpSpec(
            host: "hop.invalid", username: "u", authKind: .privateKey, keyPath: fixture.keyPath)
        try fixture.secrets.savePassword(Self.ownPassphrase, for: spec.secretID)
        let stored = StoredSession(
            name: "through-hop", kind: .ssh,
            ssh: StoredSSHConfig(host: "target.invalid", username: "tim", jump: spec))

        let ownWins = try fixture.vm.resolvedJumpLogin(for: stored)?.secret == Self.ownPassphrase
        #expect(ownWins, "the jump's own slot no longer wins over the managed key's")
    }

    /// A password jump has no key to fall back to — even one whose set still
    /// carries a managed key path from an earlier private-key login.
    @Test func aPasswordJumpIsUnaffected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let set = LoginSet(name: "hop", username: "u", authKind: .password, keyPath: fixture.keyPath)
        fixture.vm.saveLoginSet(set, secret: nil)
        let stored = StoredSession(
            name: "through-hop", kind: .ssh,
            ssh: StoredSSHConfig(
                host: "target.invalid", username: "tim",
                jump: .init(
                    host: "hop.invalid", username: "u", authKind: .password,
                    keyPath: fixture.keyPath)))

        let form = makeForm()
        form.jumpLoginMode = .set
        form.jumpSelectedLoginSetID = set.id
        #expect(fixture.vm.resolveJumpLoginSet(form: form) == nil)
        let formPasswordEmpty = form.jumpPassword.isEmpty
        let storedSecretNil = try fixture.vm.resolvedJumpLogin(for: stored)?.secret == nil
        #expect(formPasswordEmpty, "a password jump's form was filled from the managed key's slot")
        #expect(storedSecretNil, "a password jump resolved a secret from the managed key's slot")
    }

    // MARK: - The fallback's value is not copied back into the jump's slot

    /// The fill above puts the managed key's passphrase into `jumpPassword`,
    /// and both save paths write `jumpSecret` into the jump's own slot — so
    /// without a guard, saving a form filled that way would put the one
    /// passphrase in two places again. The same rule the target's save
    /// applies (`SessionSecretPolicy.usesStoredManagedPassphrase`).
    @Test func savingAJumpOnAManagedKeyWithAStoredPassphraseWritesNoJumpSlot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let spec = StoredSession.JumpSpec(
            host: "hop.invalid", username: "u", authKind: .privateKey, keyPath: fixture.keyPath)

        let saved = try #require(fixture.vm.save(
            name: "through-hop",
            values: sshValues(host: "target.invalid", username: "tim"),
            password: Self.targetSecret, jump: spec, jumpSecret: Self.managedPassphrase))
        let slotEmptyAfterSave = try fixture.secrets.password(for: spec.secretID) == nil
        #expect(slotEmptyAfterSave, "`save` copied the managed key's passphrase into the jump's slot")

        fixture.vm.updateSession(saved, newSecret: nil, jumpSecret: Self.managedPassphrase)
        let slotEmptyAfterUpdate = try fixture.secrets.password(for: spec.secretID) == nil
        #expect(slotEmptyAfterUpdate, "`updateSession` copied the managed key's passphrase into the jump's slot")
    }

    /// The positive beside the check above: a key macSCP does not manage
    /// keeps its passphrase in the jump's own slot, exactly as before.
    @Test func savingAJumpOnAForeignKeyStillWritesTheJumpSlot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let spec = StoredSession.JumpSpec(
            host: "hop.invalid", username: "u", authKind: .privateKey,
            keyPath: fixture.dir.appendingPathComponent("foreign-key").path)

        _ = try #require(fixture.vm.save(
            name: "through-hop",
            values: sshValues(host: "target.invalid", username: "tim"),
            password: Self.targetSecret, jump: spec, jumpSecret: Self.ownPassphrase))
        let written = try fixture.secrets.password(for: spec.secretID) == Self.ownPassphrase
        #expect(written, "a foreign key's jump passphrase was not written into the jump's slot")
    }
}
