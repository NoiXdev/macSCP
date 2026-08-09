import Foundation
import Testing
@testable import macSCPCore

@Suite("SubmitPreparation")
@MainActor
struct SubmitPreparationTests {
    /// Same shape as `SessionListViewModelTests.makeVM` — read that helper
    /// and mirror it rather than inventing a second construction.
    private func makeVM() -> (SessionListViewModel, InMemorySecretStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-submit-\(UUID().uuidString)")
        let secrets = InMemorySecretStore()
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            loginSetStore: LoginSetStore(directory: dir))
        return (vm, secrets, dir)
    }

    /// A form with no connector: none of these tests connects, and a
    /// throwing stub is the smallest value satisfying the signature.
    private func makeForm() -> ConnectionViewModel {
        ConnectionViewModel(connector: { _, _ in throw CancellationError() })
    }

    /// A live set resolves silently and fills the credential fields.
    @Test func aLiveTargetSetResolvesAndFills() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Root", username: "root")
        vm.saveLoginSet(set, secret: "s3cr3t")

        let form = makeForm()
        form.loginMode = .set
        form.selectedLoginSetID = set.id

        #expect(vm.resolveTargetLoginSet(form: form) == nil)
        // Assert the username arrived, NOT the secret's text.
        #expect(form.values[SSHField.username] == "root")
    }

    /// The set was deleted while the form stayed open.
    @Test func aDanglingTargetSetIsRefused() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let form = makeForm()
        form.loginMode = .set
        form.selectedLoginSetID = UUID()

        #expect(vm.resolveTargetLoginSet(form: form) == .targetSetMissing)
    }

    /// NEW in P2: a set belonging to another protocol is refused rather than
    /// written into fields the form never reads. That was harmless only
    /// because `applyResolvedCredentials` namespaces values per backend — a
    /// coincidence, not a rule.
    @Test func aTargetSetOfAnotherKindIsRefused() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let share = LoginSet(name: "Share", username: "dav", kind: .webdav)
        vm.saveLoginSet(share, secret: "share-secret")

        let form = makeForm()
        form.kind = .ssh
        form.loginMode = .set
        form.selectedLoginSetID = share.id

        #expect(vm.resolveTargetLoginSet(form: form) == .targetSetKindMismatch)
    }

    /// Manual mode and "nothing selected yet" are both no-ops — the submit
    /// buttons are already disabled for the latter, so this is the
    /// belt-and-suspenders half rather than the only guard.
    @Test func manualModeAndNoSelectionResolveSilently() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manual = makeForm()
        manual.loginMode = .manual
        #expect(vm.resolveTargetLoginSet(form: manual) == nil)

        let unselected = makeForm()
        unselected.loginMode = .set
        unselected.selectedLoginSetID = nil
        #expect(vm.resolveTargetLoginSet(form: unselected) == nil)
    }

    // MARK: - The jump's login set

    /// M28's Critical, now assertable. A jump bound to a WebDAV set must be
    /// refused — AND the set's secret must never reach the form. The second
    /// assertion is the one that matters: it pins the ORDER of the guard and
    /// the fill. Swap those two lines and this goes red with the credential
    /// sitting in the form, not merely with a differing flag.
    @Test func aJumpBoundToANonSSHSetIsRefusedBeforeItsSecretIsRead() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let share = LoginSet(name: "Share", username: "dav", kind: .webdav)
        // The slot the fill would read: `password(for:)` addresses the
        // Keychain by id alone, and `saveLoginSet` writes the set's own id.
        vm.saveLoginSet(share, secret: "share-secret")

        let form = makeForm()
        form.jumpEnabled = true
        form.jumpLoginMode = .set
        form.jumpSelectedLoginSetID = share.id

        #expect(vm.resolveJumpLoginSet(form: form) == .jumpSetNotSSH)
        // Hoisted into a Bool so no secret can reach a failure message: a
        // bare `#expect(form.jumpPassword.isEmpty)` expands the receiver, and
        // the one run where this goes red is exactly the run where that
        // receiver HOLDS the share's password. The Bool still says what
        // matters — the field was written or it was not.
        let jumpPasswordFieldIsEmpty = form.jumpPassword.isEmpty
        #expect(jumpPasswordFieldIsEmpty)
    }

    /// The refusal must not depend on the set holding a secret at all: an
    /// empty slot would make the assertion above pass for the wrong reason.
    @Test func theRefusalDoesNotDependOnTheSetHoldingASecret() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bucket = LoginSet(
            name: "Bucket", username: "", kind: .s3, accessKeyID: "AKIA")
        vm.saveLoginSet(bucket, secret: nil)
        #expect(secrets.storedIDs.contains(bucket.id) == false)

        let form = makeForm()
        form.jumpEnabled = true
        form.jumpLoginMode = .set
        form.jumpSelectedLoginSetID = bucket.id

        #expect(vm.resolveJumpLoginSet(form: form) == .jumpSetNotSSH)
        let jumpPasswordFieldIsEmpty = form.jumpPassword.isEmpty
        #expect(jumpPasswordFieldIsEmpty)
    }

    /// The happy path: an SSH set fills the jump's four manual-looking fields
    /// and resolves silently.
    @Test func aLiveJumpSetFillsAndResolves() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(
            name: "Bastion", username: "root", authKind: .privateKey,
            keyPath: "/keys/id_ed25519")
        vm.saveLoginSet(set, secret: "passphrase")

        let form = makeForm()
        form.jumpEnabled = true
        form.jumpLoginMode = .set
        form.jumpSelectedLoginSetID = set.id

        #expect(vm.resolveJumpLoginSet(form: form) == nil)
        #expect(form.jumpUsername == "root")
        #expect(form.jumpAuthChoice == .privateKey)
        #expect(form.jumpKeyPath == "/keys/id_ed25519")
        // That the secret arrived, never what it says — hoisted for the same
        // reason as in the ordering test above.
        let jumpPasswordFieldIsEmpty = form.jumpPassword.isEmpty
        #expect(jumpPasswordFieldIsEmpty == false)
    }

    /// The set was deleted while the form stayed open.
    @Test func aDanglingJumpSetIsRefused() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let form = makeForm()
        form.jumpEnabled = true
        form.jumpLoginMode = .set
        form.jumpSelectedLoginSetID = UUID()

        #expect(vm.resolveJumpLoginSet(form: form) == .jumpSetMissing)
    }

    /// An agent set has no Keychain slot, so the fill must not reach for one.
    /// Proven by planting a secret under the set's id anyway: an unconditional
    /// read would put it in the form.
    @Test func anAgentJumpSetFillsWithoutAKeychainRead() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "Agent", username: "root", authKind: .agent)
        vm.saveLoginSet(set, secret: nil)
        // Past `saveLoginSet`, which clears an agent set's slot on purpose.
        try secrets.savePassword("planted", for: set.id)

        let form = makeForm()
        form.jumpEnabled = true
        form.jumpLoginMode = .set
        form.jumpSelectedLoginSetID = set.id

        #expect(vm.resolveJumpLoginSet(form: form) == nil)
        #expect(form.jumpUsername == "root")
        #expect(form.jumpAuthChoice == .agent)
        #expect(form.jumpKeyPath.isEmpty)
        let jumpPasswordFieldIsEmpty = form.jumpPassword.isEmpty
        #expect(jumpPasswordFieldIsEmpty)
    }

    /// The three no-ops of the set half: the jump is off, the jump's SOURCE is
    /// a saved connection (which has its own resolution), or the jump's login
    /// is manual. A leftover dangling selection must not refuse a submit in
    /// any of them.
    @Test func theJumpSetHalfIsANoOpOffInSessionModeAndInManualMode() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }

        let off = makeForm()
        off.jumpEnabled = false
        off.jumpLoginMode = .set
        off.jumpSelectedLoginSetID = UUID()
        #expect(vm.resolveJumpLoginSet(form: off) == nil)

        let sessionSourced = makeForm()
        sessionSourced.jumpEnabled = true
        sessionSourced.jumpSourceMode = .session
        sessionSourced.jumpLoginMode = .set
        sessionSourced.jumpSelectedLoginSetID = UUID()
        #expect(vm.resolveJumpLoginSet(form: sessionSourced) == nil)

        let manual = makeForm()
        manual.jumpEnabled = true
        manual.jumpLoginMode = .manual
        #expect(vm.resolveJumpLoginSet(form: manual) == nil)

        let unselected = makeForm()
        unselected.jumpEnabled = true
        unselected.jumpLoginMode = .set
        unselected.jumpSelectedLoginSetID = nil
        #expect(vm.resolveJumpLoginSet(form: unselected) == nil)
    }

    // MARK: - The jump's referenced session

    /// WebDAV form values, for the one session-mode test that needs a
    /// non-SSH connection to point at.
    private func webdavValues(baseURL: String, username: String) -> FieldValues {
        var values = BackendDescriptor.descriptor(for: .webdav).defaultValues
        values[WebDAVField.baseURL] = baseURL
        values[WebDAVField.username] = username
        return values
    }

    /// The happy path: host, port and login all come from the referenced
    /// connection.
    @Test func aLiveJumpSessionFillsHostPortAndLogin() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bastion = vm.save(
            name: "bastion",
            values: sshValues(host: "b.example.com", port: 2222, username: "root"),
            password: "bp")!

        let form = makeForm()
        form.jumpEnabled = true
        form.jumpSourceMode = .session
        form.jumpSessionID = bastion.id

        #expect(vm.resolveJumpSession(form: form) == nil)
        #expect(form.jumpHost == "b.example.com")
        #expect(form.jumpPort == "2222")
        #expect(form.jumpUsername == "root")
        #expect(form.jumpAuthChoice == .password)
    }

    /// The referenced connection was deleted while the form stayed open.
    @Test func aDanglingJumpSessionIsRefused() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let form = makeForm()
        form.jumpEnabled = true
        form.jumpSourceMode = .session
        form.jumpSessionID = UUID()

        #expect(vm.resolveJumpSession(form: form) == .jumpSessionMissing)
    }

    /// One hop only: a connection that itself tunnels cannot be a jump host.
    @Test func aJumpSessionThatItselfHasAJumpIsRefused() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chained = vm.save(
            name: "chained",
            values: sshValues(host: "c.example.com", username: "root"),
            password: "cp",
            jump: StoredSession.JumpSpec(host: "inner.example.com", username: "root"))!

        let form = makeForm()
        form.jumpEnabled = true
        form.jumpSourceMode = .session
        form.jumpSessionID = chained.id

        #expect(vm.resolveJumpSession(form: form) == .jumpChainNotSupported)
    }

    /// A share is not a bastion.
    @Test func aNonSSHJumpSessionIsRefused() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let share = vm.save(
            name: "cloud",
            values: webdavValues(
                baseURL: "https://cloud.example.com/remote.php/dav", username: "dav"),
            password: "pw", kind: .webdav)!

        let form = makeForm()
        form.jumpEnabled = true
        form.jumpSourceMode = .session
        form.jumpSessionID = share.id

        #expect(vm.resolveJumpSession(form: form) == .jumpSessionNotSSH)
    }

    /// The referenced connection exists and is SSH, but its OWN login set is
    /// gone — the resolver's `.missingSet`, which the catch-all classifies.
    @Test func aJumpSessionWithADanglingLoginSetIsRefused() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bastion = vm.save(
            name: "bastion",
            values: sshValues(host: "b.example.com", username: "root"),
            password: "bp", loginSetID: UUID())!

        let form = makeForm()
        form.jumpEnabled = true
        form.jumpSourceMode = .session
        form.jumpSessionID = bastion.id

        #expect(vm.resolveJumpSession(form: form) == .jumpSessionLoginUnresolvable)
    }

    /// The two no-ops of the session half: the jump is off, or its source is
    /// the manual block (which the set half resolves instead).
    @Test func theJumpSessionHalfIsANoOpOffAndInManualSourceMode() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }

        let off = makeForm()
        off.jumpEnabled = false
        off.jumpSourceMode = .session
        off.jumpSessionID = UUID()
        #expect(vm.resolveJumpSession(form: off) == nil)

        let manualSource = makeForm()
        manualSource.jumpEnabled = true
        manualSource.jumpSourceMode = .manual
        manualSource.jumpSessionID = UUID()
        #expect(vm.resolveJumpSession(form: manualSource) == nil)

        let unselected = makeForm()
        unselected.jumpEnabled = true
        unselected.jumpSourceMode = .session
        unselected.jumpSessionID = nil
        #expect(vm.resolveJumpSession(form: unselected) == nil)
    }

    /// The field mapping is part of the contract: a refusal that highlighted
    /// the wrong control would be a silent regression the user sees but no
    /// test does.
    @Test func eachRefusalNamesItsField() {
        #expect(SubmitRefusal.targetSetMissing.field == nil)
        #expect(SubmitRefusal.targetSetKindMismatch.field == nil)
        #expect(SubmitRefusal.jumpSetMissing.field == .jumpHost)
        #expect(SubmitRefusal.jumpSetNotSSH.field == .jumpHost)
        #expect(SubmitRefusal.jumpSessionMissing.field == .jumpSession)
        #expect(SubmitRefusal.jumpChainNotSupported.field == .jumpSession)
        #expect(SubmitRefusal.jumpSessionNotSSH.field == .jumpSession)
        #expect(SubmitRefusal.jumpSessionLoginUnresolvable.field == .jumpSession)
    }
}
