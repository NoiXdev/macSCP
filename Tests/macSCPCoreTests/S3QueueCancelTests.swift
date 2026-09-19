import Foundation
import MacSCPTestSupport
import Synchronization
import Testing

@testable import macSCPCore

/// A transfer queue cancelling an S3 multipart upload whose endpoint has
/// stopped answering (Task 2 fix round 2 of the 2026-09-19 plan, N1).
///
/// `cancelAll` is awaited by a tab's teardown and, through it, by the quit
/// watchdog, both of which rest on it returning at once
/// (`TabTeardown.run`'s doc comment). The multipart abort a cancel sends
/// must therefore never be waited for on that path: it runs detached, under
/// its own bound, and only a caller that ASKS — the throughput test,
/// through `incompleteUploadMayRemain(at:)`, and the command line before it
/// exits, through `awaitUnconfirmedAborts()` — waits for its answer.
///
/// The endpoint here holds the abort until the case releases it, and fails
/// a part request whose task is cancelled, the way a `URLSession` request is
/// documented to. The ordering is asserted, never a time. The abort bound is
/// one no runner reaches, so a `cancelAll` that waited for the abort would
/// never return — the abort is released only after it. It runs through
/// `returnedOrCancelled`, so the time limit ends that wait as `.cancelled`
/// and the case goes red, where a plain `await` would hold the run until
/// the bound. (It used to be caught by an "abandoned" flag the 30 s
/// production bound raised only after 30 s: a wall-clock ceiling, final
/// review M8 of the 2026-09-19 plan.)
@Suite("S3 multipart cancel in the transfer queue", .timeLimit(.minutes(2)))
struct S3QueueCancelTests {
    @Test @MainActor func aQueueCancelReturnsBeforeTheAbortIsAnsweredAndTheAbortIsStillSent()
        async throws
    {
        let transport = SilentS3Endpoint()
        let fs = try await S3FileSystem.connect(
            Self.config, transport: transport, abortBoundSeconds: Self.roomyAbortBound)
        let queue = TransferQueueViewModel()
        queue.enqueue(
            fileName: "big.bin", direction: .upload,
            source: ThroughputPayload(seed: 7, size: S3Uploader.singlePutThreshold + 1),
            sourcePath: ThroughputPayload.path, destination: fs, destinationDirectory: "/",
            onCompleted: nil)
        #expect(await transport.partArrived.wait() == .signalled)

        let cancel = await returnedOrCancelled { await queue.cancelAll(reason: .userRequested) }
        let answeredWhenCancelAllReturned = transport.abortAnswered
        let arrived = await transport.abortArrived.wait()
        transport.release.signal()

        #expect(cancel.returned == .signalled, "cancelAll waited for the abort")
        #expect(answeredWhenCancelAllReturned == false)
        #expect(arrived == .signalled, "the abort was never sent")
        await cancel.task.value
        // A user's Cancel reads as cancelled, not as a lost connection: the
        // part request's cancellation reaches the queue as one
        // (`HTTPTransferCancelTests` drives every leg of it).
        #expect(queue.items.first?.status == .cancelled)

        // The one caller that asks waits for the answer, and reads it.
        #expect(await fs.incompleteUploadMayRemain(at: "/big.bin") == false)
        #expect(transport.abortAnswered)
    }

    // MARK: - The guard: the queue path never awaits an abort

    /// The awaiting variants are `incompleteUploadMayRemain(at:)`,
    /// `awaitUnconfirmedAborts()` and the in-flight abort's `confirmation`.
    /// None may appear on the queue's path — the queue and the engine it
    /// calls — while the throughput test is where the first is used and the
    /// command line's connection scope where the second is. Read with
    /// comments and strings blanked (`SwiftSource`), so a doc comment naming
    /// the method is not a call.
    ///
    /// The negative check stands beside positive ones: each scanned file
    /// must still carry the code this guard is about (`copyFile(` in both),
    /// and the probe and the scope must still call their method, so a moved
    /// or renamed method turns this red instead of leaving the negative
    /// matching nothing.
    @Test func theQueuePathNeverAwaitsAnAbort() throws {
        let queue = try Self.code("Sources/macSCPCore/Presentation/TransferQueueViewModel.swift")
        let engine = try Self.code("Sources/macSCPCore/RemoteFS/TransferEngine.swift")
        let probe = try Self.code("Sources/macSCPCore/Diagnostics/ThroughputProbe.swift")
        let scope = try Self.code("Sources/macSCPCore/CLI/CLIConnectionScope.swift")

        #expect(queue.contains("copyFile("), "the queue no longer calls the engine")
        #expect(engine.contains("func copyFile("), "the engine no longer declares copyFile")
        #expect(probe.contains(Self.awaiting[0]), "the probe no longer asks — rename?")
        #expect(scope.contains(Self.awaiting[1]), "the scope no longer asks — rename?")
        for (name, code) in [("TransferQueueViewModel", queue), ("TransferEngine", engine)] {
            for spelling in Self.awaiting {
                #expect(!code.contains(spelling), "\(name) spells \(spelling)")
            }
        }
    }

    /// A guard that plants what it forbids in a synthetic source must find
    /// it — the check is not blind to the spelling it watches.
    @Test func theGuardSeesAnAwaitingCall() throws {
        let planted = try SwiftSource.blankingCommentsAndStrings("""
            func cancel(fs: any RemoteFileSystem) async {
                _ = await fs.incompleteUploadMayRemain(at: "/x")
                _ = await fs.awaitUnconfirmedAborts()
                _ = await error.confirmation.value
            }
            """)
        for spelling in Self.awaiting {
            #expect(planted.contains(spelling), "\(spelling)")
        }
    }

    // MARK: - Support

    static let awaiting = ["incompleteUploadMayRemain(", "awaitUnconfirmedAborts(", ".confirmation"]

    /// A bound no runner reaches: the abort answers when the case releases
    /// it, never when the clock gives up on it.
    static let roomyAbortBound = 600

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func code(_ path: String) throws -> String {
        try SourceCorpus.code(of: root.appendingPathComponent(path))
    }

    static let config = S3ConnectionConfig(
        accessKeyID: "AK", secretAccessKey: "SK", region: "us-east-1",
        endpoint: "http://127.0.0.1:9000", bucket: "macscp-seed",
        usePathStyle: true, sessionToken: nil)
}

/// An S3 endpoint for one multipart upload: empty listings, an initiate, a
/// part request that hangs until its task is cancelled and then throws
/// `CancellationError` (a real `URLSession` request throws
/// `URLError(.cancelled)` instead; both reach the queue as a cancellation,
/// `HTTPTransferCancelTests`), and an abort held until the case releases it.
final class SilentS3Endpoint: HTTPTransport, Sendable {
    private let answered = Mutex(false)
    let partArrived = AsyncSignal()
    let abortArrived = AsyncSignal()
    let release = AsyncSignal()

    var abortAnswered: Bool { answered.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
            let body = "<InitiateMultipartUploadResult><UploadId>UPQ</UploadId>"
                + "</InitiateMultipartUploadResult>"
            return (Data(body.utf8), Self.response(request, 200))
        case "PUT":
            partArrived.signal()
            _ = await AsyncSignal().wait()
            throw CancellationError()
        case "DELETE":
            abortArrived.signal()
            guard await release.wait() == .signalled else { throw CancellationError() }
            answered.withLock { $0 = true }
            return (Data(), Self.response(request, 204))
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
