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
