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

        let preparation = try await ArchivePreparation.extractPreview(
            archive: RemoteFileItem(
                name: "ar.zip", path: dir.appendingPathComponent("ar.zip").path, kind: .file),
            format: .zip, in: dir.path, fileSystem: LocalFileSystem(),
            runner: ListingRunner(entries: [".env", "other"]))

        #expect(preparation.preview.entryCount == 2)
        #expect(preparation.preview.collidingHere == 1)
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
        let preparation = try await ArchivePreparation.extractPreview(
            archive: RemoteFileItem(
                name: "f.log.gz", path: dir.appendingPathComponent("f.log.gz").path, kind: .file),
            format: .gz, in: dir.path, fileSystem: LocalFileSystem(), runner: Refusing())
        #expect(preparation.preview.entryCount == 1)
        #expect(preparation.preview.collidingHere == 1)
        // No probe either: `Refusing` would have thrown for that too.
        #expect(preparation.tarSkipExisting == .keepOldFiles)
    }

    // MARK: The archive name `unzip` is given

    /// `unzip` reads the ARCHIVE NAME it is handed as a pattern, so a folder
    /// holding both `b*.zip` and `bb.zip` answers one selection with two
    /// archives. Not a shell injection -- the single-quoting holds -- but the
    /// same class: a user-controlled name stops being a name.
    @Test func anArchiveNameWithAWildcardIsRefusedRatherThanMatched() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("selected".utf8).write(to: dir.appendingPathComponent("picked"))
        try Data("not selected".utf8).write(to: dir.appendingPathComponent("sibling"))
        for (archive, member) in [("b*.zip", "picked"), ("bb.zip", "sibling")] {
            let pack = try ArchivePlan.compress(
                .zip, selection: [Self.item(member)], workingDirectory: dir.path,
                archiveName: archive)
            #expect(try await LocalArchiveRunner().run(pack) == .finished)
        }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("picked"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("sibling"))

        let archive = RemoteFileItem(
            name: "b*.zip", path: dir.appendingPathComponent("b*.zip").path, kind: .file)
        // Refused while the dialog is being built, so the run never happens
        // and the count the dialog would have shown is never made. Before
        // this refusal existed the preview answered entryCount 3 for a
        // one-entry archive -- both archives' entries plus `unzip`'s own
        // prose summary line -- and the extraction unpacked `sibling` too.
        await #expect(throws: ArchiveRefusal.wildcardInNameUnsupportedByUnzip(name: "b*.zip")) {
            try await ArchivePreparation.extractPreview(
                archive: archive, format: .zip, in: dir.path,
                fileSystem: LocalFileSystem(), runner: LocalArchiveRunner())
        }
        // Neither archive was touched, and the member of neither was written.
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("picked").path))
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("sibling").path))
    }

    /// The positive beside it, through the real tools: the sibling is still
    /// there, the name is literal, and the preview counts ONE entry -- not
    /// two, and not a summary line. Without this the refusal above could be
    /// unconditional, or the listing could be refusing every zip.
    @Test func aLiteralArchiveNameCountsItsOwnEntriesBesideASibling() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("selected".utf8).write(to: dir.appendingPathComponent("picked"))
        try Data("not selected".utf8).write(to: dir.appendingPathComponent("sibling"))
        for (archive, member) in [("ba.zip", "picked"), ("bb.zip", "sibling")] {
            let pack = try ArchivePlan.compress(
                .zip, selection: [Self.item(member)], workingDirectory: dir.path,
                archiveName: archive)
            #expect(try await LocalArchiveRunner().run(pack) == .finished)
        }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("picked"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("sibling"))

        let archive = RemoteFileItem(
            name: "ba.zip", path: dir.appendingPathComponent("ba.zip").path, kind: .file)
        let preparation = try await ArchivePreparation.extractPreview(
            archive: archive, format: .zip, in: dir.path,
            fileSystem: LocalFileSystem(), runner: LocalArchiveRunner())
        #expect(preparation.preview.entryCount == 1)
        let plan = try ArchivePlan.extract(
            archive, format: .zip, workingDirectory: dir.path, into: .thisFolder,
            tarSkipExisting: preparation.tarSkipExisting, preview: preparation.preview)
        #expect(try await LocalArchiveRunner().run(plan) == .finished)
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("picked").path))
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("sibling").path))
    }

    /// Each character of the measured set, and the two that were measured NOT
    /// to be in it. A `tar` name carrying the same characters is fine, which
    /// is why the refusal is per format rather than per feature.
    @Test(arguments: ["b*.zip", "b?.zip", "b[a].zip"])
    func everyWildcardCharacterIsRefusedForAZip(name: String) {
        let archive = RemoteFileItem(name: name, path: "/d/" + name, kind: .file)
        #expect(throws: ArchiveRefusal.wildcardInNameUnsupportedByUnzip(name: name)) {
            try ArchivePlan.extract(
                archive, format: .zip, workingDirectory: "/d", into: .thisFolder,
                tarSkipExisting: .keepOldFiles)
        }
        #expect(throws: ArchiveRefusal.wildcardInNameUnsupportedByUnzip(name: name)) {
            try ArchivePlan.listing(of: name, format: .zip, workingDirectory: "/d")
        }
    }

    /// Measured 2026-10-09: a lone `]` and a `\` are taken literally by
    /// `unzip` and open the archive that is named, so they are not refused.
    /// And `tar -xf './q*.tar'` does not glob at all.
    @Test(arguments: ["b].zip", "b\\c.zip"])
    func aCharacterUnzipTakesLiterallyIsNotRefused(name: String) throws {
        let archive = RemoteFileItem(name: name, path: "/d/" + name, kind: .file)
        let plan = try ArchivePlan.extract(
            archive, format: .zip, workingDirectory: "/d", into: .thisFolder,
            tarSkipExisting: .keepOldFiles)
        #expect(plan.words.contains(.operand("./" + name)))
    }

    @Test(arguments: [ArchiveExtractFormat.tar, .tarGz])
    func aTarNameWithTheSameCharactersIsNotRefused(format: ArchiveExtractFormat) throws {
        let name = "q*[a]?.tar"
        let archive = RemoteFileItem(name: name, path: "/d/" + name, kind: .file)
        let plan = try ArchivePlan.extract(
            archive, format: format, workingDirectory: "/d", into: .thisFolder,
            tarSkipExisting: .keepOldFiles)
        #expect(plan.words.contains(.operand("./" + name)))
        let list = try ArchivePlan.listing(of: name, format: format, workingDirectory: "/d")
        #expect(list.words.contains(.operand("./" + name)))
    }

    // MARK: The .gz extraction target

    /// `ArchivePlan.compress` refuses a `.gz` whose target exists; extraction
    /// must refuse the mirror case. Measured 2026-10-09: local
    /// `/usr/bin/gunzip -k -- ./x.gz` with `x` present printed `gunzip: ./x
    /// already exists -- skipping` and exited **1**, leaving `x` unchanged;
    /// the rig's BusyBox `gunzip` printed `can't open './x': File exists`
    /// and also exited 1. Nothing is lost either way -- it is a protective
    /// outcome reported as a failure.
    @Test func aGzExtractionOntoAnExistingNameIsRefusedBeforeRunning() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("payload".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        let pack = try ArchivePlan.compress(
            .gz, selection: [Self.item("notes.txt")], workingDirectory: dir.path,
            namesInFolder: ["notes.txt"])
        #expect(try await LocalArchiveRunner().run(pack) == .finished)

        let archive = RemoteFileItem(
            name: "notes.txt.gz",
            path: dir.appendingPathComponent("notes.txt.gz").path, kind: .file)
        let preparation = try await ArchivePreparation.extractPreview(
            archive: archive, format: .gz, in: dir.path,
            fileSystem: LocalFileSystem(), runner: LocalArchiveRunner())
        #expect(preparation.preview.takenGzOutput == "notes.txt")
        #expect(throws: ArchiveRefusal.gzExtractTargetExists(name: "notes.txt")) {
            try ArchivePlan.extract(
                archive, format: .gz, workingDirectory: dir.path, into: .thisFolder,
                tarSkipExisting: preparation.tarSkipExisting,
                preview: preparation.preview)
        }
    }

    /// The positive beside it: with the output name free the plan is made,
    /// and the real `gunzip` finishes. Without this the refusal above could
    /// be unconditional and nothing would notice.
    @Test func aGzExtractionWhoseOutputNameIsFreeIsPlannedAndRuns() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("payload".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        let pack = try ArchivePlan.compress(
            .gz, selection: [Self.item("notes.txt")], workingDirectory: dir.path,
            namesInFolder: ["notes.txt"])
        #expect(try await LocalArchiveRunner().run(pack) == .finished)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("notes.txt"))

        let archive = RemoteFileItem(
            name: "notes.txt.gz",
            path: dir.appendingPathComponent("notes.txt.gz").path, kind: .file)
        let preparation = try await ArchivePreparation.extractPreview(
            archive: archive, format: .gz, in: dir.path,
            fileSystem: LocalFileSystem(), runner: LocalArchiveRunner())
        #expect(preparation.preview.takenGzOutput == nil)
        let plan = try ArchivePlan.extract(
            archive, format: .gz, workingDirectory: dir.path, into: .thisFolder,
            tarSkipExisting: preparation.tarSkipExisting, preview: preparation.preview)
        #expect(try await LocalArchiveRunner().run(plan) == .finished)
        #expect(
            try Data(contentsOf: dir.appendingPathComponent("notes.txt"))
                == Data("payload".utf8))
    }

    /// The folder's own comparison, as the compress side is held to it: a
    /// differently-cased `NOTES.TXT` is the same name on this volume.
    @Test func aGzExtractionTargetIsComparedTheWayTheFileSystemDoes() {
        let preview = ExtractPreview.make(
            archiveName: "notes.txt.gz", format: .gz, archiveEntries: nil,
            namesInFolder: ["NOTES.TXT"])
        #expect(preview.takenGzOutput == "notes.txt")
    }

    /// And no other format carries the answer, because no other format's
    /// tool needs it: `unzip -n` and `tar` skip a collision at exit 0.
    @Test(arguments: [ArchiveExtractFormat.zip, .tar, .tarGz])
    func onlyAGzCarriesATakenOutputName(format: ArchiveExtractFormat) {
        let preview = ExtractPreview.make(
            archiveName: "notes.txt", format: format, archiveEntries: ["notes.txt"],
            namesInFolder: ["notes.txt"])
        #expect(preview.collidingHere == 1)
        #expect(preview.takenGzOutput == nil)
    }

    // MARK: Which skip-existing flag this tar takes

    /// A far side's `tar`, as the probe can see it: the set of long flags it
    /// accepts. Each probe plan names exactly one, so the double answers by
    /// looking for it in the plan's own words -- which also pins that the
    /// plan asks per flag rather than once for both.
    private struct ProbeRunner: ArchiveRunner {
        /// The three flavours measured 2026-10-09, by what they accept.
        static let gnu: Set<String> = ["--skip-old-files", "--keep-old-files"]
        static let bsd: Set<String> = ["--keep-old-files"]
        static let busybox: Set<String> = []

        let accepts: Set<String>
        /// Raised instead of an exit status, for the failures that are not
        /// answers.
        let failure: ArchiveFailure?

        init(accepts: Set<String> = ProbeRunner.gnu, failure: ArchiveFailure? = nil) {
            self.accepts = accepts
            self.failure = failure
        }

        func run(_ plan: ArchivePlan) async throws -> ArchiveOutcome { .finished }
        func listing(_ plan: ArchivePlan, limit: Int) async throws -> [String] {
            if let failure { throw failure }
            let asked = plan.words.compactMap { word -> String? in
                if case .flag(let value) = word, value != "--version" { value } else { nil }
            }
            guard asked.allSatisfy(accepts.contains) else {
                throw ArchiveFailure.exited(status: 1)
            }
            return ["tar (a flavour) 1.0"]
        }
    }

    @Test func aTarThatTakesTheSkipFlagIsAskedForIt() async throws {
        let flavour = try await ArchivePreparation.tarSkipExisting(
            in: "/d", runner: ProbeRunner(accepts: ProbeRunner.gnu))
        #expect(flavour == .skipOldFiles)
    }

    /// Each probe plan names ONE flag and `--version`, which is what makes
    /// the three cases above distinguishable at all: a single plan naming
    /// both flags would be rejected by every flavour that takes only one.
    @Test(arguments: [TarSkipExisting.skipOldFiles, .keepOldFiles])
    func eachProbePlanAsksForOneFlagAndNothingElse(flavour: TarSkipExisting) {
        let plan = ArchivePlan.tarSkipExistingProbe(for: flavour, workingDirectory: "/d")
        #expect(plan.tool == "tar")
        #expect(plan.words == [.flag(flavour.flag), .flag("--version")])
    }

    /// A tar that takes NEITHER long flag must not be handed one. Measured
    /// 2026-10-09 in the rig against BusyBox v1.37.0, which is what an
    /// Alpine, OpenWrt or NAS remote runs: `busybox tar --skip-old-files
    /// --version` and `busybox tar --keep-old-files --version` both printed
    /// `tar: unrecognized option: …` and exited 1, and `busybox tar
    /// --keep-old-files -xf t.tar` extracted NOTHING and exited 1.
    @Test func aTarThatTakesNeitherFlagIsRefusedRatherThanGivenOne() async {
        await #expect(throws: ArchiveRefusal.tarHasNoSkipExistingFlag) {
            try await ArchivePreparation.tarSkipExisting(
                in: "/d", runner: ProbeRunner(accepts: ProbeRunner.busybox))
        }
    }

    @Test func aTarThatTakesOnlyTheKeepFlagIsAskedForThatOne() async throws {
        let flavour = try await ArchivePreparation.tarSkipExisting(
            in: "/d", runner: ProbeRunner(accepts: ProbeRunner.bsd))
        #expect(flavour == .keepOldFiles)
    }

    /// A non-zero status is an ANSWER; a missing tool and a timeout are not,
    /// and must reach the user while the dialog is being built rather than
    /// after Extract is pressed.
    @Test(arguments: [ArchiveFailure.toolMissing(tool: "tar"), .timedOut])
    func aFailureThatIsNotAnAnswerIsNotSwallowed(failure: ArchiveFailure) async {
        await #expect(throws: failure) {
            try await ArchivePreparation.tarSkipExisting(
                in: "/d", runner: ProbeRunner(accepts: ProbeRunner.gnu, failure: failure))
        }
    }

    /// The real local tool, which is bsdtar: it rejects `--skip-old-files`
    /// (`tar: Option --skip-old-files is not supported`, exit 1, measured
    /// 2026-10-09), so the probe must come back with the flag both
    /// flavours accept. The GNU answer is the rig case
    /// `aRemoteTarExtractionOntoAnExistingNameFinishes`.
    @Test func theLocalTarTakesKeepOldFiles() async throws {
        let flavour = try await ArchivePreparation.tarSkipExisting(
            in: NSTemporaryDirectory(), runner: LocalArchiveRunner())
        #expect(flavour == .keepOldFiles)
    }

    /// The whole local path, with the real tools: a tarball extracted over a
    /// name that is already there keeps the old file, extracts the rest, and
    /// is reported as FINISHED. This is the local half of the finding; GNU
    /// tar's half can only be shown against the rig.
    @Test func aLocalTarExtractionOntoAnExistingNameFinishes() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("A".utf8).write(to: dir.appendingPathComponent("a"))
        try Data("B".utf8).write(to: dir.appendingPathComponent("b"))
        let pack = try ArchivePlan.compress(
            .tarGz, selection: [Self.item("a"), Self.item("b")],
            workingDirectory: dir.path, namesInFolder: ["a", "b"])
        #expect(try await LocalArchiveRunner().run(pack) == .finished)
        try Data("old".utf8).write(to: dir.appendingPathComponent("a"))
        // `b` is removed so the archive carries one colliding entry and one
        // that has to be written. Fix round 2: without it both halves of the
        // outcome were satisfied by a run that wrote nothing -- a plant that
        // turned `-xzf` into `-tzf` was caught by the rig twin and NOT by
        // this case (measured 2026-10-09, `scripts/mutation-probe`).
        try FileManager.default.removeItem(at: dir.appendingPathComponent("b"))

        let archive = RemoteFileItem(
            name: pack.title, path: dir.appendingPathComponent(pack.title).path, kind: .file)
        let preparation = try await ArchivePreparation.extractPreview(
            archive: archive, format: .tarGz, in: dir.path,
            fileSystem: LocalFileSystem(), runner: LocalArchiveRunner())
        #expect(preparation.preview.collidingHere == 1)
        let extract = try ArchivePlan.extract(
            archive, format: .tarGz, workingDirectory: dir.path, into: .thisFolder,
            tarSkipExisting: preparation.tarSkipExisting)
        #expect(try await LocalArchiveRunner().run(extract) == .finished)
        #expect(
            try Data(contentsOf: dir.appendingPathComponent("a")) == Data("old".utf8))
        #expect(
            try Data(contentsOf: dir.appendingPathComponent("b")) == Data("B".utf8))
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
            archive, format: extractFormat, workingDirectory: dir.path, into: destination,
            // The LOCAL tool is bsdtar, which takes only this flag; measured
            // through the real tool by `theLocalTarTakesKeepOldFiles`.
            tarSkipExisting: .keepOldFiles)
        #expect(try await LocalArchiveRunner().run(extract) == .finished)

        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("out/a.txt").path))
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("a.txt").path))
    }
}
