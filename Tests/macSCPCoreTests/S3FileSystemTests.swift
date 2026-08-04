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

    @Test func deleteSendsDeleteForTheObjectKey() async throws {
        let (fs, transport) = try await connect(responses: [(Data(), httpResponse(status: 204))])
        try await fs.delete(path: "/dir/file.txt")
        let req = await transport.requests.last!
        #expect(req.httpMethod == "DELETE")
        #expect(req.url!.path.hasSuffix("/dir/file.txt"))
    }

    @Test func deleteNotFoundResponseThrowsNotFound() async throws {
        let (fs, _) = try await connect(responses: [(Data(), httpResponse(status: 404))])
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

    /// `deleteTree` lists every key under the prefix (including the
    /// directory's own trailing-slash marker) via `allObjectKeys`, then
    /// issues ONE signed `POST {bucket}?delete` per <=1000-key batch with a
    /// `Content-MD5` header (S3 requires it for this call) and an XML body
    /// naming every key in the batch.
    @Test func deleteTreeBatchesDeleteObjectsWithContentMD5() async throws {
        let (fs, transport) = try await connect(responses: [
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
            (Data(listingWithKeys(["d/", "d/a"]).utf8), httpResponse(status: 200)),
            (Data(deleteResultWithError.utf8), httpResponse(status: 200)),
        ])

        await expectProtocolError {
            try await fs.deleteTree(at: "/d")
        }
    }
}
