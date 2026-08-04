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
        decider: @escaping WebDAVSessionDelegate.CertificateDecider
    ) async throws -> WebDAVFileSystem {
        guard let url = URL(string: config.baseURL), url.scheme != nil, url.host() != nil else {
            throw RemoteFSError.connectionFailed(reason: "WebDAV base URL is not a valid URL")
        }
        let delegate = WebDAVSessionDelegate(
            username: config.username, password: config.password,
            trustStore: trustStore, decider: decider)
        let session = URLSession(
            configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
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
            throw error
        }
        return fs
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

        let (data, response) = try await transport.send(request)
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
        let (body, response) = try await transport.sendStreaming(request)
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
    /// multi-gigabyte upload must not be held in memory. `httpBodyStream` is
    /// also what lets URLSession replay the body after an auth challenge —
    /// it asks the delegate for a fresh stream via `needNewBodyStream`.
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

        // Feeds the bound pair while the request is in flight, so a
        // multi-gigabyte upload is never held in memory. Runs detached so
        // the transport can start reading immediately — the pair has a
        // single chunk of buffer, so the pump has to wait for the reader to
        // drain it before it can write more.
        //
        // That "wait" is deliberately a poll on `hasSpaceAvailable` plus a
        // cancellable `Task.sleep`, never a direct blocking `write` into a
        // full buffer: `OutputStream.write` is a synchronous Foundation call
        // that parks the underlying thread until space frees up, and
        // nothing we can do from outside — not `Task.cancel()`, not closing
        // the stream's peer — interrupts a call already parked inside it
        // (verified empirically: a thread blocked in `write()` on a full,
        // unread buffer stays blocked even after the paired `InputStream` is
        // closed). If the request fails before ever reading the body — a
        // connection error, or a fast 4xx — polling is what lets
        // `pump.cancel()` actually stop the pump instead of leaking a
        // permanently parked thread.
        let pump = Task.detached {
            output.open()
            defer { output.close() }
            for try await chunk in contents {
                try Task.checkCancellation()
                var written = 0
                while written < chunk.count {
                    while !output.hasSpaceAvailable {
                        try Task.checkCancellation()
                        try await Task.sleep(nanoseconds: 5_000_000)
                    }
                    try Task.checkCancellation()
                    let n = chunk.withUnsafeBytes { raw -> Int in
                        output.write(
                            raw.baseAddress!.advanced(by: written)
                                .assumingMemoryBound(to: UInt8.self),
                            maxLength: chunk.count - written)
                    }
                    guard n > 0 else {
                        throw RemoteFSError.connectionFailed(
                            reason: "The upload stream closed early")
                    }
                    written += n
                }
            }
        }

        do {
            let (_, response) = try await transport.send(request)
            try await pump.value
            try Self.mapStatus(response.statusCode, path: path, method: "PUT")
        } catch {
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
    }

    /// Awaits `pump`'s outcome without throwing, so `write` can decide which
    /// of two failures — the pump's or the transport's — is the more useful
    /// one to report. `nil` means the pump succeeded, or its only failure was
    /// our own cancellation of it (which carries no information).
    private func pumpFailure(_ pump: Task<Void, Error>) async -> Error? {
        do {
            try await pump.value
            return nil
        } catch is CancellationError {
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
        let (_, response) = try await transport.send(request)
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
        let (_, response) = try await transport.send(request)
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
