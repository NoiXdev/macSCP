import Foundation

/// The one place macOS offers everything WebDAV needs from below the request:
/// the authentication challenge (Basic and Digest, computed by URLSession
/// itself once we hand it a credential), the server-trust challenge, and the
/// body stream for a streaming upload.
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

    private let lock = NSLock()
    private var certificateError: ServerCertificateError?
    private var bodyStreams: [Int: InputStream] = [:]

    /// Set when a challenge was refused, so the connect path can report the
    /// precise cause instead of URLSession's generic cancellation.
    public var lastCertificateError: ServerCertificateError? {
        lock.lock(); defer { lock.unlock() }
        return certificateError
    }

    public init(username: String, password: String,
                trustStore: TrustedCertificateStore,
                decider: @escaping CertificateDecider) {
        self.username = username
        self.password = password
        self.trustStore = trustStore
        self.decider = decider
    }

    /// Registers the body stream a streaming PUT will hand back when
    /// URLSession asks for it (including on a retry after an auth challenge).
    public func attachBodyStream(_ stream: InputStream, for taskIdentifier: Int) {
        lock.lock(); defer { lock.unlock() }
        bodyStreams[taskIdentifier] = stream
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

    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void
    ) {
        lock.lock()
        let stream = bodyStreams[task.taskIdentifier]
        lock.unlock()
        completionHandler(stream)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        lock.lock(); defer { lock.unlock() }
        bodyStreams[task.taskIdentifier] = nil
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
