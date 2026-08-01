import Foundation
import Testing
@testable import macSCPCore

@Suite("ManagedKeyPassphrase")
struct ManagedKeyPassphraseTests {
    private func tempStore() -> ManagedKeyStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-pp-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ManagedKeyStore(directory: dir)
    }

    @Test func managedKeyWithStoredPassphraseIsResolved() throws {
        let store = tempStore()
        let key = ManagedKey(
            name: "k", comment: "", type: .ed25519, fingerprint: "SHA256:x",
            publicKeyOpenSSH: "ssh-ed25519 AAAA", createdAt: Date(),
            hasPassphrase: true, fileName: "kf")
        try store.add(key)
        let secrets = InMemorySecretStore()
        try secrets.savePassword("stored-pp", for: key.id)
        let path = store.keyDirectory.appendingPathComponent("kf").path

        let effective = ManagedKeyPassphrase.resolve(
            keyPath: path, typed: "", store: store, secrets: secrets)
        #expect(effective == "stored-pp")
    }

    @Test func typedPassphraseWins() throws {
        let store = tempStore()
        let key = ManagedKey(
            name: "k", comment: "", type: .ed25519, fingerprint: "SHA256:x",
            publicKeyOpenSSH: "ssh-ed25519 AAAA", createdAt: Date(),
            hasPassphrase: true, fileName: "kf")
        try store.add(key)
        let secrets = InMemorySecretStore()
        try secrets.savePassword("stored-pp", for: key.id)
        let path = store.keyDirectory.appendingPathComponent("kf").path

        #expect(ManagedKeyPassphrase.resolve(
            keyPath: path, typed: "typed", store: store, secrets: secrets) == "typed")
    }

    @Test func foreignPathFallsBackToTyped() throws {
        let store = tempStore()
        let secrets = InMemorySecretStore()
        #expect(ManagedKeyPassphrase.resolve(
            keyPath: "/Users/tim/.ssh/id_ed25519", typed: "", store: store, secrets: secrets) == "")
    }
}
