import Crypto
import Foundation

/// Thin S3 (and S3-compatible: MinIO, R2, Hetzner, …) implementation of
/// `RemoteFileSystem` (M12/T5). `connect`/`list`/`stat`/`readStream` are
/// real, signed calls; `delete` and `createDirectory` are real as of M13/T4,
/// `write` (single-PUT and multipart) is real as of M13/T5-T6, `rename`
/// (copy+delete, with a re-key loop for directories) is real as of M13/T7,
/// and `deleteTree` (recursive list + batched `DeleteObjects`) is real as of
/// M13/T8. The one remaining mutating operation, `setPermissions`, still
/// throws `RemoteFSError.protocolError` — S3 has no POSIX permissions.
///
/// `Sendable` by construction rather than `@unchecked`: every stored
/// property is immutable and itself `Sendable` (`S3ConnectionConfig` is a
/// `Sendable` struct; `any HTTPTransport` requires `Sendable`; `URLSession`
/// is `Sendable`; `S3RedirectSessionDelegate` is `@unchecked Sendable` and
/// argues its own case — one recorded refusal behind a lock), so there is
/// no shared mutable state here to race on.
public final class S3FileSystem: RemoteFileSystem, S3RequestBuilder {
    private let config: S3ConnectionConfig
    private let transport: any HTTPTransport
    /// The session this file system owns and must invalidate, or `nil` when
    /// the transport was injected and the session belongs to someone else.
    /// Same arrangement as `WebDAVFileSystem`.
    private let session: URLSession?
    /// The delegate that decided what to do with any redirect on that
    /// session, or `nil` for an injected transport — whose session's
    /// redirect policy, if it has one, is the caller's business.
    private let redirectPolicy: S3RedirectSessionDelegate?

    private init(
        config: S3ConnectionConfig, transport: any HTTPTransport, session: URLSession?,
        redirectPolicy: S3RedirectSessionDelegate?
    ) {
        self.config = config
        self.transport = transport
        self.session = session
        self.redirectPolicy = redirectPolicy
    }

    /// Connects by performing one ListObjectsV2 probe against the bucket
    /// root (prefix `""`). Maps HTTP 403 → `.authenticationFailed`, 404 →
    /// `.notFound`, and any transport/network failure → `.connectionFailed`.
    ///
    /// Module-internal, like every backend's dial: the only way in from
    /// outside Core is `BackendDescriptor.openConnection`, which is where the
    /// deciders and the configured connect timeout are supplied. Core's own
    /// tests import `@testable` and keep this.
    ///
    /// With no transport supplied the dial builds its OWN session from
    /// `URLSessionConfiguration.ephemeral`, the way `WebDAVFileSystem.connect`
    /// does. It used to take `URLSessionHTTPTransport`'s old default and run
    /// on `URLSession.shared`, which put every bucket listing into the
    /// process-wide on-disk `URLCache.shared` and let a cached permanent
    /// redirect be followed by a later run without the endpoint being asked
    /// — measured on loopback, see `S3SessionIsolationTests`. An ephemeral
    /// configuration hands out a fresh, memory-only cache per session, so a
    /// dial shares nothing with another dial or another process.
    ///
    /// That own session is also what makes a redirect policy possible at
    /// all — `URLSession.shared` cannot carry a delegate — so it is built
    /// with `S3RedirectSessionDelegate`: a redirect inside the endpoint's
    /// origin is re-signed and followed, one that leaves it is refused. An
    /// INJECTED transport gets none of that; a test that wants to measure
    /// what Foundation does when nothing decides injects one for exactly
    /// that reason (`S3RedirectAuthorizationMeasurementTests`).
    static func connect(
        _ config: S3ConnectionConfig, transport: (any HTTPTransport)? = nil
    ) async throws -> S3FileSystem {
        let fs: S3FileSystem
        if let transport {
            fs = S3FileSystem(
                config: config, transport: transport, session: nil, redirectPolicy: nil)
        } else {
            let redirectPolicy = S3RedirectSessionDelegate(config: config)
            let session = URLSession(
                configuration: .ephemeral, delegate: redirectPolicy, delegateQueue: nil)
            fs = S3FileSystem(
                config: config, transport: URLSessionHTTPTransport(session: session),
                session: session, redirectPolicy: redirectPolicy)
        }
        do {
            _ = try await fs.fetchPage(prefix: "", continuationToken: nil)
        } catch {
            // A dial that fails still built a session, and nothing else will
            // ever hold this file system. Same reason `WebDAVFileSystem.connect`
            // invalidates before it rethrows.
            await fs.disconnect()
            throw error
        }
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

        // The streaming counterpart of `send`, kept here rather than folded
        // into it because its return type differs; the two arms match it
        // line for line, refused-redirect check included. A download runs on
        // the same session and therefore under the same policy.
        let body: AsyncThrowingStream<Data, Error>
        let response: HTTPURLResponse
        do {
            (body, response) = try await transport.sendStreaming(request)
            if let refused = refusedRedirect() { throw refused }
        } catch let error as RemoteFSError {
            throw error
        } catch {
            if let refused = refusedRedirect() { throw refused }
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
    /// like any other request. Delegates to the raw-key overload below.
    public func delete(path: String) async throws {
        try await delete(key: Self.objectKey(forPath: path))
    }

    /// Raw-key counterpart to `delete(path:)`, for callers that already hold
    /// a full S3 object key rather than a browser path — `rename` (M13/T7,
    /// re-keying a directory) and `deleteTree` (M13/T8) both enumerate keys
    /// via `allObjectKeys(underPrefix:)` and need to delete exactly those
    /// keys, including a directory's own trailing-slash marker key, which
    /// `objectKey(forPath:)` cannot address (it always strips trailing
    /// slashes).
    private func delete(key: String) async throws {
        let request = try buildSignedRequest(
            method: "DELETE", key: key, query: [],
            payloadHash: SigV4Signer.emptyPayloadHash)
        try await sendExpectingSuccess(request, path: "/" + key)
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

    /// Renames/moves an object or "directory" prefix. S3 has no native
    /// rename — this is a server-side copy (`copyObject`, no bytes round-trip
    /// through this process) followed by a delete of the source.
    ///
    /// Destination pre-check: S3's PUT-copy silently overwrites an existing
    /// key, but the `RemoteFileSystem` contract forbids a silent overwrite on
    /// rename, so `to` is `stat`-ed first and rejected (without touching
    /// anything) if it already exists.
    ///
    /// A FILE rename is a single copy+delete. A DIRECTORY rename re-keys
    /// every object under the source prefix (via `allObjectKeys`, which also
    /// picks up the directory's own trailing-slash marker key) one at a
    /// time. This is deliberately NOT atomic or transactional: a failure
    /// partway through leaves some objects already copied to the
    /// destination and the rest still at the source, with no rollback (v1—
    /// S3 has no multi-object transaction to lean on here).
    public func rename(from: String, to: String) async throws {
        do {
            _ = try await stat(path: to)
            throw RemoteFSError.protocolError(reason: "Destination already exists: \(to)")
        } catch RemoteFSError.notFound {
            // Confirmed absent — safe to proceed.
        }
        let fromKind = try await stat(path: from).kind
        if fromKind == .directory {
            let fromPrefix = Self.s3Prefix(forPath: from)
            let toPrefix = Self.s3Prefix(forPath: to)
            for key in try await allObjectKeys(underPrefix: fromPrefix) {
                let destKey = toPrefix + key.dropFirst(fromPrefix.count)
                try await copyObject(fromKey: key, toKey: String(destKey))
                try await delete(key: key)
            }
        } else {
            try await copyObject(fromKey: Self.objectKey(forPath: from), toKey: Self.objectKey(forPath: to))
            try await delete(key: Self.objectKey(forPath: from))
        }
    }

    public func setPermissions(path: String, permissions: UInt32) async throws {
        throw RemoteFSError.protocolError(reason: "S3 has no POSIX permissions to set (M13)")
    }

    /// Recursively lists every key under the path's prefix (via
    /// `allObjectKeys`, which also picks up the directory's own
    /// trailing-slash marker key) and removes them in `<=1000`-key
    /// `DeleteObjects` batches — S3's maximum per call. Each batch is one
    /// signed `POST {bucket}?delete` carrying an XML `<Delete>` body and a
    /// SIGNED `Content-MD5` header, which S3 requires for this call (unlike
    /// every other request this file builds).
    ///
    /// `Task.checkCancellation()` runs once per batch, not per key — a batch
    /// already in flight always completes. Like `rename`'s directory re-key
    /// loop, this is deliberately NOT transactional: a cancellation or
    /// mid-tree failure leaves a PARTIALLY deleted tree, with no rollback.
    ///
    /// S3's `DeleteObjects` can answer HTTP 200 with a `<DeleteResult>` body
    /// that lists per-key `<Error>` entries for objects it failed to delete
    /// — the same "200 lies" shape `copyObject` already guards against for
    /// CopyObject. A clean response never contains an `<Error` element, so a
    /// substring check on the body is enough to catch a partial failure
    /// without a full XML parse.
    public func deleteTree(at path: String) async throws {
        let keys = try await allObjectKeys(underPrefix: Self.s3Prefix(forPath: path))
        for batch in keys.chunked(into: 1000) {
            try Task.checkCancellation()
            let body = try Self.deleteObjectsXML(keys: batch)
            let md5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
            let request = try buildSignedRequest(
                method: "POST", key: "", query: [(name: "delete", value: "")],
                extraHeaders: ["Content-MD5": md5], body: body,
                payloadHash: SigV4Signer.hexSHA256(body))

            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch let error as RemoteFSError {
                throw error
            } catch {
                throw RemoteFSError.connectionFailed(reason: "S3 request failed: \(error.localizedDescription)")
            }
            guard (200..<300).contains(response.statusCode) else {
                throw Self.mapErrorStatus(response.statusCode, path: path)
            }
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            if responseBody.contains("<Error") {
                throw RemoteFSError.protocolError(
                    reason: "S3 deleteTree: one or more objects could not be deleted")
            }
        }
    }

    public func homeDirectoryPath() async throws -> String {
        "/"
    }

    /// Releases the session the dial built. There is no S3 connection to
    /// tear down — the protocol is stateless request-by-request — but a
    /// `URLSession` holds its connection pool, its own cache and — since it
    /// carries one — a strong reference to its delegate until it is
    /// invalidated, and this one exists for the length of this file system
    /// and nothing else. A no-op when the transport was injected: that
    /// session is the caller's to end.
    public func disconnect() async {
        session?.invalidateAndCancel()
    }

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

    /// `S3RequestBuilder.perform`: a thin pass-through to `send`, so an
    /// uploader's requests get the same transport-error mapping and the
    /// same refused-redirect reporting every other request path gets.
    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await send(request)
    }

    // MARK: - The one way out to the network

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
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let result = try await transport.send(request)
            if let refused = refusedRedirect() { throw refused }
            return result
        } catch let error as RemoteFSError {
            throw error
        } catch {
            if let refused = refusedRedirect() { throw refused }
            throw RemoteFSError.connectionFailed(reason: "S3 request failed: \(error.localizedDescription)")
        }
    }

    /// The redirect this file system's session refused, as the error to
    /// report instead of whatever the refusal left behind. Always `nil` for
    /// an injected transport, which carries no policy of ours.
    private func refusedRedirect() -> RemoteFSError? {
        redirectPolicy?.lastRefusedRedirect.map { RemoteFSError.connectionFailed(reason: $0) }
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
        let (data, response) = try await send(request)

        switch response.statusCode {
        case 200..<300:
            return try S3ListParser.parse(data, prefix: prefix)
        default:
            throw Self.mapErrorStatus(response.statusCode, path: "/" + prefix)
        }
    }

    /// A signed `PUT {toKey}` carrying `x-amz-copy-source` — S3's
    /// server-side copy, so the object body never round-trips through this
    /// process. The header value is `/{bucket}/{rfc3986(fromKey)}` (a copy
    /// source is ALWAYS addressed path-style, `/{bucket}/{key}`, regardless
    /// of whether this connection itself uses path-style or virtual-hosted
    /// addressing for its other requests) and is encoded with
    /// `SigV4Signer.canonicalURI` — the exact same RFC-3986 rules the
    /// signer uses elsewhere — so the signed and wire header values can
    /// never diverge (same reasoning as M12 review I-1's query/path fix,
    /// applied here to a header instead).
    ///
    /// The header MUST travel via `extraHeaders` so `buildSignedRequest`
    /// folds it into the SigV4 canonical (and therefore signed) header set —
    /// an unsigned `x-amz-copy-source` is rejected by S3 with a signature
    /// mismatch. Empty body; `payloadHash` is the well-known empty-body
    /// SHA-256, same as `delete`/`createDirectory`.
    ///
    /// Unlike `delete`/`createDirectory` (which go through
    /// `sendExpectingSuccess` and never look at the response body),
    /// `copyObject` inspects the body even on a 2xx: S3's server-side
    /// CopyObject is documented to sometimes answer `200 OK` with an
    /// `<Error>…</Error>` XML body when the copy fails partway through.
    /// `rename` unconditionally deletes the SOURCE right after a successful
    /// copy, so treating that "successful" 200 as real would delete the
    /// only remaining copy of the data. A real `CopyObjectResult` body never
    /// contains an `<Error` element, so a plain substring check is enough to
    /// catch this without a full XML parse.
    private func copyObject(fromKey: String, toKey: String) async throws {
        let copySource = "/\(config.bucket)/\(SigV4Signer.canonicalURI(path: fromKey))"
        let request = try buildSignedRequest(
            method: "PUT", key: toKey, query: [],
            extraHeaders: ["x-amz-copy-source": copySource], body: Data(),
            payloadHash: SigV4Signer.emptyPayloadHash)

        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.mapErrorStatus(response.statusCode, path: "/" + toKey)
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        if body.contains("<Error") || !body.contains("<CopyObjectResult") {
            throw RemoteFSError.protocolError(
                reason: "S3 copy failed: \(body.isEmpty ? "empty response body" : body)")
        }
    }

    /// Pages a signed `ListObjectsV2` call WITHOUT a delimiter, collecting
    /// every object's FULL raw key. Unlike `list`/`fetchPage` (which always
    /// list with `delimiter=/` and group anything past the next slash into
    /// `CommonPrefixes`), this flattens the entire subtree under `prefix`
    /// into one list of keys — exactly what `rename` needs to re-key a
    /// directory (and what `deleteTree`, M13/T8, will need to remove one).
    /// Follows `NextContinuationToken` pagination the same way `list` does.
    private func allObjectKeys(underPrefix prefix: String) async throws -> [String] {
        var keys: [String] = []
        var token: String?
        repeat {
            let request = try buildListRequest(prefix: prefix, continuationToken: token, delimiter: false)
            let (data, response) = try await send(request)
            guard (200..<300).contains(response.statusCode) else {
                throw Self.mapErrorStatus(response.statusCode, path: "/" + prefix)
            }
            let page = try Self.parseObjectKeys(data)
            keys.append(contentsOf: page.keys)
            token = page.continuationToken
        } while token != nil
        return keys
    }

    /// Parses a raw (no-delimiter) `ListObjectsV2` response into every
    /// `<Contents><Key>` value — no leaf-name stripping, no
    /// `CommonPrefixes`, unlike `S3ListParser` (which is built for the file
    /// browser's leaf-name/grouping needs and therefore cannot be reused
    /// where full keys are required). A small, focused counterpart kept
    /// private here rather than folded into `S3ListParser`, since its job
    /// (raw keys, no grouping) is genuinely different, not a variant of the
    /// same thing.
    private static func parseObjectKeys(_ data: Data) throws -> (keys: [String], continuationToken: String?) {
        final class Delegate: NSObject, XMLParserDelegate {
            var keys: [String] = []
            var continuationToken: String?
            private var isTruncated = false
            private var elementStack: [String] = []
            private var currentText = ""

            func parser(
                _ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]
            ) {
                elementStack.append(elementName)
                currentText = ""
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                currentText += string
            }

            func parser(
                _ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?
            ) {
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                let parent = elementStack.count >= 2 ? elementStack[elementStack.count - 2] : nil
                switch elementName {
                case "Key" where parent == "Contents":
                    keys.append(trimmed)
                case "IsTruncated":
                    isTruncated = trimmed.lowercased() == "true"
                case "NextContinuationToken":
                    continuationToken = trimmed
                default:
                    break
                }
                elementStack.removeLast()
                currentText = ""
            }

            func parserDidEndDocument(_ parser: XMLParser) {
                if !isTruncated { continuationToken = nil }
            }
        }

        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "unknown XML error"
            throw RemoteFSError.protocolError(reason: "Failed to parse S3 ListObjectsV2 response: \(reason)")
        }
        return (delegate.keys, delegate.continuationToken)
    }

    /// Sends a signed request whose only interesting outcome is
    /// success/failure — no response body to parse (`delete`,
    /// `createDirectory`, and later mutating operations). Shares the
    /// transport-error handling with every other request path via `send`,
    /// and the non-2xx status mapping with `fetchPage` via `mapErrorStatus`,
    /// so the two never drift into duplicated (and possibly inconsistent)
    /// HTTP-status handling.
    private func sendExpectingSuccess(_ request: URLRequest, path: String) async throws {
        let (_, response) = try await send(request)
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

    private func buildListRequest(
        prefix: String, continuationToken: String?, delimiter: Bool = true
    ) throws -> URLRequest {
        let queryPairs = Self.queryPairs(prefix: prefix, continuationToken: continuationToken, delimiter: delimiter)
        let url = try Self.requestURL(config: config, queryPairs: queryPairs)
        return try S3RequestSigning.signedRequest(
            url: url, method: "GET", canonicalPath: url.path.isEmpty ? "/" : url.path,
            query: queryPairs, extraHeaders: [:], body: nil,
            payloadHash: SigV4Signer.emptyPayloadHash, config: config)
    }

    /// Generalized signed-request builder — any HTTP method against an
    /// OBJECT KEY, with optional signed extra headers/body (later tasks:
    /// `x-amz-copy-source` for rename, `Content-MD5` for uploads). Decides
    /// the URL, the canonical path and the query, then hands the signing
    /// itself to `S3RequestSigning` — the same machinery `buildListRequest`
    /// hands its own bucket-root query to, just keyed on an object key.
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
        return try S3RequestSigning.signedRequest(
            url: url, method: method,
            canonicalPath: Self.canonicalKeyPath(config: config, key: key), query: query,
            extraHeaders: extraHeaders, body: body, payloadHash: payloadHash, config: config)
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
    ///
    /// An EMPTY key addresses the bucket resource itself (`deleteTree`'s
    /// `POST {bucket}?delete`, M13/T8), never an object with an empty-string
    /// name — path-style must therefore omit the trailing slash a naive
    /// `"/\(bucket)/\(key)"` concatenation would leave behind, matching
    /// `requestURL`'s bucket-root path (`"/" + bucket`, no trailing slash)
    /// used for `ListObjectsV2`.
    private static func canonicalKeyPath(config: S3ConnectionConfig, key: String) -> String {
        guard config.usePathStyle else { return "/\(key)" }
        return key.isEmpty ? "/\(config.bucket)" : "/\(config.bucket)/\(key)"
    }

    /// Builds the `<Delete>` XML body for one `DeleteObjects` batch — an
    /// `<Object><Key>…</Key></Object>` per key, XML-escaped (a key CAN
    /// contain "&" or "<", e.g. an object named "a&b.txt").
    private static func deleteObjectsXML(keys: [String]) throws -> Data {
        var xml = "<Delete>"
        for key in keys {
            xml += "<Object><Key>\(try S3XMLText.escaped(key))</Key></Object>"
        }
        xml += "</Delete>"
        return Data(xml.utf8)
    }

    /// Maps an absolute browser path to the S3 object key used for a FILE
    /// (unlike `s3Prefix`, no trailing slash — a key names one object, not
    /// a "directory" prefix): no leading slash, no trailing slash.
    private static func objectKey(forPath path: String) -> String {
        let normalized = RemotePath.normalizedAbsolute(path)
        if normalized == "/" { return "" }
        return String(normalized.dropFirst())
    }

    /// The `list-type`/`prefix`[/`delimiter`][/`continuation-token`] pairs
    /// for one ListObjectsV2 call, as raw (unencoded) `(name, value)`
    /// tuples. Built once and shared by both the signer
    /// (`authorizationHeader`, via `buildListRequest`) and the wire URL
    /// (`requestURL`) so the two can never see different query contents.
    ///
    /// `delimiter` defaults to `true` (the file-browser shape: group
    /// anything past the next `/` into `CommonPrefixes`); `allObjectKeys`
    /// passes `false` to get every key under `prefix` flattened, with no
    /// grouping, regardless of depth.
    private static func queryPairs(
        prefix: String, continuationToken: String?, delimiter: Bool = true
    ) -> [(name: String, value: String)] {
        var pairs: [(name: String, value: String)] = [
            (name: "list-type", value: "2"),
            (name: "prefix", value: prefix),
        ]
        if delimiter {
            pairs.append((name: "delimiter", value: "/"))
        }
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

/// M14/T2: `PresignedURLProvider` conformance — a time-limited signed URL
/// for a key, generated PURELY from the signer + the same URL-building
/// helpers `buildSignedRequest` uses, with no `transport` call at all.
extension S3FileSystem: PresignedURLProvider {
    public func presignedURL(method: PresignedMethod, key: String, expiresIn: TimeInterval) throws -> URL {
        let seconds = Int(max(1, min(604_800, expiresIn))) // SigV4 max 7 days
        // Base object URL (no query yet).
        let base = try Self.keyRequestURL(config: config, key: key, queryPairs: [])
        guard let host = base.host else {
            throw RemoteFSError.connectionFailed(reason: "S3 endpoint has no host: \(config.endpoint)")
        }
        let hostHeader = base.port.map { "\(host):\($0)" } ?? host
        let signer = SigV4Signer(
            accessKeyID: config.accessKeyID, secretAccessKey: config.secretAccessKey,
            region: config.region, service: "s3", sessionToken: config.sessionToken)
        let query = signer.presignedQuery(
            method: method.rawValue, host: hostHeader,
            path: Self.canonicalKeyPath(config: config, key: key),
            expiresInSeconds: seconds, date: Date())
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw RemoteFSError.protocolError(reason: "Failed to build presigned URL")
        }
        comps.percentEncodedQuery = SigV4Signer.canonicalQueryString(query: query)
        guard let url = comps.url else {
            throw RemoteFSError.protocolError(reason: "Failed to build presigned URL")
        }
        return url
    }
}

/// Splits an array into subarrays of at most `size` elements each — used by
/// `deleteTree` (M13/T8) to respect S3 `DeleteObjects`' 1000-key-per-call
/// limit. A non-positive `size` returns the whole array as one chunk rather
/// than looping forever or crashing on a zero-stride `stride`.
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
