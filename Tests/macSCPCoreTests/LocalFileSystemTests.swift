import Foundation
import Testing
@testable import macSCPCore

@Suite("LocalFileSystem")
struct LocalFileSystemTests {
    /// Legt einen Wegwerf-Baum an: <root>/unterordner/ und <root>/datei.txt (5 Bytes).
    private func makeTempTree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-lfs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("unterordner"),
            withIntermediateDirectories: true)
        try Data("hallo".utf8).write(to: root.appendingPathComponent("datei.txt"))
        return root
    }

    @Test func listsFilesAndDirectoriesWithKinds() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()

        let items = try await fs.list(path: root.path(percentEncoded: false))
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(byName["unterordner"]?.kind == .directory)
        #expect(byName["datei.txt"]?.kind == .file)
    }

    @Test func fileSizeAndDateAreReported() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()

        let items = try await fs.list(path: root.path(percentEncoded: false))
        let file = items.first { $0.name == "datei.txt" }
        #expect(file?.size == 5)
        #expect(file?.modifiedAt != nil)
    }

    @Test func statReturnsDirectory() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()

        let item = try await fs.stat(path: root.path(percentEncoded: false))
        #expect(item.kind == .directory)
    }

    @Test func statReturnsFileWithSize() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()

        let path = root.appendingPathComponent("datei.txt").path(percentEncoded: false)
        let item = try await fs.stat(path: path)
        #expect(item.kind == .file)
        #expect(item.size == 5)
    }

    @Test func statBrokenSymlinkReportsSymlink() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let linkURL = root.appendingPathComponent("kaputt")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: root.appendingPathComponent("gibt-es-nicht"))

        let fs = LocalFileSystem()
        let item = try await fs.stat(path: linkURL.path(percentEncoded: false))
        #expect(item.kind == .symlink)
    }

    @Test func listMissingPathThrowsNotFound() async {
        let fs = LocalFileSystem()
        let missing = "/tmp/macscp-gibt-es-nicht-\(UUID().uuidString)"
        await #expect(throws: RemoteFSError.notFound(path: missing)) {
            _ = try await fs.list(path: missing)
        }
    }

    @Test func statMissingPathThrowsNotFound() async {
        let fs = LocalFileSystem()
        let missing = "/tmp/macscp-gibt-es-nicht-\(UUID().uuidString)"
        await #expect(throws: RemoteFSError.notFound(path: missing)) {
            _ = try await fs.stat(path: missing)
        }
    }

    @Test func directoryPathsHaveNoTrailingSlash() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()

        let items = try await fs.list(path: root.path(percentEncoded: false))
        let dir = items.first { $0.name == "unterordner" }
        #expect(dir?.path.hasSuffix("/") == false)
        #expect(dir?.path.hasSuffix("unterordner") == true)
    }

    @Test func createDirectoryCreatesNewDirectory() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()

        let target = root.appendingPathComponent("neu").path(percentEncoded: false)
        try await fs.createDirectory(at: target)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)
    }

    @Test func createDirectoryIsIdempotentOnExistingDirectory() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()

        let target = root.appendingPathComponent("unterordner").path(percentEncoded: false)
        try await fs.createDirectory(at: target)
        try await fs.createDirectory(at: target)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)
    }

    @Test func createDirectoryThrowsProtocolErrorOnFileCollision() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()

        let target = root.appendingPathComponent("datei.txt").path(percentEncoded: false)
        await #expect(throws: RemoteFSError.protocolError(reason: "Pfad existiert als Datei: \(target)")) {
            try await fs.createDirectory(at: target)
        }
    }

    @Test func createDirectoryCreatesIntermediateLevels() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()

        let target = root.appendingPathComponent("a/b/c").path(percentEncoded: false)
        try await fs.createDirectory(at: target)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)
    }
}
