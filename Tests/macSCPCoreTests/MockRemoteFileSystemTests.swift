import Testing
@testable import macSCPCore

@Suite("MockRemoteFileSystem")
struct MockRemoteFileSystemTests {
    private func makeMock() -> MockRemoteFileSystem {
        MockRemoteFileSystem(tree: [
            "/": [
                RemoteFileItem(name: "readme.txt", path: "/readme.txt", kind: .file, size: 12),
                RemoteFileItem(name: "docs", path: "/docs", kind: .directory),
            ],
            "/docs": [
                RemoteFileItem(name: "spec.md", path: "/docs/spec.md", kind: .file, size: 400),
            ],
        ])
    }

    @Test func listsSeededDirectory() async throws {
        let fs = makeMock()
        let items = try await fs.list(path: "/")
        #expect(items.map(\.name) == ["readme.txt", "docs"])
    }

    @Test func listUnknownPathThrowsNotFound() async {
        let fs = makeMock()
        await #expect(throws: RemoteFSError.notFound(path: "/nope")) {
            _ = try await fs.list(path: "/nope")
        }
    }

    @Test func statFindsItemViaParentListing() async throws {
        let fs = makeMock()
        let item = try await fs.stat(path: "/docs/spec.md")
        #expect(item.name == "spec.md")
        #expect(item.kind == .file)
    }

    @Test func statUnknownPathThrowsNotFound() async {
        let fs = makeMock()
        await #expect(throws: RemoteFSError.notFound(path: "/docs/ghost.md")) {
            _ = try await fs.stat(path: "/docs/ghost.md")
        }
    }
}
