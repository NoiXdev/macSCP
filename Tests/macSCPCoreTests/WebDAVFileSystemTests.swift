import Foundation
import Testing
@testable import macSCPCore

/// Records every request and answers from a scripted queue, so request
/// building and error mapping are provable without a server — the same
/// approach the S3 tests take.
final class FakeHTTPTransport: HTTPTransport, @unchecked Sendable {
    struct Reply { let status: Int; let body: Data; let headers: [String: String] }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        guard !replies.isEmpty else {
            throw RemoteFSError.protocolError(reason: "fake transport ran out of replies")
        }
        let reply = replies.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status,
            httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply.body, response)
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
        stored: StoredWebDAVConfig(
            baseURL: "https://dav.example.com/dav", username: "u", useNextcloudPath: false),
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
    @Test func discardedHeadMaySpanSeveralChunks() async throws {
        let body = Data(repeating: 0x41, count: 10) + Data(repeating: 0x42, count: 3)
        let transport = FakeHTTPTransport(replies: [
            .init(status: 200, body: body, headers: [:])
        ])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        var received = Data()
        for try await chunk in try await fs.readStream(path: "/a.txt", fromOffset: 10) {
            received.append(chunk)
        }

        #expect(received == Data(repeating: 0x42, count: 3))
    }

    @Test func notFoundMapsToTypedError() async throws {
        let transport = FakeHTTPTransport(replies: [.init(status: 404, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        await #expect(throws: RemoteFSError.notFound(path: "/missing.txt")) {
            _ = try await fs.stat(path: "/missing.txt")
        }
    }

    @Test func unauthorizedMapsToAuthenticationFailed() async throws {
        let transport = FakeHTTPTransport(replies: [.init(status: 401, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        await #expect(throws: RemoteFSError.authenticationFailed) {
            _ = try await fs.list(path: "/")
        }
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
