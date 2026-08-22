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

    /// Review finding (M11d fix round 1): the disconnect-time scrub must
    /// forget `lastConnectedConfig` too, not just the form's own password --
    /// otherwise it survives in `SessionTab.connectionViewModel` across every
    /// later disconnect/reconnect in that tab. Since fix round 2,
    /// `lastConnectedConfig` no longer carries a raw secret at all -- it is
    /// redacted at assignment (`SSHConnectionConfig.redactingSecrets()`) --
    /// so this test now covers the property becoming `nil`, not a plaintext
    /// secret it once held; see `lastConnectedConfigCarriesNoPlaintextPassword`
    /// below for that guarantee.
    @Test func clearRetainedSecretsForgetsPasswordAndLastConnectedConfig() async {
        let vm = makeVM()
        _ = await vm.connect()
        #expect(vm.lastConnectedConfig != nil)

        vm.password = "still-here"
        vm.clearRetainedSecrets()
        #expect(vm.password.isEmpty)
        #expect(vm.lastConnectedConfig == nil)
    }

    /// Whole-phase review finding (fix round 2): `lastConnectedConfig` used
    /// to retain the DIALED config verbatim, plaintext password included, for
    /// as long as the tab stayed connected -- hours, not the seconds an
    /// alert is open. `connect()` now stores it via
    /// `SSHConnectionConfig.redactingSecrets()`, so a successful password
    /// login must leave no plaintext password reachable through this
    /// property, even while the session is still connected (i.e. before
    /// `clearRetainedSecrets()` ever runs).
    @Test func lastConnectedConfigCarriesNoPlaintextPassword() async {
        let vm = makeVM()
        _ = await vm.connect()

        // Hoisted into a Bool: `#expect` expands its receiver, and no
        // expansion may be able to print a password.
        let isEmptiedPassword: Bool
        if case .password(let value) = vm.lastConnectedConfig?.auth {
            isEmptiedPassword = value.isEmpty
        } else {
            isEmptiedPassword = false
        }
        #expect(vm.lastConnectedConfig != nil)
        #expect(isEmptiedPassword)
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

    /// `cancelConnecting()`'s own reason for existing (connection-liveness
    /// plan, Task 6): the connector below never returns on its own — the
    /// same hanging shape `secondConnectWhileConnectingIsRejected` above
    /// uses to prove a dial can outlast `Task.cancel()` on whatever wraps
    /// `connect()`. `cancelConnecting()` must release `state` anyway,
    /// without waiting for the dial.
    @Test @MainActor
    func cancelConnectingReleasesStateWhileTheDialNeverReturns() async {
        let counter = CallCounter()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let vm = makeVM(connector: { _, _ in
            await counter.increment()
            for await _ in stream {}   // hangs until the test ends the stream
            return MockRemoteFileSystem(tree: ["/": []])
        })

        async let result = vm.connect()
        guard await waitUntil("connect() must reach the connector", {
            await counter.value == 1
        }) else {
            continuation.finish()
            _ = await result
            return
        }
        #expect(vm.state == .connecting)

        vm.cancelConnecting()
        #expect(vm.state == .idle)

        // The connector is still parked on `stream` at this point — proof
        // that the assertion above did not depend on it having settled.
        // Releasing it now just lets the test itself finish cleanly.
        continuation.finish()
        _ = await result
    }

    /// `state` outside `.connecting` must not be stomped by a stray Cancel
    /// arriving late (the dial already settled on its own) — here,
    /// `.failed`, which must not be silently erased. NOT a claim that
    /// `cancelConnecting()` does nothing outside `.connecting` (fix round
    /// 2: `currentAttempt` now moves unconditionally, precisely so a
    /// Cancel arriving in this exact window still means something — see
    /// that method's own doc comment); this test only pins the ONE thing
    /// that stays untouched, `state` itself.
    @Test @MainActor func cancelConnectingLeavesStateAloneOutsideConnecting() async {
        let vm = makeVM()
        #expect(vm.state == .idle)
        vm.cancelConnecting()
        #expect(vm.state == .idle)

        vm.showFailure(message: "boom", field: nil)
        vm.cancelConnecting()
        #expect(vm.state == .failed(message: "boom", field: nil))
    }

    /// The regression test fix round 2's reordering shipped without (fix
    /// round 3, review-mandated): `cancelConnecting()` moves `currentAttempt`
    /// UNCONDITIONALLY now — before, not after, the `state == .connecting`
    /// guard. `currentAttempt` is `internal` specifically so this test can
    /// read it directly; see that property's own doc comment for why an
    /// indirect, effects-only test cannot reach this particular claim once
    /// `connect()` has already returned (there is no longer a suspended
    /// call left whose refusal would prove the token moved).
    @Test @MainActor func cancelConnectingMovesTheTokenEvenOutsideConnecting() async {
        let vm = makeVM()
        #expect(vm.state == .idle)
        let before = vm.currentAttempt

        vm.cancelConnecting()

        #expect(vm.currentAttempt != before, """
            cancelConnecting() must move currentAttempt even when state is \
            not .connecting — the OLD (fix round 1) shape gated the whole \
            method on `state == .connecting` and returned before ever \
            touching this property, which is exactly the window fix \
            round 2 closed.
            """)
    }

    /// The reason `cancelConnecting()` needs an attempt token at all
    /// (fix round 1, connection-liveness plan Task 6, measured by review):
    /// forcing `state` back to `.idle` unblocks a SECOND `connect()` call
    /// on this SAME instance, but the FIRST attempt's connector is still
    /// running, so both are genuinely concurrent on one `ConnectionViewModel`.
    /// Both connectors hang on their OWN stream here — attempt #2's is
    /// released only after this test has confirmed #2 also reached
    /// `.connecting` — so the test can deterministically prove attempt #1's
    /// late success is refused WHILE #2 is still genuinely in flight,
    /// rather than racing to catch a fast, easily-missed transition.
    @Test @MainActor
    func aLateSuccessFromAnAbandonedAttemptDoesNotOverwriteTheCurrentOnesState() async {
        let counter = CallCounter()
        let (stream1, continuation1) = AsyncStream<Void>.makeStream()
        let (stream2, continuation2) = AsyncStream<Void>.makeStream()
        let vm = makeVM(connector: { _, _ in
            let callNumber = await counter.incrementAndGet()
            if callNumber == 1 {
                for await _ in stream1 {}   // attempt #1 hangs until released
            } else {
                for await _ in stream2 {}   // attempt #2 hangs until released
            }
            return MockRemoteFileSystem(tree: ["/": []])
        })

        async let firstResult = vm.connect()
        guard await waitUntil("attempt #1 must reach the connector", {
            await counter.value == 1
        }) else {
            continuation1.finish()
            continuation2.finish()
            _ = await firstResult
            return
        }
        #expect(vm.state == .connecting)

        vm.cancelConnecting()
        #expect(vm.state == .idle)

        async let secondResult = vm.connect()
        guard await waitUntil("attempt #2 must reach the connector", {
            await counter.value == 2
        }) else {
            continuation1.finish()
            continuation2.finish()
            _ = await firstResult
            _ = await secondResult
            return
        }
        #expect(vm.state == .connecting)

        // Attempt #1 finally succeeds, in the true background, while #2 is
        // still hanging in ITS OWN connector call — genuinely concurrent,
        // not just theoretically so.
        continuation1.finish()
        let firstFS = await firstResult
        #expect(firstFS == nil, """
            an abandoned attempt's own success must not be handed back to \
            its own caller — the caller has already moved on.
            """)
        #expect(vm.state == .connecting, """
            attempt #1's late, abandoned success must not overwrite \
            attempt #2's still-genuine `.connecting`.
            """)

        continuation2.finish()
        let secondFS = await secondResult
        #expect(secondFS != nil)
        #expect(vm.state == .idle)
        #expect(await counter.value == 2)
    }

    /// The host-key half of the same measured failure: attempt #1's late
    /// decider call must not replace attempt #2's still-pending trust card
    /// with a DIFFERENT host's fingerprint, and must not overwrite #2's
    /// continuation — which would leave #2's card on screen with nothing
    /// left able to resolve it.
    @Test @MainActor
    func anAbandonedAttemptsHostKeyPromptDoesNotOverwriteTheCurrentOnesCard() async {
        let candidateA = HostKeyCandidate(
            host: "abandoned.example.com", port: 22, keyType: "ssh-ed25519",
            publicKeyBase64: "AAAAC3NzaC1lZDI1NTE5AAAAIAtestA")
        let candidateB = HostKeyCandidate(
            host: "current.example.com", port: 22, keyType: "ssh-ed25519",
            publicKeyBase64: "AAAAC3NzaC1lZDI1NTE5AAAAIAtestB")
        let counter = CallCounter()
        let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
        let vm = makeVM(connector: { _, decider in
            let callNumber = await counter.incrementAndGet()
            let candidate: HostKeyCandidate
            if callNumber == 1 {
                for await _ in releaseStream {}   // attempt #1 hangs before ever asking
                candidate = candidateA
            } else {
                candidate = candidateB
            }
            let trusted = await decider(candidate)
            guard trusted else { throw HostKeyError.rejectedByUser }
            return MockRemoteFileSystem(tree: ["/": []])
        })

        async let firstResult = vm.connect()
        guard await waitUntil("attempt #1 must reach the connector", {
            await counter.value == 1
        }) else {
            releaseContinuation.finish()
            _ = await firstResult
            return
        }
        vm.cancelConnecting()

        async let secondResult = vm.connect()
        guard await waitUntil("attempt #2's host-key prompt must be published", {
            vm.hostKeyPrompt != nil
        }) else {
            releaseContinuation.finish()
            _ = await firstResult
            _ = await secondResult
            return
        }
        #expect(vm.hostKeyPrompt?.candidate == candidateB)

        // Attempt #1 is released now and reaches its OWN decider call — it
        // must not publish `candidateA` over `candidateB`'s still-pending
        // card, and must not register a continuation nobody will resume.
        // Awaiting `firstResult` directly (rather than polling a counter)
        // is what actually waits for attempt #1's decider call AND its
        // subsequent guard-return to finish, not just for its connector to
        // have STARTED.
        releaseContinuation.finish()
        let firstFS = await firstResult
        #expect(firstFS == nil)
        #expect(vm.hostKeyPrompt?.candidate == candidateB, """
            attempt #1's late decider call must not replace attempt #2's \
            still-pending host-key card.
            """)

        // #2's continuation must still be the live one — resolving it
        // must still work, proving it was never silently overwritten.
        vm.resolveHostKeyPrompt(trust: true)
        let secondFS = await secondResult
        #expect(secondFS != nil, """
            attempt #2's continuation was overwritten or lost — resolving \
            it did not let #2's connect() finish.
            """)
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

    /// `beginEditing` prefills `tags` from the stored session (P3a/T5) —
    /// mirroring `saveName`/`selectedGroupID` above, one row in the same
    /// prefill test rather than a separate one, since it is the same
    /// mechanism.
    @Test @MainActor func beginEditingPrefillsTags() {
        let vm = makeVM()
        var stored = sshSession(name: "web", host: "h", username: "u")
        stored.tags = ["docker", "web"]
        vm.beginEditing(stored)

        #expect(vm.tags == ["docker", "web"])
    }

    @Test @MainActor func exitEditModeResetsModeAndGroupButKeepsFields() {
        let vm = makeVM()
        var stored = sshSession(name: "web", host: "h", username: "u", groupID: UUID())
        stored.tags = ["docker"]
        vm.beginEditing(stored)
        vm.exitEditMode()

        #expect(vm.mode == .new)
        #expect(vm.selectedGroupID == nil)
        // Field values are owned by the teardown/connectStored callers,
        // which overwrite them right after — exitEditMode must not clear them.
        #expect(vm.host == "h" && vm.saveName == "web")
        #expect(vm.tags == ["docker"])
    }

    @Test @MainActor func validateForEditSaveAllowsEmptyPasswordAndBuildsTheSession() {
        let vm = makeVM()
        let stored = sshSession(name: "web", host: "h", username: "u")
        vm.beginEditing(stored)
        vm.host = "new.example"

        let result = vm.validateForEditSave()
        #expect(result?.id == stored.id)
        #expect(result?.ssh?.host == "new.example")
        #expect(vm.state == .idle)
    }

    /// `validateForEditSave` hands the form's raw `tags` straight to
    /// `StoredSession.tags`, whose setter applies `TagList.normalized`
    /// (P3a/T5, whole-phase fix round) — so the returned session carries the
    /// normalized list even though this path never calls the rule itself.
    /// Pinned for the edit path separately from
    /// `SessionListViewModelTests.savingCarriesTagsOntoTheStoredSession`
    /// because the two write paths do not share code and either could stop
    /// assigning `tags` at all.
    @Test @MainActor func validateForEditSaveNormalizesTags() {
        let vm = makeVM()
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u"))
        vm.tags = ["  docker ", "docker", "web"]

        let result = vm.validateForEditSave()
        #expect(result?.tags == ["docker", "web"])
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
        var stored = sshSession(name: "web", host: "h", username: "u")
        stored.tags = ["docker"]
        vm.beginEditing(stored)
        vm.endEditing()
        #expect(vm.mode == .new)
        #expect(vm.host.isEmpty && vm.saveName.isEmpty)
        #expect(vm.tags.isEmpty)
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
    /// `SessionListViewModel.resolveJumpSession` fills both with the
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

        #expect(result?.ssh?.authKind == .agent)
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

    /// The shared `username` property must resolve to WebDAV's OWN field, not
    /// to `stored.username` (the "unused" placeholder every WebDAV session
    /// carries there, same as S3). This used to be a statement-order
    /// dependency inside `beginEditing` — the shared field was filled first and
    /// OVERRIDDEN by the `.webdav` branch afterwards; since M23/T7 it is the
    /// descriptor's own `sessionValues`, which never reads `stored.username`
    /// for a WebDAV session at all. The fixture deliberately uses two different
    /// names for the two, so reading the wrong one still fails here.
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

    // MARK: - One prefill body (M23/T7)

    /// `beginEditing` must not leave one protocol's fields visible in another's
    /// form — the sticky-toggle lesson the S3 and WebDAV `else` branches spelled
    /// out by hand. Resetting to the descriptor's defaults says it once.
    @Test @MainActor func beginEditingLeavesNoFieldsFromThePreviousSession() {
        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
        vm.beginEditing(s3Session(
            name: "bucket",
            config: StoredS3Config(
                accessKeyID: "AKIA", region: "eu-central-1",
                endpoint: "https://s3.example.com", bucket: "archive",
                usePathStyle: true)))
        #expect(vm.s3Bucket == "archive")

        vm.beginEditing(sshSession(name: "prod", host: "example.com", username: "tim"))
        #expect(vm.kind == .ssh)
        #expect(vm.host == "example.com")
        #expect(vm.s3Bucket == "")
        #expect(vm.s3UsePathStyle == false)
    }

    /// The same rule for two edits of the SAME kind, which the `kind` setter's
    /// own reset cannot catch (it is guarded on an actual change): a second S3
    /// session whose stored block is MISSING must leave a blank form, not the
    /// previous bucket. `sessionValues` returns the empty bag for that
    /// inconsistency and the defaults underneath it are what blanks the form.
    @Test @MainActor func beginEditingSameKindTwiceLeavesNoFieldsFromThePreviousSession() {
        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
        vm.beginEditing(s3Session(
            name: "bucket",
            config: StoredS3Config(
                accessKeyID: "AKIA", region: "eu-central-1",
                endpoint: "https://s3.example.com", bucket: "archive",
                usePathStyle: true)))
        #expect(vm.s3Bucket == "archive")

        var inconsistent = s3Session(name: "broken")
        inconsistent.s3 = nil
        vm.beginEditing(inconsistent)

        #expect(vm.kind == .s3)
        #expect(vm.s3Bucket == "")
        #expect(vm.s3Region == "")
        #expect(vm.s3Endpoint == "")
        #expect(vm.s3AccessKeyID == "")
        #expect(vm.s3UsePathStyle == false)
    }

    /// WebDAV's user name lives on its own block, and the secret is NEVER read
    /// from the Keychain during a prefill.
    @Test @MainActor func beginEditingFillsWebDAVFromItsOwnBlock() {
        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
        vm.beginEditing(webdavSession(
            name: "cloud",
            config: StoredWebDAVConfig(
                baseURL: "https://nas.example.com/dav",
                username: "tim", useNextcloudPath: true)))
        #expect(vm.kind == .webdav)
        #expect(vm.webdavBaseURL == "https://nas.example.com/dav")
        #expect(vm.username == "tim")
        #expect(vm.webdavUseNextcloudPath == true)
        #expect(vm.password == "")
    }

    /// The jump toggle is a MODE switch and must not survive a protocol switch
    /// (M23/T7). `kind`'s own reset already wipes the jump's host/port/login out
    /// of `values`, but `jumpEnabled` and the source/set bookkeeping live beside
    /// it — so a jump left on in an SSH form and then switched to S3 used to
    /// leave `buildJumpSpec()` returning a hollow spec (empty host, fresh
    /// `secretID`) for a backend with no hop at all. Only the SSH form renders
    /// the block, so the user could not even see what was about to be saved.
    @Test @MainActor func switchingProtocolClearsTheJumpBlock() {
        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
        vm.jumpEnabled = true
        vm.jumpHost = "bastion.example.com"
        vm.jumpUsername = "tim"
        vm.jumpSourceMode = .session
        vm.jumpSessionID = UUID()

        vm.kind = .s3

        #expect(vm.jumpEnabled == false)
        #expect(vm.jumpHost == "")
        #expect(vm.jumpSourceMode == .manual)
        #expect(vm.jumpSessionID == nil)
        #expect(vm.buildJumpSpec() == nil)
    }

    /// The login switcher is a MODE switch too, and a stale selection here is
    /// worse than a stale jump: the picker filters its options by kind
    /// (`ConnectionFormView.loginSetPicker`), so an SSH set selected before a
    /// switch to S3 becomes INVISIBLE rather than cleared, while the submit gate
    /// only checked that something is selected. The session would be stored
    /// with `kind == .s3` bound to an SSH set, and every later connect would
    /// throw `LoginResolveError.kindMismatch` — a permanently unopenable
    /// session. Since M29-P2 the gate also compares kinds
    /// (`SessionListViewModel.resolveTargetLoginSet` refuses with
    /// `.targetSetKindMismatch`); this reset stays the earlier line of
    /// defense, clearing the selection before that guard is reached.
    @Test @MainActor func switchingProtocolClearsTheLoginSetSelection() {
        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
        vm.loginMode = .set
        vm.selectedLoginSetID = UUID()

        vm.kind = .s3

        #expect(vm.loginMode == .manual)
        #expect(vm.selectedLoginSetID == nil)
    }

    /// The counterpart to the reset above: "Save as new login set" is NOT a
    /// stale-reference risk and deliberately survives the switch. See the
    /// `kind` setter's own doc comment for the reasoning.
    @Test @MainActor func switchingProtocolKeepsTheSaveAsNewLoginSetIntent() {
        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
        vm.saveAsNewLoginSet = true
        vm.newLoginSetName = "Work"

        vm.kind = .webdav

        #expect(vm.saveAsNewLoginSet)
        #expect(vm.newLoginSetName == "Work")
    }

    /// A prefill must never park the `"unused"` placeholder a legacy non-SSH
    /// session still carries in `host`/`username` into the form — the S3 form
    /// does not render those rows, but a later switch to the SSH type would
    /// show them, and `displaySummary` reads them.
    @Test @MainActor func beginEditingCopiesNoPlaceholderIntoTheForm() {
        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
        vm.beginEditing(s3Session(name: "bucket"))
        #expect(vm.values[SSHField.host] == "")
        #expect(vm.values[SSHField.username] == "")
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
                id: UUID(), name: "n", loginSetID: setID, kind: kind,
                ssh: kind == .ssh ? StoredSSHConfig(host: "h", username: "u") : nil,
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

    // MARK: - One edit-save body (M23/T6)

    /// The defect this milestone dissolves at its root: every non-SSH session
    /// stored the literal placeholder "unused" in host and username, which made
    /// them all share the import duplicate key `unused|22|unused`.
    ///
    /// Repointed at `ssh` in M23/T8 fix round 1. It used to assert
    /// `host != "unused"`, which became a tautology the moment `host` was a
    /// convenience returning "" for a block-less session — there is no longer
    /// any value it COULD have returned that would fail. The placeholder is
    /// now impossible by construction rather than merely absent, and the
    /// assertion that says so is `ssh == nil`.
    @Test @MainActor func editSaveWritesNoPlaceholders() {
        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
        vm.beginEditing(s3Session(name: "bucket"))
        vm.saveName = "bucket"
        vm.s3Endpoint = "https://s3.example.com"
        vm.s3Region = "eu-central-1"
        vm.s3Bucket = "archive"
        vm.s3AccessKeyID = "AKIA"
        let saved = vm.validateForEditSave()
        #expect(saved?.ssh == nil)
        #expect(saved?.s3?.bucket == "archive")
    }

    /// An edit-save must carry forward everything the form does not show.
    ///
    /// NOTE (fix round 1): this does NOT discriminate mutate-vs-rebuild —
    /// the OLD `validateForEditSaveS3` already forwarded `groupID` and
    /// `loginSetID` by hand (an earlier milestone had fixed that specific
    /// binding loss), so all four assertions below pass against a rebuilding
    /// implementation too. It pins that regression, which is real and worth
    /// keeping pinned, but see `editSaveMutatesTheOriginalInsteadOfRebuildingIt`
    /// for the test that actually goes red if this body were changed back to
    /// constructing a fresh `StoredSession`.
    @Test @MainActor func editSavePreservesWhatTheFormNeverShows() {
        let group = UUID(), set = UUID()
        let original = s3Session(name: "bucket", groupID: group, loginSetID: set)
        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
        vm.beginEditing(original)
        vm.saveName = "bucket renamed"
        vm.s3Bucket = "archive"
        let saved = vm.validateForEditSave()
        #expect(saved?.id == original.id)
        #expect(saved?.name == "bucket renamed")
        #expect(saved?.groupID == group)
        #expect(saved?.loginSetID == set)
    }

    /// RETIRED and replaced (M23/T8): this slot held
    /// `editSaveMutatesTheOriginalInsteadOfRebuildingIt`, whose own doc
    /// comment predicted its end. It used `port: 443` on an S3 session as its
    /// mutate-versus-rebuild discriminator, which only worked while
    /// `StoredSession` carried `port` as a field shared by every kind even
    /// though S3 never reads or writes it. Task 8 moved host/port/username/
    /// authKind/keyPath/jump into an SSH-only `ssh` block, so `StoredSession`
    /// now shrinks to exactly the set `validateForEditSave` assigns — id,
    /// name, groupID, loginSetID, kind and the three backend blocks. There is
    /// nothing left for a rebuild to forget, so mutate-versus-rebuild is
    /// structural rather than test-guarded, and a test asserting it would
    /// assert nothing.
    ///
    /// What takes its place is a real behavioral claim about the new shape,
    /// not a consequence of it: an edit-save on a non-SSH session must leave
    /// NO SSH block behind.
    ///
    /// SCOPE (corrected in fix round 2): this pins the OUTCOME for a session
    /// that was already non-SSH, and it does NOT cover the
    /// `if kind != .ssh { session.ssh = nil }` guard in `validateForEditSave`.
    /// It cannot: `s3Session(...)` starts with `ssh == nil` and the `.s3`
    /// adapter never writes `ssh`, so deleting the guard leaves this test
    /// green. The guard is covered by
    /// `editSaveClearsTheSSHBlockWhenTheKindChangesAwayFromSSH` below, which
    /// starts from a session that HAS a block.
    @Test @MainActor func editSaveLeavesNoSSHBlockOnANonSSHSession() {
        let stored = s3Session(
            name: "bucket",
            config: StoredS3Config(
                accessKeyID: "AKIA", region: "eu-central-1",
                endpoint: "https://s3.example.com", bucket: "bucket", usePathStyle: false))
        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
        vm.beginEditing(stored)
        vm.saveName = "bucket"
        vm.s3Bucket = "renamed-bucket"

        let saved = vm.validateForEditSave()

        #expect(saved?.ssh == nil)
        #expect(saved?.s3?.bucket == "renamed-bucket")
    }

    /// The guard the test above cannot reach: `validateForEditSave`'s
    /// `if kind != .ssh { session.ssh = nil }` (fix round 2).
    ///
    /// Starting from a session that HAS an SSH block and switching `kind` away
    /// from `.ssh` mid-edit is the only way to exercise it — every other route
    /// begins with `ssh == nil`, so the guard is a no-op and its deletion goes
    /// unnoticed. Without it the S3 session keeps a fully populated SSH block
    /// (host, port, user name, key path) that reaches the store, every export,
    /// and `SessionImportPlanner.duplicateKey` — the pre-M23 defect exactly,
    /// only now spelled with real values rather than `"unused"`.
    ///
    /// REACHABILITY, decided on evidence rather than assumption: the type
    /// picker is `.disabled(isEditMode)` in `ConnectionFormView`, so the UI
    /// cannot drive this today. The view model nonetheless permits it —
    /// `kind` is a public settable property whose `didSet` resets `values`,
    /// the jump fields and the login-set binding, i.e. it is BUILT to be
    /// changed, not merely assignable. `validateForEditSave` is public and
    /// makes no claim about `kind` being frozen. So the guard is defensible
    /// as a view-model-level invariant rather than dead code, and the right
    /// answer is to test it, not delete it. If the picker is ever enabled in
    /// edit mode, this is the test that was already waiting.
    @Test @MainActor func editSaveClearsTheSSHBlockWhenTheKindChangesAwayFromSSH() {
        let stored = sshSession(
            name: "shared", host: "h.example.com", port: 2222, username: "tim",
            authKind: .privateKey, keyPath: "/keys/id_ed25519")
        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
        vm.beginEditing(stored)
        // Sanity: the session really does carry a block to lose.
        #expect(stored.ssh != nil)

        vm.kind = .s3
        vm.saveName = "shared"
        vm.s3Endpoint = "https://s3.example.com"
        vm.s3Region = "eu-central-1"
        vm.s3Bucket = "backups"
        vm.s3AccessKeyID = "AKIA"

        let saved = vm.validateForEditSave()

        #expect(saved?.kind == .s3)
        #expect(saved?.s3?.bucket == "backups")
        #expect(saved?.ssh == nil)
    }

    /// The old S3/WebDAV edit-save bodies passed no `jump:` argument at all
    /// when constructing their replacement `StoredSession`, so a configured
    /// jump host silently vanished on the very next edit-save. M23/T6 fixed
    /// that by mutating rather than rebuilding; nothing pinned it before.
    ///
    /// Retargeted from `.s3` to `.ssh` by M23/T8: the jump now lives inside
    /// the SSH block, so "a jump on an S3 session" is unrepresentable rather
    /// than merely preserved — and SSH is where the regression would actually
    /// cost a user their bastion.
    @Test @MainActor func editSavePreservesTheJumpAcrossAnEditSave() {
        let jump = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "bastion-user", authKind: .password)
        let stored = sshSession(
            name: "prod", host: "example.com", username: "tim", jump: jump)
        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
        vm.beginEditing(stored)
        #expect(vm.jumpEnabled) // sanity: beginEditing actually picked the jump up
        vm.saveName = "prod"

        let saved = vm.validateForEditSave()

        #expect(saved?.jump?.host == "bastion.example.com")
    }

    /// Edit mode leaves the secret blank to mean "keep the stored one". A
    /// requireSecrets: true here would make every password session unsaveable
    /// without retyping its password.
    @Test @MainActor func editSaveAcceptsABlankSecret() {
        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
        vm.beginEditing(sshSession(name: "prod", host: "example.com", username: "tim"))
        vm.saveName = "prod"
        vm.password = ""
        #expect(vm.validateForEditSave() != nil)
    }

    /// M30: leaving Set mode is the one moment where an empty secret field
    /// does NOT mean "leave the stored one unchanged". Without this rule the
    /// password of the previous configuration stays in the keychain and is
    /// silently used again on the next connect.
    ///
    /// The other direction -- a manual session that does not switch mode at
    /// all -- is held by `validateForEditSaveAllowsEmptyPasswordAndBuildsTheSession`
    /// earlier in this file. Together the two pin the rule in BOTH
    /// directions: a hardcoded `true` or `false` turns one of them red.
    @Test @MainActor func leavingLoginSetModeWithAnEmptyPasswordIsRefused() {
        let vm = makeVM()
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u",
                                   loginSetID: UUID()))
        vm.loginMode = .manual
        vm.password = ""

        #expect(vm.validateForEditSave() == nil)
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.passwordEmpty"),
            field: .schema("\(SSHField.namespace).\(SSHField.password.rawValue)")))
    }

    @Test @MainActor func leavingLoginSetModeWithATypedPasswordSaves() {
        let vm = makeVM()
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u",
                                   loginSetID: UUID()))
        vm.loginMode = .manual
        vm.password = "typed"

        let result = vm.validateForEditSave()
        #expect(result?.loginSetID == nil)
        #expect(vm.state == .idle)
    }

    /// False-refusal guard. The SSH passphrase is deliberately NOT declared
    /// required in `SSHFieldSchema.credential` -- an unencrypted key has
    /// none. Should that ever change, it surfaces here rather than at the
    /// user.
    @Test @MainActor func leavingLoginSetModeWithAKeyLoginNeedsNoPassphrase() {
        let vm = makeVM()
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u",
                                   authKind: .privateKey, keyPath: "/k",
                                   loginSetID: UUID()))
        vm.loginMode = .manual
        vm.password = ""

        #expect(vm.validateForEditSave() != nil)
    }

    /// Second false-refusal guard: an agent login shows no secret field at
    /// all, so `requireSecrets` has nothing to demand there.
    @Test @MainActor func leavingLoginSetModeWithAnAgentLoginNeedsNoSecret() {
        let vm = makeVM()
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u",
                                   authKind: .agent, loginSetID: UUID()))
        vm.loginMode = .manual
        vm.password = ""

        #expect(vm.validateForEditSave() != nil)
    }

    /// Moving from one set to another is not leaving: there is no manual mode
    /// in which an old slot could become live again.
    @Test @MainActor func switchingBetweenLoginSetsNeedsNoSecret() {
        let vm = makeVM()
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u",
                                   loginSetID: UUID()))
        vm.selectedLoginSetID = UUID()
        vm.password = ""

        #expect(vm.validateForEditSave() != nil)
    }

    /// M30, the jump's half of the same rule: the jump owns a keychain slot
    /// and the same set binding, so it has the same way back into a stale
    /// credential. The session itself stays unbound here so this test
    /// measures the jump rule alone rather than the session one.
    @Test @MainActor func aJumpLeavingLoginSetModeWithAnEmptyPasswordIsRefused() {
        let vm = makeVM()
        vm.beginEditing(sshSession(
            name: "web", host: "h", username: "u",
            jump: StoredSession.JumpSpec(host: "bastion", username: "j",
                                         loginSetID: UUID())))
        vm.jumpLoginMode = .manual
        vm.jumpPassword = ""

        #expect(vm.validateForEditSave() == nil)
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.jumpPasswordEmpty"),
            field: .jumpPassword))
    }

    @Test @MainActor func aJumpLeavingLoginSetModeWithATypedPasswordSaves() {
        let vm = makeVM()
        vm.beginEditing(sshSession(
            name: "web", host: "h", username: "u",
            jump: StoredSession.JumpSpec(host: "bastion", username: "j",
                                         loginSetID: UUID())))
        vm.jumpLoginMode = .manual
        vm.jumpPassword = "typed"

        #expect(vm.validateForEditSave() != nil)
        #expect(vm.state == .idle)
    }
}

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
    /// Atomic read-after-increment (connection-liveness plan, Task 6 fix
    /// round 1): a caller that needs to know WHICH numbered call it is —
    /// telling a first, hanging connector invocation apart from a second,
    /// immediately-resolving one — cannot do that safely with two separate
    /// actor hops (`increment()` then `value`), since another call could
    /// land between them.
    func incrementAndGet() -> Int {
        value += 1
        return value
    }
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
/// Recording the failure is only half the job: at eight of the nine call
/// sites (recounted for the connection-liveness plan Task 6 fix round,
/// which added four more of the guarded kind) the very next statement is an
/// `await` that cannot complete when the wait timed out (the connect child
/// never published what the test is about to answer, or never reached the
/// state that would make the following call return). Falling through would
/// print the message and THEN park at 0% CPU — the exact failure this
/// helper exists to prevent, just with a diagnosis nobody gets to read,
/// because `swift test` prints no summary for a run that never ends. Hence
/// the `Bool`: callers whose next step can park must `guard` on it and
/// leave the test instead. `@discardableResult` for the one site that
/// provably cannot park.
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
