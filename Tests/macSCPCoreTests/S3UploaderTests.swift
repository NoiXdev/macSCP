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

    func abortChannel() -> any S3AbortChannel { ThroughTheBuilder(builder: self) }
}

/// An abort channel that sends through its builder's own `perform`, for the
/// fakes here, which have no connection a disconnect could end — which
/// channel an abort takes is `S3AbortOutlivesDisconnectTests`' subject.
struct ThroughTheBuilder: S3AbortChannel {
    let builder: any S3RequestBuilder

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await builder.perform(request)
    }

    func finish() {}
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

    func abortChannel() -> any S3AbortChannel { ThroughTheBuilder(builder: self) }

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

/// Collects the object keys `S3Uploader` notes.
final class AbortNotes: Sendable {
    private let state = Mutex<[String]>([])
    var keys: [String] { state.withLock { $0 } }
    var record: @Sendable (String) -> Void { { [self] key in state.withLock { $0.append(key) } } }
}

/// Initiates, fails the first part, and holds the abort until the case
/// releases it — an endpoint that stopped answering.
final class SilentAbortBuilder: S3RequestBuilder, Sendable {
    private let answered = Mutex(false)
    private let uploadID: String
    let abortArrived = AsyncSignal()
    let release = AsyncSignal()

    init(uploadID: String) { self.uploadID = uploadID }

    var abortAnswered: Bool { answered.withLock { $0 } }

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
        let query = request.url?.query ?? ""
        let response = { (status: Int) in
            HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: nil)!
        }
        switch request.httpMethod {
        case "POST" where query.contains("uploads"):
            let body = "<InitiateMultipartUploadResult><UploadId>\(uploadID)</UploadId>"
                + "</InitiateMultipartUploadResult>"
            return (Data(body.utf8), response(200))
        case "DELETE":
            abortArrived.signal()
            guard await release.wait() == .signalled else { throw CancellationError() }
            answered.withLock { $0 = true }
            return (Data(), response(204))
        default:
            return (Data(), response(500))
        }
    }

    func abortChannel() -> any S3AbortChannel { ThroughTheBuilder(builder: self) }
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
            try await S3Uploader(noteUnconfirmedAbort: { _ in }, abortBound: Self.roomyAbortBound)
                .upload(
                    key: "big.bin",
                    contents: CancellationRefusingBuilder.parkingStream(reached: reached),
                    using: builder)
        }
        #expect(await reached.wait() == .signalled)
        run.cancel()
        let result = await finishingResult(run)

        guard case .failure(let error) = result,
            let aborting = error as? S3MultipartAbortInFlight
        else {
            Issue.record("expected S3MultipartAbortInFlight, got \(result)")
            return
        }
        #expect(aborting.underlying is CancellationError, "\(aborting.underlying)")
        #expect(await aborting.confirmation.value, "the abort was not confirmed")
        let aborted = builder.performed.contains {
            $0.httpMethod == "DELETE" && ($0.url!.query ?? "").contains("uploadId=UP3")
        }
        #expect(aborted, "no abort reached the server: \(builder.performed.map(\.httpMethod))")
        #expect(builder.refusedFromACancelledTask == 0)
    }

    /// The abort was sent and the server did not confirm it: the abort's
    /// confirmation says so, the note names the object key, and the error
    /// carries what ended the upload.
    @Test func anAbortThatIsNotConfirmedIsReportedAndNoted() async throws {
        let builder = CancellationRefusingBuilder(responses: [
            (Data(initiateXML(uploadID: "UP4").utf8), http(200)),
            (Data(), http(200, etag: "\"etag-1\"")),
            (Data(), http(500)),
        ])
        let reached = AsyncSignal()

        let notes = AbortNotes()
        let run = Task {
            try await S3Uploader(noteUnconfirmedAbort: notes.record, abortBound: Self.roomyAbortBound)
                .upload(
                    key: "big.bin",
                    contents: CancellationRefusingBuilder.parkingStream(reached: reached),
                    using: builder)
        }
        #expect(await reached.wait() == .signalled)
        run.cancel()
        let result = await finishingResult(run)

        guard case .failure(let error) = result,
            let aborting = error as? S3MultipartAbortInFlight
        else {
            Issue.record("expected S3MultipartAbortInFlight, got \(result)")
            return
        }
        #expect(aborting.key == "big.bin")
        #expect(aborting.underlying is CancellationError)
        #expect(await aborting.confirmation.value == false)
        #expect(notes.keys == ["big.bin"])
    }

    /// And a confirmed abort after a plain failure carries the failure, is
    /// confirmed, and notes nothing — the positive half of the case above.
    @Test func aConfirmedAbortCarriesTheOriginalErrorAndNotesNothing() async throws {
        let chunks = Array(repeating: Data(repeating: 1, count: 64 * 1024), count: 160)
        let builder = FakeRequestBuilder(responses: [
            (Data(initiateXML(uploadID: "UP5").utf8), http(200)),
            (Data(), http(403)),
            (Data(), http(204)),
        ])
        let notes = AbortNotes()
        do {
            try await S3Uploader(noteUnconfirmedAbort: notes.record, abortBound: Self.roomyAbortBound)
                .upload(key: "big.bin", contents: stream(of: chunks), using: builder)
            Issue.record("expected a throw")
        } catch let aborting as S3MultipartAbortInFlight {
            #expect(aborting.underlying as? RemoteFSError == .authenticationFailed)
            #expect(await aborting.confirmation.value)
            #expect(notes.keys.isEmpty)
        }
    }

    /// The upload throws while its abort is still unanswered: nothing that
    /// cancelled the upload waits on the abort — a queue's `cancelAll`
    /// awaits the upload's task, and must not be held by an endpoint that
    /// stopped answering (Task 2 fix round 2 of the 2026-09-19 plan, N1).
    /// The abort answers only when the case releases it, so the ordering is
    /// fixed without a clock.
    ///
    /// An upload that waited for its abort would never throw here: the
    /// bound is one no runner reaches, and the abort is released only after
    /// the throw. The upload runs through `returnedOrCancelled`, so the time
    /// limit ends that wait as `.cancelled` — a plain `await` would hold the
    /// run until the bound. It used to be caught by an "abandoned" flag
    /// instead, which the 30 s production bound could raise only after
    /// 30 s — a wall-clock ceiling (final review M8 of the 2026-09-19 plan).
    @Test(.timeLimit(.minutes(2))) func theUploadThrowsBeforeItsAbortIsAnswered() async throws {
        let contents = stream(of: Array(repeating: Data(repeating: 1, count: 64 * 1024), count: 160))
        let builder = SilentAbortBuilder(uploadID: "UP6")
        let uploader = S3Uploader(noteUnconfirmedAbort: { _ in }, abortBound: Self.roomyAbortBound)

        let upload = await returnedOrCancelled { () -> (any Error)? in
            do {
                try await uploader.upload(key: "big.bin", contents: contents, using: builder)
                return nil
            } catch {
                return error
            }
        }
        let answeredWhenTheUploadThrew = builder.abortAnswered
        let arrived = await builder.abortArrived.wait()
        builder.release.signal()

        #expect(upload.returned == .signalled, "the upload waited for its abort")
        #expect(answeredWhenTheUploadThrew == false)
        #expect(arrived == .signalled, "the abort was never sent")
        let aborting = try #require(await upload.task.value as? S3MultipartAbortInFlight)
        #expect(await aborting.confirmation.value)
        #expect(builder.abortAnswered)
    }

    /// A bound no runner reaches, for every case that reads an abort's
    /// confirmation: the fake answers the abort, never the clock.
    static let roomyAbortBound = 600

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
        do {
            try await S3Uploader(noteUnconfirmedAbort: { _ in }, abortBound: Self.roomyAbortBound)
                .upload(key: "big.bin", contents: stream(of: chunks), using: builder)
            Issue.record("expected a throw")
        } catch let aborting as S3MultipartAbortInFlight {
            // The abort runs detached from the upload; wait for it before
            // looking at what was sent.
            _ = await aborting.confirmation.value
        }
        // An Abort (DELETE ?uploadId) must have been issued:
        #expect(builder.performed.contains { $0.httpMethod == "DELETE" && ($0.url!.query ?? "").contains("uploadId=UP2") })
    }
}
