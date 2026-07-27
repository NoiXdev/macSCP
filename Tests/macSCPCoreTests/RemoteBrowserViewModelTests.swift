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
}
