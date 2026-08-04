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
        // A collection and a file differ in URL shape, and a server may answer
        // the wrong one with a redirect. Ask for the collection form first for
        // the root (which is always a collection), the plain form otherwise,
        // and fall back once — but only when the FIRST shape's PROPFIND came
        // back successful yet didn't contain the addressed entry (a shape
        // mismatch). A definitive HTTP-level error (404, 401, ...) from
        // `propfind` is not shape-ambiguous and must not trigger a second,
        // unstubbed network round trip — it is the caller's answer already.
        let isRoot = (path == "/")
        if let item = try await statOnce(path: path, isDirectory: isRoot) { return item }
        if let item = try await statOnce(path: path, isDirectory: !isRoot) { return item }
        throw RemoteFSError.notFound(path: path)
    }

    /// Returns nil (rather than throwing `.notFound`) when the PROPFIND
    /// succeeded but the addressed entry was not among the results — that is
    /// the signal for `stat` to retry with the opposite URL shape. Errors
    /// `propfind` itself throws (mapped HTTP statuses) propagate unchanged.
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

    public func write(path: String, mode: WriteMode,
                      contents: AsyncThrowingStream<Data, Error>) async throws {
        throw RemoteFSError.protocolError(reason: "not implemented yet")
    }
    public func delete(path: String) async throws {
        throw RemoteFSError.protocolError(reason: "not implemented yet")
    }
    public func createDirectory(at path: String) async throws {
        throw RemoteFSError.protocolError(reason: "not implemented yet")
    }
    public func rename(from: String, to: String) async throws {
        throw RemoteFSError.protocolError(reason: "not implemented yet")
    }
    public func setPermissions(path: String, permissions: UInt32) async throws {
        throw RemoteFSError.protocolError(reason: "not implemented yet")
    }
    public func deleteTree(at path: String) async throws {
        throw RemoteFSError.protocolError(reason: "not implemented yet")
    }

    // MARK: - Error mapping

    static func mapStatus(_ status: Int, path: String, method: String) throws {
        switch status {
        case 200...299: return
        case 401, 403 where method == "PROPFIND":
            throw status == 401
                ? RemoteFSError.authenticationFailed
                : RemoteFSError.permissionDenied(path: path)
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
