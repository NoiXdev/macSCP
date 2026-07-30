import Testing
@testable import macSCPCore

@Suite("RemotePath")
struct RemotePathTests {
    @Test func joinAppendsComponent() {
        #expect(RemotePath.join("/home/user", "docs") == "/home/user/docs")
    }

    @Test func joinHandlesTrailingSlash() {
        #expect(RemotePath.join("/home/user/", "docs") == "/home/user/docs")
    }

    @Test func joinOnRoot() {
        #expect(RemotePath.join("/", "etc") == "/etc")
    }

    @Test func parentOfNestedPath() {
        #expect(RemotePath.parent(of: "/home/user/docs") == "/home/user")
    }

    @Test func parentOfTopLevelIsRoot() {
        #expect(RemotePath.parent(of: "/etc") == "/")
    }

    @Test func parentOfRootIsRoot() {
        #expect(RemotePath.parent(of: "/") == "/")
    }

    @Test func normalizedAbsoluteCollapsesRepeatedAndTrailingSlashes() {
        #expect(RemotePath.normalizedAbsolute("/var//www///") == "/var/www")
        #expect(RemotePath.normalizedAbsolute("") == "/")
        #expect(RemotePath.normalizedAbsolute("/") == "/")
    }

    /// Regression (T1 review M-1): `PathCompletion.directoryToList` and
    /// `RemoteBrowserViewModel.navigate(to:)` used to each carry their own
    /// verbatim-identical slash normalizer. Both now route through
    /// `RemotePath.normalizedAbsolute` — one test proving both call sites
    /// agree on the same hostile input is enough to pin that they share it.
    @MainActor
    @Test func normalizedAbsoluteIsSharedByPathCompletionAndNavigate() async {
        let hostileInput = "/var//www///h"

        #expect(PathCompletion.directoryToList(for: hostileInput) == RemotePath.normalizedAbsolute("/var//www///"))

        let fs = MockRemoteFileSystem(tree: [
            "/": [RemoteFileItem(name: "var", path: "/var", kind: .directory)],
            "/var": [RemoteFileItem(name: "www", path: "/var/www", kind: .directory)],
            // See the regression note on the equivalent fixture in
            // RemoteBrowserViewModelTests (M11g final review, Important).
            "/var/www": [],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()

        let error = await vm.navigate(to: "/var//www///")

        #expect(error == nil)
        #expect(vm.currentPath == RemotePath.normalizedAbsolute("/var//www///"))
    }
}
