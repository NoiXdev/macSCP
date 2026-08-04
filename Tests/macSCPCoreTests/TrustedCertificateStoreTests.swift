import Foundation
import Testing
@testable import macSCPCore

@Suite("TrustedCertificateStore")
struct TrustedCertificateStoreTests {
    private func makeStore() throws -> (TrustedCertificateStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-certs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (TrustedCertificateStore(directory: directory), directory)
    }

    private func certificate(host: String = "nas.local", der: String = "QUJD") -> TrustedCertificate {
        TrustedCertificate(
            host: host, port: 5006, derBase64: der,
            subject: "CN=\(host)", issuer: "CN=\(host)", notAfter: nil)
    }

    @Test func findReturnsNilOnAnEmptyStore() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try store.find(host: "nas.local", port: 5006) == nil)
    }

    @Test func upsertThenFindRoundtrips() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.upsert(certificate())
        let found = try #require(try store.find(host: "nas.local", port: 5006))
        #expect(found.derBase64 == "QUJD")
    }

    /// Host lookup is case-insensitive, like the known-hosts store.
    @Test func hostLookupIgnoresCase() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.upsert(certificate(host: "NAS.Local"))
        #expect(try store.find(host: "nas.local", port: 5006) != nil)
    }

    /// Same host and port replaces rather than accumulating — otherwise a
    /// re-accepted certificate would leave the old one in the file and the
    /// next lookup could return either.
    @Test func upsertReplacesTheSameHostAndPort() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.upsert(certificate(der: "QUJD"))
        try store.upsert(certificate(der: "WFla"))
        #expect(try store.allCertificates().count == 1)
        #expect(try store.find(host: "nas.local", port: 5006)?.derBase64 == "WFla")
    }

    @Test func removeDeletesOnlyTheMatchingEntry() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.upsert(certificate(host: "a.local"))
        try store.upsert(certificate(host: "b.local"))
        try store.remove(host: "a.local", port: 5006)
        #expect(try store.allCertificates().map(\.host) == ["b.local"])
    }
}
