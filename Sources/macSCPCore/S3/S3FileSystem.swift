import Foundation

/// Thin S3 (and S3-compatible: MinIO, R2, Hetzner, …) implementation of
/// `RemoteFileSystem` (M12/T5). `connect`/`list`/`stat` are real, signed
/// `ListObjectsV2` calls; every mutating operation throws
/// `RemoteFSError.protocolError` — those land in M13.
///
/// `Sendable` by construction rather than `@unchecked`: both stored
/// properties are immutable and themselves `Sendable` (`S3ConnectionConfig`
/// is a `Sendable` struct; `any S3HTTPTransport` requires `Sendable`), so
/// there is no shared mutable state to race on.
public final class S3FileSystem: RemoteFileSystem {
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

    public func readStream(path: String, fromOffset offset: UInt64) async throws -> AsyncThrowingStream<Data, Error> {
        throw RemoteFSError.protocolError(reason: "S3 read is not supported yet (M13)")
    }

    public func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {
        throw RemoteFSError.protocolError(reason: "S3 write is not supported yet (M13)")
    }

    public func delete(path: String) async throws {
        throw RemoteFSError.protocolError(reason: "S3 delete is not supported yet (M13)")
    }

    public func createDirectory(at path: String) async throws {
        throw RemoteFSError.protocolError(reason: "S3 create-directory is not supported yet (M13)")
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
        case 403:
            throw RemoteFSError.authenticationFailed
        case 404:
            throw RemoteFSError.notFound(path: "/" + prefix)
        default:
            throw RemoteFSError.protocolError(reason: "S3 request failed with HTTP status \(response.statusCode)")
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
