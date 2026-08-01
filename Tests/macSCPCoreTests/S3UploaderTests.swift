import Crypto
import Foundation
import Testing
@testable import macSCPCore

/// Records every `signedRequest`/`perform` call and returns canned `perform`
/// responses in order — the `S3Uploader` analogue of `FakeS3Transport`
/// (`S3FileSystemTests.swift`). `S3RequestBuilder.signedRequest` is a
/// synchronous (non-`async`) requirement, so this is a lock-guarded
/// `@unchecked Sendable` class rather than an actor (an actor's stored
/// properties can only be touched from `async`-isolated context, which a
/// synchronous protocol requirement can't satisfy) — same pattern as
/// `ProgressRecorder` in `PermissionsTreeApplierTests.swift`.
final class FakeRequestBuilder: S3RequestBuilder, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Data, HTTPURLResponse)]
    private var _performed: [URLRequest] = []
    private var _lastPayloadHash: String?

    init(responses: [(Data, HTTPURLResponse)]) {
        self.responses = responses
    }

    var performed: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _performed
    }

    var lastPayloadHash: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastPayloadHash
    }

    func signedRequest(
        method: String, key: String, query: [(name: String, value: String)],
        extraHeaders: [String: String], body: Data?, payloadHash: String
    ) throws -> URLRequest {
        lock.lock()
        _lastPayloadHash = payloadHash
        lock.unlock()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:9000/bucket/\(key)")!)
        request.httpMethod = method
        request.httpBody = body
        return request
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        _performed.append(request)
        guard !responses.isEmpty else {
            lock.unlock()
            throw RemoteFSError.protocolError(reason: "FakeRequestBuilder ran out of canned responses")
        }
        let next = responses.removeFirst()
        lock.unlock()
        return next
    }
}

@Suite("S3Uploader")
struct S3UploaderTests {
    private func http(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:9000/bucket/key")!,
            statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
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

    /// A stream that exceeds `singlePutThreshold` before ending must throw —
    /// multipart upload lands in M13/T6, not here.
    @Test func aboveThresholdStreamThrowsProtocolError() async throws {
        let bigChunk = Data(repeating: 0x00, count: S3Uploader.singlePutThreshold + 1)
        let builder = FakeRequestBuilder(responses: [(Data(), http(200))])
        let uploader = S3Uploader()

        do {
            try await uploader.upload(key: "big.bin", contents: stream(of: [bigChunk]), using: builder)
            Issue.record("expected throw")
        } catch let error as RemoteFSError {
            guard case .protocolError = error else {
                Issue.record("expected .protocolError, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }

        // Must not have sent anything to the network — the threshold check
        // happens before any request is built.
        let performed = builder.performed
        #expect(performed.isEmpty)
    }
}
