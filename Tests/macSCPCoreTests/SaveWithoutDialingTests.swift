import Foundation
import Testing
@testable import macSCPCore

/// `ConnectionViewModel.validateForNewSave()` — the rules a NEW session has
/// to pass to be written, asked WITHOUT opening a connection.
///
/// Before this existed, `connect()` was the only caller that ran them, so
/// "remember this connection" and "open this connection" were one act: a
/// user with a session already running could not have it saved without
/// dialing the same server a second time. These tests pin that the rules
/// did not soften on the way out of the dial — the save name, the backend
/// schema, and the jump block are the same three gates `connect()` applies.
@Suite("Save without dialing")
@MainActor
struct SaveWithoutDialingTests {
    private func makeVM() -> ConnectionViewModel {
        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem(tree: ["/": []]) })
        vm.host = "example.com"
        vm.port = "22"
        vm.username = "tim"
        vm.password = "geheim"
        vm.shouldSaveSession = true
        vm.saveName = "hetzner-web"
        return vm
    }

    @Test func acompleteFormValidatesWithoutDialing() {
        let vm = makeVM()
        #expect(vm.validateForNewSave())
        #expect(vm.state == .idle)
    }

    /// The dial is what used to run these rules; nothing about the form may
    /// suggest one happened.
    @Test func validatingNeverEntersTheConnectingState() {
        let vm = makeVM()
        _ = vm.validateForNewSave()
        #expect(vm.state != .connecting)
        #expect(vm.lastConnectedConfig == nil)
    }

    @Test func anEmptySaveNameIsRefusedAndHighlightsThatField() {
        let vm = makeVM()
        vm.saveName = "   "
        #expect(!vm.validateForNewSave())
        guard case .failed(_, let field) = vm.state else {
            Issue.record("expected a .failed state")
            return
        }
        #expect(field == .saveName)
    }

    /// The schema half, borrowed whole from `resolveConfigWithoutDialing()`:
    /// a form the dial would have rejected cannot be saved either.
    @Test func aFormTheDialWouldRefuseIsRefusedHere() {
        let vm = makeVM()
        vm.host = ""
        #expect(!vm.validateForNewSave())
        guard case .failed(_, let field) = vm.state else {
            Issue.record("expected a .failed state")
            return
        }
        guard case .schema = field else {
            Issue.record("expected a schema field to be highlighted, got \(String(describing: field))")
            return
        }
    }

    /// The jump block is validated too — a bastion half-filled in is a
    /// refusal, not a session quietly saved as a direct one.
    @Test func anIncompleteJumpBlockIsRefused() {
        let vm = makeVM()
        vm.jumpEnabled = true
        vm.jumpHost = ""
        #expect(!vm.validateForNewSave())
        guard case .failed(_, let field) = vm.state else {
            Issue.record("expected a .failed state")
            return
        }
        #expect(field == .jumpHost)
    }

    /// A complete jump block passes — otherwise the test above would be
    /// green for the wrong reason (any jump refused, rather than an
    /// incomplete one).
    @Test func aCompleteJumpBlockValidates() {
        let vm = makeVM()
        vm.jumpEnabled = true
        vm.jumpHost = "bastion.example.com"
        vm.jumpPort = "22"
        vm.jumpUsername = "tim"
        vm.jumpPassword = "geheim"
        #expect(vm.validateForNewSave())
    }

    /// Edit mode has its own validator with a different secret rule (empty
    /// means "leave the stored one alone"), so this one refuses rather than
    /// silently applying the wrong rules to an edited session.
    @Test func editModeIsRefusedRatherThanValidatedByTheWrongRules() {
        let vm = makeVM()
        vm.beginEditing(StoredSession(name: "existing", kind: .ssh))
        #expect(!vm.validateForNewSave())
    }
}
