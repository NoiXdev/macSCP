import Foundation
import os

/// The one place macOS offers everything WebDAV needs from below the request:
/// the authentication challenge (Basic and Digest, computed by URLSession
/// itself once we hand it a credential) and the server-trust challenge.
///
/// The certificate decision may be answered asynchronously: unlike NIO's
/// promise-based host-key hook — which forced `CitadelFileSystem` into a
/// two-stage probe-and-reconnect — `URLSession` explicitly allows its
/// challenge completion handler to be called later. So the decider is simply
/// awaited. Do not copy the SSH retry dance here.
public final class WebDAVSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public typealias CertificateDecider = @Sendable (ServerCertificateCandidate) async -> Bool

    private let username: String
    /// Warning: plaintext secret — never log, interpolate or persist it.
    private let password: String
    private let trustStore: TrustedCertificateStore
    private let decider: CertificateDecider

    private static let logger = Logger(
        subsystem: "dev.noix.macscp", category: "WebDAVSessionDelegate")

    private let lock = NSLock()
    private var certificateError: ServerCertificateError?
    private var credentialRejected = false
    private var bodyStreamRefusal: String?

    /// Set when a challenge was refused, so the connect path can report the
    /// precise cause instead of URLSession's generic cancellation.
    public var lastCertificateError: ServerCertificateError? {
        lock.lock(); defer { lock.unlock() }
        return certificateError
    }

    /// Set when the server challenged a SECOND time for the same request,
    /// which is how URLSession reports that the credential this delegate
    /// supplied was rejected.
    ///
    /// It has to be recorded rather than derived from the request's own
    /// error, because refusing the repeated challenge is what makes
    /// URLSession abandon the request: the caller sees `NSURLErrorCancelled`
    /// and nothing else. There is no response to read, so `mapStatus` never
    /// sees the 401 that caused all this — without this flag, a mistyped
    /// password reads as "cancelled".
    public var credentialWasRejected: Bool {
        lock.lock(); defer { lock.unlock() }
        return credentialRejected
    }

    /// Set when URLSession asked to replay a request body and was refused —
    /// see `needNewBodyStream`. Sticky for the life of the session, and
    /// deliberately not folded into any single request's thrown error: one
    /// delegate serves every concurrent request on the connection, so it
    /// cannot attribute a refusal to a particular one without misreporting
    /// somebody else's failure. It exists to name the cause in a bug report,
    /// alongside the log line.
    public var lastBodyStreamRefusal: String? {
        lock.lock(); defer { lock.unlock() }
        return bodyStreamRefusal
    }

    public init(username: String, password: String,
                trustStore: TrustedCertificateStore,
                decider: @escaping CertificateDecider) {
        self.username = username
        self.password = password
        self.trustStore = trustStore
        self.decider = decider
    }

    /// The TOFU decision, separated from the URLSession plumbing so it is
    /// testable without a network stack.
    func decideCertificate(_ candidate: ServerCertificateCandidate) async -> Bool {
        let known: TrustedCertificate?
        do {
            known = try trustStore.find(host: candidate.host, port: candidate.port)
        } catch {
            // Store unreadable → fail closed. Treating it as "unknown" would
            // silently re-TOFU and overwrite a remembered certificate. This
            // is not a user refusal — keep the two distinguishable so
            // whatever surfaces the error doesn't misreport a corrupt store
            // as a certificate the user declined.
            setError(.trustStoreUnreadable(reason: "trust store read failed"))
            return false
        }

        switch ServerCertificateValidation.evaluate(candidate: candidate, known: known) {
        case .accept:
            return true
        case .mismatch(let expected):
            setError(.mismatch(host: candidate.host, expected: expected,
                               presented: candidate.fingerprintSHA256))
            return false
        case .askUser:
            guard await decider(candidate) else {
                setError(.rejectedByUser)
                return false
            }
            try? trustStore.upsert(TrustedCertificate(
                host: candidate.host, port: candidate.port,
                derBase64: candidate.derBase64, subject: candidate.subject,
                issuer: candidate.issuer, notAfter: candidate.notAfter))
            return true
        }
    }

    private func setError(_ error: ServerCertificateError) {
        lock.lock(); defer { lock.unlock() }
        certificateError = error
    }

    private func setCredentialRejected() {
        lock.lock(); defer { lock.unlock() }
        credentialRejected = true
    }

    // MARK: - URLSessionTaskDelegate

    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest:
            // Repeated challenge means the credential was rejected — answering
            // again would loop.
            guard challenge.previousFailureCount == 0 else {
                // Recorded BEFORE cancelling: cancelling is what destroys the
                // evidence, since URLSession then reports the request as
                // cancelled rather than as the 401 it actually got.
                setCredentialRejected()
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            // URLSession computes the Digest response itself from this
            // credential: nonce, qop, nonce count and stale renewal included.
            completionHandler(.useCredential,
                              URLCredential(user: username, password: password,
                                            persistence: .forSession))

        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust,
                  let candidate = Self.candidate(from: trust,
                                                 host: challenge.protectionSpace.host,
                                                 port: challenge.protectionSpace.port)
            else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            // A chain the system already trusts never reaches TOFU.
            if SecTrustEvaluateWithError(trust, nil) {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            Task {
                if await self.decideCertificate(candidate) {
                    completionHandler(.useCredential, URLCredential(trust: trust))
                } else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// URLSession asks for this when it wants to send a request body a second
    /// time. A WebDAV PUT body cannot be replayed, and this is not a gap to
    /// be filled later: the body is the `InputStream` half of a
    /// `Stream.getBoundStreams` pair, which is single-use, and it was fed
    /// from a one-shot `AsyncThrowingStream` that has already been consumed.
    /// Neither can be rewound — the bytes are gone.
    ///
    /// So the answer is always `nil`, and URLSession fails the task with an
    /// error that says nothing about why. Recording and logging the refusal
    /// is what turns that into something diagnosable.
    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void
    ) {
        let reason = "URLSession asked to replay the request body of "
            + "\(task.originalRequest?.httpMethod ?? "?"); a WebDAV upload body "
            + "is a single-use stream and cannot be resent"
        lock.lock()
        bodyStreamRefusal = reason
        lock.unlock()
        Self.logger.error("\(reason, privacy: .public)")
        completionHandler(nil)
    }

    private static func candidate(
        from trust: SecTrust, host: String, port: Int
    ) -> ServerCertificateCandidate? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        let subject = (SecCertificateCopySubjectSummary(leaf) as String?) ?? "?"
        return ServerCertificateCandidate(
            host: host, port: port, derBase64: der.base64EncodedString(),
            subject: subject, issuer: subject, notAfter: nil)
    }
}
