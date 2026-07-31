import Foundation
import Testing
@testable import macSCPCore

/// `URLProtocol` stub registered on an ephemeral `URLSessionConfiguration` —
/// intercepts every request made through a session configured with it, so
/// `GitHubReleaseFetcherTests` never touches the real network. Any request
/// whose URL doesn't match what a test expects fails loudly via
/// `Issue.record` (through `unexpectedRequest`) instead of silently letting
/// a real network call through.
///
/// `@Suite(.serialized)` on the test suite below serializes access to the
/// static `handler`/`unexpectedRequest` state (same cross-test-static-state
/// pattern as `AgentAuthTests`) — this suite is the ONLY place that touches
/// them, so serializing within it is sufficient.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var expectedURL: URL?
    nonisolated(unsafe) static var unexpectedRequestSeen = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let expectedURL = Self.expectedURL, request.url != expectedURL {
            Self.unexpectedRequestSeen = true
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset(expecting url: URL) {
        expectedURL = url
        unexpectedRequestSeen = false
        handler = nil
    }
}

/// `GitHubReleaseFetcher` (spec §2/§3): builds the exact GitHub REST
/// request, parses a 200 response, and maps non-200 statuses (including the
/// rate-limit special case) to typed `UpdateCheckError`s. Every test proves
/// it never dials the real network: the stub fails the test outright if a
/// request for anything other than the expected release URL is made.
@Suite("GitHubReleaseFetcher", .serialized)
struct GitHubReleaseFetcherTests {
    private static let expectedURL = URL(
        string: "https://api.github.com/repos/NoiXdev/macSCP/releases/latest")!

    @Test func buildsCorrectRequest() async throws {
        StubURLProtocol.reset(expecting: Self.expectedURL)
        var capturedRequest: URLRequest?
        StubURLProtocol.handler = { request in
            capturedRequest = request
            let json = #"{"tag_name":"v1.0.0","html_url":"https://github.com/NoiXdev/macSCP/releases/tag/v1.0.0"}"#
            return (200, [:], Data(json.utf8))
        }

        let fetcher = GitHubReleaseFetcher(session: StubURLProtocol.makeSession())
        _ = try await fetcher.latestRelease()

        #expect(!StubURLProtocol.unexpectedRequestSeen)
        let request = try #require(capturedRequest)
        #expect(request.url == Self.expectedURL)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        let userAgent = try #require(request.value(forHTTPHeaderField: "User-Agent"))
        #expect(userAgent.hasPrefix("macSCP/"))
        #expect(request.timeoutInterval == 10)
    }

    /// `URLSession` fills in `Accept-Language` from the system locale by
    /// default — a weak fingerprinting signal that has no business leaving
    /// with this request (M11b final review, Finding I1). Pinned to a fixed
    /// `"en"` instead, regardless of the test runner's own locale.
    @Test func acceptLanguageIsFixedToEnglish() async throws {
        StubURLProtocol.reset(expecting: Self.expectedURL)
        var capturedRequest: URLRequest?
        StubURLProtocol.handler = { request in
            capturedRequest = request
            let json = #"{"tag_name":"v1.0.0","html_url":"https://github.com/NoiXdev/macSCP/releases/tag/v1.0.0"}"#
            return (200, [:], Data(json.utf8))
        }

        let fetcher = GitHubReleaseFetcher(session: StubURLProtocol.makeSession())
        _ = try await fetcher.latestRelease()

        #expect(!StubURLProtocol.unexpectedRequestSeen)
        let request = try #require(capturedRequest)
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
    }

    /// The App layer passes the running bundle's `CFBundleShortVersionString`
    /// through `userAgentVersion` (Core stays bundle-free) — proves it
    /// actually reaches the `User-Agent` header instead of the default
    /// placeholder (T1 hand-off requirement).
    @Test func userAgentIncludesProvidedVersion() async throws {
        StubURLProtocol.reset(expecting: Self.expectedURL)
        var capturedRequest: URLRequest?
        StubURLProtocol.handler = { request in
            capturedRequest = request
            let json = #"{"tag_name":"v1.0.0","html_url":"https://github.com/NoiXdev/macSCP/releases/tag/v1.0.0"}"#
            return (200, [:], Data(json.utf8))
        }

        let fetcher = GitHubReleaseFetcher(
            session: StubURLProtocol.makeSession(), userAgentVersion: "9.9.9")
        _ = try await fetcher.latestRelease()

        #expect(!StubURLProtocol.unexpectedRequestSeen)
        let request = try #require(capturedRequest)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "macSCP/9.9.9")
    }

    @Test func parsesTagAndURL() async throws {
        StubURLProtocol.reset(expecting: Self.expectedURL)
        StubURLProtocol.handler = { _ in
            let json = #"{"tag_name":"v1.2.3","html_url":"https://github.com/NoiXdev/macSCP/releases/tag/v1.2.3"}"#
            return (200, [:], Data(json.utf8))
        }

        let fetcher = GitHubReleaseFetcher(session: StubURLProtocol.makeSession())
        let release = try await fetcher.latestRelease()

        #expect(!StubURLProtocol.unexpectedRequestSeen)
        #expect(release.tag == "v1.2.3")
        #expect(release.url == URL(string: "https://github.com/NoiXdev/macSCP/releases/tag/v1.2.3"))
    }

    @Test func missingFieldsThrowMalformed() async throws {
        StubURLProtocol.reset(expecting: Self.expectedURL)
        StubURLProtocol.handler = { _ in
            (200, [:], Data(#"{"html_url":"https://example.com/v1.2.3"}"#.utf8))
        }

        let fetcher = GitHubReleaseFetcher(session: StubURLProtocol.makeSession())
        await #expect(throws: UpdateCheckError.malformedResponse) {
            try await fetcher.latestRelease()
        }
        #expect(!StubURLProtocol.unexpectedRequestSeen)
    }

    @Test func rateLimitDetectedWithHeader() async throws {
        StubURLProtocol.reset(expecting: Self.expectedURL)
        StubURLProtocol.handler = { _ in
            (403, ["x-ratelimit-remaining": "0"], Data())
        }

        let fetcher = GitHubReleaseFetcher(session: StubURLProtocol.makeSession())
        await #expect(throws: UpdateCheckError.rateLimited) {
            try await fetcher.latestRelease()
        }
        #expect(!StubURLProtocol.unexpectedRequestSeen)
    }

    @Test func forbiddenWithoutRateLimitHeaderIsHTTPStatus() async throws {
        StubURLProtocol.reset(expecting: Self.expectedURL)
        StubURLProtocol.handler = { _ in (403, [:], Data()) }

        let fetcher = GitHubReleaseFetcher(session: StubURLProtocol.makeSession())
        await #expect(throws: UpdateCheckError.httpStatus(403)) {
            try await fetcher.latestRelease()
        }
        #expect(!StubURLProtocol.unexpectedRequestSeen)
    }

    @Test func otherStatusThrowsHTTPStatus() async throws {
        StubURLProtocol.reset(expecting: Self.expectedURL)
        StubURLProtocol.handler = { _ in (500, [:], Data()) }

        let fetcher = GitHubReleaseFetcher(session: StubURLProtocol.makeSession())
        await #expect(throws: UpdateCheckError.httpStatus(500)) {
            try await fetcher.latestRelease()
        }
        #expect(!StubURLProtocol.unexpectedRequestSeen)
    }

    /// The release URL comes straight from the API response; a `file://`
    /// link would otherwise reach `NSWorkspace.shared.open` unvalidated
    /// (M11b final review, Finding M1) — rejected as malformed instead of
    /// parsed through.
    @Test func fileURLIsRejectedAsMalformed() async throws {
        StubURLProtocol.reset(expecting: Self.expectedURL)
        StubURLProtocol.handler = { _ in
            let json = #"{"tag_name":"v1.0.0","html_url":"file:///etc/passwd"}"#
            return (200, [:], Data(json.utf8))
        }

        let fetcher = GitHubReleaseFetcher(session: StubURLProtocol.makeSession())
        await #expect(throws: UpdateCheckError.malformedResponse) {
            try await fetcher.latestRelease()
        }
        #expect(!StubURLProtocol.unexpectedRequestSeen)
    }

    /// Same guard, a different escape hatch: an `https` URL on a host other
    /// than `github.com` (Finding M1).
    @Test func offHostURLIsRejectedAsMalformed() async throws {
        StubURLProtocol.reset(expecting: Self.expectedURL)
        StubURLProtocol.handler = { _ in
            let json = #"{"tag_name":"v1.0.0","html_url":"https://evil.example/v1.0.0"}"#
            return (200, [:], Data(json.utf8))
        }

        let fetcher = GitHubReleaseFetcher(session: StubURLProtocol.makeSession())
        await #expect(throws: UpdateCheckError.malformedResponse) {
            try await fetcher.latestRelease()
        }
        #expect(!StubURLProtocol.unexpectedRequestSeen)
    }
}
