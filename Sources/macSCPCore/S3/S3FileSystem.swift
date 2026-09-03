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

    /// Where this connection's root sits, decided once in `connect` from
    /// `S3ConnectionConfig.startsAtBucketList` and never re-derived.
    ///
    /// `resolve` is the ONE place a browser path becomes an addressed S3
    /// resource, so the request builders below take a bucket and a key and
    /// never branch on strings themselves — the structural half of the
    /// bucket-list design (2026-09-02, design §4).
    enum RootMode: Equatable, Sendable {
        /// Today: the root IS one bucket, and the whole path is a key in it.
        case bucket(String)
        /// The root is the account's bucket list; the FIRST path component
        /// names the bucket, the rest is the key inside it.
        case bucketList

        /// `path` split into the bucket that answers for it and the key
        /// inside that bucket. `"/"` has no key (it is the bucket root in
        /// `.bucket` mode, and has no bucket at all in `.bucketList` mode,
        /// where it is the bucket list itself and callers must handle it
        /// before asking).
        func resolve(path: String) throws -> (bucket: String, key: String) {
            let components = RemotePath.normalizedAbsolute(path)
                .split(separator: "/").map(String.init)
            switch self {
            case .bucket(let bucket):
                return (bucket, components.joined(separator: "/"))
            case .bucketList:
                // Never fall back to the endpoint root: `GET /` is the
                // ACCOUNT's bucket list, so a bucketless path sent there
                // would address a different resource entirely — and a
                // DELETE or PUT would address it too.
                guard let bucket = components.first else {
                    throw RemoteFSError.protocolError(
                        reason: "S3: this connection starts at the bucket list, "
                            + "and \"\(path)\" names no bucket")
                }
                return (bucket, components.dropFirst().joined(separator: "/"))
            }
        }
    }

    private let mode: RootMode

    private init(
        config: S3ConnectionConfig, transport: any HTTPTransport, session: URLSession?,
        redirectPolicy: S3RedirectSessionDelegate?
    ) {
        self.mode = config.startsAtBucketList ? .bucketList : .bucket(config.bucket)
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
            switch fs.mode {
            case .bucket(let bucket):
                _ = try await fs.fetchPage(bucket: bucket, prefix: "", continuationToken: nil)
            case .bucketList:
                // The permission is checked HERE, once, so the failure lands
                // on the form the user is looking at rather than deep in the
                // browser (design §2). An account with no buckets is its own
                // outcome for the same reason: an empty browser explains
                // nothing.
                if try await fs.listBuckets().isEmpty {
                    throw RemoteFSError.bucketListEmpty
                }
            }
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
        if isBucketListRoot(path) { return try await listBuckets() }
        let (bucket, prefix) = try resolvePrefix(path: path)
        var items: [RemoteFileItem] = []
        var token: String?
        repeat {
            let page = try await fetchPage(bucket: bucket, prefix: prefix, continuationToken: token)
            items.append(contentsOf: page.items)
            token = page.continuationToken
        } while token != nil
        return items
    }

    /// True for the one path that IS the bucket list rather than something
    /// inside a bucket. `RootMode.resolve` refuses it (there is no bucket to
    /// route to), so every caller that can answer it must ask first.
    private func isBucketListRoot(_ path: String) -> Bool {
        guard case .bucketList = mode else { return false }
        return RemotePath.normalizedAbsolute(path) == "/"
    }

    /// Refuses an operation whose target IS a bucket rather than something
    /// inside one — the resolved key is empty.
    ///
    /// Only in `.bucketList` mode: with the toggle off the very same path
    /// is the bucket ROOT, where these calls have always been the caller's
    /// business, and this must change nothing there.
    ///
    /// The design offers exactly one action on a bucket row — open it — and
    /// this is that rule where it cannot be bypassed, rather than a promise
    /// the browser makes. `rename("/b1", "/b2")` would otherwise re-key
    /// every object of one bucket into another and delete the originals;
    /// `deleteTree("/b1")` would empty it. Both from one keystroke on a row
    /// that looks like a folder.
    ///
    /// SCOPE: every operation that addresses a bucket as if it were an
    /// object — the mutating ones, `presignedURL` (the one seam that hands
    /// write capability OUT of this process, where a PUT to a path-style
    /// bucket root is `CreateBucket`, Task 2 review I-1), and `readStream`
    /// (Task 2 review M-3, closed in Task 4: a ranged GET on a bucket root
    /// is answered with the bucket's LISTING, delivered as file bytes).
    /// `list` and `stat` are the two calls a bucket legitimately answers,
    /// and they are the two that do not come through here.
    ///
    /// `operation` names the call being refused, so the error says which
    /// rule stopped what — and so a test can assert the refusal per
    /// operation instead of settling for an aggregate request count. It is
    /// an enum, so every renderer of the refusal is compile-forced to have
    /// a sentence for it.
    private func refuseBucketLevelOperation(
        _ operation: RemoteFSError.BucketLevelOperation, path: String
    ) throws {
        guard case .bucketList = mode else { return }
        guard try mode.resolve(path: path).key.isEmpty else { return }
        throw RemoteFSError.bucketLevelRefused(operation: operation, path: path)
    }

    /// The BROWSER path a caller would recognize for an addressed S3
    /// resource — the exact inverse of `RootMode.resolve`, and the string
    /// every error raised below the resolver names.
    ///
    /// Task 2 review M-2: those errors used to be built as `"/" + key`,
    /// which in bucket-list mode drops the bucket. A 404 deleting
    /// `/second/dir/file.txt` then reported `.notFound(path: "/dir/file.txt")`
    /// — a path that exists in no browser and can name a real object in a
    /// DIFFERENT bucket. In `.bucket` mode the two are the same string, so
    /// nothing there changes.
    ///
    /// `key` may be a listing PREFIX (trailing slash and all); it is not
    /// re-normalized, so whatever shape the caller reports stays that shape
    /// under its bucket.
    private func reportedPath(bucket: String, key: String) -> String {
        switch mode {
        case .bucket:
            return "/" + key
        case .bucketList:
            return key.isEmpty ? "/" + bucket : "/" + bucket + "/" + key
        }
    }

    /// The bucket that answers for `path` and the KEY PREFIX inside it —
    /// `RootMode.resolve` plus the trailing slash a `ListObjectsV2` prefix
    /// carries (`""` for a bucket root, `"sub/"` under `sub`). The former
    /// `s3Prefix(forPath:)`, now that the bucket is part of the answer.
    private func resolvePrefix(path: String) throws -> (bucket: String, prefix: String) {
        let (bucket, key) = try mode.resolve(path: path)
        return (bucket, key.isEmpty ? "" : key + "/")
    }

    /// The entry at `path`, found the way `listedEntry` describes below.
    public func stat(path: String) async throws -> RemoteFileItem {
        try await listedEntry(at: path).item
    }

    /// One entry of a listing, plus the raw `<ETag>` text the listing
    /// carried for it. `eTag` is `nil` for anything that is not an object —
    /// a `CommonPrefixes` "directory", or the bucket root.
    private struct ListedEntry {
        let item: RemoteFileItem
        let eTag: String?
    }

    /// Looks up a single entry by listing its PARENT with a delimiter and
    /// matching the leaf name — S3 has no dedicated "stat a single key"
    /// call that also tells you whether a key is a `CommonPrefixes` (a
    /// "directory"), so this reuses the same signed-list machinery `list`
    /// uses rather than adding a second, subtly-different request path.
    ///
    /// `stat` and `remoteChecksum` are its callers, and it exists as one
    /// function because they want the same walk over the same pages: the
    /// checksum capability's whole source is the ETag that comes back in
    /// THIS listing, so a second, separate lookup for it would be the
    /// "subtly-different request path" the paragraph above rules out.
    private func listedEntry(at path: String) async throws -> ListedEntry {
        let normalized = RemotePath.normalizedAbsolute(path)
        if normalized == "/" {
            return ListedEntry(
                item: RemoteFileItem(name: "/", path: "/", kind: .directory), eTag: nil)
        }
        if case .bucketList = mode, normalized.split(separator: "/").count == 1 {
            // A BUCKET's own entry does not live in any bucket listing: the
            // level above it is the account's bucket list, so that is where
            // it is looked up. Never an ETag — a bucket is not an object.
            guard let row = try await listBuckets().first(where: { $0.path == normalized }) else {
                throw RemoteFSError.notFound(path: path)
            }
            return ListedEntry(item: row, eTag: nil)
        }
        let leafName = normalized.split(separator: "/").last.map(String.init) ?? normalized
        let (bucket, parentPrefix) = try resolvePrefix(path: RemotePath.parent(of: normalized))

        var token: String?
        repeat {
            let page = try await fetchPage(
                bucket: bucket, prefix: parentPrefix, continuationToken: token)
            if let match = page.items.first(where: { $0.name == leafName }) {
                return ListedEntry(item: match, eTag: page.eTags[match.path])
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
        try refuseBucketLevelOperation(.readStream, path: path)
        let (bucket, key) = try mode.resolve(path: path)
        var request = try buildSignedRequest(
            bucket: bucket, method: "GET", key: key, query: [],
            payloadHash: SigV4Signer.emptyPayloadHash)
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
        try refuseBucketLevelOperation(.write, path: path)
        try await S3Uploader().upload(key: Self.objectKey(forPath: path), contents: contents, using: self)
    }

    /// A signed `DELETE` on the object key. S3's `DeleteObject` is
    /// idempotent and returns 204 whether or not the key existed, but a
    /// non-2xx (403/404/other) is still mapped through `sendExpectingSuccess`
    /// like any other request. Delegates to the raw-key overload below.
    public func delete(path: String) async throws {
        try refuseBucketLevelOperation(.delete, path: path)
        let (bucket, key) = try mode.resolve(path: path)
        try await delete(bucket: bucket, key: key)
    }

    /// Raw-key counterpart to `delete(path:)`, for callers that already hold
    /// a full S3 object key rather than a browser path — `rename` (M13/T7,
    /// re-keying a directory) and `deleteTree` (M13/T8) both enumerate keys
    /// via `allObjectKeys(underPrefix:)` and need to delete exactly those
    /// keys, including a directory's own trailing-slash marker key, which
    /// `objectKey(forPath:)` cannot address (it always strips trailing
    /// slashes).
    private func delete(bucket: String, key: String) async throws {
        let request = try buildSignedRequest(
            bucket: bucket, method: "DELETE", key: key, query: [],
            payloadHash: SigV4Signer.emptyPayloadHash)
        try await sendExpectingSuccess(request, path: reportedPath(bucket: bucket, key: key))
    }

    /// Creates a 0-byte marker object whose key ends in "/" — the universal
    /// S3 convention for representing an empty "folder" (S3 itself has no
    /// directory concept; every other S3-compatible tool and console
    /// recognizes this marker). Idempotent: re-PUTting the same marker is
    /// harmless.
    public func createDirectory(at path: String) async throws {
        try refuseBucketLevelOperation(.createDirectory, path: path)
        let (bucket, key) = try mode.resolve(path: path)
        let markerKey = key + "/"
        let request = try buildSignedRequest(
            bucket: bucket, method: "PUT", key: markerKey, query: [], body: Data(),
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
    ///
    /// In bucket-list mode the two ends could name two different buckets,
    /// which would spread exactly that half-failure across a permission
    /// boundary. They may not: see the guard below and
    /// `RemoteFSError.crossBucketRenameRefused`.
    public func rename(from: String, to: String) async throws {
        // Both ends, and before the destination pre-check, so a refused
        // rename issues no request at all.
        try refuseBucketLevelOperation(.rename, path: from)
        try refuseBucketLevelOperation(.rename, path: to)
        // ...and neither may this rename leave the bucket it started in.
        // `copyObject` can address two buckets since 2026-09-02, which is
        // what made the shape reachable at all; see
        // `RemoteFSError.crossBucketRenameRefused` for why it is refused
        // rather than performed.
        guard try mode.resolve(path: from).bucket == mode.resolve(path: to).bucket else {
            throw RemoteFSError.crossBucketRenameRefused(from: from, to: to)
        }
        do {
            _ = try await stat(path: to)
            throw RemoteFSError.protocolError(reason: "Destination already exists: \(to)")
        } catch RemoteFSError.notFound {
            // Confirmed absent — safe to proceed.
        }
        let fromKind = try await stat(path: from).kind
        if fromKind == .directory {
            let (fromBucket, fromPrefix) = try resolvePrefix(path: from)
            let (toBucket, toPrefix) = try resolvePrefix(path: to)
            for key in try await allObjectKeys(bucket: fromBucket, underPrefix: fromPrefix) {
                let destKey = toPrefix + key.dropFirst(fromPrefix.count)
                try await copyObject(
                    sourceBucket: fromBucket, fromKey: key,
                    destinationBucket: toBucket, toKey: String(destKey))
                try await delete(bucket: fromBucket, key: key)
            }
        } else {
            let (fromBucket, fromKey) = try mode.resolve(path: from)
            let (toBucket, toKey) = try mode.resolve(path: to)
            try await copyObject(
                sourceBucket: fromBucket, fromKey: fromKey,
                destinationBucket: toBucket, toKey: toKey)
            try await delete(bucket: fromBucket, key: fromKey)
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
        try refuseBucketLevelOperation(.deleteTree, path: path)
        let (bucket, treePrefix) = try resolvePrefix(path: path)
        let keys = try await allObjectKeys(bucket: bucket, underPrefix: treePrefix)
        for batch in keys.chunked(into: 1000) {
            try Task.checkCancellation()
            let body = try Self.deleteObjectsXML(keys: batch)
            let md5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
            let request = try buildSignedRequest(
                bucket: bucket, method: "POST", key: "", query: [(name: "delete", value: "")],
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

    /// The one overrider in the tree (2026-09-02): with the toggle on, `/`
    /// is the account's bucket list and its rows are buckets. With it off
    /// this is a bucket's own root, which holds objects like any directory,
    /// so the answer is the protocol's default.
    ///
    /// Derived from `mode`, not from `config.startsAtBucketList`, so it can
    /// only ever agree with the resolver that decides what every path means.
    public var rootIsContainerList: Bool {
        if case .bucketList = mode { return true }
        return false
    }

    // MARK: - S3RequestBuilder conformance (thin wrappers for S3Uploader, M13/T5)

    /// `S3RequestBuilder.signedRequest`: a thin pass-through to
    /// `buildSignedRequest` so `S3Uploader` can sign a PUT without knowing
    /// about `S3ConnectionConfig` or `SigV4Signer` directly.
    public func signedRequest(
        method: String, key: String, query: [(name: String, value: String)],
        extraHeaders: [String: String], body: Data?, payloadHash: String
    ) throws -> URLRequest {
        // `key` crossed a seam that knows nothing about buckets, so it is
        // the mode key `objectKey(forPath:)` produced — split it again
        // through the one resolver rather than assuming a bucket here.
        let (bucket, objectKey) = try mode.resolve(path: "/" + key)
        return try buildSignedRequest(
            bucket: bucket, method: method, key: objectKey, query: query,
            extraHeaders: extraHeaders, body: body, payloadHash: payloadHash)
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
        bucket: String, prefix: String, continuationToken: String?
    ) async throws -> (items: [RemoteFileItem], continuationToken: String?, eTags: [String: String]) {
        let request = try buildListRequest(
            bucket: bucket, prefix: prefix, continuationToken: continuationToken)
        let (data, response) = try await send(request)

        switch response.statusCode {
        case 200..<300:
            let page = try S3ListParser.parse(data, prefix: prefix)
            return rerootedIntoBucket(bucket, page)
        default:
            throw Self.mapErrorStatus(response.statusCode, path: reportedPath(bucket: bucket, key: prefix))
        }
    }

    /// The listing's items carry BUCKET-relative paths (`"/a.txt"`), because
    /// that is all a `ListObjectsV2` response knows. In bucket-list mode a
    /// browser path starts with the bucket, so every path handed back is
    /// prefixed with it — the exact inverse of `RootMode.resolve`, without
    /// which the next navigation would resolve `/a.txt` against whatever
    /// bucket its first component happened to name. A no-op in
    /// `.bucket` mode, where the two are the same string.
    private func rerootedIntoBucket(
        _ bucket: String,
        _ page: (items: [RemoteFileItem], continuationToken: String?, eTags: [String: String])
    ) -> (items: [RemoteFileItem], continuationToken: String?, eTags: [String: String]) {
        guard case .bucketList = mode else { return page }
        let root = "/" + bucket
        let items = page.items.map {
            RemoteFileItem(
                name: $0.name, path: root + $0.path, kind: $0.kind, size: $0.size,
                modifiedAt: $0.modifiedAt, permissions: $0.permissions,
                owner: $0.owner, group: $0.group)
        }
        let eTags = Dictionary(uniqueKeysWithValues: page.eTags.map { (root + $0.key, $0.value) })
        return (items, page.continuationToken, eTags)
    }

    /// One signed `GET /` on the BARE endpoint — S3's account-level
    /// `ListBuckets` — parsed into one directory row per bucket. Called on
    /// connect in bucket-list mode, and again whenever `/` is listed.
    ///
    /// 403 is `bucketListForbidden` rather than `.authenticationFailed`:
    /// the key authenticated fine, it just may not enumerate the account's
    /// buckets. Everything else keeps the mapping every other request has,
    /// so a provider that does not implement `ListBuckets` at all is not
    /// reported as a missing permission.
    private func listBuckets() async throws -> [RemoteFileItem] {
        let url = try Self.bucketListURL(config: config)
        let request = try S3RequestSigning.signedRequest(
            url: url, method: "GET", canonicalPath: "/", query: [], extraHeaders: [:],
            body: nil, payloadHash: SigV4Signer.emptyPayloadHash, config: config)
        let (data, response) = try await send(request)

        switch response.statusCode {
        case 200..<300:
            return try S3ListParser.parseBuckets(data)
        case 403:
            throw RemoteFSError.bucketListForbidden
        default:
            throw Self.mapErrorStatus(response.statusCode, path: "/")
        }
    }

    /// `ListBuckets` is an ACCOUNT-level call: it is always `GET /` on the
    /// endpoint's own host, in BOTH addressing styles. Virtual-hosted
    /// addressing has no bucket to put in front of the host here — and with
    /// an empty one, `"\(bucket).\(host)"` would resolve to a different
    /// name entirely — so this deliberately does not go through
    /// `requestURL`.
    private static func bucketListURL(config: S3ConnectionConfig) throws -> URL {
        guard var components = S3FieldSchema.endpointComponents(config.endpoint) else {
            throw RemoteFSError.connectionFailed(reason: "Invalid S3 endpoint: \(config.endpoint)")
        }
        components.percentEncodedPath = "/"
        components.percentEncodedQuery = nil
        guard let url = components.url else {
            throw RemoteFSError.connectionFailed(
                reason: "Failed to build S3 request URL for endpoint: \(config.endpoint)")
        }
        return url
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
    private func copyObject(
        sourceBucket: String, fromKey: String, destinationBucket: String, toKey: String
    ) async throws {
        let copySource = "/\(sourceBucket)/\(SigV4Signer.canonicalURI(path: fromKey))"
        let request = try buildSignedRequest(
            bucket: destinationBucket, method: "PUT", key: toKey, query: [],
            extraHeaders: ["x-amz-copy-source": copySource], body: Data(),
            payloadHash: SigV4Signer.emptyPayloadHash)

        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.mapErrorStatus(response.statusCode, path: reportedPath(bucket: destinationBucket, key: toKey))
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
    private func allObjectKeys(bucket: String, underPrefix prefix: String) async throws -> [String] {
        var keys: [String] = []
        var token: String?
        repeat {
            let request = try buildListRequest(
                bucket: bucket, prefix: prefix, continuationToken: token, delimiter: false)
            let (data, response) = try await send(request)
            guard (200..<300).contains(response.statusCode) else {
                throw Self.mapErrorStatus(response.statusCode, path: reportedPath(bucket: bucket, key: prefix))
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
        bucket: String, prefix: String, continuationToken: String?, delimiter: Bool = true
    ) throws -> URLRequest {
        let queryPairs = Self.queryPairs(prefix: prefix, continuationToken: continuationToken, delimiter: delimiter)
        let url = try Self.requestURL(config: config, bucket: bucket, queryPairs: queryPairs)
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
        bucket: String, method: String, key: String, query: [(name: String, value: String)],
        extraHeaders: [String: String] = [:], body: Data? = nil,
        payloadHash: String
    ) throws -> URLRequest {
        let url = try Self.keyRequestURL(config: config, bucket: bucket, key: key, queryPairs: query)
        return try S3RequestSigning.signedRequest(
            url: url, method: method,
            canonicalPath: Self.canonicalKeyPath(config: config, bucket: bucket, key: key),
            query: query,
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
        config: S3ConnectionConfig, bucket: String, key: String,
        queryPairs: [(name: String, value: String)]
    ) throws -> URL {
        guard var components = S3FieldSchema.endpointComponents(config.endpoint) else {
            throw RemoteFSError.connectionFailed(reason: "Invalid S3 endpoint: \(config.endpoint)")
        }
        if config.usePathStyle {
            components.percentEncodedPath = SigV4Signer.canonicalURI(
                path: canonicalKeyPath(config: config, bucket: bucket, key: key))
        } else {
            guard let host = components.host else {
                throw RemoteFSError.connectionFailed(reason: "Invalid S3 endpoint host: \(config.endpoint)")
            }
            components.host = "\(bucket).\(host)"
            components.percentEncodedPath = SigV4Signer.canonicalURI(
                path: canonicalKeyPath(config: config, bucket: bucket, key: key))
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
    private static func canonicalKeyPath(
        config: S3ConnectionConfig, bucket: String, key: String
    ) -> String {
        guard config.usePathStyle else { return "/\(key)" }
        return key.isEmpty ? "/\(bucket)" : "/\(bucket)/\(key)"
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

    /// Maps an absolute browser path to the KEY the seams outside this file
    /// speak in — `S3RequestBuilder.signedRequest` (the uploader) and
    /// `PresignedURLProvider.presignedURL` (the App): the path with no
    /// leading and no trailing slash. In `.bucket` mode that IS the S3
    /// object key; in `.bucketList` mode it still carries the bucket as its
    /// first component, and both seams hand it straight back to
    /// `RootMode.resolve` to split it again. `write` is its only caller
    /// here — everything else resolves the path to a `(bucket, key)` pair
    /// directly.
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
        config: S3ConnectionConfig, bucket: String, queryPairs: [(name: String, value: String)]
    ) throws -> URL {
        guard var components = S3FieldSchema.endpointComponents(config.endpoint) else {
            throw RemoteFSError.connectionFailed(reason: "Invalid S3 endpoint: \(config.endpoint)")
        }
        if config.usePathStyle {
            components.path = "/" + bucket
        } else {
            guard let host = components.host else {
                throw RemoteFSError.connectionFailed(reason: "Invalid S3 endpoint host: \(config.endpoint)")
            }
            components.host = "\(bucket).\(host)"
            components.path = ""
        }

        components.percentEncodedQuery = SigV4Signer.canonicalQueryString(query: queryPairs)

        guard let url = components.url else {
            throw RemoteFSError.connectionFailed(reason: "Failed to build S3 request URL for endpoint: \(config.endpoint)")
        }
        return url
    }
}

/// M14/T2: `PresignedURLProvider` conformance — a time-limited signed URL
/// for a key, generated PURELY from the signer + the same URL-building
/// helpers `buildSignedRequest` uses, with no `transport` call at all.
extension S3FileSystem: PresignedURLProvider {
    public func presignedURL(method: PresignedMethod, key: String, expiresIn: TimeInterval) throws -> URL {
        let seconds = Int(max(1, min(604_800, expiresIn))) // SigV4 max 7 days
        // Same seam as `signedRequest` above: a `key` from outside is a mode
        // key, and only `RootMode.resolve` knows which bucket it names.
        //
        // Refused at bucket level like the mutating operations (Task 2
        // review, I-1). `PresignedURLSheet` lets the user TYPE the target
        // key for a PUT, and every key ever typed there was bucket-relative
        // — so in this mode a plain `x.txt` resolves to the bucket `x.txt`
        // with an empty key, and a path-style PUT to a bucket root is
        // `CreateBucket`, signed and handed to a third party. `.get` is
        // refused by the same line and for its own reason: a signed GET on
        // a bucket root is that bucket's whole listing.
        try refuseBucketLevelOperation(.presignedURL, path: "/" + key)
        let (bucket, objectKey) = try mode.resolve(path: "/" + key)
        // Base object URL (no query yet).
        let base = try Self.keyRequestURL(
            config: config, bucket: bucket, key: objectKey, queryPairs: [])
        guard let host = base.host else {
            throw RemoteFSError.connectionFailed(reason: "S3 endpoint has no host: \(config.endpoint)")
        }
        let hostHeader = base.port.map { "\(host):\($0)" } ?? host
        let signer = SigV4Signer(
            accessKeyID: config.accessKeyID, secretAccessKey: config.secretAccessKey,
            region: config.region, service: "s3", sessionToken: config.sessionToken)
        let query = signer.presignedQuery(
            method: method.rawValue, host: hostHeader,
            path: Self.canonicalKeyPath(config: config, bucket: bucket, key: objectKey),
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

/// The checksum capability for an object store, which is a different kind of
/// answer from SSH's: **nothing is computed on request here.** S3 offers no
/// way to ask a bucket for a digest, and the maintainer's ruling of
/// 2026-08-27 rules out the alternative — downloading the object to hash it
/// — explicitly, and not as a fallback either. What is left is the digest
/// the store already published: the `ETag` that came back in the listing.
///
/// That value is not always the object's hash, which is the whole reason
/// `ChecksumProvenance` exists. An upload that arrived in one part has an
/// ETag that IS the MD5 of the bytes; a multipart upload has an MD5 over the
/// parts' MD5s with `-N` appended — and that shape turns up on exactly the
/// large files somebody wants to check. Both come back as values, because
/// hiding the composite and passing it off as a file hash are both worse
/// than showing it for what it is; which one it was is carried in the
/// result's provenance, where a display cannot drop it without dropping the
/// value with it.
extension S3FileSystem: RemoteChecksumProvider {
    /// The ETag of the object at `path`, read for what it is.
    ///
    /// `algorithm` is a REQUEST, not a promise, and this is the one backend
    /// where the two can differ: a store computes nothing on demand, so the
    /// only digest available is the ETag's MD5 whatever was asked for. The
    /// answer names its own algorithm (`FileChecksum.algorithm`) and its own
    /// origin, so nothing labelled SHA-256 ever comes back carrying an MD5.
    ///
    /// Never `.unavailableOnThisConnection`: that case says a connection
    /// cannot answer for any file, and this one can. An ETag that is not a
    /// digest at all — some stores put opaque text there — is a failure
    /// instead, the same treatment the SSH path gives output it cannot read.
    public func remoteChecksum(
        forFileAt path: String, algorithm: ChecksumAlgorithm
    ) async throws -> RemoteChecksumOutcome {
        let entry = try await listedEntry(at: path)
        guard entry.item.kind == .file else {
            throw RemoteFSError.protocolError(reason: "path is a directory: \(path)")
        }
        guard let raw = entry.eTag else {
            throw RemoteFSError.protocolError(reason: "the listing carried no ETag for this object")
        }
        guard let checksum = FileChecksum.objectStorageETag(raw) else {
            throw RemoteFSError.protocolError(reason: "the object's ETag is not a checksum")
        }
        return .checksum(checksum)
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
