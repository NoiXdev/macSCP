import Foundation
import Testing
@testable import macSCPCore

/// A challenge needs a sender; nothing here ever calls back through it.
private final class SilentChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

@Suite("WebDAVSessionDelegate")
struct WebDAVSessionDelegateTests {
    /// Drives the real delegate method with a synthesized challenge and
    /// reports what it answered. The task is created but never resumed —
    /// nothing is dialled.
    private func answer(
        _ delegate: WebDAVSessionDelegate, host: String, port: Int,
        scheme: String, method: String = NSURLAuthenticationMethodHTTPBasic,
        previousFailureCount: Int = 0
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = URLProtectionSpace(
            host: host, port: port, protocol: scheme, realm: "macSCP test",
            authenticationMethod: method)
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil,
            previousFailureCount: previousFailureCount, failureResponse: nil, error: nil,
            sender: SilentChallengeSender())
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "http://127.0.0.1:1/")!)
        var answered: (URLSession.AuthChallengeDisposition, URLCredential?)?
        delegate.urlSession(session, task: task, didReceive: challenge) { disposition, credential in
            answered = (disposition, credential)
        }
        return answered ?? (.performDefaultHandling, nil)
    }

    /// The plain-upgrade case, which is the one host and port alone cannot
    /// describe: a base URL of `http://nas.local` challenged from
    /// `https://nas.local:443`. Without the scheme the message reads
    /// "nas.local:443 instead of nas.local:80" — two names for what looks
    /// like the same server, and no hint that the fix is to configure the
    /// https URL.
    ///
    /// The second half is the disjointness the connect path's read order
    /// rests on: a refused challenge is never answered, so it can never
    /// produce the repeat that marks a credential rejected. That is why
    /// the order those two flags are read in cannot matter — pinned here
    /// rather than asserted in a comment.
    @Test func anUpgradedSchemeIsRefusedAndBothSchemesAreNamed() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = WebDAVSessionDelegate(
            baseURL: URL(string: "http://nas.local/dav")!,
            username: "u", password: "p", trustStore: store, decider: .asking { _ in true })

        let (disposition, credential) = answer(
            delegate, host: "nas.local", port: 443, scheme: "https")

        #expect(disposition == .cancelAuthenticationChallenge)
        #expect(credential == nil)
        let reason = try #require(delegate.lastForeignChallenge)
        #expect(reason.contains("https://nas.local:443"))
        #expect(reason.contains("http://nas.local:80"))
        #expect(delegate.credentialWasRejected == false)
    }

    /// The control, and the proof that the guard above is not simply
    /// refusing everything: the configured origin is answered, with the
    /// credential the user stored.
    @Test func theConfiguredOriginStillGetsTheCredential() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = WebDAVSessionDelegate(
            baseURL: URL(string: "https://nas.local/dav")!,
            username: "u", password: "p", trustStore: store, decider: .asking { _ in true })

        let (disposition, credential) = answer(
            delegate, host: "nas.local", port: 443, scheme: "https")

        #expect(disposition == .useCredential)
        #expect(credential?.user == "u")
        #expect(delegate.lastForeignChallenge == nil)
    }

    /// A certificate candidate for a host other than the configured one is
    /// refused without asking and without writing. The decider says YES to
    /// everything, so a pin would appear if the arm ran at all.
    @Test func aForeignCertificateCandidateIsNeitherAskedAboutNorPinned() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let asked = TestBox(false)
        let delegate = WebDAVSessionDelegate(
            baseURL: URL(string: "https://nas.local/dav")!,
            username: "u", password: "p", trustStore: store,
            decider: .asking { _ in asked.value = true; return true })

        let decision = await delegate.decideCertificate(ServerCertificateCandidate(
            host: "elsewhere.test", port: 443, derBase64: "QUJD",
            subject: "CN=elsewhere.test", issuer: "CN=elsewhere.test", notAfter: nil))

        #expect(decision == false)
        #expect(asked.value == false)
        #expect(try store.find(host: "elsewhere.test", port: 443) == nil)
        #expect(try store.allCertificates().isEmpty)
        let reason = try #require(delegate.lastForeignChallenge)
        #expect(reason.contains("https://elsewhere.test:443"))
        #expect(reason.contains("https://nas.local:443"))
    }

    /// The server-trust ARM guard, on its own.
    ///
    /// `decideCertificate` refuses a foreign candidate too, and the
    /// loopback test exercises both at once — so it passes with either one
    /// present and proves the pair rather than the parts. This one is
    /// specifically the arm guard, because the arm guard is what returns
    /// BEFORE the system-trust shortcut. Without it, a redirect target
    /// whose chain the system already trusts is answered with
    /// `performDefaultHandling` and the connection continues silently:
    /// `decideCertificate` is never consulted at all on that path, so its
    /// own guard cannot help. That is the half a user would never see.
    ///
    /// A synthesized protection space carries no `SecTrust`, so what is
    /// measured here is that the arm REFUSED AND RECORDED before reaching
    /// any trust handling — the recording is the only observable that
    /// distinguishes the guard from the `serverTrust == nil` path below it,
    /// which also cancels but says nothing.
    @Test func aForeignServerTrustChallengeIsRefusedByTheArmItself() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let asked = TestBox(false)
        let delegate = WebDAVSessionDelegate(
            baseURL: URL(string: "https://nas.local/dav")!,
            username: "u", password: "p", trustStore: store,
            decider: .asking { _ in asked.value = true; return true })

        let (disposition, credential) = answer(
            delegate, host: "elsewhere.test", port: 443, scheme: "https",
            method: NSURLAuthenticationMethodServerTrust)

        #expect(disposition == .cancelAuthenticationChallenge)
        #expect(credential == nil)
        #expect(asked.value == false)
        // The assertion that kills the mutation: with the arm guard gone
        // this is nil, because the fall-through cancels without recording.
        let reason = try #require(delegate.lastForeignChallenge)
        #expect(reason.contains("https://elsewhere.test:443"))
        #expect(reason.contains("https://nas.local:443"))
        #expect(try store.allCertificates().isEmpty)
    }

    /// The control for the test above, and the reason its assertion is
    /// about the RECORDING rather than the disposition: a challenge for the
    /// configured origin also cancels here — a synthesized space has no
    /// `SecTrust` to evaluate — but it must record nothing, because the arm
    /// guard let it through.
    @Test func aServerTrustChallengeForTheConfiguredOriginRecordsNoRefusal() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = WebDAVSessionDelegate(
            baseURL: URL(string: "https://nas.local/dav")!,
            username: "u", password: "p", trustStore: store, decider: .asking { _ in true })

        let (disposition, _) = answer(
            delegate, host: "nas.local", port: 443, scheme: "https",
            method: NSURLAuthenticationMethodServerTrust)

        #expect(disposition == .cancelAuthenticationChallenge)
        #expect(delegate.lastForeignChallenge == nil)
    }

    /// A base URL of `http://nas.local` means a TLS handshake for that host
    /// is somebody else's idea — the redirect that plants a certificate for
    /// the very name the user is about to configure. Same port, same host,
    /// refused on the scheme alone.
    @Test func aTLSCandidateForAPlaintextBaseURLIsRefused() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let asked = TestBox(false)
        let delegate = WebDAVSessionDelegate(
            baseURL: URL(string: "http://nas.local/dav")!,
            username: "u", password: "p", trustStore: store,
            decider: .asking { _ in asked.value = true; return true })

        let decision = await delegate.decideCertificate(ServerCertificateCandidate(
            host: "nas.local", port: 443, derBase64: "QUJD",
            subject: "CN=nas.local", issuer: "CN=nas.local", notAfter: nil))

        #expect(decision == false)
        #expect(asked.value == false)
        #expect(try store.allCertificates().isEmpty)
    }

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
            baseURL: URL(string: "https://nas.local")!,
            username: "u", password: "p", trustStore: store,
            decider: .asking { _ in asked.value = true; return true })

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
            baseURL: URL(string: "https://nas.local")!,
            username: "u", password: "p", trustStore: store, decider: .asking { _ in true })

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
            baseURL: URL(string: "https://nas.local")!,
            username: "u", password: "p", trustStore: store,
            decider: .asking { _ in false })

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
            baseURL: URL(string: "https://nas.local")!,
            username: "u", password: "p", trustStore: store,
            decider: .asking { _ in asked.value = true; return true })

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
            baseURL: URL(string: "https://nas.local")!,
            username: "u", password: "p", trustStore: store, decider: .asking { _ in true })
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
            baseURL: URL(string: "https://nas.local")!,
            username: "u", password: "p", trustStore: store, decider: .asking { _ in true })
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
/// Thread-safe box, shared across this target's suites: it lets a value
/// written by an escaping closure or produced on a background queue be
/// read back without tripping concurrency checking. Internal rather than
/// private so a suite that needs one does not grow its own copy under
/// another name — which had happened twice.
final class TestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
