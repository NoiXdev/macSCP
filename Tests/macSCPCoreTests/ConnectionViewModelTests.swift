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
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.portNumeric"), field: .schema("SSHField.port")))
    }

    @Test func emptyHostFlagsHostField() async {
        let vm = makeVM()
        vm.host = ""
        _ = await vm.connect()
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.emptyHost"), field: .schema("SSHField.host")))
    }

    @Test func emptyPasswordFlagsPasswordFieldBeforeConnecting() async {
        let vm = makeVM(connector: { _, _ in
            Issue.record("Connector must not be called with an empty password")
            throw RemoteFSError.connectionFailed(reason: "unreachable")
        })
        vm.password = ""
        _ = await vm.connect()
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.passwordEmpty"),
            field: .schema("SSHField.password")))
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
            guard case .ssh(let ssh) = config else {
                Issue.record("expected .ssh config")
                throw RemoteFSError.protocolError(reason: "expected .ssh config")
            }
            #expect(ssh.host == "example.com")
            #expect(ssh.username == "tim")
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
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.keyPathEmpty"),
            field: .schema("SSHField.keyPath")))
    }

    /// The key path is required only while it is VISIBLE, which under the
    /// schema means only under private-key auth — so this covers the
    /// `visibleWhen`-gated requirement reaching `connect()` through
    /// `firstViolation`, and the namespaced key naming the row to outline.
    ///
    /// It does NOT cover the password/passphrase split; `keyPath` is a plain
    /// text row, not a secret one. `keyErrorsMapToLocalizedMessages` is what
    /// pins that a private-key-auth secret failure names `SSHField.passphrase`.
    @Test @MainActor func emptyKeyPathUnderPrivateKeyAuthOutlinesTheKeyPathRow() async {
        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
        vm.host = "example.com"
        vm.username = "tim"
        vm.authChoice = .privateKey
        vm.keyPath = ""
        #expect(await vm.connect() == nil)
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.keyPathEmpty"),
            field: .schema("SSHField.keyPath")))
    }

    @Test func keyAuthAllowsEmptyPassphraseAndBuildsPrivateKeyAuth() async {
        let vm = makeVM(connector: { config, _ in
            guard case .ssh(let ssh) = config else {
                Issue.record("expected .ssh config")
                throw RemoteFSError.protocolError(reason: "expected .ssh config")
            }
            #expect(ssh.auth == .privateKey(keyPath: "~/.ssh/id_ed25519", passphrase: nil))
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
        // `SSHField.passphrase`, not `SSHField.password`: a key-passphrase
        // error can only happen under private-key auth, and the passphrase row
        // is the secret row visible there. This is what the App's old
        // `failedFieldID` computed from `authChoice`; the key now says it.
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.keyPassphraseRequired"),
            field: .schema("SSHField.passphrase")))
    }

    /// `selectAuthChoice` is what the auth-kind PICKER goes through — the form
    /// intercepts that field's write and calls this instead of storing the new
    /// value (`ConnectionFormView.interceptEdit`, M22/T8 fix round 1). Both
    /// storage slots are asserted, not just `password`'s current reading: the
    /// slot the user is switching AWAY from is the one that would otherwise
    /// resurface prefilled in the other mode's row, and from there be written
    /// to the Keychain by "Save as session" as a secret the user never typed
    /// for that purpose.
    @Test func userSwitchClearsSecretButProgrammaticSetDoesNot() async {
        let vm = makeVM()
        vm.password = "geheim"
        vm.selectAuthChoice(.privateKey)
        #expect(vm.password.isEmpty)
        #expect(vm.values[SSHField.password].isEmpty)
        #expect(vm.values[SSHField.passphrase].isEmpty)

        vm.password = "aus-dem-schluesselbund"
        vm.authChoice = .password   // programmatic (connectStored path)
        #expect(vm.password == "aus-dem-schluesselbund")
    }

    /// Review finding (M11d fix round 1): `lastConnectedConfig` carries the
    /// same raw secret as `password`/`keyPath` (it's built from them in
    /// `connect()`), so the disconnect-time scrub must forget it too --
    /// otherwise it survives in `SessionTab.connectionViewModel` across every
    /// later disconnect/reconnect in that tab, defeating `clearPassword()`'s
    /// own purpose for exactly this secret.
    @Test func clearRetainedSecretsForgetsPasswordAndLastConnectedConfig() async {
        let vm = makeVM()
        _ = await vm.connect()
        #expect(vm.lastConnectedConfig != nil)

        vm.password = "still-here"
        vm.clearRetainedSecrets()
        #expect(vm.password.isEmpty)
        #expect(vm.lastConnectedConfig == nil)
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
        // Same shape as the host-key tests below: a fixed sleep would let the
        // second connect() run BEFORE the first one reached `state =
        // .connecting`, so it would not be rejected — it would enter the
        // connector itself and park on the stream, and the
        // `continuation.finish()` that releases it sits AFTER this line.
        guard await waitUntil("first connect() must reach the connector", {
            await counter.value == 1
        }) else {
            // The failure is recorded; leaving here is what keeps it readable.
            // Falling through would run the second connect() into the stream
            // and park on it. Release the connector first so the implicit
            // await of `first` at scope exit cannot park either.
            continuation.finish()
            _ = await first
            return
        }

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
        // Leaving on a timeout is what keeps the recorded failure readable:
        // `await result` below would never return, because the prompt this
        // test is about to answer was never published. `result` is implicitly
        // cancelled and awaited at scope exit, which connect() survives — the
        // two cancellation tests below pin exactly that.
        guard await waitUntil("the host-key prompt must be published", {
            vm.hostKeyPrompt != nil
        }) else { return }
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
        // Same as above: without this guard the timeout path falls into
        // `await result`, which cannot return, and parks the run.
        guard await waitUntil("the host-key prompt must be published", {
            vm.hostKeyPrompt != nil
        }) else { return }
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
        // Wait until the prompt is up. The one site that deliberately does NOT
        // guard on the result: what follows is `completesWithoutHanging`, which
        // never awaits `connectTask` directly — it races the task against its
        // own watchdog and returns `false` when the task does not finish. A
        // timeout here therefore lands in the same red-and-return outcome the
        // guards produce elsewhere, and cannot park the run. Both failures are
        // reported, which is more than an early return would say.
        await waitUntil("the host-key prompt must be published") { vm.hostKeyPrompt != nil }

        connectTask.cancel()

        // Without a cancellation handler, connect() would hang forever.
        let finished = await completesWithoutHanging(connectTask)
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

        // Without cancellation handling (fast path AND onCancel), connect()
        // would hang forever.
        let finished = await completesWithoutHanging(connectTask)
        #expect(finished, "connect() must return when cancel is already set before the prompt")
        #expect(vm.hostKeyPrompt == nil)
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.hostkey.rejected"), field: nil))
    }

    @Test @MainActor func beginEditingPrefillsEverythingExceptTheSecret() {
        let vm = makeVM()
        let stored = sshSession(name: "web", host: "h", port: 2222, username: "u",
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
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u", groupID: UUID()))
        vm.exitEditMode()

        #expect(vm.mode == .new)
        #expect(vm.selectedGroupID == nil)
        // Field values are owned by the teardown/connectStored callers,
        // which overwrite them right after — exitEditMode must not clear them.
        #expect(vm.host == "h" && vm.saveName == "web")
    }

    @Test @MainActor func validateForEditSaveAllowsEmptyPasswordAndBuildsTheSession() {
        let vm = makeVM()
        let stored = sshSession(name: "web", host: "h", username: "u")
        vm.beginEditing(stored)
        vm.host = "new.example"

        let result = vm.validateForEditSave()
        #expect(result?.id == stored.id)
        #expect(result?.host == "new.example")
        #expect(vm.state == .idle)
    }

    @Test @MainActor func validateForEditSaveRejectsInvalidPort() {
        let vm = makeVM()
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u"))
        vm.port = "abc"
        #expect(vm.validateForEditSave() == nil)
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.portNumeric"), field: .schema("SSHField.port")))
    }

    @Test @MainActor func endEditingReturnsToNewMode() {
        let vm = makeVM()
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u"))
        vm.endEditing()
        #expect(vm.mode == .new)
        #expect(vm.host.isEmpty && vm.saveName.isEmpty)
    }

    /// `endEditing` must fully blank the form AND leave edit mode (via
    /// `exitEditMode`) — unlike `exitEditMode()` alone, which deliberately
    /// keeps the field values for its own callers.
    @Test @MainActor func endEditingResetsEverything() {
        let vm = makeVM()
        vm.beginEditing(sshSession(
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

    /// M23/T5 fix round 1 (CRITICAL): `validateJump` checks only PRESENCE --
    /// host non-empty, port parses as an `Int`, username non-empty -- while
    /// `SSHConnectionConfig.init` additionally enforces the host/username
    /// whitelists, the `1...65535` port range and a non-empty jump key path.
    /// A jump rejected by the second but accepted by the first must fail the
    /// connect, NOT silently drop the hop: swallowing the throw would dial the
    /// target directly, with no error anywhere, for a session whose whole point
    /// is that it may only be reached through the bastion.
    ///
    /// The connector guard is the load-bearing half of this test: asserting
    /// only the `.failed` state would still pass if the dial happened first and
    /// the error came from somewhere else.
    @Test func jumpConfigRejectedByTheConfigInitNeverDials() async {
        let vm = makeVM(connector: { _, _ in
            Issue.record("Connector must not be called when the jump config is rejected")
            throw RemoteFSError.connectionFailed(reason: "unreachable")
        })
        vm.jumpEnabled = true
        vm.jumpHost = "bastion.example.com"
        // Parses as an `Int` (so `validateJump` waves it through) but is
        // outside the port range `SSHConnectionConfig.init` enforces.
        vm.jumpPort = "70000"
        vm.jumpUsername = "bastion-user"
        vm.jumpPassword = "bastion-pass"

        let fs = await vm.connect()

        #expect(fs == nil)
        #expect(vm.state == .failed(
            message: String(
                format: CoreL10n.string("core.connect.invalidJumpPort %@"), "70000"),
            field: .jumpPort))
        // The hop was never silently dropped into a direct connection.
        #expect(vm.lastConnectedConfig == nil)
    }

    @Test @MainActor func jumpSetModeRequiresSelection() {
        let vm = makeVM()
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u"))
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
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u", jump: jump))
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
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u", jump: jump))
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
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u", jump: jump))
        // Sanity: beginEditing actually picked up the reference.
        #expect(vm.jumpSourceMode == .session)
        #expect(vm.jumpSessionID != nil)

        vm.exitEditMode()

        #expect(vm.jumpSourceMode == .manual)
        #expect(vm.jumpSessionID == nil)
    }

    /// F-1 fix (final review): `buildJumpSpec` must never emit BOTH a
    /// `sessionID` and a `loginSetID` -- a stale login-set pick left over
    /// from Manual+Set mode, made before the user flipped Source to "Saved
    /// connection", must not survive into the built spec. Without the fix
    /// this would inflate `sessionsUsing(setID:)`'s usage count and let
    /// `deleteLoginSet` write the set's secret into this session-mode jump's
    /// otherwise-unused `secretID` slot.
    @Test @MainActor func buildJumpSpecInSessionModeIgnoresDanglingLoginSetSelection() {
        let vm = makeVM()
        vm.jumpEnabled = true
        vm.jumpLoginMode = .set
        vm.jumpSelectedLoginSetID = UUID()
        vm.jumpSourceMode = .session
        vm.jumpSessionID = UUID()

        let spec = vm.buildJumpSpec()

        #expect(spec?.sessionID == vm.jumpSessionID)
        #expect(spec?.loginSetID == nil)
    }

    /// M-5 fix (final review): switching the jump's source picker AWAY from
    /// `.session` must clear `jumpPassword`/`jumpKeyPath` --
    /// `resolveSelectedJumpSession` (App layer) fills both with the
    /// REFERENCED session's own resolved secret/key path right before a
    /// connect attempt; if that connect then fails and the user flips Source
    /// to Manual, the bastion's secret would otherwise sit pre-filled in the
    /// manual SecureField, ready to be persisted into THIS session's own
    /// jump slot on the next save -- a secret the user never typed.
    @Test @MainActor func selectJumpSourceModeClearsSecretWhenLeavingSessionMode() {
        let vm = makeVM()
        vm.jumpEnabled = true
        vm.jumpSourceMode = .session
        vm.jumpSessionID = UUID()
        vm.jumpPassword = "bastion-secret"
        vm.jumpKeyPath = "/resolved/key"

        vm.selectJumpSourceMode(.manual)

        #expect(vm.jumpSourceMode == .manual)
        #expect(vm.jumpPassword.isEmpty)
        #expect(vm.jumpKeyPath.isEmpty)
    }

    /// Same call with the SAME mode is a no-op (mirrors `selectAuthChoice`'s
    /// own early-return guard) -- must not clobber fields the user is
    /// actively editing just because the picker re-fired with an unchanged
    /// selection.
    @Test @MainActor func selectJumpSourceModeIsNoOpWhenUnchanged() {
        let vm = makeVM()
        vm.jumpEnabled = true
        vm.jumpSourceMode = .manual
        vm.jumpPassword = "still-typing"

        vm.selectJumpSourceMode(.manual)

        #expect(vm.jumpPassword == "still-typing")
    }

    // MARK: - Agent auth (M10d/T3)

    @Test func agentAuthSkipsPasswordAndKeyPathValidationAndBuildsAgentAuth() async {
        let vm = makeVM(connector: { config, _ in
            guard case .ssh(let ssh) = config else {
                Issue.record("expected .ssh config")
                throw RemoteFSError.protocolError(reason: "expected .ssh config")
            }
            #expect(ssh.auth == .agent)
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
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u"))
        vm.authChoice = .agent
        vm.password = ""
        vm.keyPath = ""

        let result = vm.validateForEditSave()

        #expect(result?.authKind == .agent)
        #expect(result?.keyPath == nil)
    }

    @Test @MainActor func beginEditingMapsAgentAuthKindToAgentChoice() {
        let vm = makeVM()
        let stored = sshSession(name: "web", host: "h", username: "u", authKind: .agent)
        vm.beginEditing(stored)
        #expect(vm.authChoice == .agent)
    }

    @Test func jumpAgentModeRequiresNeitherSecretNorKeyPath() async {
        let vm = makeVM(connector: { config, _ in
            guard case .ssh(let ssh) = config else {
                Issue.record("expected .ssh config")
                throw RemoteFSError.protocolError(reason: "expected .ssh config")
            }
            #expect(ssh.jump?.auth == .agent)
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
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u"))
        vm.jumpEnabled = true
        vm.jumpHost = "bastion.example.com"
        vm.jumpUsername = "bastion-user"
        vm.jumpAuthChoice = .agent

        let result = vm.validateForEditSave()

        #expect(result?.jump?.authKind == .agent)
        #expect(result?.jump?.keyPath == nil)
    }

    // MARK: - S3 kind (M12/T7a)

    @Test func connectWithS3KindBuildsS3ConfigFromEnteredFields() async {
        let vm = makeVM(connector: { config, _ in
            guard case .s3(let s3) = config else {
                Issue.record("expected .s3 config")
                throw RemoteFSError.protocolError(reason: "expected .s3 config")
            }
            #expect(s3.accessKeyID == "AKIAEXAMPLE")
            #expect(s3.secretAccessKey == "shh-secret")
            #expect(s3.region == "eu-central-1")
            #expect(s3.endpoint == "https://s3.eu-central-1.amazonaws.com")
            #expect(s3.bucket == "my-bucket")
            #expect(s3.usePathStyle == true)
            return MockRemoteFileSystem(tree: ["/": []])
        })
        vm.kind = .s3
        vm.s3AccessKeyID = "AKIAEXAMPLE"
        vm.s3SecretAccessKey = "shh-secret"
        vm.s3Region = "eu-central-1"
        vm.s3Endpoint = "https://s3.eu-central-1.amazonaws.com"
        vm.s3Bucket = "my-bucket"
        vm.s3UsePathStyle = true

        let fs = await vm.connect()

        #expect(fs != nil)
        #expect(vm.state == .idle)
    }

    @Test func connectWithS3KindAndMissingBucketFailsBeforeConnecting() async {
        let vm = makeVM(connector: { _, _ in
            Issue.record("Connector must not be called with a missing required S3 field")
            throw RemoteFSError.connectionFailed(reason: "unreachable")
        })
        vm.kind = .s3
        vm.s3AccessKeyID = "AKIAEXAMPLE"
        vm.s3SecretAccessKey = "shh-secret"
        vm.s3Region = "eu-central-1"
        vm.s3Endpoint = "https://s3.eu-central-1.amazonaws.com"
        vm.s3Bucket = ""

        let fs = await vm.connect()

        #expect(fs == nil)
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.s3FieldRequired"),
            field: .schema("S3Field.bucket")))
    }

    /// The whole point of the collapse: one body, and S3/WebDAV now report WHICH
    /// field failed instead of a bare `field: nil`.
    @Test @MainActor func connectReportsTheOffendingS3Field() async {
        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
        vm.kind = .s3
        vm.s3Endpoint = "https://s3.example.com"
        vm.s3Region = "eu-central-1"
        vm.s3Bucket = ""
        vm.s3AccessKeyID = "AKIA"
        vm.s3SecretAccessKey = "secret"
        #expect(await vm.connect() == nil)
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.s3FieldRequired"),
            field: .schema("S3Field.bucket")))
    }

    @Test @MainActor func validateForEditSaveWithS3KindBuildsStoredSessionWithSecretFreeConfig() {
        let vm = makeVM()
        let stored = s3Session(name: "s3-prod")
        vm.beginEditing(stored)
        vm.kind = .s3
        vm.s3AccessKeyID = "AKIAEXAMPLE"
        vm.s3Region = "eu-central-1"
        vm.s3Endpoint = "https://s3.eu-central-1.amazonaws.com"
        vm.s3Bucket = "my-bucket"
        vm.s3UsePathStyle = true
        // Deliberately left empty -- edit mode never requires the secret
        // (mirrors the SSH/jump password's "leave unchanged" rule).
        vm.s3SecretAccessKey = ""

        let saved = vm.validateForEditSave()

        #expect(saved?.kind == .s3)
        #expect(saved?.s3 == StoredS3Config(
            accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
            endpoint: "https://s3.eu-central-1.amazonaws.com", bucket: "my-bucket",
            usePathStyle: true))
    }

    @Test @MainActor func beginEditingWithS3StoredSessionPopulatesFieldsWithoutTheSecret() {
        let vm = makeVM()
        let s3Config = StoredS3Config(
            accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
            endpoint: "https://s3.eu-central-1.amazonaws.com", bucket: "my-bucket",
            usePathStyle: true)
        let stored = s3Session(name: "s3-prod", config: s3Config)

        vm.beginEditing(stored)

        #expect(vm.kind == .s3)
        #expect(vm.s3Endpoint == "https://s3.eu-central-1.amazonaws.com")
        #expect(vm.s3Region == "eu-central-1")
        #expect(vm.s3Bucket == "my-bucket")
        #expect(vm.s3AccessKeyID == "AKIAEXAMPLE")
        #expect(vm.s3UsePathStyle == true)
        #expect(vm.s3SecretAccessKey.isEmpty)
    }

    // MARK: - WebDAV kind (M21/T9, tests added in the bug-fix round)

    @Test func connectWithWebDAVKindBuildsWebDAVConfigFromEnteredFields() async {
        let vm = makeVM(connector: { config, _ in
            guard case .webdav(let webdav) = config else {
                Issue.record("expected .webdav config")
                throw RemoteFSError.protocolError(reason: "expected .webdav config")
            }
            #expect(webdav.baseURL == "https://dav.example.com/dav")
            #expect(webdav.username == "dave")
            #expect(webdav.useNextcloudPath == true)
            #expect(webdav.password == "shh-secret")
            return MockRemoteFileSystem(tree: ["/": []])
        })
        vm.kind = .webdav
        vm.webdavBaseURL = "https://dav.example.com/dav"
        vm.username = "dave"
        vm.webdavUseNextcloudPath = true
        vm.password = "shh-secret"

        let fs = await vm.connect()

        #expect(fs != nil)
        #expect(vm.state == .idle)
    }

    @Test func connectWithWebDAVKindAndMissingBaseURLFailsBeforeConnecting() async {
        let vm = makeVM(connector: { _, _ in
            Issue.record("Connector must not be called with a missing required WebDAV field")
            throw RemoteFSError.connectionFailed(reason: "unreachable")
        })
        vm.kind = .webdav
        vm.webdavBaseURL = ""
        vm.username = "dave"
        vm.password = "shh-secret"

        let fs = await vm.connect()

        #expect(fs == nil)
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.webdavFieldRequired"),
            field: .schema("WebDAVField.baseURL")))
    }

    @Test @MainActor func connectReportsTheOffendingWebDAVField() async {
        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
        vm.kind = .webdav
        vm.webdavBaseURL = ""
        vm.username = "tim"
        vm.password = "pw"
        #expect(await vm.connect() == nil)
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.webdavFieldRequired"),
            field: .schema("WebDAVField.baseURL")))
    }

    @Test @MainActor func validateForEditSaveWithWebDAVKindBuildsStoredSessionWithSecretFreeConfig() {
        let vm = makeVM()
        let stored = webdavSession(name: "dav-prod")
        vm.beginEditing(stored)
        vm.kind = .webdav
        vm.webdavBaseURL = "https://dav.example.com/dav"
        vm.username = "dave"
        vm.webdavUseNextcloudPath = true
        // Deliberately left empty -- edit mode never requires the secret
        // (mirrors the SSH/S3 password's "leave unchanged" rule).
        vm.password = ""

        let saved = vm.validateForEditSave()

        #expect(saved?.kind == .webdav)
        #expect(saved?.webdav == StoredWebDAVConfig(
            baseURL: "https://dav.example.com/dav", username: "dave", useNextcloudPath: true))
    }

    /// Pins the statement-order dependency the reviewer flagged in
    /// `beginEditing`: the shared `username` field is set from
    /// `stored.username` (the "unused" placeholder every WebDAV session
    /// carries there, same as S3) FIRST, and only OVERRIDDEN by
    /// `stored.webdav.username` inside the `.webdav` branch. Using two
    /// different names for `stored.username` and `stored.webdav.username`
    /// here means this test would fail if a future refactor reordered or
    /// merged the S3/WebDAV blocks and dropped the override.
    @Test @MainActor func beginEditingWithWebDAVStoredSessionPopulatesFieldsWithoutTheSecret() {
        let vm = makeVM()
        let webdavConfig = StoredWebDAVConfig(
            baseURL: "https://dav.example.com/dav", username: "dave", useNextcloudPath: true)
        let stored = webdavSession(
            name: "dav-prod", config: webdavConfig)

        vm.beginEditing(stored)

        #expect(vm.kind == .webdav)
        #expect(vm.webdavBaseURL == "https://dav.example.com/dav")
        #expect(vm.username == "dave")
        #expect(vm.webdavUseNextcloudPath == true)
        #expect(vm.password.isEmpty)
    }

    /// M22/T9: an edit-save must carry the login-set reference forward for
    /// EVERY kind. The S3 and WebDAV paths dropped it — `beginEditing` put the
    /// form into Set mode with the set preselected, and the rebuilt
    /// `StoredSession` then came back with `loginSetID == nil`, so saving a
    /// renamed bucket silently unbound its credentials.
    @Test @MainActor func editSaveKeepsTheLoginSetBindingForEveryKind() {
        let setID = UUID()
        for kind in ConnectionKind.allCases {
            let vm = makeVM()
            let stored = StoredSession(
                id: UUID(), name: "n", host: "h", username: "u",
                loginSetID: setID, kind: kind,
                s3: kind == .s3
                    ? StoredS3Config(
                        accessKeyID: "AKIA", region: "r",
                        endpoint: "https://e.example.com", bucket: "b", usePathStyle: true)
                    : nil,
                webdav: kind == .webdav
                    ? StoredWebDAVConfig(
                        baseURL: "https://dav.example.com", username: "dave",
                        useNextcloudPath: false)
                    : nil)
            vm.beginEditing(stored)
            #expect(vm.loginMode == .set)

            let saved = vm.validateForEditSave()
            #expect(saved?.loginSetID == setID, "\(kind) dropped its login-set binding on save")
        }
    }
}

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Polls `condition` until it holds, and fails the test with `description`
/// once `timeout` is up instead of letting the run hang.
///
/// This suite and `ConnectionViewModel` are both `@MainActor`, so every
/// `async let`/`Task` started here queues behind all other main-actor work in
/// the process. A fixed `Task.sleep` is therefore NOT a wait for the child to
/// have run — under a full parallel suite it often has not, and the test then
/// answers a prompt that does not exist yet: `resolveHostKeyPrompt` takes its
/// `guard let continuation … else { return }` no-op, the child afterwards
/// registers a continuation nobody will ever resume, and the awaiting test
/// parks forever (0% CPU, `swift test` has no per-test timeout, so the whole
/// run never reports). Polling ties the wait to the state the test actually
/// depends on rather than to a wall clock.
///
/// The timeout is deliberately generous: it is an emergency exit that turns a
/// future regression into a red test, not a performance assertion. The
/// success path never waits for it — the loop leaves as soon as `condition`
/// holds.
///
/// Recording the failure is only half the job: at three of the four call
/// sites the very next statement is an `await` that cannot complete when the
/// wait timed out (the connect child never published what the test is about
/// to answer, or never reached the state that would make the following call
/// return). Falling through would print the message and THEN park at 0% CPU —
/// the exact failure this helper exists to prevent, just with a diagnosis
/// nobody gets to read, because `swift test` prints no summary for a run that
/// never ends. Hence the `Bool`: callers whose next step can park must
/// `guard` on it and leave the test instead. `@discardableResult` for the one
/// site that provably cannot park.
@MainActor @discardableResult
private func waitUntil(
    _ description: Comment,
    timeout: Duration = .seconds(30),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    var satisfied = await condition()
    while !satisfied, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
        satisfied = await condition()
    }
    #expect(satisfied, description, sourceLocation: sourceLocation)
    return satisfied
}

/// Reports whether `task` returned at all — the assertion the cancellation
/// tests above actually make ("connect() does not hang forever"). They
/// deliberately do NOT assert how *fast* it returns.
///
/// The success path is therefore signal-driven: the awaiting task resolves
/// the continuation the moment `task` returns, with no wall clock involved.
/// `deadline` is only an emergency exit so a genuine hang fails the test
/// instead of blocking the whole suite forever (`swift test` has no per-test
/// timeout). It is deliberately generous — the watchdog sleeps on the
/// cooperative pool while the work it judges hops through the MainActor, so a
/// tight deadline lets the timer beat correct behaviour on a loaded machine
/// (parallel builds, gated integration suites) and the test would measure
/// system load instead of cancellation handling.
///
/// A `withTaskGroup` race would implicitly wait for the hanging child task
/// when leaving the closure despite `cancelAll()` (Swift always waits for all
/// child tasks) and would itself block forever — hence two unstructured tasks
/// racing for the continuation via an actor claim; a hanging losing task
/// therefore doesn't block the return value.
private func completesWithoutHanging<T: Sendable>(
    _ task: Task<T, Never>,
    within deadline: Duration = .seconds(30)
) async -> Bool {
    let claim = RaceClaim()
    return await withCheckedContinuation { continuation in
        let watchdog = Task {
            try? await Task.sleep(for: deadline)
            if await claim.tryClaim() { continuation.resume(returning: false) }
        }
        Task {
            _ = await task.value
            if await claim.tryClaim() { continuation.resume(returning: true) }
            watchdog.cancel()
        }
    }
}

/// Lets exactly one of several competing tasks "win" — prevents a double
/// `continuation.resume` in the watchdog race.
private actor RaceClaim {
    private var claimed = false
    func tryClaim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
