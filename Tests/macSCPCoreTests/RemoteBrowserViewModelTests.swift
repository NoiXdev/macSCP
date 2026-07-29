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
        #expect(vm.items.map(\.name) == ["fresh"])
        #expect(vm.selectedItems.map(\.name) == ["fresh"])
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
}
