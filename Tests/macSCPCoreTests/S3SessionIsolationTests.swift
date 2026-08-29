import Foundation
import Testing

@testable import macSCPCore

/// The S3 dial must not run on `URLSession.shared`.
///
/// Measured on 2026-08-29, cross-process, against loopback stubs: a session
/// whose `urlCache` is disk-backed stores a 301/308 and replays it in a
/// LATER process. The reader process, with nothing listening anywhere,
/// followed the cached 308 and failed connecting to the REDIRECT TARGET's
/// port — it never asked the origin at all. `URLSession.shared`'s cache is
/// `URLCache.shared` (same object identity, 20 MB of disk under
/// `~/Library/Caches`), so a redirect an S3 endpoint answers once outlives
/// the process that received it. The same measurement over
/// `URLSession.bytes(for:)` — the download path — came out identical, and a
/// `Cache-Control: max-age` object body was served to the second process
/// from disk.
///
/// `URLSessionConfiguration.ephemeral` hands out a FRESH cache per session,
/// with `diskCapacity == 0`. That is the fix, and it is what these two
/// tests hold in place.
///
/// Neither test clears `URLCache.shared`: it belongs to whoever is running
/// the suite. They only read it, and each dial uses a bucket name nothing
/// has used before so the key they look up is unrepeatable.
@Suite("S3 session isolation")
struct S3SessionIsolationTests {

    /// A well-formed, EXPLICITLY cacheable empty `ListObjectsV2` answer.
    /// `max-age` is what makes both tests below non-vacuous: without a
    /// freshness lifetime there would be nothing for a cache to reuse, and
    /// "nothing was cached" would be true for the wrong reason.
    private static let cacheableEmptyListing: String = {
        let body = #"<?xml version="1.0" encoding="UTF-8"?><ListBucketResult></ListBucketResult>"#
        return """
            HTTP/1.1 200 OK\r
            Content-Type: application/xml\r
            Cache-Control: max-age=3600\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
    }()

    private static func config(port: Int) -> S3ConnectionConfig {
        S3ConnectionConfig(
            accessKeyID: "AKIAISOLATION", secretAccessKey: "isolation-secret-key",
            region: "us-east-1", endpoint: "http://127.0.0.1:\(port)",
            bucket: "bucket-\(UUID().uuidString)", usePathStyle: true, sessionToken: nil)
    }

    /// Rebuilds the request the dial actually sent, from the head the stub
    /// recorded, rather than spelling out a query string that
    /// `buildListRequest` owns. A cache lookup is keyed by method and URL,
    /// so a hand-written URL that drifted from the real one would turn every
    /// lookup below into a miss for a reason that has nothing to do with the
    /// property under test.
    private static func recordedRequest(_ head: String, port: Int) -> URLRequest? {
        guard let requestLine = head.split(separator: "\r\n").first else { return nil }
        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2, fields[0] == "GET",
            let url = URL(string: "http://127.0.0.1:\(port)\(fields[1])")
        else { return nil }
        return URLRequest(url: url)
    }

    @Test("the dial's own transport writes nothing into URLCache.shared")
    func dialLeavesNothingInTheSharedCache() async throws {
        let stub = try LoopbackHTTPStub(response: Self.cacheableEmptyListing)
        defer { stub.stop() }
        let config = Self.config(port: stub.port)

        let fs = try await S3FileSystem.connect(config)
        await fs.disconnect()

        // POSITIVE, and first: the dial reached the stub. Everything below
        // is vacuous for a request that never went out.
        #expect(await stub.waitForRequests(atLeast: 1), "the dial never reached the stub")
        let head = try #require(stub.requests.first)
        #expect(head.contains(config.bucket), "the recorded head is not this dial's request")
        let request = try #require(Self.recordedRequest(head, port: stub.port))

        // POSITIVE: the canned answer really is storable, and a
        // `cachedResponse(for:)` lookup with THIS request shape really
        // finds it. Proved on a private, memory-only cache, so the control
        // costs the developer's cache nothing. Without this the check that
        // follows would pass just as happily against a response no cache
        // would ever keep.
        let controlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 0, diskPath: nil)
        let controlConfiguration = URLSessionConfiguration.ephemeral
        controlConfiguration.urlCache = controlCache
        controlConfiguration.requestCachePolicy = .useProtocolCachePolicy
        let controlSession = URLSession(configuration: controlConfiguration)
        defer { controlSession.finishTasksAndInvalidate() }
        _ = try await controlSession.data(for: request)
        #expect(
            controlCache.cachedResponse(for: request) != nil,
            "the canned answer is not cacheable, so the check below proves nothing")

        // THE QUESTION. Read-only: the shared cache is never cleared here.
        #expect(
            URLCache.shared.cachedResponse(for: request) == nil,
            "the S3 dial stored its answer in the process-wide on-disk cache")
    }

    /// The other half, in positive form: a second dial to the same URL must
    /// reach the server, not a cache. This is the behaviour the shared
    /// session takes away — a `max-age` answer is reused for the whole
    /// process, and for every later process, without asking the endpoint.
    ///
    /// It also pins per-dial isolation, not merely "no disk": each dial
    /// builds its own session, and an ephemeral configuration hands out a
    /// fresh cache per session. One process-wide ephemeral session would
    /// still share a cache between two windows' connections, which is the
    /// arrangement this project's window-scope rule exists to prevent.
    @Test("a second dial to the same URL reaches the server, not a cache")
    func everyDialReachesTheServer() async throws {
        let stub = try LoopbackHTTPStub(response: Self.cacheableEmptyListing)
        defer { stub.stop() }
        let config = Self.config(port: stub.port)

        for _ in 0..<2 {
            let fs = try await S3FileSystem.connect(config)
            await fs.disconnect()
        }

        #expect(
            await stub.waitForRequests(atLeast: 2),
            "the second dial was answered from a cache; the stub saw \(stub.requests.count)")
        #expect(
            stub.requests.allSatisfy { $0.contains(config.bucket) },
            "the stub recorded a request that is not this test's")
    }
}
