import Foundation
import Testing

@testable import macSCPCore

/// The S3 dial's redirect policy, driven end to end over loopback:
/// a redirect that stays inside the endpoint's own origin is re-signed and
/// followed, one that leaves it is refused with an error that names where
/// it was being sent.
///
/// This is the counterpart to `S3RedirectAuthorizationMeasurementTests`,
/// which measures what FOUNDATION does when nothing decides — it injects a
/// delegate-less transport for exactly that reason. Here the dial builds
/// its own session, and that session carries `S3RedirectSessionDelegate`.
///
/// Loopback only, one socket per stub, torn down with the test. Every dial
/// uses a bucket name nothing has used before, for the reason the
/// measurement suite spells out at length: a cacheable redirect keyed by an
/// ephemeral port that comes round again is a cross-run false negative, and
/// emptying `URLCache.shared` to avoid it would empty the cache of whoever
/// is running the suite.
///
/// What this cannot see: what a REAL S3 provider does on a redirect. It
/// measures this project's policy against a controlled stub.
@Suite("S3 redirect control", .timeLimit(.minutes(1)))
struct S3RedirectControlTests {

    private static func freshBucket() -> String { "bucket-\(UUID().uuidString)" }

    private static func config(port: Int) -> S3ConnectionConfig {
        S3ConnectionConfig(
            accessKeyID: "AKIAREDIRECTCONTROL", secretAccessKey: "redirect-control-secret",
            region: "us-east-1", endpoint: "http://127.0.0.1:\(port)",
            bucket: freshBucket(), usePathStyle: true, sessionToken: nil)
    }

    private static func redirect(to location: String) -> String {
        """
        HTTP/1.1 302 Found\r
        Location: \(location)\r
        Content-Length: 0\r
        Connection: close\r
        \r

        """
    }

    /// A path that appears nowhere in the original request, so a recorded
    /// head can be identified as the REDIRECTED one and not as some other
    /// request that happened to arrive.
    private static let hopPath = "/redirect-control-hop/bucket"

    // MARK: - Same origin: re-signed and followed

    /// The functional half of the finding: before this policy existed a
    /// legitimate provider redirect arrived UNSIGNED, because Foundation
    /// strips `Authorization` on every redirect including a same-origin one
    /// (measured, ten cases plus a control). The dial now rebuilds and
    /// re-signs the request for the redirect's own target.
    ///
    /// One stub answers both hops, because a same-origin redirect by
    /// definition lands back on the same socket: first the 302, then a real
    /// (empty) listing — so a followed redirect makes `connect` SUCCEED,
    /// which is a second, independent piece of evidence that the hop
    /// completed rather than merely started.
    @Test("a same-origin redirect arrives signed, and connect succeeds")
    func sameOriginRedirectIsReSignedAndFollowed() async throws {
        let stub = try LoopbackHTTPStub(responses: [
            Self.redirect(to: "\(Self.hopPath)?list-type=2&delimiter=%2F&prefix="),
            LoopbackHTTPStub.emptyBucketListing,
        ])
        defer { stub.stop() }

        var failure: String?
        do { _ = try await S3FileSystem.connect(Self.config(port: stub.port)) } catch {
            failure = "\(error)"
        }
        try await stub.waitForRequests(atLeast: 2)
        let heads = stub.requests

        // Positive, and first: both hops happened at all. Every reading
        // below is vacuously true without this.
        #expect(heads.count >= 2, "the redirect was not followed; heads: \(heads.count)")
        let hop = try #require(heads.dropFirst().first)
        #expect(hop.contains(Self.hopPath), "the second request was not the redirected one")

        // The question. The first request carries `Authorization` in every
        // measured case, so asserting it on the FIRST head as well is what
        // keeps the detector honest — a reader that saw no header anywhere
        // would fail here rather than pass below.
        #expect(LoopbackHTTPStub.headerValue("authorization", in: heads[0]) != nil,
                "the first request carried no Authorization header")
        #expect(LoopbackHTTPStub.headerValue("authorization", in: hop) != nil,
                "the re-signed redirect arrived without an Authorization header")

        // The `Host` the signature binds. It is the endpoint's own here —
        // a same-origin hop cannot move it — and what this pins is that
        // re-signing did not drop or garble it. That it FOLLOWS the target
        // rather than being copied is pinned by
        // `S3RequestSigningTests.reSigningSetsTheHostOfTheNewTarget`, which
        // can hand the signer a target the policy would never allow.
        #expect(LoopbackHTTPStub.headerValue("host", in: hop) == "127.0.0.1:\(stub.port)")
        #expect(LoopbackHTTPStub.headerValue("x-amz-date", in: hop) != nil,
                "the re-signed request carries no x-amz-date")
        #expect(failure == nil, "connect failed after a followed redirect: \(failure ?? "-")")
    }

    // MARK: - Foreign origin: refused

    /// The security half. Before this policy the foreign origin learned the
    /// bucket path, the list query, `x-amz-date`, `x-amz-content-sha256` and
    /// — through the hand-set, now stale `Host` — the configured endpoint.
    /// Now it learns nothing, because nothing is sent.
    @Test("a redirect to a foreign origin is refused, and the target is named")
    func foreignOriginRedirectIsRefused() async throws {
        let second = try LoopbackHTTPStub(response: LoopbackHTTPStub.emptyBucketListing)
        defer { second.stop() }
        let first = try LoopbackHTTPStub(
            response: Self.redirect(to: "http://127.0.0.1:\(second.port)\(Self.hopPath)"))
        defer { first.stop() }

        var caught: Error?
        do { _ = try await S3FileSystem.connect(Self.config(port: first.port)) } catch {
            caught = error
        }
        try await first.waitForRequests(atLeast: 1)

        // The two positive events the negative below is read after: `caught`
        // is set above, so the dial has already ended, and the endpoint's own
        // request is recorded, so it really happened. Nothing is left running
        // that could still dial the foreign origin, and so no grace is taken:
        // a fixed wait here would be a ceiling in the forgiving direction --
        // a hop arriving one tick after it would read as a hop never made.
        //
        // The claim is read at ACCEPT rather than from `requests`, because a
        // request is recorded only once its response has been written. A hop
        // that was made but whose response is still in flight is invisible in
        // `requests` and unmistakable in the accept count, which the kernel
        // raises before this stub can write anything at all.
        let reached = second.acceptedConnections > 0

        // Positive first: the endpoint WAS asked, and it was asked with a
        // signature. Without this the refusal below could be a dial that
        // never got off the ground.
        #expect(first.requests.count == 1, "the endpoint saw \(first.requests.count) requests")
        // And the accept counter counts, measured on the origin that WAS
        // reached. The zero asserted on the foreign origin at the end is a
        // negative, and it would read exactly the same against a counter
        // that never increments at all.
        #expect(
            first.acceptedConnections >= 1,
            "the endpoint accepted \(first.acceptedConnections) connection(s)")
        #expect(first.requests.first.flatMap { LoopbackHTTPStub.headerValue("authorization", in: $0) } != nil,
                "the endpoint was not asked with a signed request")

        // The refusal, and the sentence it carries. Asserting on the two
        // origins rather than on a whole translated sentence is deliberate:
        // the host's preferred language decides which catalog answers, so a
        // fixed text would pass on one machine and fail on another. That the
        // key resolves to real text at all is
        // `S3RedirectDecisionTests.theRefusalKeyResolves`.
        let error = try #require(caught as? RemoteFSError)
        guard case .connectionFailed(let reason) = error else {
            Issue.record("expected .connectionFailed, got \(error)")
            return
        }
        #expect(reason.contains("http://127.0.0.1:\(first.port)"),
                "the refusal does not name the configured endpoint: \(reason)")
        #expect(reason.contains("http://127.0.0.1:\(second.port)"),
                "the refusal does not name where the endpoint wanted to send it: \(reason)")

        // The finding this whole task exists for: the foreign origin is
        // never asked. A negative — hence the two positives above, and the
        // named target in the message, which could only be produced by
        // machinery that really saw this redirect.
        #expect(reached == false, "the redirect was followed to the foreign origin")
        #expect(
            second.acceptedConnections == 0,
            "the foreign origin accepted \(second.acceptedConnections) connection(s)")
    }
}
