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
