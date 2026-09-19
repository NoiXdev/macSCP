import Crypto
import Foundation
import Synchronization
import Testing
@testable import macSCPCore

/// Records every `signedRequest`/`perform` call and returns canned `perform`
/// responses in order — the `S3Uploader` analogue of `FakeS3Transport`
/// (`S3FileSystemTests.swift`). `S3RequestBuilder.signedRequest` is a
/// synchronous (non-`async`) requirement, so this cannot be an actor: an
/// actor's stored properties are only reachable from isolated context, and a
/// synchronous requirement has none. The recorded state therefore lives in a
/// `Mutex`, which makes the `Sendable` conformance a checked one — every
/// access goes through `withLock`, and the type has no mutable stored
/// property outside it.
final class FakeRequestBuilder: S3RequestBuilder, Sendable {
    private struct State {
        var responses: [(Data, HTTPURLResponse)]
        var performed: [URLRequest] = []
        var lastPayloadHash: String?
    }

    private let state: Mutex<State>

    init(responses: [(Data, HTTPURLResponse)]) {
        state = Mutex(State(responses: responses))
    }

    var performed: [URLRequest] {
        state.withLock { $0.performed }
    }

    var lastPayloadHash: String? {
        state.withLock { $0.lastPayloadHash }
    }

    func signedRequest(
        method: String, key: String, query: [(name: String, value: String)],
        extraHeaders: [String: String], body: Data?, payloadHash: String
    ) throws -> URLRequest {
        state.withLock { $0.lastPayloadHash = payloadHash }
        var components = URLComponents(string: "http://127.0.0.1:9000/bucket/\(key)")!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.name, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        return request
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try state.withLock {
            $0.performed.append(request)
            guard !$0.responses.isEmpty else {
                throw RemoteFSError.protocolError(reason: "FakeRequestBuilder ran out of canned responses")
            }
            return $0.responses.removeFirst()
        }
    }
}

/// A request builder that refuses any request made from a cancelled task —
/// the way a `URLSession` request is documented to throw once its task is
/// cancelled — and counts the refusals. Its first stream element arrives at
/// once; its second parks until the task reading it is cancelled.
final class CancellationRefusingBuilder: S3RequestBuilder, Sendable {
    private struct State {
        var responses: [(Data, HTTPURLResponse)]
        var performed: [URLRequest] = []
        var refusedFromACancelledTask = 0
    }

    private let state: Mutex<State>

    init(responses: [(Data, HTTPURLResponse)]) {
        state = Mutex(State(responses: responses))
    }

    var performed: [URLRequest] { state.withLock { $0.performed } }
    var refusedFromACancelledTask: Int { state.withLock { $0.refusedFromACancelledTask } }

    func signedRequest(
        method: String, key: String, query: [(name: String, value: String)],
        extraHeaders: [String: String], body: Data?, payloadHash: String
    ) throws -> URLRequest {
        var components = URLComponents(string: "http://127.0.0.1:9000/bucket/\(key)")!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.name, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        return request
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let cancelled = Task.isCancelled
        return try state.withLock {
            if cancelled {
                $0.refusedFromACancelledTask += 1
                throw CancellationError()
            }
            $0.performed.append(request)
            guard !$0.responses.isEmpty else {
                throw RemoteFSError.protocolError(reason: "out of canned responses")
            }
            return $0.responses.removeFirst()
        }
    }

    /// Just over the single-PUT threshold, so the upload goes multipart and
    /// sends its first part; then a park until the reader is cancelled.
    static func parkingStream(reached: AsyncSignal) -> AsyncThrowingStream<Data, Error> {
        let pulls = Mutex(0)
        return AsyncThrowingStream(unfolding: {
            let pull = pulls.withLock { value -> Int in
                defer { value += 1 }
                return value
            }
            if pull == 0 { return Data(count: S3Uploader.singlePutThreshold + 1) }
            reached.signal()
            _ = await AsyncSignal().wait()
            throw CancellationError()
        })
    }
}

@Suite("S3Uploader")
struct S3UploaderTests {
    // MARK: - The abort survives a cancel (Task 2 fix round 1, I3)

    /// Cancelled mid-multipart: the abort is SENT — from a task the
    /// cancellation does not reach, so a transport that refuses a cancelled
    /// caller still carries it — and the cancellation is what the caller
    /// sees. Red while the abort ran in the cancelled task: the builder
    /// refused it, and the `try?` swallowed that.
    @Test func aCancelledMultipartUploadIsAbortedOutsideTheCancelledTask() async throws {
        let builder = CancellationRefusingBuilder(responses: [
            (Data(initiateXML(uploadID: "UP3").utf8), http(200)),
            (Data(), http(200, etag: "\"etag-1\"")),
            (Data(), http(204)),
        ])
        let reached = AsyncSignal()

        let run = Task {
            try await S3Uploader().upload(
                key: "big.bin", contents: CancellationRefusingBuilder.parkingStream(reached: reached),
                using: builder)
        }
        #expect(await reached.wait() == .signalled)
        run.cancel()
        let result = await finishingResult(run)

        let aborted = builder.performed.contains {
            $0.httpMethod == "DELETE" && ($0.url!.query ?? "").contains("uploadId=UP3")
        }
        #expect(aborted, "no abort reached the server: \(builder.performed.map(\.httpMethod))")
        #expect(builder.refusedFromACancelledTask == 0)
        guard case .failure(let error) = result else {
            Issue.record("a cancelled upload succeeded")
            return
        }
        #expect(error is CancellationError, "\(error)")
    }

    /// The abort was sent and the server did not confirm it: the uploader
    /// says an incomplete upload may remain, carrying what ended the upload.
    @Test func anAbortThatIsNotConfirmedIsReported() async throws {
        let builder = CancellationRefusingBuilder(responses: [
            (Data(initiateXML(uploadID: "UP4").utf8), http(200)),
            (Data(), http(200, etag: "\"etag-1\"")),
            (Data(), http(500)),
        ])
        let reached = AsyncSignal()

        let run = Task {
            try await S3Uploader().upload(
                key: "big.bin", contents: CancellationRefusingBuilder.parkingStream(reached: reached),
                using: builder)
        }
        #expect(await reached.wait() == .signalled)
        run.cancel()
        let result = await finishingResult(run)

        guard case .failure(let error) = result,
            let unconfirmed = error as? S3MultipartAbortUnconfirmed
        else {
            Issue.record("expected S3MultipartAbortUnconfirmed, got \(result)")
            return
        }
        #expect(unconfirmed.key == "big.bin")
        #expect(unconfirmed.underlying is CancellationError)
    }

    /// And a confirmed abort after a plain failure reports nothing more than
    /// the failure — the positive half of the case above.
    @Test func aConfirmedAbortThrowsTheOriginalError() async throws {
        let chunks = Array(repeating: Data(repeating: 1, count: 64 * 1024), count: 160)
        let builder = FakeRequestBuilder(responses: [
            (Data(initiateXML(uploadID: "UP5").utf8), http(200)),
            (Data(), http(403)),
            (Data(), http(204)),
        ])
        await #expect(throws: RemoteFSError.authenticationFailed) {
            try await S3Uploader().upload(key: "big.bin", contents: stream(of: chunks), using: builder)
        }
    }

    private func http(_ status: Int, etag: String? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:9000/bucket/key")!,
            statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: etag.map { ["ETag": $0] })!
    }

    /// A minimal `InitiateMultipartUploadResult` XML body carrying `uploadID`
    /// — the multipart handshake's only piece `S3Uploader` reads.
    private func initiateXML(uploadID: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
            "<InitiateMultipartUploadResult><UploadId>\(uploadID)</UploadId></InitiateMultipartUploadResult>"
    }

    private func stream(of chunks: [Data]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func smallUploadIsASinglePut() async throws {
        let body = Data(repeating: 0x42, count: 1024)
        let builder = FakeRequestBuilder(responses: [(Data(), http(200))])
        let uploader = S3Uploader()

        try await uploader.upload(key: "dir/small.bin", contents: stream(of: [body]), using: builder)

        let performed = builder.performed
        #expect(performed.count == 1)
        let req = performed[0]
        #expect(req.httpMethod == "PUT")
        #expect(req.httpBody == body)
        // payloadHash was the real sha256 of the body (not UNSIGNED-PAYLOAD).
        let lastPayloadHash = builder.lastPayloadHash
        #expect(lastPayloadHash == sha256Hex(body))
    }

    /// A stream split across several chunks must still be concatenated into
    /// ONE PUT body — the whole point of buffering below the threshold.
    @Test func multipleChunksAreConcatenatedIntoOnePutBody() async throws {
        let chunks = [Data(repeating: 0x01, count: 100), Data(repeating: 0x02, count: 200)]
        let builder = FakeRequestBuilder(responses: [(Data(), http(200))])
        let uploader = S3Uploader()

        try await uploader.upload(key: "a.bin", contents: stream(of: chunks), using: builder)

        let performed = builder.performed
        #expect(performed.count == 1)
        #expect(performed[0].httpBody == chunks[0] + chunks[1])
    }

    /// A non-2xx `perform` response must be mapped through the same
    /// status→`RemoteFSError` rules the rest of `S3FileSystem` uses (403 →
    /// `.authenticationFailed`).
    @Test func nonSuccessResponseThrowsTheMappedError() async throws {
        let builder = FakeRequestBuilder(responses: [(Data(), http(403))])
        let uploader = S3Uploader()

        await #expect(throws: RemoteFSError.authenticationFailed) {
            try await uploader.upload(key: "dir/small.bin", contents: stream(of: [Data([0x01])]), using: builder)
        }
    }

    @Test func nonSuccessResponseMapsNotFoundStatus() async throws {
        let builder = FakeRequestBuilder(responses: [(Data(), http(404))])
        let uploader = S3Uploader()

        do {
            try await uploader.upload(key: "dir/small.bin", contents: stream(of: [Data([0x01])]), using: builder)
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

    /// An empty stream (0-byte object) is still valid: it ends at or below
    /// the threshold, so it goes out as one PUT of an empty body.
    @Test func emptyStreamIsASinglePutOfAnEmptyBody() async throws {
        let builder = FakeRequestBuilder(responses: [(Data(), http(200))])
        let uploader = S3Uploader()

        try await uploader.upload(key: "empty.bin", contents: stream(of: []), using: builder)

        let performed = builder.performed
        #expect(performed.count == 1)
        #expect(performed[0].httpBody == Data())
        let lastPayloadHash = builder.lastPayloadHash
        #expect(lastPayloadHash == sha256Hex(Data()))
    }

    /// A stream that exceeds `singlePutThreshold` before ending switches to
    /// the multipart path (M13/T6): Initiate → several UploadParts → Complete.
    @Test func largeUploadUsesMultipartWithParts() async throws {
        // 20 MiB in 64 KiB chunks → >8 MiB threshold → multipart, parts >=5 MiB.
        let chunks = Array(repeating: Data(repeating: 0x7, count: 64 * 1024), count: 320)
        let builder = FakeRequestBuilder(responses: [
            (Data(initiateXML(uploadID: "UP1").utf8), http(200)),  // Initiate
            (Data(), http(200, etag: "\"etag-1\"")),  // UploadPart 1
            (Data(), http(200, etag: "\"etag-2\"")),  // UploadPart 2
            (Data(), http(200, etag: "\"etag-3\"")),  // UploadPart 3
            (Data(), http(200)),  // Complete
        ])
        try await S3Uploader().upload(key: "big.bin", contents: stream(of: chunks), using: builder)
        let methods = builder.performed.map { ($0.httpMethod!, $0.url!.query ?? "") }
        #expect(methods.first!.1.contains("uploads"))  // Initiate POST ?uploads
        #expect(methods.contains { $0.1.contains("partNumber=1") && $0.1.contains("uploadId=UP1") })
        #expect(methods.last!.1.contains("uploadId=UP1"))  // Complete POST ?uploadId
        // Complete body lists the collected ETags in part order:
        #expect(String(data: builder.performed.last!.httpBody!, encoding: .utf8)!.contains("etag-1"))
    }

    /// A part upload failure must abort the multipart upload — never leave
    /// an orphaned upload sitting on the server.
    @Test func multipartAbortsOnPartFailure() async throws {
        let chunks = Array(repeating: Data(repeating: 1, count: 64 * 1024), count: 320)
        let builder = FakeRequestBuilder(responses: [
            (Data(initiateXML(uploadID: "UP2").utf8), http(200)),  // Initiate
            (Data(), http(500)),  // UploadPart 1 fails
        ])
        await #expect(throws: (any Error).self) {
            try await S3Uploader().upload(key: "big.bin", contents: stream(of: chunks), using: builder)
        }
        // An Abort (DELETE ?uploadId) must have been issued:
        #expect(builder.performed.contains { $0.httpMethod == "DELETE" && ($0.url!.query ?? "").contains("uploadId=UP2") })
    }
}
