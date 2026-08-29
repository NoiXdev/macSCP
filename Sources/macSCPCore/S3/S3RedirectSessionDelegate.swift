import Foundation
import os

/// The S3 dial's answer to "your endpoint wants to send this request
/// somewhere else". It asks `S3RedirectDecision` and carries out the answer:
/// a same-origin target is rebuilt through the signing path and followed, a
/// foreign one is refused and recorded.
///
/// **Deliberately not `WebDAVSessionDelegate`, and deliberately not a shared
/// base.** That one is also a `URLSessionTaskDelegate`, but it answers a
/// different question — credentials and certificates — and the two share
/// nothing beyond the protocol's shape. Folding them together would put two
/// policies in one type so that a change to either has to be read against
/// the other.
///
/// This delegate could not exist before 2026-08-29: S3 ran on
/// `URLSession.shared`, which cannot carry a delegate, so there was no
/// redirect control in that path at all. The dial builds its own ephemeral
/// session now, and this rides on it.
///
/// `@unchecked Sendable` for the same reason `WebDAVSessionDelegate` is: the
/// one piece of mutable state is a recorded refusal behind an `NSLock`.
final class S3RedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let config: S3ConnectionConfig

    private static let logger = Logger(
        subsystem: "dev.noix.macscp", category: "S3RedirectSessionDelegate")

    private let lock = NSLock()
    private var refusal: String?

    /// The sentence describing a redirect this delegate refused, or `nil` if
    /// none was.
    ///
    /// It has to be recorded rather than derived from the request's own
    /// outcome, because refusing a redirect is not an error at the
    /// `URLSession` level: the 3xx response is handed to the caller as if
    /// the endpoint had answered it, so the request reads as a plain
    /// "HTTP status 302" and nothing says a redirect was declined. Same
    /// arrangement, and the same reason, as
    /// `WebDAVSessionDelegate.lastForeignChallenge`.
    ///
    /// Sticky for the life of the delegate, and first refusal wins: the
    /// first one is what explains any that follow.
    var lastRefusedRedirect: String? {
        lock.lock(); defer { lock.unlock() }
        return refusal
    }

    /// Holds the endpoint's credentials because re-signing is the whole
    /// point: it signs the redirect's own target the way the first request
    /// was signed. Warning: `config` carries the secret access key — never
    /// log, interpolate or persist it.
    init(config: S3ConnectionConfig) {
        self.config = config
    }

    // MARK: - URLSessionTaskDelegate

    /// Answering with `nil` is what refuses: `URLSession` then stops
    /// following and delivers the redirect response itself, which
    /// `S3FileSystem` turns into the recorded sentence rather than into the
    /// bare status.
    ///
    /// Every redirect status runs through the same decision. 301/302/303
    /// rewrite the method to GET and 307/308 preserve it; that is
    /// Foundation's behaviour and it stays Foundation's, so what gets
    /// signed here is the method of the request that is actually about to
    /// be made.
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // The origin being left is the one that ANSWERED, not the one first
        // asked: a chain of same-origin hops is judged hop by hop, so a
        // second redirect is compared against where the first one landed.
        let current = response.url ?? task.currentRequest?.url ?? task.originalRequest?.url
        guard let current, let target = request.url else {
            record("an S3 redirect with no readable source or target was refused")
            completionHandler(nil)
            return
        }

        let decision = S3RedirectDecision.decide(from: current, to: target)
        guard decision == .reSignAndFollow else {
            if let message = decision.refusalMessage { record(message) }
            completionHandler(nil)
            return
        }

        let method = request.httpMethod ?? task.originalRequest?.httpMethod ?? "GET"
        // A body that only exists as a stream cannot be read twice, so a
        // request needing one cannot be reproduced — and a signature over
        // bytes that will not be resent is worse than a refusal. The S3
        // path builds no such body today (every one is a `Data` in memory
        // or absent), which is the assumption `S3RequestSigning.reSigned`
        // records; this is where a future streaming upload would announce
        // itself instead of silently signing the wrong thing.
        if request.httpBodyStream != nil || task.originalRequest?.httpBodyStream != nil {
            record("an S3 redirect was refused: the request body is a stream and cannot be resent")
            completionHandler(nil)
            return
        }

        do {
            let signed = try S3RequestSigning.reSigned(
                target: target, method: method, body: Self.body(for: method, request, task),
                signedHeaders: Self.carriedSignedHeaders(method: method, task: task),
                unsignedHeaders: Self.carriedUnsignedHeaders(task: task),
                config: config)
            completionHandler(signed)
        } catch {
            record("an S3 redirect could not be re-signed and was refused: "
                + error.localizedDescription)
            completionHandler(nil)
        }
    }

    /// The body of the request that is about to be made. A redirect that
    /// rewrote the method to GET has no body; one that preserved it keeps
    /// the bytes of the original.
    private static func body(
        for method: String, _ proposed: URLRequest, _ task: URLSessionTask
    ) -> Data? {
        guard !Self.bodylessMethods.contains(method.uppercased()) else { return nil }
        return proposed.httpBody ?? task.originalRequest?.httpBody
    }

    private static let bodylessMethods: Set<String> = ["GET", "HEAD"]

    /// The headers the first request had signed beyond the ones the signer
    /// produces for itself — `x-amz-copy-source` for a server-side copy,
    /// `Content-MD5` for a `DeleteObjects` batch, `Content-Type` — carried
    /// into the new signature.
    ///
    /// The signer's own output (`x-amz-date`, `x-amz-content-sha256`,
    /// `x-amz-security-token`) is deliberately NOT carried: it is computed
    /// fresh for the new target, and copying it would put a stale timestamp
    /// and a payload hash for the old body into the new canonical request.
    ///
    /// Carried only while the method survives the redirect. 301/302/303
    /// rewrite the request to a GET, and a GET carrying a copy source or a
    /// checksum for a body it no longer has is not the same request under a
    /// new name.
    private static func carriedSignedHeaders(
        method: String, task: URLSessionTask
    ) -> [String: String] {
        guard method.uppercased() == task.originalRequest?.httpMethod?.uppercased() else {
            return [:]
        }
        let headers = task.originalRequest?.allHTTPHeaderFields ?? [:]
        return headers.filter { name, _ in
            let lowered = name.lowercased()
            if signerOwnedHeaders.contains(lowered) { return false }
            return lowered.hasPrefix("x-amz-") || lowered == "content-md5"
                || lowered == "content-type"
        }
    }

    private static let signerOwnedHeaders: Set<String> = [
        "x-amz-date", "x-amz-content-sha256", "x-amz-security-token",
    ]

    /// `Range` is set on a download request AFTER it is signed, on purpose —
    /// AWS does not require it to be signed — so it is carried the same way
    /// here, outside the signature, rather than quietly becoming a signed
    /// header on the second hop.
    private static func carriedUnsignedHeaders(task: URLSessionTask) -> [String: String] {
        let headers = task.originalRequest?.allHTTPHeaderFields ?? [:]
        return headers.filter { $0.key.lowercased() == "range" }
    }

    /// Recorded and logged: a redirect this product declined to follow is
    /// worth a line whether or not anybody reads the error it produces. The
    /// text is `.public` — it names two origins that Foundation parsed out
    /// of URLs, and no path, no query and no credential.
    private func record(_ reason: String) {
        lock.lock()
        let alreadyRecorded = refusal != nil
        if !alreadyRecorded { refusal = reason }
        lock.unlock()
        guard !alreadyRecorded else { return }
        Self.logger.error("\(reason, privacy: .public)")
    }
}
