import Foundation
import MacSCPTestSupport
import Testing
@testable import macSCPCore

@Suite("TransferEngine", .timeLimit(.minutes(1)))
struct TransferEngineTests {
    private func makeSource(content: Data) -> MockRemoteFileSystem {
        MockRemoteFileSystem(
            tree: ["/": [RemoteFileItem(
                name: "quelle.bin", path: "/quelle.bin", kind: .file,
                size: UInt64(content.count))]],
            files: ["/quelle.bin": content]
        )
    }

    @Test func copiesContentToDestinationDirectory() async throws {
        let content = Data((0..<(TransferChunk.size + 512)).map { UInt8($0 % 241) })
        let source = makeSource(content: content)
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])

        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            onProgress: { _ in }
        )
        #expect(await destination.writtenData(at: "/ziel/quelle.bin") == content)
    }

    @Test func reportsMonotonicProgressUpToTotal() async throws {
        let content = Data(repeating: 7, count: TransferChunk.size * 3)
        let source = makeSource(content: content)
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])

        let recorder = ProgressRecorder()
        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            onProgress: { progress in recorder.record(progress) }
        )
        let snapshots = recorder.snapshots
        #expect(!snapshots.isEmpty)
        #expect(snapshots.map(\.bytesTransferred) == snapshots.map(\.bytesTransferred).sorted())
        #expect(snapshots.last?.bytesTransferred == UInt64(content.count))
        #expect(snapshots.last?.totalBytes == UInt64(content.count))
    }

    @Test func missingSourceThrowsNotFound() async {
        let source = MockRemoteFileSystem(tree: ["/": []])
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])
        await #expect(throws: RemoteFSError.notFound(path: "/fehlt.bin")) {
            try await TransferEngine.copyFile(
                from: source, sourcePath: "/fehlt.bin",
                to: destination, destinationDirectory: "/ziel", fileName: "fehlt.bin",
                onProgress: { _ in }
            )
        }
    }

    @Test func fractionIsNilWithoutTotalAndOneAtCompletion() {
        #expect(TransferProgress(bytesTransferred: 10, totalBytes: nil).fraction == nil)
        #expect(TransferProgress(bytesTransferred: 0, totalBytes: 0).fraction == nil)
        #expect(TransferProgress(bytesTransferred: 50, totalBytes: 100).fraction == 0.5)
    }

    // MARK: - Cooperative Cancellation (M5c/T2)

    /// If the transfer task is cancelled in the middle of the transfer,
    /// `copyFile` must stop chunk-precisely: `CancellationError` is thrown and
    /// from the cancel point on, NO further chunk lands at the destination.
    ///
    /// Setup deliberately WITHOUT cancellation-aware waiting in the test
    /// double: the destination parks after the first chunk in a
    /// `Task.isCancelled` loop (which itself does NOT throw). This means
    /// cancellation is caught exclusively via the new `checkCancellation` in
    /// `copyFile` — not via a throwing wait. Without the engine check, all
    /// remaining chunks would run through after the cancel (red starting
    /// state).
    @Test func cancellationStopsBeforeNextChunkWrite() async throws {
        let chunkTotal = 4
        let content = Data(repeating: 0xAB, count: TransferChunk.size * chunkTotal)
        let source = makeSource(content: content)
        let reached = PlainSignal()
        let destination = RecordingSpinDestination(reached: reached)

        let task = Task {
            try await TransferEngine.copyFile(
                from: source, sourcePath: "/quelle.bin",
                to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
                onProgress: { _ in })
        }

        // First chunk has arrived at the destination → transfer is running, destination parks.
        try await reached.wait()
        task.cancel()

        // Timeout race so that a (regressed) missing cancellation doesn't
        // leave the test hanging forever.
        let outcome = try await awaitOutcome(task)
        guard case .failure(let error) = outcome else {
            Issue.record("expected CancellationError, was: \(String(describing: outcome))")
            return
        }
        #expect(error is CancellationError)

        let written = await destination.chunkCount
        #expect(written == 1)                // no further chunk after the cancel point
        #expect(written < chunkTotal)         // not all chunks transferred
    }

    // MARK: - Bandwidth Throttle (M6a/T2)

    /// A shared `BandwidthBucket` at 256 KB/s over 1 MiB (= 16 chunks of 64
    /// KiB): the first 4 chunks (262_144 bytes == 1s of rate, the bucket's
    /// initial burst) ride for free, the remaining 12 chunks are each paced
    /// ~0.25s apart — total virtual sleep ≈ 3.0s (786_432 bytes ÷ 262_144
    /// B/s). The chunk size equals the bucket's capacity exactly, so the
    /// terminal chunk lands the balance at 0, not negative — no leftover
    /// debt to add to the expectation. `VirtualTime` drives the bucket's
    /// clock/sleep so the test is deterministic instead of depending on real
    /// timing (no flakiness risk).
    @Test func throttleRequestsExpectedTotalSleepDuration() async throws {
        let content = Data(repeating: 0x42, count: 1024 * 1024)
        let source = makeSource(content: content)
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])

        let time = VirtualTime()
        let bucket = BandwidthBucket(bytesPerSecond: 256 * 1024, now: time.now, sleep: time.sleep)
        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            throttle: bucket,
            onProgress: { _ in }
        )

        #expect(await destination.writtenData(at: "/ziel/quelle.bin") == content)
        let totalSeconds = time.totalSlept.secondsAsDouble
        // Tolerance window instead of exact equality (Double rounding over 12
        // additions).
        #expect(totalSeconds >= 2.8)
        #expect(totalSeconds <= 3.2)
    }

    // MARK: - Double Throttle (M8b/T1)

    /// A cross-remote transfer is real download AND upload on this machine's
    /// link, so every chunk must pay BOTH buckets, sequentially (primary then
    /// secondary), and the observed pace follows the TIGHTER one.
    ///
    /// 2 chunks (128 KiB, `TransferChunk.size` each): primary paces at exactly
    /// 1 chunk/s (64 KiB/s — its own burst covers chunk 1 for free, chunk 2
    /// costs exactly 1.0s), secondary paces at a quarter of that (16 KiB/s —
    /// its burst covers only a quarter-chunk, so chunk 2 costs it 3.0s once
    /// its debt from chunk 1 is included). Both buckets share ONE virtual
    /// clock, so a sleep issued by either one advances the same timeline the
    /// other refills from — exactly mirroring two independent links that
    /// happen to be paced back-to-back. Total virtual sleep is deterministic:
    /// 1.0s (primary, chunk 2) + 3.0s (secondary, chunk 2) = 4.0s.
    @Test func copyFileConsumesBothThrottles() async throws {
        let content = Data(repeating: 0x11, count: TransferChunk.size * 2)
        let source = makeSource(content: content)
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])

        let time = VirtualTime()
        let primary = BandwidthBucket(bytesPerSecond: TransferChunk.size, now: time.now, sleep: time.sleep)
        let secondary = BandwidthBucket(
            bytesPerSecond: TransferChunk.size / 4, now: time.now, sleep: time.sleep)

        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            throttle: primary, secondaryThrottle: secondary,
            onProgress: { _ in }
        )

        #expect(await destination.writtenData(at: "/ziel/quelle.bin") == content)
        let totalSeconds = time.totalSlept.secondsAsDouble
        #expect(totalSeconds >= 3.8)
        #expect(totalSeconds <= 4.2)
    }

    /// Same setup as above but WITHOUT a secondary throttle: only the primary
    /// bucket paces the transfer (regression — must behave exactly like
    /// pre-M8b `copyFile`). Total virtual sleep ≈ 1.0s (chunk 1 free from the
    /// burst, chunk 2 costs exactly 1.0s).
    @Test func copyFileSecondaryThrottleNilBehavesAsBefore() async throws {
        let content = Data(repeating: 0x11, count: TransferChunk.size * 2)
        let source = makeSource(content: content)
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])

        let time = VirtualTime()
        let primary = BandwidthBucket(bytesPerSecond: TransferChunk.size, now: time.now, sleep: time.sleep)

        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            throttle: primary, secondaryThrottle: nil,
            onProgress: { _ in }
        )

        #expect(await destination.writtenData(at: "/ziel/quelle.bin") == content)
        let totalSeconds = time.totalSlept.secondsAsDouble
        #expect(totalSeconds >= 0.9)
        #expect(totalSeconds <= 1.1)
    }

    // MARK: - Resume (M5d/T2)

    /// Destination already holds the first 2 of 5 chunks. `resume: true` must
    /// read only the remaining 3 chunks (starting at the offset, not from 0),
    /// write them with `.append`, and report progress starting at the resume
    /// offset while `totalBytes` stays the FULL source size throughout.
    @Test func resumeMidTransferReadsOnlyRemainingChunksAndAppends() async throws {
        let content = Data((0..<(TransferChunk.size * 5)).map { UInt8($0 % 241) })
        let source = makeSource(content: content)
        let resumeOffset = UInt64(TransferChunk.size * 2)
        let existing = content.prefix(Int(resumeOffset))
        let destination = MockRemoteFileSystem(
            tree: ["/ziel": [RemoteFileItem(
                name: "quelle.bin", path: "/ziel/quelle.bin", kind: .file, size: resumeOffset)]],
            files: ["/ziel/quelle.bin": Data(existing)])

        let recorder = ProgressRecorder()
        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            resume: true,
            onProgress: { progress in recorder.record(progress) }
        )

        let snapshots = recorder.snapshots
        #expect(!snapshots.isEmpty)
        // Progress never dips below the resume offset and always carries the
        // FULL source size as totalBytes, not the remaining amount.
        #expect(snapshots.allSatisfy { $0.bytesTransferred > resumeOffset })
        #expect(snapshots.allSatisfy { $0.totalBytes == UInt64(content.count) })
        #expect(snapshots.last?.bytesTransferred == UInt64(content.count))

        #expect(await destination.writeModes["/ziel/quelle.bin"] == .append)
        // Only the 3 remaining chunks were written, not the whole file again.
        #expect(await destination.writtenData(at: "/ziel/quelle.bin") == content.suffix(from: Int(resumeOffset)))

        // The merged remote file (existing prefix + appended remainder) is
        // byte-identical to the full source.
        var merged = Data()
        for try await chunk in try await destination.readStream(path: "/ziel/quelle.bin") {
            merged.append(chunk)
        }
        #expect(merged == content)
    }

    /// `resume: true` against an ABSENT destination behaves exactly like a
    /// fresh transfer: full content, `.overwrite`, starting at offset 0.
    @Test func resumeWithMissingDestinationBehavesLikeFreshTransfer() async throws {
        let content = Data((0..<(TransferChunk.size + 512)).map { UInt8($0 % 241) })
        let source = makeSource(content: content)
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])

        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            resume: true,
            onProgress: { _ in }
        )
        #expect(await destination.writtenData(at: "/ziel/quelle.bin") == content)
        #expect(await destination.writeModes["/ziel/quelle.bin"] == .overwrite)
    }

    /// Destination already has the FULL size of the source: `resume: true`
    /// must report one final progress event at full size and return
    /// WITHOUT reading the source or writing anything (size-based "already
    /// complete" heuristic).
    @Test func resumeWithCompleteDestinationSkipsReadAndWrite() async throws {
        let content = Data(repeating: 3, count: TransferChunk.size * 2)
        let source = ReadCountingSource(content: content)
        let destination = MockRemoteFileSystem(
            tree: ["/ziel": [RemoteFileItem(
                name: "quelle.bin", path: "/ziel/quelle.bin", kind: .file,
                size: UInt64(content.count))]])

        let recorder = ProgressRecorder()
        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            resume: true,
            onProgress: { progress in recorder.record(progress) }
        )

        #expect(recorder.snapshots.map(\.bytesTransferred) == [UInt64(content.count)])
        #expect(recorder.snapshots.map(\.totalBytes) == [UInt64(content.count)])
        #expect(await source.readCallCount == 0)
        #expect(await destination.writtenData(at: "/ziel/quelle.bin") == nil)   // no write() call at all
    }

    /// Destination is LARGER than the source (documented size heuristic):
    /// treated the same as "already complete" — immediate success, no
    /// read/write.
    @Test func resumeWithDestinationLargerThanSourceSkipsReadAndWrite() async throws {
        let content = Data(repeating: 5, count: TransferChunk.size)
        let source = ReadCountingSource(content: content)
        let destination = MockRemoteFileSystem(
            tree: ["/ziel": [RemoteFileItem(
                name: "quelle.bin", path: "/ziel/quelle.bin", kind: .file,
                size: UInt64(content.count) + 999)]])

        let recorder = ProgressRecorder()
        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            resume: true,
            onProgress: { progress in recorder.record(progress) }
        )

        #expect(recorder.snapshots.map(\.bytesTransferred) == [UInt64(content.count)])
        #expect(await source.readCallCount == 0)
        #expect(await destination.writtenData(at: "/ziel/quelle.bin") == nil)
    }

    /// Cancellation mid-RESUME behaves exactly like the fresh-transfer case
    /// (M5c/T2): `CancellationError`, only the chunks up to the cancel point
    /// are written, and the write mode used is `.append` (proving the resume
    /// path — not a fresh overwrite — was actually taken).
    @Test func cancellationDuringResumeStopsBeforeNextChunkWriteAndLeavesPartial() async throws {
        let chunkTotal = 4
        let content = Data(repeating: 0xCD, count: TransferChunk.size * chunkTotal)
        let source = makeSource(content: content)
        let existingSize = UInt64(TransferChunk.size)   // one chunk already there
        let reached = PlainSignal()
        let destination = ResumeSpinDestination(reached: reached, existingSize: existingSize)

        let task = Task {
            try await TransferEngine.copyFile(
                from: source, sourcePath: "/quelle.bin",
                to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
                resume: true,
                onProgress: { _ in })
        }

        try await reached.wait()
        task.cancel()

        let outcome = try await awaitOutcome(task)
        guard case .failure(let error) = outcome else {
            Issue.record("expected CancellationError, was: \(String(describing: outcome))")
            return
        }
        #expect(error is CancellationError)

        let written = await destination.chunkCount
        #expect(written == 1)
        #expect(written < chunkTotal)
        #expect(await destination.recordedMode == .append)
    }

    // MARK: - Resume Safety Guard (M13/T1)

    /// An S3-like destination cannot append (`supportsAppendResume == false`).
    /// Its `stat` reports a smaller existing size — the classic resume
    /// trigger — but `copyFile(resume: true)` must NOT take the append path:
    /// appending a tail to a size-mismatched object would corrupt it. The
    /// engine must force a full overwrite from offset 0 instead.
    @Test func resumeIsSuppressedForNonAppendableDestination() async throws {
        let content = Data(repeating: 0xAB, count: 100)
        let source = makeSource(content: content)
        // Reports 40 bytes already there AND supportsAppendResume == false.
        // A naive resume would append the tail from offset 40 and corrupt
        // the object.
        let destination = RecordingFS(existingSize: 40, supportsAppendResume: false)

        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            resume: true,
            onProgress: { _ in })

        #expect(await destination.lastWriteMode == .overwrite)
        // Full re-read from offset 0, not a resume from the reported 40
        // bytes: the written payload is the WHOLE 100-byte source.
        #expect(await destination.writtenData == content)
    }

    /// Waits for the task's result without ever awaiting the task itself:
    /// a regression that never cancels leaves this poll unsatisfied, and the
    /// suite's `.timeLimit` ends it as a red naming the test rather than as
    /// a run that never returns. No bound of its own -- one would be a wall
    /// clock over work a loaded machine schedules.
    private func awaitOutcome(_ task: Task<Void, Error>) async throws -> Result<Void, Error> {
        let box = ResultBox()
        Task {
            do { try await task.value; box.set(.success(())) }
            catch { box.set(.failure(error)) }
        }
        try await pollUntil("the transfer task to settle") { box.value != nil }
        // Unreachable: the poll above ends only once `box.value` is set, and
        // `ResultBox` never clears it. Thrown rather than substituted,
        // because both callers go on to assert that this Result is a
        // `.failure` carrying a `CancellationError` -- fabricating exactly
        // that here would let an unreachable path pass the test it broke.
        guard let result = box.value else { throw OutcomeVanished() }
        return result
    }
}

/// Lock-protected test double instead of an actor: `onProgress` is
/// synchronous, so an actor + `Task { await ... }` would create unstructured
/// tasks whose completion before the assertions is not guaranteed (observed
/// intermittent failures). Synchronous locking makes the ordering
/// deterministic.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshots: [TransferProgress] = []
    var snapshots: [TransferProgress] {
        lock.lock()
        defer { lock.unlock() }
        return _snapshots
    }
    func record(_ p: TransferProgress) {
        lock.lock()
        defer { lock.unlock() }
        _snapshots.append(p)
    }
}

/// Cancellation-INDEPENDENT one-shot signal: `wait()` ignores task
/// cancellation (unlike the cancellation-aware `TestSignal` used in the
/// queue tests). This means cancellation in the test is caught exclusively
/// via `copyFile`'s `checkCancellation`.
private final class PlainSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func fire() {
        lock.lock()
        fired = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }

    func wait() async throws {
        try await awaitResumption { (continuation: CheckedContinuation<Void, Never>) in
            self.lock.lock()
            if self.fired {
                self.lock.unlock()
                continuation.resume()
            } else {
                self.continuations.append(continuation)
                self.lock.unlock()
            }
        }
    }
}

/// Destination double that counts every chunk written and, after the FIRST
/// chunk, parks in a cancellation-UNAWARE `Task.isCancelled` loop. If the
/// transfer task is cancelled, the loop exits and the next pull from the
/// source stream is caught by the engine's `checkCancellation`.
private actor RecordingSpinDestination: RemoteFileSystem {
    private let reached: PlainSignal
    private(set) var chunkCount = 0

    init(reached: PlainSignal) { self.reached = reached }

    func list(path: String) async throws -> [RemoteFileItem] { [] }

    func stat(path: String) async throws -> RemoteFileItem {
        throw RemoteFSError.notFound(path: path)
    }

    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {
        var isFirst = true
        for try await _ in contents {
            chunkCount += 1
            if isFirst {
                isFirst = false
                reached.fire()
                // Park cancellation-UNAWARE: only the cancellation wakes the loop.
                while !Task.isCancelled { await Task.yield() }
            }
        }
    }

    func delete(path: String) async throws {
        throw RemoteFSError.notFound(path: path)
    }

    func createDirectory(at path: String) async throws {}
    func rename(from: String, to: String) async throws {
        throw RemoteFSError.protocolError(reason: "unsupported in this test double")
    }
    func setPermissions(path: String, permissions: UInt32) async throws {
        throw RemoteFSError.protocolError(reason: "unsupported in this test double")
    }
    func deleteTree(at path: String) async throws {
        throw RemoteFSError.protocolError(reason: "unsupported in this test double")
    }
    func homeDirectoryPath() async throws -> String { "/" }
    func disconnect() async {}
}

/// Source double that counts `readStream` calls (M5d/T2) — lets the
/// "already complete" resume tests assert the source is NEVER read at all,
/// not just that no bytes end up written.
private actor ReadCountingSource: RemoteFileSystem {
    private let content: Data
    private(set) var readCallCount = 0

    init(content: Data) { self.content = content }

    func list(path: String) async throws -> [RemoteFileItem] { [] }

    func stat(path: String) async throws -> RemoteFileItem {
        RemoteFileItem(name: "quelle.bin", path: path, kind: .file, size: UInt64(content.count))
    }

    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        readCallCount += 1
        let start = min(Int(offset), content.count)
        return AsyncThrowingStream { continuation in
            var position = start
            while position < content.count {
                let end = min(position + TransferChunk.size, content.count)
                continuation.yield(content.subdata(in: position..<end))
                position = end
            }
            continuation.finish()
        }
    }

    func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {}
    func delete(path: String) async throws { throw RemoteFSError.notFound(path: path) }
    func createDirectory(at path: String) async throws {}
    func rename(from: String, to: String) async throws {
        throw RemoteFSError.protocolError(reason: "unsupported in this test double")
    }
    func setPermissions(path: String, permissions: UInt32) async throws {
        throw RemoteFSError.protocolError(reason: "unsupported in this test double")
    }
    func deleteTree(at path: String) async throws {
        throw RemoteFSError.protocolError(reason: "unsupported in this test double")
    }
    func homeDirectoryPath() async throws -> String { "/" }
    func disconnect() async {}
}

/// Destination double for the resume-cancellation test (M5d/T2): `stat`
/// reports an EXISTING partial size (so `copyFile` takes the resume path and
/// computes a non-zero offset), then — just like `RecordingSpinDestination`
/// — parks cancellation-unaware after the first written chunk so cancellation
/// is caught exclusively via the engine's `checkCancellation`. Records the
/// write mode it was called with, so the test can prove `.append` (not
/// `.overwrite`) was actually used.
private actor ResumeSpinDestination: RemoteFileSystem {
    private let reached: PlainSignal
    private let existingSize: UInt64
    private(set) var chunkCount = 0
    private(set) var recordedMode: WriteMode?

    init(reached: PlainSignal, existingSize: UInt64) {
        self.reached = reached
        self.existingSize = existingSize
    }

    func list(path: String) async throws -> [RemoteFileItem] { [] }

    func stat(path: String) async throws -> RemoteFileItem {
        RemoteFileItem(name: "quelle.bin", path: path, kind: .file, size: existingSize)
    }

    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {
        recordedMode = mode
        var isFirst = true
        for try await _ in contents {
            chunkCount += 1
            if isFirst {
                isFirst = false
                reached.fire()
                while !Task.isCancelled { await Task.yield() }
            }
        }
    }

    func delete(path: String) async throws { throw RemoteFSError.notFound(path: path) }
    func createDirectory(at path: String) async throws {}
    func rename(from: String, to: String) async throws {
        throw RemoteFSError.protocolError(reason: "unsupported in this test double")
    }
    func setPermissions(path: String, permissions: UInt32) async throws {
        throw RemoteFSError.protocolError(reason: "unsupported in this test double")
    }
    func deleteTree(at path: String) async throws {
        throw RemoteFSError.protocolError(reason: "unsupported in this test double")
    }
    func homeDirectoryPath() async throws -> String { "/" }
    func disconnect() async {}
}

/// Minimal destination double for the resume-safety guard test (M13/T1):
/// reports a configurable `existingSize` (smaller than the source — the
/// classic resume trigger) and a configurable `supportsAppendResume`, and
/// records the write mode and full payload it received, so the test can
/// prove a non-appendable destination gets a full `.overwrite` rather than
/// an `.append` continuing from the reported size.
private actor RecordingFS: RemoteFileSystem {
    private let existingSize: UInt64
    let supportsAppendResume: Bool
    private(set) var lastWriteMode: WriteMode?
    private(set) var writtenData: Data?

    init(existingSize: UInt64, supportsAppendResume: Bool) {
        self.existingSize = existingSize
        self.supportsAppendResume = supportsAppendResume
    }

    func list(path: String) async throws -> [RemoteFileItem] { [] }

    func stat(path: String) async throws -> RemoteFileItem {
        RemoteFileItem(name: "quelle.bin", path: path, kind: .file, size: existingSize)
    }

    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {
        lastWriteMode = mode
        var collected = Data()
        for try await chunk in contents {
            collected.append(chunk)
        }
        writtenData = collected
    }

    func delete(path: String) async throws { throw RemoteFSError.notFound(path: path) }
    func createDirectory(at path: String) async throws {}
    func rename(from: String, to: String) async throws {
        throw RemoteFSError.protocolError(reason: "unsupported in this test double")
    }
    func setPermissions(path: String, permissions: UInt32) async throws {
        throw RemoteFSError.protocolError(reason: "unsupported in this test double")
    }
    func deleteTree(at path: String) async throws {
        throw RemoteFSError.protocolError(reason: "unsupported in this test double")
    }
    func homeDirectoryPath() async throws -> String { "/" }
    func disconnect() async {}
}

/// Signals that `awaitOutcome`'s poll ended with nothing recorded, which
/// cannot happen; it exists so that path fails loudly instead of answering.
private struct OutcomeVanished: Error {}

/// Thread-safe result holder for the settle poll in `awaitOutcome`.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Result<Void, Error>?
    var value: Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    func set(_ result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if _value == nil { _value = result }
    }
}
