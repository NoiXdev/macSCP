import Foundation
import Synchronization
import Testing

@testable import macSCPCore

/// A failed S3 multipart upload's abort against the `disconnect()` that
/// follows it (final review I1 of the 2026-09-19 plan).
///
/// Every tab teardown ends in `disconnect()` milliseconds after
/// `cancelAll`, and the command line disconnects the moment a command
/// fails. While the abort went out on the connection's own session,
/// `invalidateAndCancel` cancelled it there, and the upload stayed on the
/// server, billed. The abort now has a channel of its own, which
/// `disconnect()` neither cancels nor waits for.
///
/// The endpoint holds every abort until the case releases it, and fails a
/// request on a channel that was cancelled — at once if it arrives after the
/// cancel, when the cancel comes if it was already waiting — the way
/// `invalidateAndCancel` treats a `URLSession`'s tasks. The ordering is
/// asserted, never a time; the abort bound is one no runner reaches.
///
/// The write and the disconnect run through `returnedOrCancelled`: one that
/// waited for the held abort would never return here, since the abort is
/// released only after them, and a plain `await` on it would hold the run
/// until the abort bound. The time limit ends the wait instead, the case
/// reads what it asserts, and only then releases the abort.
@Suite("An S3 multipart abort outlives the disconnect", .timeLimit(.minutes(2)))
struct S3AbortOutlivesDisconnectTests {
    @Test func anAbortAfterAFailedPartIsStillSentAfterTheDisconnectThatFollows() async throws {
        let endpoint = S3AbortEndpoint(abortStatus: 204)
        let fs = try await Self.connect(endpoint)

        let write = await Self.failingWrite(to: fs)
        let disconnect = await returnedOrCancelled { await fs.disconnect() }
        let arrived = await endpoint.abortArrived.wait()
        endpoint.release()

        #expect(write.returned == .signalled, "the write waited for its abort")
        #expect(disconnect.returned == .signalled, "disconnect() waited for the abort")
        #expect(arrived == .signalled, "the abort was never sent")
        #expect(await write.task.value as? RemoteFSError == .authenticationFailed)
        await disconnect.task.value
        #expect(await fs.incompleteUploadMayRemain(at: "/big.bin") == false)
        let events = endpoint.events
        let answered = try #require(
            events.firstIndex { $0.hasPrefix("abort answered on ") }, "\(events)")
        let channel = String(events[answered].dropFirst("abort answered on ".count))
        #expect(channel != "0", "the abort went out on the connection's own channel: \(events)")
        let finished = try #require(events.firstIndex(of: "channel \(channel) finished"), "\(events)")
        #expect(answered < finished)
        #expect(!events.contains("channel \(channel) cancelled"))
        #expect(events.contains("channel 0 cancelled"))
    }

    /// `disconnect()` returns while the abort is still unanswered: a tab's
    /// teardown awaits it, and an endpoint that stopped answering must not
    /// hold it.
    @Test func theDisconnectDoesNotWaitForTheAbort() async throws {
        let endpoint = S3AbortEndpoint(abortStatus: 204)
        let fs = try await Self.connect(endpoint)

        let write = await Self.failingWrite(to: fs)
        let arrived = await endpoint.abortArrived.wait()
        let disconnect = await returnedOrCancelled { await fs.disconnect() }
        let answeredWhenTheDisconnectReturned = endpoint.events.contains {
            $0.hasPrefix("abort answered")
        }
        endpoint.release()

        #expect(write.returned == .signalled, "the write waited for its abort")
        #expect(arrived == .signalled, "the abort was never sent")
        #expect(disconnect.returned == .signalled, "disconnect() waited for the abort")
        #expect(answeredWhenTheDisconnectReturned == false)
        await disconnect.task.value
        _ = await write.task.value
        #expect(await fs.incompleteUploadMayRemain(at: "/big.bin") == false)
    }

    /// The connection names every upload whose abort did not confirm, once
    /// the aborts have answered — the question the command line asks before
    /// it exits.
    @Test func theConnectionNamesTheUploadsWhoseAbortDidNotConfirm() async throws {
        let endpoint = S3AbortEndpoint(abortStatus: 500)
        let fs = try await Self.connect(endpoint)

        let write = await Self.failingWrite(to: fs)
        let asking = Task { await fs.awaitUnconfirmedAborts() }
        let arrived = await endpoint.abortArrived.wait()
        endpoint.release()

        #expect(write.returned == .signalled, "the write waited for its abort")
        #expect(arrived == .signalled, "the abort was never sent")
        #expect(await asking.value == ["big.bin"])
    }

    /// And a confirmed abort is not named.
    @Test func aConfirmedAbortIsNotNamed() async throws {
        let endpoint = S3AbortEndpoint(abortStatus: 204)
        let fs = try await Self.connect(endpoint)

        let write = await Self.failingWrite(to: fs)
        let asking = Task { await fs.awaitUnconfirmedAborts() }
        let arrived = await endpoint.abortArrived.wait()
        endpoint.release()

        #expect(write.returned == .signalled, "the write waited for its abort")
        #expect(arrived == .signalled, "the abort was never sent")
        #expect(await asking.value == [])
    }

    // MARK: - Support

    /// A write of `largerThanOnePut()` to `/big.bin`, which the endpoint
    /// fails at its first part — answering the error it threw.
    static func failingWrite(
        to fs: S3FileSystem
    ) async -> (returned: AsyncSignal.WaitOutcome, task: Task<(any Error)?, Never>) {
        await returnedOrCancelled {
            do {
                try await fs.write(path: "/big.bin", contents: largerThanOnePut())
                return nil
            } catch {
                return error
            }
        }
    }

    static func connect(_ endpoint: S3AbortEndpoint) async throws -> S3FileSystem {
        try await S3FileSystem.connect(
            config, channels: endpoint.channel, abortBoundSeconds: roomyAbortBound)
    }

    /// A bound no runner reaches: the abort is answered when the case
    /// releases it, never cut by the clock.
    static let roomyAbortBound = 600

    static let config = S3ConnectionConfig(
        accessKeyID: "AK", secretAccessKey: "SK", region: "us-east-1",
        endpoint: "http://127.0.0.1:9000", bucket: "macscp-seed",
        usePathStyle: true, sessionToken: nil)

    /// Just over the single-PUT threshold, so the upload goes multipart.
    static func largerThanOnePut() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data(count: S3Uploader.singlePutThreshold + 1))
            continuation.finish()
        }
    }
}

/// An S3 endpoint for one multipart upload that fails: empty listings, an
/// initiate, a part refused with 403, and an abort held until the case
/// releases it, then answered with `abortStatus`. Every channel it hands out
/// is numbered in the order the file system asked for it; the connection's
/// own is channel 0.
final class S3AbortEndpoint: Sendable {
    private struct State {
        var events: [String] = []
        var channels = 0
        var cancelled: Set<Int> = []
        var released = false
        var held: [(channel: Int, gate: S3AbortGate)] = []
    }

    private let state = Mutex(State())
    private let abortStatus: Int
    let abortArrived = AsyncSignal()

    init(abortStatus: Int) { self.abortStatus = abortStatus }

    var events: [String] { state.withLock { $0.events } }

    /// The channel factory `S3FileSystem.connect(_:channels:abortBoundSeconds:)`
    /// takes.
    var channel: @Sendable () -> S3HTTPChannel {
        { [self] in
            let index = state.withLock { state -> Int in
                defer { state.channels += 1 }
                return state.channels
            }
            return S3HTTPChannel(
                transport: S3AbortEndpointTransport(endpoint: self, channel: index),
                redirectPolicy: nil,
                cancel: { [self] in cancel(index) },
                finish: { [self] in log("channel \(index) finished") })
        }
    }

    /// Answers every abort held now, and every one that arrives later.
    func release() {
        let held = state.withLock { state in
            state.released = true
            defer { state.held.removeAll() }
            return state.held
        }
        for entry in held { entry.gate.settle(released: true) }
    }

    private func cancel(_ channel: Int) {
        let held = state.withLock { state in
            state.events.append("channel \(channel) cancelled")
            state.cancelled.insert(channel)
            let onThisChannel = state.held.filter { $0.channel == channel }
            state.held.removeAll { $0.channel == channel }
            return onThisChannel
        }
        for entry in held { entry.gate.settle(released: false) }
    }

    private func log(_ event: String) {
        state.withLock { $0.events.append(event) }
    }

    fileprivate func handle(
        _ request: URLRequest, on channel: Int
    ) async throws -> (Data, HTTPURLResponse) {
        // An abort is recorded as arriving even on a cancelled channel —
        // the `DELETE` case refuses it itself — so a case waiting for it is
        // never left waiting on a refusal.
        let refusedAtOnce = request.httpMethod != "DELETE"
            && state.withLock { $0.cancelled.contains(channel) }
        if refusedAtOnce {
            log("\(request.httpMethod ?? "?") refused on \(channel)")
            throw URLError(.cancelled)
        }
        let query = request.url?.query ?? ""
        switch request.httpMethod {
        case "GET":
            let listing = """
                <?xml version="1.0" encoding="UTF-8"?>
                <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                <IsTruncated>false</IsTruncated></ListBucketResult>
                """
            return (Data(listing.utf8), Self.response(request, 200))
        case "POST" where query.contains("uploads"):
            let body = "<InitiateMultipartUploadResult><UploadId>UPD</UploadId>"
                + "</InitiateMultipartUploadResult>"
            return (Data(body.utf8), Self.response(request, 200))
        case "PUT":
            return (Data(), Self.response(request, 403))
        case "DELETE":
            let gate = S3AbortGate()
            state.withLock { state in
                state.events.append("abort arrived on \(channel)")
                if state.released {
                    gate.settle(released: true)
                } else if state.cancelled.contains(channel) {
                    gate.settle(released: false)
                } else {
                    state.held.append((channel, gate))
                }
            }
            abortArrived.signal()
            guard await gate.wait() else {
                log("abort refused on \(channel)")
                throw URLError(.cancelled)
            }
            log("abort answered on \(channel)")
            return (Data(), Self.response(request, abortStatus))
        default:
            return (Data(), Self.response(request, 500))
        }
    }

    private static func response(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

/// One channel's transport onto `S3AbortEndpoint`.
struct S3AbortEndpointTransport: HTTPTransport {
    let endpoint: S3AbortEndpoint
    let channel: Int

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await endpoint.handle(request, on: channel)
    }

    func sendStreaming(_ request: URLRequest) async throws
        -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse)
    {
        throw RemoteFSError.protocolError(reason: "not used here")
    }
}

/// A held request's answer: released, or cancelled with its channel. The
/// first settlement wins; a wait whose own task is cancelled reads as
/// cancelled.
final class S3AbortGate: Sendable {
    private let outcome = Mutex<Bool?>(nil)
    private let settled = AsyncSignal()

    func settle(released: Bool) {
        let first = outcome.withLock { outcome -> Bool in
            guard outcome == nil else { return false }
            outcome = released
            return true
        }
        if first { settled.signal() }
    }

    func wait() async -> Bool {
        _ = await settled.wait()
        return outcome.withLock { $0 } ?? false
    }
}
