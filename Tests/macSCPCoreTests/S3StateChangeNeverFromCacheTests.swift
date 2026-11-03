import Foundation
import Testing

@testable import macSCPCore

/// A request that changes state on the store carries nothing a cache made up
/// from an earlier read, and is never answered from one.
///
/// **What was measured, and what an earlier version of this comment got
/// wrong.** On 2026-11-03 a `DELETE ?versionId=` sent after a buffered `GET`
/// of the same url came back from the Docker rig as `200` with the object's
/// body, and the version stayed listed (`S3VersionsGatedTests`, the case
/// `aDeleteOnTheDefaultSessionIsAnsweredWithTheObjectItWasMeantToRemove`).
/// The first reading, written into that case, the spec and the backlog, was
/// "the cache answered it and the DELETE never reached the store". **That
/// reading is withdrawn.** The stub below records the DELETE's head: it
/// REACHES the server, carrying `If-None-Match` and `If-Modified-Since`,
/// which the default session's cache copied from the entry the earlier `GET`
/// left under the same url. (On the rig, the repeated DELETEs of one run each
/// came back with a different `x-request-id`, which a replayed cached response
/// cannot do; that was the tell.) What the rig does with a DELETE carrying
/// those validators is to answer it as a read and not delete. What another
/// store does with them is unmeasured, and so is what a store does with them
/// on a `PUT`.
///
/// Either reading ends in the same false success on the one operation that
/// cannot be undone, and the only reason production did not send the sequence
/// was that its object `GET` streams: a property of one call site, not of the
/// channel. **What is held is the behaviour**: the request that follows a
/// read of the same url reaches the stub with no conditional header, counted
/// at `accept`, so a change to HOW the channel avoids the cache cannot make
/// this stale and one that stops avoiding it turns it red.
@Suite("S3 state-changing requests carry nothing from a cache", .timeLimit(.minutes(5)))
struct S3StateChangeNeverFromCacheTests {

    private static let objectBody = "version-content"

    /// A stored object's answer as a real store gives it: a `Date`, a
    /// `Last-Modified` and an `ETag`, which are the validators a cache keeps.
    private static var storedObject: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let now = formatter.string(from: Date())
        return """
            HTTP/1.1 200 OK\r
            Date: \(now)\r
            Content-Type: text/plain\r
            ETag: "0123456789abcdef0123456789abcdef"\r
            Last-Modified: \(now)\r
            Accept-Ranges: bytes\r
            Content-Length: \(objectBody.utf8.count)\r
            Connection: close\r
            \r
            \(objectBody)
            """
    }

    private static func answer(to method: String) -> String {
        method == "DELETE"
            ? "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
            : "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    }

    private static func config(port: Int) -> S3ConnectionConfig {
        S3ConnectionConfig(
            accessKeyID: "AKIACACHECHECK", secretAccessKey: "cache-check-secret-key",
            region: "us-east-1", endpoint: "http://127.0.0.1:\(port)",
            bucket: "bucket-\(UUID().uuidString)", usePathStyle: true, sessionToken: nil)
    }

    /// What the stub saw and what the client was told, for one run of the
    /// sequence: connect (probe), a buffered `GET` of one object version, then
    /// `method` on the same url.
    private struct Run {
        var getStatus: Int?
        var status: Int?
        var connections = 0
        var headIsTheMethod = false
        /// The conditional headers the request carried, by name.
        var conditionals: [String] = []
        var failure: (any Error)?
    }

    private static func run(method: String, transport: (any HTTPTransport)?) async throws -> Run {
        let stub = try LoopbackHTTPStub(responses: [
            LoopbackHTTPStub.emptyBucketListing, storedObject, answer(to: method),
        ])
        defer { stub.stop() }
        let config = config(port: stub.port)
        let fs = try await S3FileSystem.connect(config, transport: transport)
        var run = Run()
        do {
            let query = [(name: "versionId", value: "v1")]
            let get = try S3FileSystem.signedRequest(
                .objectKey(bucket: config.bucket, key: "doc.txt"), method: "GET", query: query,
                config: config)
            run.getStatus = try await fs.perform(get).1.statusCode
            let write = try S3FileSystem.signedRequest(
                .objectKey(bucket: config.bucket, key: "doc.txt"), method: method, query: query,
                config: config)
            run.status = try await fs.perform(write).1.statusCode
        } catch {
            run.failure = error
        }
        await fs.disconnect()
        run.connections = stub.acceptedConnections
        if run.connections >= 3 {
            try await stub.waitForRequests(atLeast: 3)
            let head = stub.requests[2]
            run.headIsTheMethod = head.hasPrefix(method + " ")
            run.conditionals = head.split(separator: "\r\n")
                .compactMap { $0.split(separator: ":").first.map { $0.lowercased() } }
                .filter { ["if-none-match", "if-modified-since", "if-match", "if-unmodified-since"].contains($0) }
        }
        return run
    }

    /// The control comes first. Without it, "no conditional header" would hold
    /// just as well for a stub whose GET answer no cache would keep. It pins
    /// what the platform does on a session that keeps the default cache, on
    /// purpose: if that ever changes, this goes red by name and the test
    /// below is known to have lost its meaning.
    @Test(arguments: ["DELETE", "PUT"])
    func aSessionThatKeepsTheDefaultCacheCopiesTheValidatorsOntoTheWrite(method: String) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let run = try await Self.run(
            method: method, transport: URLSessionHTTPTransport(session: session))

        #expect(run.failure == nil)
        #expect(run.getStatus == 200)
        #expect(run.connections == 3 && run.headIsTheMethod)
        #expect(
            !run.conditionals.isEmpty,
            "the control no longer reproduces the hazard, so the test below proves nothing")
    }

    @Test(arguments: ["DELETE", "PUT"])
    func aWriteAfterABufferedGetOfTheSameUrlReachesTheStoreWithNoConditionalHeader(
        method: String
    ) async throws {
        let run = try await Self.run(method: method, transport: nil)

        #expect(run.failure == nil)
        #expect(run.getStatus == 200)
        #expect(run.connections == 3, "the write was answered without reaching the store")
        #expect(run.headIsTheMethod)
        #expect(run.conditionals == [], "the write carried validators from an earlier read")
        #expect(run.status == (method == "DELETE" ? 204 : 200))
    }
}
