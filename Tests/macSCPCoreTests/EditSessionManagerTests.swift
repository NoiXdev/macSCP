import Foundation
import Testing
@testable import macSCPCore

@Suite("EditSessionManager")
@MainActor
struct EditSessionManagerTests {

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
