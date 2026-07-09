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
        #expect(vm.state == .failed(message: "Port muss eine Zahl sein.", field: .port))
    }

    @Test func emptyHostFlagsHostField() async {
        let vm = makeVM()
        vm.host = ""
        _ = await vm.connect()
        #expect(vm.state == .failed(message: "Host darf nicht leer sein.", field: .host))
    }

    @Test func emptyPasswordFlagsPasswordFieldBeforeConnecting() async {
        let vm = makeVM(connector: { _, _ in
            Issue.record("Connector darf bei leerem Passwort nicht aufgerufen werden")
            throw RemoteFSError.connectionFailed(reason: "unreachable")
        })
        vm.password = ""
        _ = await vm.connect()
        #expect(vm.state == .failed(message: "Passwort darf nicht leer sein.", field: .password))
    }

    @Test func authFailureHasNoField() async {
        let vm = makeVM(connector: { _, _ in throw RemoteFSError.authenticationFailed })
        let fs = await vm.connect()
        #expect(fs == nil)
        #expect(vm.state == .failed(
            message: "Anmeldung fehlgeschlagen — Benutzername oder Passwort prüfen.",
            field: nil))
    }

    @Test func connectionFailureHasNoField() async {
        let vm = makeVM(connector: { _, _ in
            throw RemoteFSError.connectionFailed(reason: "timeout")
        })
        _ = await vm.connect()
        #expect(vm.state == .failed(message: "Verbindung fehlgeschlagen: timeout", field: nil))
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
            Issue.record("Connector darf bei fehlendem Session-Namen nicht laufen")
            throw RemoteFSError.connectionFailed(reason: "unreachable")
        })
        vm.shouldSaveSession = true
        vm.saveName = "   "
        let fs = await vm.connect()
        #expect(fs == nil)
        #expect(vm.state == .failed(
            message: "Name für die gespeicherte Session angeben.", field: .saveName))
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
            Issue.record("Connector darf ohne Key-Pfad nicht laufen")
            throw RemoteFSError.connectionFailed(reason: "unreachable")
        })
        vm.authChoice = .privateKey
        vm.keyPath = "  "
        _ = await vm.connect()
        #expect(vm.state == .failed(message: "Pfad zum SSH-Key angeben.", field: .keyPath))
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

    @Test func keyErrorsMapToGermanMessages() async {
        let vm = makeVM(connector: { _, _ in throw SSHKeyError.passphraseRequired })
        vm.authChoice = .privateKey
        vm.keyPath = "~/.ssh/id_ed25519"
        _ = await vm.connect()
        #expect(vm.state == .failed(
            message: "Der SSH-Key ist verschlüsselt — Passphrase angeben.",
            field: .password))
    }

    @Test func userSwitchClearsSecretButProgrammaticSetDoesNot() async {
        let vm = makeVM()
        vm.password = "geheim"
        vm.selectAuthChoice(.privateKey)
        #expect(vm.password.isEmpty)

        vm.password = "aus-dem-schluesselbund"
        vm.authChoice = .password   // programmatisch (connectStored-Pfad)
        #expect(vm.password == "aus-dem-schluesselbund")
    }

    @Test func secondConnectWhileConnectingIsRejected() async {
        let counter = CallCounter()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let vm = makeVM(connector: { _, _ in
            await counter.increment()
            for await _ in stream {}   // hängt, bis der Test den Stream beendet
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

    @Test func rejectMapsToGermanMessage() async {
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
            message: "Verbindung abgebrochen — Host-Key nicht bestätigt.", field: nil))
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
        // Warten bis der Prompt steht
        for _ in 0..<200 where vm.hostKeyPrompt == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(vm.hostKeyPrompt != nil)

        connectTask.cancel()

        // Ohne Cancellation-Handler hängt connect() für immer. Ein
        // withTaskGroup-Race würde beim Verlassen des Closures trotz
        // cancelAll() implizit auf den hängenden Kindtask warten (Swift
        // wartet immer auf alle Kindtasks) und selbst ewig blockieren —
        // deshalb hier zwei unstrukturierte Tasks, die per Actor-Claim um
        // die Continuation konkurrieren; ein hängender Verlierer-Task
        // blockiert so nicht den Rückgabewert.
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
        #expect(finished, "connect() muss nach Cancel zurückkehren (Continuation aufgelöst)")
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
            message: "ACHTUNG: Der Host-Key von example.com hat sich geändert! "
                + "Erwartet SHA256:AAAA, präsentiert SHA256:BBBB. "
                + "Möglicher Man-in-the-Middle — Verbindung abgebrochen.",
            field: nil))
        #expect(vm.hostKeyPrompt == nil)
    }
}

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Lässt genau einen von mehreren konkurrierenden Tasks „gewinnen" —
/// verhindert doppeltes `continuation.resume` im Timeout-Race.
private actor RaceClaim {
    private var claimed = false
    func tryClaim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
