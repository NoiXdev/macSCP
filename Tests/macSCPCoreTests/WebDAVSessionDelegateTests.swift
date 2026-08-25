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

    /// The accept path writes the certificate and then keeps going: unlike
    /// the host-key path, the handshake is not restarted, so the connection
    /// succeeds whether or not the write did. What must not happen is the
    /// write failing invisibly — a certificate that was never pinned means
    /// every later connect sees it as unknown and asks again, so a
    /// substituted certificate can never reach `.mismatch`, the hard stop.
    @Test func acceptedCertificateThatCannotBeRememberedIsRecorded() async throws {
        // A directory path that is actually a FILE (the M9a pattern): the
        // store's `createDirectory` fails, so `upsert` throws. A real store
        // on a real unwritable path — the failure being tested lives in
        // Foundation's write, and a fake would only prove the fake's shape.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-deleg-blocked-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = TrustedCertificateStore(directory: file)

        let delegate = WebDAVSessionDelegate(
            username: "u", password: "p", trustStore: store, decider: { _ in true })
        #expect(delegate.lastTrustStoreWriteFailure == nil)

        let decision = await delegate.decideCertificate(
            ServerCertificateCandidate(
                host: "nas.local", port: 443, derBase64: "QUJD",
                subject: "CN=nas.local", issuer: "CN=nas.local", notAfter: nil))

        // The user approved this certificate, so the connection proceeds ...
        #expect(decision == true)
        // ... and must NOT be reported as a certificate failure: nothing
        // about the certificate itself went wrong, and `lastCertificateError`
        // is what the connect path reads as the reason a connect failed.
        #expect(delegate.lastCertificateError == nil)
        // ... but the lost pin is on the record, naming the host it was lost
        // for. Without this the store write is the only step in the TOFU
        // path that can fail without leaving a trace.
        let failure = try #require(delegate.lastTrustStoreWriteFailure)
        #expect(failure.contains("nas.local"))
        #expect(failure.contains("443"))
        // And nothing was pinned — that is the state the record describes.
        #expect(try store.allCertificates().isEmpty)
    }

    /// A WebDAV upload body is a single-use bound stream fed from a one-shot
    /// async sequence, so a replay request can only be refused. What must not
    /// happen is refusing it *silently*: URLSession then fails the task with
    /// an error that names no cause at all. The refusal is recorded (and
    /// logged) so the failure is diagnosable.
    @Test func bodyReplayIsRefusedAndRecorded() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = WebDAVSessionDelegate(
            username: "u", password: "p", trustStore: store, decider: { _ in true })
        #expect(delegate.lastBodyStreamRefusal == nil)

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://dav.example.com/dav/a.txt")!)
        request.httpMethod = "PUT"
        let task = session.dataTask(with: request)   // never resumed

        let handed = TestBox<InputStream?>(nil)
        let answered = TestBox(false)
        delegate.urlSession(session, task: task, needNewBodyStream: { stream in
            handed.value = stream
            answered.value = true
        })

        #expect(answered.value)
        #expect(handed.value == nil)
        let refusal = try #require(delegate.lastBodyStreamRefusal)
        #expect(refusal.contains("PUT"))
        #expect(refusal.contains("cannot be resent"))
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
