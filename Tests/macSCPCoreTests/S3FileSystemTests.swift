import Foundation
import Testing
@testable import macSCPCore

/// Canned-response transport (M12/T5): returns the next queued
/// `(Data, HTTPURLResponse)` pair for each `send`, in order, and records
/// every request it was asked to send. An `actor` because the queue is
/// mutated across concurrent `await`s — `HTTPTransport` requires
/// `Sendable`, and this is the simplest way to satisfy that honestly for a
/// stateful fake (no `@unchecked` needed).
actor FakeS3Transport: HTTPTransport {
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
struct ThrowingS3Transport: HTTPTransport {
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

    /// `disconnect()` invalidates the session the dial built for itself, but
    /// an injected transport's session belongs to whoever injected it — so
    /// for this construction the call must still change nothing, and the
    /// file system must keep working afterwards. The second listing is what
    /// makes that a claim rather than a call that merely did not crash.
    @Test func disconnectLeavesAnInjectedTransportAlone() async throws {
        let (fs, _) = try await connect(
            responses: [(Data(rootListingXML.utf8), httpResponse(status: 200))])

        await fs.disconnect()

        let items = try await fs.list(path: "/")
        #expect(items.count == 2)
    }

    /// S3 has no append; `TransferEngine` must never hand it a resumed
    /// `.append` write from a non-zero offset (M13/T1).
    @Test func supportsAppendResumeIsFalse() async throws {
        let (fs, _) = try await connect(responses: [])
        #expect(fs.supportsAppendResume == false)
    }

    /// The one thing the browser has to learn from the connection to gate a
    /// bucket row (2026-09-02): whether `/` lists containers. Both answers,
    /// so the flag cannot be a constant.
    @Test func onlyABucketListSessionSaysItsRootListsContainers() async throws {
        let (listMode, _) = try await connectAtBucketList(responses: [])
        #expect(listMode.rootIsContainerList)

        let (oneBucket, _) = try await connect(responses: [])
        #expect(oneBucket.rootIsContainerList == false)
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

    /// Runs `operation` and asserts the BUCKET-LEVEL guard is what refused
    /// it — its own error case, naming the operation and the path.
    ///
    /// `expectProtocolError` above cannot make that claim and never could:
    /// `FakeS3Transport` throws `.protocolError` when it runs out of canned
    /// responses, so every one of those checks passed with the guard
    /// deleted (Task 2 review, I-2). The only load-bearing assertion in
    /// that test was the request count. Here the case itself is the
    /// assertion, and the transport's exhaustion error cannot satisfy it.
    private func expectBucketRefusal(
        _ expectedOperation: RemoteFSError.BucketLevelOperation, _ expectedPath: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("expected throw", sourceLocation: sourceLocation)
        } catch let error as RemoteFSError {
            guard case .bucketLevelRefused(let operationName, let path) = error else {
                Issue.record(
                    "expected .bucketLevelRefused, got \(error)", sourceLocation: sourceLocation)
                return
            }
            #expect(operationName == expectedOperation, sourceLocation: sourceLocation)
            #expect(path == expectedPath, sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected error type: \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func readStreamThrowsProtocolError() async throws {
        let (fs, _) = try await connect(responses: [])
        await expectProtocolError {
            _ = try await fs.readStream(path: "/a.txt", fromOffset: 0)
        }
    }

    // `write` is real as of M13/T5 (delegates to `S3Uploader`),
    // `delete`/`createDirectory` are real as of M13/T4, and `rename` is real
    // as of M13/T7 — see the "M13/T5: write delegates to S3Uploader",
    // "M13/T4: delete + createDirectory", and "M13/T7: rename" sections
    // below for their coverage.

    @Test func setPermissionsThrowsProtocolError() async throws {
        let (fs, _) = try await connect(responses: [])
        await expectProtocolError {
            try await fs.setPermissions(path: "/a.txt", permissions: 0o644)
        }
    }

    // `deleteTree` is real as of M13/T8 (recursive list + batched
    // DeleteObjects) — see the "M13/T8: deleteTree" section below for its
    // coverage.

    // MARK: - M13/T2: streaming transport seam

    /// Proves `FakeS3Transport.sendStreaming` chunks a canned body into
    /// `TransferChunk.size` pieces (so `S3FileSystem.readStream`, wired in
    /// T3, sees the same chunking the real `URLSessionHTTPTransport` would
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
        // Regression guard: Range must stay unsigned (M13 T3 review, Minor 2).
        // `Authorization`'s `SignedHeaders=host;x-amz-...` names are all
        // lowercase, so the literal substring "range" only shows up there if
        // Range were mistakenly folded into the signed header set.
        let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
        #expect(!auth.contains("range"))
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

    // MARK: - M13/T4: delete + createDirectory

    /// The lookup listing in front of the DELETE (see `delete(path:)`)
    /// answers for `dir/file.txt`, so the object key is what leaves.
    @Test func deleteSendsDeleteForTheObjectKey() async throws {
        let (fs, transport) = try await connect(responses: [
            (Data(listingWithKeys(["dir/file.txt"]).utf8), httpResponse(status: 200)),
            (Data(), httpResponse(status: 204)),
        ])
        try await fs.delete(path: "/dir/file.txt")
        let req = await transport.requests.last!
        #expect(req.httpMethod == "DELETE")
        #expect(req.url!.path.hasSuffix("/dir/file.txt"))
    }

    /// A 404 on the DELETE ITSELF still maps to `notFound` — the lookup
    /// found the object, so the 404 can only have come from the delete.
    /// (`deleteOnAMissingKeyThrowsNotFoundAndSendsNoDelete` below covers
    /// the other, now far more common, way to reach that case.)
    @Test func deleteNotFoundResponseThrowsNotFound() async throws {
        let (fs, _) = try await connect(responses: [
            (Data(listingWithKeys(["dir/file.txt"]).utf8), httpResponse(status: 200)),
            (Data(), httpResponse(status: 404)),
        ])
        do {
            try await fs.delete(path: "/dir/file.txt")
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

    /// `RemoteFileSystem.delete`'s contract: "Throws
    /// `RemoteFSError.protocolError` if `path` is a directory."
    /// `DeleteObject` cannot carry that on its own — it answers 204 for any
    /// key, and `mode.resolve` addresses the BARE key `sub`, never the
    /// `sub/` marker the directory actually is, so the request went out and
    /// came back a silent success having deleted nothing.
    ///
    /// The spare 204 left in the queue is deliberate: `FakeS3Transport`
    /// throws `.protocolError` when it runs out of canned responses, so
    /// without a response to spare the expectation below could be satisfied
    /// by exhaustion rather than by the guard.
    @Test func deleteOnADirectoryThrowsProtocolErrorAndSendsNoDelete() async throws {
        let (fs, transport) = try await connect(responses: [
            (Data(rootListingXML.utf8), httpResponse(status: 200)),
            (Data(), httpResponse(status: 204)),
        ])

        await expectProtocolError { try await fs.delete(path: "/sub") }

        // The connect probe and the lookup listing, and nothing after them.
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(!requests.contains { $0.httpMethod == "DELETE" })
    }

    /// ...and: "Throws `RemoteFSError.notFound` if nothing exists there."
    /// `DeleteObject` is idempotent — 204 for a key that never existed — so
    /// deleting nothing reported success too.
    @Test func deleteOnAMissingKeyThrowsNotFoundAndSendsNoDelete() async throws {
        let (fs, transport) = try await connect(responses: [
            (Data(rootListingXML.utf8), httpResponse(status: 200)),
            (Data(), httpResponse(status: 204)),
        ])

        await #expect(throws: RemoteFSError.notFound(path: "/nope")) {
            try await fs.delete(path: "/nope")
        }

        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(!requests.contains { $0.httpMethod == "DELETE" })
    }

    @Test func createDirectoryPutsAZeroByteMarkerKey() async throws {
        let (fs, transport) = try await connect(responses: [(Data(), httpResponse(status: 200))])
        try await fs.createDirectory(at: "/newfolder")
        let req = await transport.requests.last!
        #expect(req.httpMethod == "PUT")
        // `URL.path` silently drops a trailing slash (a Foundation quirk),
        // so assert against the percent-encoded path to actually see the
        // marker's trailing "/" as it goes out on the wire.
        #expect(req.url!.path(percentEncoded: true).hasSuffix("/newfolder/"))
        #expect((req.httpBody?.count ?? 0) == 0)
    }

    // MARK: - M13/T5: write delegates to S3Uploader

    /// `write`'s own logic (buffering, threshold, signing) is `S3Uploader`'s
    /// job and is covered exhaustively in `S3UploaderTests.swift` against a
    /// fake `S3RequestBuilder`. This only proves the WIRING: `write` reaches
    /// the real transport as a single signed PUT of the exact key/body, `mode`
    /// is accepted but ignored (Task 1's resume guard means an S3 destination
    /// only ever gets `.overwrite`).
    @Test func writeSendsASingleSignedPutOfTheStreamedContent() async throws {
        let (fs, transport) = try await connect(responses: [(Data(), httpResponse(status: 200))])
        let body = Data("hello s3".utf8)
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(body)
            continuation.finish()
        }

        try await fs.write(path: "/dir/file.txt", mode: .overwrite, contents: stream)

        let req = await transport.requests.last!
        #expect(req.httpMethod == "PUT")
        #expect(req.url!.path(percentEncoded: true).hasSuffix("/dir/file.txt"))
        #expect(req.httpBody == body)
    }

    @Test func writeForbiddenResponseThrowsAuthenticationFailed() async throws {
        let (fs, _) = try await connect(responses: [(Data(), httpResponse(status: 403))])
        let stream = AsyncThrowingStream<Data, Error> { $0.finish() }
        await #expect(throws: RemoteFSError.authenticationFailed) {
            try await fs.write(path: "/a.txt", mode: .overwrite, contents: stream)
        }
    }

    // MARK: - M13/T7: rename

    /// A no-delimiter ListObjectsV2 response listing every key under a
    /// prefix directly (used by `allObjectKeys`, exercised here indirectly
    /// through a directory rename) — three raw keys, including the
    /// directory's own trailing-slash marker.
    private let srcdirRawKeysXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <IsTruncated>false</IsTruncated>
        <Contents>
            <Key>srcdir/a.txt</Key>
            <Size>1</Size>
        </Contents>
        <Contents>
            <Key>srcdir/sub/b.txt</Key>
            <Size>2</Size>
        </Contents>
        <Contents>
            <Key>srcdir/</Key>
            <Size>0</Size>
        </Contents>
    </ListBucketResult>
    """

    private let srcdirAsCommonPrefixXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <IsTruncated>false</IsTruncated>
        <CommonPrefixes>
            <Prefix>srcdir/</Prefix>
        </CommonPrefixes>
    </ListBucketResult>
    """

    /// A well-formed `CopyObjectResult` body — what a genuinely successful
    /// server-side copy returns on HTTP 200. Used as the canned PUT-copy
    /// response in tests that exercise a rename all the way through, now
    /// that `copyObject` inspects the 2xx body instead of trusting the
    /// status code alone.
    private let copyObjectResultXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <CopyObjectResult>
        <LastModified>2024-01-02T03:04:05.000Z</LastModified>
        <ETag>"abc123"</ETag>
    </CopyObjectResult>
    """

    /// What S3 is documented to sometimes return for a server-side copy that
    /// failed PARTWAY through: HTTP 200 with an `<Error>` XML body instead
    /// of a `<CopyObjectResult>`. `copyObject` must treat this as a failure
    /// even though the status code alone says success.
    private let copyObjectErrorBodyXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Error>
        <Code>InternalError</Code>
        <Message>We encountered an internal error. Please try again.</Message>
    </Error>
    """

    /// `rename` on a FILE: `stat(to)` (the destination pre-check — S3's
    /// PUT-copy would otherwise silently overwrite) finds nothing, `stat
    /// (from)` finds the source file, then a signed PUT carries `x-amz-
    /// copy-source` referencing the source key, followed by a DELETE of the
    /// source. Both `from` and `to` live at the bucket root here, so both
    /// `stat` calls list the SAME parent prefix (""), just against
    /// different canned responses — the sequence below mirrors that.
    @Test func renameFileCopiesThenDeletesAndPrechecksDestination() async throws {
        let (fs, transport) = try await connect(responses: [
            (Data(emptyListingXML.utf8), httpResponse(status: 200)),    // stat(to="/b.txt") -> not found
            (Data(rootListingXML.utf8), httpResponse(status: 200)),     // stat(from="/a.txt") -> file found
            (Data(copyObjectResultXML.utf8), httpResponse(status: 200)), // PUT copy
            (Data(), httpResponse(status: 204)),                        // DELETE source
        ])

        try await fs.rename(from: "/a.txt", to: "/b.txt")

        let requests = await transport.requests
        let copy = try #require(requests.first { $0.httpMethod == "PUT" })
        #expect(copy.value(forHTTPHeaderField: "x-amz-copy-source")?.contains("a.txt") == true)
        #expect(copy.url!.path(percentEncoded: true).hasSuffix("/b.txt"))

        let delete = try #require(requests.first { $0.httpMethod == "DELETE" })
        #expect(delete.url!.path(percentEncoded: true).hasSuffix("/a.txt"))
    }

    /// The destination pre-check must reject the rename WITHOUT issuing any
    /// copy or delete when something already exists at `to`.
    @Test func renameThrowsWhenDestinationAlreadyExists() async throws {
        let (fs, transport) = try await connect(responses: [
            (Data(rootListingXML.utf8), httpResponse(status: 200)), // stat(to="/a.txt") -> already exists
        ])

        await expectProtocolError {
            try await fs.rename(from: "/other.txt", to: "/a.txt")
        }

        let requests = await transport.requests
        #expect(!requests.contains { $0.httpMethod == "PUT" })
        #expect(!requests.contains { $0.httpMethod == "DELETE" })
    }

    /// `rename` on a DIRECTORY re-keys every object under the source
    /// prefix — including the directory's own trailing-slash marker — via
    /// `allObjectKeys(underPrefix:)` (a no-delimiter listing), one
    /// copy+delete pair per key.
    @Test func renameDirectoryReKeysEveryObjectUnderThePrefix() async throws {
        let (fs, transport) = try await connect(responses: [
            (Data(emptyListingXML.utf8), httpResponse(status: 200)),        // stat(to="/destdir") -> not found
            (Data(srcdirAsCommonPrefixXML.utf8), httpResponse(status: 200)), // stat(from="/srcdir") -> directory found
            (Data(srcdirRawKeysXML.utf8), httpResponse(status: 200)),        // allObjectKeys(underPrefix: "srcdir/")
            (Data(copyObjectResultXML.utf8), httpResponse(status: 200)), (Data(), httpResponse(status: 204)), // copy+delete srcdir/a.txt
            (Data(copyObjectResultXML.utf8), httpResponse(status: 200)), (Data(), httpResponse(status: 204)), // copy+delete srcdir/sub/b.txt
            (Data(copyObjectResultXML.utf8), httpResponse(status: 200)), (Data(), httpResponse(status: 204)), // copy+delete srcdir/ (marker)
        ])

        try await fs.rename(from: "/srcdir", to: "/destdir")

        let requests = await transport.requests
        let puts = requests.filter { $0.httpMethod == "PUT" }
        let deletes = requests.filter { $0.httpMethod == "DELETE" }
        #expect(puts.count == 3)
        #expect(deletes.count == 3)

        let putPaths = puts.map { $0.url!.path(percentEncoded: true) }
        #expect(putPaths.contains { $0.hasSuffix("/destdir/a.txt") })
        #expect(putPaths.contains { $0.hasSuffix("/destdir/sub/b.txt") })
        #expect(putPaths.contains { $0.hasSuffix("/destdir/") })

        let deletePaths = deletes.map { $0.url!.path(percentEncoded: true) }
        #expect(deletePaths.contains { $0.hasSuffix("/srcdir/a.txt") })
        #expect(deletePaths.contains { $0.hasSuffix("/srcdir/sub/b.txt") })
        #expect(deletePaths.contains { $0.hasSuffix("/srcdir/") })

        // Every copy's `x-amz-copy-source` must reference its OWN source
        // key, not just any key under the prefix.
        let copySourceForDestSub = puts.first { $0.url!.path(percentEncoded: true).hasSuffix("/destdir/sub/b.txt") }?
            .value(forHTTPHeaderField: "x-amz-copy-source")
        #expect(copySourceForDestSub?.contains("srcdir/sub/b.txt") == true)
    }

    /// A transient (non-404) failure on the destination pre-check `stat`
    /// must NOT be treated as "destination absent". Before the fix, `(try?
    /// await stat(path: to)) != nil` collapsed EVERY `stat` failure —
    /// including a 500 — to `nil`, so `rename` proceeded to copy over
    /// whatever really lives at `to`. Now only `RemoteFSError.notFound`
    /// means "confirmed absent"; anything else must propagate and `rename`
    /// must issue no copy or delete at all.
    @Test func renameThrowsWhenDestinationPrecheckFailsTransiently() async throws {
        let (fs, transport) = try await connect(responses: [
            (Data(), httpResponse(status: 500)), // stat(to="/b.txt") -> transient server error, NOT "not found"
        ])

        await expectProtocolError {
            try await fs.rename(from: "/a.txt", to: "/b.txt")
        }

        let requests = await transport.requests
        #expect(!requests.contains { $0.httpMethod == "PUT" })
        #expect(!requests.contains { $0.httpMethod == "DELETE" })
    }

    /// S3's server-side CopyObject can answer HTTP 200 with an `<Error>`
    /// XML body when the copy fails partway through. `rename` unconditionally
    /// deletes the source right after a successful copy, so treating that
    /// "successful" 200 as real would delete the only remaining copy of the
    /// data. `copyObject` must inspect the 2xx body and throw, and `rename`
    /// must not reach the source DELETE.
    @Test func renameThrowsAndDoesNotDeleteSourceWhenCopyReturns200WithErrorBody() async throws {
        let (fs, transport) = try await connect(responses: [
            (Data(emptyListingXML.utf8), httpResponse(status: 200)), // stat(to="/b.txt") -> not found
            (Data(rootListingXML.utf8), httpResponse(status: 200)),  // stat(from="/a.txt") -> file found
            (Data(copyObjectErrorBodyXML.utf8), httpResponse(status: 200)), // PUT copy -> 200 with <Error> body
        ])

        await expectProtocolError {
            try await fs.rename(from: "/a.txt", to: "/b.txt")
        }

        let requests = await transport.requests
        #expect(!requests.contains { $0.httpMethod == "DELETE" })
    }

    // MARK: - M14/T2: presignedURL

    /// Pure-computation check (no fake-transport response is even consumed
    /// beyond the `connect` probe): the presigned URL carries the expected
    /// SigV4 query-parameter shape, the expiry is clamped to the SigV4
    /// maximum of 7 days, and the secret access key never appears in the
    /// URL itself (it only ever feeds the signature, an HMAC digest).
    @Test func presignedGetURLCarriesSigV4QueryAndClampsExpiry() async throws {
        let (fs, _) = try await connect(responses: [(Data(rootListingXML.utf8), httpResponse(status: 200))])
        // `fs` already conforms to `PresignedURLProvider`; call it directly (the
        // `as?` seam is exercised at the App call site, not here).
        let url = try fs.presignedURL(
            method: .get, key: "dir/file.txt", expiresIn: 999_999_999) // clamp to 7d
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(q["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256")
        #expect(q["X-Amz-Expires"] == "604800") // clamped to SigV4 max
        #expect(q["X-Amz-Signature"]?.isEmpty == false)
        #expect(url.path.hasSuffix("/dir/file.txt"))
        #expect(!url.absoluteString.contains(config.secretAccessKey)) // secret never in URL
    }

    /// The presigned URL is signed with the SAME canonical path the request
    /// factory pairs with that key's URL — re-review Finding A, which found
    /// `presignedURL` hand-pairing `keyRequestURL` with `canonicalKeyPath`
    /// six lines apart, outside the factory that exists to own exactly that.
    ///
    /// Proved by RE-SIGNING rather than by reading a path: a signature is the
    /// only observable that depends on the signed path, and
    /// `SigV4Signer.presignedQuery` derives everything else from the
    /// formatted `X-Amz-Date`, which the URL itself carries to the second.
    /// So parsing that date back and recomputing over
    /// `S3FileSystem.addressed`'s canonical path reproduces the signature
    /// exactly when the two paths agree — and the third expectation, over a
    /// deliberately different path, is what says this comparison can fail at
    /// all.
    ///
    /// Both addressing styles, because they produce DIFFERENT canonical paths
    /// for the same key (`/{bucket}/{key}` path-style, `/{key}`
    /// virtual-hosted), so a single style could pass while the other drifted.
    @Test(arguments: [true, false])
    func thePresignedURLSignsTheSamePathTheFactoryDoes(usePathStyle: Bool) async throws {
        var styled = config
        styled.usePathStyle = usePathStyle
        let transport = FakeS3Transport(
            responses: [(Data(emptyListingXML.utf8), httpResponse(status: 200))])
        let fs = try await S3FileSystem.connect(styled, transport: transport)
        let key = "dir/file.txt"

        let url = try fs.presignedURL(method: .get, key: key, expiresIn: 600)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        let presignedSignature = try #require(query["X-Amz-Signature"])
        let stamp = try #require(query["X-Amz-Date"])
        let signedAt = try #require(Self.amzDate(stamp))

        // The pairing the factory would use for this very key.
        let paired = try S3FileSystem.addressed(
            .objectKey(bucket: styled.bucket, key: key), query: [], config: styled)
        let host = try #require(paired.url.host)
        let hostHeader = paired.url.port.map { "\(host):\($0)" } ?? host
        let signer = SigV4Signer(
            accessKeyID: styled.accessKeyID, secretAccessKey: styled.secretAccessKey,
            region: styled.region, service: "s3", sessionToken: styled.sessionToken)

        func signatureOver(_ path: String) -> String? {
            signer.presignedQuery(
                method: "GET", host: hostHeader, path: path, expiresInSeconds: 600,
                date: signedAt
            ).first { $0.name == "X-Amz-Signature" }?.value
        }

        #expect(presignedSignature == signatureOver(paired.canonicalPath))
        // The wire URL is the factory's too, so the URL and the signature
        // cannot come from two different addressings.
        #expect(url.path == paired.url.path)
        // The negative half: a different path really does produce a different
        // signature, so the equality above is a measurement and not an
        // identity that would hold for any path at all.
        #expect(presignedSignature != signatureOver(paired.canonicalPath + "-elsewhere"))
    }

    /// `X-Amz-Date` back into the `Date` it was formatted from. SigV4 carries
    /// seconds and no more, and `presignedQuery` reads the date only through
    /// this format and the day stamp cut from it, so a round trip through the
    /// string is exact for signing purposes.
    private static func amzDate(_ stamp: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.date(from: stamp)
    }

    // MARK: - M13/T8: deleteTree

    /// A no-delimiter `ListObjectsV2` response listing exactly the given
    /// raw keys as `<Contents><Key>` entries — the shape `allObjectKeys`
    /// parses, parametrized so `deleteTree` tests can hand it whichever
    /// keys (including a directory's own trailing-slash marker) they need.
    private func listingWithKeys(_ keys: [String]) -> String {
        let contents = keys.map { "<Contents><Key>\($0)</Key><Size>0</Size></Contents>" }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <IsTruncated>false</IsTruncated>
            \(contents)
        </ListBucketResult>
        """
    }

    /// A delimited listing of the bucket root whose only entry is the
    /// `CommonPrefixes` "directory" `d/` — what `stat("/d")` sees, and so
    /// the reply that precedes every walk below.
    private let directoryDListingXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <IsTruncated>false</IsTruncated>
        <CommonPrefixes>
            <Prefix>d/</Prefix>
        </CommonPrefixes>
    </ListBucketResult>
    """

    /// `deleteTree` lists every key under the prefix (including the
    /// directory's own trailing-slash marker) via `allObjectKeys`, then
    /// issues ONE signed `POST {bucket}?delete` per <=1000-key batch with a
    /// `Content-MD5` header (S3 requires it for this call) and an XML body
    /// naming every key in the batch.
    @Test func deleteTreeBatchesDeleteObjectsWithContentMD5() async throws {
        let (fs, transport) = try await connect(responses: [
            (Data(directoryDListingXML.utf8), httpResponse(status: 200)),
            (Data(listingWithKeys(["d/", "d/a", "d/b"]).utf8), httpResponse(status: 200)),
            (Data("<DeleteResult></DeleteResult>".utf8), httpResponse(status: 200)),
        ])

        try await fs.deleteTree(at: "/d")

        let del = await transport.requests.last!
        #expect(del.httpMethod == "POST")
        #expect((del.url!.query ?? "").contains("delete"))
        #expect(del.value(forHTTPHeaderField: "Content-MD5") != nil)
        let bodyXML = String(data: del.httpBody!, encoding: .utf8)!
        #expect(bodyXML.contains("<Key>d/a</Key>") && bodyXML.contains("<Key>d/</Key>"))
    }

    /// The keys in that body are XML-ESCAPED, and nothing pinned that
    /// before: mutating the escaper to return its input unchanged left the
    /// whole suite green, which is how a security-relevant function ends up
    /// rewritten with no test behind it.
    ///
    /// An object named `a&b.txt` is ordinary, and `a<b` or `a"b` are legal
    /// S3 keys too. Unescaped, each one decides where `<Key>` ends — the
    /// body stops being the document this process meant to send. The listing
    /// hands the raw key back, so the round trip is real rather than
    /// hypothetical: the parser unescapes what S3 sent, and this rebuilds it.
    @Test func deleteTreeEscapesXMLMetacharactersInKeys() async throws {
        let (fs, transport) = try await connect(responses: [
            (Data(directoryDListingXML.utf8), httpResponse(status: 200)),
            (Data(listingWithKeys(["d/", "d/a&amp;b.txt", "d/c&lt;d&gt;e", "d/f&quot;g&apos;h"]).utf8),
             httpResponse(status: 200)),
            (Data("<DeleteResult></DeleteResult>".utf8), httpResponse(status: 200)),
        ])

        try await fs.deleteTree(at: "/d")

        let bodyXML = String(data: await transport.requests.last!.httpBody!, encoding: .utf8)!
        #expect(bodyXML.contains("<Key>d/a&amp;b.txt</Key>"))
        #expect(bodyXML.contains("<Key>d/c&lt;d&gt;e</Key>"))
        #expect(bodyXML.contains("<Key>d/f&quot;g&apos;h</Key>"))
        // The escape is a single pass, so an ampersand it introduced is not
        // escaped again -- the ordering trap of chained replacement.
        #expect(!bodyXML.contains("&amp;amp;"))
    }

    /// S3's `DeleteObjects` can answer HTTP 200 with a `<DeleteResult>` body
    /// that STILL lists a per-key `<Error>` for an object it failed to
    /// delete — the same "200 lies" shape `copyObject` already guards
    /// against for CopyObject. `deleteTree` must inspect the 2xx body and
    /// throw rather than reporting a partial failure as success.
    @Test func deleteTreeThrowsWhenDeleteResultContainsAPerKeyError() async throws {
        let deleteResultWithError = """
        <?xml version="1.0" encoding="UTF-8"?>
        <DeleteResult>
            <Error>
                <Key>d/a</Key>
                <Code>InternalError</Code>
                <Message>We encountered an internal error. Please try again.</Message>
            </Error>
        </DeleteResult>
        """
        let (fs, _) = try await connect(responses: [
            (Data(directoryDListingXML.utf8), httpResponse(status: 200)),
            (Data(listingWithKeys(["d/", "d/a"]).utf8), httpResponse(status: 200)),
            (Data(deleteResultWithError.utf8), httpResponse(status: 200)),
        ])

        await expectProtocolError {
            try await fs.deleteTree(at: "/d")
        }
    }

    /// `RemoteFileSystem.deleteTree`'s contract: "A plain file behaves
    /// exactly like `delete`." The prefix walk cannot honour that — it
    /// enumerates `<key>/`, which a plain object's key never matches, so it
    /// batched zero keys and reported success having deleted nothing.
    ///
    /// The assertion is the request SHAPE, not just the count: a plain file
    /// leaves through the same single `DELETE` on its own key that `delete`
    /// sends, and no `POST ?delete` batch is issued at all.
    @Test func deleteTreeOnAPlainFileSendsOneDeleteOnItsKey() async throws {
        let (fs, transport) = try await connect(responses: [
            (Data(rootListingXML.utf8), httpResponse(status: 200)),
            (Data(), httpResponse(status: 204)),
        ])

        try await fs.deleteTree(at: "/a.txt")

        let requests = await transport.requests
        let deletes = requests.filter { $0.httpMethod == "DELETE" }
        #expect(deletes.count == 1)
        #expect(deletes.first?.url?.path(percentEncoded: true).hasSuffix("/a.txt") == true)
        #expect(!requests.contains { ($0.url?.query ?? "").contains("delete") })
    }

    // MARK: - Checksums (the ETag from the listing, read for what it is)

    /// A one-object listing whose `ETag` is exactly `etag` — written into
    /// the XML the way S3 writes it, quotes and all.
    private func listingXML(etag: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <IsTruncated>false</IsTruncated>
            <Contents>
                <Key>a.txt</Key>
                <LastModified>2024-01-02T03:04:05.000Z</LastModified>
                <ETag>\(etag)</ETag>
                <Size>12</Size>
            </Contents>
        </ListBucketResult>
        """
    }

    /// The `as?` route the surface takes, from an existential of the
    /// file-system protocol rather than from the concrete type.
    private func checksumProvider(_ fs: S3FileSystem) throws -> any RemoteChecksumProvider {
        let erased: any RemoteFileSystem = fs
        return try #require(erased as? any RemoteChecksumProvider)
    }

    /// An upload that arrived in one part: the ETag IS the object's MD5, and
    /// the value says where it came from.
    @Test func aSinglePartETagBecomesAnMD5ThatDescribesTheObject() async throws {
        let (fs, _) = try await connect(responses: [
            (Data(listingXML(etag: "&quot;598d4c200461b81522a3328565c25f7c&quot;").utf8),
             httpResponse(status: 200))
        ])

        let outcome = try await checksumProvider(fs)
            .remoteChecksum(forFileAt: "/a.txt", algorithm: .md5)

        guard case .checksum(let checksum) = outcome else {
            Issue.record("expected a checksum, got \(outcome)")
            return
        }
        #expect(checksum.algorithm == .md5)
        #expect(checksum.hex == "598d4c200461b81522a3328565c25f7c")
        #expect(checksum.provenance == .objectStorageETagSinglePart)
        #expect(checksum.describesFileContent)
    }

    /// The case a display could lie about: `<md5 of the parts' md5s>-N` is
    /// not the object's hash, and it turns up on exactly the large files
    /// somebody wants to check. The value comes out carrying that.
    @Test func aMultipartETagIsCarriedAsSomethingThatIsNotTheFilesHash() async throws {
        let (fs, _) = try await connect(responses: [
            (Data(listingXML(etag: "&quot;9bb58f26192e4ba00f01e2e7b136bbd8-3&quot;").utf8),
             httpResponse(status: 200))
        ])

        let outcome = try await checksumProvider(fs)
            .remoteChecksum(forFileAt: "/a.txt", algorithm: .md5)

        guard case .checksum(let checksum) = outcome else {
            Issue.record("expected a checksum, got \(outcome)")
            return
        }
        #expect(checksum.provenance == .objectStorageETagMultipart(partCount: 3))
        #expect(!checksum.describesFileContent)
        #expect(checksum.hex == "9bb58f26192e4ba00f01e2e7b136bbd8")
    }

    /// Some stores put arbitrary opaque text in the ETag. That is an answer
    /// that cannot be read, not a store without checksums — the same
    /// treatment SSH gives output it cannot read.
    @Test func anOpaqueETagIsAFailureRatherThanAValue() async throws {
        let (fs, _) = try await connect(responses: [
            (Data(listingXML(etag: "&quot;not-a-digest&quot;").utf8), httpResponse(status: 200))
        ])

        await #expect(throws: RemoteFSError.self) {
            _ = try await self.checksumProvider(fs)
                .remoteChecksum(forFileAt: "/a.txt", algorithm: .md5)
        }
    }

    /// An object store computes nothing on request: the only digest it has
    /// is the ETag's MD5, whatever algorithm was asked for. The answer
    /// therefore names its own algorithm, and asking for SHA-256 does not
    /// silently produce something labelled SHA-256.
    @Test func askingForSHA256StillYieldsTheETagsMD5AndSaysSo() async throws {
        let (fs, _) = try await connect(responses: [
            (Data(listingXML(etag: "&quot;598d4c200461b81522a3328565c25f7c&quot;").utf8),
             httpResponse(status: 200))
        ])

        let outcome = try await checksumProvider(fs)
            .remoteChecksum(forFileAt: "/a.txt", algorithm: .sha256)

        guard case .checksum(let checksum) = outcome else {
            Issue.record("expected a checksum, got \(outcome)")
            return
        }
        #expect(checksum.algorithm == .md5)
        #expect(checksum.provenance == .objectStorageETagSinglePart)
    }

    @Test func aKeyThatIsNotInTheListingIsNotFound() async throws {
        let (fs, _) = try await connect(responses: [
            (Data(listingXML(etag: "&quot;598d4c200461b81522a3328565c25f7c&quot;").utf8),
             httpResponse(status: 200))
        ])

        await #expect(throws: RemoteFSError.self) {
            _ = try await self.checksumProvider(fs)
                .remoteChecksum(forFileAt: "/b.txt", algorithm: .md5)
        }
    }

    /// The capability field beside the behaviour it claims: S3 can answer
    /// the checksum question, so a menu may exist for it.
    @Test func theS3CapabilityAgreesThatItCanAnswerTheChecksumQuestion() {
        #expect(BackendDescriptor.descriptor(for: .s3).capabilities.supportsRemoteChecksum)
    }

    // MARK: - The bucket list: a connection may start at it (2026-09-02)

    /// A two-bucket `ListBuckets` response, shaped the way S3 and MinIO
    /// answer `GET /`: an `<Owner>` (whose `<ID>`/`<DisplayName>` must NOT
    /// be mistaken for a bucket's `<Name>`) followed by `<Buckets>`.
    private let bucketListXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <Owner>
            <ID>02d6176db174dc93cb1b899f7c6078f08654445fe8cf1b6ce98d8855f66bdbf4</ID>
            <DisplayName>minio</DisplayName>
        </Owner>
        <Buckets>
            <Bucket>
                <Name>macscp-seed</Name>
                <CreationDate>2024-01-02T03:04:05.000Z</CreationDate>
            </Bucket>
            <Bucket>
                <Name>macscp-second</Name>
                <CreationDate>2024-02-03T04:05:06.000Z</CreationDate>
            </Bucket>
        </Buckets>
    </ListAllMyBucketsResult>
    """

    /// The key may list buckets; the account has none.
    private let emptyBucketListXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <Owner><ID>owner</ID><DisplayName>minio</DisplayName></Owner>
        <Buckets></Buckets>
    </ListAllMyBucketsResult>
    """

    /// What AWS answers a key without `s3:ListAllMyBuckets`. MinIO does NOT
    /// answer this — measured 2026-09-02, it returns the FILTERED list
    /// instead (docker/test-server/README.md), which is why this outcome is
    /// pinned here with a canned response and in the rig only as the
    /// filtered list plus a cross-bucket `AccessDenied`.
    private let accessDeniedXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Error><Code>AccessDenied</Code><Message>Access Denied.</Message></Error>
    """

    /// The same rig-shaped connection as `config`, with the toggle ON. The
    /// bucket field is empty on purpose: in this mode nothing may read it,
    /// and an empty one turns any leftover reader into a visible failure
    /// rather than a silent listing of the wrong bucket.
    private var bucketListConfig: S3ConnectionConfig {
        S3ConnectionConfig(
            accessKeyID: "AK", secretAccessKey: "SK", region: "us-east-1",
            endpoint: "http://127.0.0.1:9000", bucket: "", usePathStyle: true,
            sessionToken: nil, startsAtBucketList: true)
    }

    /// Connects with the toggle on, feeding the connect-time `ListBuckets`
    /// its own canned two-bucket answer first — the bucket-list counterpart
    /// of `connect(responses:)` above.
    private func connectAtBucketList(
        _ config: S3ConnectionConfig? = nil, responses: [(Data, HTTPURLResponse)]
    ) async throws -> (S3FileSystem, FakeS3Transport) {
        let transport = FakeS3Transport(
            responses: [(Data(bucketListXML.utf8), httpResponse(status: 200))] + responses)
        let fs = try await S3FileSystem.connect(config ?? bucketListConfig, transport: transport)
        return (fs, transport)
    }

    /// `"<bucket>|<key>"` for one resolution, so the path table below reads
    /// as a table instead of as ten destructuring statements.
    private func resolved(_ mode: S3FileSystem.RootMode, _ path: String) throws -> String {
        let (bucket, key) = try mode.resolve(path: path)
        return "\(bucket)|\(key)"
    }

    /// The path table of the design's §4, both modes, in one place.
    @Test func rootModeResolvesEveryPathToItsBucketAndKey() throws {
        // Toggle off: the bucket comes from the config, the whole path is
        // the key — byte for byte what `objectKey(forPath:)` produced.
        #expect(try resolved(.bucket("only"), "/") == "only|")
        #expect(try resolved(.bucket("only"), "/x") == "only|x")
        #expect(try resolved(.bucket("only"), "/x/y") == "only|x/y")
        #expect(try resolved(.bucket("only"), "//x//y/") == "only|x/y")

        // Toggle on: the FIRST component names the bucket.
        #expect(try resolved(.bucketList, "/b") == "b|")
        #expect(try resolved(.bucketList, "/b/") == "b|")
        #expect(try resolved(.bucketList, "/b/x/y") == "b|x/y")
        #expect(try resolved(.bucketList, "//b//x/y") == "b|x/y")
    }

    /// The one path that has no bucket to route to. It must be an ERROR —
    /// never a request against `/`, which is a different resource entirely
    /// (the account's bucket list) and would delete or overwrite something
    /// nobody named.
    @Test func aPathWithoutABucketIsAnErrorInBucketListMode() throws {
        do {
            _ = try S3FileSystem.RootMode.bucketList.resolve(path: "/")
            Issue.record("expected throw")
        } catch let error as RemoteFSError {
            guard case .protocolError = error else {
                Issue.record("expected .protocolError, got \(error)")
                return
            }
        }
    }

    /// …and the file system must not send anything when it happens.
    @Test func aBucketlessPathSendsNoRequestAtAll() async throws {
        let (fs, transport) = try await connectAtBucketList(responses: [])

        await expectProtocolError { try await fs.delete(path: "/") }

        // Only the connect-time ListBuckets, nothing after it.
        let sent = await transport.requests.count
        #expect(sent == 1)
    }

    /// Outcome 1 of the design's §2 table: 200 with buckets. `connect` asks
    /// for the ACCOUNT's buckets — `GET /` on the bare endpoint, no query,
    /// signed — instead of probing one bucket with `ListObjectsV2`.
    @Test func connectAsksForTheBucketListInsteadOfProbingOneBucket() async throws {
        let transport = FakeS3Transport(
            responses: [(Data(bucketListXML.utf8), httpResponse(status: 200))])
        let fs = try await S3FileSystem.connect(bucketListConfig, transport: transport)
        await fs.disconnect()

        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        let url = try #require(request.url)
        #expect(request.httpMethod == "GET")
        #expect(url.path == "/")
        #expect(url.query == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256") == true)
    }

    /// The positive check beside the negative ones: with the toggle OFF,
    /// connect still probes the configured bucket with `ListObjectsV2` —
    /// so "no ListObjectsV2 on connect" above is a property of the mode,
    /// not of a probe that quietly stopped happening.
    @Test func withTheToggleOffConnectStillProbesTheConfiguredBucket() async throws {
        let transport = FakeS3Transport(
            responses: [(Data(emptyListingXML.utf8), httpResponse(status: 200))])
        let fs = try await S3FileSystem.connect(config, transport: transport)
        await fs.disconnect()

        let url = try #require(await transport.requests.first?.url)
        #expect(url.path == "/macscp-seed")
        #expect((url.query ?? "").contains("list-type=2"))
    }

    /// Outcome 2: 200 with zero buckets. The key may list, the account has
    /// none — its own case, because "an empty browser" is not an answer the
    /// form can explain.
    @Test func aBucketListWithNoBucketsIsItsOwnOutcome() async throws {
        let config = bucketListConfig
        let transport = FakeS3Transport(
            responses: [(Data(emptyBucketListXML.utf8), httpResponse(status: 200))])
        await #expect(throws: RemoteFSError.bucketListEmpty) {
            _ = try await S3FileSystem.connect(config, transport: transport)
        }
    }

    /// Outcome 3: 403 `AccessDenied` on `ListBuckets` — a key without
    /// `s3:ListAllMyBuckets`, which is what AWS answers.
    @Test func aForbiddenBucketListIsItsOwnOutcome() async throws {
        let config = bucketListConfig
        let transport = FakeS3Transport(
            responses: [(Data(accessDeniedXML.utf8), httpResponse(status: 403))])
        await #expect(throws: RemoteFSError.bucketListForbidden) {
            _ = try await S3FileSystem.connect(config, transport: transport)
        }
    }

    /// Outcome 4: anything else stays what it was. A 500 on `ListBuckets`
    /// is a `protocolError`, not one of the two new cases — a provider that
    /// does not implement `ListBuckets` must not be reported as a key
    /// without the permission.
    @Test func anyOtherBucketListFailureStaysWhatItWas() async throws {
        let config = bucketListConfig
        let transport = FakeS3Transport(responses: [(Data(), httpResponse(status: 500))])
        do {
            _ = try await S3FileSystem.connect(config, transport: transport)
            Issue.record("expected throw")
        } catch let error as RemoteFSError {
            guard case .protocolError = error else {
                Issue.record("expected .protocolError, got \(error)")
                return
            }
        }
    }

    /// The root listing IS the bucket list: one directory row per bucket,
    /// carrying the creation date as `modifiedAt` and nothing else — no
    /// size, no permissions, no owner (§4).
    @Test func theRootListingIsOneDirectoryRowPerBucket() async throws {
        let (fs, _) = try await connectAtBucketList(
            responses: [(Data(bucketListXML.utf8), httpResponse(status: 200))])

        let items = try await fs.list(path: "/")

        #expect(items.count == 2)
        #expect(items.map(\.name) == ["macscp-seed", "macscp-second"])
        let seed = try #require(items.first { $0.name == "macscp-seed" })
        #expect(seed.kind == .directory)
        #expect(seed.path == "/macscp-seed")
        #expect(seed.modifiedAt != nil)
        #expect(seed.size == nil)
        #expect(seed.permissions == nil)
        #expect(seed.owner == nil)
        #expect(seed.group == nil)
    }

    /// A bucket row's path is the path that opens it: listing `/b` lists
    /// the ROOT of bucket `b`, and every item it hands back carries the
    /// bucket-qualified path — otherwise the browser's next navigation
    /// would resolve `/a.txt` against a bucket nobody chose.
    @Test func openingABucketListsItsRootAndItemsCarryTheBucketInTheirPath() async throws {
        let (fs, transport) = try await connectAtBucketList(
            responses: [(Data(rootListingXML.utf8), httpResponse(status: 200))])

        let items = try await fs.list(path: "/macscp-second")

        let url = try #require(await transport.requests.last?.url)
        #expect(url.path == "/macscp-second")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect((components.queryItems ?? []).contains(URLQueryItem(name: "prefix", value: "")))
        #expect(items.first { $0.name == "a.txt" }?.path == "/macscp-second/a.txt")
        #expect(items.first { $0.name == "sub" }?.path == "/macscp-second/sub")
    }

    /// A path deeper than the bucket splits into the bucket and the key
    /// prefix inside it.
    @Test func aDeeperPathBecomesThatBucketsKeyPrefix() async throws {
        let (fs, transport) = try await connectAtBucketList(
            responses: [(Data(emptyListingXML.utf8), httpResponse(status: 200))])

        _ = try await fs.list(path: "/macscp-second/sub")

        let url = try #require(await transport.requests.last?.url)
        #expect(url.path == "/macscp-second")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect((components.queryItems ?? []).contains(URLQueryItem(name: "prefix", value: "sub/")))
    }

    /// `stat` of a BUCKET has no parent listing to be found in — its entry
    /// exists one level up, in the bucket list itself.
    @Test func statOfABucketComesFromTheBucketList() async throws {
        let (fs, _) = try await connectAtBucketList(
            responses: [(Data(bucketListXML.utf8), httpResponse(status: 200))])

        let item = try await fs.stat(path: "/macscp-seed")

        #expect(item.kind == .directory)
        #expect(item.path == "/macscp-seed")
    }

    @Test func statOfABucketThatIsNotThereIsNotFound() async throws {
        let (fs, _) = try await connectAtBucketList(
            responses: [(Data(bucketListXML.utf8), httpResponse(status: 200))])

        await #expect(throws: RemoteFSError.notFound(path: "/nope")) {
            _ = try await fs.stat(path: "/nope")
        }
    }

    /// `stat` INSIDE a bucket lists that bucket's parent prefix, and the
    /// entry it returns carries the bucket-qualified path.
    @Test func statInsideABucketAddressesThatBucket() async throws {
        let (fs, transport) = try await connectAtBucketList(
            responses: [(Data(rootListingXML.utf8), httpResponse(status: 200))])

        let item = try await fs.stat(path: "/macscp-second/a.txt")

        #expect(item.path == "/macscp-second/a.txt")
        #expect(item.size == 12)
        let url = try #require(await transport.requests.last?.url)
        #expect(url.path == "/macscp-second")
    }

    /// A transfer routes into the bucket named by the path — the upload
    /// seam (`S3RequestBuilder.signedRequest`) resolves it too, not just
    /// the listing path.
    @Test func aWriteRoutesIntoTheBucketNamedByThePath() async throws {
        let (fs, transport) = try await connectAtBucketList(
            responses: [(Data(), httpResponse(status: 200))])
        let body = Data("hello".utf8)
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(body)
            continuation.finish()
        }

        try await fs.write(path: "/macscp-second/dir/file.txt", mode: .overwrite, contents: stream)

        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path(percentEncoded: true) == "/macscp-second/dir/file.txt")
        #expect(request.httpBody == body)
    }

    @Test func aDeleteRoutesIntoTheBucketNamedByThePath() async throws {
        let (fs, transport) = try await connectAtBucketList(responses: [
            (Data(listingWithKeys(["dir/file.txt"]).utf8), httpResponse(status: 200)),
            (Data(), httpResponse(status: 204)),
        ])

        try await fs.delete(path: "/macscp-second/dir/file.txt")

        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path(percentEncoded: true) == "/macscp-second/dir/file.txt")
    }

    @Test func aDownloadRoutesIntoTheBucketNamedByThePath() async throws {
        let (fs, transport) = try await connectAtBucketList(
            responses: [(Data("bytes".utf8), httpResponse(status: 206))])

        for try await _ in try await fs.readStream(path: "/macscp-second/a.txt", fromOffset: 0) {}

        let request = try #require(await transport.requests.last)
        #expect(request.url?.path(percentEncoded: true) == "/macscp-second/a.txt")
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-")
    }

    /// The presigned-URL seam takes a KEY, and in this mode a key is the
    /// browser path without its leading slash — so it names the bucket too.
    @Test func aPresignedURLRoutesIntoTheBucketNamedByTheKey() async throws {
        let (fs, _) = try await connectAtBucketList(responses: [])

        let url = try fs.presignedURL(
            method: .get, key: "macscp-second/dir/file.txt", expiresIn: 600)

        #expect(url.path == "/macscp-second/dir/file.txt")
    }

    /// Virtual-hosted addressing, where the trap is: `ListBuckets` is an
    /// ACCOUNT-level call and always goes to the BARE endpoint host. There
    /// is no bucket to put in front of it, and `.<host>` with an empty
    /// bucket would resolve to a different name entirely.
    @Test func virtualHostedListBucketsGoesToTheBareEndpointHost() async throws {
        let config = S3ConnectionConfig(
            accessKeyID: "AK", secretAccessKey: "SK", region: "us-east-1",
            endpoint: "http://s3.example.test", bucket: "", usePathStyle: false,
            sessionToken: nil, startsAtBucketList: true)
        let transport = FakeS3Transport(
            responses: [(Data(bucketListXML.utf8), httpResponse(status: 200))])
        let fs = try await S3FileSystem.connect(config, transport: transport)
        await fs.disconnect()

        let url = try #require(await transport.requests.first?.url)
        #expect(url.host == "s3.example.test")
        #expect(url.path == "/")
    }

    /// …and once inside a bucket, virtual-hosted addressing puts THAT
    /// bucket — the one from the path — in front of the host.
    @Test func virtualHostedListingInsideABucketUsesThatBucketsHost() async throws {
        let config = S3ConnectionConfig(
            accessKeyID: "AK", secretAccessKey: "SK", region: "us-east-1",
            endpoint: "http://s3.example.test", bucket: "", usePathStyle: false,
            sessionToken: nil, startsAtBucketList: true)
        let (fs, transport) = try await connectAtBucketList(
            config, responses: [(Data(rootListingXML.utf8), httpResponse(status: 200))])

        _ = try await fs.list(path: "/macscp-second")

        let url = try #require(await transport.requests.last?.url)
        #expect(url.host == "macscp-second.s3.example.test")
    }

    /// A bucket is a second kind of directory, and the only action the
    /// design offers on one is OPEN (§4). Core refuses the rest itself
    /// rather than trusting the browser to hide them: `rename("/b1", "/b2")`
    /// would otherwise re-key every object of one bucket into another and
    /// delete the originals, and `deleteTree("/b1")` would empty it — both
    /// from a single keystroke on a row that looks like a folder.
    @Test func aBucketItselfIsNotAThingToWriteRenameOrDelete() async throws {
        let (fs, transport) = try await connectAtBucketList(responses: [])

        await expectBucketRefusal(.delete, "/macscp-seed") {
            try await fs.delete(path: "/macscp-seed")
        }
        await expectBucketRefusal(.deleteTree, "/macscp-seed") {
            try await fs.deleteTree(at: "/macscp-seed")
        }
        await expectBucketRefusal(.createDirectory, "/macscp-seed") {
            try await fs.createDirectory(at: "/macscp-seed")
        }
        await expectBucketRefusal(.write, "/macscp-seed") {
            try await fs.write(
                path: "/macscp-seed", mode: .overwrite,
                contents: AsyncThrowingStream<Data, Error> { $0.finish() })
        }
        // Both ends of a rename, and the refusal names the END that was a
        // bucket — the source here, the DESTINATION below.
        await expectBucketRefusal(.rename, "/macscp-seed") {
            try await fs.rename(from: "/macscp-seed", to: "/macscp-third")
        }
        await expectBucketRefusal(.rename, "/macscp-third") {
            try await fs.rename(from: "/macscp-seed/a.txt", to: "/macscp-third")
        }

        // Refused BEFORE the wire, every time: only the connect-time
        // ListBuckets was ever sent.
        let sent = await transport.requests.count
        #expect(sent == 1)
    }

    /// The seam that hands write capability OUT of the process (Task 2
    /// review, I-1). `PresignedURLSheet` lets the user type the target key
    /// for a PUT, and every key ever typed there was bucket-relative — so
    /// in this mode a plain `x.txt` resolves to the bucket `x.txt` with an
    /// EMPTY key. Path-style, a presigned PUT to a bucket root is
    /// `CreateBucket`, and the URL is by design handed to a third party.
    ///
    /// Refused for `.get` too, and not only for the `CreateBucket` shape: a
    /// signed GET on a bucket root is a listing of somebody's whole bucket,
    /// handed out with the same clipboard button.
    @Test func aPresignedURLForABucketItselfIsRefusedByTheSameGuard() async throws {
        let (fs, _) = try await connectAtBucketList(responses: [])

        for method in [PresignedMethod.put, .get] {
            do {
                _ = try fs.presignedURL(method: method, key: "macscp-third", expiresIn: 600)
                Issue.record("expected throw for \(method)")
            } catch let error as RemoteFSError {
                guard case .bucketLevelRefused(let operation, let path) = error else {
                    Issue.record("expected .bucketLevelRefused for \(method), got \(error)")
                    continue
                }
                #expect(operation == .presignedURL)
                #expect(path == "/macscp-third")
            }
        }
    }

    /// The positive check beside it: one level in, the same seam still
    /// signs a URL — so the refusal above is about the bucket LEVEL and not
    /// about this mode. (`aPresignedURLRoutesIntoTheBucketNamedByTheKey`
    /// above pins the routing; this pins that the guard did not swallow it.)
    @Test func aPresignedURLOneLevelInsideABucketIsStillSigned() async throws {
        let (fs, _) = try await connectAtBucketList(responses: [])

        let url = try fs.presignedURL(method: .put, key: "macscp-third/x.txt", expiresIn: 600)

        #expect(url.path == "/macscp-third/x.txt")
    }

    /// …and with the toggle OFF the very same typed key still signs, byte
    /// for byte as before: there the key is bucket-relative by definition
    /// and names an object, not a bucket.
    @Test func withTheToggleOffAPresignedURLForATypedKeyIsUnchanged() async throws {
        let (fs, _) = try await connect(responses: [])

        let url = try fs.presignedURL(method: .put, key: "macscp-third", expiresIn: 600)

        #expect(url.path == "/macscp-seed/macscp-third")
    }

    /// The positive check beside it: one level deeper, inside the bucket,
    /// the very same operations go through — so the refusal above is a
    /// property of the bucket LEVEL, not of a mode that refuses everything.
    @Test func oneLevelInsideABucketTheSameOperationsGoThrough() async throws {
        let (fs, transport) = try await connectAtBucketList(responses: [
            (Data(listingWithKeys(["a.txt"]).utf8), httpResponse(status: 200)),
            (Data(), httpResponse(status: 204)),
        ])

        try await fs.delete(path: "/macscp-seed/a.txt")

        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path(percentEncoded: true) == "/macscp-seed/a.txt")
    }

    /// …and with the toggle OFF nothing is refused at all: `"/"` is the
    /// bucket ROOT there, where these calls have always been the caller's
    /// business, and this guard must not change that.
    ///
    /// `deleteTree` rather than `delete`, since 2026-09-04: `delete("/")`
    /// now throws `protocolError` because the root is a DIRECTORY — the
    /// `RemoteFileSystem` contract, not this guard — and "some error, but
    /// not `bucketLevelRefused`" is a negative check with nothing positive
    /// beside it. `deleteTree` at the root is precisely what the guard
    /// refuses in list mode (it empties the bucket), so a batch really
    /// going out is the positive form of the same claim.
    @Test func withTheToggleOffTheRootIsStillTheCallersBusiness() async throws {
        let (fs, transport) = try await connect(responses: [
            (Data(listingWithKeys(["a.txt"]).utf8), httpResponse(status: 200)),
            (Data("<DeleteResult></DeleteResult>".utf8), httpResponse(status: 200)),
        ])

        try await fs.deleteTree(at: "/")

        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "POST")
        // Bound to a `String` first: an optional chain feeding `??` inside
        // `#expect` makes the macro pick the `String?` overload of `??`,
        // which warns twice and leaves the `contains` result unused.
        let query = request.url?.query ?? ""
        #expect(query.contains("delete"))
        #expect(request.url?.path(percentEncoded: true) == "/macscp-seed")
    }

    // MARK: - Task 4: reads at bucket level, cross-bucket rename, error paths

    /// Task 2 review M-3, decided in Task 4: a bucket is REFUSED as a read
    /// too, not merely unreachable.
    ///
    /// `readStream("/macscp-seed")` in this mode used to resolve to bucket
    /// `macscp-seed` with an empty key and issue a ranged `GET` on the
    /// bucket ROOT, which S3 and MinIO answer with a `ListObjectsV2` XML
    /// body — so the caller received a "file" whose contents are somebody's
    /// bucket listing. Nothing in the browser or the CLI could ask for that
    /// today, but "cannot be asked for from the two front doors we know
    /// about" is an argument about callers, and this project's guard rules
    /// prefer a boundary that does not depend on one.
    @Test func aBucketIsNotAFileToDownloadEither() async throws {
        let (fs, transport) = try await connectAtBucketList(responses: [])

        await expectBucketRefusal(.readStream, "/macscp-seed") {
            _ = try await fs.readStream(path: "/macscp-seed", fromOffset: 0)
        }

        // Refused before the wire: only the connect-time ListBuckets went out.
        let sent = await transport.requests.count
        #expect(sent == 1)
    }

    /// The positive check beside it: one level in, the same call still
    /// streams — the refusal is about the bucket LEVEL, not about this mode.
    @Test func oneLevelInsideABucketADownloadStillStreams() async throws {
        let (fs, transport) = try await connectAtBucketList(responses: [
            (Data("hello".utf8), httpResponse(status: 200)),
        ])

        _ = try await fs.readStream(path: "/macscp-seed/a.txt", fromOffset: 0)

        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path(percentEncoded: true) == "/macscp-seed/a.txt")
    }

    /// …and with the toggle OFF the very same path is an OBJECT key inside
    /// the configured bucket, which has always been downloadable.
    @Test func withTheToggleOffADownloadOfTheSamePathIsUnchanged() async throws {
        let (fs, transport) = try await connect(responses: [
            (Data("hello".utf8), httpResponse(status: 200)),
        ])

        _ = try await fs.readStream(path: "/macscp-seed", fromOffset: 0)

        let request = try #require(await transport.requests.last)
        #expect(request.url?.path(percentEncoded: true) == "/macscp-seed/macscp-seed")
    }

    /// Task 2 review (b), decided in Task 4: a rename never spans two
    /// buckets.
    ///
    /// `rename` is a copy+delete per object with no rollback — documented
    /// and accepted INSIDE one bucket, where a half-failure leaves the
    /// objects in one place the user can see. Across buckets the same
    /// half-failure splits them over a permission boundary (and possibly two
    /// regions), which is a behaviour nobody has designed. Refused until
    /// someone does.
    @Test func aRenameNeverCrossesFromOneBucketIntoAnother() async throws {
        let (fs, transport) = try await connectAtBucketList(responses: [])

        var thrown: (any Error)?
        do {
            try await fs.rename(from: "/macscp-seed/a.txt", to: "/macscp-second/a.txt")
        } catch {
            thrown = error
        }

        // No early `return` on a wrong case: that would skip the request
        // count below, which is the half that proves the refusal happened
        // BEFORE the destination pre-check went out.
        if case .crossBucketRenameRefused(let from, let to)? = thrown as? RemoteFSError {
            #expect(from == "/macscp-seed/a.txt")
            #expect(to == "/macscp-second/a.txt")
        } else {
            Issue.record("expected .crossBucketRenameRefused, got \(String(describing: thrown))")
        }

        // Refused before the destination pre-check, so nothing was sent.
        let sent = await transport.requests.count
        #expect(sent == 1)
    }

    /// The positive check beside it: inside ONE bucket the same rename
    /// still runs — it reaches the destination pre-check (`stat`), which is
    /// the first thing on the wire.
    @Test func aRenameInsideOneBucketStillRuns() async throws {
        let (fs, transport) = try await connectAtBucketList(responses: [
            (Data(rootListingXML.utf8), httpResponse(status: 200)),
        ])

        do {
            // `a.txt` IS in the canned listing, so the destination pre-check
            // reports it taken — which is proof the call got that far, past
            // the cross-bucket guard and onto the wire.
            try await fs.rename(from: "/macscp-seed/b.txt", to: "/macscp-seed/a.txt")
            Issue.record("expected throw")
        } catch let error as RemoteFSError {
            guard case .protocolError(let reason) = error else {
                Issue.record("expected .protocolError, got \(error)")
                return
            }
            #expect(reason.hasPrefix("Destination already exists"))
        }

        let sent = await transport.requests.count
        #expect(sent == 2)
    }

    /// Task 2 review M-2: an error raised in list mode names a path the
    /// browser can recognize — `"/<bucket>/<key>"`, not the bucket-relative
    /// `"/<key>"` that names a real object in some OTHER bucket.
    @Test func anErrorInListModeNamesThePathWithItsBucket() async throws {
        let (fs, _) = try await connectAtBucketList(responses: [
            (Data(listingWithKeys(["dir/file.txt"]).utf8), httpResponse(status: 200)),
            (Data(), httpResponse(status: 404)),
        ])

        do {
            try await fs.delete(path: "/macscp-second/dir/file.txt")
            Issue.record("expected throw")
        } catch let error as RemoteFSError {
            guard case .notFound(let path) = error else {
                Issue.record("expected .notFound, got \(error)")
                return
            }
            #expect(path == "/macscp-second/dir/file.txt")
        }
    }

    /// The positive check beside it: with the toggle OFF the reported path
    /// is unchanged, because there the browser path and the key really are
    /// the same string.
    @Test func withTheToggleOffAnErrorNamesTheSamePathAsBefore() async throws {
        let (fs, _) = try await connect(responses: [
            (Data(listingWithKeys(["dir/file.txt"]).utf8), httpResponse(status: 200)),
            (Data(), httpResponse(status: 404)),
        ])

        do {
            try await fs.delete(path: "/dir/file.txt")
            Issue.record("expected throw")
        } catch let error as RemoteFSError {
            guard case .notFound(let path) = error else {
                Issue.record("expected .notFound, got \(error)")
                return
            }
            #expect(path == "/dir/file.txt")
        }
    }
}
