import Foundation
import Testing
@testable import macSCPCore

@Suite("KnownHostsStore")
struct KnownHostsStoreTests {
    private func makeStore() -> (KnownHostsStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-\(UUID().uuidString)")
        return (KnownHostsStore(directory: dir), dir)
    }

    private let key = KnownHostKey(
        host: "example.com", port: 22,
        keyType: "ssh-ed25519", publicKeyBase64: "QUJDREVG")

    @Test func findOnEmptyStoreReturnsNil() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.find(host: "example.com", port: 22) == nil)
    }

    @Test func upsertPersistsAndFindsByHostAndPort() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.upsert(key)
        #expect(try store.find(host: "example.com", port: 22) == key)
        #expect(try store.find(host: "example.com", port: 2222) == nil)
    }

    @Test func upsertReplacesByHostPort() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.upsert(key)
        let rotated = KnownHostKey(
            host: "example.com", port: 22,
            keyType: "ssh-ed25519", publicKeyBase64: "TEVFUlpFSUxF")
        try store.upsert(rotated)
        #expect(try store.find(host: "example.com", port: 22)?.publicKeyBase64 == "TEVFUlpFSUxF")
    }

    @Test func fingerprintIsDerivedFromBlob() {
        // "QUJDREVG" == Base64("ABCDEF") — Fingerprint muss dem SHA256 davon entsprechen
        #expect(key.fingerprintSHA256 == HostKeyFingerprint.sha256(ofKeyBlobBase64: "QUJDREVG"))
    }
}
