import Foundation
import MacSCPTestSupport
import Testing

@testable import macSCPCore

/// The tab names an unreadable `managed_keys.json` when it costs the
/// connection (review follow-ups of 2026-09-18, Task 6 fix round 1).
///
/// The tab fills its key passphrase through
/// `ConnectionViewModel.fillManagedKeyPassphrase(store:secrets:)` — both App
/// call sites, `ContentView.fillForm` and the form's Connect button — which
/// reads the store through `ManagedKeyPassphrase.resolve`. That read used to
/// be a `try?`: an unreadable store looked exactly like a key macSCP does not
/// manage, and the dial's `passphraseRequired` asked the person to type a
/// passphrase with nothing pointing at the store.
///
/// The connector here is the one part that is not the App's: it loads the
/// key for real (`SSHPrivateKeyLoader`, the call the dial makes first) and
/// hands back a mock file system instead of dialling, so "it connects" means
/// "the key loaded with the passphrase the form held". The key is generated
/// at run time by `ssh-keygen`; the store is a temporary directory
/// (`CorruptManagedKeyStoreRig`).
@Suite("ConnectionViewModel over an unreadable managed key store", .timeLimit(.minutes(1)))
@MainActor
struct ConnectionViewModelManagedKeyStoreTests {
    private static let loadingConnector: ConnectionViewModel.Connector = { config, _ in
        guard case .ssh(let ssh) = config,
            case .privateKey(let keyPath, let passphrase) = ssh.auth
        else { throw RemoteFSError.protocolError(reason: "not a private-key dial") }
        _ = try SSHPrivateKeyLoader.authentication(
            username: ssh.username, keyPath: keyPath, passphrase: passphrase)
        return MockRemoteFileSystem(tree: ["/": []])
    }

    private static func form(keyPath: String, typed: String = "") -> ConnectionViewModel {
        let vm = ConnectionViewModel(connector: loadingConnector)
        vm.host = "127.0.0.1"
        vm.port = "22"
        vm.username = "tester"
        vm.authChoice = .privateKey
        vm.keyPath = keyPath
        vm.password = typed
        return vm
    }

    private static let storeMessage = CoreL10n.string("core.connect.managedKeyStoreUnreadable")
    private static let passphraseMessage = CoreL10n.string("core.connect.keyPassphraseRequired")
    private static let passphraseField = ConnectionViewModel.sshField(.passphrase)

    /// Corrupt store, managed encrypted key, empty slot: the failure names
    /// the store, on the passphrase row, and is still a person's to fix.
    @Test func aManagedKeyBehindACorruptStoreNamesTheStore() async throws {
        let rig = try CorruptManagedKeyStoreRig()
        defer { rig.tearDown() }
        try await rig.writeEncryptedKey(at: rig.managedKeyPath)
        let vm = Self.form(keyPath: rig.managedKeyPath)

        vm.fillManagedKeyPassphrase(store: rig.keys, secrets: rig.secrets)
        let fs = await vm.connect()

        #expect(fs == nil)
        #expect(vm.state == .failed(message: Self.storeMessage, field: Self.passphraseField))
        #expect(Self.storeMessage != Self.passphraseMessage)
        #expect(Self.storeMessage.contains("managed_keys.json"))
        #expect(vm.lastFailureKind == .needsPerson)
        #expect(vm.lastFailureReason == TunnelFailureKind.managedKeyStoreUnreadable.sentence)
    }

    /// The same corrupt store with the passphrase typed into the form: the
    /// fill takes what was typed and never reads the store, so nothing blocks
    /// the connection.
    @Test func aTypedPassphraseStillConnectsOverTheCorruptStore() async throws {
        let rig = try CorruptManagedKeyStoreRig()
        defer { rig.tearDown() }
        try await rig.writeEncryptedKey(at: rig.managedKeyPath)
        let vm = Self.form(keyPath: rig.managedKeyPath, typed: CorruptManagedKeyStoreRig.keyPassphrase)

        vm.fillManagedKeyPassphrase(store: rig.keys, secrets: rig.secrets)
        let fs = await vm.connect()

        #expect(fs != nil)
        #expect(vm.state == .idle)
    }

    /// The same corrupt store and a key it could never have held: the
    /// failure is the missing passphrase it always was.
    @Test func anUnmanagedKeyOverTheCorruptStoreFailsAsBefore() async throws {
        let rig = try CorruptManagedKeyStoreRig()
        defer { rig.tearDown() }
        try await rig.writeEncryptedKey(at: rig.unmanagedKeyPath)
        let vm = Self.form(keyPath: rig.unmanagedKeyPath)

        vm.fillManagedKeyPassphrase(store: rig.keys, secrets: rig.secrets)
        _ = await vm.connect()

        #expect(vm.state == .failed(message: Self.passphraseMessage, field: Self.passphraseField))
        #expect(vm.lastFailureReason == TunnelFailureKind.keyPassphraseRequired.sentence)
    }

    /// The fact belongs to the key path the fill looked at. A form whose key
    /// path was changed afterwards, to a key the store could never have held,
    /// is not told about the store when that key needs a passphrase.
    @Test func theFactDoesNotFollowTheFormToAnotherKey() async throws {
        let rig = try CorruptManagedKeyStoreRig()
        defer { rig.tearDown() }
        try await rig.writeEncryptedKey(at: rig.unmanagedKeyPath)
        let vm = Self.form(keyPath: rig.managedKeyPath)

        vm.fillManagedKeyPassphrase(store: rig.keys, secrets: rig.secrets)
        vm.keyPath = rig.unmanagedKeyPath
        _ = await vm.connect()

        #expect(vm.state == .failed(message: Self.passphraseMessage, field: Self.passphraseField))
    }

    /// A readable store that does not list the key is not a store problem.
    @Test func aReadableStoreIsAnOrdinaryMissingPassphrase() async throws {
        let rig = try CorruptManagedKeyStoreRig()
        defer { rig.tearDown() }
        try rig.repairStore()
        try await rig.writeEncryptedKey(at: rig.managedKeyPath)
        let vm = Self.form(keyPath: rig.managedKeyPath)

        vm.fillManagedKeyPassphrase(store: rig.keys, secrets: rig.secrets)
        _ = await vm.connect()

        #expect(vm.state == .failed(message: Self.passphraseMessage, field: Self.passphraseField))
    }

    // MARK: - The resolver no longer swallows the store

    @Test func theResolverReportsAnUnreadableStoreThatHidAManagedKey() throws {
        let rig = try CorruptManagedKeyStoreRig()
        defer { rig.tearDown() }

        let managed = ManagedKeyPassphrase.resolve(
            keyPath: rig.managedKeyPath, typed: "", store: rig.keys, secrets: rig.secrets)
        let unmanaged = ManagedKeyPassphrase.resolve(
            keyPath: rig.unmanagedKeyPath, typed: "", store: rig.keys, secrets: rig.secrets)

        #expect(managed == .init(passphrase: "", unreadableStoreHidTheKey: true))
        #expect(unmanaged == .init(passphrase: "", unreadableStoreHidTheKey: false))
    }

    /// A typed passphrase wins before the store is looked at, so it carries
    /// no fact about the store.
    @Test func aTypedPassphraseCarriesNoStoreFact() throws {
        let rig = try CorruptManagedKeyStoreRig()
        defer { rig.tearDown() }
        let typed = CorruptManagedKeyStoreRig.keyPassphrase

        let resolution = ManagedKeyPassphrase.resolve(
            keyPath: rig.managedKeyPath, typed: typed, store: rig.keys, secrets: rig.secrets)

        let passedThrough = resolution.passphrase == typed
        #expect(passedThrough)
        #expect(resolution.unreadableStoreHidTheKey == false)
    }
}
