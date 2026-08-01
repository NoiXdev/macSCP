import Foundation

/// Thin S3 (and S3-compatible: MinIO, R2, Hetzner, …) implementation of
/// `RemoteFileSystem` (M12/T5). `connect`/`list`/`stat`/`readStream` are
/// real, signed calls; `delete` and `createDirectory` are real as of M13/T4,
/// and `write` (single-PUT and multipart) is real as of M13/T5-T6. The
/// remaining mutating operations (`rename`, `setPermissions`, `deleteTree`)
/// still throw `RemoteFSError.protocolError` — those land in later M13
/// tasks.
///
/// `Sendable` by construction rather than `@unchecked`: both stored
/// properties are immutable and themselves `Sendable` (`S3ConnectionConfig`
/// is a `Sendable` struct; `any S3HTTPTransport` requires `Sendable`), so
/// there is no shared mutable state to race on.
public final class S3FileSystem: RemoteFileSystem, S3RequestBuilder {
    private let config: S3ConnectionConfig
    private let transport: any S3HTTPTransport

    private init(config: S3ConnectionConfig, transport: any S3HTTPTransport) {
        self.config = config
        self.transport = transport
    }

    /// Connects by performing one ListObjectsV2 probe against the bucket
    /// root (prefix `""`). Maps HTTP 403 → `.authenticationFailed`, 404 →
    /// `.notFound`, and any transport/network failure → `.connectionFailed`.
    public static func connect(
        _ config: S3ConnectionConfig, transport: any S3HTTPTransport = URLSessionS3Transport()
    ) async throws -> S3FileSystem {
        let fs = S3FileSystem(config: config, transport: transport)
        _ = try await fs.fetchPage(prefix: "", continuationToken: nil)
        return fs
    }

    public func list(path: String) async throws -> [RemoteFileItem] {
        let prefix = Self.s3Prefix(forPath: path)
        var items: [RemoteFileItem] = []
        var token: String?
        repeat {
            let page = try await fetchPage(prefix: prefix, continuationToken: token)
            items.append(contentsOf: page.items)
            token = page.continuationToken
        } while token != nil
        return items
    }

    /// Looks up a single entry by listing its PARENT with a delimiter and
    /// matching the leaf name — S3 has no dedicated "stat a single key"
    /// call that also tells you whether a key is a `CommonPrefixes` (a
    /// "directory"), so this reuses the same signed-list machinery `list`
    /// uses rather than adding a second, subtly-different request path.
    public func stat(path: String) async throws -> RemoteFileItem {
        let normalized = RemotePath.normalizedAbsolute(path)
        if normalized == "/" {
            return RemoteFileItem(name: "/", path: "/", kind: .directory)
        }
        let leafName = normalized.split(separator: "/").last.map(String.init) ?? normalized
        let parentPrefix = Self.s3Prefix(forPath: RemotePath.parent(of: normalized))

        var token: String?
        repeat {
            let page = try await fetchPage(prefix: parentPrefix, continuationToken: token)
            if let match = page.items.first(where: { $0.name == leafName }) {
                return match
            }
            token = page.continuationToken
        } while token != nil
        throw RemoteFSError.notFound(path: path)
    }

    /// A signed range GET on the object key, streamed through
    /// `transport.sendStreaming`. Maps 2xx → the body stream, 416 (range at
    /// or beyond EOF) → an EMPTY stream (per the `RemoteFileSystem` contract
    /// — this is not an error), 403 → `.authenticationFailed`, 404 →
    /// `.notFound`, anything else → `.protocolError`.
    ///
    /// `Range` is set on the request AFTER `buildSignedRequest` returns, so
    /// it is never part of the SigV4-signed header set — AWS does not
    /// require `Range` to be signed, and signing it here would just be
    /// extra surface for a byte-identical-header bug with no benefit.
    public func readStream(path: String, fromOffset offset: UInt64) async throws -> AsyncThrowingStream<Data, Error> {
        let key = Self.objectKey(forPath: path)
        var request = try buildSignedRequest(
            method: "GET", key: key, query: [], payloadHash: SigV4Signer.emptyPayloadHash)
        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")

        let body: AsyncThrowingStream<Data, Error>
        let response: HTTPURLResponse
        do {
            (body, response) = try await transport.sendStreaming(request)
        } catch let error as RemoteFSError {
            throw error
        } catch {
            throw RemoteFSError.connectionFailed(reason: "S3 request failed: \(error.localizedDescription)")
        }
        switch response.statusCode {
        case 200..<300:
            return body
        case 416:
            return AsyncThrowingStream { $0.finish() }
        case 403:
            throw RemoteFSError.authenticationFailed
        case 404:
            throw RemoteFSError.notFound(path: path)
        default:
            throw RemoteFSError.protocolError(reason: "S3 download failed with HTTP status \(response.statusCode)")
        }
    }

    /// Delegates to `S3Uploader` (M13/T5). `mode` is ignored: Task 1's
    /// resume guard (`supportsAppendResume == false`) guarantees
    /// `TransferEngine` only ever hands an S3 destination `.overwrite` — a
    /// resumed `.append` write from a non-zero offset never reaches here.
    public func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {
        try await S3Uploader().upload(key: Self.objectKey(forPath: path), contents: contents, using: self)
    }

    /// A signed `DELETE` on the object key. S3's `DeleteObject` is
    /// idempotent and returns 204 whether or not the key existed, but a
    /// non-2xx (403/404/other) is still mapped through `sendExpectingSuccess`
    /// like any other request.
    public func delete(path: String) async throws {
        let request = try buildSignedRequest(
            method: "DELETE", key: Self.objectKey(forPath: path), query: [],
            payloadHash: SigV4Signer.emptyPayloadHash)
        try await sendExpectingSuccess(request, path: path)
    }

    /// Creates a 0-byte marker object whose key ends in "/" — the universal
    /// S3 convention for representing an empty "folder" (S3 itself has no
    /// directory concept; every other S3-compatible tool and console
    /// recognizes this marker). Idempotent: re-PUTting the same marker is
    /// harmless.
    public func createDirectory(at path: String) async throws {
        let markerKey = Self.objectKey(forPath: path) + "/"
        let request = try buildSignedRequest(
            method: "PUT", key: markerKey, query: [], body: Data(),
            payloadHash: SigV4Signer.emptyPayloadHash)
        try await sendExpectingSuccess(request, path: path)
    }

    public func rename(from: String, to: String) async throws {
        throw RemoteFSError.protocolError(reason: "S3 rename is not supported yet (M13)")
    }

    public func setPermissions(path: String, permissions: UInt32) async throws {
        throw RemoteFSError.protocolError(reason: "S3 has no POSIX permissions to set (M13)")
    }

    public func deleteTree(at path: String) async throws {
        throw RemoteFSError.protocolError(reason: "S3 delete is not supported yet (M13)")
    }

    public func homeDirectoryPath() async throws -> String {
        "/"
    }

    public func disconnect() async {}

    /// S3 has no append; a re-PUT replaces the whole object (M13).
    public var supportsAppendResume: Bool { false }

    // MARK: - S3RequestBuilder conformance (thin wrappers for S3Uploader, M13/T5)

    /// `S3RequestBuilder.signedRequest`: a thin pass-through to
    /// `buildSignedRequest` so `S3Uploader` can sign a PUT without knowing
    /// about `S3ConnectionConfig` or `SigV4Signer` directly.
    public func signedRequest(
        method: String, key: String, query: [(name: String, value: String)],
        extraHeaders: [String: String], body: Data?, payloadHash: String
    ) throws -> URLRequest {
        try buildSignedRequest(
            method: method, key: key, query: query, extraHeaders: extraHeaders,
            body: body, payloadHash: payloadHash)
    }

    /// `S3RequestBuilder.perform`: a thin pass-through to `transport.send`,
    /// with the same transport-error mapping every other request path uses.
    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as RemoteFSError {
            throw error
        } catch {
            throw RemoteFSError.connectionFailed(reason: "S3 request failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Request building + signed ListObjectsV2

    /// One signed `GET ?list-type=2&prefix=&delimiter=/[&continuation-token=]`
    /// call, mapped through `S3ListParser`. HTTP 403 → `.authenticationFailed`,
    /// 404 → `.notFound`, any other non-2xx → `.protocolError`, and a
    /// transport-level (network) failure → `.connectionFailed`.
    private func fetchPage(
        prefix: String, continuationToken: String?
    ) async throws -> (items: [RemoteFileItem], continuationToken: String?) {
        let request = try buildListRequest(prefix: prefix, continuationToken: continuationToken)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as RemoteFSError {
            throw error
        } catch {
            throw RemoteFSError.connectionFailed(reason: "S3 request failed: \(error.localizedDescription)")
        }

        switch response.statusCode {
        case 200..<300:
            return try S3ListParser.parse(data, prefix: prefix)
        default:
            throw Self.mapErrorStatus(response.statusCode, path: "/" + prefix)
        }
    }

    /// Sends a signed request whose only interesting outcome is
    /// success/failure — no response body to parse (`delete`,
    /// `createDirectory`, and later mutating operations). Shares the
    /// transport-error and non-2xx status mapping with `fetchPage` via
    /// `mapErrorStatus`, so the two never drift into duplicated (and
    /// possibly inconsistent) HTTP-status handling.
    private func sendExpectingSuccess(_ request: URLRequest, path: String) async throws {
        let response: HTTPURLResponse
        do {
            (_, response) = try await transport.send(request)
        } catch let error as RemoteFSError {
            throw error
        } catch {
            throw RemoteFSError.connectionFailed(reason: "S3 request failed: \(error.localizedDescription)")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.mapErrorStatus(response.statusCode, path: path)
        }
    }

    /// Maps a non-2xx HTTP status to the `RemoteFSError` it represents:
    /// 403 → `.authenticationFailed`, 404 → `.notFound(path:)`, anything
    /// else → `.protocolError`. Callers only reach this for a status
    /// already known to be outside the 2xx range.
    private static func mapErrorStatus(_ statusCode: Int, path: String) -> RemoteFSError {
        switch statusCode {
        case 403:
            return .authenticationFailed
        case 404:
            return .notFound(path: path)
        default:
            return .protocolError(reason: "S3 request failed with HTTP status \(statusCode)")
        }
    }

    private func buildListRequest(prefix: String, continuationToken: String?) throws -> URLRequest {
        let queryPairs = Self.queryPairs(prefix: prefix, continuationToken: continuationToken)
        let url = try Self.requestURL(config: config, queryPairs: queryPairs)
        guard let host = url.host else {
            throw RemoteFSError.connectionFailed(reason: "S3 endpoint has no host: \(config.endpoint)")
        }
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        let canonicalPath = url.path.isEmpty ? "/" : url.path

        let signer = SigV4Signer(
            accessKeyID: config.accessKeyID, secretAccessKey: config.secretAccessKey,
            region: config.region, service: "s3", sessionToken: config.sessionToken)
        let (authorization, extraHeaders) = signer.authorizationHeader(
            method: "GET", host: hostHeader, path: canonicalPath, query: queryPairs,
            headers: ["host": hostHeader], payloadHash: SigV4Signer.emptyPayloadHash, date: Date())

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(hostHeader, forHTTPHeaderField: "Host")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    /// Generalized signed-request builder — any HTTP method against an
    /// OBJECT KEY, with optional signed extra headers/body (later tasks:
    /// `x-amz-copy-source` for rename, `Content-MD5` for uploads). Shares
    /// the same host/path/signer machinery `buildListRequest` uses, just
    /// keyed on an object key instead of a bucket-root query.
    ///
    /// IMPORTANT: `extraHeaders` are SIGNED (merged into the SigV4 canonical
    /// header set). A caller that needs an unsigned header (e.g. `Range` —
    /// AWS does not require it to be signed) must set it on the returned
    /// `URLRequest` directly, never pass it here.
    private func buildSignedRequest(
        method: String, key: String, query: [(name: String, value: String)],
        extraHeaders: [String: String] = [:], body: Data? = nil,
        payloadHash: String
    ) throws -> URLRequest {
        let url = try Self.keyRequestURL(config: config, key: key, queryPairs: query)
        guard let host = url.host else {
            throw RemoteFSError.connectionFailed(reason: "S3 endpoint has no host: \(config.endpoint)")
        }
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        let canonicalPath = Self.canonicalKeyPath(config: config, key: key)

        var headers = extraHeaders
        headers["host"] = hostHeader
        let signer = SigV4Signer(
            accessKeyID: config.accessKeyID, secretAccessKey: config.secretAccessKey,
            region: config.region, service: "s3", sessionToken: config.sessionToken)
        let (authorization, signed) = signer.authorizationHeader(
            method: method, host: hostHeader, path: canonicalPath, query: query,
            headers: headers, payloadHash: payloadHash, date: Date())

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(hostHeader, forHTTPHeaderField: "Host")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        for (k, v) in signed { request.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
        if let body { request.httpBody = body }
        return request
    }

    /// Builds the request URL for an OBJECT KEY — path-style
    /// (`{endpoint}/{bucket}/{key}`) or virtual-hosted
    /// (`{scheme}://{bucket}.{host}/{key}`) — analogous to `requestURL` but
    /// keyed on an object key rather than a bucket-root query.
    ///
    /// The path is percent-encoded segment-by-segment via
    /// `SigV4Signer.canonicalURI` (leaving `/` literal) and assigned through
    /// `percentEncodedPath`, and the query through
    /// `SigV4Signer.canonicalQueryString` via `percentEncodedQuery` — both
    /// for the same reason `requestURL` does (M12 review I-1): letting
    /// `URLComponents` re-encode a key or query value with its own (looser)
    /// rules would desync the wire request from what the signer signed.
    private static func keyRequestURL(
        config: S3ConnectionConfig, key: String, queryPairs: [(name: String, value: String)]
    ) throws -> URL {
        guard var components = URLComponents(string: config.endpoint) else {
            throw RemoteFSError.connectionFailed(reason: "Invalid S3 endpoint: \(config.endpoint)")
        }
        if config.usePathStyle {
            components.percentEncodedPath = SigV4Signer.canonicalURI(path: canonicalKeyPath(config: config, key: key))
        } else {
            guard let host = components.host else {
                throw RemoteFSError.connectionFailed(reason: "Invalid S3 endpoint host: \(config.endpoint)")
            }
            components.host = "\(config.bucket).\(host)"
            components.percentEncodedPath = SigV4Signer.canonicalURI(path: canonicalKeyPath(config: config, key: key))
        }

        components.percentEncodedQuery = queryPairs.isEmpty ? nil : SigV4Signer.canonicalQueryString(query: queryPairs)

        guard let url = components.url else {
            throw RemoteFSError.connectionFailed(reason: "Failed to build S3 request URL for endpoint: \(config.endpoint)")
        }
        return url
    }

    /// The raw (pre-encoding) request path for an object key — the exact
    /// string `keyRequestURL` feeds into `canonicalURI` for the wire URL.
    /// Signing MUST use THIS, not `URL.path` (which drops a trailing slash and
    /// would produce a SignatureDoesNotMatch for folder-marker keys) (M13).
    private static func canonicalKeyPath(config: S3ConnectionConfig, key: String) -> String {
        config.usePathStyle ? "/\(config.bucket)/\(key)" : "/\(key)"
    }

    /// Maps an absolute browser path to the S3 object key used for a FILE
    /// (unlike `s3Prefix`, no trailing slash — a key names one object, not
    /// a "directory" prefix): no leading slash, no trailing slash.
    private static func objectKey(forPath path: String) -> String {
        let normalized = RemotePath.normalizedAbsolute(path)
        if normalized == "/" { return "" }
        return String(normalized.dropFirst())
    }

    /// The `list-type`/`prefix`/`delimiter`[/`continuation-token`] pairs for
    /// one ListObjectsV2 call, as raw (unencoded) `(name, value)` tuples.
    /// Built once and shared by both the signer (`authorizationHeader`,
    /// via `buildListRequest`) and the wire URL (`requestURL`) so the two
    /// can never see different query contents.
    private static func queryPairs(prefix: String, continuationToken: String?) -> [(name: String, value: String)] {
        var pairs: [(name: String, value: String)] = [
            (name: "list-type", value: "2"),
            (name: "prefix", value: prefix),
            (name: "delimiter", value: "/"),
        ]
        if let continuationToken {
            pairs.append((name: "continuation-token", value: continuationToken))
        }
        return pairs
    }

    /// Builds the ListObjectsV2 request URL for either path-style
    /// (`{endpoint}/{bucket}?...`) or virtual-hosted
    /// (`{scheme}://{bucket}.{host}?...`) addressing.
    ///
    /// The wire query is encoded with `SigV4Signer.canonicalQueryString` —
    /// the SAME RFC-3986 percent-encoding (and sort order) the signer uses
    /// to canonicalize the query it signs — and assigned via
    /// `percentEncodedQuery`, which Foundation stores verbatim. Using
    /// `queryItems`/`query` instead would let `URLComponents` re-encode the
    /// value with its own rules, which notably leave `+` un-escaped; a
    /// `+` in a value (e.g. a base64 `continuation-token`) would then be
    /// signed as `%2B` but sent as a literal `+`, decoded server-side as a
    /// space, and rejected as a signature mismatch (HTTP 403). See M12
    /// review finding I-1.
    private static func requestURL(
        config: S3ConnectionConfig, queryPairs: [(name: String, value: String)]
    ) throws -> URL {
        guard var components = URLComponents(string: config.endpoint) else {
            throw RemoteFSError.connectionFailed(reason: "Invalid S3 endpoint: \(config.endpoint)")
        }
        if config.usePathStyle {
            components.path = "/" + config.bucket
        } else {
            guard let host = components.host else {
                throw RemoteFSError.connectionFailed(reason: "Invalid S3 endpoint host: \(config.endpoint)")
            }
            components.host = "\(config.bucket).\(host)"
            components.path = ""
        }

        components.percentEncodedQuery = SigV4Signer.canonicalQueryString(query: queryPairs)

        guard let url = components.url else {
            throw RemoteFSError.connectionFailed(reason: "Failed to build S3 request URL for endpoint: \(config.endpoint)")
        }
        return url
    }

    /// Maps an absolute browser path (`"/"`, `"/sub"`, …) to the S3 key
    /// prefix used in the query (`""`, `"sub/"`, …): no leading slash,
    /// trailing slash except for the empty (root) prefix.
    private static func s3Prefix(forPath path: String) -> String {
        let normalized = RemotePath.normalizedAbsolute(path)
        if normalized == "/" { return "" }
        let trimmed = String(normalized.dropFirst())
        return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }
}
