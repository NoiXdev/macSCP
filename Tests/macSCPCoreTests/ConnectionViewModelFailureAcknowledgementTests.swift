import Foundation
import MacSCPTestSupport
import Testing
@testable import macSCPCore

/// `ConnectionViewModel.unacknowledgedFailure` (jump-and-groups plan, Task
/// 1, fix round 1): the marker that a failure a person must read has been
/// written and not yet dismissed.
///
/// Why it exists: the form shows a failure's text only in an alert, and an
/// alert raised by a state CHANGE is never raised for a form that mounts
/// into a state that is already `.failed`. The App's paths to the form do
/// exactly that — a refusal before the dial replaces the session overview,
/// a missing passphrase replaces "Connecting…". The marker outlives the
/// mount, so the form can raise the alert when it appears, once, until the
/// person dismisses it.
///
/// Driven through the real `connect()` and `showFailure`, as the
/// `lastFailureKind` tests in `ConnectionViewModelTests` are: what matters
/// is that the marker reaches the property on the path the App reads.
@Suite("Connection failure acknowledgement", .timeLimit(.minutes(1)))
@MainActor
struct ConnectionViewModelFailureAcknowledgementTests {
    private func makeVM(
        connector: @escaping ConnectionViewModel.Connector = { _, _ in
            MockRemoteFileSystem(tree: ["/": []])
        }
    ) -> ConnectionViewModel {
        let vm = ConnectionViewModel(connector: connector)
        vm.host = "example.com"
        vm.port = "22"
        vm.username = "tim"
        vm.password = "geheim"
        return vm
    }

    private func isFailed(_ vm: ConnectionViewModel) -> Bool {
        if case .failed = vm.state { return true }
        return false
    }

    // MARK: - Set for every failure a person must read

    @Test(arguments: [
        HostKeyError.mismatch(host: "example.com", expected: "SHA256:a", presented: "SHA256:b"),
        HostKeyError.rejectedByUser,
    ])
    func aHostKeyFailureIsMarkedUnacknowledged(error: HostKeyError) async {
        let vm = makeVM(connector: { _, _ in throw error })
        _ = await vm.connect()
        #expect(isFailed(vm))
        #expect(vm.unacknowledgedFailure != nil)
    }

    @Test(arguments: [
        ServerCertificateError.mismatch(host: "example.com", expected: "a", presented: "b"),
        ServerCertificateError.rejectedByUser,
        ServerCertificateError.trustStoreUnreadable(reason: "unreadable"),
    ])
    func aCertificateFailureIsMarkedUnacknowledged(error: ServerCertificateError) async {
        let vm = makeVM(connector: { _, _ in throw error })
        _ = await vm.connect()
        #expect(vm.unacknowledgedFailure != nil)
    }

    @Test(arguments: [SSHKeyError.passphraseRequired, .wrongPassphrase])
    func aKeyPassphraseFailureIsMarkedUnacknowledged(error: SSHKeyError) async {
        let vm = makeVM(connector: { _, _ in throw error })
        _ = await vm.connect()
        #expect(vm.unacknowledgedFailure != nil)
    }

    /// The pre-dial refusals, each by its own route: form validation, a
    /// schema violation on a required secret, the save-name rule, and the
    /// App's own refusal through `showFailure` (a login set or jump session
    /// that no longer resolves, a `fillForm` throw).
    @Test func aValidationRefusalIsMarkedUnacknowledged() async {
        let vm = makeVM()
        vm.host = ""
        _ = await vm.connect()
        #expect(isFailed(vm))
        #expect(vm.unacknowledgedFailure != nil)
    }

    @Test func aMissingRequiredSecretIsMarkedUnacknowledged() async {
        let vm = makeVM()
        vm.password = ""
        _ = await vm.connect()
        #expect(vm.unacknowledgedFailure != nil)
    }

    @Test func anEmptySaveNameIsMarkedUnacknowledged() async {
        let vm = makeVM()
        vm.shouldSaveSession = true
        vm.saveName = "   "
        _ = await vm.connect()
        #expect(vm.unacknowledgedFailure != nil)
    }

    @Test func anAppRefusalIsMarkedUnacknowledged() {
        let vm = makeVM()
        vm.showFailure(message: "refused")
        #expect(vm.unacknowledgedFailure != nil)
    }

    // MARK: - Not set for a failure with a surface of its own

    /// A dial that failed on the wire is described by the failed-connect
    /// surface, not by the form; the marker would make the form raise that
    /// text again after the person left the surface through "Edit".
    @Test func aWireFailureIsNotMarked() async {
        let vm = makeVM(connector: { _, _ in throw RemoteFSError.connectionFailed(reason: "unreachable") })
        _ = await vm.connect()
        #expect(isFailed(vm), "the positive half: the attempt did fail")
        #expect(vm.lastFailureKind == .other)
        #expect(vm.unacknowledgedFailure == nil)
    }

    @Test func aWireFailureReplacesAnEarlierUnreadMarker() async {
        let vm = makeVM(connector: { _, _ in throw RemoteFSError.connectionFailed(reason: "unreachable") })
        vm.showFailure(message: "refused")
        #expect(vm.unacknowledgedFailure != nil)
        _ = await vm.connect()
        #expect(vm.unacknowledgedFailure == nil)
    }

    // MARK: - Cleared by the person, the next attempt or an edit

    @Test func acknowledgingTheFailureClearsTheMarker() throws {
        let vm = makeVM()
        vm.showFailure(message: "refused")
        let id = try #require(vm.unacknowledgedFailure)
        vm.acknowledgeFailure(id)
        #expect(vm.unacknowledgedFailure == nil)
        #expect(isFailed(vm), "acknowledging reads the text; it does not undo the failure")
    }

    /// An alert still on screen for an earlier failure must not acknowledge
    /// a newer one it never showed.
    @Test func acknowledgingAnEarlierFailureLeavesANewerOneUnread() throws {
        let vm = makeVM()
        vm.showFailure(message: "first")
        let first = try #require(vm.unacknowledgedFailure)
        vm.showFailure(message: "second")
        let second = try #require(vm.unacknowledgedFailure)
        #expect(first != second, "each failure carries its own marker")
        vm.acknowledgeFailure(first)
        #expect(vm.unacknowledgedFailure == second)
    }

    @Test func theNextAttemptClearsTheMarker() async {
        let vm = makeVM()
        vm.showFailure(message: "refused")
        #expect(vm.unacknowledgedFailure != nil)
        let fs = await vm.connect()
        #expect(fs != nil)
        #expect(vm.unacknowledgedFailure == nil)
    }

    @Test func beginningAnEditClearsTheMarker() {
        let vm = makeVM()
        vm.showFailure(message: "refused")
        #expect(vm.unacknowledgedFailure != nil)
        vm.beginEditing(StoredSession(
            name: "edited", kind: .ssh, ssh: StoredSSHConfig(host: "example.com", username: "tim")))
        #expect(vm.unacknowledgedFailure == nil)
    }
}
