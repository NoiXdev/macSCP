import Foundation
import Testing
@testable import macSCPCore

/// Canned-response transport (M12/T5): returns the next queued
/// `(Data, HTTPURLResponse)` pair for each `send`, in order, and records
/// every request it was asked to send. An `actor` because the queue is
/// mutated across concurrent `await`s — `S3HTTPTransport` requires
/// `Sendable`, and this is the simplest way to satisfy that honestly for a
/// stateful fake (no `@unchecked` needed).
actor FakeS3Transport: S3HTTPTransport {
    private var responses: [(Data, HTTPURLResponse)]
    private(set) var requests: [URLRequest] = []

    init(responses: [(Data, HTTPURLResponse)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw RemoteFSError.protocolError(reason: "FakeS3Transport ran out of canned responses")
        }
        return responses.removeFirst()
    }

    /// Delivers the next canned response's body as a stream, sliced into
    /// `TransferChunk.size` pieces so tests can observe chunking. Builds the
    /// stream from the already-popped `Data` local — the `AsyncThrowingStream`
    /// closure is non-isolated, so it must not touch `self` (an actor).
    func sendStreaming(_ request: URLRequest) async throws
        -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw RemoteFSError.protocolError(reason: "FakeS3Transport ran out of canned responses")
        }
        let (data, response) = responses.removeFirst()
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            // Emit the canned body in <= TransferChunk.size slices so tests see chunking.
            var offset = 0
            while offset < data.count {
                let end = min(offset + TransferChunk.size, data.count)
                continuation.yield(data.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
        }
        return (stream, response)
    }
}

/// Always throws a raw (non-`RemoteFSError`) error from `send`, so tests can
/// exercise `S3FileSystem`'s network-failure → `.connectionFailed` mapping
/// (`fetchPage`'s `catch` clause), which `FakeS3Transport` cannot reach since
/// it only ever returns canned responses or a `RemoteFSError` of its own.
struct ThrowingS3Transport: S3HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.cannotConnectToHost)
    }

    func sendStreaming(_ request: URLRequest) async throws
        -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse) {
        throw URLError(.cannotConnectToHost)
    }
}

@Suite("S3FileSystem")
struct S3FileSystemTests {
    private let config = S3ConnectionConfig(
        accessKeyID: "AK", secretAccessKey: "SK", region: "us-east-1",
        endpoint: "http://127.0.0.1:9000", bucket: "macscp-seed",
        usePathStyle: true, sessionToken: nil)

    /// An empty-but-valid ListObjectsV2 response, used purely to satisfy
    /// `connect`'s probe request in tests that want to control the response
    /// to the SUBSEQUENT `list` call independently of the connect probe.
    private let emptyListingXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <IsTruncated>false</IsTruncated>
    </ListBucketResult>
    """

    private let rootListingXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <IsTruncated>false</IsTruncated>
        <Contents>
            <Key>a.txt</Key>
            <LastModified>2024-01-02T03:04:05.000Z</LastModified>
            <Size>12</Size>
        </Contents>
        <CommonPrefixes>
            <Prefix>sub/</Prefix>
        </CommonPrefixes>
    </ListBucketResult>
    """

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:9000/macscp-seed")!,
            statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    private func connect(responses: [(Data, HTTPURLResponse)]) async throws -> (S3FileSystem, FakeS3Transport) {
        let transport = FakeS3Transport(responses: [(Data(emptyListingXML.utf8), httpResponse(status: 200))] + responses)
        let fs = try await S3FileSystem.connect(config, transport: transport)
        return (fs, transport)
    }

    @Test func listMapsCannedXMLIntoItems() async throws {
        let (fs, _) = try await connect(responses: [(Data(rootListingXML.utf8), httpResponse(status: 200))])

        let items = try await fs.list(path: "/")

        #expect(items.count == 2)
        #expect(items.first { $0.name == "a.txt" }?.kind == .file)
        #expect(items.first { $0.name == "a.txt" }?.size == 12)
        #expect(items.first { $0.name == "sub" }?.kind == .directory)
    }

    @Test func requestCarriesTheExpectedQueryAndAuthorizationHeader() async throws {
        let (fs, transport) = try await connect(responses: [(Data(rootListingXML.utf8), httpResponse(status: 200))])
        _ = try await fs.list(path: "/")

        let requests = await transport.requests
        let listRequest = try #require(requests.last)
        let url = try #require(listRequest.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = try #require(components.queryItems)

        #expect(queryItems.contains(URLQueryItem(name: "list-type", value: "2")))
        #expect(queryItems.contains(URLQueryItem(name: "prefix", value: "")))
        #expect(queryItems.contains(URLQueryItem(name: "delimiter", value: "/")))
        #expect(listRequest.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256") == true)
    }

    @Test func forbiddenResponseThrowsAuthenticationFailed() async throws {
        let (fs, _) = try await connect(responses: [(Data(), httpResponse(status: 403))])

        await #expect(throws: RemoteFSError.authenticationFailed) {
            _ = try await fs.list(path: "/")
        }
    }

    @Test func connectItselfMapsForbiddenToAuthenticationFailed() async throws {
        let transport = FakeS3Transport(responses: [(Data(), httpResponse(status: 403))])
        await #expect(throws: RemoteFSError.authenticationFailed) {
            _ = try await S3FileSystem.connect(config, transport: transport)
        }
    }

    @Test func notFoundResponseThrowsNotFound() async throws {
        let (fs, _) = try await connect(responses: [(Data(), httpResponse(status: 404))])

        do {
            _ = try await fs.list(path: "/missing")
            Issue.record("expected throw")
        } catch let error as RemoteFSError {
            guard case .notFound = error else {
                Issue.record("expected .notFound, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    /// `connect` performs a `ListObjectsV2` probe request itself, so a
    /// transport that throws a raw (non-`RemoteFSError`) error surfaces the
    /// `.connectionFailed` mapping there — there is no successfully-connected
    /// `S3FileSystem` to call `list` on in this scenario.
    @Test func networkFailureMapsToConnectionFailed() async throws {
        do {
            _ = try await S3FileSystem.connect(config, transport: ThrowingS3Transport())
            Issue.record("expected connect to throw")
        } catch let error as RemoteFSError {
            guard case .connectionFailed = error else {
                Issue.record("expected .connectionFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func truncatedListingPaginatesAndConcatenatesBothPages() async throws {
        let page1 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <IsTruncated>true</IsTruncated>
            <NextContinuationToken>tok-1</NextContinuationToken>
            <Contents>
                <Key>a.txt</Key>
                <Size>12</Size>
            </Contents>
        </ListBucketResult>
        """
        let page2 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <IsTruncated>false</IsTruncated>
            <Contents>
                <Key>z.txt</Key>
                <Size>3</Size>
            </Contents>
        </ListBucketResult>
        """
        let (fs, transport) = try await connect(responses: [
            (Data(page1.utf8), httpResponse(status: 200)),
            (Data(page2.utf8), httpResponse(status: 200)),
        ])

        let items = try await fs.list(path: "/")

        #expect(items.map(\.name).sorted() == ["a.txt", "z.txt"])

        let requests = await transport.requests
        // probe + page1 + page2 = 3 requests; the second page's request
        // must carry the continuation token from the first.
        #expect(requests.count == 3)
        let page2Request = requests[2]
        let page2URL = try #require(page2Request.url)
        let page2Query = try #require(URLComponents(url: page2URL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(page2Query.contains(URLQueryItem(name: "continuation-token", value: "tok-1")))
    }

    /// M12 review finding I-1: `NextContinuationToken` values are base64 and
    /// routinely contain `+`. The signer canonicalizes the query with
    /// strict RFC-3986 encoding (`+` → `%2B`), so the WIRE request must
    /// carry that same encoding — if it instead went out through
    /// `URLComponents`'s own (looser) re-encoding, the `+` would reach the
    /// server literally, get decoded as a space, and the signature would no
    /// longer match the query the server sees (HTTP 403 on every listing
    /// whose second page's continuation token contains a `+`).
    @Test func continuationTokenWithPlusIsPercentEncodedOnTheWire() async throws {
        let tokenWithPlus = "1/AB+cd=="
        let page1 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <IsTruncated>true</IsTruncated>
            <NextContinuationToken>\(tokenWithPlus)</NextContinuationToken>
            <Contents>
                <Key>a.txt</Key>
                <Size>12</Size>
            </Contents>
        </ListBucketResult>
        """
        let page2 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <IsTruncated>false</IsTruncated>
            <Contents>
                <Key>z.txt</Key>
                <Size>3</Size>
            </Contents>
        </ListBucketResult>
        """
        let (fs, transport) = try await connect(responses: [
            (Data(page1.utf8), httpResponse(status: 200)),
            (Data(page2.utf8), httpResponse(status: 200)),
        ])

        let items = try await fs.list(path: "/")

        // Both pages' items still concatenate correctly.
        #expect(items.map(\.name).sorted() == ["a.txt", "z.txt"])

        let requests = await transport.requests
        #expect(requests.count == 3)
        let page2URL = try #require(requests[2].url)
        let sentQuery = try #require(page2URL.query)

        // The `+` (and the `/` and `=` around it) must be percent-encoded
        // exactly as the signer encodes them — never sent as literal
        // characters, which is what `URLComponents`'s own re-encoding would
        // have done for `+`.
        #expect(sentQuery.contains("continuation-token=1%2FAB%2Bcd%3D%3D"))
        #expect(!sentQuery.contains("AB+cd"))
    }

    /// Same encoding requirement for a `prefix` (e.g. a folder name) that
    /// itself contains a `+` — this affects the FIRST page, not just
    /// pagination, so it's worth its own assertion.
    @Test func prefixWithPlusIsPercentEncodedOnTheWire() async throws {
        let (fs, transport) = try await connect(responses: [(Data(rootListingXML.utf8), httpResponse(status: 200))])

        _ = try await fs.list(path: "/folder+name")

        let requests = await transport.requests
        let listRequest = try #require(requests.last)
        let sentQuery = try #require(listRequest.url?.query)

        #expect(sentQuery.contains("prefix=folder%2Bname%2F"))
        #expect(!sentQuery.contains("folder+name"))
    }

    @Test func statFindsAFileByListingItsParent() async throws {
        let (fs, _) = try await connect(responses: [(Data(rootListingXML.utf8), httpResponse(status: 200))])
        let item = try await fs.stat(path: "/a.txt")
        #expect(item.kind == .file)
        #expect(item.size == 12)
    }

    @Test func statThrowsNotFoundWhenTheEntryIsMissing() async throws {
        let (fs, _) = try await connect(responses: [(Data(rootListingXML.utf8), httpResponse(status: 200))])
        do {
            _ = try await fs.stat(path: "/does-not-exist.txt")
            Issue.record("expected throw")
        } catch let error as RemoteFSError {
            guard case .notFound = error else {
                Issue.record("expected .notFound, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func homeDirectoryPathIsRoot() async throws {
        let (fs, _) = try await connect(responses: [])
        #expect(try await fs.homeDirectoryPath() == "/")
    }

    @Test func disconnectIsANoOp() async throws {
        let (fs, _) = try await connect(responses: [])
        await fs.disconnect()
    }

    /// S3 has no append; `TransferEngine` must never hand it a resumed
    /// `.append` write from a non-zero offset (M13/T1).
    @Test func supportsAppendResumeIsFalse() async throws {
        let (fs, _) = try await connect(responses: [])
        #expect(fs.supportsAppendResume == false)
    }

    // MARK: - M13 stubs: every mutating method throws protocolError

    /// Runs `operation` and asserts it throws specifically
    /// `RemoteFSError.protocolError`, not just some `RemoteFSError`.
    private func expectProtocolError(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("expected throw")
        } catch let error as RemoteFSError {
            guard case .protocolError = error else {
                Issue.record("expected .protocolError, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func readStreamThrowsProtocolError() async throws {
        let (fs, _) = try await connect(responses: [])
        await expectProtocolError {
            _ = try await fs.readStream(path: "/a.txt", fromOffset: 0)
        }
    }

    @Test func writeThrowsProtocolError() async throws {
        let (fs, _) = try await connect(responses: [])
        let stream = AsyncThrowingStream<Data, Error> { $0.finish() }
        await expectProtocolError {
            try await fs.write(path: "/a.txt", mode: .overwrite, contents: stream)
        }
    }

    @Test func deleteThrowsProtocolError() async throws {
        let (fs, _) = try await connect(responses: [])
        await expectProtocolError {
            try await fs.delete(path: "/a.txt")
        }
    }

    @Test func createDirectoryThrowsProtocolError() async throws {
        let (fs, _) = try await connect(responses: [])
        await expectProtocolError {
            try await fs.createDirectory(at: "/new")
        }
    }

    @Test func renameThrowsProtocolError() async throws {
        let (fs, _) = try await connect(responses: [])
        await expectProtocolError {
            try await fs.rename(from: "/a.txt", to: "/b.txt")
        }
    }

    @Test func setPermissionsThrowsProtocolError() async throws {
        let (fs, _) = try await connect(responses: [])
        await expectProtocolError {
            try await fs.setPermissions(path: "/a.txt", permissions: 0o644)
        }
    }

    @Test func deleteTreeThrowsProtocolError() async throws {
        let (fs, _) = try await connect(responses: [])
        await expectProtocolError {
            try await fs.deleteTree(at: "/sub")
        }
    }

    // MARK: - M13/T2: streaming transport seam

    /// Proves `FakeS3Transport.sendStreaming` chunks a canned body into
    /// `TransferChunk.size` pieces (so `S3FileSystem.readStream`, wired in
    /// T3, sees the same chunking the real `URLSessionS3Transport` would
    /// produce) and still returns the canned response. Deliberately
    /// independent of `S3FileSystem` — this only exercises the transport seam.
    @Test func fakeTransportSendStreamingChunksTheCannedBody() async throws {
        let body = Data((0..<(TransferChunk.size + 10)).map { UInt8($0 % 256) })
        let transport = FakeS3Transport(responses: [(body, httpResponse(status: 200))])
        let request = URLRequest(url: URL(string: "http://127.0.0.1:9000/macscp-seed/a.txt")!)

        let (stream, response) = try await transport.sendStreaming(request)

        var chunks: [Data] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }

        #expect(response.statusCode == 200)
        #expect(chunks.count >= 2)
        #expect(chunks.first?.count == TransferChunk.size)
        #expect(chunks.reduce(Data()) { $0 + $1 } == body)
    }

    // MARK: - M13/T3: readStream is a real, signed range GET

    /// `readStream` requests `Range: bytes={offset}-`, streams the object
    /// body through `sendStreaming`, and yields whatever chunks the
    /// transport hands back (chunking itself is `FakeS3Transport`'s job,
    /// proven above — this test only cares that the bytes/header are right).
    @Test func readStreamRequestsRangeAndYieldsChunkedBytes() async throws {
        let body = Data((0..<(TransferChunk.size + 10)).map { UInt8($0 & 0xFF) })
        let (fs, transport) = try await connect(responses: [(body, httpResponse(status: 206))])
        var received = Data()
        for try await chunk in try await fs.readStream(path: "/big.bin", fromOffset: 5) {
            received.append(chunk)
        }
        #expect(received == body)
        let req = await transport.requests.last!
        #expect(req.value(forHTTPHeaderField: "Range") == "bytes=5-")
        #expect(req.httpMethod == "GET")
    }

    /// S3 answers a range request past EOF with HTTP 416; the protocol
    /// contract is "offset at or beyond EOF yields an empty stream", not an
    /// error, so this must NOT throw.
    @Test func readStreamBeyondEOFYieldsEmptyStream() async throws {
        let (fs, _) = try await connect(responses: [(Data(), httpResponse(status: 416))])
        var count = 0
        for try await _ in try await fs.readStream(path: "/x", fromOffset: 999) { count += 1 }
        #expect(count == 0)
    }
}
