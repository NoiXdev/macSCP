import Foundation
import Testing
@testable import macSCPCore

@Suite("TransferEngine")
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
        await reached.wait()
        task.cancel()

        // Timeout race so that a (regressed) missing cancellation doesn't
        // leave the test hanging forever.
        let outcome = await awaitOutcome(task)
        guard case .failure(let error)? = outcome else {
            Issue.record("expected CancellationError, was: \(String(describing: outcome))")
            return
        }
        #expect(error is CancellationError)

        let written = await destination.chunkCount
        #expect(written == 1)                // no further chunk after the cancel point
        #expect(written < chunkTotal)         // not all chunks transferred
    }

    // MARK: - Bandwidth Throttle (M5c/T5)

    /// A limit of 256 KB/s over 1 MiB (= 16 chunks of 64 KiB) must yield a
    /// total of ~4s of requested sleep (1_048_576 / (256*1024) == 4.0). The
    /// injected `sleep` hook does NOT actually sleep — it only accumulates
    /// the requested durations, making the test deterministic instead of
    /// dependent on real timing (no flakiness risk).
    @Test func throttleRequestsExpectedTotalSleepDuration() async throws {
        let content = Data(repeating: 0x42, count: 1024 * 1024)
        let source = makeSource(content: content)
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])

        let recorder = SleepRecorder()
        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            bytesPerSecondLimit: 256 * 1024,
            sleep: { duration in recorder.record(duration) },
            onProgress: { _ in }
        )

        #expect(await destination.writtenData(at: "/ziel/quelle.bin") == content)
        let totalSeconds = recorder.totalSeconds
        // Tolerance window instead of exact equality (Double rounding over 16
        // additions) — the binding requirement was "duration ≥ ~3.5s"; the
        // virtual model yields exactly 4.0s here, a tight window covers that
        // plus a bit of margin.
        #expect(totalSeconds >= 3.5)
        #expect(totalSeconds <= 4.5)
    }

    /// `bytesPerSecondLimit == 0` (default) is left untouched: not a single
    /// sleep call, exactly the pre-T5 behavior.
    @Test func noThrottleWithoutLimitNeverSleeps() async throws {
        let content = Data(repeating: 0x1, count: TransferChunk.size * 2)
        let source = makeSource(content: content)
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])

        let recorder = SleepRecorder()
        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            sleep: { duration in recorder.record(duration) },
            onProgress: { _ in }
        )
        #expect(recorder.callCount == 0)
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

        await reached.wait()
        task.cancel()

        let outcome = await awaitOutcome(task)
        guard case .failure(let error)? = outcome else {
            Issue.record("expected CancellationError, was: \(String(describing: outcome))")
            return
        }
        #expect(error is CancellationError)

        let written = await destination.chunkCount
        #expect(written == 1)
        #expect(written < chunkTotal)
        #expect(await destination.recordedMode == .append)
    }

    /// Waits for the task's result, but returns `nil` after `timeout`
    /// (timeout) instead of blocking forever.
    private func awaitOutcome(
        _ task: Task<Void, Error>, timeout: Duration = .seconds(2)
    ) async -> Result<Void, Error>? {
        let box = ResultBox()
        Task {
            do { try await task.value; box.set(.success(())) }
            catch { box.set(.failure(error)) }
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let result = box.value { return result }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return box.value   // nil ⇒ timeout
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

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
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
    func disconnect() async {}
}

/// Accumulates the durations passed to the injected `sleep` hook WITHOUT
/// actually sleeping (M5c/T5) — makes the throttle test deterministic
/// instead of dependent on real timing.
private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _totalSeconds: Double = 0
    private var _callCount = 0
    var totalSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return _totalSeconds
    }
    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }
    func record(_ duration: Duration) {
        lock.lock()
        _totalSeconds += duration.secondsAsDouble
        _callCount += 1
        lock.unlock()
    }
}

/// Thread-safe result holder for the timeout race in `awaitOutcome`.
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
