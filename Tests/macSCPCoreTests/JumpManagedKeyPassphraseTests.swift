import Foundation
import Testing
@testable import macSCPCore

/// A jump hop whose login is a managed private key takes that key's own
/// Keychain passphrase, and reads the slot the hop is bound to — the jump's
/// own, its login set's, or the referenced session's — only when the managed
/// store answers nothing (maintainer answer of 2026-09-19).
///
/// Two defects, one row. The fallback of the technical backlog of 2026-09-16
/// (Task 5) applied only when the hop's own slot was EMPTY, so a stale value
/// already sitting there kept winning over the key's real passphrase. And the
/// save guard that stops the fill's own value from being copied back into the
/// hop's slot skipped every write, including one carrying a typed correction.
///
/// The guard's input is what a fill PUT in the field
/// (`ConnectionViewModel.filledJumpPassphrase`), not a fresh Keychain probe
/// (fix round 1). A probe answers about the key the jump names NOW, which is
/// not necessarily the key the value came from — repointing the jump at
/// another key made the next save write the first key's passphrase into the
/// hop's slot, which the session export reads.
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
    /// What a person types into the jump passphrase field over the value the
    /// fill put there — neither the managed key's nor the hop's stored one.
    private static let typedCorrection = "typed-correction-value"

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

    // MARK: - LoginResolver.preferringManagedKeyPassphrase, directly

    private static let unencryptedKeySlotValue = "unencrypted-key-slot-value"

    /// A key store holding the fixture's encrypted key (`hopkey`, slot holds
    /// `managedPassphrase`) plus an UNENCRYPTED managed key (`plainkey`,
    /// `hasPassphrase == false`) whose slot nonetheless holds a value — so a
    /// fallback that ignored the flag would be seen.
    private func makeKeys() throws -> (ManagedKeyStore, InMemorySecretStore, URL, encrypted: String, plain: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-fallback-\(UUID().uuidString)")
        let keys = ManagedKeyStore(directory: dir)
        let secrets = InMemorySecretStore()
        let encrypted = ManagedKey(
            name: "hop-key", comment: "", type: .ed25519, fingerprint: "SHA256:x",
            publicKeyOpenSSH: "ssh-ed25519 AAAA", createdAt: Date(timeIntervalSince1970: 0),
            hasPassphrase: true, fileName: "hopkey")
        let plain = ManagedKey(
            name: "plain-key", comment: "", type: .ed25519, fingerprint: "SHA256:p",
            publicKeyOpenSSH: "ssh-ed25519 AAAA", createdAt: Date(timeIntervalSince1970: 0),
            hasPassphrase: false, fileName: "plainkey")
        try keys.add(encrypted)
        try keys.add(plain)
        try secrets.savePassword(Self.managedPassphrase, for: encrypted.id)
        try secrets.savePassword(Self.unencryptedKeySlotValue, for: plain.id)
        return (keys, secrets, dir,
                keys.keyDirectory.appendingPathComponent("hopkey").path,
                keys.keyDirectory.appendingPathComponent("plainkey").path)
    }

    private func login(keyPath: String?, secret: String?, authKind: StoredSession.AuthKind = .privateKey) -> ResolvedLogin {
        ResolvedLogin(username: "u", authKind: authKind, keyPath: keyPath, secret: secret)
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func anEmptyOrBlankKeyPathLeavesTheLoginUnchanged(keyPath: String) throws {
        let (keys, secrets, dir, _, _) = try makeKeys()
        defer { try? FileManager.default.removeItem(at: dir) }
        for typed in [nil, ""] as [String?] {
            let input = login(keyPath: keyPath, secret: typed)
            let unchanged = LoginResolver.preferringManagedKeyPassphrase(
                input, keys: keys, secrets: secrets) == input
            #expect(unchanged, "a blank key path resolved a passphrase")
        }
        let nilPath = login(keyPath: nil, secret: nil)
        let nilUnchanged = LoginResolver.preferringManagedKeyPassphrase(
            nilPath, keys: keys, secrets: secrets) == nilPath
        #expect(nilUnchanged, "a nil key path resolved a passphrase")
    }

    @Test func aManagedKeyWithoutAPassphraseLeavesTheLoginUnchanged() throws {
        let (keys, secrets, dir, _, plain) = try makeKeys()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = login(keyPath: plain, secret: nil)
        let unchanged = LoginResolver.preferringManagedKeyPassphrase(
            input, keys: keys, secrets: secrets) == input
        #expect(unchanged, "an unencrypted managed key's slot was read into the login")
    }

    /// The other half of the precedence: the managed store answering nothing
    /// leaves whatever the hop's own slot holds in place. Both spellings of
    /// "answers nothing" that a key path can produce — a managed key that is
    /// not encrypted, and a path macSCP does not manage at all — asked with a
    /// value in the hop's slot, so a resolver that dropped it would be seen.
    @Test func aManagedStoreThatAnswersNothingKeepsTheHopsOwnSlot() throws {
        let (keys, secrets, dir, _, plain) = try makeKeys()
        defer { try? FileManager.default.removeItem(at: dir) }
        for keyPath in [plain, dir.appendingPathComponent("foreign-key").path] {
            let resolved = LoginResolver.preferringManagedKeyPassphrase(
                login(keyPath: keyPath, secret: Self.ownPassphrase), keys: keys, secrets: secrets)
            let keptOwn = resolved.secret == Self.ownPassphrase
            #expect(keptOwn, "a key the store cannot answer for lost the hop's own passphrase")
        }
    }

    /// The third spelling of "answers nothing", and the one the reporting of
    /// 2026-09-18 is about: `managed_keys.json` cannot be read at all. The
    /// hop's own slot survives it — an unreadable store costs a hop nothing
    /// it already had.
    @Test func anUnreadableKeyStoreKeepsTheHopsOwnSlot() throws {
        let rig = try CorruptManagedKeyStoreRig()
        defer { rig.tearDown() }
        let resolved = LoginResolver.preferringManagedKeyPassphrase(
            login(keyPath: rig.managedKeyPath, secret: Self.ownPassphrase),
            keys: rig.keys, secrets: rig.secrets)
        let keptOwn = resolved.secret == Self.ownPassphrase
        #expect(keptOwn, "an unreadable managed key store cost the hop its own passphrase")
    }

    /// The precedence itself (maintainer answer of 2026-09-19): the managed
    /// key's passphrase wins over a value already sitting in the hop's slot.
    @Test func theManagedKeysPassphraseWinsOverTheHopsOwnSlot() throws {
        let (keys, secrets, dir, encrypted, _) = try makeKeys()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = login(keyPath: encrypted, secret: Self.ownPassphrase)
        let managedWins = LoginResolver.preferringManagedKeyPassphrase(
            input, keys: keys, secrets: secrets).secret == Self.managedPassphrase
        #expect(managedWins, "the hop's own stored slot still won over the managed key's")
    }

    /// Both spellings of "nothing typed" — a slot that holds no item (`nil`)
    /// and one that holds an empty string — take the managed key's value; a
    /// padded key path is trimmed before it is looked up.
    @Test(arguments: [nil, ""] as [String?])
    func nothingTypedTakesTheManagedKeysPassphrase(typed: String?) throws {
        let (keys, secrets, dir, encrypted, _) = try makeKeys()
        defer { try? FileManager.default.removeItem(at: dir) }
        for keyPath in [encrypted, "  \(encrypted)\n"] {
            let resolved = LoginResolver.preferringManagedKeyPassphrase(
                login(keyPath: keyPath, secret: typed), keys: keys, secrets: secrets)
            let takesManaged = resolved.secret == Self.managedPassphrase
            #expect(takesManaged, "nothing typed did not take the managed key's passphrase")
        }
    }

    @Test(arguments: [StoredSession.AuthKind.password, .agent])
    func aNonKeyLoginIsUnchanged(authKind: StoredSession.AuthKind) throws {
        let (keys, secrets, dir, encrypted, _) = try makeKeys()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = login(keyPath: encrypted, secret: nil, authKind: authKind)
        let unchanged = LoginResolver.preferringManagedKeyPassphrase(
            input, keys: keys, secrets: secrets) == input
        #expect(unchanged)
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

    /// The same precedence through the App's stored-session fill: a hop
    /// whose own slot still holds a stale passphrase dials with the managed
    /// key's.
    @Test func aStaleOwnJumpSlotLosesToTheManagedKeysPassphrase() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let spec = StoredSession.JumpSpec(
            host: "hop.invalid", username: "u", authKind: .privateKey, keyPath: fixture.keyPath)
        try fixture.secrets.savePassword(Self.ownPassphrase, for: spec.secretID)
        let stored = StoredSession(
            name: "through-hop", kind: .ssh,
            ssh: StoredSSHConfig(host: "target.invalid", username: "tim", jump: spec))

        let managedWins = try fixture.vm.resolvedJumpLogin(for: stored)?.secret == Self.managedPassphrase
        #expect(managedWins, "a stale value in the jump's own slot still won over the managed key's")
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

    // MARK: - What a fill put in the field is not copied into the jump's slot

    /// `ExportedSession.jumpPassword`, which is a hop's own slot read back
    /// verbatim (`SessionListViewModel.exportPayload`, jump branch). Every
    /// check below reads it: a stray write into that slot is not a stale
    /// value nobody sees, it is a secret that leaves the machine.
    private func exportedJumpPassword(
        _ vm: SessionListViewModel, _ session: StoredSession
    ) -> String? {
        vm.exportPayload(for: .single(session), includeGroups: false, includePasswords: true)
            .payload.sessions.first?.jumpPassword
    }

    private func hopSpec(keyPath: String) -> StoredSession.JumpSpec {
        StoredSession.JumpSpec(
            host: "hop.invalid", username: "u", authKind: .privateKey, keyPath: keyPath)
    }

    private func saveThroughHop(
        _ fixture: Fixture, _ spec: StoredSession.JumpSpec,
        jumpSecret: String, filled: String?
    ) -> StoredSession? {
        fixture.vm.save(
            name: "through-hop",
            values: sshValues(host: "target.invalid", username: "tim"),
            password: Self.targetSecret, jump: spec,
            jumpSecret: jumpSecret, filledJumpPassphrase: filled)
    }

    /// The fill puts the managed key's passphrase into `jumpPassword`, and
    /// both save paths hand `jumpPassword` back as `jumpSecret` — so without
    /// a guard, saving a form filled that way would put one passphrase in two
    /// places. Handed back unchanged, it is refused, and the export carries
    /// nothing.
    @Test func aFilledJumpPassphraseIsNotCopiedIntoTheHopsSlot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let spec = hopSpec(keyPath: fixture.keyPath)

        let saved = try #require(saveThroughHop(
            fixture, spec, jumpSecret: Self.managedPassphrase, filled: Self.managedPassphrase))
        let slotEmptyAfterSave = try fixture.secrets.password(for: spec.secretID) == nil
        #expect(slotEmptyAfterSave, "`save` copied the filled passphrase into the jump's slot")

        fixture.vm.updateSession(
            saved, newSecret: nil,
            jumpSecret: Self.managedPassphrase, filledJumpPassphrase: Self.managedPassphrase)
        let slotEmptyAfterUpdate = try fixture.secrets.password(for: spec.secretID) == nil
        #expect(slotEmptyAfterUpdate, "`updateSession` copied the filled passphrase into the jump's slot")

        let exportCarriesNothing = exportedJumpPassword(fixture.vm, saved) == nil
        #expect(exportCarriesNothing, "the export carried a passphrase nobody typed")
    }

    /// The defect of fix round 1: the key path moves out from under a filled
    /// passphrase. Changing it clears the field along with what the fill put
    /// there, so the next save has nothing to write and one key's passphrase
    /// cannot land in a hop that now names another.
    @Test func changingTheJumpKeyPathTakesTheFilledPassphraseWithIt() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let form = makeForm()
        form.jumpAuthChoice = .privateKey
        form.jumpKeyPath = fixture.keyPath
        form.fillJumpPassphrase(Self.managedPassphrase)
        let theFillReachedTheField = form.jumpPassword == Self.managedPassphrase
        #expect(theFillReachedTheField, "the fill did not reach the field")

        form.jumpKeyPath = fixture.dir.appendingPathComponent("other-key").path
        let fieldCleared = form.jumpPassword.isEmpty
        let rememberedFillCleared = form.filledJumpPassphrase == nil
        #expect(fieldCleared, "the field kept a passphrase belonging to the previous key")
        #expect(rememberedFillCleared, "the remembered fill outlived the key it came from")

        let spec = hopSpec(keyPath: form.jumpKeyPath)
        let saved = try #require(saveThroughHop(
            fixture, spec, jumpSecret: form.jumpPassword, filled: form.filledJumpPassphrase))
        let slotEmpty = try fixture.secrets.password(for: spec.secretID) == nil
        let exportCarriesNothing = exportedJumpPassword(fixture.vm, saved) == nil
        #expect(slotEmpty, "saving after a key-path change wrote another key's passphrase")
        #expect(exportCarriesNothing, "the export carried another key's passphrase")
    }

    /// The same for the auth kind: a passphrase belongs to a private-key
    /// login, and switching away from one takes it with it.
    @Test func changingTheJumpAuthKindTakesTheFilledPassphraseWithIt() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let form = makeForm()
        form.jumpAuthChoice = .privateKey
        form.jumpKeyPath = fixture.keyPath
        form.fillJumpPassphrase(Self.managedPassphrase)

        form.jumpAuthChoice = .password
        let fieldCleared = form.jumpPassword.isEmpty
        let rememberedFillCleared = form.filledJumpPassphrase == nil
        #expect(fieldCleared, "the field kept a key passphrase after the login stopped using a key")
        #expect(rememberedFillCleared, "the remembered fill outlived the auth kind it came from")
    }

    /// The saved-connection fill (`resolveJumpSession`) goes through the same
    /// door as the other three, so no fill leaves a managed key's passphrase
    /// in the field with nothing remembering that it put it there. Nothing
    /// reachable wrote it — a session-mode jump owns no slot — but the
    /// invariant the save guard is argued from has to be true, not nearly
    /// true.
    @Test func theSavedConnectionFillIsRememberedLikeEveryOther() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let bastion = try #require(fixture.vm.save(
            name: "bastion",
            values: sshValues(
                host: "bastion.invalid", username: "u", authKind: .privateKey,
                keyPath: fixture.keyPath),
            password: ""))

        let form = makeForm()
        form.jumpSourceMode = .session
        form.jumpSessionID = bastion.id
        #expect(fixture.vm.resolveJumpSession(form: form) == nil)
        let theFillReachedTheField = form.jumpPassword == Self.managedPassphrase
        let remembered = form.filledJumpPassphrase == Self.managedPassphrase
        #expect(theFillReachedTheField, "the saved-connection fill did not reach the field")
        #expect(remembered, "the saved-connection fill was not remembered")

        // And its echo is refused exactly as every other fill's is, at a
        // manual hop -- the shape that does own a slot.
        let spec = hopSpec(keyPath: fixture.keyPath)
        let saved = try #require(saveThroughHop(
            fixture, spec, jumpSecret: form.jumpPassword, filled: form.filledJumpPassphrase))
        let slotEmpty = try fixture.secrets.password(for: spec.secretID) == nil
        let exportCarriesNothing = exportedJumpPassword(fixture.vm, saved) == nil
        #expect(slotEmpty, "the saved-connection fill's echo was written into a hop's own slot")
        #expect(exportCarriesNothing, "the export carried the saved-connection fill's value")
    }

    /// `adoptFilledJumpPassphrase` refuses a memory the field does not hold.
    /// That is the one thing a carry between two forms can get wrong — it
    /// copies `values` wholesale, so the field and the memory of it arrive by
    /// different routes — and the reason it is not a plain assignment.
    @Test func aRememberedFillIsRefusedWhenTheFieldDoesNotHoldIt() throws {
        let form = makeForm()
        form.jumpPassword = Self.typedCorrection
        form.adoptFilledJumpPassphrase(Self.managedPassphrase)
        let refused = form.filledJumpPassphrase == nil
        #expect(refused, "a form claimed a fill its own field does not hold")

        form.adoptFilledJumpPassphrase(Self.typedCorrection)
        let accepted = form.filledJumpPassphrase == Self.typedCorrection
        #expect(accepted, "a form refused a fill its own field does hold")
    }

    /// Typing over what the fill put there ends the fill — the form-level
    /// half of the correction path, and the reason the save's comparison is
    /// enough. Any write to the field that is not the fill's own value drops
    /// the memory of it.
    @Test func typingOverTheFilledPassphraseEndsTheFill() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let form = makeForm()
        form.jumpAuthChoice = .privateKey
        form.jumpKeyPath = fixture.keyPath
        form.fillJumpPassphrase(Self.managedPassphrase)
        let rememberedAfterTheFill = form.filledJumpPassphrase == Self.managedPassphrase
        #expect(rememberedAfterTheFill, "the fill was not remembered")

        form.jumpPassword = Self.typedCorrection
        let rememberedFillCleared = form.filledJumpPassphrase == nil
        #expect(rememberedFillCleared, "a typed value was still read as the fill's own")
    }

    /// A Keychain that is there but not answering changes nothing: the
    /// decision is the comparison above, and no probe is made at save time.
    /// Read through `peek`, since this store's own read path is rigged to
    /// fail.
    @Test func aKeychainThatWillNotAnswerCopiesNoFilledPassphrase() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-jumpkey-unreadable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = UnreliableSecretStore(failsReads: true)
        let keys = ManagedKeyStore(directory: dir)
        let key = ManagedKey(
            name: "hop-key", comment: "", type: .ed25519, fingerprint: "SHA256:x",
            publicKeyOpenSSH: "ssh-ed25519 AAAA", createdAt: Date(timeIntervalSince1970: 0),
            hasPassphrase: true, fileName: "hopkey")
        try keys.add(key)
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            auditStore: AuditLogStore(directory: dir),
            loginSetStore: LoginSetStore(directory: dir), keys: keys)
        let spec = hopSpec(keyPath: keys.keyDirectory.appendingPathComponent("hopkey").path)

        _ = vm.save(
            name: "through-hop",
            values: sshValues(host: "target.invalid", username: "tim"),
            password: Self.targetSecret, jump: spec,
            jumpSecret: Self.managedPassphrase, filledJumpPassphrase: Self.managedPassphrase)
        let slotEmpty = secrets.peek(spec.secretID) == nil
        #expect(slotEmpty, "a Keychain that would not answer let the filled passphrase through")
    }

    /// A typed correction — a jump passphrase field holding something OTHER
    /// than what the fill put there — is what the guard must not eat. Both
    /// save paths write it, and the export carries exactly it.
    @Test func aTypedCorrectionReachesTheJumpsOwnSlot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let spec = hopSpec(keyPath: fixture.keyPath)
        try fixture.secrets.savePassword(Self.ownPassphrase, for: spec.secretID)

        let saved = try #require(saveThroughHop(
            fixture, spec, jumpSecret: Self.typedCorrection, filled: Self.managedPassphrase))
        let savedTheCorrection = try fixture.secrets.password(for: spec.secretID) == Self.typedCorrection
        #expect(savedTheCorrection, "`save` skipped a typed correction into the jump's own slot")

        try fixture.secrets.savePassword(Self.ownPassphrase, for: spec.secretID)
        fixture.vm.updateSession(
            saved, newSecret: nil,
            jumpSecret: Self.typedCorrection, filledJumpPassphrase: Self.managedPassphrase)
        let updatedTheCorrection = try fixture.secrets.password(for: spec.secretID) == Self.typedCorrection
        #expect(updatedTheCorrection, "`updateSession` skipped a typed correction into the jump's own slot")

        let exportCarriesOnlyWhatWasTyped = exportedJumpPassword(fixture.vm, saved) == Self.typedCorrection
        #expect(exportCarriesOnlyWhatWasTyped, "the export carried something other than what was typed")
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
