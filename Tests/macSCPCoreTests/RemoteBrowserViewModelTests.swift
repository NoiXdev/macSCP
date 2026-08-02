import Foundation
import Testing
@testable import macSCPCore

@Suite("RemoteBrowserViewModel")
@MainActor
struct RemoteBrowserViewModelTests {
    private func makeFS() -> MockRemoteFileSystem {
        MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(name: "zebra.txt", path: "/zebra.txt", kind: .file, size: 1),
                RemoteFileItem(name: "Alpha", path: "/Alpha", kind: .directory),
                RemoteFileItem(name: "beta.txt", path: "/beta.txt", kind: .file, size: 2),
            ],
            "/Alpha": [
                RemoteFileItem(name: "inner.md", path: "/Alpha/inner.md", kind: .file, size: 3),
            ],
        ])
    }

    @Test func loadSortsDirectoriesFirstThenCaseInsensitive() async {
        let vm = RemoteBrowserViewModel(fs: makeFS())
        await vm.load()
        #expect(vm.state == .loaded)
        #expect(vm.items.map(\.name) == ["Alpha", "beta.txt", "zebra.txt"])
    }

    @Test func openDirectoryNavigatesAndLoads() async {
        let vm = RemoteBrowserViewModel(fs: makeFS())
        await vm.load()
        let alpha = vm.items[0]
        await vm.open(alpha)
        #expect(vm.currentPath == "/Alpha")
        #expect(vm.items.map(\.name) == ["inner.md"])
    }

    @Test func openFileIsNoOp() async {
        let vm = RemoteBrowserViewModel(fs: makeFS())
        await vm.load()
        let file = vm.items[1]
        await vm.open(file)
        #expect(vm.currentPath == "/")
    }

    @Test func goUpNavigatesToParent() async {
        let vm = RemoteBrowserViewModel(fs: makeFS(), startPath: "/Alpha")
        await vm.load()
        #expect(vm.canGoUp)
        await vm.goUp()
        #expect(vm.currentPath == "/")
        #expect(vm.items.count == 3)
    }

    @Test func goUpAtRootIsNoOp() async {
        let vm = RemoteBrowserViewModel(fs: makeFS())
        await vm.load()
        #expect(!vm.canGoUp)
        await vm.goUp()
        #expect(vm.currentPath == "/")
    }

    @Test func missingPathYieldsLocalizedNotFoundMessage() async {
        let vm = RemoteBrowserViewModel(fs: makeFS(), startPath: "/nope")
        await vm.load()
        #expect(vm.state == .failed(
            message: String(format: CoreL10n.string("core.browse.notFound %@"), "/nope")))
        #expect(vm.items.isEmpty)
    }

    @Test func navigationResetsSelection() async {
        let vm = RemoteBrowserViewModel(fs: makeFS())
        await vm.load()
        vm.selectedItems = [vm.items[1]]
        await vm.open(vm.items[0])
        #expect(vm.selectedItem == nil)
    }

    // MARK: - Hidden files (M7a Task 4)

    @Test func loadFiltersDotfilesUnlessShowHiddenIsOn() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(name: ".env", path: "/.env", kind: .file, size: 1),
                RemoteFileItem(name: "visible.txt", path: "/visible.txt", kind: .file, size: 1),
            ],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        #expect(vm.items.map(\.name) == ["visible.txt"])
        vm.showHiddenFiles = true
        await vm.load()
        #expect(vm.items.map(\.name) == [".env", "visible.txt"])
    }

    @Test @MainActor func selectedItemDerivesFromSelectedItems() async {
        let vm = RemoteBrowserViewModel(fs: MockRemoteFileSystem())
        let a = RemoteFileItem(name: "a", path: "/a", kind: .file, size: 1)
        let b = RemoteFileItem(name: "b", path: "/b", kind: .file, size: 1)
        vm.selectedItems = [a]
        #expect(vm.selectedItem == a)
        vm.selectedItems = [a, b]
        #expect(vm.selectedItem == nil)
        vm.selectedItems = []
        #expect(vm.selectedItem == nil)
    }

    // MARK: - Browser actions (M7b Task 1)

    @Test func renameRefreshesAndFollowsSelection() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "old.txt", path: "/old.txt", kind: .file, size: 1)],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        let old = vm.items[0]
        let error = await vm.rename(old, to: "new.txt")
        #expect(error == nil)
        await vm.refreshAndSelect(path: "/new.txt")
        #expect(vm.items.map(\.name) == ["new.txt"])
        #expect(vm.selectedItems.map(\.name) == ["new.txt"])
    }

    @Test func renameCollisionReturnsLocalizedMessage() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file, size: 1),
                RemoteFileItem(name: "b.txt", path: "/b.txt", kind: .file, size: 1),
            ],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        let error = await vm.rename(vm.items[0], to: "b.txt")
        #expect(error != nil)
        #expect(vm.items.count == 2)   // nothing changed
    }

    @Test func invalidNamesAreRejected() {
        #expect(!RemoteBrowserViewModel.isValidEntryName(""))
        #expect(!RemoteBrowserViewModel.isValidEntryName("a/b"))
        #expect(!RemoteBrowserViewModel.isValidEntryName("."))
        #expect(!RemoteBrowserViewModel.isValidEntryName(".."))
        #expect(RemoteBrowserViewModel.isValidEntryName(".env"))
        #expect(RemoteBrowserViewModel.isValidEntryName("normal name.txt"))
    }

    @Test func deleteItemsRemovesAllAndRefreshes() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file, size: 1),
                RemoteFileItem(name: "dir", path: "/dir", kind: .directory),
                RemoteFileItem(name: "keep.txt", path: "/keep.txt", kind: .file, size: 1),
            ],
            "/dir": [RemoteFileItem(name: "x.txt", path: "/dir/x.txt", kind: .file, size: 1)],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        let doomed = vm.items.filter { $0.name != "keep.txt" }
        let error = await vm.deleteItems(doomed)
        #expect(error == nil)
        #expect(vm.items.map(\.name) == ["keep.txt"])
        #expect(vm.selectedItems.isEmpty)
    }

    @Test func createFolderRefreshesAndSelects() async {
        let fs = MockRemoteFileSystem(tree: ["/": []])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        let error = await vm.createFolder(named: "fresh")
        #expect(error == nil)
        await vm.refreshAndSelect(path: "/fresh")
        #expect(vm.items.map(\.name) == ["fresh"])
        #expect(vm.selectedItems.map(\.name) == ["fresh"])
    }

    // MARK: - Operation does not wait on the listing (M18a)

    @Test func createFolderReturnsWithoutRefreshingTheListing() async {
        let fs = MockRemoteFileSystem(tree: ["/": []])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        let listsAfterLoad = await fs.listCallCounts["/"] ?? 0

        let error = await vm.createFolder(named: "fresh")
        #expect(error == nil)
        // The create must NOT have triggered another listing — dismissing the
        // sheet may not wait on it.
        #expect(await fs.listCallCounts["/"] ?? 0 == listsAfterLoad)
    }

    @Test func refreshAndSelectRefreshesAndSelectsTheNewEntry() async {
        let fs = MockRemoteFileSystem(tree: ["/": []])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        _ = await vm.createFolder(named: "fresh")

        await vm.refreshAndSelect(path: RemotePath.join(vm.currentPath, "fresh"))
        #expect(vm.items.contains { $0.name == "fresh" })
        #expect(vm.selectedItems.map(\.name) == ["fresh"])
    }

    // MARK: - createFile (M18a)

    @Test func createFileCreatesAnEmptyFileAndReportsSuccess() async {
        let fs = MockRemoteFileSystem(tree: ["/": []])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()

        let error = await vm.createFile(named: "notes.txt")
        #expect(error == nil)
        // The DEFINITE "not found" from the probe is the only verdict that
        // may proceed to the write — and it must actually write.
        #expect(await fs.writeModes["/notes.txt"] == .overwrite)
        await vm.refreshAndSelect(path: RemotePath.join(vm.currentPath, "notes.txt"))
        #expect(vm.items.contains { $0.name == "notes.txt" })
    }

    @Test func createFileCollisionReturnsError() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "taken.txt", path: "/taken.txt", kind: .file, size: 0)],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        let error = await vm.createFile(named: "taken.txt")
        #expect(error != nil)
        #expect(await fs.writeModes["/taken.txt"] == nil)
    }

    /// Regression (M18a final review, Important-1): the existence probe used
    /// to be `if (try? await fs.stat(path:)) != nil`, which collapses
    /// `permissionDenied`/`protocolError`/a dropped connection into the same
    /// "nothing there" verdict as a genuine "not found" — and the write that
    /// follows is `.overwrite`, i.e. a truncation. A server that denies
    /// `SSH_FXP_STAT`, or an S3 bucket that grants `s3:PutObject` but not
    /// `s3:ListBucket` (`S3FileSystem.stat` is a `ListObjectsV2` under the
    /// hood, and a 403 there maps to `.authenticationFailed`, NOT
    /// `.notFound`), would silently blank an existing file. Only a definite
    /// "does not exist" may proceed; anything else must surface as an error
    /// with the sheet left open, and must not write a single byte.
    @Test func createFileFailsWithoutWritingWhenExistenceCannotBeVerified() async throws {
        let existing = Data("important".utf8)
        let fs = MockRemoteFileSystem(
            tree: ["/": [RemoteFileItem(
                name: "notes.txt", path: "/notes.txt", kind: .file,
                size: UInt64(existing.count))]],
            files: ["/notes.txt": existing])
        let vm = RemoteBrowserViewModel(fs: fs)
        let capture = EventCapture()
        vm.auditSink = { capture.record($0) }
        await vm.load()
        await fs.setStatFailure(RemoteFSError.permissionDenied(path: "/notes.txt"), at: "/notes.txt")

        let error = await vm.createFile(named: "notes.txt")

        #expect(error == RemoteBrowserViewModel.message(
            for: RemoteFSError.permissionDenied(path: "/notes.txt"), path: "/notes.txt"))
        // No write at all — neither recorded nor applied to the content.
        #expect(await fs.writeModes["/notes.txt"] == nil)
        #expect(await fs.writtenData(at: "/notes.txt") == nil)
        var readBack = Data()
        for try await chunk in try await fs.readStream(path: "/notes.txt", fromOffset: 0) {
            readBack.append(chunk)
        }
        #expect(readBack == existing)
        #expect(capture.events.count == 1)
        #expect(capture.events[0].kind == .newFile)
        #expect(capture.events[0].isError == true)
        #expect(capture.events[0].errorMessage == error)
    }

    /// The deliberate asymmetry to the test above (M18a final review): the
    /// SAME probe guards `createFolder`, but `createDirectory` is idempotent
    /// by contract — it cannot destroy data — so an unverifiable probe there
    /// still proceeds and lets the real `createDirectory` decide, keeping
    /// that path's user-visible messages exactly as they were.
    @Test func createFolderStillProceedsWhenExistenceCannotBeVerified() async {
        let fs = MockRemoteFileSystem(tree: ["/": []])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        await fs.setStatFailure(RemoteFSError.permissionDenied(path: "/neu"), at: "/neu")

        let error = await vm.createFolder(named: "neu")

        #expect(error == nil)
        #expect(await fs.createdDirectories == ["/neu"])
    }

    /// Same operation/refresh split as `createFolder` (M18a): `createFile`
    /// must not trigger a listing on its own — dismissing the sheet may not
    /// wait on it.
    @Test func createFileReturnsWithoutRefreshingTheListing() async {
        let fs = MockRemoteFileSystem(tree: ["/": []])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        let listsAfterLoad = await fs.listCallCounts["/"] ?? 0

        let error = await vm.createFile(named: "notes.txt")
        #expect(error == nil)
        #expect(await fs.listCallCounts["/"] ?? 0 == listsAfterLoad)
    }

    // MARK: - applyPermissions (M7b Task 1 review follow-up)

    @Test func applyPermissionsSucceedsAndRefreshes() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file, size: 1)],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        let item = vm.items[0]
        vm.selectedItems = [item]   // so we can observe load() resetting it
        let error = await vm.applyPermissions(0o640, to: item)
        #expect(error == nil)
        let recorded = await fs.permissionsByPath[item.path]
        #expect(recorded == 0o640)
        #expect(vm.selectedItems.isEmpty)          // load() ran and reset selection
        #expect(vm.items.map(\.name) == ["a.txt"])  // reload succeeded
    }

    @Test func applyPermissionsFailureReturnsLocalizedMessage() async {
        let fs = MockRemoteFileSystem(tree: ["/": []])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        // Not seeded anywhere in the mock tree -> setPermissions throws notFound.
        let ghost = RemoteFileItem(name: "ghost.txt", path: "/ghost.txt", kind: .file, size: 1)
        let error = await vm.applyPermissions(0o640, to: ghost)
        #expect(error != nil)
    }

    // MARK: - createFolder collisions (M7b Task 1 review follow-up)

    @Test func createFolderCollisionWithVisibleDirReturnsError() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "taken", path: "/taken", kind: .directory)],
            "/taken": [],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        let itemsBefore = vm.items.map(\.name)
        let error = await vm.createFolder(named: "taken")
        #expect(error != nil)
        #expect(vm.items.map(\.name) == itemsBefore)
    }

    /// Regression test for the adjudicated `fs.stat`-based collision probe
    /// (see the deviation note in the M7b Task 1 report): a directory
    /// collision that is a HIDDEN dotfile must still be caught even though
    /// it is filtered out of `vm.items` by the hidden-files display filter.
    @Test func createFolderCollisionWithHiddenDotfileDirReturnsError() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: ".config", path: "/.config", kind: .directory)],
            "/.config": [],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        // showHiddenFiles defaults to false.
        await vm.load()
        #expect(vm.items.isEmpty)   // the dotfile dir is not in the display list
        let error = await vm.createFolder(named: ".config")
        #expect(error != nil)
    }

    // MARK: - deleteItems stop-at-first-failure (M7b Task 1 review follow-up)

    @Test func deleteItemsStopsAtFirstFailureLeavingLaterItemsUntouched() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file, size: 1),
                RemoteFileItem(name: "c.txt", path: "/c.txt", kind: .file, size: 1),
            ],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        let a = vm.items.first(where: { $0.name == "a.txt" })!
        let c = vm.items.first(where: { $0.name == "c.txt" })!
        // Stale item: never seeded in the mock tree, so `deleteTree` throws
        // `notFound` for it — a real failure mode, not injected mock machinery.
        let staleB = RemoteFileItem(name: "b.txt", path: "/b.txt", kind: .file, size: 1)
        let error = await vm.deleteItems([a, staleB, c])
        #expect(error != nil)
        #expect(vm.items.map(\.name) == ["c.txt"])   // a deleted, loop stopped before c
    }

    // MARK: - auditSink (M9b/T2)

    @MainActor final class EventCapture {
        private(set) var events: [AuditEvent] = []
        func record(_ event: AuditEvent) { events.append(event) }
    }

    /// Thread-safe capture of `applyPermissionsRecursively`'s `progress`
    /// snapshots (M11c/T2) — the callback is `@Sendable` and may fire from
    /// off the main actor, mirroring `ProgressRecorder` in
    /// `PermissionsTreeApplierTests`.
    private final class RecursiveProgressCapture: @unchecked Sendable {
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

    /// Cancellation-INDEPENDENT one-shot signal (mirrors `PlainSignal` in
    /// `PermissionsTreeApplierTests`/`TransferEngineTests`, duplicated per
    /// file per that established convention): `wait()` ignores task
    /// cancellation on the WAITING side, since it is the walker's own
    /// `Task.isCancelled` checks — not this signal — that must observe
    /// cancellation in `recursiveApplyMarksCancelledRunAndStillReloads`.
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

    @Test func renameSuccessFiresRenameEvent() async throws {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "old.txt", path: "/old.txt", kind: .file, size: 1)],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        let capture = EventCapture()
        vm.auditSink = { capture.record($0) }
        await vm.load()

        let error = await vm.rename(vm.items[0], to: "new.txt")

        #expect(error == nil)
        #expect(capture.events.count == 1)
        #expect(capture.events[0].kind == .rename)
        #expect(capture.events[0].isError == false)
        #expect(capture.events[0].detail.contains("/old.txt"))
        #expect(capture.events[0].detail.contains("new.txt"))
    }

    @Test func renameFailureFiresIsErrorEventWithLocalizedMessage() async throws {
        let fs = MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file, size: 1),
                RemoteFileItem(name: "b.txt", path: "/b.txt", kind: .file, size: 1),
            ],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        let capture = EventCapture()
        vm.auditSink = { capture.record($0) }
        await vm.load()

        let error = await vm.rename(vm.items[0], to: "b.txt")

        #expect(error != nil)
        #expect(capture.events.count == 1)
        #expect(capture.events[0].kind == .rename)
        #expect(capture.events[0].isError == true)
        #expect(capture.events[0].errorMessage == error)
    }

    @Test func createFolderSuccessFiresNewFolderEventWithFullPath() async throws {
        let fs = MockRemoteFileSystem(tree: ["/": []])
        let vm = RemoteBrowserViewModel(fs: fs)
        let capture = EventCapture()
        vm.auditSink = { capture.record($0) }
        await vm.load()

        let error = await vm.createFolder(named: "fresh")

        #expect(error == nil)
        #expect(capture.events.count == 1)
        #expect(capture.events[0].kind == .newFolder)
        #expect(capture.events[0].detail.contains("/fresh"))
        #expect(capture.events[0].isError == false)
    }

    @Test func createFolderCollisionFiresIsErrorNewFolderEvent() async throws {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "taken", path: "/taken", kind: .directory)],
            "/taken": [],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        let capture = EventCapture()
        vm.auditSink = { capture.record($0) }
        await vm.load()

        let error = await vm.createFolder(named: "taken")

        #expect(error != nil)
        #expect(capture.events.count == 1)
        #expect(capture.events[0].kind == .newFolder)
        #expect(capture.events[0].isError == true)
        #expect(capture.events[0].errorMessage == error)
    }

    @Test func createFileSuccessFiresNewFileEventWithFullPath() async throws {
        let fs = MockRemoteFileSystem(tree: ["/": []])
        let vm = RemoteBrowserViewModel(fs: fs)
        let capture = EventCapture()
        vm.auditSink = { capture.record($0) }
        await vm.load()

        let error = await vm.createFile(named: "notes.txt")

        #expect(error == nil)
        #expect(capture.events.count == 1)
        #expect(capture.events[0].kind == .newFile)
        #expect(capture.events[0].detail.contains("/notes.txt"))
        #expect(capture.events[0].isError == false)
    }

    @Test func createFileCollisionFiresIsErrorNewFileEvent() async throws {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "taken.txt", path: "/taken.txt", kind: .file, size: 0)],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        let capture = EventCapture()
        vm.auditSink = { capture.record($0) }
        await vm.load()

        let error = await vm.createFile(named: "taken.txt")

        #expect(error != nil)
        #expect(capture.events.count == 1)
        #expect(capture.events[0].kind == .newFile)
        #expect(capture.events[0].isError == true)
        #expect(capture.events[0].errorMessage == error)
    }

    @Test func applyPermissionsSuccessFiresPermissionsEventWithOctal() async throws {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file, size: 1)],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        let capture = EventCapture()
        vm.auditSink = { capture.record($0) }
        await vm.load()
        let item = vm.items[0]

        let error = await vm.applyPermissions(0o640, to: item)

        #expect(error == nil)
        #expect(capture.events.count == 1)
        #expect(capture.events[0].kind == .permissions)
        #expect(capture.events[0].detail.contains("640"))
        #expect(capture.events[0].detail.contains("/a.txt"))
        #expect(capture.events[0].isError == false)
    }

    @Test func applyPermissionsFailureFiresIsErrorPermissionsEvent() async throws {
        let fs = MockRemoteFileSystem(tree: ["/": []])
        let vm = RemoteBrowserViewModel(fs: fs)
        let capture = EventCapture()
        vm.auditSink = { capture.record($0) }
        await vm.load()
        let ghost = RemoteFileItem(name: "ghost.txt", path: "/ghost.txt", kind: .file, size: 1)

        let error = await vm.applyPermissions(0o640, to: ghost)

        #expect(error != nil)
        #expect(capture.events.count == 1)
        #expect(capture.events[0].kind == .permissions)
        #expect(capture.events[0].isError == true)
        #expect(capture.events[0].errorMessage == error)
    }

    // MARK: - applyPermissionsRecursively (M11c/T2)

    @Test func recursiveApplyWritesOneAuditEventWithCounts() async throws {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "r", path: "/r", kind: .directory)],
            "/r": [
                RemoteFileItem(name: "a.txt", path: "/r/a.txt", kind: .file, size: 1),
                RemoteFileItem(name: "sub", path: "/r/sub", kind: .directory),
            ],
            "/r/sub": [RemoteFileItem(name: "b.txt", path: "/r/sub/b.txt", kind: .file, size: 1)],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        let capture = EventCapture()
        vm.auditSink = { capture.record($0) }
        await vm.load()
        let root = vm.items[0]

        let result = await vm.applyPermissionsRecursively(
            filePermissions: 0o644, directoryPermissions: 0o755, to: root)

        #expect(result == PermissionsTreeResult(changed: 4))
        #expect(capture.events.count == 1)
        #expect(capture.events[0].kind == .permissions)
        #expect(capture.events[0].isError == false)
        #expect(capture.events[0].detail.contains("chmod -R"))
        #expect(capture.events[0].detail.contains("644"))
        #expect(capture.events[0].detail.contains("755"))
        #expect(capture.events[0].detail.contains("/r"))
        // M11c/T2 review (finding 2): `.contains("4")` is vacuous — it also
        // matches the "4" inside the octal literal "644". Pin the exact
        // counts fragment `applyPermissionsRecursively` actually writes.
        #expect(capture.events[0].detail.contains("(changed 4, skipped 0, failed 0)"))
    }

    @Test func recursiveApplyMarksErrorWhenAnyEntryFailed() async throws {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "r", path: "/r", kind: .directory)],
            "/r": [RemoteFileItem(name: "a.txt", path: "/r/a.txt", kind: .file, size: 1)],
        ])
        await fs.setPermissionsFailure(
            RemoteFSError.permissionDenied(path: "/r/a.txt"), at: "/r/a.txt")
        let vm = RemoteBrowserViewModel(fs: fs)
        let capture = EventCapture()
        vm.auditSink = { capture.record($0) }
        await vm.load()
        let root = vm.items[0]

        let result = await vm.applyPermissionsRecursively(
            filePermissions: 0o644, directoryPermissions: 0o755, to: root)

        #expect(result.failed == 1)
        #expect(capture.events.count == 1)
        #expect(capture.events[0].kind == .permissions)
        #expect(capture.events[0].isError == true)
        #expect(capture.events[0].errorMessage == result.firstErrorMessage)
    }

    @Test func recursiveApplyReloadsListing() async throws {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "r", path: "/r", kind: .directory)],
            "/r": [RemoteFileItem(name: "a.txt", path: "/r/a.txt", kind: .file, size: 1)],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        let root = vm.items[0]
        // Counted per-path: the walk itself lists `/r` (the target's own
        // subtree), a DIFFERENT path from the browser's own `currentPath`
        // ("/") — so only the "/" count isolates the reload from the walk's
        // own listing traffic.
        let callsBefore = await fs.listCallCounts["/"] ?? 0

        _ = await vm.applyPermissionsRecursively(
            filePermissions: 0o644, directoryPermissions: 0o755, to: root)

        let callsAfter = await fs.listCallCounts["/"] ?? 0
        #expect(callsAfter == callsBefore + 1)   // load() re-listed the current directory
    }

    @Test func recursiveApplyReloadsListingEvenAfterFailure() async throws {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "r", path: "/r", kind: .directory)],
            "/r": [RemoteFileItem(name: "a.txt", path: "/r/a.txt", kind: .file, size: 1)],
        ])
        await fs.setPermissionsFailure(
            RemoteFSError.permissionDenied(path: "/r/a.txt"), at: "/r/a.txt")
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        let root = vm.items[0]
        let callsBefore = await fs.listCallCounts["/"] ?? 0

        _ = await vm.applyPermissionsRecursively(
            filePermissions: 0o644, directoryPermissions: 0o755, to: root)

        let callsAfter = await fs.listCallCounts["/"] ?? 0
        #expect(callsAfter == callsBefore + 1)   // reload runs even when an entry failed
    }

    @Test func recursiveApplyForwardsProgress() async throws {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "r", path: "/r", kind: .directory)],
            "/r": [
                RemoteFileItem(name: "a.txt", path: "/r/a.txt", kind: .file, size: 1),
                RemoteFileItem(name: "b.txt", path: "/r/b.txt", kind: .file, size: 1),
            ],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        let root = vm.items[0]
        let progressCapture = RecursiveProgressCapture()

        let result = await vm.applyPermissionsRecursively(
            filePermissions: 0o644, directoryPermissions: 0o755, to: root,
            progress: { progressCapture.record($0) })

        #expect(progressCapture.snapshots.count == 3) // /r, a.txt, b.txt
        #expect(progressCapture.snapshots.last == result)
    }

    /// M11c/T2 review (finding 1): the brief requires that a cancelled
    /// recursive run still reloads the listing AND is marked as cancelled in
    /// the single audit event — both held by inspection but neither was ever
    /// driven by an actual `Task.cancel()` at this layer. Mirrors
    /// `PermissionsTreeApplierTests.cancellationStopsAndReportsPartial`'s
    /// block-after-`setPermissions` + signal machinery, now hung off
    /// `MockRemoteFileSystem.blockAfterSetPermissions` instead of a second,
    /// bespoke test double.
    @Test func recursiveApplyMarksCancelledRunAndStillReloads() async throws {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "r", path: "/r", kind: .directory)],
            "/r": [RemoteFileItem(name: "a.txt", path: "/r/a.txt", kind: .file, size: 1)],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        let capture = EventCapture()
        vm.auditSink = { capture.record($0) }
        await vm.load()
        let root = vm.items[0]
        // "/" (the browser's own currentPath), not "/r" (the walk's own
        // target subtree) — same isolation reasoning as
        // `recursiveApplyReloadsListing` above.
        let callsBefore = await fs.listCallCounts["/"] ?? 0

        let reached = PlainSignal()
        // The root directory's own setPermissions("/r", ...) is the walk's
        // very first call — blocking there lets the test cancel right after
        // exactly one entry has landed, deterministically.
        await fs.blockAfterSetPermissions(at: "/r", onReached: { reached.fire() })

        let task = Task { @MainActor in
            await vm.applyPermissionsRecursively(
                filePermissions: 0o644, directoryPermissions: 0o755, to: root)
        }
        await reached.wait()
        task.cancel()
        let result = await task.value

        #expect(result.cancelled == true)
        let callsAfter = await fs.listCallCounts["/"] ?? 0
        #expect(callsAfter == callsBefore + 1)   // reload still ran despite cancellation
        #expect(capture.events.count == 1)
        #expect(capture.events[0].kind == .permissions)
        #expect(capture.events[0].detail.contains("— cancelled"))
        #expect(capture.events[0].isError == (result.failed > 0))
    }

    @Test func deleteItemsWithTwoPathsNamesBothInDetail() async throws {
        let fs = MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file, size: 1),
                RemoteFileItem(name: "b.txt", path: "/b.txt", kind: .file, size: 1),
            ],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        let capture = EventCapture()
        vm.auditSink = { capture.record($0) }
        await vm.load()

        let error = await vm.deleteItems(vm.items)

        #expect(error == nil)
        #expect(capture.events.count == 1)
        #expect(capture.events[0].kind == .delete)
        #expect(capture.events[0].detail.contains("/a.txt"))
        #expect(capture.events[0].detail.contains("/b.txt"))
        #expect(capture.events[0].isError == false)
    }

    @Test func deleteItemsFailureFiresIsErrorDeleteEvent() async throws {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file, size: 1)],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        let capture = EventCapture()
        vm.auditSink = { capture.record($0) }
        await vm.load()
        let a = vm.items[0]
        let staleB = RemoteFileItem(name: "b.txt", path: "/b.txt", kind: .file, size: 1)

        let error = await vm.deleteItems([a, staleB])

        #expect(error != nil)
        #expect(capture.events.count == 1)
        #expect(capture.events[0].kind == .delete)
        #expect(capture.events[0].isError == true)
        #expect(capture.events[0].errorMessage == error)
    }

    /// M9b/T4 review (finding 6): `deleteItems` stops at the first failure
    /// (see `deleteItemsStopsAtFirstFailureLeavingLaterItemsUntouched` above)
    /// but the audit detail used to list EVERY selected path regardless —
    /// claiming paths were deleted that never were. The detail must name
    /// only the paths ACTUALLY deleted, with the failure point named
    /// separately (chosen shape: `delete <deleted paths> — failed at
    /// <path>`; the deleted-paths list is empty-but-present when nothing
    /// was deleted before the first failure).
    @Test func deleteItemsPartialFailureDetailNamesOnlyDeletedPathsPlusFailure() async throws {
        let fs = MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file, size: 1),
                RemoteFileItem(name: "c.txt", path: "/c.txt", kind: .file, size: 1),
            ],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        let capture = EventCapture()
        vm.auditSink = { capture.record($0) }
        await vm.load()
        let a = vm.items.first(where: { $0.name == "a.txt" })!
        let c = vm.items.first(where: { $0.name == "c.txt" })!
        // Stale item: never seeded, so `deleteTree` fails on it — matches
        // the stop-at-first-failure test's mock pattern exactly.
        let staleB = RemoteFileItem(name: "b.txt", path: "/b.txt", kind: .file, size: 1)

        let error = await vm.deleteItems([a, staleB, c])

        #expect(error != nil)
        #expect(capture.events.count == 1)
        #expect(capture.events[0].kind == .delete)
        #expect(capture.events[0].isError == true)
        #expect(capture.events[0].detail.contains("/a.txt"))
        #expect(!capture.events[0].detail.contains("/c.txt"))   // never reached, never deleted
        #expect(capture.events[0].detail.contains("/b.txt"))    // names the failure point
    }

    // MARK: - refreshQuietly (M9c Task 1)

    @Test func refreshQuietlyUpdatesItemsWithoutStateFlicker() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file, size: 1)],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        #expect(vm.items.map(\.name) == ["a.txt"])

        await fs.addItem(
            RemoteFileItem(name: "b.txt", path: "/b.txt", kind: .file, size: 2), to: "/")

        await vm.refreshQuietly()
        #expect(vm.items.map(\.name) == ["a.txt", "b.txt"])
        #expect(vm.state == .loaded)
    }

    @Test func refreshQuietlyPrunesVanishedAndHiddenFromSelection() async throws {
        let fs = MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file, size: 1),
                RemoteFileItem(name: "b.txt", path: "/b.txt", kind: .file, size: 1),
                RemoteFileItem(name: ".hidden", path: "/.hidden", kind: .file, size: 1),
            ],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        vm.showHiddenFiles = true
        await vm.load()
        #expect(vm.items.map(\.name) == [".hidden", "a.txt", "b.txt"])
        vm.selectedItems = vm.items   // select all three

        try await fs.deleteTree(at: "/b.txt")   // b.txt vanishes from the server
        vm.showHiddenFiles = false              // .hidden now filtered out

        await vm.refreshQuietly()
        #expect(vm.selectedItems.map(\.name) == ["a.txt"])
    }

    @Test func refreshQuietlySwallowsErrors() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "a.txt", path: "/a.txt", kind: .file, size: 1)],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        #expect(vm.state == .loaded)

        await fs.setListFailure(RemoteFSError.connectionFailed(reason: "closed"))

        await vm.refreshQuietly()
        #expect(vm.state == .loaded)
        #expect(vm.items.map(\.name) == ["a.txt"])
    }

    @Test func refreshQuietlyBailsWhenNotLoaded() async {
        let fs = MockRemoteFileSystem(tree: [:])
        await fs.setListFailure(RemoteFSError.connectionFailed(reason: "closed"))
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        guard case .failed = vm.state else {
            Issue.record("expected .failed state after loading against a throwing mock")
            return
        }

        await fs.setListFailure(nil)   // "heal" the mock — server is reachable again

        await vm.refreshQuietly()
        guard case .failed = vm.state else {
            Issue.record("refreshQuietly must not repair a failed state — only a manual retry does")
            return
        }
        #expect(vm.items.isEmpty)
    }

    // MARK: - navigate(to:) (M11g/T1)

    @Test func navigateToExistingDirectorySetsPathLoadsAndClearsSelection() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "var", path: "/var", kind: .directory)],
            "/var": [RemoteFileItem(name: "www", path: "/var/www", kind: .directory)],
            "/var/www": [RemoteFileItem(name: "html", path: "/var/www/html", kind: .directory)],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        vm.selectedItems = [vm.items[0]]

        let error = await vm.navigate(to: "/var/www")

        #expect(error == nil)
        #expect(vm.currentPath == "/var/www")
        #expect(vm.items.map(\.name) == ["html"])
        #expect(vm.selectedItems.isEmpty)
    }

    /// The file-target message must be its OWN message, not the "not
    /// found" one — the FS found something, it's just the wrong kind.
    @Test func navigateToFileReturnsDistinctMessageAndDoesNotMove() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "readme.txt", path: "/readme.txt", kind: .file, size: 1)],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()

        let error = await vm.navigate(to: "/readme.txt")

        #expect(error != nil)
        #expect(error != String(format: CoreL10n.string("core.browse.notFound %@"), "/readme.txt"))
        #expect(vm.currentPath == "/")
    }

    @Test func navigateToMissingPathReturnsNotFoundMessageAndDoesNotMove() async {
        let fs = MockRemoteFileSystem(tree: ["/": []])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()

        let error = await vm.navigate(to: "/nope")

        #expect(error == String(format: CoreL10n.string("core.browse.notFound %@"), "/nope"))
        #expect(vm.currentPath == "/")
    }

    /// An FS-level error (e.g. permission denied) is passed through
    /// unchanged — not remapped into the file/not-found messages above.
    @Test func navigatePermissionErrorPassesThroughFSMessage() async {
        let fs = MockRemoteFileSystem(tree: ["/": []])
        await fs.setStatFailure(RemoteFSError.permissionDenied(path: "/locked"), at: "/locked")
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()

        let error = await vm.navigate(to: "/locked")

        #expect(error == String(format: CoreL10n.string("core.error.permissionDenied %@"), "/locked"))
        #expect(vm.currentPath == "/")
    }

    /// Regression (M11g final review, Important): `navigate` used to decide
    /// success from `stat` alone. A directory with no read permission
    /// `stat`s fine but fails to `list` — the COMMON permission case on a
    /// real server (a non-root SFTP user typing `/root`). Before this fix,
    /// that moved `currentPath` and returned `nil` ("success"), so the field
    /// closed and the pane fell back to its red failure screen instead of
    /// the spec's promised "field stays open with the message". Everything
    /// (`currentPath`, `items`, `selectedItems`) must come back exactly as
    /// it was before the attempt — the same as every other failure path in
    /// this function, which never mutates state to begin with.
    @Test func navigateToUnlistableDirectoryLeavesEverythingUnchangedAndReturnsMessage() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "locked", path: "/locked", kind: .directory)],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        vm.selectedItems = [vm.items[0]]
        await fs.setListFailure(RemoteFSError.permissionDenied(path: "/locked"))

        let error = await vm.navigate(to: "/locked")

        #expect(error == String(format: CoreL10n.string("core.error.permissionDenied %@"), "/locked"))
        #expect(vm.currentPath == "/")
        #expect(vm.items.map(\.name) == ["locked"])
        #expect(vm.selectedItems.count == 1)
    }

    @Test func navigateCollapsesRepeatedAndTrailingSlashes() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "var", path: "/var", kind: .directory)],
            "/var": [RemoteFileItem(name: "www", path: "/var/www", kind: .directory)],
            // Regression note (M11g final review, Important): this key was
            // missing before that fix. `navigate` used to ignore `load()`'s
            // outcome entirely, so an unseeded `/var/www` silently `list`-
            // failed with `notFound` and the test still passed — it was only
            // ever proving `currentPath` moved, not that navigation actually
            // succeeded. Now that `navigate` rolls back on a `load()`
            // failure, the fixture has to be real.
            "/var/www": [],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()

        let error = await vm.navigate(to: "/var//www///")

        #expect(error == nil)
        #expect(vm.currentPath == "/var/www")
    }

    /// A single strip of ONE trailing slash is not enough (M7a lesson) —
    /// a DOUBLE trailing slash exercises that specifically.
    @Test func navigateCollapsesDoubleTrailingSlash() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "var", path: "/var", kind: .directory)],
            "/var": [RemoteFileItem(name: "www", path: "/var/www", kind: .directory)],
            // See the matching note in navigateCollapsesRepeatedAndTrailingSlashes above.
            "/var/www": [],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()

        let error = await vm.navigate(to: "/var/www//")

        #expect(error == nil)
        #expect(vm.currentPath == "/var/www")
    }

    @Test func navigateWithEmptyOrWhitespaceInputReturnsMessageWithoutMoving() async {
        let fs = MockRemoteFileSystem(tree: ["/": []])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()

        let emptyError = await vm.navigate(to: "")
        #expect(emptyError != nil)
        #expect(vm.currentPath == "/")

        let whitespaceError = await vm.navigate(to: "   ")
        #expect(whitespaceError != nil)
        #expect(vm.currentPath == "/")
    }

    // MARK: - navigate(to:) symlinks against a REAL LocalFileSystem (T1 review I-1)
    //
    // `MockRemoteFileSystem.stat` cannot reproduce this bug: the finding is
    // specifically about what the REAL `LocalFileSystem` reports for a
    // symlink (`kind == .symlink` even when the target is a directory), so
    // only a real temporary directory plus a real symlink proves the fix.

    @Test func navigateFollowsSymlinkToRealDirectory() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-navigate-symlink-dir-\(UUID().uuidString)")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: root) }
        let linkPath = link.path(percentEncoded: false)

        let vm = RemoteBrowserViewModel(fs: LocalFileSystem())

        let error = await vm.navigate(to: linkPath)

        #expect(error == nil)
        #expect(vm.currentPath == linkPath)
    }

    /// A symlink to a FILE must still be rejected with the "not a
    /// directory" message — only a symlink whose `list()` actually succeeds
    /// counts as walkable.
    @Test func navigateRejectsSymlinkToFile() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-navigate-symlink-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("file.txt")
        try Data("hi".utf8).write(to: file)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        defer { try? FileManager.default.removeItem(at: root) }
        let linkPath = link.path(percentEncoded: false)

        let vm = RemoteBrowserViewModel(fs: LocalFileSystem())

        let error = await vm.navigate(to: linkPath)

        #expect(error == String(format: CoreL10n.string("core.browse.notADirectory %@"), linkPath))
        #expect(vm.currentPath == "/")
    }

    @Test func nilAuditSinkFiresNothing() async throws {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "old.txt", path: "/old.txt", kind: .file, size: 1)],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        // vm.auditSink intentionally left nil.
        await vm.load()

        let error = await vm.rename(vm.items[0], to: "new.txt")

        #expect(error == nil)   // no crash, behaves exactly as before M9b
    }

    // MARK: - Search (M11k/T1)

    private func makeSearchFS() -> MockRemoteFileSystem {
        MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(name: "Access.log", path: "/Access.log", kind: .file, size: 1),
                RemoteFileItem(name: "readme.md", path: "/readme.md", kind: .file, size: 2),
                RemoteFileItem(name: "error.log", path: "/error.log", kind: .file, size: 3),
            ],
        ])
    }

    @Test func filterModeReducesItemsAndReportsCounts() async {
        let vm = RemoteBrowserViewModel(fs: makeSearchFS())
        await vm.load()
        #expect(vm.items.count == 3)

        vm.searchMode = .filter
        vm.searchQuery = "log"

        #expect(vm.items.map(\.name) == ["Access.log", "error.log"])
        #expect(vm.searchMatchCount == 2)
        #expect(vm.searchTotalCount == 3)

        vm.searchQuery = ""

        #expect(vm.items.map(\.name) == ["Access.log", "error.log", "readme.md"])
        #expect(vm.searchMatchCount == 3)
        #expect(vm.searchTotalCount == 3)
    }

    @Test func jumpModeKeepsFullListingAndFocusNextWrapsForward() async {
        let vm = RemoteBrowserViewModel(fs: makeSearchFS())
        await vm.load()

        vm.searchMode = .jump
        vm.searchQuery = "log"

        // Full listing stays, sorted: Access.log, error.log, readme.md.
        #expect(vm.items.map(\.name) == ["Access.log", "error.log", "readme.md"])

        vm.focusNextMatch()
        #expect(vm.selectedItems.map(\.name) == ["Access.log"])

        vm.focusNextMatch()
        #expect(vm.selectedItems.map(\.name) == ["error.log"])

        // Wraps past the last match back to the first.
        vm.focusNextMatch()
        #expect(vm.selectedItems.map(\.name) == ["Access.log"])
    }

    @Test func focusPreviousMatchWrapsBackward() async {
        let vm = RemoteBrowserViewModel(fs: makeSearchFS())
        await vm.load()

        vm.searchMode = .jump
        vm.searchQuery = "log"

        // From no selection, "previous" lands on the last match.
        vm.focusPreviousMatch()
        #expect(vm.selectedItems.map(\.name) == ["error.log"])

        vm.focusPreviousMatch()
        #expect(vm.selectedItems.map(\.name) == ["Access.log"])

        // Wraps past the first match back to the last.
        vm.focusPreviousMatch()
        #expect(vm.selectedItems.map(\.name) == ["error.log"])
    }

    @Test func invalidRegexSetsErrorAndLeavesItemsUnchanged() async {
        let vm = RemoteBrowserViewModel(fs: makeSearchFS())
        await vm.load()
        let before = vm.items

        vm.searchIsRegex = true
        vm.searchQuery = "["

        #expect(vm.searchError == .invalidRegex)
        #expect(vm.items == before)   // NOT cleared — no faked "0 matches"
    }

    @Test func loadOnNewDirectoryResetsSearch() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "dir", path: "/dir", kind: .directory)],
            "/dir": [
                RemoteFileItem(name: "a.log", path: "/dir/a.log", kind: .file, size: 1),
                RemoteFileItem(name: "b.txt", path: "/dir/b.txt", kind: .file, size: 2),
            ],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        vm.searchMode = .filter
        vm.searchQuery = "dir"
        #expect(vm.items.map(\.name) == ["dir"])   // filtered down before navigating away

        // Navigate to a new directory — a filter from "/" must not silently
        // hide entries in "/dir" too.
        let error = await vm.navigate(to: "/dir")

        #expect(error == nil)
        #expect(vm.searchQuery.isEmpty)
        #expect(vm.searchError == nil)
        #expect(vm.items.map(\.name) == ["a.log", "b.txt"])
    }

    /// Regression (M18a review, Important): the App fires
    /// `refreshAndSelect(path:)` — which calls `load()` — in a DETACHED
    /// `Task` after `createFolder`/`rename`/`createFile` so the sheet can
    /// dismiss immediately (`BrowserPane.swift`). That means a `load()` for
    /// the OLD directory can still be in flight when the user navigates
    /// elsewhere; without a staleness guard, its late-arriving listing can
    /// land AFTER the new directory's own listing and paint the wrong
    /// directory's contents while `currentPath` still (correctly) names the
    /// new one. `load()` must apply the same "late writer must lose" rule
    /// `refreshQuietly()` already documents.
    @Test func loadIgnoresStaleResultFromEarlierDirectory() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(name: "A", path: "/A", kind: .directory),
                RemoteFileItem(name: "B", path: "/B", kind: .directory),
            ],
            "/A": [RemoteFileItem(name: "a.txt", path: "/A/a.txt", kind: .file, size: 1)],
            "/B": [RemoteFileItem(name: "b.txt", path: "/B/b.txt", kind: .file, size: 2)],
        ])
        let vm = RemoteBrowserViewModel(fs: fs, startPath: "/A")
        await vm.load()
        #expect(vm.items.map(\.name) == ["a.txt"])

        // Arm a gate on "/A"'s listing and start a second `load()` for it —
        // the detached refresh a slow/gated create/rename/createFile would
        // trigger. It blocks right after `list` records the call, until
        // released below; `arrived` confirms the call has actually reached
        // that point before the test proceeds (deterministic, no `sleep`).
        let arrived = PlainSignal()
        await fs.gateListCall(at: "/A") { arrived.fire() }
        let staleLoad = Task { await vm.load() }
        await arrived.wait()

        // Navigate to "/B" while the stale "/A" load is still in flight —
        // this is the fast path that must win.
        let error = await vm.navigate(to: "/B")
        #expect(error == nil)
        #expect(vm.currentPath == "/B")
        #expect(vm.items.map(\.name) == ["b.txt"])

        // Now let the stale "/A" load complete — it must NOT overwrite "/B"'s
        // listing nor its `.loaded` state.
        await fs.releaseListGate(at: "/A")
        await staleLoad.value

        #expect(vm.currentPath == "/B")
        #expect(vm.state == .loaded)
        #expect(vm.items.map(\.name) == ["b.txt"])
    }

    /// Regression (M18a final review, Important-2): `navigate(to:)` captures
    /// `previousState` AFTER its `stat` await. If a detached refresh (the
    /// `Task` the App fires after create/rename) is in flight at that
    /// moment, it has already set `state = .loading`, and the failure
    /// rollback then writes that `.loading` back with nothing left in flight
    /// to repair it. The pane goes fully inert: `BrowserPane` gates the table
    /// with `.allowsHitTesting(state == .loaded)` and disables Refresh/Go-Up
    /// while `.loading`, so the user is left staring at a spinner over a
    /// perfectly correct listing. The rollback restores a fully derived
    /// `displayedAll`, so `.loaded` is the truthful state to restore.
    @Test func navigateRollbackDoesNotRestoreAConcurrentLoadingState() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(name: "good.txt", path: "/good.txt", kind: .file, size: 1),
                RemoteFileItem(name: "bad", path: "/bad", kind: .directory),
            ],
            // "/bad" is deliberately absent from the tree: it `stat`s fine
            // (its parent lists it) but `list`ing it fails — the unreadable
            // directory `navigate`'s rollback path exists for.
        ])
        let vm = RemoteBrowserViewModel(fs: fs, startPath: "/")
        await vm.load()
        #expect(vm.state == .loaded)

        // A detached refresh of "/" is in flight and has set `.loading`.
        let refreshArrived = PlainSignal()
        await fs.gateListCall(at: "/") { refreshArrived.fire() }
        let detachedRefresh = Task { await vm.load() }
        await refreshArrived.wait()
        #expect(vm.state == .loading)

        // Start the doomed navigation and let it get as far as its own
        // `list("/bad")` — by then it has captured `previousState == .loading`.
        let navArrived = PlainSignal()
        await fs.gateListCall(at: "/bad") { navArrived.fire() }
        let navigation = Task { await vm.navigate(to: "/bad") }
        await navArrived.wait()

        // Let the detached refresh finish FIRST — it loses to the newer
        // `currentPath` and leaves nothing in flight to repair the state.
        await fs.releaseListGate(at: "/")
        await detachedRefresh.value

        await fs.releaseListGate(at: "/bad")
        let message = await navigation.value

        #expect(message != nil)
        #expect(vm.currentPath == "/")
        #expect(vm.items.map(\.name) == ["bad", "good.txt"])   // directories first
        // The listing is restored and complete, so the pane must be usable.
        #expect(vm.state == .loaded)
    }

    /// Regression (M18a final review, Important-2, second defect): after
    /// `await load()`, `navigate(to:)` reads `state` to decide success or
    /// failure. With `load()`'s late-writer guard in place, a navigation
    /// that has been SUPERSEDED sees the state of whoever won — and would
    /// then roll `currentPath`/`displayedAll` back to ITS own snapshot,
    /// undoing the winner's navigation, and return the winner's failure
    /// message as its own verdict. A superseded navigation must return
    /// without claiming a verdict and without touching anything.
    @Test func supersededNavigateDoesNotClaimAnotherNavigationsVerdict() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(name: "A", path: "/A", kind: .directory),
                RemoteFileItem(name: "bad", path: "/bad", kind: .directory),
            ],
            "/A": [RemoteFileItem(name: "a.txt", path: "/A/a.txt", kind: .file, size: 1)],
            // "/bad" absent again: stats fine, fails to list.
        ])
        let vm = RemoteBrowserViewModel(fs: fs, startPath: "/")
        await vm.load()
        let badItem = vm.items.first { $0.name == "bad" }!

        // Navigation 1 to "/A" blocks inside its listing.
        let arrived = PlainSignal()
        await fs.gateListCall(at: "/A") { arrived.fire() }
        let navigation = Task { await vm.navigate(to: "/A") }
        await arrived.wait()

        // A second, faster navigation supersedes it and ends in `.failed`.
        await vm.open(badItem)
        #expect(vm.currentPath == "/bad")

        await fs.releaseListGate(at: "/A")
        let message = await navigation.value

        #expect(message == nil)
        #expect(vm.currentPath == "/bad")
        if case .failed = vm.state {} else {
            Issue.record("expected the superseding navigation's .failed state, got \(vm.state)")
        }
    }

    @Test func refreshQuietlyReappliesActiveFilterToFreshListing() async {
        let fs = makeSearchFS()
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        vm.searchMode = .filter
        vm.searchQuery = "log"
        #expect(vm.items.map(\.name) == ["Access.log", "error.log"])
        vm.selectedItems = [vm.items[0]]

        await fs.addItem(
            RemoteFileItem(name: "new.log", path: "/new.log", kind: .file, size: 4), to: "/")

        await vm.refreshQuietly()

        #expect(vm.items.map(\.name) == ["Access.log", "error.log", "new.log"])
        #expect(vm.searchMatchCount == 3)
        #expect(vm.searchTotalCount == 4)
        #expect(vm.selectedItems.map(\.name) == ["Access.log"])   // selection preserved
    }

    /// A bare `load()` — the same-directory refresh that `rename`,
    /// `createFolder`, `applyPermissions`, and `deleteItems` all trigger —
    /// must KEEP an active filter and re-apply it to the fresh listing
    /// (M11k/T1 fix: the search reset lives on the navigation entry points
    /// `open`/`goUp`/`navigate`, NOT in `load()`, so renaming a file inside
    /// a filtered view doesn't silently drop the filter and flash the whole
    /// directory back).
    @Test func loadKeepsActiveFilterOnSameDirectoryRefresh() async {
        let fs = makeSearchFS()
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        vm.searchMode = .filter
        vm.searchQuery = "log"
        #expect(vm.items.map(\.name) == ["Access.log", "error.log"])

        await vm.load()   // e.g. the reload rename/delete perform, same path

        #expect(vm.searchQuery == "log")
        #expect(vm.items.map(\.name) == ["Access.log", "error.log"])
        #expect(vm.searchMatchCount == 2)
    }

    /// A failed `navigate` (stat succeeds, list throws) must leave the ACTIVE
    /// jump search fully consistent (M11k/T1 review): the rolled-back `load()`
    /// re-derives against the restored directory, so `searchMatchPaths` is
    /// restored too and `focusNextMatch()` still finds the matches — not left
    /// empty while the query and counts still claim there are some.
    @Test func failedNavigateKeepsJumpSearchConsistent() async {
        let fs = makeSearchFS()
        await fs.addItem(
            RemoteFileItem(name: "locked", path: "/locked", kind: .directory), to: "/")
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        vm.searchMode = .jump
        vm.searchQuery = "log"
        await fs.setListFailure(RemoteFSError.permissionDenied(path: "/locked"))

        let error = await vm.navigate(to: "/locked")

        #expect(error != nil)                               // navigation failed
        #expect(vm.currentPath == "/")                      // rolled back
        #expect(vm.searchQuery == "log")                    // query intact
        // The match paths survived the rollback, so jump navigation works.
        vm.focusNextMatch()
        #expect(vm.selectedItems.map(\.name) == ["Access.log"])
        vm.focusNextMatch()
        #expect(vm.selectedItems.map(\.name) == ["error.log"])
    }

    // MARK: - Sort (M11l/T1)

    private func makeSortFS() -> MockRemoteFileSystem {
        MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(name: "big.txt", path: "/big.txt", kind: .file, size: 100),
                RemoteFileItem(name: "small.txt", path: "/small.txt", kind: .file, size: 1),
                RemoteFileItem(name: "mid.txt", path: "/mid.txt", kind: .file, size: 10),
                // `navigate(to:)` resolves via `stat`, which the mock only
                // finds through the parent directory's own listing (see the
                // mock's invariant comment) — "other" must be an entry here.
                RemoteFileItem(name: "other", path: "/other", kind: .directory),
            ],
            "/other": [
                RemoteFileItem(name: "z.txt", path: "/other/z.txt", kind: .file, size: 3),
                RemoteFileItem(name: "a.txt", path: "/other/a.txt", kind: .file, size: 7),
            ],
        ])
    }

    @Test func settingSortKeyReordersItems() async {
        let vm = RemoteBrowserViewModel(fs: makeSortFS())
        await vm.load()
        // Default: .name ascending; "other" (a directory) leads regardless.
        #expect(vm.items.map(\.name) == ["other", "big.txt", "mid.txt", "small.txt"])

        vm.sortKey = .size

        #expect(vm.items.map(\.name) == ["other", "small.txt", "mid.txt", "big.txt"])
    }

    @Test func settingSortAscendingReordersItems() async {
        let vm = RemoteBrowserViewModel(fs: makeSortFS())
        await vm.load()
        vm.sortKey = .size
        #expect(vm.items.map(\.name) == ["other", "small.txt", "mid.txt", "big.txt"])

        vm.sortAscending = false

        // The folder still leads even descending — only the files reverse.
        #expect(vm.items.map(\.name) == ["other", "big.txt", "mid.txt", "small.txt"])
    }

    @Test func sortSurvivesRefreshQuietly() async {
        let fs = makeSortFS()
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        vm.sortKey = .size
        #expect(vm.items.map(\.name) == ["other", "small.txt", "mid.txt", "big.txt"])

        await fs.addItem(RemoteFileItem(name: "tiny.txt", path: "/tiny.txt", kind: .file, size: 0), to: "/")
        await vm.refreshQuietly()

        #expect(vm.items.map(\.name) == ["other", "tiny.txt", "small.txt", "mid.txt", "big.txt"])
    }

    /// Unlike the M11k search (reset by the navigation entry points), the
    /// sort preference is a per-pane display setting and must NOT reset when
    /// the directory changes.
    @Test func sortSurvivesLoadOnNewDirectory() async {
        let vm = RemoteBrowserViewModel(fs: makeSortFS())
        await vm.load()
        vm.sortKey = .size
        vm.sortAscending = false

        let error = await vm.navigate(to: "/other")

        #expect(error == nil)
        #expect(vm.sortKey == .size)
        #expect(vm.sortAscending == false)
        #expect(vm.items.map(\.name) == ["a.txt", "z.txt"])   // sizes 7, 3 descending
    }

    @Test func sortComposesWithActiveSearchFilter() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(name: "log-big.txt", path: "/log-big.txt", kind: .file, size: 100),
                RemoteFileItem(name: "log-small.txt", path: "/log-small.txt", kind: .file, size: 1),
                RemoteFileItem(name: "readme.md", path: "/readme.md", kind: .file, size: 50),
            ],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        vm.sortKey = .size
        vm.searchMode = .filter
        vm.searchQuery = "log"

        #expect(vm.items.map(\.name) == ["log-small.txt", "log-big.txt"])
        #expect(vm.searchMatchCount == 2)
        #expect(vm.searchTotalCount == 3)
    }

    // MARK: - Sort — extra columns (M11m/T1)

    private func makeExtraColumnsSortFS() -> MockRemoteFileSystem {
        MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(
                    name: "a.txt", path: "/a.txt", kind: .file, permissions: 0o644,
                    owner: "zoe", group: "staff"),
                RemoteFileItem(
                    name: "b.txt", path: "/b.txt", kind: .file, permissions: 0o600,
                    owner: "amy", group: "staff"),
                RemoteFileItem(
                    name: "c.txt", path: "/c.txt", kind: .file, permissions: 0o755,
                    owner: nil, group: nil),
                RemoteFileItem(
                    name: "link", path: "/link", kind: .symlink, permissions: 0o777,
                    owner: "amy", group: "eng"),
            ],
        ])
    }

    @Test func sortByPermissionsOrdersNumericallyAscending() async {
        let vm = RemoteBrowserViewModel(fs: makeExtraColumnsSortFS())
        await vm.load()
        vm.sortKey = .permissions

        // 0o600 < 0o644 < 0o755 < 0o777 — no directories here to group first.
        #expect(vm.items.map(\.name) == ["b.txt", "a.txt", "c.txt", "link"])
    }

    @Test func sortByPermissionsDescendingReverses() async {
        let vm = RemoteBrowserViewModel(fs: makeExtraColumnsSortFS())
        await vm.load()
        vm.sortKey = .permissions
        vm.sortAscending = false

        #expect(vm.items.map(\.name) == ["link", "c.txt", "a.txt", "b.txt"])
    }

    /// `nil` owner sorts LAST regardless of direction — distinct from
    /// `.size`/`.modified`'s "missing sorts first" rule (M11m design).
    @Test func sortByOwnerIsCaseInsensitiveWithNilLast() async {
        let vm = RemoteBrowserViewModel(fs: makeExtraColumnsSortFS())
        await vm.load()
        vm.sortKey = .owner

        // amy, amy (tiebreak by name: b.txt < link), zoe, then nil last.
        #expect(vm.items.map(\.name) == ["b.txt", "link", "a.txt", "c.txt"])
    }

    /// `nil`'s identity is "greatest" (never touched by `ascending`, exactly
    /// like `.size`/`.modified`'s "missing == smallest" identity) — so
    /// flipping to descending moves it from last to FIRST, the same
    /// direction-flip behavior already established for those two keys.
    @Test func sortByOwnerDescendingMovesNilToFront() async {
        let vm = RemoteBrowserViewModel(fs: makeExtraColumnsSortFS())
        await vm.load()
        vm.sortKey = .owner
        vm.sortAscending = false

        #expect(vm.items.map(\.name) == ["c.txt", "a.txt", "b.txt", "link"])
    }

    @Test func sortByGroupOrdersCaseInsensitivelyWithNilLast() async {
        let vm = RemoteBrowserViewModel(fs: makeExtraColumnsSortFS())
        await vm.load()
        vm.sortKey = .group

        // eng < staff < staff (tiebreak a.txt < b.txt), nil last.
        #expect(vm.items.map(\.name) == ["link", "a.txt", "b.txt", "c.txt"])
    }

    @Test func sortByTypeGroupsSymlinksApartFromFiles() async {
        let vm = RemoteBrowserViewModel(fs: makeExtraColumnsSortFS())
        await vm.load()
        vm.sortKey = .type

        // No directories here; files (rank 1) before the symlink (rank 2),
        // name tiebreak among the files.
        #expect(vm.items.map(\.name) == ["a.txt", "b.txt", "c.txt", "link"])
    }

    /// Directories still group first under every new key too (M11l rule
    /// carried forward unchanged).
    @Test func sortByOwnerStillGroupsDirectoriesFirst() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(name: "zdir", path: "/zdir", kind: .directory, owner: "amy"),
                RemoteFileItem(name: "afile.txt", path: "/afile.txt", kind: .file, owner: "amy"),
            ],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        vm.sortKey = .owner

        #expect(vm.items.map(\.name) == ["zdir", "afile.txt"])
    }
}
