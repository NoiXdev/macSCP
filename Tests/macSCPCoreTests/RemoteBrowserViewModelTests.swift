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
}
