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

    /// `hasPassphrase` means "the key file is encrypted". A key materialized
    /// from a login-set export that carried no secrets is encrypted and has NO
    /// Keychain slot — and the save paths must be able to tell, or they treat
    /// the (nonexistent) key.id slot as authoritative and drop the passphrase
    /// the user typed.
    @Test func anEncryptedKeyWithoutASlotIsNotAStoredPassphrase() throws {
        let store = tempStore()
        let secrets = InMemorySecretStore()
        let encryptedWithSlot = ManagedKey(
            name: "generated", comment: "", type: .ed25519, fingerprint: "SHA256:a",
            publicKeyOpenSSH: "ssh-ed25519 AAAA", createdAt: Date(),
            hasPassphrase: true, fileName: "with-slot")
        let encryptedWithoutSlot = ManagedKey(
            name: "imported", comment: "", type: .ed25519, fingerprint: "SHA256:b",
            publicKeyOpenSSH: "ssh-ed25519 BBBB", createdAt: Date(),
            hasPassphrase: true, fileName: "without-slot")
        let plain = ManagedKey(
            name: "plain", comment: "", type: .ed25519, fingerprint: "SHA256:c",
            publicKeyOpenSSH: "ssh-ed25519 CCCC", createdAt: Date(),
            hasPassphrase: false, fileName: "plain")
        try store.add(encryptedWithSlot)
        try store.add(encryptedWithoutSlot)
        try store.add(plain)
        try secrets.savePassword("stored-pp", for: encryptedWithSlot.id)

        func path(_ name: String) -> String {
            store.keyDirectory.appendingPathComponent(name).path
        }
        #expect(ManagedKeyPassphrase.hasStoredPassphrase(
            keyPath: path("with-slot"), store: store, secrets: secrets))
        #expect(!ManagedKeyPassphrase.hasStoredPassphrase(
            keyPath: path("without-slot"), store: store, secrets: secrets))
        #expect(!ManagedKeyPassphrase.hasStoredPassphrase(
            keyPath: path("plain"), store: store, secrets: secrets))
        // An external key path is nobody's managed key, so its passphrase
        // belongs in the session's/set's own slot too.
        #expect(!ManagedKeyPassphrase.hasStoredPassphrase(
            keyPath: "/Users/tim/.ssh/id_ed25519", store: store, secrets: secrets))
        // …and resolving still falls back to the typed value for the
        // slot-less key rather than inventing one.
        #expect(ManagedKeyPassphrase.resolve(
            keyPath: path("without-slot"), typed: "", store: store, secrets: secrets) == "")
    }

    /// An empty string in the slot is not a stored passphrase: sessions and
    /// login sets persist `""` for "no secret", and a stray empty write must
    /// not make the save paths believe the key is covered.
    @Test func anEmptySlotDoesNotCountAsAStoredPassphrase() throws {
        let store = tempStore()
        let secrets = InMemorySecretStore()
        let key = ManagedKey(
            name: "k", comment: "", type: .ed25519, fingerprint: "SHA256:x",
            publicKeyOpenSSH: "ssh-ed25519 AAAA", createdAt: Date(),
            hasPassphrase: true, fileName: "kf")
        try store.add(key)
        try secrets.savePassword("", for: key.id)

        #expect(!ManagedKeyPassphrase.hasStoredPassphrase(
            keyPath: store.keyDirectory.appendingPathComponent("kf").path,
            store: store, secrets: secrets))
    }
}
