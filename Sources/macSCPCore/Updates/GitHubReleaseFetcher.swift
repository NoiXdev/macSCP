import Foundation

/// Production `ReleaseFetcher`: reads the latest release of `NoiXdev/macSCP`
/// from the public GitHub REST API (spec §3).
///
/// No token, no authenticated request, no user data — the request carries
/// only the URL plus `Accept` and `User-Agent` headers (Global Constraints).
public struct GitHubReleaseFetcher: ReleaseFetcher {
    private static let releaseURL = URL(
        string: "https://api.github.com/repos/NoiXdev/macSCP/releases/latest")!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func latestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: Self.releaseURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("macSCP/update-check", forHTTPHeaderField: "User-Agent")
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
        guard let url = URL(string: payload.htmlURL) else {
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
