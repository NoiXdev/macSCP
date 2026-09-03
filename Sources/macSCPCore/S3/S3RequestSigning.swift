import Foundation

/// The one place a signed S3 request is assembled: `Host`, `Authorization`
/// and the signer's companion headers set on a `URLRequest` whose URL and
/// signed canonical path/query are guaranteed to be the same ones.
///
/// It exists because a redirect has to be signed by the same machinery the
/// first request was. `signedRequest` has two callers, counted here on
/// 2026-09-03: `S3FileSystem.signedRequest(_:method:query:…)`, the factory
/// that turns one of three RESOURCE shapes into the URL and the canonical
/// path signed beside it (every ordinary request in this module goes through
/// it), and `reSigned` below, which is what
/// `S3RedirectSessionDelegate` reaches for. A redirect
/// re-signed by patching Foundation's proposed request would keep the
/// `Host` the first request was signed with, which is the stale value the
/// measurement found travelling to a foreign origin. Rebuilt through here,
/// the `Host` is set for the new target and signed with it, so the stale
/// one cannot survive: there is nothing to fix, because nothing is carried.
enum S3RequestSigning {

    /// Signs one request. `canonicalPath` is the RAW, pre-encoding path the
    /// signature covers — never `URL.path`, which drops a trailing slash
    /// and would produce a signature mismatch for a folder-marker key.
    /// `extraHeaders` are SIGNED; a header that must not be signed (`Range`)
    /// is set by the caller on the returned request.
    static func signedRequest(
        url: URL, method: String, canonicalPath: String,
        query: [(name: String, value: String)], extraHeaders: [String: String],
        body: Data?, payloadHash: String, config: S3ConnectionConfig
    ) throws -> URLRequest {
        guard let host = url.host else {
            throw RemoteFSError.connectionFailed(reason: "S3 endpoint has no host: \(config.endpoint)")
        }
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host

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
        for (key, value) in signed { request.setValue(value, forHTTPHeaderField: key) }
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        if let body { request.httpBody = body }
        return request
    }

    /// Rebuilds a request for the target of a redirect that
    /// `S3RedirectDecision` has already judged same-origin.
    ///
    /// The wire URL is rebuilt from the target's own path and query with
    /// the signer's encoding rules, rather than passed through as Foundation
    /// proposed it, so the request that goes out and the string that was
    /// signed cannot diverge — the same reason `keyRequestURL` and
    /// `requestURL` assign `percentEncodedPath`/`percentEncodedQuery`
    /// instead of letting `URLComponents` re-encode. One consequence worth
    /// naming: a `Location` that percent-encodes a slash INSIDE a segment
    /// (`%2F`) is normalized to a plain separator, so such a target is
    /// followed as the path it decodes to. It stays inside the endpoint's
    /// own origin either way.
    ///
    /// **This depends on the S3 path having no streaming request body.**
    /// Every body it builds is a `Data` in memory or absent, so a request
    /// can be reproduced faithfully and its payload hash recomputed. A
    /// stream cannot be read twice; `S3RedirectSessionDelegate` refuses a
    /// redirect that would need one rather than send a request signed for
    /// bytes it cannot resend.
    static func reSigned(
        target: URL, method: String, body: Data?,
        signedHeaders: [String: String], unsignedHeaders: [String: String],
        config: S3ConnectionConfig
    ) throws -> URLRequest {
        guard var components = URLComponents(url: target, resolvingAgainstBaseURL: false) else {
            throw RemoteFSError.connectionFailed(reason: "S3 redirect target is not a valid URL")
        }
        let encodedPath = components.percentEncodedPath
        let rawPath = encodedPath.removingPercentEncoding ?? encodedPath
        let canonicalPath = rawPath.isEmpty ? "/" : rawPath
        let query = queryPairs(from: components.percentEncodedQuery)

        components.percentEncodedPath = SigV4Signer.canonicalURI(path: canonicalPath)
        components.percentEncodedQuery =
            query.isEmpty ? nil : SigV4Signer.canonicalQueryString(query: query)
        guard let url = components.url else {
            throw RemoteFSError.connectionFailed(reason: "S3 redirect target could not be rebuilt")
        }

        var request = try signedRequest(
            url: url, method: method, canonicalPath: canonicalPath, query: query,
            extraHeaders: signedHeaders, body: body,
            payloadHash: body.map(SigV4Signer.hexSHA256) ?? SigV4Signer.emptyPayloadHash,
            config: config)
        for (key, value) in unsignedHeaders { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    /// The raw `(name, value)` pairs of a percent-encoded query string, for
    /// handing back to the signer — which re-encodes them itself. A pair
    /// with no `=` is a name with an empty value, which is how S3's own
    /// sub-resource queries (`?delete`, `?uploads`) are shaped.
    private static func queryPairs(from percentEncoded: String?) -> [(name: String, value: String)] {
        guard let percentEncoded, !percentEncoded.isEmpty else { return [] }
        return percentEncoded.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]) : ""
            return (name: name.removingPercentEncoding ?? name,
                    value: value.removingPercentEncoding ?? value)
        }
    }
}
