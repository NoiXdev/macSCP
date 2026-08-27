import Foundation
import Synchronization
import Testing
@testable import macSCPCore

/// Records every request and answers from a scripted queue, so request
/// building and error mapping are provable without a server — the same
/// approach the S3 tests take.
///
/// It also **drains `httpBodyStream`** and records what it carried. That is
/// not a nicety: a streaming PUT feeds a bound stream pair with a single
/// `TransferChunk.size` buffer, so any body larger than that buffer only
/// finishes if somebody reads the other end. A transport that ignored the
/// body stream would make every multi-buffer upload test hang, and would let
/// a pump that wrote nothing at all pass unnoticed.
final class FakeHTTPTransport: HTTPTransport, Sendable {
    struct Reply { let status: Int; let body: Data; let headers: [String: String] }

    /// Carries a reference type Swift cannot prove `Sendable` across to the
    /// draining thread. Safe here: exactly one thread ever touches it.
    private struct Unchecked<T>: @unchecked Sendable { let value: T }

    private struct State {
        var replies: [Reply]
        var recordedRequests: [URLRequest] = []
        var recordedBodies: [Data] = []
    }

    private let state: Mutex<State>

    /// A server that rejects a PUT early — 401 on a stale nonce, 403, 507 —
    /// answers *without* reading the rest of the body. Pass `false` to
    /// reproduce exactly that.
    private let drainsRequestBody: Bool

    /// When set, `send` throws this instead of consulting `replies` — a
    /// transport-level failure (TLS, auth, timeout) rather than a mapped
    /// HTTP status.
    private let transportError: Error?

    /// Only consulted when `transportError` is set. Simulates what a real
    /// `URLSessionTask` does to its body stream when it tears itself down
    /// after a transport failure: opens then closes the paired
    /// `InputStream`, which delivers `.endEncountered` to the writer's
    /// `OutputStream` — the reader-vanished event `BoundStreamWriter` reacts
    /// to. Used to reproduce the precedence race in Finding 1 (fix round 3):
    /// the reader-vanished event landing before `write`'s catch block even
    /// gets to `pump.cancel()`.
    private let closesBodyStreamOnFailure: Bool

    init(replies: [Reply], drainsRequestBody: Bool = true,
         transportError: Error? = nil, closesBodyStreamOnFailure: Bool = false) {
        state = Mutex(State(replies: replies))
        self.drainsRequestBody = drainsRequestBody
        self.transportError = transportError
        self.closesBodyStreamOnFailure = closesBodyStreamOnFailure
    }

    var requests: [URLRequest] {
        state.withLock { $0.recordedRequests }
    }

    /// The bytes each streamed request body actually carried, in request order.
    var bodies: [Data] {
        state.withLock { $0.recordedBodies }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        state.withLock { $0.recordedRequests.append(request) }

        if let transportError {
            if closesBodyStreamOnFailure, let stream = request.httpBodyStream {
                // Give the pump time to fill the bound pair's single buffer
                // and park on it — the moment this race actually matters.
                try? await Task.sleep(nanoseconds: 200_000_000)
                stream.open()
                stream.close()
                // Let the writer's dedicated thread process the resulting
                // `.endEncountered` event and settle its terminal state
                // BEFORE the transport error below is thrown, so the race
                // this simulates is decided deterministically rather than by
                // scheduling luck.
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            throw transportError
        }

        if drainsRequestBody, let stream = request.httpBodyStream {
            let body = try await Self.drain(stream)
            state.withLock { $0.recordedBodies.append(body) }
        }

        let reply = try state.withLock {
            guard !$0.replies.isEmpty else {
                throw RemoteFSError.protocolError(reason: "fake transport ran out of replies")
            }
            return $0.replies.removeFirst()
        }

        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status,
            httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply.body, response)
    }

    /// Reads the body to EOF on a thread of its own. `InputStream.read`
    /// blocks, and blocking a cooperative executor thread here would starve
    /// the very pump that has to keep feeding the other end.
    private static func drain(_ stream: InputStream) async throws -> Data {
        let boxed = Unchecked(value: stream)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let input = boxed.value
                input.open()
                defer { input.close() }
                var collected = Data()
                var buffer = [UInt8](repeating: 0, count: 32 * 1024)
                while true {
                    let read = input.read(&buffer, maxLength: buffer.count)
                    if read < 0 {
                        continuation.resume(throwing: RemoteFSError.connectionFailed(
                            reason: "fake transport failed to read the request body"))
                        return
                    }
                    if read == 0 { break }
                    collected.append(contentsOf: buffer[0..<read])
                }
                continuation.resume(returning: collected)
            }
        }
    }

    func sendStreaming(_ request: URLRequest) async throws
        -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse) {
        let (data, response) = try await send(request)
        return (AsyncThrowingStream { continuation in
            if !data.isEmpty { continuation.yield(data) }
            continuation.finish()
        }, response)
    }
}

@Suite("WebDAVFileSystem")
struct WebDAVFileSystemTests {
    private let config = WebDAVConnectionConfig(
        baseURL: "https://dav.example.com/dav", username: "u", useNextcloudPath: false,
        password: "p")

    private let listing = Data("""
    <?xml version="1.0"?>
    <d:multistatus xmlns:d="DAV:">
      <d:response><d:href>/dav/</d:href>
        <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
      <d:response><d:href>/dav/a.txt</d:href>
        <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>12</d:getcontentlength></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
    </d:multistatus>
    """.utf8)

    @Test func listIssuesPropfindWithDepthOne() async throws {
        let transport = FakeHTTPTransport(replies: [
            .init(status: 207, body: listing, headers: [:])
        ])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        let items = try await fs.list(path: "/")

        #expect(items.map(\.name) == ["a.txt"])
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "PROPFIND")
        #expect(request.value(forHTTPHeaderField: "Depth") == "1")
        #expect(request.url?.absoluteString == "https://dav.example.com/dav/")
    }

    @Test func statIssuesPropfindWithDepthZero() async throws {
        let single = Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/dav/a.txt</d:href>
            <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>12</d:getcontentlength></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """.utf8)
        let transport = FakeHTTPTransport(replies: [.init(status: 207, body: single, headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        let item = try await fs.stat(path: "/a.txt")

        #expect(item.name == "a.txt")
        #expect(item.size == 12)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Depth") == "0")
    }

    /// `stat` on the root must address the base with a single trailing slash —
    /// the shape M20 got wrong for SFTP.
    @Test func statOfRootUsesASingleTrailingSlash() async throws {
        let transport = FakeHTTPTransport(replies: [
            .init(status: 207, body: listing, headers: [:])
        ])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        let item = try await fs.stat(path: "/")

        #expect(item.path == "/")
        #expect(item.kind == .directory)
        #expect(transport.requests.first?.url?.absoluteString == "https://dav.example.com/dav/")
    }

    @Test func readStreamSendsARangeHeaderWhenResuming() async throws {
        let transport = FakeHTTPTransport(replies: [
            .init(status: 206, body: Data("tail".utf8), headers: ["Accept-Ranges": "bytes"])
        ])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        var received = Data()
        for try await chunk in try await fs.readStream(path: "/a.txt", fromOffset: 8) {
            received.append(chunk)
        }

        #expect(String(data: received, encoding: .utf8) == "tail")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Range") == "bytes=8-")
    }

    /// A server that ignores Range answers 200 with the WHOLE body. Handing
    /// that to a caller who asked for byte 6 onward would append the head a
    /// second time and corrupt the file. The backend drops the head itself,
    /// so the caller gets exactly what it asked for — at the cost of
    /// re-transferring what it already had.
    @Test func rangeIgnoredByServerFallsBackToDiscardingTheHead() async throws {
        let transport = FakeHTTPTransport(replies: [
            .init(status: 200, body: Data("headtail".utf8), headers: [:])
        ])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        var received = Data()
        for try await chunk in try await fs.readStream(path: "/a.txt", fromOffset: 4) {
            received.append(chunk)
        }

        #expect(String(data: received, encoding: .utf8) == "tail")
    }

    /// The head may span several chunks — dropping only within the first one
    /// would leak the remainder of the head into the caller's file.
    ///
    /// Goes straight at `dropping(_:from:)` with a hand-built stream that
    /// actually delivers several chunks, rather than through
    /// `readStream`/`FakeHTTPTransport.sendStreaming` — that path collapses
    /// any body into a SINGLE chunk, so it cannot distinguish a correct
    /// running-total discard from a broken first-chunk-only one; a wrong
    /// implementation would pass it just as well as a correct one.
    @Test func discardedHeadMaySpanSeveralChunks() async throws {
        let chunks = [
            Data(repeating: 0x41, count: 4),
            Data(repeating: 0x41, count: 4),
            Data(repeating: 0x41, count: 2) + Data(repeating: 0x42, count: 3),
        ]
        let source = AsyncThrowingStream<Data, Error> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }

        var received = Data()
        for try await chunk in WebDAVFileSystem.dropping(10, from: source) {
            received.append(chunk)
        }

        #expect(received == Data(repeating: 0x42, count: 3))
    }

    /// A 404 on the first shape guess is shape-ambiguous, so `stat` retries
    /// with the other shape. When BOTH attempts 404, that is a genuine miss:
    /// two replies are stubbed here (not one) to prove the retry actually
    /// happens and still lands on the correct typed error, rather than
    /// merely reflecting an unstubbed first attempt.
    @Test func notFoundMapsToTypedError() async throws {
        let transport = FakeHTTPTransport(replies: [
            .init(status: 404, body: Data(), headers: [:]),
            .init(status: 404, body: Data(), headers: [:]),
        ])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        await #expect(throws: RemoteFSError.notFound(path: "/missing.txt")) {
            _ = try await fs.stat(path: "/missing.txt")
        }
        #expect(transport.requests.count == 2)
    }

    /// Some servers 404 a collection addressed without its trailing slash
    /// instead of redirecting or answering 2xx with no matching entry. The
    /// first attempt's 404 must not be treated as definitive: retrying with
    /// the other URL shape finds the directory.
    @Test func stat404OnFirstShapeRetriesAndSucceeds() async throws {
        let directoryEntry = Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/dav/dir/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """.utf8)
        let transport = FakeHTTPTransport(replies: [
            .init(status: 404, body: Data(), headers: [:]),
            .init(status: 207, body: directoryEntry, headers: [:]),
        ])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        let item = try await fs.stat(path: "/dir")

        #expect(item.path == "/dir")
        #expect(item.kind == .directory)
        #expect(transport.requests.count == 2)
    }

    @Test func unauthorizedMapsToAuthenticationFailed() async throws {
        let transport = FakeHTTPTransport(replies: [.init(status: 401, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        await #expect(throws: RemoteFSError.authenticationFailed) {
            _ = try await fs.list(path: "/")
        }
    }

    /// 401 is not shape-ambiguous — it is the caller's answer already, and
    /// retrying would waste a round trip. Only a single reply is stubbed: a
    /// retry would exhaust the fake transport and surface
    /// `.protocolError("fake transport ran out of replies")` instead of
    /// `.authenticationFailed`, so this test would fail loudly if `stat`
    /// retried on 401.
    @Test func unauthorizedDoesNotRetryStat() async throws {
        let transport = FakeHTTPTransport(replies: [.init(status: 401, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        await #expect(throws: RemoteFSError.authenticationFailed) {
            _ = try await fs.stat(path: "/private.txt")
        }
        #expect(transport.requests.count == 1)
    }

    @Test func homeDirectoryIsTheRoot() async throws {
        let fs = WebDAVFileSystem(config: config, transport: FakeHTTPTransport(replies: []))
        #expect(try await fs.homeDirectoryPath() == "/")
    }

    /// WebDAV has no partial PUT — the queue reads this to gate resume.
    @Test func appendResumeIsNotSupported() {
        let fs = WebDAVFileSystem(config: config, transport: FakeHTTPTransport(replies: []))
        #expect(fs.supportsAppendResume == false)
    }
}
