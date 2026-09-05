import Crypto
import Foundation
import MacSCPTestSupport
import Testing
@testable import macSCPCore

/// `.timeLimit(.minutes(1))`: the parked-entry tests below abandon a child
/// `Task` on a `Gate` the test never opens — the ONLY clock that ends such a
/// test is cancellation from this trait, never a wall-clock bound of the
/// test's own (CLAUDE.md, "A wall-clock ceiling in a test measures the
/// runner").
@Suite("LocalFileSystem", .timeLimit(.minutes(1)))
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

    /// Phase one (local-listing-never-blocks Task 1): `list` no longer runs
    /// a per-entry metadata call, so `size`/`modifiedAt` are nil straight off
    /// the directory read. Renamed from `fileSizeAndDateAreReported`, which
    /// asserted the opposite before this change — a metadata-carrying `list`.
    @Test func fileSizeAndDateAreNilAfterPhaseOne() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()

        let items = try await fs.list(path: root.path(percentEncoded: false))
        let file = items.first { $0.name == "datei.txt" }
        #expect(file?.size == nil)
        #expect(file?.modifiedAt == nil)
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

    /// T1/M11g review follow-up: `list` must be able to list THROUGH a
    /// symlink pointing at a real directory, and the child paths it returns
    /// must stay under the symlink path — not silently resolved to the
    /// real destination. The old URL-based `contentsOfDirectory(at:
    /// includingPropertiesForKeys:)` call did exactly that resolving; this
    /// locks in the string-path API's un-resolved behavior instead.
    @Test func listFollowsSymlinkToDirectory() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: real.appendingPathComponent("innen.txt"))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let fs = LocalFileSystem()
        let items = try await fs.list(path: link.path(percentEncoded: false))

        let child = items.first { $0.name == "innen.txt" }
        #expect(child != nil)
        #expect(child?.path.hasPrefix(link.path(percentEncoded: false)) == true)
        #expect(child?.path.contains("/real/") == false)
    }

    /// Phase one (local-listing-never-blocks Task 1): listing through a
    /// symlinked parent goes through the resolve-once-then-URL-API path
    /// (`resolvingSymlinksInPath` on the parent, then `contentsOfDirectory(
    /// at:includingPropertiesForKeys:)` on the resolved directory — the
    /// bulk `getattrlistbulk` read that answers kind for every child without
    /// a per-child `stat`). Every returned item must still (a) report the
    /// same kinds the old per-entry path produced, (b) keep a `path` under
    /// the UNRESOLVED `link/...` parent — never the resolved `real/...`
    /// target — and (c) carry no metadata, exactly like every other phase-one
    /// listing.
    @Test func listThroughSymlinkedParentReportsKindsAndNilMetadataUnderTheUnresolvedPath() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent("innerDir"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: real.appendingPathComponent("innen.txt"))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let fs = LocalFileSystem()
        let items = try await fs.list(path: link.path(percentEncoded: false))

        let file = items.first { $0.name == "innen.txt" }
        let directory = items.first { $0.name == "innerDir" }
        #expect(file?.kind == .file)
        #expect(directory?.kind == .directory)
        for item in items {
            #expect(item.path.hasPrefix(link.path(percentEncoded: false)) == true)
            #expect(item.path.contains("/real/") == false)
            #expect(item.size == nil)
            #expect(item.modifiedAt == nil)
            #expect(item.owner == nil)
            #expect(item.group == nil)
            #expect(item.permissions == nil)
        }
    }

    /// Pins a behavior change (M11g final review, Minor): the old URL-based
    /// `contentsOfDirectory(at:includingPropertiesForKeys:)` silently
    /// standardized away repeated slashes; the string-path API this now uses
    /// (see the doc comment on `LocalFileSystem.list`) does not — a repeated
    /// slash in `path` survives into every child's `path`. Not a claim that
    /// this is desirable, only that it's a known quantity: nothing upstream
    /// should quietly start relying on `list` normalizing hostile input.
    @Test func listOnPathWithRepeatedSlashYieldsChildPathsContainingIt() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("innen.txt"))
        let parent = root.deletingLastPathComponent().path(percentEncoded: false)
        let name = root.lastPathComponent
        let pathWithRepeatedSlash = parent + "//" + name

        let fs = LocalFileSystem()
        let items = try await fs.list(path: pathWithRepeatedSlash)

        let child = items.first { $0.name == "innen.txt" }
        #expect(child?.path.contains("//") == true)
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

    /// A trailing slash on a symlink argument makes `removeItem` FOLLOW the
    /// link (proven live in the M7a final review) — normalization must strip
    /// it before the delete happens, otherwise the target's contents are
    /// destroyed instead of just the link.
    @Test func deleteTreeWithTrailingSlashOnSymlinkRemovesOnlyTheLink() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = LocalFileSystem()
        let outside = dir.appendingPathComponent("outsideDir", isDirectory: true)
        let keep = outside.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: keep)
        let link = dir.appendingPathComponent("dirlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        try await fs.deleteTree(at: link.path(percentEncoded: false) + "/")

        #expect(!FileManager.default.fileExists(atPath: link.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: outside.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: keep.path(percentEncoded: false)))

        // Repeated trailing slashes must be equally harmless (final-review
        // follow-up: a single-strip normalization left "//" following the
        // link) — recreate the link and delete it with a double slash.
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try await fs.deleteTree(at: link.path(percentEncoded: false) + "//")
        #expect(!FileManager.default.fileExists(atPath: link.path(percentEncoded: false)))
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

    // MARK: - Owner/group (M11m/T1)

    /// Phase one (local-listing-never-blocks Task 1): `list` no longer calls
    /// `item(for:)`/`ownerGroup(for:)` at all, so `fetchesOwnerGroup: true`
    /// no longer has any effect on a `list` result — owner/group are nil
    /// regardless, exactly like every other metadata field. Renamed from
    /// `listReportsOwnerAndGroupNamesForOwnFiles`, which asserted the
    /// opposite (non-nil names resolved through `list`) before this change.
    @Test func listOmitsOwnerAndGroupNamesForOwnFilesAfterPhaseOne() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem(fetchesOwnerGroup: true)

        let items = try await fs.list(path: root.path(percentEncoded: false))
        let file = items.first { $0.name == "datei.txt" }
        #expect(file?.owner == nil)
        #expect(file?.group == nil)
    }

    @Test func statReportsOwnerAndGroupNamesForOwnFiles() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem(fetchesOwnerGroup: true)

        let path = root.appendingPathComponent("datei.txt").path(percentEncoded: false)
        let item = try await fs.stat(path: path)
        #expect(item.owner == NSUserName())
        #expect(item.group != nil)
    }

    // MARK: - Owner/group is opt-in (M18a)

    /// M18a finding: the owner/group syscall (`attributesOfItem`) runs once
    /// PER ENTRY and can trigger a blocking macOS permission prompt on
    /// TCC-protected folders (Desktop/Documents/Downloads). The plain
    /// initializer must never pay for it.
    @Test func listOmitsOwnerAndGroupByDefault() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()

        let items = try await fs.list(path: root.path(percentEncoded: false))
        let file = items.first { $0.name == "datei.txt" }
        #expect(file?.owner == nil)
        #expect(file?.group == nil)
    }

    // MARK: - metadata(for:) as a stream (local-listing-never-blocks Task 2)

    /// Mirrors `ConnectionDiagnosticsTests`' private `Gate`: a probe parks
    /// on `opened()` and never returns while this test never calls `open()`.
    /// `isClosed` is read by the parked-entry test to prove the abandoned
    /// child really never got past the gate, not merely that it finished
    /// quickly by some other route.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            guard !isOpen else { return }
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func opened() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        var isClosed: Bool { !isOpen }
    }

    /// Collects the items a `metadata(for:)` consumer receives, across the
    /// task boundary between the consumer `Task` (below) and this test's own
    /// polling — an `actor` so the two sides never race on the same array.
    private actor CollectedItems {
        private(set) var items: [RemoteFileItem] = []

        func append(_ item: RemoteFileItem) {
            items.append(item)
        }

        var count: Int { items.count }
    }

    /// Test (a): three plain files, no substituted probe (the REAL
    /// `item(for:fetchesOwnerGroup:)` runs) — `metadata(for:)` yields all
    /// three, each filled in, and then finishes on its own (every child
    /// completed; nothing here cancels the consumer).
    @Test func metadataFillsInSizeAndDateForPlainFilesThenFinishes() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["one.txt", "two.txt", "three.txt"]
        for name in names {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        let fs = LocalFileSystem()
        let phaseOne = try await fs.list(path: root.path(percentEncoded: false))
        #expect(phaseOne.count == 3)

        var filled: [RemoteFileItem] = []
        for await item in fs.metadata(for: phaseOne) {
            filled.append(item)
        }

        #expect(filled.count == 3)
        let byName = Dictionary(uniqueKeysWithValues: filled.map { ($0.name, $0) })
        for name in names {
            #expect(byName[name]?.size != nil)
            #expect(byName[name]?.modifiedAt != nil)
        }
    }

    /// Test (b): one entry's probe is parked on a `Gate` this test never
    /// opens. `metadata(for:)` still yields the other two entries — proving
    /// the stuck one does not hold up the rest — and then the test CANCELS
    /// the consumer task itself. The stream must finish (the consumer's
    /// `for await` loop ends) with the gate STILL closed: the parked child
    /// was abandoned, not waited for and not cancelled-and-joined. Nothing
    /// here asserts elapsed time (CLAUDE.md: a ceiling measures the runner,
    /// not the property) — only the outcome and the ordering.
    @Test func metadataAbandonsAStuckEntryWhenTheConsumerCancels() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fastNames = ["one.txt", "two.txt"]
        for name in fastNames + ["stuck.txt"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        let stuckPath = root.appendingPathComponent("stuck.txt").path(percentEncoded: false)
        let gate = Gate()
        let fs = LocalFileSystem(metadataProbe: { url in
            guard url.path(percentEncoded: false) == stuckPath else {
                return RemoteFileItem(
                    name: url.lastPathComponent, path: url.path(percentEncoded: false),
                    kind: .file, size: 1)
            }
            // Never opened by this test — parks forever. `async` lets this
            // suspend on the actor's continuation instead of blocking a
            // thread (CLAUDE.md: tests never block the cooperative pool).
            await gate.opened()
            return nil
        })
        let phaseOne = try await fs.list(path: root.path(percentEncoded: false))
        #expect(phaseOne.count == 3)

        let collected = CollectedItems()
        let consumer = Task<Int, Never> {
            var seen = 0
            for await item in fs.metadata(for: phaseOne) {
                await collected.append(item)
                seen += 1
            }
            return seen
        }

        try await pollUntil("the two fast entries to arrive") {
            await collected.count == 2
        }
        consumer.cancel()
        let yieldedBeforeCancellation = await consumer.value

        #expect(yieldedBeforeCancellation == 2)
        let byName = Dictionary(uniqueKeysWithValues: await collected.items.map { ($0.name, $0) })
        #expect(Set(byName.keys) == Set(fastNames))
        #expect(await gate.isClosed)
    }

    /// Test (c): the consumer is cancelled before the stream has any chance
    /// to yield — a single entry, its probe permanently parked. The `for
    /// await` loop must still end (the consumer task completes) rather than
    /// hang waiting for a first item that will never come.
    @Test func metadataConsumerCancelledBeforeAnyYieldEndsTheLoop() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("one.txt"))
        let gate = Gate()
        let fs = LocalFileSystem(metadataProbe: { _ in
            await gate.opened()
            return nil
        })
        let phaseOne = try await fs.list(path: root.path(percentEncoded: false))

        let consumer = Task<Bool, Never> {
            for await _ in fs.metadata(for: phaseOne) {
                Issue.record("expected no item before cancellation")
            }
            return true
        }
        consumer.cancel()
        let loopEnded = await consumer.value

        #expect(loopEnded)
        #expect(await gate.isClosed)
    }

    /// Test (d): owner/group in phase two are gated by `fetchesOwnerGroup`,
    /// exactly like `stat` (`ownerGroup(for:fetchesOwnerGroup:)`) — this
    /// drives the REAL probe (no substitution) so it also proves the default
    /// `metadataProbe` is wired to the flag correctly, not just that the
    /// gate exists somewhere.
    @Test func metadataIncludesOwnerOnlyWhenFetchesOwnerGroupIsTrue() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let fsWithOwner = LocalFileSystem(fetchesOwnerGroup: true)
        let phaseOneWithOwner = try await fsWithOwner.list(path: root.path(percentEncoded: false))
        var filledWithOwner: [RemoteFileItem] = []
        for await item in fsWithOwner.metadata(for: phaseOneWithOwner) { filledWithOwner.append(item) }
        #expect(filledWithOwner.first { $0.name == "datei.txt" }?.owner != nil)

        let fsWithoutOwner = LocalFileSystem(fetchesOwnerGroup: false)
        let phaseOneWithoutOwner = try await fsWithoutOwner.list(path: root.path(percentEncoded: false))
        var filledWithoutOwner: [RemoteFileItem] = []
        for await item in fsWithoutOwner.metadata(for: phaseOneWithoutOwner) { filledWithoutOwner.append(item) }
        #expect(filledWithoutOwner.first { $0.name == "datei.txt" }?.owner == nil)
    }

    // MARK: - Session-scoped memory of stuck paths (final fix round)

    /// Records the paths `metadataProbe` was actually called with — an
    /// `actor` for the same cross-task-boundary reason `CollectedItems`
    /// above is.
    private actor CallLog {
        private(set) var paths: [String] = []
        func record(_ path: String) { paths.append(path) }
    }

    /// A path already in `StuckPaths` never gets a child on the NEXT
    /// `metadata(for:)` call — proven by counting probe calls, never by
    /// timing — while an unmarked path in the SAME listing is still probed
    /// normally, so this is a positive beside the negative (CLAUDE.md,
    /// "Guards that name what they watch"). `filled` also carries only the
    /// unmarked entry, and only it: the marked one's row stays exactly as
    /// phase one left it.
    @Test func metadataSkipsAPathAlreadyMarkedStuckButStillProbesOthers() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["stuck.txt", "fine.txt"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        let stuckPath = root.appendingPathComponent("stuck.txt").path(percentEncoded: false)
        let finePath = root.appendingPathComponent("fine.txt").path(percentEncoded: false)
        let stuckPaths = StuckPaths()
        stuckPaths.markStuck(stuckPath)

        let calls = CallLog()
        let fs = LocalFileSystem(
            metadataProbe: { url in
                let path = url.path(percentEncoded: false)
                await calls.record(path)
                return RemoteFileItem(name: url.lastPathComponent, path: path, kind: .file, size: 1)
            },
            stuckPaths: stuckPaths)
        let phaseOne = try await fs.list(path: root.path(percentEncoded: false))
        #expect(phaseOne.count == 2)

        var filled: [RemoteFileItem] = []
        for await item in fs.metadata(for: phaseOne) { filled.append(item) }

        #expect(filled.map(\.name) == ["fine.txt"])
        let calledPaths = await calls.paths
        #expect(!calledPaths.contains(stuckPath))
        #expect(calledPaths.contains(finePath))
    }

    /// `StuckPaths.contains`/`.markStuck` themselves, without going through
    /// `metadata(for:)` — the direct positive/negative this test's sibling
    /// above relies on.
    @Test func stuckPathsContainsOnlyMarkedPaths() {
        let stuckPaths = StuckPaths()
        #expect(!stuckPaths.contains("/a"))
        stuckPaths.markStuck("/a")
        #expect(stuckPaths.contains("/a"))
        #expect(!stuckPaths.contains("/b"))
    }

    /// `StuckPaths.clear` directly — the third state (never marked, marked
    /// then cleared) beside `stuckPathsContainsOnlyMarkedPaths`' two above.
    @Test func stuckPathsClearRemovesAMarkedPath() {
        let stuckPaths = StuckPaths()
        stuckPaths.clear("/never-marked")
        #expect(!stuckPaths.contains("/never-marked"), "clearing an absent path is a harmless no-op")

        stuckPaths.markStuck("/a")
        stuckPaths.clear("/a")
        #expect(!stuckPaths.contains("/a"))
    }

    /// Round 2, Important: the FIRST deadline (`slowEntryThreshold`) is a
    /// log line only — it must not mark anything, exactly the regression
    /// `DiagnosticLogSharedSinkTests
    /// .metadataSupervisorLogsAStillPendingLineForAPermanentlyStuckEntry`
    /// also covers. This test drives the SECOND deadline
    /// (`stuckEntryDeadline`) with a tiny injected `MetadataDeadlines`, so
    /// a permanently parked entry gets marked without a real five-second
    /// wait, while a fast sibling in the SAME listing is never marked.
    /// Waits on `StuckPaths`' own membership via `pollUntil`, never on a
    /// clock of its own beyond the suite's `.timeLimit`.
    @Test func metadataMarksAPermanentlyStuckEntryOnlyAfterTheStuckEntryDeadlineNotTheSlowThreshold() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["stuck.txt", "fast.txt"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        let stuckPath = root.appendingPathComponent("stuck.txt").path(percentEncoded: false)
        let fastPath = root.appendingPathComponent("fast.txt").path(percentEncoded: false)
        let stuckPaths = StuckPaths()
        let gate = Gate()
        let deadlines = MetadataDeadlines(
            slowEntryThreshold: .milliseconds(5), stuckEntryDeadline: .milliseconds(30))
        let fs = LocalFileSystem(
            metadataProbe: { url in
                let path = url.path(percentEncoded: false)
                guard path == stuckPath else {
                    return RemoteFileItem(name: url.lastPathComponent, path: path, kind: .file, size: 1)
                }
                await gate.opened()
                return nil
            },
            metadataDeadlines: deadlines,
            stuckPaths: stuckPaths)
        let phaseOne = try await fs.list(path: root.path(percentEncoded: false))
        #expect(phaseOne.count == 2)

        let consumer = Task {
            for await _ in fs.metadata(for: phaseOne) {}
        }

        try await pollUntil("the permanently stuck entry to be marked after the stuck-entry deadline") {
            stuckPaths.contains(stuckPath)
        }
        #expect(!stuckPaths.contains(fastPath))
        consumer.cancel()
    }

    /// Round 2, ruled in: a probe marked stuck by the supervisor's second
    /// deadline but NOT cancelled (Task 2's own accepted cost — nothing
    /// here ever cancels a child) still eventually returns, and doing so
    /// clears its own path — this visit's row fills in, and a later
    /// listing of the same directory probes it again instead of skipping
    /// it forever.
    @Test func metadataClearsAMarkedPathOnceItsProbeFinallyReturns() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("late.txt"))
        let latePath = root.appendingPathComponent("late.txt").path(percentEncoded: false)
        let stuckPaths = StuckPaths()
        let gate = Gate()
        let deadlines = MetadataDeadlines(
            slowEntryThreshold: .milliseconds(5), stuckEntryDeadline: .milliseconds(15))
        let fs = LocalFileSystem(
            metadataProbe: { url in
                await gate.opened()
                return RemoteFileItem(
                    name: url.lastPathComponent, path: url.path(percentEncoded: false),
                    kind: .file, size: 1)
            },
            metadataDeadlines: deadlines,
            stuckPaths: stuckPaths)
        let phaseOne = try await fs.list(path: root.path(percentEncoded: false))
        #expect(phaseOne.count == 1)

        let collected = CollectedItems()
        let consumer = Task<Int, Never> {
            var seen = 0
            for await item in fs.metadata(for: phaseOne) {
                await collected.append(item)
                seen += 1
            }
            return seen
        }

        try await pollUntil("the late entry to be marked stuck") {
            stuckPaths.contains(latePath)
        }
        await gate.open()

        try await pollUntil("the mark to be cleared once the probe returns") {
            !stuckPaths.contains(latePath)
        }
        let yielded = await consumer.value
        #expect(yielded == 1)
        let byName = await collected.items
        #expect(byName.map(\.name) == ["late.txt"])
    }

    // `listIncludesOwnerAndGroupWhenRequested` (M18a) used to live here,
    // asserting that `fetchesOwnerGroup: true` makes `list` resolve owner/
    // group names. Removed (local-listing-never-blocks Task 1): phase one
    // makes that assertion permanently false, and its setup is now identical
    // to `listOmitsOwnerAndGroupNamesForOwnFilesAfterPhaseOne` above, which
    // asserts what `list` actually does today.

    // MARK: - Checksums (computed here, over a file that is already here)

    /// The `as?` route the surface takes, from an existential of the
    /// file-system protocol — not a cast of the concrete type, which would
    /// always succeed and prove nothing about the conformance being
    /// reachable the way a caller reaches it.
    private func checksumProvider() throws -> any RemoteChecksumProvider {
        let fs: any RemoteFileSystem = LocalFileSystem()
        return try #require(fs as? any RemoteChecksumProvider)
    }

    /// Figures produced by this host's `shasum`/`md5` over the same five
    /// bytes, not by this code: a hasher wired to the wrong algorithm would
    /// still be self-consistent, and only an outside figure catches that.
    @Test func computesAllThreeDigestsOfALocalFileAndSaysItComputedThemHere() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("datei.txt").path(percentEncoded: false)
        let provider = try checksumProvider()

        let expected: [ChecksumAlgorithm: String] = [
            .sha256: "d3751d33f9cd5049c4af2b462735457e4d3baf130bcbb87f389e349fbaeb20b9",
            .sha1: "fd4cef7a4e607f1fcc920ad6329a6df2df99a4e8",
            .md5: "598d4c200461b81522a3328565c25f7c",
        ]
        for algorithm in ChecksumAlgorithm.allCases {
            let outcome = try await provider.remoteChecksum(forFileAt: path, algorithm: algorithm)
            guard case .checksum(let checksum) = outcome else {
                Issue.record("expected a checksum for \(algorithm), got \(outcome)")
                continue
            }
            #expect(checksum.algorithm == algorithm)
            #expect(checksum.hex == expected[algorithm])
            #expect(checksum.provenance == .computedLocally)
            #expect(checksum.describesFileContent)
        }
    }

    /// A file several read chunks long, against a one-shot hash of the same
    /// bytes. The reference is computed here in the test rather than pasted,
    /// because the point is the chunk seam: a streamed digest that dropped
    /// or repeated a chunk boundary would disagree with it.
    @Test func aFileLongerThanOneReadChunkHashesTheSameAsAOneShotDigest() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        // Not a multiple of the chunk size, so the last read is a short one.
        let contents = Data((0..<(TransferChunk.size * 3 + 517)).map { UInt8($0 % 251) })
        let url = root.appendingPathComponent("gross.bin")
        try contents.write(to: url)
        let provider = try checksumProvider()

        let outcome = try await provider.remoteChecksum(
            forFileAt: url.path(percentEncoded: false), algorithm: .sha256)

        guard case .checksum(let checksum) = outcome else {
            Issue.record("expected a checksum, got \(outcome)")
            return
        }
        let oneShot = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        #expect(checksum.hex == oneShot)
    }

    @Test func aMissingFileHasNoChecksumAndSaysSoAsNotFound() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = try checksumProvider()

        await #expect(throws: RemoteFSError.self) {
            _ = try await provider.remoteChecksum(
                forFileAt: root.appendingPathComponent("weg.txt").path(percentEncoded: false),
                algorithm: .sha256)
        }
    }

    /// A directory is not a file with bytes to hash, and the refusal has to
    /// SAY that — which is why the exact reason is asserted here rather than
    /// merely that something was thrown.
    ///
    /// Measured on 2026-08-31 with the explicit check removed, on the two
    /// spellings a directory path takes: WITH a trailing slash (what
    /// `URL.path(percentEncoded:)` yields for a directory, so what this test
    /// passes) `FileHandle(forReadingFrom:)` throws Cocoa error 4, which
    /// this file maps to `.notFound` — an existing directory reported as
    /// missing. WITHOUT one it throws Cocoa error 512, whose message is
    /// about a file that could not be SAVED in a folder, for a read. Both
    /// are what the user would be shown.
    @Test func aDirectoryIsRefusedWithAReasonThatNamesTheDirectory() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = try checksumProvider()
        let path = root.appendingPathComponent("unterordner").path(percentEncoded: false)

        await #expect(throws: RemoteFSError.protocolError(reason: "path is a directory: \(path)")) {
            _ = try await provider.remoteChecksum(forFileAt: path, algorithm: .sha256)
        }
    }
}
