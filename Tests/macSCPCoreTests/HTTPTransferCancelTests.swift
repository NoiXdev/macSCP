import Foundation
import MacSCPTestSupport
import Synchronization
import Testing

@testable import macSCPCore

/// A user's Cancel of an S3 or WebDAV transfer reads as cancelled, and a
/// connection that really went away still reads as lost (2026-09-19 small
/// follow-ups, Task 1).
///
/// The queue recognises a cancellation by its type alone — `catch is
/// CancellationError` in `TransferQueueViewModel.process`, the shape SFTP's
/// read and write hand through. A `URLSession` request whose task is
/// cancelled throws `URLError(.cancelled)` instead (measured 2026-09-19,
/// both awaiting a response and mid-body), so both kinds are driven here.
///
/// The endpoint parks each cancelled request until its task is cancelled —
/// a wait on a signal nobody raises, which returns on cancellation — and
/// only then throws, so no request ends on its own while the case is
/// deciding. The lost connection fails at once; nothing races it.
@Suite("An HTTP transfer's cancel in the transfer queue", .timeLimit(.minutes(2)))
struct HTTPTransferCancelTests {
    // MARK: - Cancel reads cancelled

    @Test(arguments: Case.all(failures: [.cancellationError, .urlCancelled]))
    @MainActor func aUserCancelReadsCancelled(_ testCase: Case) async throws {
        let endpoint = ParkingHTTPEndpoint(backend: testCase.backend, leg: testCase.leg,
                                           failure: testCase.failure)
        let queue = TransferQueueViewModel()
        try await testCase.enqueue(on: queue, through: endpoint)
        #expect(await endpoint.arrived.wait() == .signalled, "the request never went out")

        let cancel = await returnedOrCancelled { await queue.cancelAll(reason: .userRequested) }
        #expect(cancel.returned == .signalled, "cancelAll did not return")
        await cancel.task.value

        #expect(queue.items.first?.status == .cancelled)
    }

    // MARK: - A lost connection still reads lost

    /// The one leg left out is S3's body mid-stream: apart from a
    /// cancellation, what its body throws reaches the queue unwrapped, as
    /// it did before this task, so a lost connection there reads "Transfer
    /// failed", not "Connection lost" (recorded in the Task 1 report).
    @Test(arguments: Case.all(failures: [.networkConnectionLost]).filter {
        !($0.backend == .s3 && $0.leg == .downloadBody)
    })
    @MainActor func aLostConnectionStillReadsConnectionLost(_ testCase: Case) async throws {
        let endpoint = ParkingHTTPEndpoint(backend: testCase.backend, leg: testCase.leg,
                                           failure: testCase.failure)
        let queue = TransferQueueViewModel()
        try await testCase.enqueueAndWait(on: queue, through: endpoint)

        // An upload's destination cannot resume, so a lost connection is a
        // plain failure with the interrupted text; a download's local
        // destination can, so it is kept as interrupted.
        let expected: TransferQueueViewModel.Item.Status =
            testCase.leg == .upload
            ? .failed(CoreL10n.string("core.transfer.interrupted")) : .interrupted
        #expect(queue.items.first?.status == expected)
    }

    // MARK: - S3's tree delete

    /// The one S3 request outside a transfer that wraps its transport's
    /// errors itself instead of going through the channel: the batch
    /// `DeleteObjects` in `deleteTree`. Cancelled while that request is in
    /// flight, the delete ends in a `CancellationError`.
    @Test(arguments: [Failure.cancellationError, .urlCancelled])
    func aCancelledTreeDeleteEndsInACancellation(_ failure: Failure) async throws {
        let endpoint = ParkingTreeDeleteEndpoint(failure: failure)
        let fs = try await S3FileSystem.connect(Case.s3Config, transport: endpoint)
        let run = Task { try await fs.deleteTree(at: "/dir") }
        #expect(await endpoint.arrived.wait() == .signalled, "the batch delete never went out")
        run.cancel()

        let result = await finishingResult(run)
        let endedInACancellation: Bool
        if case .failure(let error) = result { endedInACancellation = error is CancellationError }
        else { endedInACancellation = false }
        #expect(endedInACancellation, "\(result)")
    }

    // MARK: - A cancelled URLError outside a cancelled task

    /// `URLError(.cancelled)` is a cancellation only when the task that made
    /// the request is cancelled. The same code ends a request whose session
    /// was ended under it — `disconnect()` — and, on WebDAV, one whose
    /// challenge the session's delegate refused. Neither is a Cancel anyone
    /// pressed, so neither may read as one.
    @Test(arguments: Backend.allCases)
    func aCancelledURLErrorInATaskThatIsNotCancelledIsAConnectionFailure(_ backend: Backend)
        async throws
    {
        let transport = ImmediateURLErrorTransport(code: .cancelled)
        let error: (any Error)?
        do {
            switch backend {
            case .s3:
                _ = try await S3FileSystem.connect(Case.s3Config, transport: transport)
            case .webDAV:
                _ = try await WebDAVFileSystem(config: Case.webDAVConfig, transport: transport)
                    .list(path: "/")
            }
            error = nil
        } catch let thrown {
            error = thrown
        }
        let isConnectionFailure = (error as? RemoteFSError)?.isConnectionFailure == true
        #expect(isConnectionFailure, "\(String(describing: error))")
    }

    // MARK: - Support

    enum Backend: String, CaseIterable, Sendable { case s3, webDAV }

    /// Where the request that fails is: the upload's PUT, the download's GET
    /// before its response, or the download's body after its first chunk.
    enum Leg: String, CaseIterable, Sendable { case upload, downloadResponse, downloadBody }

    enum Failure: String, Sendable {
        case cancellationError, urlCancelled, networkConnectionLost

        var error: any Error {
            switch self {
            case .cancellationError: return CancellationError()
            case .urlCancelled: return URLError(.cancelled)
            case .networkConnectionLost: return URLError(.networkConnectionLost)
            }
        }

        /// A cancellation is thrown once the request's task is cancelled; a
        /// lost connection at once.
        var waitsForCancellation: Bool { self != .networkConnectionLost }
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let backend: Backend
        let leg: Leg
        let failure: Failure

        var testDescription: String { "\(backend.rawValue) \(leg.rawValue) \(failure.rawValue)" }

        static func all(failures: [Failure]) -> [Case] {
            Backend.allCases.flatMap { backend in
                Leg.allCases.flatMap { leg in
                    failures.map { Case(backend: backend, leg: leg, failure: $0) }
                }
            }
        }

        static let s3Config = S3ConnectionConfig(
            accessKeyID: "AK", secretAccessKey: "SK", region: "us-east-1",
            endpoint: "http://127.0.0.1:9000", bucket: "macscp-seed",
            usePathStyle: true, sessionToken: nil)

        static let webDAVConfig = WebDAVConnectionConfig(
            baseURL: "https://dav.example.com/dav", username: "u", useNextcloudPath: false,
            password: "p")

        func fileSystem(on endpoint: ParkingHTTPEndpoint) async throws -> any RemoteFileSystem {
            switch backend {
            case .s3: return try await S3FileSystem.connect(Self.s3Config, transport: endpoint)
            case .webDAV: return WebDAVFileSystem(config: Self.webDAVConfig, transport: endpoint)
            }
        }

        @MainActor func enqueue(
            on queue: TransferQueueViewModel, through endpoint: ParkingHTTPEndpoint
        ) async throws {
            let remote = try await fileSystem(on: endpoint)
            switch leg {
            case .upload:
                queue.enqueue(
                    fileName: ParkingHTTPEndpoint.uploadName, direction: .upload,
                    source: ThroughputPayload(seed: 3, size: 64 * 1024),
                    sourcePath: ThroughputPayload.path, destination: remote,
                    destinationDirectory: "/", onCompleted: nil)
            case .downloadResponse, .downloadBody:
                queue.enqueue(
                    fileName: ParkingHTTPEndpoint.remoteName, direction: .download,
                    source: remote, sourcePath: "/" + ParkingHTTPEndpoint.remoteName,
                    destination: DrainingSink(), destinationDirectory: "/", onCompleted: nil)
            }
        }

        /// The same, returning once the item has ended; the thrown error is
        /// the queue's waiter contract for a failed item, not the assertion.
        @MainActor func enqueueAndWait(
            on queue: TransferQueueViewModel, through endpoint: ParkingHTTPEndpoint
        ) async throws {
            let remote = try await fileSystem(on: endpoint)
            switch leg {
            case .upload:
                try? await queue.enqueueAndWait(
                    fileName: ParkingHTTPEndpoint.uploadName, direction: .upload,
                    source: ThroughputPayload(seed: 3, size: 64 * 1024),
                    sourcePath: ThroughputPayload.path, destination: remote,
                    destinationDirectory: "/")
            case .downloadResponse, .downloadBody:
                try? await queue.enqueueAndWait(
                    fileName: ParkingHTTPEndpoint.remoteName, direction: .download,
                    source: remote, sourcePath: "/" + ParkingHTTPEndpoint.remoteName,
                    destination: DrainingSink(), destinationDirectory: "/")
            }
        }
    }
}

/// An S3 or WebDAV endpoint with one object, `remote.bin`, whose one
/// request under test fails with `failure`: the upload's PUT, the
/// download's GET before its response, or the download's body after one
/// chunk. A cancellation parks until the request's task is cancelled; a lost
/// connection fails at once. Every other request answers: an S3 listing
/// that holds `remote.bin`, a WebDAV `PROPFIND` that finds it and misses
/// everything else.
final class ParkingHTTPEndpoint: HTTPTransport, Sendable {
    static let remoteName = "remote.bin"
    static let uploadName = "up.bin"
    static let remoteSize = 4 * TransferChunk.size

    let backend: HTTPTransferCancelTests.Backend
    let leg: HTTPTransferCancelTests.Leg
    let failure: HTTPTransferCancelTests.Failure
    /// Raised when the request under test has gone out.
    let arrived = AsyncSignal()

    init(
        backend: HTTPTransferCancelTests.Backend, leg: HTTPTransferCancelTests.Leg,
        failure: HTTPTransferCancelTests.Failure
    ) {
        self.backend = backend
        self.leg = leg
        self.failure = failure
    }

    /// The request under test's end.
    private func fail() async throws -> Never {
        arrived.signal()
        if failure.waitsForCancellation { _ = await AsyncSignal().wait() }
        throw failure.error
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        switch request.httpMethod {
        case "GET" where backend == .s3:
            let listing = """
                <?xml version="1.0" encoding="UTF-8"?>
                <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                <IsTruncated>false</IsTruncated>
                <Contents><Key>\(Self.remoteName)</Key><Size>\(Self.remoteSize)</Size></Contents>
                </ListBucketResult>
                """
            return (Data(listing.utf8), Self.response(request, 200))
        case "PROPFIND" where backend == .webDAV:
            guard request.url?.path.hasSuffix("/" + Self.remoteName) == true else {
                return (Data(), Self.response(request, 404))
            }
            let found = """
                <?xml version="1.0"?>
                <d:multistatus xmlns:d="DAV:">
                  <d:response><d:href>/dav/\(Self.remoteName)</d:href>
                    <d:propstat><d:prop><d:resourcetype/>
                      <d:getcontentlength>\(Self.remoteSize)</d:getcontentlength></d:prop>
                      <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
                </d:multistatus>
                """
            return (Data(found.utf8), Self.response(request, 207))
        case "PUT" where leg == .upload:
            try await fail()
        default:
            return (Data(), Self.response(request, 500))
        }
    }

    func sendStreaming(_ request: URLRequest) async throws
        -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse)
    {
        switch leg {
        case .downloadResponse:
            try await fail()
        case .downloadBody:
            let first = Data(repeating: 7, count: TransferChunk.size)
            let once = Once()
            let body = AsyncThrowingStream<Data, Error>(unfolding: { [self] in
                if once.isFirst() { return first }
                try await fail()
            })
            return (body, Self.response(request, 200))
        case .upload:
            throw RemoteFSError.protocolError(reason: "no download in an upload case")
        }
    }

    private static func response(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

/// An S3 endpoint holding one "directory", `dir/`, whose batch
/// `DeleteObjects` parks until its task is cancelled and then fails with
/// `failure`. `HEAD` misses, so the path is a directory and nothing else.
final class ParkingTreeDeleteEndpoint: HTTPTransport, Sendable {
    let failure: HTTPTransferCancelTests.Failure
    /// Raised when the batch delete has gone out.
    let arrived = AsyncSignal()

    init(failure: HTTPTransferCancelTests.Failure) { self.failure = failure }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        switch request.httpMethod {
        case "GET":
            let listing = """
                <?xml version="1.0" encoding="UTF-8"?>
                <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                <IsTruncated>false</IsTruncated>
                <Contents><Key>dir/a.txt</Key><Size>1</Size></Contents>
                </ListBucketResult>
                """
            return (Data(listing.utf8), Self.response(request, 200))
        case "HEAD":
            return (Data(), Self.response(request, 404))
        case "POST" where request.url?.query?.contains("delete") == true:
            arrived.signal()
            _ = await AsyncSignal().wait()
            throw failure.error
        default:
            return (Data(), Self.response(request, 500))
        }
    }

    func sendStreaming(_ request: URLRequest) async throws
        -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse)
    {
        throw RemoteFSError.protocolError(reason: "not used here")
    }

    private static func response(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

/// `true` the first time it is asked, `false` after.
private final class Once: Sendable {
    private let asked = Mutex(false)

    func isFirst() -> Bool {
        asked.withLock { asked in
            defer { asked = true }
            return !asked
        }
    }
}

/// A transport whose every request fails at once with a `URLError` — in
/// the calling task, whatever that task's state.
struct ImmediateURLErrorTransport: HTTPTransport {
    let code: URLError.Code

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(code)
    }

    func sendStreaming(_ request: URLRequest) async throws
        -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse)
    {
        throw URLError(code)
    }
}

/// A download's destination that keeps nothing: nothing exists at any path,
/// and a write drains what it is given.
final class DrainingSink: RemoteFileSystem {
    func stat(path: String) async throws -> RemoteFileItem {
        throw RemoteFSError.notFound(path: path)
    }

    func write(
        path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
    ) async throws {
        for try await _ in contents {}
    }

    func list(path: String) async throws -> [RemoteFileItem] { throw Self.refusal }
    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> { throw Self.refusal }
    func delete(path: String) async throws { throw Self.refusal }
    func createDirectory(at path: String) async throws { throw Self.refusal }
    func rename(from: String, to: String) async throws { throw Self.refusal }
    func setPermissions(path: String, permissions: UInt32) async throws { throw Self.refusal }
    func deleteTree(at path: String) async throws { throw Self.refusal }
    func homeDirectoryPath() async throws -> String { "/" }
    func disconnect() async {}

    private static let refusal = RemoteFSError.protocolError(
        reason: "the draining sink is a destination and nothing else")
}
