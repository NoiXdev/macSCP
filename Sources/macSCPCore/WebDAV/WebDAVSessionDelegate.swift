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

    /// Scheme, host and port together — the unit a credential belongs to.
    /// The password the user stored is for ONE server, and this is the
    /// identity of that server, so it is what an authentication challenge
    /// has to match before the password is handed over.
    struct Origin: Equatable, Sendable {
        let scheme: String
        let host: String
        let port: Int
    }

    private let username: String
    /// Warning: plaintext secret — never log, interpolate or persist it.
    private let password: String
    /// The origin of the configured base URL. `nil` when the base URL has
    /// no scheme, no host, or a scheme with no port this code knows — in
    /// which case no challenge matches and none is answered, which is the
    /// safe direction to fail.
    private let configuredOrigin: Origin?
    private let trustStore: TrustedCertificateStore
    private let decider: CertificateDecider

    private static let logger = Logger(
        subsystem: "dev.noix.macscp", category: "WebDAVSessionDelegate")

    private let lock = NSLock()
    private var certificateError: ServerCertificateError?
    private var credentialRejected = false
    private var bodyStreamRefusal: String?
    private var trustStoreWriteFailure: String?
    private var foreignChallenge: String?

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

    /// Set when the user accepted an unknown certificate but remembering it
    /// failed — see `decideCertificate` for why that does not fail the
    /// connection. Sticky for the life of the delegate, and deliberately
    /// separate from `certificateError`: this connection succeeded, and
    /// `WebDAVFileSystem.connect` reads that property as the reason one did
    /// not. Carries the host, the port and the store's own complaint, so a
    /// bug report can name what was not pinned; no secret is at stake, a
    /// server certificate is public material.
    public var lastTrustStoreWriteFailure: String? {
        lock.lock(); defer { lock.unlock() }
        return trustStoreWriteFailure
    }

    /// Set when a challenge — for a credential or for a certificate —
    /// arrived from an origin other than the configured one and was
    /// therefore refused. Carries both origins, scheme included, so the
    /// connect path can say what happened instead of reporting
    /// URLSession's cancellation.
    ///
    /// KNOWN GAP, recorded rather than closed: `WebDAVFileSystem.connect`
    /// is the only reader, so a foreign challenge raised during a LATER
    /// operation — a list, a PUT — is still refused and still logged, but
    /// the operation itself surfaces as a bare cancellation. Closing it
    /// means threading this state into every operation's error mapping,
    /// which is a wider change than the refusal itself; the refusal, which
    /// is the security-relevant half, holds everywhere.
    public var lastForeignChallenge: String? {
        lock.lock(); defer { lock.unlock() }
        return foreignChallenge
    }

    public init(baseURL: URL, username: String, password: String,
                trustStore: TrustedCertificateStore,
                decider: @escaping CertificateDecider) {
        self.username = username
        self.password = password
        self.configuredOrigin = Self.origin(of: baseURL)
        self.trustStore = trustStore
        self.decider = decider
    }

    /// The origin of a configured base URL. A base URL usually omits the
    /// port, so the scheme's default is filled in here — a challenge always
    /// names a port, and comparing one against `nil` would never match.
    /// An unknown scheme yields `nil` rather than a guessed port: nothing
    /// but http and https reaches `URLSession` as a WebDAV base anyway, and
    /// inventing a port for one would be inventing a match.
    static func origin(of url: URL) -> Origin? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(),
              !host.isEmpty
        else { return nil }
        let defaultPort: Int
        switch scheme {
        case "https": defaultPort = 443
        case "http": defaultPort = 80
        default: return nil
        }
        return Origin(scheme: scheme, host: host, port: url.port ?? defaultPort)
    }

    /// Whether an authentication challenge came from the very server the
    /// user configured. Scheme and host are compared case-insensitively
    /// (both are case-insensitive by definition); the port is compared
    /// exactly, after `origin(of:)` has filled in the scheme's default.
    ///
    /// A proxy challenge never matches. `URLSession` raises proxy
    /// authentication under the same Basic/Digest methods, and a proxy is
    /// by construction not the origin the password belongs to.
    static func challengeIsForConfiguredOrigin(
        _ space: URLProtectionSpace, configured: Origin?
    ) -> Bool {
        guard let configured, !space.isProxy() else { return false }
        guard let scheme = space.protocol?.lowercased() else { return false }
        return scheme == configured.scheme
            && space.host.lowercased() == configured.host
            && space.port == configured.port
    }

    /// The origin a certificate candidate belongs to. A candidate is only
    /// ever built from a completed TLS handshake, so its scheme is `https`
    /// by construction — which is also why a base URL of `http://host`
    /// never matches one: a TLS challenge for that host is a redirect's
    /// doing, not the user's.
    static func origin(of candidate: ServerCertificateCandidate) -> Origin {
        Origin(scheme: "https", host: candidate.host.lowercased(), port: candidate.port)
    }

    /// The TOFU decision, separated from the URLSession plumbing so it is
    /// testable without a network stack.
    func decideCertificate(_ candidate: ServerCertificateCandidate) async -> Bool {
        // A trust decision may only be ASKED, and a pin may only be
        // WRITTEN, for the origin the user configured. This function is
        // where both of those happen, which is why the check lives here
        // and not only at the challenge arm that calls it.
        //
        // The danger is not that a redirect target learns something — a
        // certificate is public material in both directions. It is that
        // the ATTACKER WRITES THE `Location` HEADER and therefore chooses
        // the host this runs for, including the configured host's own name
        // on 443. A pin is a state change that outlives the failed
        // connect: once one is written for a host, `ServerCertificateValidation`
        // sees a KNOWN certificate for it and `.mismatch` — this project's
        // hard stop — can never fire for that host again. So a plaintext
        // base URL, one injected redirect and one accepted prompt are
        // enough to plant a certificate that a later, correctly configured
        // https connect then accepts in silence.
        guard configuredOrigin == Self.origin(of: candidate) else {
            recordForeignCertificate(candidate)
            return false
        }
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
            // Recorded, not thrown — deliberately unlike the host-key
            // path, and for the same reason the file header already gives
            // for not copying its retry dance. In
            // `CitadelFileSystem.connectWithTOFURetries` this write is
            // load-bearing: accepting a host key reconnects from scratch and
            // re-reads the store, so a lost write leaves the reconnect
            // facing the same unknown key it just asked about — which is why
            // it throws `RemoteFSError.connectionFailed` there rather than
            // ask again. Here the handshake continues in place with the very
            // certificate the user just approved, so refusing the connection
            // would refuse a session that is exactly as trustworthy as the
            // user said it was.
            //
            // What IS lost is TOFU for this host: nothing was pinned, so
            // every later connect sees an unknown certificate and asks
            // again, and `.mismatch` — the hard stop this whole path exists
            // for — can never fire for a substituted one. Too quiet to leave
            // to a `try?`, hence a recorded condition plus a log line, the
            // same treatment `needNewBodyStream` gives a refused body
            // replay.
            //
            // The log splits its privacy where that one did not have to:
            // this message names the host and quotes Foundation's error,
            // which spells out the store's path and with it the account
            // name. The static half is `.public` so the line is findable;
            // the specifics stay `.private` and live in
            // `lastTrustStoreWriteFailure` for a bug report.
            do {
                try trustStore.upsert(TrustedCertificate(
                    host: candidate.host, port: candidate.port,
                    derBase64: candidate.derBase64, subject: candidate.subject,
                    issuer: candidate.issuer, notAfter: candidate.notAfter))
            } catch {
                recordTrustStoreWriteFailure(candidate: candidate, error: error)
            }
            return true
        }
    }

    private func recordTrustStoreWriteFailure(
        candidate: ServerCertificateCandidate, error: Error
    ) {
        let reason = "accepted certificate for \(candidate.host):\(candidate.port) "
            + "could not be remembered — \(error.localizedDescription); "
            + "this host will be asked about again on every connect"
        lock.lock()
        trustStoreWriteFailure = reason
        lock.unlock()
        Self.logger.error(
            """
            trusted-certificate store not writable; the accepted certificate \
            was not pinned and this host stays unpinned: \
            \(reason, privacy: .private)
            """)
    }

    private func setError(_ error: ServerCertificateError) {
        lock.lock(); defer { lock.unlock() }
        certificateError = error
    }

    private func setCredentialRejected() {
        lock.lock(); defer { lock.unlock() }
        credentialRejected = true
    }

    /// The credential half of the refusal.
    private func recordForeignChallenge(_ space: URLProtectionSpace) {
        let asked = Self.describe(scheme: space.protocol, host: space.host, port: space.port)
        let reason = space.isProxy()
            ? "an HTTP proxy at \(asked) asked for the WebDAV password; it was not sent"
            : "the login was challenged by \(asked) instead of the configured "
                + "\(configuredOriginText); the server redirected it elsewhere, "
                + "so the password was not sent"
        record(foreignChallenge: reason)
    }

    /// The certificate half of the same refusal. Worded around what was
    /// withheld rather than around the password, because nothing secret was
    /// at stake here — what was withheld is a trust decision and the pin
    /// that would have followed it.
    private func recordForeignCertificate(_ candidate: ServerCertificateCandidate) {
        recordForeignCertificate(scheme: "https", host: candidate.host, port: candidate.port)
    }

    private func recordForeignCertificate(scheme: String?, host: String, port: Int) {
        let asked = Self.describe(scheme: scheme, host: host, port: port)
        record(foreignChallenge:
            "a certificate was presented by \(asked) instead of the configured "
            + "\(configuredOriginText); the server redirected the connection elsewhere, "
            + "so the certificate was neither trusted nor remembered")
    }

    /// First refusal wins. The two arms cannot both fire in one `connect`
    /// — a refused TLS handshake never gets as far as a login challenge —
    /// but if that ever changed, the earlier refusal is the one that
    /// explains the later, and overwriting it would report the symptom.
    ///
    /// Logged as well as recorded: this is a credential or a trust decision
    /// the product deliberately withheld, which is worth a line whether or
    /// not anybody reads the connect error.
    ///
    /// Naming the origin that asked is the whole diagnostic value — "your
    /// server sent us somewhere else" is not actionable without the
    /// somewhere — and naming its SCHEME is what makes the two origins
    /// distinguishable when a redirect only upgrades the transport, where
    /// host and port alone would print the same name twice. It is the only
    /// server-influenced text in these messages, and it is a scheme, a host
    /// and a port that Foundation parsed out of a URL, not free-form
    /// server prose.
    private func record(foreignChallenge reason: String) {
        lock.lock()
        let alreadyRecorded = foreignChallenge != nil
        if !alreadyRecorded { foreignChallenge = reason }
        lock.unlock()
        guard !alreadyRecorded else { return }
        Self.logger.error("\(reason, privacy: .public)")
    }

    /// `scheme://host:port`, with the port always spelled out even when it
    /// is the scheme's default — the difference between the configured
    /// origin and the one that asked is exactly what these messages exist
    /// to show.
    private static func describe(scheme: String?, host: String, port: Int) -> String {
        "\(scheme?.lowercased() ?? "?")://\(host):\(port)"
    }

    private var configuredOriginText: String {
        guard let configuredOrigin else { return "server" }
        return Self.describe(scheme: configuredOrigin.scheme,
                             host: configuredOrigin.host, port: configuredOrigin.port)
    }

    // MARK: - URLSessionTaskDelegate

    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest:
            // A challenge is answered ONLY for the server the user typed
            // into the form. `URLSession` follows redirects on its own, and
            // it raises the redirect TARGET's challenge on this same
            // delegate — so without this guard any server that answers with
            // `302 Location: http://elsewhere/` is handed the user's WebDAV
            // password, and over plain http anyone on the path can inject
            // that redirect. The challenge carries no proof of who is
            // asking; the configured origin is the only thing that does.
            //
            // Refused unanswered rather than followed: there is no way to
            // ask the user mid-request whether this other server should get
            // their password, and answering silently is the leak itself.
            // The redirect is still followed — that part is URLSession's —
            // so the target sees the request, but never a credential.
            //
            // The match is strict on all three parts, which costs one real
            // convenience: a base URL of `http://host` whose server
            // upgrades to `https://host` now fails instead of logging in,
            // because the scheme and the port both moved. That is the right
            // trade for a redirect arriving over plaintext, and the refusal
            // names both origins, so the fix — configure the `https` URL —
            // is readable straight out of the error. A redirect that stays
            // within the origin (the usual `/dav` → `/dav/`) is unaffected.
            guard Self.challengeIsForConfiguredOrigin(
                challenge.protectionSpace, configured: configuredOrigin)
            else {
                recordForeignChallenge(challenge.protectionSpace)
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
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
            // Same rule as the credential arm, for a different reason. A
            // certificate is public, so nothing leaks here — but the TOFU
            // question and the pin that follows it are a state change, and
            // a redirect lets the server choose the host they are made
            // for. `decideCertificate` carries the argument in full.
            //
            // Checked here as well as there so a refusal costs no trust
            // evaluation and no prompt: this returns before the system
            // trust check below, which would otherwise silently accept a
            // foreign host whose chain happens to be valid.
            guard Self.challengeIsForConfiguredOrigin(
                challenge.protectionSpace, configured: configuredOrigin)
            else {
                recordForeignCertificate(
                    scheme: challenge.protectionSpace.protocol,
                    host: challenge.protectionSpace.host,
                    port: challenge.protectionSpace.port)
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
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
