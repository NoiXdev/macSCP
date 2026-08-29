import Foundation
import Testing

@testable import macSCPCore

/// MEASUREMENT (2026-08-28), specified by
/// `docs/superpowers/specs/2026-08-28-zwei-offene-fragen-design.md`, section
/// "Die S3-Redirect-Frage".
///
/// The question: `S3FileSystem` sets `Authorization` by hand and runs over
/// `URLSessionHTTPTransport` on a session carrying no delegate, so there is
/// no redirect control in that path at all. Does Foundation carry that
/// hand-set header across an automatic redirect to a DIFFERENT origin?
///
/// The session under it changed on 2026-08-29 — the dial builds its own from
/// `URLSessionConfiguration.ephemeral` instead of taking `URLSession.shared`
/// — and the measurement was re-run against it unchanged.
///
/// Later the same day the dial's own session gained
/// `S3RedirectSessionDelegate`, which decides what happens to a redirect
/// instead of leaving it to Foundation. **That is why this suite now injects
/// a transport over a delegate-less session.** The question it asks is about
/// FOUNDATION, not about this project's policy: what a hand-set header does
/// on a redirect when nothing intervenes. Measuring it through the dial's
/// own session would measure the policy instead, and the finding — the
/// reason the policy exists — would quietly stop being checked. The policy
/// has its own suite, `S3RedirectControlTests`.
///
/// The behaviour measured here is Foundation's, undocumented and
/// version-dependent, so the question stays worth re-asking on every
/// platform the suite runs on. What CHANGED is only who is asked.
///
/// The header carries no secret key, but it carries the access key ID and the
/// SigV4 signature. A signature delivered to a foreign origin is not a
/// plaintext credential leak; it is a request-forgery surface.
///
/// Two origin shapes, because they can go differently and measuring one would
/// be a claim about both:
///   A: `127.0.0.1:p1` → `127.0.0.1:p2`  (port only)
///   B: `127.0.0.1:p1` → `localhost:p2`  (hostname AND port)
/// An implementation that strips only on a host change passes A and fails B.
///
/// The POSITIVE check is not optional. "No `Authorization` at the second
/// origin" is a NEGATIVE statement and it is vacuously true for a request
/// that never arrived — so every case asserts FIRST that the second origin
/// saw a request at all, via `waitForRequests(atLeast:)` (the stub appends to
/// `seenRequests` on its accept thread AFTER writing the response, so reading
/// `requests` straight after the operation races that append).
///
/// What this cannot see: what a REAL S3 provider does on a redirect. This
/// measures Foundation against a controlled loopback stub, which is what the
/// question is about, and nothing beyond it.
@Suite("S3 redirect Authorization measurement")
struct S3RedirectAuthorizationMeasurementTests {

    // MARK: - Canned responses

    private static func redirect(status: Int, phrase: String, to location: String) -> String {
        """
        HTTP/1.1 \(status) \(phrase)\r
        Location: \(location)\r
        Content-Length: 0\r
        Connection: close\r
        \r

        """
    }

    /// A well-formed, empty `ListObjectsV2` answer, so a redirect that is
    /// followed all the way through makes `S3FileSystem.connect` SUCCEED —
    /// a second, independent piece of positive evidence that the hop
    /// completed rather than merely started.
    private static let emptyListing: String = {
        let body = #"<?xml version="1.0" encoding="UTF-8"?><ListBucketResult></ListBucketResult>"#
        return """
            HTTP/1.1 200 OK\r
            Content-Type: application/xml\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
    }()

    // MARK: - One measurement

    private struct Outcome {
        let firstRequests: [String]
        let secondRequests: [String]
        let secondSawARequest: Bool
        let connectSucceeded: Bool
        let connectError: String?
    }

    /// A path that exists nowhere in the original request, so a head
    /// recorded at the second stub can be identified as the REDIRECTED
    /// request and not as some other request that happened to arrive.
    private static let secondOriginPathMarker = "/redirected-to-the-second-origin/bucket"

    /// A bucket name nothing has used before, and the reason it is not just
    /// `"bucket"`.
    ///
    /// `S3FileSystem` used to run over `URLSession.shared`, hence over
    /// `URLCache.shared` — a persistent on-disk cache shared by every
    /// process on the machine. The stub's 301 and 308 answers are cacheable
    /// and got keyed by `http://127.0.0.1:<ephemeral port>/<bucket>?…`, and
    /// ephemeral ports come round again: a later run that drew a port some
    /// EARLIER `swift test` process had left an entry for was answered from
    /// disk, and the stub never saw the request. Measured over 80 runs, that
    /// turned this suite red 13 times — and never under load, which is what
    /// made it look like a timing problem for two days.
    ///
    /// The cause is gone: the dial now builds its own session from
    /// `URLSessionConfiguration.ephemeral`, whose cache is fresh per session
    /// and has no disk at all (`S3SessionIsolationTests`). A fresh name per
    /// call is kept anyway, because it costs nothing and this suite should
    /// not be the thing that goes red if that ever regresses — the suite
    /// that owns the question should be. It was always preferred over
    /// `URLCache.shared.removeAllCachedResponses()`, which would empty the
    /// cache of whoever is running the suite along with every other suite's.
    private static func freshBucket() -> String { "bucket-\(UUID().uuidString)" }

    /// A `URLSessionHTTPTransport` over an ephemeral session with NO
    /// delegate — the arrangement the dial had until the redirect policy
    /// landed, and the only way left to ask what Foundation does on its own.
    /// Ephemeral for the reason `S3SessionIsolationTests` gives: a
    /// disk-backed cache replays a 301 or 308 to a later run, and clearing
    /// `URLCache.shared` instead would empty the cache of whoever is running
    /// the suite.
    ///
    /// The session is returned alongside so the caller can invalidate it. An
    /// injected transport's session is not `S3FileSystem`'s to end — its
    /// `disconnect` deliberately leaves it alone — and a `URLSession` keeps
    /// itself alive until somebody invalidates it.
    private static func delegatelessTransport() -> (URLSessionHTTPTransport, URLSession) {
        let session = URLSession(configuration: .ephemeral)
        return (URLSessionHTTPTransport(session: session), session)
    }

    /// Drives the REAL signed request: `S3FileSystem.connect` builds it
    /// through its own signing path. Not a hand-built `URLRequest` that
    /// merely looks like one.
    private func measure(
        status: Int, phrase: String, secondHost: String
    ) async throws -> Outcome {
        let second = try LoopbackHTTPStub(response: Self.emptyListing)
        defer { second.stop() }
        let first = try LoopbackHTTPStub(
            response: Self.redirect(
                status: status, phrase: phrase,
                to: "http://\(secondHost):\(second.port)\(Self.secondOriginPathMarker)"
                    + "?list-type=2&delimiter=%2F&prefix="))
        defer { first.stop() }

        let config = S3ConnectionConfig(
            accessKeyID: "AKIAMEASUREMENT", secretAccessKey: "measurement-secret-key",
            region: "us-east-1", endpoint: "http://127.0.0.1:\(first.port)",
            bucket: Self.freshBucket(), usePathStyle: true, sessionToken: nil)

        let (transport, session) = Self.delegatelessTransport()
        defer { session.finishTasksAndInvalidate() }

        var succeeded = false
        var failure: String?
        do {
            _ = try await S3FileSystem.connect(config, transport: transport)
            succeeded = true
        } catch {
            failure = "\(error)"
        }

        // Wait for the appends rather than racing them.
        _ = await first.waitForRequests(atLeast: 1)
        let reached = await second.waitForRequests(atLeast: 1)

        return Outcome(
            firstRequests: first.requests, secondRequests: second.requests,
            secondSawARequest: reached, connectSucceeded: succeeded, connectError: failure)
    }

    /// Dumps every request head both stubs recorded. OFF by default —
    /// eleven full request dumps on every `swift test` would be noise, and
    /// the measurement they belong to is written down in
    /// `.superpowers/sdd/s3-redirect-measurement.md`. Set
    /// `MACSCP_REDIRECT_DUMP=1` to reproduce the evidence. This gates
    /// PRINTING only; every assertion runs either way, unlike
    /// `MACSCP_ITEST`/`MACSCP_KEYCHAIN`, which gate whole suites.
    private static let dumpRequests = ProcessInfo.processInfo
        .environment["MACSCP_REDIRECT_DUMP"] != nil

    private func report(_ label: String, _ outcome: Outcome) {
        guard Self.dumpRequests else { return }
        print("=== MEASUREMENT \(label) ===")
        print("connect succeeded: \(outcome.connectSucceeded) error: \(outcome.connectError ?? "-")")
        print("first origin requests: \(outcome.firstRequests.count)")
        for head in outcome.firstRequests { print("--- first ---\n\(head)") }
        print("second origin requests: \(outcome.secondRequests.count)")
        for head in outcome.secondRequests { print("--- second ---\n\(head)") }
        print("=== END \(label) ===")
    }

    // MARK: - The cases

    /// Every redirect status Foundation may treat differently: 301/302/303
    /// rewrite the method to GET, 307/308 preserve it. The S3 probe is
    /// already a GET, so all five are followable and all five are measured;
    /// a difference between them would be a difference in header handling,
    /// which is exactly the question.
    static let statuses: [(Int, String)] = [
        (301, "Moved Permanently"), (302, "Found"), (303, "See Other"),
        (307, "Temporary Redirect"), (308, "Permanent Redirect"),
    ]

    @Test("case A — 127.0.0.1:p1 → 127.0.0.1:p2 (port differs)",
          arguments: statuses)
    func caseAPortOnly(status: Int, phrase: String) async throws {
        let outcome = try await measure(status: status, phrase: phrase, secondHost: "127.0.0.1")
        report("A/\(status)", outcome)
        check(outcome, label: "A/\(status)")
    }

    @Test("case B — 127.0.0.1:p1 → localhost:p2 (hostname and port differ)",
          arguments: statuses)
    func caseBHostAndPort(status: Int, phrase: String) async throws {
        let outcome = try await measure(status: status, phrase: phrase, secondHost: "localhost")
        report("B/\(status)", outcome)
        check(outcome, label: "B/\(status)")
    }

    /// Both cases ask the same four questions, in this order on purpose.
    private func check(_ outcome: Outcome, label: String) {
        // 1. POSITIVE, and FIRST: the redirect actually happened, and the
        //    second origin saw the REDIRECTED request — identified by a
        //    path that appears nowhere in the original. Without this every
        //    check below is vacuously true, which is the failure mode this
        //    measurement was written to avoid. It also catches a cached
        //    reply standing in for either hop: a response served from cache
        //    leaves the stub with nothing recorded, and these two checks
        //    fail.
        #expect(outcome.firstRequests.count >= 1, "\(label): the first origin was never reached")
        #expect(outcome.secondSawARequest, "\(label): the redirect never arrived")
        #expect(
            outcome.secondRequests.contains { $0.contains(Self.secondOriginPathMarker) },
            "\(label): the second origin saw no request bearing the redirect's own path")

        // 2. POSITIVE: the header the question is about exists at all, and
        //    `hasAuthorization` recognises it in a head this same stub
        //    recorded. The negative check below is worth nothing without
        //    this — it is what proves the detector is not simply blind.
        #expect(outcome.firstRequests.contains { Self.hasAuthorization($0) },
                "\(label): the first origin never saw an Authorization header")

        // 3. POSITIVE: hand-set request headers DO survive the hop. This is
        //    the sharpest control available here — `x-amz-date` is set by
        //    `buildSignedRequest` exactly the way `Authorization` is, so
        //    its presence at the second origin rules out "nothing is
        //    carried" and "the stub does not record headers" as
        //    explanations for the absence below.
        #expect(outcome.secondRequests.contains { Self.hasHeader("x-amz-date", $0) },
                "\(label): no hand-set header survived, so the control is missing")

        // 4. THE QUESTION.
        #expect(outcome.secondRequests.contains { Self.hasAuthorization($0) } == false,
                "\(label): the Authorization header was carried to the second origin")
    }

    /// The SCOPE control the two cases above cannot supply: is the header
    /// dropped BECAUSE the origin changed, or on every redirect regardless?
    /// One stub redirects to a different PATH on itself, so the hop stays
    /// inside one origin. Whatever URLSession does with the repetition —
    /// follow it to its redirect limit, or refuse it as a loop — the only
    /// thing read here is what arrives AFTER the first request.
    ///
    /// The count of hops is Foundation's to choose and is deliberately not
    /// asserted as a number — only that there was at least one, which is
    /// what makes the reading below non-vacuous.
    @Test("scope control — a SAME-origin redirect")
    func sameOriginRedirectControl() async throws {
        let stub = try LoopbackHTTPStub(
            response: Self.redirect(status: 302, phrase: "Found", to: "/same-origin-hop"))
        defer { stub.stop() }

        let config = S3ConnectionConfig(
            accessKeyID: "AKIAMEASUREMENT", secretAccessKey: "measurement-secret-key",
            region: "us-east-1", endpoint: "http://127.0.0.1:\(stub.port)",
            bucket: Self.freshBucket(), usePathStyle: true, sessionToken: nil)
        let (transport, session) = Self.delegatelessTransport()
        defer { session.finishTasksAndInvalidate() }
        var failure: String?
        do { _ = try await S3FileSystem.connect(config, transport: transport) } catch {
            failure = "\(error)"
        }
        _ = await stub.waitForRequests(atLeast: 2)

        let heads = stub.requests
        if Self.dumpRequests {
            print("=== MEASUREMENT same-origin ===")
            print("error: \(failure ?? "-")  requests: \(heads.count)")
            for head in heads { print("--- hop ---\n\(head)") }
            print("=== END same-origin ===")
        }

        // Positive first, as everywhere in this file.
        #expect(heads.count >= 1, "the origin was never reached")
        #expect(heads.first.map(Self.hasAuthorization) == true,
                "the first request carried no Authorization header")
        let hops = heads.dropFirst()
        #expect(hops.isEmpty == false, "no same-origin hop happened; the control is silent")
        #expect(hops.allSatisfy { $0.contains("/same-origin-hop") })
        // Same positive control as the cross-origin cases: hand-set headers
        // DO survive the hop, so the absence below is not "nothing was
        // carried".
        #expect(hops.allSatisfy { Self.hasHeader("x-amz-date", $0) },
                "no hand-set header survived, so the control is missing")
        // The finding this arm exists for: the drop is not conditional on
        // the origin changing. It happens on a hop that never leaves it.
        #expect(hops.contains { Self.hasAuthorization($0) } == false,
                "Authorization survived a same-origin redirect")
    }

    private static func hasHeader(_ name: String, _ head: String) -> Bool {
        head.split(separator: "\r\n").contains { $0.lowercased().hasPrefix("\(name.lowercased()):") }
    }

    private static func hasAuthorization(_ head: String) -> Bool {
        hasHeader("authorization", head)
    }
}
