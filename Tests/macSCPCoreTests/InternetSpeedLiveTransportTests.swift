import Foundation
import Testing

@testable import macSCPCore

/// What `InternetSpeedTransport.live` does over a real `URLSession`,
/// driven end to end over loopback: the redirect policy — a redirect that
/// leaves the origin the request was made to is refused and nothing is sent
/// to the new one, one that stays inside it is followed — and what actually
/// reaches the wire.
///
/// The counterpart to `S3RedirectControlTests`, over the same stub and with
/// the same rule (`S3RedirectDecision`). It exists at THIS level because
/// the probe's own seam cannot see a redirect at all: the injected
/// transport is handed a `URLRequest` and answers a byte count, so
/// everything Foundation does between those two points is invisible to
/// `InternetSpeedProbeTests`. This suite drives `InternetSpeedTransport.live`
/// itself.
///
/// Loopback only; nothing here reaches the network, and no service URL is
/// used — the rule compares the origin that ANSWERED against the origin
/// being proposed, so a stub's own port is all it needs.
///
/// Caching cannot cross a run here the way it can in the S3 suite: the live
/// transport's session is ephemeral with `urlCache = nil`, and every
/// request carries `.reloadIgnoringLocalAndRemoteCacheData`.
@Suite("The internet speed test's live transport", .timeLimit(.minutes(1)))
struct InternetSpeedLiveTransportTests {
    /// A 307, which is the dangerous one: 301/302/303 rewrite the request
    /// to a GET and drop the body, while 307 and 308 preserve the method
    /// AND resend the body — the 1 MiB upload, to a host of the response's
    /// choosing.
    static func temporaryRedirect(to location: String) -> String {
        """
        HTTP/1.1 307 Temporary Redirect\r
        Location: \(location)\r
        Content-Length: 0\r
        Connection: close\r
        \r

        """
    }

    /// A 200 carrying `count` bytes, so a followed redirect can be told
    /// from an unfollowed one by the number the transport answers.
    static func ok(bytes count: Int) -> String {
        let body = String(repeating: "x", count: count)
        return """
            HTTP/1.1 200 OK\r
            Content-Type: application/octet-stream\r
            Content-Length: \(count)\r
            Connection: close\r
            \r
            \(body)
            """
    }

    /// A body small enough to sit in the socket buffer, so the stub — which
    /// reads a request head and not a body — can still answer it. The size
    /// is irrelevant to what is asserted: what matters is that a body
    /// exists and that it does not reach the far origin.
    static let bodyBytes = 512

    static func request(_ url: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(
            url: URL(string: url)!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 10)
        request.httpShouldHandleCookies = false
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        } else {
            request.httpMethod = "GET"
        }
        return request
    }

    // MARK: - Away from the origin: refused, and nothing is sent there

    /// The upload's shape, which is the one that matters: a `POST` with a
    /// body, answered with a 307 pointing at a second origin.
    ///
    /// The assertion that the body was not re-sent is
    /// `acceptedConnections == 0` on the far stub, counted at `accept` and
    /// before a byte of any response is written — so it cannot read "no
    /// request" for a request still in flight.
    @Test func aCrossOriginRedirectIsRefusedAndTheBodyIsNotResent() async throws {
        let elsewhere = try LoopbackHTTPStub(response: Self.ok(bytes: 1))
        defer { elsewhere.stop() }
        let service = try LoopbackHTTPStub(responses: [
            Self.temporaryRedirect(to: "http://127.0.0.1:\(elsewhere.port)/elsewhere"),
            Self.ok(bytes: 1),
        ])
        defer { service.stop() }

        var thrown: (any Error)?
        do {
            _ = try await InternetSpeedTransport.live.perform(
                Self.request(
                    "http://127.0.0.1:\(service.port)/__up",
                    body: Data(repeating: 0x5A, count: Self.bodyBytes)))
        } catch {
            thrown = error
        }

        let refusal = try #require(thrown as? InternetSpeedRefusal, "\(String(describing: thrown))")
        guard case .redirect(let from, let to) = refusal else {
            Issue.record("a cross-origin redirect was not refused as one: \(refusal)")
            return
        }
        #expect(from == "http://127.0.0.1:\(service.port)")
        #expect(to == "http://127.0.0.1:\(elsewhere.port)")
        #expect(elsewhere.acceptedConnections == 0, """
            the redirect target was contacted, so the upload body left for an origin the \
            service chose
            """)
        // The positive check beside that zero: the FIRST origin really was
        // asked, so the zero above is a refusal and not a request nobody
        // made.
        try await service.waitForRequests(atLeast: 1)
        #expect(service.requests.count == 1, "\(service.requests.count)")
    }

    /// The download's shape, and an `https` → `http` downgrade is foreign
    /// too by the rule this reuses — but a loopback stub speaks no TLS, so
    /// what is varied here is the port, which the same rule treats the same
    /// way.
    @Test func aCrossOriginRedirectOnADownloadIsRefusedToo() async throws {
        let elsewhere = try LoopbackHTTPStub(response: Self.ok(bytes: 1))
        defer { elsewhere.stop() }
        let service = try LoopbackHTTPStub(
            response: Self.temporaryRedirect(to: "http://127.0.0.1:\(elsewhere.port)/elsewhere"))
        defer { service.stop() }

        var thrown: (any Error)?
        do {
            _ = try await InternetSpeedTransport.live.perform(
                Self.request("http://127.0.0.1:\(service.port)/__down?bytes=1"))
        } catch {
            thrown = error
        }

        #expect(thrown is InternetSpeedRefusal, "\(String(describing: thrown))")
        #expect(elsewhere.acceptedConnections == 0)
        try await service.waitForRequests(atLeast: 1)
    }

    // MARK: - Inside the origin: followed

    /// A same-origin redirect is allowed, which is what
    /// `S3RedirectDecision` decides and what this step reuses rather than
    /// deciding again. Both hops land on the same socket by definition, so
    /// one stub answers both — and the byte count the transport returns is
    /// the SECOND response's, which is independent evidence the hop
    /// completed rather than merely started.
    @Test func aSameOriginRedirectIsFollowed() async throws {
        let service = try LoopbackHTTPStub(responses: [
            Self.temporaryRedirect(to: "/hop"),
            Self.ok(bytes: 4242),
        ])
        defer { service.stop() }

        let bytes = try await InternetSpeedTransport.live.perform(
            Self.request("http://127.0.0.1:\(service.port)/__down?bytes=4242"))

        #expect(bytes == 4242)
        try await service.waitForRequests(atLeast: 2)
        let hop = try #require(service.requests.dropFirst().first)
        #expect(hop.contains("/hop"), "the second request was not the redirected one")
    }

    // MARK: - What reaches the wire

    /// The request head as a server really sees it, which is one layer
    /// below what `InternetSpeedProbeTests.theRequestsCarryNothingOfTheSession`
    /// can reach: that case holds the `URLRequest`, and `URLSession` adds
    /// headers of its own on the way out.
    ///
    /// Measured here on 2026-09-20, macOS 25.6.0 / CFNetwork 3860.700.1:
    /// Foundation added `Host`, `Cache-Control: no-cache` (from this
    /// step's cache policy), `Accept: */*`, `User-Agent` (the process name
    /// plus the CFNetwork and Darwin versions), `Accept-Language` (the
    /// viewer's preferred languages) and `Connection: keep-alive`. None of
    /// it is session data; `Accept-Language` is the one thing on that list
    /// that is about the person rather than about the request, and it is
    /// the same header every web page they open receives.
    ///
    /// The exact set is Foundation's and moves with the OS, so what is
    /// asserted is not that list: it is that OUR two headers arrive and
    /// that the two a credential would travel in do not. The positive half
    /// is there so the negative half cannot pass by reading nothing
    /// (CLAUDE.md, "Guards that name what they watch").
    @Test func theHeadOnTheWireCarriesOursAndNoCredential() async throws {
        let stub = try LoopbackHTTPStub(response: Self.ok(bytes: 2))
        defer { stub.stop() }

        _ = try await InternetSpeedTransport.live.perform(
            Self.request("http://127.0.0.1:\(stub.port)/__down?bytes=2"))

        try await stub.waitForRequests(atLeast: 1)
        let head = try #require(stub.requests.first)
        #expect(head.hasPrefix("GET /__down?bytes=2 "), "\(head)")
        #expect(LoopbackHTTPStub.headerValue("Accept-Encoding", in: head) == "identity", "\(head)")
        #expect(LoopbackHTTPStub.headerValue("Host", in: head) == "127.0.0.1:\(stub.port)")
        #expect(LoopbackHTTPStub.headerValue("Authorization", in: head) == nil, "\(head)")
        #expect(LoopbackHTTPStub.headerValue("Cookie", in: head) == nil, "\(head)")
    }
}
