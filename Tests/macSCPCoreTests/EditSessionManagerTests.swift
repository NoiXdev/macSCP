import Foundation
import Testing
@testable import macSCPCore

@Suite("EditSessionManager")
@MainActor
struct EditSessionManagerTests {

    // MARK: - Test signal (same pattern as TransferQueueViewModelTests/TransferEngineTests)

    /// One-shot async gate: `wait()` suspends until `fire()` is called (or
    /// resolves immediately if `fire()` already happened). Lets a test pin a
    /// mock download mid-flight without a real sleep.
    actor TestSignal {
        private var fired = false
        private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]

        func fire() {
            fired = true
            let pending = continuations
            continuations.removeAll()
            for continuation in pending.values { continuation.resume() }
        }

        func wait() async throws {
            if fired { return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if fired {
                        continuation.resume()
                    } else if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuations[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
        }

        private func cancelWaiter(_ id: UUID) {
            if let continuation = continuations.removeValue(forKey: id) {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// Wraps a `MockRemoteFileSystem` and gates `readStream` on `TestSignal`s
    /// so a test can pause a download mid-flight — `entered` fires as soon as
    /// the read starts, `gate` (if set) blocks the read until released. Also
    /// counts `readStream` calls, the basis of the "downloads once" assertion.
    actor GatedRemoteFileSystem: RemoteFileSystem {
        private let inner: MockRemoteFileSystem
        private let entered: TestSignal?
        private let gate: TestSignal?
        private(set) var readStreamCallCount = 0

        init(inner: MockRemoteFileSystem, entered: TestSignal? = nil, gate: TestSignal? = nil) {
            self.inner = inner
            self.entered = entered
            self.gate = gate
        }

        func list(path: String) async throws -> [RemoteFileItem] {
            try await inner.list(path: path)
        }

        func stat(path: String) async throws -> RemoteFileItem {
            try await inner.stat(path: path)
        }

        func readStream(path: String, fromOffset offset: UInt64) async throws -> AsyncThrowingStream<Data, Error> {
            readStreamCallCount += 1
            await entered?.fire()
            if let gate { try await gate.wait() }
            return try await inner.readStream(path: path, fromOffset: offset)
        }

        func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {
            try await inner.write(path: path, mode: mode, contents: contents)
        }

        func delete(path: String) async throws {
            try await inner.delete(path: path)
        }

        func createDirectory(at path: String) async throws {
            try await inner.createDirectory(at: path)
        }

        func disconnect() async {
            await inner.disconnect()
        }
    }

    // MARK: - Helpers

    /// Number of upload items currently in the queue (the write-backs).
    private func uploadCount(_ queue: TransferQueueViewModel) -> Int {
        queue.items.filter { $0.direction == .upload }.count
    }

    /// Number of download items currently in the queue.
    private func downloadCount(_ queue: TransferQueueViewModel) -> Int {
        queue.items.filter { $0.direction == .download }.count
    }

    /// Polls (with `Task.yield`) for a condition so tests don't sleep on the
    /// real clock. Bounded so a regression fails instead of hanging.
    private func waitUntil(
        _ condition: @MainActor () -> Bool, limit: Int = 200_000
    ) async {
        var iterations = 0
        while !condition() && iterations < limit {
            await Task.yield()
            iterations += 1
        }
    }

    /// Remote source/destination double for one file under `/dir/<name>`. The
    /// tree entry lets the transfer engine `stat` the source for its size.
    private func makeRemote(name: String, content: Data) -> MockRemoteFileSystem {
        MockRemoteFileSystem(
            tree: ["/dir": [
                RemoteFileItem(name: name, path: "/dir/\(name)", kind: .file, size: UInt64(content.count)),
            ]],
            files: ["/dir/\(name)": content])
    }

    // MARK: - 1: download via the queue, return URL

    @Test func beginEditingDownloadsViaQueueAndReturnsURL() async throws {
        let content = Data("remote content".utf8)
        let remote = makeRemote(name: "a.txt", content: content)
        let queue = TransferQueueViewModel()
        let manager = EditSessionManager(
            sessionID: UUID(), queue: queue,
            debounceInterval: .zero, sleep: { _ in })

        let url = try await manager.beginEditing(
            remotePath: "/dir/a.txt", fileName: "a.txt",
            source: remote, destinationForUploads: remote)

        // The download appears in the bar as exactly one finished download.
        #expect(downloadCount(queue) == 1)
        #expect(queue.items.first(where: { $0.direction == .download })?.status == .finished)
        // The local file exists with the remote's content.
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(try Data(contentsOf: url) == content)
        #expect(manager.activeEdits.count == 1)
        #expect(manager.activeEdits.first?.remotePath == "/dir/a.txt")

        await manager.stopAll()
    }

    // MARK: - 2: re-editing the same path reuses the local copy

    @Test func beginEditingTwiceReturnsSameURLNoSecondDownload() async throws {
        let content = Data("x".utf8)
        let remote = makeRemote(name: "a.txt", content: content)
        let queue = TransferQueueViewModel()
        let manager = EditSessionManager(
            sessionID: UUID(), queue: queue,
            debounceInterval: .zero, sleep: { _ in })

        let first = try await manager.beginEditing(
            remotePath: "/dir/a.txt", fileName: "a.txt",
            source: remote, destinationForUploads: remote)
        let second = try await manager.beginEditing(
            remotePath: "/dir/a.txt", fileName: "a.txt",
            source: remote, destinationForUploads: remote)

        #expect(first == second)
        #expect(downloadCount(queue) == 1)          // NO second download
        #expect(manager.activeEdits.count == 1)

        await manager.stopAll()
    }

    // MARK: - 2b: two OVERLAPPING beginEditing calls for the same path (the
    // race a post-download-only "already editing" registration misses)
    // download exactly once (M5e/T3 fix).

    @Test func concurrentBeginEditingSameFileDownloadsOnce() async throws {
        let content = Data("v1".utf8)
        let remote = makeRemote(name: "a.txt", content: content)
        let entered = TestSignal()
        let gate = TestSignal()
        let gated = GatedRemoteFileSystem(inner: remote, entered: entered, gate: gate)
        let queue = TransferQueueViewModel()
        let manager = EditSessionManager(
            sessionID: UUID(), queue: queue,
            debounceInterval: .zero, sleep: { _ in })

        // First call starts the download and blocks on `gate` mid-`readStream`.
        async let first = manager.beginEditing(
            remotePath: "/dir/a.txt", fileName: "a.txt",
            source: gated, destinationForUploads: gated)
        try await entered.wait()

        // Second, OVERLAPPING call for the SAME remotePath — fired while the
        // first download is still in flight (the "fast double-double-click").
        async let second = manager.beginEditing(
            remotePath: "/dir/a.txt", fileName: "a.txt",
            source: gated, destinationForUploads: gated)
        // Give the second call a beat to actually reach (and be reserved
        // behind) the first call's in-flight entry before releasing the gate.
        for _ in 0..<50 { await Task.yield() }

        await gate.fire()

        let firstURL = try await first
        let secondURL = try await second

        // Same URL, exactly one download, exactly one registered edit.
        #expect(firstURL == secondURL)
        #expect(await gated.readStreamCallCount == 1)
        #expect(downloadCount(queue) == 1)
        #expect(manager.activeEdits.count == 1)

        // Exactly one watcher: a single subsequent file change produces
        // exactly ONE upload (two watchers on the same fd would double it).
        let editID = try #require(manager.activeEdits.first?.id)
        try Data("v2".utf8).write(to: firstURL)
        manager.handleFileEvent(editID: editID)

        await waitUntil { uploadCount(queue) == 1 }
        #expect(uploadCount(queue) == 1)

        await manager.stopAll()
    }

    // MARK: - 3: a detected change triggers exactly one upload after debounce

    @Test func fileChangeTriggersOneUploadAfterDebounce() async throws {
        let content = Data("v1".utf8)
        let remote = makeRemote(name: "a.txt", content: content)
        let queue = TransferQueueViewModel()
        let manager = EditSessionManager(
            sessionID: UUID(), queue: queue,
            debounceInterval: .zero, sleep: { _ in })

        let url = try await manager.beginEditing(
            remotePath: "/dir/a.txt", fileName: "a.txt",
            source: remote, destinationForUploads: remote)
        let editID = try #require(manager.activeEdits.first?.id)

        // Locally edit the file, then feed the watcher's event path directly
        // (the DispatchSource layer is a thin seam over `handleFileEvent`).
        try Data("v2".utf8).write(to: url)
        manager.handleFileEvent(editID: editID)

        await waitUntil { uploadCount(queue) == 1 }
        #expect(uploadCount(queue) == 1)
        await waitUntil { queue.items.first(where: { $0.direction == .upload })?.status == .finished }
        #expect(await remote.writtenData(at: "/dir/a.txt") == Data("v2".utf8))

        await manager.stopAll()
    }

    // MARK: - 4: two fast changes coalesce into a single upload

    @Test func twoFastChangesTriggerSingleUpload() async throws {
        let remote = makeRemote(name: "a.txt", content: Data("v1".utf8))
        let queue = TransferQueueViewModel()
        let manager = EditSessionManager(
            sessionID: UUID(), queue: queue,
            debounceInterval: .zero, sleep: { _ in })

        let url = try await manager.beginEditing(
            remotePath: "/dir/a.txt", fileName: "a.txt",
            source: remote, destinationForUploads: remote)
        let editID = try #require(manager.activeEdits.first?.id)

        try Data("v2".utf8).write(to: url)
        // Two events back-to-back on the MainActor: the first debounce task is
        // cancelled by the second before it can fire — one upload survives.
        manager.handleFileEvent(editID: editID)
        manager.handleFileEvent(editID: editID)

        await waitUntil { uploadCount(queue) == 1 }
        #expect(uploadCount(queue) == 1)

        await manager.stopAll()
    }

    // MARK: - 5: stopAll deletes the temp dir and silences further events

    @Test func stopAllDeletesTempDirAndSilencesEvents() async throws {
        let remote = makeRemote(name: "a.txt", content: Data("v1".utf8))
        let queue = TransferQueueViewModel()
        let manager = EditSessionManager(
            sessionID: UUID(), queue: queue,
            debounceInterval: .zero, sleep: { _ in })

        let url = try await manager.beginEditing(
            remotePath: "/dir/a.txt", fileName: "a.txt",
            source: remote, destinationForUploads: remote)
        let editID = try #require(manager.activeEdits.first?.id)

        await manager.stopAll()

        // Temp file (and its directory) are gone.
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(manager.activeEdits.isEmpty)

        // A further event for the (now stopped) edit triggers nothing.
        manager.handleFileEvent(editID: editID)
        // Give any (wrongly) scheduled debounce task a chance to run.
        for _ in 0..<50 { await Task.yield() }
        #expect(uploadCount(queue) == 0)

        // stopAll is idempotent.
        await manager.stopAll()
    }

    // MARK: - 6: pathHash is deterministic and filesystem-safe

    @Test func pathHashIsStableAndSafe() {
        #expect(EditSessionManager.pathHash("/dir/a.txt") == EditSessionManager.pathHash("/dir/a.txt"))
        #expect(EditSessionManager.pathHash("/dir/a.txt") != EditSessionManager.pathHash("/dir/b.txt"))
        let hash = EditSessionManager.pathHash("/some/deep/path with spaces/x.y")
        #expect(!hash.isEmpty)
        #expect(!hash.contains("/"))
    }

    // MARK: - 7: atomic save (rename-swap) survival with a REAL DispatchSource

    /// Integration-style: uses a real `DispatchSource` on a real temp file. An
    /// editor's atomic save replaces the watched file via `rename`, unlinking
    /// the inode our fd points at; the watcher must reopen at the same path and
    /// keep firing. Assertions are retry-friendly (bounded polling), not timed.
    @Test func atomicSaveSurvivesReopenAndUploads() async throws {
        let content = Data("v1".utf8)
        let remote = makeRemote(name: "a.txt", content: content)
        let queue = TransferQueueViewModel()
        // Real DispatchSource + real (short) debounce so the reopen path runs
        // end to end without a slow 500 ms wait.
        let manager = EditSessionManager(
            sessionID: UUID(), queue: queue,
            debounceInterval: .milliseconds(10))

        let url = try await manager.beginEditing(
            remotePath: "/dir/a.txt", fileName: "a.txt",
            source: remote, destinationForUploads: remote)
        let path = url.path(percentEncoded: false)

        // Atomic save: write a sibling temp file and rename it over the target.
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("a.txt.sb-tmp", isDirectory: false)
        try Data("v2".utf8).write(to: tmp)
        #expect(rename(tmp.path(percentEncoded: false), path) == 0)

        // The rename event must reach us and produce an upload.
        await waitUntil { uploadCount(queue) >= 1 }
        #expect(uploadCount(queue) >= 1)

        // Prove the watcher SURVIVED: modify the replacement file in place and
        // expect a further upload from the reopened descriptor.
        let uploadsAfterRename = uploadCount(queue)
        // Small settle so the reopen has attached before the next write.
        for _ in 0..<200 { await Task.yield() }
        try Data("v3".utf8).write(to: url)

        await waitUntil { uploadCount(queue) > uploadsAfterRename }
        #expect(uploadCount(queue) > uploadsAfterRename)

        await manager.stopAll()
    }
}
