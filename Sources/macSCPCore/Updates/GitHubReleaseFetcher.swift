import Foundation

/// Production `ReleaseFetcher`: reads the latest release of `NoiXdev/macSCP`
/// from the public GitHub REST API (spec §3).
///
/// No token, no authenticated request, no user data — the request carries
/// only the URL plus `Accept`, `User-Agent` and a fixed `Accept-Language`
/// header (Global Constraints). `Accept-Language` is pinned to `"en"` so the
/// system locale — otherwise sent by default by `URLSession` and a weak
/// fingerprinting signal — never travels with the request (M11b final
/// review, Finding I1). The session defaults to an ephemeral configuration
/// (Finding M4) so the request never touches the process-wide cookie store
/// or URL cache either.
public struct GitHubReleaseFetcher: ReleaseFetcher {
    private static let releaseURL = URL(
        string: "https://api.github.com/repos/NoiXdev/macSCP/releases/latest")!

    private let session: URLSession

    /// The version substituted into the `User-Agent` header (`macSCP/<version>`,
    /// spec §2). Defaulted so existing call sites and tests that don't care
    /// about the header's exact value keep compiling; the App layer passes
    /// the actual bundle version (`CFBundleShortVersionString`) — Core stays
    /// bundle-free itself.
    private let userAgentVersion: String

    public init(
        session: URLSession = URLSession(configuration: .ephemeral),
        userAgentVersion: String = "update-check"
    ) {
        self.session = session
        self.userAgentVersion = userAgentVersion
    }

    public func latestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: Self.releaseURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("macSCP/\(userAgentVersion)", forHTTPHeaderField: "User-Agent")
        // Fixed, never the system locale (Finding I1) — see the type doc above.
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // `URLSession` throws `URLError` for anything transport-level
            // (no connection, DNS failure, timeout, ...) — all of that maps
            // to `.offline` (spec §3).
            throw UpdateCheckError.offline
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.malformedResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 403 || httpResponse.statusCode == 429,
                httpResponse.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
            {
                throw UpdateCheckError.rateLimited
            }
            throw UpdateCheckError.httpStatus(httpResponse.statusCode)
        }

        guard let payload = try? JSONDecoder().decode(ReleasePayload.self, from: data) else {
            throw UpdateCheckError.malformedResponse
        }
        // The URL comes from the API response, not a fixed constant — never
        // hand an unvalidated URL to `NSWorkspace.shared.open` downstream
        // (M11b final review, Finding M1). Restricted to `https://github.com`
        // (and `www.github.com`); anything else — `file://`, a different
        // host, a scheme-less string — is treated the same as any other
        // malformed payload.
        guard let url = URL(string: payload.htmlURL),
            url.scheme == "https",
            let host = url.host,
            host == "github.com" || host == "www.github.com"
        else {
            throw UpdateCheckError.malformedResponse
        }
        return ReleaseInfo(tag: payload.tagName, url: url)
    }

    /// Minimal shape of the fields this app reads from GitHub's release
    /// JSON — everything else in the payload is ignored.
    private struct ReleasePayload: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}
