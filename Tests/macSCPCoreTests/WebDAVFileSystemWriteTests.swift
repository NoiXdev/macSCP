import Foundation
import Testing
@testable import macSCPCore

/// Delivers the first of two outcomes and ignores the rest, so a deadline and
/// a piece of work can race without either resuming a continuation twice.
private final class FirstResult<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var buffered: T?
    private var delivered = false

    func attach(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        if let buffered, !delivered {
            delivered = true
            lock.unlock()
            continuation.resume(returning: buffered)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func offer(_ value: T) {
        lock.lock()
        guard !delivered else { lock.unlock(); return }
        if let waiting = continuation {
            delivered = true
            continuation = nil
            lock.unlock()
            waiting.resume(returning: value)
            return
        }
        if buffered == nil { buffered = value }
        lock.unlock()
    }
}

/// Runs `work` under a hard deadline and returns `nil` if it is still running
/// when the deadline passes.
///
/// `work` runs in a **detached** task on purpose. A structured child — a task
/// group, `async let` — would keep the caller suspended until the child
/// finished, which is precisely what a genuinely wedged `write` never does:
/// the test would inherit the hang instead of reporting it, and `cancelAll()`
/// cannot help, because a task parked on an uninterruptible wait does not
/// observe cancellation. Detaching means a wedge costs one abandoned task for
/// the rest of the test process and nothing else — the suite still finishes.
private func withDeadline<T: Sendable>(
    seconds: Double, _ work: @escaping @Sendable () async -> T
) async -> T? {
    let outcome = FirstResult<T?>()
    let worker = Task.detached { outcome.offer(await work()) }
    let timer = Task.detached {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        outcome.offer(nil)
    }
    let result = await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        outcome.attach(continuation)
    }
    worker.cancel()
    timer.cancel()
    return result
}

/// What a bounded `write` call ended up doing. A plain `Error?` is not
/// `Sendable`, and the distinction between "threw" and "was cancelled"
/// matters to two of the tests below.
private struct WriteOutcome: Sendable {
    var thrown: RemoteFSError?
    var wasCancelled = false
}

@Suite("WebDAVFileSystem writes")
struct WebDAVFileSystemWriteTests {
    private let config = WebDAVConnectionConfig(
        stored: StoredWebDAVConfig(
            baseURL: "https://dav.example.com/dav", username: "u", useNextcloudPath: false),
        password: "p")

    private func stream(_ text: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data(text.utf8))
            continuation.finish()
        }
    }

    private func chunked(_ data: Data, chunk: Int) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunk, data.count)
                continuation.yield(data.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
        }
    }

    /// A deterministic, non-repeating pattern. A uniform fill would hide a
    /// duplicated, dropped or reordered chunk — every byte would match anyway.
    private static func pattern(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var state: UInt32 = 0x1234_5678
        for index in 0..<count {
            state = state &* 1_664_525 &+ 1_013_904_223
            bytes[index] = UInt8(truncatingIfNeeded: state >> 16)
        }
        return Data(bytes)
    }

    @Test func writeIssuesPut() async throws {
        let transport = FakeHTTPTransport(replies: [.init(status: 201, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        try await fs.write(path: "/a.txt", mode: .overwrite, contents: stream("hello"))

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://dav.example.com/dav/a.txt")
    }

    /// The pump is the whole point of the streaming PUT, so prove it moves
    /// bytes: what the caller streamed must be exactly what the request body
    /// carried. Asserting only on method and URL would pass just as well if
    /// the pump wrote garbage, or nothing.
    @Test func writeStreamsTheCallersBytesVerbatim() async throws {
        let transport = FakeHTTPTransport(replies: [.init(status: 201, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        try await fs.write(path: "/a.txt", mode: .overwrite, contents: stream("hello"))

        #expect(transport.bodies == [Data("hello".utf8)])
    }

    /// The bound stream pair holds a single `TransferChunk.size` (64 KiB)
    /// buffer, so a payload this size cannot be handed over in one go: the
    /// pump has to fill the buffer, wait for the reader to drain it, and
    /// resume — repeatedly. That wait branch is the one a small payload never
    /// reaches, and it is where both the throughput ceiling and the wedge
    /// live. 768 KiB forces at least a dozen round trips through it.
    @Test func writeRoundTripsAPayloadLargerThanTheStreamBuffer() async throws {
        let payload = Self.pattern(count: 768 * 1024)
        #expect(payload.count >= 12 * TransferChunk.size)
        let transport = FakeHTTPTransport(replies: [.init(status: 201, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        // A chunk size that is not a divisor of the buffer, so partial writes
        // and chunk boundaries do not line up conveniently.
        try await fs.write(path: "/big.bin", mode: .overwrite,
                           contents: chunked(payload, chunk: 40_000))

        #expect(transport.bodies.first?.count == payload.count)
        #expect(transport.bodies.first == payload)
    }

    /// A server that rejects a PUT early — 401 after a stale Digest nonce,
    /// 403, 507 — answers *without* reading the rest of the body. The
    /// response arrives normally, but nothing will ever drain the bound pair
    /// again, so the pump is parked on a buffer with no reader. Waiting for
    /// it there wedges the transfer-queue slot for the life of the process.
    ///
    /// The deadline is what keeps this test honest without risking the suite:
    /// see `withDeadline` for why the work is detached rather than a
    /// structured child.
    @Test func earlyRejectionDoesNotWedgeTheWrite() async throws {
        let payload = Self.pattern(count: 768 * 1024)
        let transport = FakeHTTPTransport(
            replies: [.init(status: 507, body: Data(), headers: [:])],
            drainsRequestBody: false)
        let fs = WebDAVFileSystem(config: config, transport: transport)
        let contents = chunked(payload, chunk: 40_000)

        let outcome = await withDeadline(seconds: 5) { () -> WriteOutcome in
            do {
                try await fs.write(path: "/big.bin", mode: .overwrite, contents: contents)
                return WriteOutcome()
            } catch let error as RemoteFSError {
                return WriteOutcome(thrown: error)
            } catch {
                return WriteOutcome(thrown: .protocolError(reason: "unexpected \(error)"))
            }
        }

        let result = try #require(
            outcome,
            "write() never returned: the pump is parked on a body nobody will drain")
        #expect(result.thrown == .protocolError(reason: "The server is out of storage"))
    }

    /// Same wedge, reached the other way: the server accepts the PUT but the
    /// body is still being fed when the caller gives up. `Task.value` does not
    /// observe the awaiting task's cancellation, so without an explicit
    /// cancellation handler the caller can never break out either.
    @Test func cancellingTheCallerBreaksTheWaitOnAnUndrainedBody() async throws {
        let payload = Self.pattern(count: 768 * 1024)
        let transport = FakeHTTPTransport(
            replies: [.init(status: 201, body: Data(), headers: [:])],
            drainsRequestBody: false)
        let fs = WebDAVFileSystem(config: config, transport: transport)
        let contents = chunked(payload, chunk: 40_000)

        let work = Task {
            try await fs.write(path: "/big.bin", mode: .overwrite, contents: contents)
        }
        // Long enough for the pump to fill the buffer and park.
        try await Task.sleep(nanoseconds: 200_000_000)
        work.cancel()

        let outcome = await withDeadline(seconds: 5) { () -> WriteOutcome in
            do {
                try await work.value
                return WriteOutcome()
            } catch is CancellationError {
                return WriteOutcome(wasCancelled: true)
            } catch let error as RemoteFSError {
                return WriteOutcome(thrown: error)
            } catch {
                return WriteOutcome(thrown: .protocolError(reason: "unexpected \(error)"))
            }
        }

        let result = try #require(outcome, "cancelling the caller did not unblock write()")
        #expect(result.wasCancelled)
    }

    /// There is no partial PUT in WebDAV. Accepting `.append` would silently
    /// overwrite the file from byte zero and destroy the part already there.
    @Test func appendModeIsRefused() async throws {
        let transport = FakeHTTPTransport(replies: [])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        await #expect(throws: RemoteFSError.self) {
            try await fs.write(path: "/a.txt", mode: .append, contents: stream("more"))
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func createDirectoryIssuesMkcolOnACollectionURL() async throws {
        let transport = FakeHTTPTransport(replies: [.init(status: 201, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        try await fs.createDirectory(at: "/sub")

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "MKCOL")
        #expect(request.url?.absoluteString == "https://dav.example.com/dav/sub/")
    }

    /// Pins the mapping, not merely "some `RemoteFSError`": every branch of
    /// `mapStatus` throws one of those, so the weaker assertion would survive
    /// 405 mapping to `.notFound` — or `mapStatus` being deleted outright.
    @Test func mkcolOn405ReportsAlreadyExists() async throws {
        let transport = FakeHTTPTransport(replies: [.init(status: 405, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        await #expect(throws: RemoteFSError.protocolError(
            reason: "A file or folder named that already exists")) {
            try await fs.createDirectory(at: "/sub")
        }
    }

    /// MOVE with Overwrite: F is what makes rename atomic AND non-destructive.
    /// Without the header a server replaces the destination silently.
    @Test func renameIssuesMoveWithOverwriteFalse() async throws {
        let transport = FakeHTTPTransport(replies: [.init(status: 201, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        try await fs.rename(from: "/a.txt", to: "/b.txt")

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "MOVE")
        #expect(request.value(forHTTPHeaderField: "Overwrite") == "F")
        #expect(request.value(forHTTPHeaderField: "Destination")
            == "https://dav.example.com/dav/b.txt")
    }

    /// 412 is the answer to `Overwrite: F` — the destination exists. Pinning
    /// the exact case matters here: `mapStatus` maps 409 to `.notFound`, and
    /// a weaker assertion could not tell the two apart.
    @Test func renameOn412ReportsDestinationConflict() async throws {
        let transport = FakeHTTPTransport(replies: [.init(status: 412, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        await #expect(throws: RemoteFSError.protocolError(
            reason: "The destination already exists")) {
            try await fs.rename(from: "/a.txt", to: "/b.txt")
        }
    }

    /// The headline difference from S3: one DELETE, not a recursive listing
    /// and batched deletes.
    @Test func deleteTreeIsASingleDeleteOnTheCollection() async throws {
        let transport = FakeHTTPTransport(replies: [.init(status: 204, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        try await fs.deleteTree(at: "/sub")

        #expect(transport.requests.count == 1)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == "https://dav.example.com/dav/sub/")
    }

    @Test func deleteIssuesDeleteOnTheFileURL() async throws {
        let transport = FakeHTTPTransport(replies: [.init(status: 204, body: Data(), headers: [:])])
        let fs = WebDAVFileSystem(config: config, transport: transport)

        try await fs.delete(path: "/a.txt")

        #expect(transport.requests.first?.url?.absoluteString
            == "https://dav.example.com/dav/a.txt")
    }

    /// permissionModel is .none — the capability says so, and the call must
    /// agree rather than pretending to succeed.
    @Test func setPermissionsIsRefused() async throws {
        let fs = WebDAVFileSystem(config: config, transport: FakeHTTPTransport(replies: []))
        await #expect(throws: RemoteFSError.protocolError(
            reason: "WebDAV has no permission model")) {
            try await fs.setPermissions(path: "/a.txt", permissions: 0o644)
        }
    }
}
