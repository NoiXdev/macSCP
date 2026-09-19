import Foundation
import MacSCPTestSupport
import Synchronization
import Testing

@testable import macSCPCore

/// A resumed S3 download never appends what a server sent in place of the
/// range it was asked for (final review of the 2026-09-19 small follow-ups,
/// I-3).
///
/// Task 1 of that plan made an S3 download that loses its connection
/// mid-body `.interrupted`, so `retryInterrupted` resumes it with a ranged
/// GET from the partial file's size. WebDAV already guarded that read
/// against a server that ignores `Range`; S3 did not, so a server or proxy
/// that answered 200 with the whole object had it appended after the
/// partial file — the destination ended up longer than the object, and the
/// item read finished. AWS, MinIO and the rig all honour `Range`, which is
/// why this is a fake.
///
/// The case reads what it asserts before anything heals: the retried item's
/// end is awaited through the queue's own `auditSink`, which the queue calls
/// once per item that turns terminal, and then the file on disk is read.
@Suite("A resumed S3 download refuses an ignored Range", .timeLimit(.minutes(2)))
@MainActor
struct S3ResumeRangeTests {
    @Test(arguments: RangeIgnoringS3Endpoint.Answer.allCases)
    func theQueueDoesNotAppendWhatAServerSentInsteadOfTheRange(
        _ answer: RangeIgnoringS3Endpoint.Answer
    ) async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-s3-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent(RangeIgnoringS3Endpoint.remoteName)

        let endpoint = RangeIgnoringS3Endpoint(answer: answer)
        let remote = try await S3FileSystem.connect(
            HTTPTransferCancelTests.Case.s3Config, transport: endpoint)
        let local = LocalFileSystem()
        let queue = TransferQueueViewModel()

        // The first attempt loses its connection after one chunk.
        try? await queue.enqueueAndWait(
            fileName: RangeIgnoringS3Endpoint.remoteName, direction: .download,
            source: remote, sourcePath: "/" + RangeIgnoringS3Endpoint.remoteName,
            destination: local, destinationDirectory: directory.path(percentEncoded: false))
        let interrupted = queue.items.first?.status == .interrupted
        let partial = try Data(contentsOf: destination)
        #expect(interrupted, "the lost connection did not leave a resumable item")
        #expect(partial == RangeIgnoringS3Endpoint.object.prefix(TransferChunk.size))

        // The resume: the item's end is what the case waits for.
        let ended = AsyncSignal()
        queue.auditSink = { _ in ended.signal() }
        queue.retryInterrupted(source: local, destination: remote)
        let outcome = await ended.wait()

        let status = queue.items.first?.status
        let onDisk = try Data(contentsOf: destination)
        let askedFrom = endpoint.rangesAsked.last
        #expect(outcome == .signalled, "the resumed item never ended")
        #expect(askedFrom == "bytes=\(TransferChunk.size)-", "the retry did not resume from the partial file")
        #expect(onDisk == partial, "the partial file was changed: \(onDisk.count) bytes, was \(partial.count)")
        if case .failed = status {} else {
            Issue.record("the resumed item did not fail: \(String(describing: status))")
        }
    }
}

/// An S3 endpoint with one object, `remote.bin`, whose download loses its
/// connection after the first chunk and whose every later GET ignores the
/// `Range` asked for: `wholeBody` answers 200 with the whole object,
/// `rangeFromTheStart` answers 206 with a `Content-Range` that starts at 0.
final class RangeIgnoringS3Endpoint: HTTPTransport, Sendable {
    enum Answer: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case wholeBody
        case rangeFromTheStart
        var testDescription: String { rawValue }
    }

    static let remoteName = "remote.bin"
    static let object = Data((0..<(3 * TransferChunk.size)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

    let answer: Answer
    private let downloads = Mutex<[String]>([])

    init(answer: Answer) { self.answer = answer }

    /// The `Range` header of every download, in order.
    var rangesAsked: [String] { downloads.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.httpMethod == "GET" else { return (Data(), Self.response(request, 500)) }
        let listing = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <IsTruncated>false</IsTruncated>
            <Contents><Key>\(Self.remoteName)</Key><Size>\(Self.object.count)</Size></Contents>
            </ListBucketResult>
            """
        return (Data(listing.utf8), Self.response(request, 200))
    }

    func sendStreaming(_ request: URLRequest) async throws
        -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse)
    {
        let range = request.value(forHTTPHeaderField: "Range") ?? ""
        let attempt = downloads.withLock { asked in
            asked.append(range)
            return asked.count
        }
        let whole = Self.object
        if attempt == 1 {
            let first = whole.prefix(TransferChunk.size)
            let body = AsyncThrowingStream<Data, Error> { continuation in
                continuation.yield(Data(first))
                continuation.finish(throwing: URLError(.networkConnectionLost))
            }
            return (body, Self.response(request, 206, contentRange: "bytes 0-\(whole.count - 1)/\(whole.count)"))
        }
        let body = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(whole)
            continuation.finish()
        }
        switch answer {
        case .wholeBody:
            return (body, Self.response(request, 200))
        case .rangeFromTheStart:
            return (body, Self.response(request, 206, contentRange: "bytes 0-\(whole.count - 1)/\(whole.count)"))
        }
    }

    private static func response(
        _ request: URLRequest, _ status: Int, contentRange: String? = nil
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: contentRange.map { ["Content-Range": $0] })!
    }
}
