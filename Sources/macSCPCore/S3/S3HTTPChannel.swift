import Foundation

/// One way out to the network for `S3FileSystem`: a transport, the redirect
/// policy of the session behind it, and the two ways to end that session.
///
/// A connection holds one for its whole life and cancels it in
/// `disconnect()`. A multipart abort gets one of its OWN (final review I1 of
/// the 2026-09-19 plan): an abort that went out on the connection's channel
/// was cancelled by the `disconnect()` that follows a failed upload within
/// milliseconds — a tab's teardown, ⌘Q, the command line's exit — and left an
/// incomplete upload behind that the account is billed for. An abort's
/// channel is ended with `finish()` once the abort was answered or given up,
/// which lets a request still in flight complete rather than cancelling it.
///
/// `Sendable` by construction: every stored property is immutable and
/// `Sendable` — the transport by `HTTPTransport`'s own requirement, the
/// delegate by its `@unchecked` argument, the two closures by type.
struct S3HTTPChannel: S3AbortChannel {
    let transport: any HTTPTransport
    /// The delegate that decides every redirect on the session behind
    /// `transport`, or `nil` for a borrowed transport — whose session's
    /// policy, if it has one, is the caller's business.
    let redirectPolicy: S3RedirectSessionDelegate?
    /// Ends the channel now, cancelling whatever it still carries.
    let cancel: @Sendable () -> Void
    /// Ends the channel once whatever it still carries has finished.
    private let finishing: @Sendable () -> Void

    init(
        transport: any HTTPTransport, redirectPolicy: S3RedirectSessionDelegate?,
        cancel: @escaping @Sendable () -> Void, finish: @escaping @Sendable () -> Void
    ) {
        self.transport = transport
        self.redirectPolicy = redirectPolicy
        self.cancel = cancel
        self.finishing = finish
    }

    /// A session of its own, the only way this project builds one for S3:
    /// `URLSessionConfiguration.ephemeral`, so no dial shares a cache with
    /// another dial or another process (`S3SessionIsolationTests`), carrying
    /// `S3RedirectSessionDelegate`, which re-signs a redirect inside the
    /// endpoint's origin with `config` and refuses one that leaves it. The
    /// connection and every abort get their session from here, so an abort
    /// is signed with the same credentials under the same redirect policy.
    static func ownSession(for config: S3ConnectionConfig) -> S3HTTPChannel {
        let redirectPolicy = S3RedirectSessionDelegate(config: config)
        let session = URLSession(
            configuration: .ephemeral, delegate: redirectPolicy, delegateQueue: nil)
        return S3HTTPChannel(
            transport: URLSessionHTTPTransport(session: session), redirectPolicy: redirectPolicy,
            cancel: { session.invalidateAndCancel() },
            finish: { session.finishTasksAndInvalidate() })
    }

    /// An injected transport. Its session belongs to whoever injected it, so
    /// ending the channel ends nothing — the arrangement `WebDAVFileSystem`
    /// has for its own injected transport.
    static func borrowing(_ transport: any HTTPTransport) -> S3HTTPChannel {
        S3HTTPChannel(transport: transport, redirectPolicy: nil, cancel: {}, finish: {})
    }

    /// `S3AbortChannel.finish`.
    func finish() { finishing() }

    /// Every buffered request goes through here, so the transport-error
    /// mapping exists once instead of once per call site — and so a redirect
    /// the session's delegate refused is reported as what it was.
    ///
    /// A refusal is not an error at the `URLSession` level: declining to
    /// follow leaves the 3xx response to be delivered as if the endpoint had
    /// answered it, so without this every caller would report "S3 request
    /// failed with HTTP status 302" and no reader would learn that their
    /// endpoint tried to send them elsewhere. Checked on both outcomes
    /// because a refusal can also precede a genuine transport failure — a
    /// declined redirect whose 3xx body then fails to arrive.
    ///
    /// A cancelled request is the exception, and is read first: it reaches
    /// the caller as a `CancellationError` (`HTTPCancellation`), so a user's
    /// Cancel reads as cancelled rather than as a lost connection — and
    /// rather than as a refused redirect, which is sticky for the session's
    /// life and would otherwise explain every later Cancel too.
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let result = try await transport.send(request)
            if let refused = refusedRedirect() { throw refused }
            return result
        } catch let error as RemoteFSError {
            throw error
        } catch {
            if let cancellation = HTTPCancellation.cancellation(in: error) { throw cancellation }
            if let refused = refusedRedirect() { throw refused }
            throw RemoteFSError.connectionFailed(reason: "S3 request failed: \(error.localizedDescription)")
        }
    }

    /// The redirect this channel's session refused, as the error to report
    /// instead of whatever the refusal left behind. Always `nil` for a
    /// borrowed transport, which carries no policy of ours.
    func refusedRedirect() -> RemoteFSError? {
        redirectPolicy?.lastRefusedRedirect.map { RemoteFSError.connectionFailed(reason: $0) }
    }
}
