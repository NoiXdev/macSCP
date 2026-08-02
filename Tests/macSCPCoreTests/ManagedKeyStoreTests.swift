import Foundation
import Testing
@testable import macSCPCore

@Suite("ManagedKeyStore")
struct ManagedKeyStoreTests {
    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-keystore-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sampleKey(fileName: String = "k1") -> ManagedKey {
        ManagedKey(
            name: "laptop", comment: "c", type: .ed25519, fingerprint: "SHA256:abc",
            publicKeyOpenSSH: "ssh-ed25519 AAAA c", createdAt: Date(timeIntervalSince1970: 0),
            hasPassphrase: true, fileName: fileName)
    }

    @Test func addAllRoundtripsAndJSONHasNoSecret() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ManagedKeyStore(directory: dir)
        let key = sampleKey()
        try store.add(key)
        #expect(try store.all() == [key])

        let json = try String(
            contentsOf: dir.appendingPathComponent("managed_keys.json"), encoding: .utf8)
        #expect(!json.contains("BEGIN OPENSSH PRIVATE KEY"))
    }

    @Test func keyForPathMatchesByFileNameInKeyDir() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ManagedKeyStore(directory: dir)
        let key = sampleKey(fileName: "abc123")
        try store.add(key)

        let managedPath = store.keyDirectory.appendingPathComponent("abc123").path
        #expect(try store.key(forPath: managedPath) == key)
        #expect(try store.key(forPath: "/Users/tim/.ssh/id_ed25519") == nil)
    }

    @Test func removeDeletesFilesAndKeychainSlot() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ManagedKeyStore(directory: dir)
        try FileManager.default.createDirectory(
            at: store.keyDirectory, withIntermediateDirectories: true)
        let priv = store.keyDirectory.appendingPathComponent("abc123")
        let pub = store.keyDirectory.appendingPathComponent("abc123.pub")
        try Data("priv".utf8).write(to: priv)
        try Data("pub".utf8).write(to: pub)

        let key = sampleKey(fileName: "abc123")
        try store.add(key)
        let secrets = InMemorySecretStore()
        try secrets.savePassword("s3cr3t", for: key.id)

        try store.remove(id: key.id, secrets: secrets)

        #expect(try store.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: priv.path))
        #expect(!FileManager.default.fileExists(atPath: pub.path))
        #expect(try secrets.password(for: key.id) == nil)

        // Removing the same id again must not throw and must leave the store empty.
        try store.remove(id: key.id, secrets: secrets)
        #expect(try store.all().isEmpty)
    }

    /// `fileName` is always a UUID that macSCP wrote itself, so this can only
    /// be reached through a hand-edited or tampered `managed_keys.json`. It
    /// is still worth closing: `appendingPathComponent("../…")` builds a URL
    /// OUTSIDE the key directory, and everything that resolves a managed key
    /// to a file would then follow it there — reading or deleting a file the
    /// key store does not own.
    @Test func aFileNameThatEscapesTheKeyDirectoryResolvesToNothing() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ManagedKeyStore(directory: dir)
        let outsider = dir.appendingPathComponent("outsider")
        try Data("not the key store's file".utf8).write(to: outsider)

        let key = sampleKey(fileName: "../outsider")
        try store.add(key)

        #expect(store.privateKeyURL(for: key) == nil)
        // The escaped path resolves to the planted file, and must NOT match.
        let escaped = store.keyDirectory.appendingPathComponent("../outsider")
            .standardizedFileURL.path
        #expect(escaped == outsider.standardizedFileURL.path)
        #expect(try store.key(forPath: escaped) == nil)

        // `remove` drops the metadata entry but must not delete outside the
        // key directory on the way.
        try store.remove(id: key.id, secrets: InMemorySecretStore())
        #expect(try store.all().isEmpty)
        #expect(FileManager.default.fileExists(atPath: outsider.path))
    }

    /// The same guard for the shapes that are not `../`: an empty name, a
    /// dot, and an absolute-looking one.
    @Test func onlyASinglePathComponentResolvesToAKeyFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ManagedKeyStore(directory: dir)
        for bad in ["", ".", "..", "sub/dir", "/etc/passwd"] {
            #expect(
                store.privateKeyURL(for: sampleKey(fileName: bad)) == nil,
                "fileName \"\(bad)\" must not resolve to a key file")
        }
        let good = try #require(store.privateKeyURL(for: sampleKey(fileName: "abc123")))
        #expect(good == store.keyDirectory.appendingPathComponent("abc123"))
    }
}
