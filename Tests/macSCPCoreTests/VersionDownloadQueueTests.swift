import Foundation
import Synchronization
import Testing
@testable import macSCPCore

/// `TransferQueueViewModel.enqueueAndWaitVersion`: a download of one specific
/// version of an object, through the transfer queue like any other, from an
/// `ObjectVersionProvider` that is not a file system.
///
/// Four properties are pinned, each beside the control that shows the thing
/// it scans is there at all:
/// - the version's bytes arrive under the name the caller chose, and the
///   provider is asked for exactly that key, bucket and version;
/// - a delete marker or an unknown id is refused before a byte is read;
/// - the adapter between the queue and the provider refuses a resume offset;
/// - **a version download cannot resume, and a lost connection says so**: the
///   item fails, it is not retained for `retryInterrupted`, which would hand
///   it a different source (see `VersionDownloadSource`).
@Suite("Version download through the queue", .timeLimit(.minutes(5)))
@MainActor
struct VersionDownloadQueueTests {
    // MARK: - Doubles

    /// A provider that serves canned histories and canned version bodies, and
    /// counts the reads it was asked for. Everything the download does not
    /// call refuses, so a download that reached for it would fail loudly.
    final class FakeProvider: ObjectVersionProvider {
        struct Read: Sendable {
            var body: Data
            /// When set, the stream yields `body` and then fails with this.
            var failure: RemoteFSError?
        }

        struct Asked: Equatable, Sendable {
            let key: String
            let bucket: String
            let versionId: String
        }

        private struct State {
            var history: [ObjectVersion]
            var reads: [String: Read]
            var asked: [Asked] = []
            var historyReads = 0
        }

        private let state: Mutex<State>

        init(history: [ObjectVersion], reads: [String: Read]) {
            state = Mutex(State(history: history, reads: reads))
        }

        var asked: [Asked] { state.withLock { $0.asked } }
        var historyReads: Int { state.withLock { $0.historyReads } }

        func versions(ofKey key: String, inBucket bucket: String) async throws -> [ObjectVersion] {
            state.withLock {
                $0.historyReads += 1
                return $0.history.filter { $0.key == key }
            }
        }

        func readStream(
            ofKey key: String, inBucket bucket: String, versionId: String
        ) async throws -> AsyncThrowingStream<Data, Error> {
            let read = state.withLock { state -> Read? in
                state.asked.append(Asked(key: key, bucket: bucket, versionId: versionId))
                return state.reads[versionId]
            }
            guard let read else { throw RemoteFSError.notFound(path: "/\(bucket)/\(key)") }
            return AsyncThrowingStream { continuation in
                continuation.yield(read.body)
                continuation.finish(throwing: read.failure)
            }
        }

        func deletedEntries(inBucket bucket: String, prefix: String) async throws -> [DeletedEntry] {
            throw Self.refusal
        }

        func restore(key: String, inBucket bucket: String, toVersionId versionId: String) async throws {
            throw Self.refusal
        }

        func deleteVersion(ofKey key: String, inBucket bucket: String, versionId: String) async throws {
            throw Self.refusal
        }

        func liftDeleteMarker(ofKey key: String, inBucket bucket: String, markerVersionId: String) async throws {
            throw Self.refusal
        }

        private static let refusal = RemoteFSError.protocolError(reason: "not part of a download")
    }

    static func entry(
        _ id: String, key: String = "doc.txt", size: UInt64? = nil, marker: Bool = false
    ) -> ObjectVersion {
        ObjectVersion(
            versionId: id, key: key, isLatest: false, isDeleteMarker: marker,
            size: marker ? nil : size, modifiedAt: nil, entityTag: nil)
    }

    /// A fresh directory the download may write into, removed by the caller.
    static func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-version-queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - The bytes arrive

    @Test func aVersionDownloadWritesThatVersionsBytesUnderTheGivenName() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = Data("the old content".utf8)
        let provider = FakeProvider(
            history: [Self.entry("v2", size: 3), Self.entry("v1", size: UInt64(old.count))],
            reads: ["v1": .init(body: old), "v2": .init(body: Data("new".utf8))])
        let queue = TransferQueueViewModel()

        try await queue.enqueueAndWaitVersion(
            fileName: "doc (v1).txt", source: provider, bucket: "b", key: "doc.txt", versionId: "v1",
            destination: LocalFileSystem(), destinationDirectory: directory.path(percentEncoded: false))

        let written = try Data(contentsOf: directory.appendingPathComponent("doc (v1).txt"))
        #expect(written == old)
        // Asked for that version, once, and for no other.
        #expect(provider.asked == [.init(key: "doc.txt", bucket: "b", versionId: "v1")])
        // One download item, finished, named as the caller named it.
        #expect(queue.items.map(\.fileName) == ["doc (v1).txt"])
        #expect(queue.items.map(\.direction) == [.download])
        #expect(queue.items.map(\.status) == [.finished])
    }

    /// The progress total comes from the history (a version is a known size);
    /// it is what `Item.status`'s running state would show a user.
    @Test func theSizeOfTheVersionIsKnownBeforeItIsRead() async throws {
        let adapter = VersionDownloadSource(
            source: FakeProvider(
                history: [Self.entry("v1", size: 42)], reads: [:]),
            bucket: "b", key: "doc.txt", versionId: "v1")
        let item = try await adapter.stat(path: "ignored")
        #expect(item.size == 42)
        #expect(item.kind == .file)
    }

    // MARK: - Refused before a byte is read

    @Test func aDeleteMarkerAndAnUnknownIdAreRefusedBeforeAnythingIsRead() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = FakeProvider(
            history: [Self.entry("m1", marker: true), Self.entry("v1", size: 1)],
            reads: ["m1": .init(body: Data("never".utf8)), "v1": .init(body: Data("x".utf8))])
        let queue = TransferQueueViewModel()

        func download(_ id: String) async -> Error? {
            do {
                try await queue.enqueueAndWaitVersion(
                    fileName: "out-\(id)", source: provider, bucket: "b", key: "doc.txt", versionId: id,
                    destination: LocalFileSystem(),
                    destinationDirectory: directory.path(percentEncoded: false))
                return nil
            } catch {
                return error
            }
        }

        #expect(
            (await download("m1") as? RemoteFSError)
                == .protocolError(reason: VersionDownloadSource.markerReason))
        #expect((await download("ghost") as? RemoteFSError) == .notFound(path: "/b/doc.txt"))
        #expect(provider.asked.isEmpty)
        // The positive beside the two: a version that holds content IS read,
        // so an empty `asked` above is not a provider that never reads.
        #expect(await download("v1") == nil)
        #expect(provider.asked.map(\.versionId) == ["v1"])
    }

    // MARK: - No resume

    /// The adapter is a source and nothing else: every other member refuses,
    /// `homeDirectoryPath` included (it once answered `"/"`). The positive
    /// beside the refusals is the source half, which works.
    @Test func theAdapterRefusesEverythingBeyondReadingOneVersion() async throws {
        let adapter = VersionDownloadSource(
            source: FakeProvider(history: [Self.entry("v1", size: 1)], reads: [:]),
            bucket: "b", key: "doc.txt", versionId: "v1")
        let refusal = RemoteFSError.protocolError(reason: VersionDownloadSource.refusalReason)

        func refused(_ operation: () async throws -> Void) async -> Bool {
            do { try await operation() } catch { return (error as? RemoteFSError) == refusal }
            return false
        }
        #expect(await refused { _ = try await adapter.homeDirectoryPath() })
        #expect(await refused { _ = try await adapter.list(path: "/") })
        #expect(await refused { try await adapter.delete(path: "/x") })
        #expect(await refused { try await adapter.createDirectory(at: "/x") })
        #expect(try await adapter.stat(path: "ignored").size == 1)
    }

    /// The adapter has no offset to honour. A read from anywhere but the
    /// start is refused, and the provider is not asked.
    @Test func theAdapterRefusesAResumeOffset() async throws {
        let provider = FakeProvider(history: [Self.entry("v1", size: 10)], reads: ["v1": .init(body: Data(count: 10))])
        let adapter = VersionDownloadSource(source: provider, bucket: "b", key: "doc.txt", versionId: "v1")

        do {
            _ = try await adapter.readStream(path: "ignored", fromOffset: 5)
            Issue.record("a read from an offset was served")
        } catch {
            #expect((error as? RemoteFSError) == .protocolError(reason: VersionDownloadSource.resumeRefusedReason))
        }
        #expect(provider.asked.isEmpty)

        // The positive beside it: from the start it reads.
        var received = Data()
        for try await chunk in try await adapter.readStream(path: "ignored", fromOffset: 0) {
            received.append(chunk)
        }
        #expect(received.count == 10)
        #expect(provider.asked.count == 1)
    }

    /// A lost connection mid-download. The destination is the local disk,
    /// which CAN append, so for an ordinary download this is exactly the
    /// situation the queue retains as `.interrupted` and `retryInterrupted`
    /// later resumes at the partial file's size, against whatever source the
    /// tab then passes. For a version that source would be the tab's own file
    /// system and the path would name the key's CURRENT content: the partial
    /// file of an old version with the tail of another appended to it. So the
    /// version download is classified as failed, and nothing is retained.
    @Test func aConnectionLossDuringAVersionDownloadFailsAndIsNotRetainedForResume() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lost = RemoteFSError.connectionFailed(reason: "lost")
        let provider = FakeProvider(
            history: [Self.entry("v1", size: 100)],
            reads: ["v1": .init(body: Data(count: 10), failure: lost)])
        let queue = TransferQueueViewModel()

        do {
            try await queue.enqueueAndWaitVersion(
                fileName: "doc (v1).txt", source: provider, bucket: "b", key: "doc.txt", versionId: "v1",
                destination: LocalFileSystem(), destinationDirectory: directory.path(percentEncoded: false))
            Issue.record("a lost connection was not reported")
        } catch {
            #expect((error as? RemoteFSError) == lost)
        }

        #expect(queue.items.map(\.status) == [.failed(.interrupted)])
        #expect(queue.hasInterrupted == false)
        // Nothing to retry: a retry against the tab's own file systems must
        // not re-enqueue it, and the provider is not asked a second time.
        queue.retryInterrupted(source: LocalFileSystem(), destination: LocalFileSystem())
        #expect(queue.items.map(\.status) == [.failed(.interrupted)])
        #expect(provider.asked.count == 1)
    }

    /// The transfer row warns "restarts from the beginning" while a transfer
    /// that cannot resume is queued or running (`Item.canResumeIfInterrupted`
    /// false). A version download to the local disk is the one download where
    /// that is unconditionally true, and the local disk can append, so the
    /// flag cannot be left to the destination's answer. The flag is read AFTER the download completes, which is as good as reading it
    /// while the item is queued or running: the field is immutable, set once
    /// at enqueue. The ordinary download beside it shows the flag IS the
    /// destination's there.
    @Test func aVersionDownloadIsMarkedAsRestartingWhereAnOrdinaryOneIsNot() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = FakeProvider(
            history: [Self.entry("v1", size: 1)], reads: ["v1": .init(body: Data("x".utf8))])
        let queue = TransferQueueViewModel()
        try await queue.enqueueAndWaitVersion(
            fileName: "v.txt", source: provider, bucket: "b", key: "doc.txt", versionId: "v1",
            destination: LocalFileSystem(), destinationDirectory: directory.path(percentEncoded: false))
        #expect(queue.items.map(\.canResumeIfInterrupted) == [false])

        let source = TransferQueueViewModelTests.QueueTestFS(reads: [
            "/a.txt": .init(content: Data("x".utf8)),
        ])
        try await queue.enqueueAndWait(
            fileName: "a.txt", direction: .download, source: source, sourcePath: "/a.txt",
            destination: LocalFileSystem(), destinationDirectory: directory.path(percentEncoded: false))
        #expect(queue.items.map(\.canResumeIfInterrupted) == [false, true])
    }

    /// The control for the case above: the same lost connection, the same
    /// destination, an ordinary download. It IS retained, so the case above
    /// is a decision about versions and not what any download does here.
    @Test func theSameLossDuringAnOrdinaryDownloadIsRetainedForResume() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = TransferQueueViewModelTests.QueueTestFS(reads: [
            "/a.txt": .init(
                content: Data(count: 10), failWith: RemoteFSError.connectionFailed(reason: "lost")),
        ])
        let queue = TransferQueueViewModel()

        do {
            try await queue.enqueueAndWait(
                fileName: "a.txt", direction: .download, source: source, sourcePath: "/a.txt",
                destination: LocalFileSystem(), destinationDirectory: directory.path(percentEncoded: false))
            Issue.record("a lost connection was not reported")
        } catch {
            #expect((error as? RemoteFSError) == .connectionFailed(reason: "lost"))
        }
        #expect(queue.items.map(\.status) == [.interrupted])
        #expect(queue.hasInterrupted)
    }
}
