import Foundation
import Testing
@testable import macSCPCore

/// `S3FileSystem.readStream(ofKey:inBucket:versionId:)`: the request it signs
/// and the contract it shares with the plain reader, against the canned
/// transport. No network; the rig half is a later task's.
///
/// The plain reader's own contract (the `Content-Range` check, 416, the
/// status mapping) is pinned by `S3FileSystemTests`, which this task leaves
/// unedited. What is pinned HERE is what is particular to a version read: the
/// `versionId` query and how it is encoded, the object path a failure names,
/// the refusal of an empty key, and that the status mapping is the same one
/// (one helper carries both entry points, so the cases below are the
/// evidence that the second entry point reaches it).
@Suite("S3FileSystem version read", .timeLimit(.minutes(5)))
struct S3VersionReadTests {
    private static func response(status: Int) -> HTTPURLResponse {
        S3SettingsFake.httpResponse(status: status)
    }

    private static func read(
        _ fs: S3FileSystem, key: String = "doc.txt", bucket: String = "b", versionId: String = "v1"
    ) async throws -> Data {
        var received = Data()
        for try await chunk in try await fs.readStream(ofKey: key, inBucket: bucket, versionId: versionId) {
            received.append(chunk)
        }
        return received
    }

    /// What `RemoteFSError` the read ends in, or `nil` when it ended without
    /// one. A function and not `#expect(throws:)` so a case can assert the
    /// full value (`notFound` carries its path).
    private static func failure(
        of fs: S3FileSystem, key: String = "doc.txt", bucket: String = "b", versionId: String = "v1"
    ) async -> RemoteFSError? {
        do {
            _ = try await read(fs, key: key, bucket: bucket, versionId: versionId)
            return nil
        } catch {
            return error as? RemoteFSError
        }
    }

    // MARK: - The request

    @Test func aVersionReadIsASignedGetThatNamesTheVersion() async throws {
        let body = Data((0..<(TransferChunk.size + 10)).map { UInt8($0 & 0xFF) })
        let (fs, transport) = try await S3SettingsFake.connect(
            responses: [(body, Self.response(status: 200))])

        #expect(try await Self.read(fs, key: "dir/doc.txt", bucket: "other", versionId: "v1") == body)

        let sent = try #require(await transport.requests.last)
        #expect(sent.httpMethod == "GET")
        let url = try #require(sent.url)
        // Path-style, the bucket the CALL named (not the connection's own),
        // and the version as the only query item.
        #expect(url.path == "/other/dir/doc.txt")
        #expect(url.query == "versionId=v1")
        // A signed request, and `Range` left out of the signed set exactly as
        // the plain reader leaves it (its own regression guard).
        let authorization = sent.value(forHTTPHeaderField: "Authorization") ?? ""
        #expect(authorization.contains("AWS4-HMAC-SHA256"))
        #expect(authorization.contains("range") == false)
        #expect(sent.value(forHTTPHeaderField: "Range") == "bytes=0-")
    }

    /// The id travels raw into `SigV4Signer.canonicalQueryString`, which
    /// encodes name and value once. An id that arrived pre-encoded would be
    /// encoded twice: the store would be asked for a version that does not
    /// exist. Both ids below are the characters an encoder can get wrong.
    @Test func aVersionIdIsEncodedOnceOnTheWire() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            (Data(), Self.response(status: 200)), (Data(), Self.response(status: 200)),
        ])
        _ = try await Self.read(fs, versionId: S3ObjectVersionsTests.tokenVersionIdMarker)
        // An id that already LOOKS encoded is raw text to this layer, so its
        // percent sign is escaped like any other byte.
        _ = try await Self.read(fs, versionId: "a%2Fb")

        let sent = await transport.requests.dropFirst()
        let queries = sent.map { $0.url?.query }
        #expect(queries == [
            "versionId=" + S3ObjectVersionsTests.tokenVersionIdMarkerOnTheWire,
            "versionId=a%252Fb",
        ])
    }

    @Test func aVersionReadYieldsTheBodyInChunks() async throws {
        let body = Data((0..<(TransferChunk.size * 2 + 7)).map { UInt8($0 & 0xFF) })
        let (fs, _) = try await S3SettingsFake.connect(responses: [(body, Self.response(status: 200))])
        var chunks: [Data] = []
        for try await chunk in try await fs.readStream(ofKey: "doc.txt", inBucket: "b", versionId: "v1") {
            chunks.append(chunk)
        }
        #expect(chunks.count == 3)
        #expect(chunks.reduce(Data(), +) == body)
    }

    // MARK: - The contract it shares with the plain reader

    /// `RemoteFileSystem`'s contract: a range request at or beyond the end is
    /// an empty stream, not an error. For a version it is the empty object's
    /// read, which is a real shape.
    @Test func aVersionOfAnEmptyObjectReadsAsAnEmptyStream() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [(Data(), Self.response(status: 416))])
        #expect(try await Self.read(fs).isEmpty)
    }

    @Test func theStatusMappingIsThePlainReaders() async throws {
        let cases: [(Int, RemoteFSError)] = [
            (404, .notFound(path: "/b/doc.txt")),
            (403, .authenticationFailed),
            (500, .finding(.unexpectedStatus(code: 500))),
        ]
        for (status, expected) in cases {
            let (fs, _) = try await S3SettingsFake.connect(responses: [(Data(), Self.response(status: status))])
            #expect(await Self.failure(of: fs) == expected, "status \(status)")
        }
        // The positive beside the three: the same call with a 200 does not
        // throw, so the failures above come from the status.
        let (ok, _) = try await S3SettingsFake.connect(responses: [(Data("x".utf8), Self.response(status: 200))])
        #expect(await Self.failure(of: ok) == nil)
    }

    /// The 404 names the bucket and key the CALLER passed, whichever bucket
    /// the connection was opened on (`objectLockPath`, as the write half does).
    @Test func aMissingVersionNamesTheBucketAndKeyThatWereAsked() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [(Data(), Self.response(status: 404))])
        #expect(
            await Self.failure(of: fs, key: "dir/doc.txt", bucket: "elsewhere")
                == .notFound(path: "/elsewhere/dir/doc.txt"))
    }

    /// A 206 is a legitimate answer to the `Range: bytes=0-` the read sends.
    @Test func aPartialContentAnswerIsAccepted() async throws {
        let body = Data("hello".utf8)
        let (fs, _) = try await S3SettingsFake.connect(responses: [
            (body, HTTPURLResponse(
                url: URL(string: "http://127.0.0.1:9000/other")!, statusCode: 206,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Range": "bytes 0-4/5"])!),
        ])
        #expect(try await Self.read(fs) == body)
    }

    /// The body's failures land long after the call returned, and are wrapped
    /// the way every other S3 transport error is (a raw error would print the
    /// failing URL). The shared helper's `wrappingTransportErrors`.
    @Test func aBodyThatFailsMidStreamIsReportedAsAConnectionFailure() async throws {
        let transport = StreamBreakingTransport()
        let fs = try await S3FileSystem.connect(S3SettingsFake.config, transport: transport)
        var received = Data()
        do {
            for try await chunk in try await fs.readStream(ofKey: "doc.txt", inBucket: "b", versionId: "v1") {
                received.append(chunk)
            }
            Issue.record("the broken body ended without an error")
        } catch {
            guard case RemoteFSError.connectionFailed = error else {
                Issue.record("the failure was not a connectionFailed")
                return
            }
        }
        #expect(received == Data("first".utf8))
    }

    // MARK: - An empty key

    /// An empty key addresses the bucket, and a `GET` of the bucket root is a
    /// listing, not a read: refused before a request is built, like the write
    /// half. The request count is the evidence nothing was sent.
    @Test func anEmptyKeyIsRefusedBeforeAnythingIsSent() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            (Data(S3SettingsFake.emptyListingXML.utf8), Self.response(status: 200)),
        ])
        let failure = await Self.failure(of: fs, key: "")
        #expect(failure == .protocolError(reason: S3FileSystem.versionReadKeyRequiredReason))
        #expect(await transport.requests.count == 1)  // `connect`'s probe, nothing else
        // The positive beside it: a non-empty key sends one more.
        _ = await Self.failure(of: fs, key: "doc.txt")
        #expect(await transport.requests.count == 2)
    }
}

/// Answers the connection probe, then a read whose body yields one chunk and
/// breaks with the raw error `URLSession` would end a lost connection with.
private struct StreamBreakingTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(S3SettingsFake.emptyListingXML.utf8), S3SettingsFake.httpResponse(status: 200))
    }

    func sendStreaming(_ request: URLRequest) async throws
        -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse) {
        let body = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("first".utf8))
            continuation.finish(throwing: URLError(.networkConnectionLost))
        }
        return (body, S3SettingsFake.httpResponse(status: 200))
    }
}
