import Foundation
import Testing
@testable import macSCPCore

@Suite("PermissionsTreeApplier")
struct PermissionsTreeApplierTests {
    private func item(_ name: String, _ path: String, _ kind: RemoteFileKind) -> RemoteFileItem {
        RemoteFileItem(name: name, path: path, kind: kind)
    }

    /// The small tree most tests share: /r (dir) with /r/a.txt (file) and
    /// /r/sub (dir) containing /r/sub/b.txt (file) — four entries total,
    /// matching the brief's `appliesSeparatePermissionsAcrossTree` shape.
    private func standardTree() -> [String: [RemoteFileItem]] {
        [
            "/r": [item("a.txt", "/r/a.txt", .file), item("sub", "/r/sub", .directory)],
            "/r/sub": [item("b.txt", "/r/sub/b.txt", .file)],
        ]
    }

    @Test func appliesSeparatePermissionsAcrossTree() async {
        let fs = RecordingFS(tree: standardTree())
        let result = await PermissionsTreeApplier.apply(
            root: "/r", kind: .directory, filePermissions: 0o644, directoryPermissions: 0o755, on: fs)

        #expect(result == PermissionsTreeResult(changed: 4))
        let calls = await fs.calls
        #expect(calls == [
            .init(path: "/r", permissions: 0o755),
            .init(path: "/r/a.txt", permissions: 0o644),
            .init(path: "/r/sub", permissions: 0o755),
            .init(path: "/r/sub/b.txt", permissions: 0o644),
        ])
    }

    @Test func samePermissionsModeUsesOneValue() async {
        let fs = RecordingFS(tree: standardTree())
        let result = await PermissionsTreeApplier.apply(
            root: "/r", kind: .directory, filePermissions: 0o700, directoryPermissions: 0o700, on: fs)

        #expect(result.changed == 4)
        let calls = await fs.calls
        #expect(calls.allSatisfy { $0.permissions == 0o700 })
        #expect(calls.count == 4)
    }

    @Test func neverTouchesSymlinks() async {
        let tree: [String: [RemoteFileItem]] = [
            "/r": [
                item("a.txt", "/r/a.txt", .file),
                item("link", "/r/link", .symlink),
                item("dirlink", "/r/dirlink", .symlink),
            ],
        ]
        let fs = RecordingFS(tree: tree)
        let result = await PermissionsTreeApplier.apply(
            root: "/r", kind: .directory, filePermissions: 0o644, directoryPermissions: 0o755, on: fs)

        #expect(result.skippedSymlinks == 2)
        #expect(result.changed == 2) // /r itself + a.txt
        let calls = await fs.calls
        #expect(calls == [
            .init(path: "/r", permissions: 0o755),
            .init(path: "/r/a.txt", permissions: 0o644),
        ])
        #expect(calls.allSatisfy { $0.path != "/r/link" && $0.path != "/r/dirlink" })
        let listCalls = await fs.listCalls
        #expect(listCalls == ["/r"]) // never listed into the symlink-to-a-directory
    }

    @Test func rootSymlinkDoesNothing() async {
        let fs = RecordingFS(tree: [:])
        let result = await PermissionsTreeApplier.apply(
            root: "/r/link", kind: .symlink, filePermissions: 0o644, directoryPermissions: 0o755, on: fs)

        #expect(result == PermissionsTreeResult(skippedSymlinks: 1))
        let calls = await fs.calls
        #expect(calls.isEmpty)
        let listCalls = await fs.listCalls
        #expect(listCalls.isEmpty)
    }

    @Test func rootFileAppliesFilePermissionsOnly() async {
        let fs = RecordingFS(tree: [:])
        let result = await PermissionsTreeApplier.apply(
            root: "/r/a.txt", kind: .file, filePermissions: 0o644, directoryPermissions: 0o755, on: fs)

        #expect(result == PermissionsTreeResult(changed: 1))
        let calls = await fs.calls
        #expect(calls == [.init(path: "/r/a.txt", permissions: 0o644)])
    }

    @Test func failedEntryCountsAndContinues() async {
        let fs = RecordingFS(tree: standardTree())
        await fs.failSetPermissions(at: "/r/a.txt", with: RemoteFSError.permissionDenied(path: "/r/a.txt"))

        let result = await PermissionsTreeApplier.apply(
            root: "/r", kind: .directory, filePermissions: 0o644, directoryPermissions: 0o755, on: fs)

        #expect(result.failed == 1)
        #expect(result.firstErrorMessage != nil)
        #expect(result.changed == 3) // /r, /r/sub, /r/sub/b.txt — a.txt is the only failure
        let calls = await fs.calls
        #expect(calls.contains(.init(path: "/r/sub/b.txt", permissions: 0o644)))
    }

    @Test func failedListingCountsAndContinues() async {
        let fs = RecordingFS(tree: standardTree())
        await fs.failList(at: "/r/sub", with: RemoteFSError.permissionDenied(path: "/r/sub"))

        let result = await PermissionsTreeApplier.apply(
            root: "/r", kind: .directory, filePermissions: 0o644, directoryPermissions: 0o755, on: fs)

        #expect(result.failed == 1)
        #expect(result.firstErrorMessage != nil)
        let calls = await fs.calls
        #expect(calls.contains(.init(path: "/r/a.txt", permissions: 0o644))) // rest of the walk still ran
    }

    @Test func cancellationStopsAndReportsPartial() async throws {
        let fs = RecordingFS(tree: standardTree())
        let reached = PlainSignal()
        await fs.blockAfterSetPermissions(at: "/r", signal: reached)

        let task = Task {
            await PermissionsTreeApplier.apply(
                root: "/r", kind: .directory, filePermissions: 0o644, directoryPermissions: 0o755, on: fs)
        }

        await reached.wait()
        task.cancel()
        let result = await task.value

        #expect(result.cancelled == true)
        #expect(result.changed == 1) // only the root's own setPermissions landed before cancellation
        #expect(result.changed < 4)
        let calls = await fs.calls
        #expect(calls == [.init(path: "/r", permissions: 0o755)])
    }

    @Test func emptyDirectoryOnlySetsItself() async {
        let fs = RecordingFS(tree: ["/r": []])
        let result = await PermissionsTreeApplier.apply(
            root: "/r", kind: .directory, filePermissions: 0o644, directoryPermissions: 0o755, on: fs)

        #expect(result == PermissionsTreeResult(changed: 1))
        let listCalls = await fs.listCalls
        #expect(listCalls == ["/r"])
    }

    @Test func progressReportsAfterEachEntry() async {
        let fs = RecordingFS(tree: standardTree())
        let recorder = ProgressRecorder()

        let result = await PermissionsTreeApplier.apply(
            root: "/r", kind: .directory, filePermissions: 0o644, directoryPermissions: 0o755, on: fs,
            progress: { recorder.record($0) })

        #expect(recorder.snapshots.count == 4) // /r, a.txt, sub, sub/b.txt
        #expect(recorder.snapshots.last == result)
    }
}

/// Recording test double: remembers every `setPermissions` call as
/// `(path, permissions)` and every `list` call by path, and can inject a
/// failure per path for either operation — exactly what the symlink-safety
/// and error-counting assertions above need to verify (M11c/T1).
private actor RecordingFS: RemoteFileSystem {
    struct Call: Equatable {
        let path: String
        let permissions: UInt32
    }

    private var tree: [String: [RemoteFileItem]]
    private(set) var calls: [Call] = []
    private(set) var listCalls: [String] = []
    private var listErrors: [String: Error] = [:]
    private var permissionErrors: [String: Error] = [:]
    private var blockPath: String?
    private var blockSignal: PlainSignal?

    init(tree: [String: [RemoteFileItem]]) {
        self.tree = tree
    }

    func failList(at path: String, with error: Error) {
        listErrors[path] = error
    }

    func failSetPermissions(at path: String, with error: Error) {
        permissionErrors[path] = error
    }

    /// After recording the call for `path`, fires `signal` and then spins
    /// cancellation-UNAWARE (mirrors `RecordingSpinDestination` in
    /// TransferEngineTests) until the enclosing Task is cancelled — lets a
    /// test cancel deterministically right after this one call completes,
    /// with no race on whether the cancellation lands before the walk's
    /// next `Task.isCancelled` check.
    func blockAfterSetPermissions(at path: String, signal: PlainSignal) {
        blockPath = path
        blockSignal = signal
    }

    func list(path: String) async throws -> [RemoteFileItem] {
        listCalls.append(path)
        if let error = listErrors[path] {
            throw error
        }
        return tree[path] ?? []
    }

    func setPermissions(path: String, permissions: UInt32) async throws {
        if let error = permissionErrors[path] {
            throw error
        }
        calls.append(Call(path: path, permissions: permissions))
        if path == blockPath, let signal = blockSignal {
            signal.fire()
            while !Task.isCancelled { await Task.yield() }
        }
    }

    func stat(path: String) async throws -> RemoteFileItem {
        throw RemoteFSError.protocolError(reason: "unsupported in this test double")
    }

    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        throw RemoteFSError.protocolError(reason: "unsupported in this test double")
    }

    func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {
        throw RemoteFSError.protocolError(reason: "unsupported in this test double")
    }

    func delete(path: String) async throws {
        throw RemoteFSError.protocolError(reason: "unsupported in this test double")
    }

    func createDirectory(at path: String) async throws {
        throw RemoteFSError.protocolError(reason: "unsupported in this test double")
    }

    func rename(from: String, to: String) async throws {
        throw RemoteFSError.protocolError(reason: "unsupported in this test double")
    }

    func deleteTree(at path: String) async throws {
        throw RemoteFSError.protocolError(reason: "unsupported in this test double")
    }

    func homeDirectoryPath() async throws -> String { "/" }

    func disconnect() async {}
}

/// Cancellation-INDEPENDENT one-shot signal (mirrors `PlainSignal` in
/// TransferEngineTests): `wait()` ignores task cancellation on the WAITING
/// side, since it is the walker's own `Task.isCancelled` checks — not this
/// signal — that must observe cancellation in these tests.
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

/// Thread-safe capture of every `progress` snapshot, in call order (mirrors
/// `ProgressRecorder` in TransferEngineTests).
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshots: [PermissionsTreeResult] = []
    var snapshots: [PermissionsTreeResult] {
        lock.lock()
        defer { lock.unlock() }
        return _snapshots
    }
    func record(_ r: PermissionsTreeResult) {
        lock.lock()
        defer { lock.unlock() }
        _snapshots.append(r)
    }
}
