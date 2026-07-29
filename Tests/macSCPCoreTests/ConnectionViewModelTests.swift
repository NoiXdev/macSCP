import Foundation
import Testing
@testable import macSCPCore

@Suite("ConnectionViewModel")
@MainActor
struct ConnectionViewModelTests {
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

    @Test func successReturnsFileSystemAndResetsState() async {
        let vm = makeVM()
        let fs = await vm.connect()
        #expect(fs != nil)
        #expect(vm.state == .idle)
    }

    @Test func nonNumericPortFlagsPortField() async {
        let vm = makeVM()
        vm.port = "abc"
        let fs = await vm.connect()
        #expect(fs == nil)
        #expect(vm.state == .failed(message: CoreL10n.string("core.connect.portNumeric"), field: .port))
    }

    @Test func emptyHostFlagsHostField() async {
        let vm = makeVM()
        vm.host = ""
        _ = await vm.connect()
        #expect(vm.state == .failed(message: CoreL10n.string("core.connect.emptyHost"), field: .host))
    }

    @Test func emptyPasswordFlagsPasswordFieldBeforeConnecting() async {
        let vm = makeVM(connector: { _, _ in
            Issue.record("Connector must not be called with an empty password")
            throw RemoteFSError.connectionFailed(reason: "unreachable")
        })
        vm.password = ""
        _ = await vm.connect()
        #expect(vm.state == .failed(message: CoreL10n.string("core.connect.passwordEmpty"), field: .password))
    }

    @Test func authFailureHasNoField() async {
        let vm = makeVM(connector: { _, _ in throw RemoteFSError.authenticationFailed })
        let fs = await vm.connect()
        #expect(fs == nil)
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.authFailed"),
            field: nil))
    }

    @Test func connectionFailureHasNoField() async {
        let vm = makeVM(connector: { _, _ in
            throw RemoteFSError.connectionFailed(reason: "timeout")
        })
        _ = await vm.connect()
        #expect(vm.state == .failed(
            message: String(format: CoreL10n.string("core.connect.connectionFailed %@"), "timeout"),
            field: nil))
    }

    @Test func trimsPaddedHostAndUsernameForConnection() async {
        let vm = makeVM(connector: { config, _ in
            #expect(config.host == "example.com")
            #expect(config.username == "tim")
            return MockRemoteFileSystem(tree: ["/": []])
        })
        vm.host = "  example.com "
        vm.username = " tim\t"
        let fs = await vm.connect()
        #expect(fs != nil)
    }

    @Test func saveRequestedWithEmptyNameFlagsSaveNameField() async {
        let vm = makeVM(connector: { _, _ in
            Issue.record("Connector must not run without a session name")
            throw RemoteFSError.connectionFailed(reason: "unreachable")
        })
        vm.shouldSaveSession = true
        vm.saveName = "   "
        let fs = await vm.connect()
        #expect(fs == nil)
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.saveNameEmpty"), field: .saveName))
    }

    @Test func saveNameNotValidatedWhenToggleOff() async {
        let vm = makeVM()
        vm.shouldSaveSession = false
        vm.saveName = ""
        let fs = await vm.connect()
        #expect(fs != nil)
    }

    @Test func keyAuthRequiresKeyPath() async {
        let vm = makeVM(connector: { _, _ in
            Issue.record("Connector must not run without a key path")
            throw RemoteFSError.connectionFailed(reason: "unreachable")
        })
        vm.authChoice = .privateKey
        vm.keyPath = "  "
        _ = await vm.connect()
        #expect(vm.state == .failed(message: CoreL10n.string("core.connect.keyPathEmpty"), field: .keyPath))
    }

    @Test func keyAuthAllowsEmptyPassphraseAndBuildsPrivateKeyAuth() async {
        let vm = makeVM(connector: { config, _ in
            #expect(config.auth == .privateKey(keyPath: "~/.ssh/id_ed25519", passphrase: nil))
            return MockRemoteFileSystem(tree: ["/": []])
        })
        vm.authChoice = .privateKey
        vm.keyPath = " ~/.ssh/id_ed25519 "
        vm.password = ""
        let fs = await vm.connect()
        #expect(fs != nil)
    }

    @Test func keyErrorsMapToLocalizedMessages() async {
        let vm = makeVM(connector: { _, _ in throw SSHKeyError.passphraseRequired })
        vm.authChoice = .privateKey
        vm.keyPath = "~/.ssh/id_ed25519"
        _ = await vm.connect()
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.keyPassphraseRequired"),
            field: .password))
    }

    @Test func userSwitchClearsSecretButProgrammaticSetDoesNot() async {
        let vm = makeVM()
        vm.password = "geheim"
        vm.selectAuthChoice(.privateKey)
        #expect(vm.password.isEmpty)

        vm.password = "aus-dem-schluesselbund"
        vm.authChoice = .password   // programmatic (connectStored path)
        #expect(vm.password == "aus-dem-schluesselbund")
    }

    @Test func secondConnectWhileConnectingIsRejected() async {
        let counter = CallCounter()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let vm = makeVM(connector: { _, _ in
            await counter.increment()
            for await _ in stream {}   // hangs until the test ends the stream
            return MockRemoteFileSystem(tree: ["/": []])
        })

        async let first = vm.connect()
        try? await Task.sleep(for: .milliseconds(80))

        let second = await vm.connect()
        #expect(second == nil)

        continuation.finish()
        let firstResult = await first
        #expect(firstResult != nil)
        #expect(await counter.value == 1)
    }

    @Test func unknownHostPublishesPromptAndTrustConnects() async {
        let candidate = HostKeyCandidate(
            host: "example.com", port: 22, keyType: "ssh-ed25519",
            publicKeyBase64: "AAAAC3NzaC1lZDI1NTE5AAAAIAtest")
        let vm = makeVM(connector: { _, decider in
            let trusted = await decider(candidate)
            guard trusted else { throw HostKeyError.rejectedByUser }
            return MockRemoteFileSystem(tree: ["/": []])
        })

        async let result = vm.connect()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(vm.hostKeyPrompt?.candidate == candidate)

        vm.resolveHostKeyPrompt(trust: true)
        let fs = await result

        #expect(fs != nil)
        #expect(vm.hostKeyPrompt == nil)
    }

    @Test func rejectMapsToLocalizedMessage() async {
        let candidate = HostKeyCandidate(
            host: "example.com", port: 22, keyType: "ssh-ed25519",
            publicKeyBase64: "AAAAC3NzaC1lZDI1NTE5AAAAIAtest")
        let vm = makeVM(connector: { _, decider in
            let trusted = await decider(candidate)
            guard trusted else { throw HostKeyError.rejectedByUser }
            return MockRemoteFileSystem(tree: ["/": []])
        })

        async let result = vm.connect()
        try? await Task.sleep(for: .milliseconds(80))
        vm.resolveHostKeyPrompt(trust: false)
        let fs = await result

        #expect(fs == nil)
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.hostkey.rejected"), field: nil))
        #expect(vm.hostKeyPrompt == nil)
    }

    @Test @MainActor
    func cancelWhileHostKeyPromptPendingResolvesConnect() async throws {
        let candidate = HostKeyCandidate(
            host: "example.com", port: 22, keyType: "ssh-ed25519",
            publicKeyBase64: "AAAAC3NzaC1lZDI1NTE5AAAAIAtest")
        let vm = makeVM(connector: { _, decider in
            let trusted = await decider(candidate)
            guard trusted else { throw HostKeyError.rejectedByUser }
            return MockRemoteFileSystem(tree: ["/": []])
        })

        let connectTask = Task { await vm.connect() }
        // Wait until the prompt is up.
        for _ in 0..<200 where vm.hostKeyPrompt == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(vm.hostKeyPrompt != nil)

        connectTask.cancel()

        // Without a cancellation handler, connect() would hang forever. A
        // withTaskGroup race would implicitly wait for the hanging child task
        // when leaving the closure despite cancelAll() (Swift always waits
        // for all child tasks) and would itself block forever — hence two
        // unstructured tasks here that race for the continuation via an
        // actor claim; a hanging losing task therefore doesn't block the
        // return value.
        let claim = RaceClaim()
        let finished: Bool = await withCheckedContinuation { continuation in
            Task {
                _ = await connectTask.value
                if await claim.tryClaim() { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(for: .seconds(3))
                if await claim.tryClaim() { continuation.resume(returning: false) }
            }
        }
        #expect(finished, "connect() must return after cancel (continuation resolved)")
    }

    /// Regression (Final-Review M4, Minor 2): the connector may call the
    /// `onUnknownHostKey` decider only AFTER the connect() task's cancel
    /// (forced here via a stream that's only released after the cancel).
    /// `presentHostKeyPrompt` then enters `withCheckedContinuation` with
    /// cancellation already set. The test pins the OVERALL BEHAVIOR: a cancel
    /// before the prompt must not hang and must end in the error state. WHICH
    /// branch resolves the continuation (the `Task.isCancelled` fast path in
    /// the operation, or the `onCancel` handler, whose downstream MainActor
    /// task can also resolve the by-then-set continuation) is not
    /// distinguishable from the outside — both converge on the same state. A
    /// review experiment (fast path removed) stayed green via onCancel; the
    /// fast path remains as a belt-and-suspenders safeguard in the code.
    @Test @MainActor
    func cancelBeforeHostKeyPromptDeciderIsCalledDoesNotHang() async throws {
        let candidate = HostKeyCandidate(
            host: "example.com", port: 22, keyType: "ssh-ed25519",
            publicKeyBase64: "AAAAC3NzaC1lZDI1NTE5AAAAIAtest")
        let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
        let vm = makeVM(connector: { _, decider in
            for await _ in releaseStream {}   // hangs until the test releases it
            let trusted = await decider(candidate)
            guard trusted else { throw HostKeyError.rejectedByUser }
            return MockRemoteFileSystem(tree: ["/": []])
        })

        let connectTask = Task { await vm.connect() }
        // Cancel BEFORE the release: presentHostKeyPrompt (and thus
        // withTaskCancellationHandler) only runs after this point.
        connectTask.cancel()
        releaseContinuation.finish()

        // Timeout-race pattern from this file (see cancelWhileHostKeyPromptPendingResolvesConnect):
        // without cancellation handling (fast path AND onCancel), connect() would hang forever.
        let claim = RaceClaim()
        let finished: Bool = await withCheckedContinuation { continuation in
            Task {
                _ = await connectTask.value
                if await claim.tryClaim() { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(for: .seconds(3))
                if await claim.tryClaim() { continuation.resume(returning: false) }
            }
        }
        #expect(finished, "connect() must return when cancel is already set before the prompt")
        #expect(vm.hostKeyPrompt == nil)
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.hostkey.rejected"), field: nil))
    }

    @Test @MainActor func beginEditingPrefillsEverythingExceptTheSecret() {
        let vm = makeVM()
        let stored = StoredSession(name: "web", host: "h", port: 2222, username: "u",
                                   authKind: .privateKey, keyPath: "/k", groupID: UUID())
        vm.password = "leftover"
        vm.beginEditing(stored)

        #expect(vm.mode == .edit(sessionID: stored.id))
        #expect(vm.host == "h" && vm.port == "2222" && vm.username == "u")
        #expect(vm.saveName == "web" && vm.keyPath == "/k")
        #expect(vm.authChoice == .privateKey)
        #expect(vm.selectedGroupID == stored.groupID)
        #expect(vm.password.isEmpty) // never loaded from the keychain
    }

    @Test @MainActor func exitEditModeResetsModeAndGroupButKeepsFields() {
        let vm = makeVM()
        vm.beginEditing(StoredSession(name: "web", host: "h", username: "u", groupID: UUID()))
        vm.exitEditMode()

        #expect(vm.mode == .new)
        #expect(vm.selectedGroupID == nil)
        // Field values are owned by the teardown/connectStored callers,
        // which overwrite them right after — exitEditMode must not clear them.
        #expect(vm.host == "h" && vm.saveName == "web")
    }

    @Test @MainActor func validateForEditSaveAllowsEmptyPasswordAndBuildsTheSession() {
        let vm = makeVM()
        let stored = StoredSession(name: "web", host: "h", username: "u")
        vm.beginEditing(stored)
        vm.host = "new.example"

        let result = vm.validateForEditSave()
        #expect(result?.id == stored.id)
        #expect(result?.host == "new.example")
        #expect(vm.state == .idle)
    }

    @Test @MainActor func validateForEditSaveRejectsInvalidPort() {
        let vm = makeVM()
        vm.beginEditing(StoredSession(name: "web", host: "h", username: "u"))
        vm.port = "abc"
        #expect(vm.validateForEditSave() == nil)
        #expect(vm.state == .failed(message: CoreL10n.string("core.connect.portNumeric"), field: .port))
    }

    @Test @MainActor func endEditingReturnsToNewMode() {
        let vm = makeVM()
        vm.beginEditing(StoredSession(name: "web", host: "h", username: "u"))
        vm.endEditing()
        #expect(vm.mode == .new)
        #expect(vm.host.isEmpty && vm.saveName.isEmpty)
    }

    /// `endEditing` must fully blank the form AND leave edit mode (via
    /// `exitEditMode`) — unlike `exitEditMode()` alone, which deliberately
    /// keeps the field values for its own callers.
    @Test @MainActor func endEditingResetsEverything() {
        let vm = makeVM()
        vm.beginEditing(StoredSession(
            name: "web", host: "h", port: 2222, username: "u",
            authKind: .privateKey, keyPath: "/k", groupID: UUID()))
        vm.shouldSaveSession = true

        vm.endEditing()

        #expect(vm.mode == .new)
        #expect(vm.selectedGroupID == nil)
        #expect(vm.host.isEmpty)
        #expect(vm.port == "22")
        #expect(vm.username.isEmpty)
        #expect(vm.password.isEmpty)
        #expect(vm.authChoice == .password)
        #expect(vm.keyPath.isEmpty)
        #expect(vm.shouldSaveSession == false)
        #expect(vm.saveName.isEmpty)
        #expect(vm.state == .idle)
    }

    @Test func mismatchMapsToScaryMessage() async {
        let vm = makeVM(connector: { _, _ in
            throw HostKeyError.mismatch(
                host: "example.com",
                expected: "SHA256:AAAA",
                presented: "SHA256:BBBB")
        })

        let fs = await vm.connect()

        #expect(fs == nil)
        #expect(vm.state == .failed(
            message: String(
                format: CoreL10n.string("core.hostkey.mismatch %@ %@ %@"),
                "example.com", "SHA256:AAAA", "SHA256:BBBB"),
            field: nil))
        #expect(vm.hostKeyPrompt == nil)
    }

    // MARK: - Jump host (M10c/T3)

    @Test func jumpValidationRequiresHost() async {
        let vm = makeVM()
        vm.jumpEnabled = true
        vm.jumpHost = ""
        vm.jumpUsername = "bastion-user"
        vm.jumpPassword = "bastion-pass"
        let fs = await vm.connect()
        #expect(fs == nil)
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.jumpHostEmpty"), field: .jumpHost))
    }

    @Test @MainActor func jumpSetModeRequiresSelection() {
        let vm = makeVM()
        vm.beginEditing(StoredSession(name: "web", host: "h", username: "u"))
        vm.jumpEnabled = true
        vm.jumpHost = "bastion.example.com"
        vm.jumpLoginMode = .set
        vm.jumpSelectedLoginSetID = nil
        #expect(vm.validateForEditSave() == nil)
        // field: nil (final review M-3) -- no Field case exists for the
        // picker; `.jumpHost` would misleadingly outline the host field.
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.jumpSetRequired"), field: nil))
    }

    /// Final review I-1 (BLOCKER): edit mode deliberately leaves
    /// `jumpPassword` empty ("unchanged", see `beginEditing`'s doc comment).
    /// Before the fix, `validateForEditSave()` reused `connect()`'s
    /// `validateJump()` unconditionally, which hard-required a non-empty
    /// `jumpPassword` in manual/password mode — making a session with a
    /// manual password jump impossible to save without retyping the jump
    /// secret. This proves the save now succeeds and reuses the SAME
    /// `secretID`, not a freshly generated one.
    @Test @MainActor func editSaveKeepsJumpSecretIDWithEmptyPassword() {
        let vm = makeVM()
        let originalSecretID = UUID()
        let jump = StoredSession.JumpSpec(
            host: "bastion.example.com", port: 22, username: "bastion-user",
            authKind: .password, secretID: originalSecretID)
        vm.beginEditing(StoredSession(name: "web", host: "h", username: "u", jump: jump))
        #expect(vm.jumpEnabled) // sanity: beginEditing actually picked the jump up
        #expect(vm.jumpPassword.isEmpty) // sanity: "leave unchanged" starting point

        let saved = vm.validateForEditSave()

        #expect(saved != nil)
        #expect(saved?.jump?.secretID == originalSecretID)
        #expect(saved?.jump?.loginSetID == nil)
    }

    @Test @MainActor func jumpFieldsResetOnExitEditMode() {
        let vm = makeVM()
        let jump = StoredSession.JumpSpec(
            host: "bastion.example.com", port: 2200, username: "bastion-user",
            authKind: .privateKey, keyPath: "/k")
        vm.beginEditing(StoredSession(name: "web", host: "h", username: "u", jump: jump))
        #expect(vm.jumpEnabled) // sanity: beginEditing actually picked the jump up

        vm.exitEditMode()

        #expect(vm.jumpEnabled == false)
        #expect(vm.jumpHost.isEmpty)
        #expect(vm.jumpPort == "22")
        #expect(vm.jumpUsername.isEmpty)
        #expect(vm.jumpPassword.isEmpty)
        #expect(vm.jumpKeyPath.isEmpty)
        #expect(vm.jumpAuthChoice == .password)
        #expect(vm.jumpLoginMode == .manual)
        #expect(vm.jumpSelectedLoginSetID == nil)
    }

    /// Pins the public `clearJumpFields()` primitive directly (App-layer
    /// re-review F-1): `ContentView`'s `connect(in:stored:)` calls this on
    /// BOTH early-return failure paths (a dangling target login set, and a
    /// jump-only missing set with no jump on the session) so a jump block
    /// typed for a DIFFERENT session's form can never survive into the next
    /// one. `exitEditMode()` already exercises this transitively via
    /// `jumpFieldsResetOnExitEditMode` above; this test calls the method
    /// directly, independent of edit mode, to prove it resets every jump
    /// field on its own.
    @Test @MainActor func clearJumpFieldsResetsEverything() {
        let vm = makeVM()
        vm.jumpEnabled = true
        vm.jumpHost = "bastion.example.com"
        vm.jumpPort = "2200"
        vm.jumpUsername = "bastion-user"
        vm.jumpAuthChoice = .privateKey
        vm.jumpKeyPath = "/k"
        vm.jumpPassword = "secret"
        vm.jumpLoginMode = .set
        vm.jumpSelectedLoginSetID = UUID()

        vm.clearJumpFields()

        #expect(vm.jumpEnabled == false)
        #expect(vm.jumpHost.isEmpty)
        #expect(vm.jumpPort == "22")
        #expect(vm.jumpUsername.isEmpty)
        #expect(vm.jumpPassword.isEmpty)
        #expect(vm.jumpKeyPath.isEmpty)
        #expect(vm.jumpAuthChoice == .password)
        #expect(vm.jumpLoginMode == .manual)
        #expect(vm.jumpSelectedLoginSetID == nil)
    }

    // MARK: - Jump source: saved connection (M11a/T3)

    @Test func jumpSessionModeRequiresSelection() async {
        let vm = makeVM()
        vm.jumpEnabled = true
        vm.jumpSourceMode = .session
        vm.jumpSessionID = nil
        let fs = await vm.connect()
        #expect(fs == nil)
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.jumpSessionRequired"), field: .jumpSession))
    }

    /// Proves the manual checks (host/port/login) don't just happen to pass
    /// because the fields are filled — they never run at all in session
    /// mode. `jumpPassword` is left empty, which manual `.password` mode
    /// would reject outright (`core.connect.jumpPasswordEmpty`); `jumpHost`/
    /// `jumpUsername` are set non-empty only to satisfy `SSHConnectionConfig`
    /// init's OWN unconditional emptiness check further down the pipe (spec
    /// §4a: the App fills these from the resolved reference before
    /// `connect()`, this test stands in for that fill) — this test is about
    /// `validateJump` skipping its manual branch, not about that separate,
    /// lower-level check.
    @Test func jumpSessionModeSkipsManualChecks() async {
        let vm = makeVM()
        vm.jumpEnabled = true
        vm.jumpSourceMode = .session
        vm.jumpSessionID = UUID()
        vm.jumpHost = "bastion.example.com"
        vm.jumpUsername = "bastion-user"
        vm.jumpPassword = ""
        let fs = await vm.connect()
        #expect(fs != nil)
        #expect(vm.state == .idle)
    }

    @Test @MainActor func jumpSourceFieldsResetOnExitEditMode() {
        let vm = makeVM()
        let jump = StoredSession.JumpSpec(host: "", username: "", sessionID: UUID())
        vm.beginEditing(StoredSession(name: "web", host: "h", username: "u", jump: jump))
        // Sanity: beginEditing actually picked up the reference.
        #expect(vm.jumpSourceMode == .session)
        #expect(vm.jumpSessionID != nil)

        vm.exitEditMode()

        #expect(vm.jumpSourceMode == .manual)
        #expect(vm.jumpSessionID == nil)
    }

    // MARK: - Agent auth (M10d/T3)

    @Test func agentAuthSkipsPasswordAndKeyPathValidationAndBuildsAgentAuth() async {
        let vm = makeVM(connector: { config, _ in
            #expect(config.auth == .agent)
            return MockRemoteFileSystem(tree: ["/": []])
        })
        vm.authChoice = .agent
        vm.password = ""
        vm.keyPath = ""
        let fs = await vm.connect()
        #expect(fs != nil)
    }

    @Test @MainActor func validateForEditSaveMapsAgentAuthChoice() {
        let vm = makeVM()
        vm.beginEditing(StoredSession(name: "web", host: "h", username: "u"))
        vm.authChoice = .agent
        vm.password = ""
        vm.keyPath = ""

        let result = vm.validateForEditSave()

        #expect(result?.authKind == .agent)
        #expect(result?.keyPath == nil)
    }

    @Test @MainActor func beginEditingMapsAgentAuthKindToAgentChoice() {
        let vm = makeVM()
        let stored = StoredSession(name: "web", host: "h", username: "u", authKind: .agent)
        vm.beginEditing(stored)
        #expect(vm.authChoice == .agent)
    }

    @Test func jumpAgentModeRequiresNeitherSecretNorKeyPath() async {
        let vm = makeVM(connector: { config, _ in
            #expect(config.jump?.auth == .agent)
            return MockRemoteFileSystem(tree: ["/": []])
        })
        vm.jumpEnabled = true
        vm.jumpHost = "bastion.example.com"
        vm.jumpUsername = "bastion-user"
        vm.jumpAuthChoice = .agent
        vm.jumpPassword = ""
        vm.jumpKeyPath = ""
        let fs = await vm.connect()
        #expect(fs != nil)
    }

    /// `requireSecret` is irrelevant for agent (brief point 1): even
    /// `connect()`'s `requireSecret: true` branch must not demand anything
    /// for an agent-mode jump.
    @Test @MainActor func jumpAgentModeSurvivesEditSaveWithoutSecretOrKeyPath() {
        let vm = makeVM()
        vm.beginEditing(StoredSession(name: "web", host: "h", username: "u"))
        vm.jumpEnabled = true
        vm.jumpHost = "bastion.example.com"
        vm.jumpUsername = "bastion-user"
        vm.jumpAuthChoice = .agent

        let result = vm.validateForEditSave()

        #expect(result?.jump?.authKind == .agent)
        #expect(result?.jump?.keyPath == nil)
    }
}

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Lets exactly one of several competing tasks "win" — prevents a double
/// `continuation.resume` in the timeout race.
private actor RaceClaim {
    private var claimed = false
    func tryClaim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
