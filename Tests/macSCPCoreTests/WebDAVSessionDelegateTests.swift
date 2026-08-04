import Foundation
import Testing
@testable import macSCPCore

@Suite("WebDAVSessionDelegate")
struct WebDAVSessionDelegateTests {
    private func makeStore() throws -> (TrustedCertificateStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-deleg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (TrustedCertificateStore(directory: directory), directory)
    }

    /// A remembered certificate that no longer matches must be refused
    /// WITHOUT consulting the decider. The decider records whether it ran; if
    /// it did, the invariant is broken.
    @Test func mismatchRefusesWithoutAskingTheDecider() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.upsert(TrustedCertificate(
            host: "nas.local", port: 443, derBase64: "QUJD",
            subject: "CN=nas.local", issuer: "CN=nas.local", notAfter: nil))

        let asked = TestBox(false)
        let delegate = WebDAVSessionDelegate(
            username: "u", password: "p", trustStore: store,
            decider: { _ in asked.value = true; return true })

        let decision = await delegate.decideCertificate(
            ServerCertificateCandidate(
                host: "nas.local", port: 443, derBase64: "WFla",
                subject: "CN=nas.local", issuer: "CN=nas.local", notAfter: nil))

        #expect(decision == false)
        #expect(asked.value == false)
        guard case .mismatch = try #require(delegate.lastCertificateError) else {
            Issue.record("expected .mismatch")
            return
        }
    }

    @Test func unknownCertificateAsksAndRemembersOnConsent() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = WebDAVSessionDelegate(
            username: "u", password: "p", trustStore: store, decider: { _ in true })

        let decision = await delegate.decideCertificate(
            ServerCertificateCandidate(
                host: "nas.local", port: 443, derBase64: "QUJD",
                subject: "CN=nas.local", issuer: "CN=nas.local", notAfter: nil))

        #expect(decision == true)
        #expect(try store.find(host: "nas.local", port: 443)?.derBase64 == "QUJD")
    }

    /// Refusal must not write anything — otherwise a declined certificate
    /// would be silently trusted on the next attempt.
    @Test func refusedCertificateIsNotRemembered() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = WebDAVSessionDelegate(
            username: "u", password: "p", trustStore: store, decider: { _ in false })

        let decision = await delegate.decideCertificate(
            ServerCertificateCandidate(
                host: "nas.local", port: 443, derBase64: "QUJD",
                subject: "CN=nas.local", issuer: "CN=nas.local", notAfter: nil))

        #expect(decision == false)
        #expect(try store.allCertificates().isEmpty)
    }

    /// A corrupt trust store must fail closed WITHOUT being reported as a
    /// user refusal — otherwise whatever surfaces `lastCertificateError`
    /// would tell the user they rejected a certificate they were never
    /// shown.
    @Test func corruptTrustStoreFailsClosedWithoutAskingTheDecider() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "not valid json".write(
            to: directory.appendingPathComponent("trusted-certificates.json"),
            atomically: true, encoding: .utf8)

        let asked = TestBox(false)
        let delegate = WebDAVSessionDelegate(
            username: "u", password: "p", trustStore: store,
            decider: { _ in asked.value = true; return true })

        let decision = await delegate.decideCertificate(
            ServerCertificateCandidate(
                host: "nas.local", port: 443, derBase64: "QUJD",
                subject: "CN=nas.local", issuer: "CN=nas.local", notAfter: nil))

        #expect(decision == false)
        #expect(asked.value == false)
        guard case .trustStoreUnreadable = try #require(delegate.lastCertificateError) else {
            Issue.record("expected .trustStoreUnreadable, got \(String(describing: delegate.lastCertificateError))")
            return
        }
    }
}

/// Minimal mutable box for capturing a flag out of an escaping closure.
private final class TestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
