import Foundation

/// WebDAV backend (M21). Third implementation of `RemoteFileSystem`, and the
/// first with real directories and atomic rename — the two capability axes S3
/// leaves false.
public final class WebDAVFileSystem: RemoteFileSystem, @unchecked Sendable {
    private let base: WebDAVURL
    private let transport: any HTTPTransport
    private let session: URLSession?

    /// Test seam: inject a transport, skip the network entirely.
    init(config: WebDAVConnectionConfig, transport: any HTTPTransport) {
        self.base = WebDAVURL(
            baseURL: URL(string: config.baseURL) ?? URL(string: "https://invalid.invalid")!,
            nextcloudUser: config.useNextcloudPath ? config.username : nil)
        self.transport = transport
        self.session = nil
    }

    private init(base: WebDAVURL, transport: any HTTPTransport, session: URLSession) {
        self.base = base
        self.transport = transport
        self.session = session
    }

    /// Builds the delegate-bearing session, verifies the credentials with a
    /// `Depth: 0` PROPFIND on the root, and returns a connected file system.
    public static func connect(
        _ config: WebDAVConnectionConfig,
        trustStore: TrustedCertificateStore,
        decider: WebDAVSessionDelegate.CertificateDecider
    ) async throws -> WebDAVFileSystem {
        guard let url = URL(string: config.baseURL), url.scheme != nil, url.host() != nil else {
            throw RemoteFSError.connectionFailed(reason: "WebDAV base URL is not a valid URL")
        }
        let delegate = WebDAVSessionDelegate(
            baseURL: url, username: config.username, password: config.password,
            trustStore: trustStore, decider: decider)
        let configuration = URLSessionConfiguration.ephemeral
        // The server-trust challenge is answered INSIDE this request's
        // lifetime, by `decider`, which for an unknown certificate suspends
        // until a human compares a SHA-256 fingerprint against, say, a NAS
        // admin page they have to go open first. The default 60s
        // `timeoutIntervalForRequest` races that: reading and comparing a
        // fingerprint routinely takes over a minute, and a `stat("/")` that
        // times out while the user is still looking surfaces as a generic
        // `NSURLErrorTimedOut` with no indication that the certificate was
        // in fact accepted (it gets written to the trust store regardless,
        // so the NEXT attempt silently works — which makes the timeout look
        // like a flake rather than what it is). Five minutes comfortably
        // outlasts that reading time without masking a genuinely dead
        // connection for an unreasonable while. Do not "simplify" this back
        // to the default — that reintroduces exactly this race.
        configuration.timeoutIntervalForRequest = 300
        // `timeoutIntervalForResource` (the cap on a single request's total
        // duration, including a slow upload) is left at its default, which
        // is already 7 days — ample for even a very large, very slow
        // transfer, so there is nothing to raise here.
        let session = URLSession(
            configuration: configuration, delegate: delegate, delegateQueue: nil)
        let base = WebDAVURL(
            baseURL: url, nextcloudUser: config.useNextcloudPath ? config.username : nil)
        let fs = WebDAVFileSystem(
            base: base, transport: URLSessionHTTPTransport(session: session), session: session)

        do {
            _ = try await fs.stat(path: "/")
        } catch {
            session.invalidateAndCancel()
            // A refused or mismatched certificate surfaces as a generic
            // cancellation from URLSession; report the precise cause instead.
            if let certificateError = delegate.lastCertificateError {
                throw certificateError
            }
            // A challenge from somewhere other than the configured server
            // was refused unanswered, so the request died the same
            // `NSURLErrorCancelled` death a rejected password does — but it
            // is not a rejected password, and reporting it as one would
            // send the user off to check credentials that were never sent.
            // The delegate's own sentence names both origins instead.
            //
            // The order these two are read in cannot matter: a refused
            // challenge is never answered, so it can never produce the
            // repeat that marks a credential rejected, and the two flags
            // therefore describe disjoint outcomes. That disjointness is
            // the load-bearing part, so it is pinned by a test rather than
            // claimed here — see `WebDAVSessionDelegateTests`.
            if let foreignChallenge = delegate.lastForeignChallenge {
                throw RemoteFSError.connectionFailed(reason: foreignChallenge)
            }
            // A rejected password is the same story as a refused
            // certificate, one layer over: the delegate declines the
            // repeated challenge, URLSession abandons the request, and what
            // arrives here is `NSURLErrorCancelled` -- so `mapStatus` never
            // sees the 401 and the honest `authenticationFailed` it would
            // have produced. Asking the delegate what it did is the only
            // way to tell a mistyped password from a cancelled request.
            if delegate.credentialWasRejected {
                throw RemoteFSError.authenticationFailed
            }
            // Everything else goes through the same wrap every other
            // operation on this backend uses -- see `surfaceable(_:)`, which
            // is where the reasoning for it lives.
            throw Self.surfaceable(error)
        }
        return fs
    }

    // MARK: - The network boundary

    /// Turns a foreign error from the network into one this app can put in
    /// front of a user, and is the ONLY thing in this file that talks to
    /// `transport`.
    ///
    /// **Why every call goes through here.** `WebDAVURL` builds every
    /// request from `baseURL.absoluteString`, and `WebDAVFieldSchema
    /// .makeConfig` accepts a base URL with a `user:password@` component --
    /// it checks for "not empty" and trims, nothing more. So the password
    /// is in the URL of EVERY request, not just the first one.
    ///
    /// An `NSError`'s `description` prints its entire `userInfo`, and
    /// Foundation puts the failing URL in there under
    /// `NSErrorFailingURLStringKey`, verbatim, userinfo component included.
    /// Measured against a dead loopback port: the secret is present in
    /// `String(describing:)` and absent from `localizedDescription`. The
    /// reachable sinks all stringify: the CLI's stderr fallback, the
    /// transfer-failure text and the browse-error text. No attacker is
    /// needed to reach them -- a timeout, a DNS failure or a dropped
    /// connection during an ordinary session is enough.
    ///
    /// Round 1 of this fix wrapped `connect` alone, which left `list`,
    /// `stat`, `readStream`, `delete`, `createDirectory` and `rename`
    /// handing the raw `URLError` through. Wrapping at the transport
    /// boundary instead of at each operation is deliberate: a seventh
    /// operation added later gets this for free, and "which methods
    /// remembered to wrap" stops being a thing anyone has to know.
    ///
    /// Two kinds of error pass through unchanged, and both are the app's
    /// own vocabulary rather than the network's: `RemoteFSError`, already
    /// mapped and already safe, and `CancellationError`, which the transfer
    /// queue distinguishes from a failure and would report as one if it
    /// were wrapped.
    static func surfaceable(_ error: Error) -> Error {
        if let fsError = error as? RemoteFSError { return fsError }
        if error is CancellationError { return error }
        // `localizedDescription` is the localized sentence alone ("Could
        // not connect to the server."), which carries no URL and no
        // dictionary whose keys Foundation, not macSCP, decides.
        //
        // Second effect, not a side effect: an unwrapped rethrow reaches
        // `ConnectionViewModel.failedState`'s catch-all arm, so an ordinary
        // WebDAV network failure read "Unexpected error: <NSError dump>"
        // instead of the connection-failure text every other backend
        // produces for the same condition.
        return RemoteFSError.connectionFailed(reason: error.localizedDescription)
    }

    /// `transport.send`, with the wrap above. Every request in this file
    /// goes through this rather than through `transport` directly.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch {
            throw Self.surfaceable(error)
        }
    }

    /// `transport.sendStreaming`, with the wrap above applied BOTH to the
    /// call and to the body it returns. A download that dies halfway
    /// through throws from inside the stream, long after this function has
    /// returned, and that error reaches the same transfer-failure text as
    /// any other.
    private func sendStreaming(_ request: URLRequest) async throws
        -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse)
    {
        do {
            let (body, response) = try await transport.sendStreaming(request)
            return (Self.surfacing(body), response)
        } catch {
            throw Self.surfaceable(error)
        }
    }

    /// Re-emits a body stream with `surfaceable(_:)` applied to whatever it
    /// throws.
    static func surfacing(
        _ body: AsyncThrowingStream<Data, Error>
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in body { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: surfaceable(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Reads

    public func list(path: String) async throws -> [RemoteFileItem] {
        let data = try await propfind(path: path, depth: "1", isDirectory: true)
        return try WebDAVPropfindParser.parse(data, base: base, requestedPath: path)
    }

    public func stat(path: String) async throws -> RemoteFileItem {
        // A collection and a file differ in URL shape, and servers disagree
        // about what happens when you address a collection without its
        // trailing slash: some redirect, some answer 2xx with no matching
        // entry, and some flatly 404 it. Ask for the collection form first
        // for the root (which is always a collection), the plain form
        // otherwise, and fall back once — on a successful PROPFIND that
        // didn't contain the addressed entry (a shape mismatch), AND on a
        // 404 from the first attempt for a non-root path, since that is
        // exactly the third server behaviour above and not distinguishable
        // from a genuine miss without trying the other shape. A 404 from the
        // SECOND attempt, or any non-404 error (401, 403, ...) from either
        // attempt, is not shape-ambiguous and propagates immediately — it is
        // the caller's answer already, and retrying would waste a round trip
        // (or exhaust an unstubbed transport).
        let isRoot = (path == "/")
        do {
            if let item = try await statOnce(path: path, isDirectory: isRoot) { return item }
        } catch RemoteFSError.notFound where !isRoot {
            // Shape-ambiguous: fall through to the second attempt below.
        }
        if let item = try await statOnce(path: path, isDirectory: !isRoot) { return item }
        throw RemoteFSError.notFound(path: path)
    }

    /// Returns nil (rather than throwing `.notFound`) when the PROPFIND
    /// succeeded but the addressed entry was not among the results — that is
    /// one signal for `stat` to retry with the opposite URL shape. Errors
    /// `propfind` itself throws (mapped HTTP statuses) propagate unchanged;
    /// `stat` decides for itself which of those are worth a retry.
    private func statOnce(path: String, isDirectory: Bool) async throws -> RemoteFileItem? {
        let data = try await propfind(path: path, depth: "0", isDirectory: isDirectory)
        // Depth 0 reports exactly the addressed resource, which the listing
        // parser excludes as "the requested collection". Ask it for the PARENT
        // so the entry survives, then pick the one that matches.
        let parent = path == "/" ? "/" : RemotePath.parent(of: path)
        let entries = try WebDAVPropfindParser.parse(data, base: base, requestedPath: parent)
        if let match = entries.first(where: { $0.path == path }) { return match }
        if path == "/" {
            return RemoteFileItem(name: "/", path: "/", kind: .directory)
        }
        return nil
    }

    private func propfind(path: String, depth: String, isDirectory: Bool) async throws -> Data {
        var request = URLRequest(url: base.url(forPath: path, isDirectory: isDirectory))
        request.httpMethod = "PROPFIND"
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // An explicit prop set rather than allprop: allprop invites servers to
        // return large, irrelevant property sets (Nextcloud especially).
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop>
          <d:resourcetype/><d:getcontentlength/><d:getlastmodified/>
        </d:prop></d:propfind>
        """.utf8)

        let (data, response) = try await send(request)
        try Self.mapStatus(response.statusCode, path: path, method: "PROPFIND")
        return data
    }

    public func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        var request = URLRequest(url: base.url(forPath: path, isDirectory: false))
        request.httpMethod = "GET"
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        let (body, response) = try await sendStreaming(request)
        try Self.mapStatus(response.statusCode, path: path, method: "GET")
        // A server that ignores Range answers 200 with the WHOLE body. Handing
        // that to a caller who asked for byte N onward would append the head a
        // second time and corrupt the file, so drop the head here: the caller
        // gets exactly the bytes it asked for, at the cost of re-transferring
        // what it already had.
        guard offset > 0, response.statusCode != 206 else { return body }
        return Self.dropping(offset, from: body)
    }

    /// Discards the first `count` bytes of a stream. The head may span several
    /// chunks, so this tracks a running total rather than trimming only the
    /// first chunk.
    static func dropping(
        _ count: UInt64, from body: AsyncThrowingStream<Data, Error>
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var remaining = count
                do {
                    for try await chunk in body {
                        if remaining == 0 {
                            continuation.yield(chunk)
                        } else if UInt64(chunk.count) <= remaining {
                            remaining -= UInt64(chunk.count)
                        } else {
                            continuation.yield(chunk.dropFirst(Int(remaining)))
                            remaining = 0
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func homeDirectoryPath() async throws -> String { "/" }

    public func disconnect() async {
        session?.invalidateAndCancel()
    }

    /// WebDAV has no partial PUT; Nextcloud's chunked upload is a proprietary
    /// extension and out of scope. The transfer queue gates resume on this.
    public var supportsAppendResume: Bool { false }

    // MARK: - Writes (Task 7)

    /// Streaming PUT.
    ///
    /// The body is fed through a bound stream pair rather than buffered: a
    /// multi-gigabyte upload must not be held in memory.
    ///
    /// A consequence worth naming: **this body is not replayable.** If
    /// URLSession decides to send the request again — an auth challenge on a
    /// connection it had already started writing to, a redirect — it asks the
    /// delegate for a fresh stream via `needNewBodyStream`, and there is
    /// nothing to hand back. The pair's `InputStream` is single-use, and the
    /// source it was fed from is a one-shot `AsyncThrowingStream` that has
    /// already been consumed; re-reading either is impossible, not merely
    /// unimplemented. `WebDAVSessionDelegate` therefore refuses the request
    /// and records why.
    ///
    /// Whether this is ever actually asked for is unverified. The mitigation
    /// we're relying on — the credential is cached from `connect`'s PROPFIND,
    /// so URLSession should already be authenticated before the PUT body
    /// starts streaming — is plausible but untested against a real server: a
    /// stale Digest nonce mid-session is exactly the kind of case that would
    /// provoke a fresh challenge, and therefore a replay, mid-upload. The
    /// gated WebDAV-rig test that would exercise this against a real server
    /// is a later task; until then, treat "does not bite in practice" as an
    /// expectation, not a proven claim.
    public func write(path: String, mode: WriteMode,
                      contents: AsyncThrowingStream<Data, Error>) async throws {
        guard mode == .overwrite else {
            // WebDAV has no partial PUT. Treating .append as .overwrite would
            // silently destroy the bytes already transferred.
            throw RemoteFSError.protocolError(
                reason: "WebDAV cannot append to a file; resume is not supported")
        }

        var request = URLRequest(url: base.url(forPath: path, isDirectory: false))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: TransferChunk.size,
                               inputStream: &input, outputStream: &output)
        guard let input, let output else {
            throw RemoteFSError.protocolError(reason: "Could not create the upload stream")
        }
        request.httpBodyStream = input

        // `BoundStreamWriter` owns every call on the output half: it never
        // issues a write that could park a thread, and it waits for space on
        // the run loop's `hasSpaceAvailable` event rather than on a timer.
        // See that type for why both properties are load-bearing.
        let writer = BoundStreamWriter(stream: output)
        // Whichever way we leave — success, mapped status, thrown transport
        // error, cancellation — the writer's thread is stopped and any
        // suspended pump write is released. No parked thread, no orphaned
        // continuation, no leaked run loop.
        defer { writer.close() }

        // Feeds the bound pair while the request is in flight, so a
        // multi-gigabyte upload is never held in memory. Runs detached so
        // the transport can start reading immediately — the pair has a
        // single chunk of buffer, so the pump has to wait for the reader to
        // drain it before it can write more.
        let pump = Task.detached {
            // Closes the write half so the reader (the transport, reading
            // `input`) sees EOF once the source is exhausted. This looks
            // redundant with the outer `defer` above, but it is not: on the
            // success path nothing else ever calls `close()` before
            // `transport.send` awaits the response, so without this the
            // reader never observes EOF, `send` never returns, and `write`
            // deadlocks. The outer `defer` only covers the failure/teardown
            // paths that exit before the pump finishes on its own.
            defer { writer.close() }
            for try await chunk in contents {
                try Task.checkCancellation()
                try await writer.write(chunk)
            }
        }

        let response: HTTPURLResponse
        do {
            response = try await send(request).1
        } catch {
            // The request is over; nothing will drain the body again. Stop
            // the pump BEFORE looking at its outcome — awaiting a pump that
            // is parked on an unread buffer is exactly the wedge.
            pump.cancel()
            // If the pump had ALSO failed on its own — e.g. the SOURCE
            // stream threw a read error — that is the real cause and wins
            // over a transport-level failure, which at this point is
            // usually just a downstream symptom of the aborted body (or, if
            // we're the one who just cancelled it, carries no information
            // at all).
            if let pumpError = await pumpFailure(pump) {
                throw pumpError
            }
            throw error
        }

        // A server that rejects a PUT early — 401 after a stale Digest nonce,
        // 403, 507 Insufficient Storage — answers WITHOUT reading the rest of
        // the body, so `send` returns normally while the pump is still parked
        // on a buffer that now has no reader at all. Cancel it and report the
        // status: that status is the server's own answer, and it outranks
        // whatever the abandoned body did on its way down.
        //
        // `mapStatus` throws for every non-2xx status, so control only reaches
        // the wait below on success.
        if !(200...299).contains(response.statusCode) {
            pump.cancel()
            try Self.mapStatus(response.statusCode, path: path, method: "PUT")
        }

        // 2xx: the server read the body to the end, so the pump has finished
        // or is about to, and its outcome is the real one. The wait is made
        // cancellation-responsive explicitly — `Task.value` does not observe
        // the *awaiting* task's cancellation, so without this the caller
        // could not break out of a stalled upload either.
        try await withTaskCancellationHandler {
            try await pump.value
        } onCancel: {
            pump.cancel()
        }
    }

    /// Awaits `pump`'s outcome without throwing, so `write` can decide which
    /// of two failures — the pump's or the transport's — is the more useful
    /// one to report. `nil` means the pump succeeded, or its only failure was
    /// uninformative on its own: our own teardown of it (cancellation, or the
    /// writer being closed under it), or `BoundStreamWriter.Failure.readerGone`
    /// — the write end observing the reader vanish, which at this call site is
    /// always just a symptom of the transport tearing the body down and must
    /// not be allowed to outrank the transport's own (usually far more
    /// specific) error.
    ///
    /// Safe to await only after `pump.cancel()`: every suspension point in the
    /// pump — the source stream, and `BoundStreamWriter.write` — is
    /// cancellation-responsive, so this returns promptly rather than
    /// inheriting the wait it was called to escape.
    private func pumpFailure(_ pump: Task<Void, Error>) async -> Error? {
        do {
            try await pump.value
            return nil
        } catch is CancellationError {
            return nil
        } catch is BoundStreamWriter.Failure {
            return nil
        } catch {
            return error
        }
    }

    public func delete(path: String) async throws {
        try await simple(method: "DELETE", path: path, isDirectory: false)
    }

    public func createDirectory(at path: String) async throws {
        try await simple(method: "MKCOL", path: path, isDirectory: true)
    }

    /// MOVE is atomic server-side — unlike S3, where rename is copy-then-delete
    /// and an interrupted call leaves both or neither.
    ///
    /// `Overwrite: F` is not optional: without it a server silently replaces
    /// an existing destination, which is the one outcome the conflict rules
    /// everywhere else in this app are built to prevent.
    public func rename(from: String, to: String) async throws {
        var request = URLRequest(url: base.url(forPath: from, isDirectory: false))
        request.httpMethod = "MOVE"
        request.setValue(base.url(forPath: to, isDirectory: false).absoluteString,
                         forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite")
        let (_, response) = try await send(request)
        try Self.mapStatus(response.statusCode, path: from, method: "MOVE")
    }

    /// One call. WebDAV deletes a collection recursively server-side; the S3
    /// backend needs a recursive listing and batched DeleteObjects for this.
    public func deleteTree(at path: String) async throws {
        try await simple(method: "DELETE", path: path, isDirectory: true)
    }

    /// `permissionModel` is `.none`. Failing loudly beats reporting a success
    /// the server never performed.
    public func setPermissions(path: String, permissions: UInt32) async throws {
        throw RemoteFSError.protocolError(
            reason: "WebDAV has no permission model")
    }

    private func simple(method: String, path: String, isDirectory: Bool) async throws {
        var request = URLRequest(url: base.url(forPath: path, isDirectory: isDirectory))
        request.httpMethod = method
        let (_, response) = try await send(request)
        try Self.mapStatus(response.statusCode, path: path, method: method)
    }

    // MARK: - Error mapping

    static func mapStatus(_ status: Int, path: String, method: String) throws {
        switch status {
        case 200...299: return
        case 401: throw RemoteFSError.authenticationFailed
        case 403: throw RemoteFSError.permissionDenied(path: path)
        case 404: throw RemoteFSError.notFound(path: path)
        case 405 where method == "MKCOL":
            throw RemoteFSError.protocolError(reason: "A file or folder named that already exists")
        case 409: throw RemoteFSError.notFound(path: path)
        case 412: throw RemoteFSError.protocolError(reason: "The destination already exists")
        case 507: throw RemoteFSError.protocolError(reason: "The server is out of storage")
        default:
            throw RemoteFSError.protocolError(reason: "WebDAV \(method) failed with status \(status)")
        }
    }
}
