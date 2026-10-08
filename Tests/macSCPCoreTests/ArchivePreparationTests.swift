import Testing
import Foundation
@testable import macSCPCore

/// What the pane does BEFORE it starts an archive operation: pick a free
/// name, refuse what a tool would refuse, preview an extraction against the
/// folder as the file system has it, and make the subfolder `tar` will not.
@Suite(.timeLimit(.minutes(5)))
struct ArchivePreparationTests {
    private static func item(_ name: String, kind: RemoteFileKind = .file) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/d/" + name, kind: kind)
    }

    private static func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Compress naming

    @Test func compressTakesTheFirstFreeNameBesideWhatTheFolderHolds() throws {
        let plan = try ArchivePlan.compress(
            .zip, selection: [Self.item("notes")], workingDirectory: "/d",
            namesInFolder: ["notes", "notes.zip"])
        #expect(plan.words.last == .operand("./notes 2.zip"))
    }

    /// The pane hides dotfiles, but the folder does not: `.env.zip` is a
    /// real file that `zip` would open and add to.
    @Test func aHiddenArchiveInTheFolderIsStillTaken() throws {
        let plan = try ArchivePlan.compress(
            .tarGz, selection: [Self.item(".env")], workingDirectory: "/d",
            namesInFolder: [".env", ".env.tar.gz"])
        #expect(plan.words.last == .operand("./.env 2.tar.gz"))
    }

    /// On a case-insensitive file system `tar -czf ./backup.tar.gz` would
    /// TRUNCATE an existing `Backup.tar.gz`. The name must be free the way
    /// the file system compares, not byte for byte.
    @Test func aDifferentlyCasedArchiveIsTakenToo() throws {
        let plan = try ArchivePlan.compress(
            .tarGz, selection: [Self.item("backup")], workingDirectory: "/d",
            namesInFolder: ["backup", "Backup.tar.gz"])
        #expect(plan.words.last == .operand("./backup 2.tar.gz"))
    }

    // MARK: The .gz target

    @Test func aGzIsRefusedBeforeRunningWhenItsTargetExists() {
        #expect(throws: ArchiveRefusal.gzTargetExists(name: "f.log.gz")) {
            try ArchivePlan.compress(
                .gz, selection: [Self.item("f.log")], workingDirectory: "/d",
                namesInFolder: ["f.log", "f.log.gz"])
        }
    }

    @Test func aGzTargetIsComparedTheWayTheFileSystemDoes() {
        #expect(throws: ArchiveRefusal.gzTargetExists(name: "f.log.gz")) {
            try ArchivePlan.compress(
                .gz, selection: [Self.item("f.log")], workingDirectory: "/d",
                namesInFolder: ["f.log", "F.LOG.GZ"])
        }
    }

    /// The positive beside it: with no target in the way the plan is made,
    /// and it is the plain `gzip -k` one.
    @Test func aGzWithFreeTargetIsPlanned() throws {
        let plan = try ArchivePlan.compress(
            .gz, selection: [Self.item("f.log")], workingDirectory: "/d",
            namesInFolder: ["f.log"])
        #expect(plan.tool == "gzip")
        #expect(plan.title == "f.log.gz")
    }

    /// Other refusals still arrive from the planning underneath.
    @Test func theRefusalsOfTheNamingStillPropagate() {
        #expect(throws: ArchiveRefusal.emptySelection) {
            try ArchivePlan.compress(
                .zip, selection: [], workingDirectory: "/d", namesInFolder: [])
        }
        #expect(throws: ArchiveRefusal.gzTakesAFileNotAFolder(name: "dir")) {
            try ArchivePlan.compress(
                .gz, selection: [Self.item("dir", kind: .directory)],
                workingDirectory: "/d", namesInFolder: [])
        }
    }

    // MARK: Extract preview over the UNFILTERED folder

    private struct ListingRunner: ArchiveRunner {
        let entries: [String]
        func run(_ plan: ArchivePlan) async throws -> ArchiveOutcome { .finished }
        func listing(_ plan: ArchivePlan, limit: Int) async throws -> [String] { entries }
    }

    /// The names come from the FILE SYSTEM, not from the pane's table: a pane
    /// that hides dotfiles would otherwise under-report an `.env` collision,
    /// the one direction this count must not be wrong in. A real folder with
    /// a real hidden file stands in for the file system.
    @Test func thePreviewCountsAHiddenFileTheTableWouldNotShow() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent(".env"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("visible"))

        let preview = try await ArchivePreparation.extractPreview(
            archive: RemoteFileItem(
                name: "ar.zip", path: dir.appendingPathComponent("ar.zip").path, kind: .file),
            format: .zip, in: dir.path, fileSystem: LocalFileSystem(),
            runner: ListingRunner(entries: [".env", "other"]))

        #expect(preview.entryCount == 2)
        #expect(preview.collidingHere == 1)
    }

    /// A `.gz` has no listing: its one entry is its own name, derived by the
    /// preview, and the runner is never asked.
    @Test func aGzPreviewNeverAsksTheRunnerForAListing() async throws {
        struct Refusing: ArchiveRunner {
            func run(_ plan: ArchivePlan) async throws -> ArchiveOutcome { .finished }
            func listing(_ plan: ArchivePlan, limit: Int) async throws -> [String] {
                throw ArchiveFailure.exited(status: 99)
            }
        }
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("f.log"))
        let preview = try await ArchivePreparation.extractPreview(
            archive: RemoteFileItem(
                name: "f.log.gz", path: dir.appendingPathComponent("f.log.gz").path, kind: .file),
            format: .gz, in: dir.path, fileSystem: LocalFileSystem(), runner: Refusing())
        #expect(preview.entryCount == 1)
        #expect(preview.collidingHere == 1)
    }

    // MARK: The subfolder

    @Test func thisFolderCreatesNothing() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await ArchivePreparation.makeDestination(
            .thisFolder, in: dir.path, fileSystem: LocalFileSystem())
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents.isEmpty)
    }

    @Test func aSubfolderIsCreatedThroughTheFileSystem() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await ArchivePreparation.makeDestination(
            .subfolder("sub"), in: dir.path, fileSystem: LocalFileSystem())
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("sub").path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    /// The reason the creation exists, end to end and with the real tools:
    /// `tar -C ./sub` extracts nothing when `sub` is missing, and `unzip -d`
    /// makes its own. Both formats go through the same preparation, and both
    /// must leave the archive's content INSIDE the new folder.
    @Test(arguments: [ArchiveFormat.zip, .tarGz])
    func anExtractIntoANewSubfolderLandsThereForBothTools(format: ArchiveFormat) async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("payload".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let compress = try ArchivePlan.compress(
            format, selection: [Self.item("a.txt")], workingDirectory: dir.path,
            namesInFolder: ["a.txt"])
        #expect(try await LocalArchiveRunner().run(compress) == .finished)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("a.txt"))

        let archiveName = compress.title
        let archive = RemoteFileItem(
            name: archiveName, path: dir.appendingPathComponent(archiveName).path, kind: .file)
        let extractFormat: ArchiveExtractFormat = format == .zip ? .zip : .tarGz
        let destination = ExtractDestination.subfolder("out")
        try await ArchivePreparation.makeDestination(
            destination, in: dir.path, fileSystem: LocalFileSystem())
        let extract = try ArchivePlan.extract(
            archive, format: extractFormat, workingDirectory: dir.path, into: destination)
        #expect(try await LocalArchiveRunner().run(extract) == .finished)

        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("out/a.txt").path))
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("a.txt").path))
    }
}
