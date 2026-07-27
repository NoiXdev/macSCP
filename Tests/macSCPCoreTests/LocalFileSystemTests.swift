import Foundation
import Testing
@testable import macSCPCore

@Suite("LocalFileSystem")
struct LocalFileSystemTests {
    /// Creates a throwaway tree: <root>/unterordner/ and <root>/datei.txt (5 bytes).
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
        await #expect(throws: RemoteFSError.protocolError(reason: "path exists and is not a directory: \(target)")) {
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

    // MARK: - M5d/T1: offset reads, append writes, delete

    @Test func readStreamFromOffsetZeroMatchesPlainRead() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()
        let path = root.appendingPathComponent("datei.txt").path(percentEncoded: false)

        var collected = Data()
        for try await chunk in try await fs.readStream(path: path, fromOffset: 0) {
            collected.append(chunk)
        }
        #expect(collected == Data("hallo".utf8))
    }

    @Test func readStreamFromOffsetMiddleReturnsRemainingBytes() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()
        let path = root.appendingPathComponent("datei.txt").path(percentEncoded: false)

        var collected = Data()
        for try await chunk in try await fs.readStream(path: path, fromOffset: 2) {
            collected.append(chunk)
        }
        #expect(collected == Data("llo".utf8))
    }

    @Test func readStreamFromOffsetBeyondEOFYieldsEmptyStream() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()
        let path = root.appendingPathComponent("datei.txt").path(percentEncoded: false)

        var collected = Data()
        for try await chunk in try await fs.readStream(path: path, fromOffset: 999) {
            collected.append(chunk)
        }
        #expect(collected.isEmpty)
    }

    @Test func writeAppendAddsToExistingFile() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()
        let path = root.appendingPathComponent("datei.txt").path(percentEncoded: false)

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(Data(" welt".utf8))
        continuation.finish()
        try await fs.write(path: path, mode: .append, contents: stream)

        let readBack = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(readBack == Data("hallo welt".utf8))
    }

    @Test func writeAppendToNonexistentPathCreatesFile() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()
        let path = root.appendingPathComponent("neu.txt").path(percentEncoded: false)

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(Data("frisch".utf8))
        continuation.finish()
        try await fs.write(path: path, mode: .append, contents: stream)

        let readBack = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(readBack == Data("frisch".utf8))
    }

    @Test func writeOverwriteReplacesExistingContent() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()
        let path = root.appendingPathComponent("datei.txt").path(percentEncoded: false)

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(Data("neu".utf8))
        continuation.finish()
        try await fs.write(path: path, mode: .overwrite, contents: stream)

        let readBack = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(readBack == Data("neu".utf8))
    }

    @Test func deleteRemovesExistingFile() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()
        let path = root.appendingPathComponent("datei.txt").path(percentEncoded: false)

        try await fs.delete(path: path)

        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func deleteMissingFileThrowsNotFound() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()
        let path = root.appendingPathComponent("gibt-es-nicht.txt").path(percentEncoded: false)

        await #expect(throws: RemoteFSError.notFound(path: path)) {
            try await fs.delete(path: path)
        }
    }

    @Test func deleteDirectoryThrowsProtocolError() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()
        let path = root.appendingPathComponent("unterordner").path(percentEncoded: false)

        await #expect(throws: RemoteFSError.protocolError(reason: "path is a directory: \(path)")) {
            try await fs.delete(path: path)
        }
    }

    // MARK: - M7a/T1: rename + setPermissions

    /// Creates an empty throwaway directory (unlike `makeTempTree`, which
    /// seeds a fixed tree) — this suite's rename/permission tests build
    /// their own files inside it.
    private func makeTempDir() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-lfs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func renameMovesFileAndRefusesExistingDestination() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = LocalFileSystem()
        let a = dir.appendingPathComponent("a.txt").path(percentEncoded: false)
        let b = dir.appendingPathComponent("b.txt").path(percentEncoded: false)
        try Data("x".utf8).write(to: URL(fileURLWithPath: a))
        try await fs.rename(from: a, to: b)
        #expect(!FileManager.default.fileExists(atPath: a))
        #expect(FileManager.default.fileExists(atPath: b))
        // Existing destination must be refused, source stays put.
        try Data("y".utf8).write(to: URL(fileURLWithPath: a))
        await #expect(throws: RemoteFSError.self) {
            try await fs.rename(from: a, to: b)
        }
        #expect(FileManager.default.fileExists(atPath: a))
    }

    @Test func renameMissingSourceThrowsNotFound() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = LocalFileSystem()
        await #expect(throws: RemoteFSError.self) {
            try await fs.rename(
                from: dir.appendingPathComponent("missing").path(percentEncoded: false),
                to: dir.appendingPathComponent("target").path(percentEncoded: false))
        }
    }

    @Test func setPermissionsAppliesLow12BitsOnly() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = LocalFileSystem()
        let f = dir.appendingPathComponent("p.txt").path(percentEncoded: false)
        try Data("x".utf8).write(to: URL(fileURLWithPath: f))
        // Type bits in the argument must be ignored (0o100000 = regular file).
        try await fs.setPermissions(path: f, permissions: 0o100640)
        let mode = try FileManager.default.attributesOfItem(atPath: f)[.posixPermissions] as? Int
        #expect(mode == 0o640)
    }

    /// T1 review minor: a dangling symlink as the RENAME SOURCE must succeed
    /// — `fileExists` alone follows symlinks and would misreport it as
    /// `notFound`, even though `moveItem` can move the link itself just fine.
    @Test func renameDanglingSymlinkSourceSucceeds() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = LocalFileSystem()
        let source = dir.appendingPathComponent("dangling-src").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(
            atPath: source, withDestinationPath: "/macscp-nope-\(UUID().uuidString)")
        let target = dir.appendingPathComponent("dangling-renamed").path(percentEncoded: false)

        try await fs.rename(from: source, to: target)

        let values = try? URL(fileURLWithPath: target).resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values?.isSymbolicLink == true)
        #expect(!FileManager.default.fileExists(atPath: source))
    }

    /// T1 review minor: a dangling symlink already AT the destination must
    /// trip the no-silent-overwrite guard — `fileExists` alone follows
    /// symlinks and would miss it, letting `moveItem` fall through to a raw
    /// Foundation error instead of our stable `protocolError`.
    @Test func renameOntoDanglingSymlinkDestinationIsRefused() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = LocalFileSystem()
        let source = dir.appendingPathComponent("a.txt").path(percentEncoded: false)
        try Data("x".utf8).write(to: URL(fileURLWithPath: source))
        let target = dir.appendingPathComponent("dangling-dst").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(
            atPath: target, withDestinationPath: "/macscp-nope-\(UUID().uuidString)")

        await #expect(throws: RemoteFSError.protocolError(reason: "destination already exists: \(target)")) {
            try await fs.rename(from: source, to: target)
        }
        #expect(FileManager.default.fileExists(atPath: source))
    }

    // MARK: - M7a/T2: deleteTree

    @Test func deleteTreeRemovesNestedDirectoryButNeverFollowsSymlinks() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = LocalFileSystem()
        // outside/victim.txt must SURVIVE: tree/link points at outside.
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        let victim = outside.appendingPathComponent("victim.txt")
        let tree = dir.appendingPathComponent("tree", isDirectory: true)
        let sub = tree.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: victim)
        try Data("x".utf8).write(to: sub.appendingPathComponent("f.txt"))
        try FileManager.default.createSymbolicLink(
            at: tree.appendingPathComponent("link"), withDestinationURL: outside)

        try await fs.deleteTree(at: tree.path(percentEncoded: false))

        #expect(!FileManager.default.fileExists(atPath: tree.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: victim.path(percentEncoded: false)))
    }

    /// Review CRITICAL-1 (Citadel deleteTree could follow a TOP-LEVEL
    /// symlink-to-directory): locks the contract on the no-Docker backend.
    /// `FileManager.removeItem` never follows symlinks regardless of what
    /// they point at, so a top-level symlink argument must remove only the
    /// link — the target directory and its contents survive untouched.
    @Test func deleteTreeOnSymlinkToDirectoryRemovesOnlyTheLink() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = LocalFileSystem()
        let outside = dir.appendingPathComponent("outsideDir", isDirectory: true)
        let keep = outside.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: keep)
        let link = dir.appendingPathComponent("dirlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        try await fs.deleteTree(at: link.path(percentEncoded: false))

        #expect(!FileManager.default.fileExists(atPath: link.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: outside.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: keep.path(percentEncoded: false)))
    }

    @Test func deleteTreeRemovesPlainFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = LocalFileSystem()
        let f = dir.appendingPathComponent("solo.txt").path(percentEncoded: false)
        try Data("x".utf8).write(to: URL(fileURLWithPath: f))

        try await fs.deleteTree(at: f)

        #expect(!FileManager.default.fileExists(atPath: f))
    }

    @Test func deleteTreeMissingPathThrowsNotFound() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = LocalFileSystem()
        let missing = dir.appendingPathComponent("gibt-es-nicht").path(percentEncoded: false)

        await #expect(throws: RemoteFSError.notFound(path: missing)) {
            try await fs.deleteTree(at: missing)
        }
    }

    @Test func deleteTreeRemovesDanglingSymlinkItself() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = LocalFileSystem()
        let link = dir.appendingPathComponent("dangling").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: "/macscp-nope-\(UUID().uuidString)")

        try await fs.deleteTree(at: link)

        let values = try? URL(fileURLWithPath: link).resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values?.isSymbolicLink != true)
    }
}
