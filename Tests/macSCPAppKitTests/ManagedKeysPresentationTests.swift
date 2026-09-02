import Foundation
import Testing
import macSCPCore
@testable import MacSCPAppKit

/// Covers what the SSH keys sheet and the two `keyPath` pickers are handed
/// before any view is involved: whether a read of `managed_keys.json`
/// yielded a list or failed, and which keys are offerable as a login.
///
/// It does not render `SSHKeysSheet`, so nothing here proves a message is
/// visible. What it proves is that the value the sheet decides on
/// distinguishes an empty store from an unreadable one, and that the picker
/// filter keeps the keys it should rather than always returning nothing.
@Suite("Managed keys presentation")
struct ManagedKeysPresentationTests {
    private func makeStore() -> (ManagedKeyStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-keys-app-\(UUID().uuidString)")
        return (ManagedKeyStore(directory: dir), dir)
    }

    /// `createdAt` carries no sub-second component on purpose: the store
    /// encodes dates as ISO8601, which has second resolution, so a `Date()`
    /// would not survive the round trip and `ManagedKey`'s `Equatable`
    /// compares it exactly. The failure that costs the most time is the one
    /// whose two sides PRINT identically -- the description rounds to
    /// seconds too.
    private func key(name: String, type: KeyType, fileName: String) -> ManagedKey {
        ManagedKey(
            name: name, comment: "", type: type, fingerprint: "SHA256:\(name)",
            publicKeyOpenSSH: "ssh-ed25519 AAAA \(name)",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            hasPassphrase: false, fileName: fileName)
    }

    @Test func aMissingStoreLoadsAsAnEmptyList() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let load = ManagedKeysLoad(reading: store)

        #expect(load == .loaded([]))
        #expect(!load.isUnreadable)
    }

    @Test func aStoredKeyLoads() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stored = key(name: "laptop", type: .ed25519, fileName: "id_ed25519")
        try store.add(stored)

        #expect(ManagedKeysLoad(reading: store) == .loaded([stored]))
    }

    /// The whole point: a file that exists and cannot be decoded is NOT an
    /// empty list. Nothing is lost in that state — `add` reads the file
    /// first and throws too, so no write lands on top of it — but the sheet
    /// used to say "No keys yet." over a store still holding every key.
    @Test func anUndecodableStoreIsUnreadableRatherThanEmpty() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8)
            .write(to: dir.appendingPathComponent("managed_keys.json"))

        let load = ManagedKeysLoad(reading: store)

        #expect(load == .unreadable)
        #expect(load.isUnreadable)
        #expect(load.keys.isEmpty)
    }

    /// Positive control for the two tests below: without it, a filter that
    /// always returned nothing would satisfy them both. Covers all three
    /// `KeyType` cases the loader can open (ed25519, RSA, ECDSA) — the
    /// positive half — beside the negative half, a key whose `fileName`
    /// escapes the key directory, which stays excluded regardless of type.
    @Test func everyLoadableKeyTypeWithAUsableFileNameIsOfferable() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ed25519Key = key(name: "laptop", type: .ed25519, fileName: "id_ed25519")
        let rsaKey = key(name: "server", type: .rsa(bits: 4096), fileName: "id_rsa")
        let ecdsaKey = key(name: "backup", type: .ecdsa, fileName: "id_ecdsa")
        try store.add(ed25519Key)
        try store.add(rsaKey)
        try store.add(ecdsaKey)
        try store.add(key(name: "escaping", type: .ed25519, fileName: "../outside"))

        #expect(ManagedKeysLoad.connectableKeys(in: store) == [ed25519Key, rsaKey, ecdsaKey])
    }

    @Test func nothingIsOfferableFromAnUnreadableStore() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8)
            .write(to: dir.appendingPathComponent("managed_keys.json"))

        #expect(ManagedKeysLoad.connectableKeys(in: store).isEmpty)
    }
}
