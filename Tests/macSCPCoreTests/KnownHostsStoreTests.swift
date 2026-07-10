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
        // "QUJDREVG" == Base64("ABCDEF") — the fingerprint must match its SHA256
        #expect(key.fingerprintSHA256 == HostKeyFingerprint.sha256(ofKeyBlobBase64: "QUJDREVG"))
    }

    @Test func findIsCaseInsensitiveOnHost() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.upsert(key)   // host: "example.com"
        #expect(try store.find(host: "EXAMPLE.com", port: 22) == key)
    }

    @Test func upsertNormalizesHostCasing() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.upsert(KnownHostKey(
            host: "Server.Example.COM", port: 22,
            keyType: "ssh-ed25519", publicKeyBase64: "QUJDREVG"))
        let found = try store.find(host: "server.example.com", port: 22)
        #expect(found?.host == "server.example.com")
    }

    @Test func decodedMixedCaseHostStillMatches() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Fixture written straight to disk (simulates a legacy/hand-edited file):
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("""
        [{"host":"MyServer.Local","port":22,"keyType":"ssh-ed25519","publicKeyBase64":"QUJDREVG"}]
        """.utf8).write(to: dir.appendingPathComponent("known_hosts.json"))

        #expect(try store.find(host: "myserver.local", port: 22) != nil)
        #expect(try store.find(host: "MyServer.Local", port: 22) != nil)
    }
}
