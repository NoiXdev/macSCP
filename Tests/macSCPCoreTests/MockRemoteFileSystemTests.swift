import Foundation
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

    @Test func createDirectoryAddsItemToTreeAndLogsIt() async throws {
        let fs = makeMock()
        try await fs.createDirectory(at: "/neu")

        let item = try await fs.stat(path: "/neu")
        #expect(item.kind == .directory)
        let createdDirectories = await fs.createdDirectories
        #expect(createdDirectories == ["/neu"])
    }

    @Test func createDirectoryIsIdempotentOnExistingDirectory() async throws {
        let fs = makeMock()
        try await fs.createDirectory(at: "/docs")

        let createdDirectories = await fs.createdDirectories
        #expect(createdDirectories.isEmpty)
    }

    @Test func createDirectoryThrowsProtocolErrorOnFileCollision() async {
        let fs = makeMock()
        await #expect(throws: RemoteFSError.protocolError(reason: "path exists and is not a directory: /readme.txt")) {
            try await fs.createDirectory(at: "/readme.txt")
        }
    }

    @Test func createDirectoryAllowsSubsequentListing() async throws {
        let fs = makeMock()
        try await fs.createDirectory(at: "/docs/sub")

        let items = try await fs.list(path: "/docs/sub")
        #expect(items.isEmpty)
        let parentItems = try await fs.list(path: "/docs")
        #expect(parentItems.contains { $0.name == "sub" && $0.kind == .directory })
    }

    // MARK: - M5d/T1: offset reads, append writes, delete

    private func makeMockWithFile(content: Data) -> MockRemoteFileSystem {
        MockRemoteFileSystem(
            tree: ["/": [RemoteFileItem(name: "datei.bin", path: "/datei.bin", kind: .file, size: UInt64(content.count))]],
            files: ["/datei.bin": content])
    }

    @Test func readStreamFromOffsetZeroMatchesFullContent() async throws {
        let content = Data("hello world".utf8)
        let fs = makeMockWithFile(content: content)

        var collected = Data()
        for try await chunk in try await fs.readStream(path: "/datei.bin", fromOffset: 0) {
            collected.append(chunk)
        }
        #expect(collected == content)
    }

    @Test func readStreamFromOffsetMiddleReturnsRemainingBytes() async throws {
        let content = Data("hello world".utf8)
        let fs = makeMockWithFile(content: content)

        var collected = Data()
        for try await chunk in try await fs.readStream(path: "/datei.bin", fromOffset: 6) {
            collected.append(chunk)
        }
        #expect(collected == Data("world".utf8))
    }

    @Test func readStreamFromOffsetBeyondEOFYieldsEmptyStream() async throws {
        let content = Data("hello".utf8)
        let fs = makeMockWithFile(content: content)

        var collected = Data()
        for try await chunk in try await fs.readStream(path: "/datei.bin", fromOffset: 999) {
            collected.append(chunk)
        }
        #expect(collected.isEmpty)
    }

    @Test func readStreamUnknownPathThrowsNotFound() async {
        let fs = makeMock()
        await #expect(throws: RemoteFSError.notFound(path: "/nope.bin")) {
            _ = try await fs.readStream(path: "/nope.bin", fromOffset: 0)
        }
    }

    @Test func writeOverwriteReplacesExistingContent() async throws {
        let fs = makeMockWithFile(content: Data("old".utf8))
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(Data("new".utf8))
        continuation.finish()

        try await fs.write(path: "/datei.bin", mode: .overwrite, contents: stream)

        var readBack = Data()
        for try await chunk in try await fs.readStream(path: "/datei.bin", fromOffset: 0) {
            readBack.append(chunk)
        }
        #expect(readBack == Data("new".utf8))
        let writeModes = await fs.writeModes
        #expect(writeModes["/datei.bin"] == .overwrite)
    }

    @Test func writeAppendAddsToExistingFile() async throws {
        let fs = makeMockWithFile(content: Data("hello ".utf8))
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(Data("world".utf8))
        continuation.finish()

        try await fs.write(path: "/datei.bin", mode: .append, contents: stream)

        var readBack = Data()
        for try await chunk in try await fs.readStream(path: "/datei.bin", fromOffset: 0) {
            readBack.append(chunk)
        }
        #expect(readBack == Data("hello world".utf8))
        let writeModes = await fs.writeModes
        #expect(writeModes["/datei.bin"] == .append)
    }

    @Test func writeAppendToNonexistentPathCreatesFile() async throws {
        let fs = makeMock()
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(Data("fresh".utf8))
        continuation.finish()

        try await fs.write(path: "/neu.bin", mode: .append, contents: stream)

        var readBack = Data()
        for try await chunk in try await fs.readStream(path: "/neu.bin", fromOffset: 0) {
            readBack.append(chunk)
        }
        #expect(readBack == Data("fresh".utf8))
    }

    @Test func deleteRemovesExistingFile() async throws {
        let fs = makeMockWithFile(content: Data("bye".utf8))
        try await fs.delete(path: "/datei.bin")

        await #expect(throws: RemoteFSError.notFound(path: "/datei.bin")) {
            _ = try await fs.readStream(path: "/datei.bin", fromOffset: 0)
        }
        let deletedPaths = await fs.deletedPaths
        #expect(deletedPaths == ["/datei.bin"])
    }

    @Test func deleteMissingFileThrowsNotFound() async {
        let fs = makeMock()
        await #expect(throws: RemoteFSError.notFound(path: "/gibt-es-nicht.bin")) {
            try await fs.delete(path: "/gibt-es-nicht.bin")
        }
    }

    @Test func deleteDirectoryThrowsProtocolError() async {
        let fs = makeMock()
        await #expect(throws: RemoteFSError.protocolError(reason: "path is a directory: /docs")) {
            try await fs.delete(path: "/docs")
        }
    }
}
