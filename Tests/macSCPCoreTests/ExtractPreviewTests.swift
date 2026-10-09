import Testing
import Foundation
@testable import macSCPCore

@Suite(.timeLimit(.minutes(1)))
struct ExtractPreviewTests {
    @Test func theListingCommandForAZipAsksUnzipForNamesOnly() {
        let plan = ArchivePlan.listing(
            of: "ar.zip", format: .zip, workingDirectory: "/d")
        #expect(plan.tool == "unzip")
        #expect(plan.words == [.flag("-Z1"), .operand("./ar.zip")])
    }

    @Test func theListingCommandForATarballAsksTarForNamesOnly() {
        let plan = ArchivePlan.listing(
            of: "ar.tar.gz", format: .tarGz, workingDirectory: "/d")
        #expect(plan.tool == "tar")
        #expect(plan.words == [.flag("-tzf"), .operand("./ar.tar.gz")])
    }

    /// The uncompressed tarball has its own flag; reading it with `-tzf`
    /// would ask `gzip` to decompress something that is not gzip.
    @Test func theListingCommandForAPlainTarDoesNotAskForDecompression() {
        let plan = ArchivePlan.listing(
            of: "ar.tar", format: .tar, workingDirectory: "/d")
        #expect(plan.tool == "tar")
        #expect(plan.words == [.flag("-tf"), .operand("./ar.tar")])
    }

    /// The archive's name is the one user-controlled word, so a name that
    /// begins with a dash must still arrive as an operand.
    @Test func theArchivesNameIsAnOperandEvenWhenItBeginsWithADash() {
        let plan = ArchivePlan.listing(
            of: "-v.zip", format: .zip, workingDirectory: "/d")
        #expect(plan.words.last == .operand("./-v.zip"))
        #expect(plan.words.dropLast().allSatisfy { word in
            if case .flag = word { true } else { false }
        })
    }

    /// A `.gz` holds exactly one file and no listing tool is needed: the
    /// name is the archive's own, minus the extension.
    @Test func aGzNeedsNoListingBecauseItsOneEntryIsItsName() {
        let preview = ExtractPreview.make(
            archiveName: "big.log.gz", format: .gz,
            archiveEntries: nil, namesInFolder: ["big.log"])
        #expect(preview.entryCount == 1)
        #expect(preview.collidingHere == 1)
        #expect(preview.allowsSubfolder == false)
    }

    @Test func theCollisionCountIsTheOverlapWithTheFolder() {
        let preview = ExtractPreview.make(
            archiveName: "ar.zip", format: .zip,
            archiveEntries: ["a", "b", "c/d"], namesInFolder: ["a", "z"])
        #expect(preview.entryCount == 3)
        #expect(preview.collidingHere == 1)
        #expect(preview.allowsSubfolder)
    }

    /// An entry inside the archive's own subdirectory collides on its TOP
    /// component, because that is what extraction creates in this folder.
    @Test func anEntryDeepInTheArchiveCollidesOnItsTopComponent() {
        let preview = ExtractPreview.make(
            archiveName: "ar.zip", format: .zip,
            archiveEntries: ["top/", "top/a", "top/b"], namesInFolder: ["top"])
        #expect(preview.collidingHere == 1)
    }

    /// `tar` lists an archive built from `.` as `./a`, `./top/b`. Read
    /// naively the top component of every entry is `.`, which no folder
    /// holds, so the count would be zero where extraction overwrites-or-
    /// skips real names: an under-report, the direction this feature must
    /// not be wrong in.
    @Test func aLeadingDotSlashDoesNotHideTheRealTopComponent() {
        let preview = ExtractPreview.make(
            archiveName: "ar.tar", format: .tar,
            archiveEntries: ["./", "./a", "./top/", "./top/b"],
            namesInFolder: ["a", "top", "z"])
        #expect(preview.collidingHere == 2)
    }

    @Test func theProposedSubfolderDropsTheExtensionAndIsFree() {
        let preview = ExtractPreview.make(
            archiveName: "backup.tar.gz", format: .tarGz,
            archiveEntries: ["a"], namesInFolder: ["backup", "backup 2"])
        #expect(preview.proposedSubfolder == "backup 3")
    }

    @Test func aTgzDropsItsWholeExtensionToo() {
        let preview = ExtractPreview.make(
            archiveName: "site.TGZ", format: .tarGz,
            archiveEntries: ["a"], namesInFolder: [])
        #expect(preview.proposedSubfolder == "site")
    }

    @Test func aGzRefusesASubfolderPlanBelowTheUserInterfaceToo() {
        #expect(throws: ArchiveRefusal.gzExtractsIntoThisFolderOnly) {
            try ArchivePlan.extract(
                RemoteFileItem(name: "f.gz", path: "/d/f.gz", kind: .file),
                format: .gz, workingDirectory: "/d", into: .subfolder("f"))
        }
    }

    /// The name the user types goes into `-d ./<name>` / `-C ./<name>` as an
    /// operand, so what it must not be is a path of its own: a separator
    /// would leave the folder, and `.`/`..` would name one that exists.
    @Test func aSubfolderNameIsOneNewComponent() {
        #expect(ExtractPreview.isUsableSubfolderName("backup 2"))
        #expect(ExtractPreview.isUsableSubfolderName("-v2"))
        #expect(ExtractPreview.isUsableSubfolderName("a.b"))
        #expect(ExtractPreview.isUsableSubfolderName("") == false)
        #expect(ExtractPreview.isUsableSubfolderName("   ") == false)
        #expect(ExtractPreview.isUsableSubfolderName(".") == false)
        #expect(ExtractPreview.isUsableSubfolderName("..") == false)
        #expect(ExtractPreview.isUsableSubfolderName("a/b") == false)
        #expect(ExtractPreview.isUsableSubfolderName("/abs") == false)
        #expect(ExtractPreview.isUsableSubfolderName("a\nb") == false)
        #expect(ExtractPreview.isUsableSubfolderName("a\0b") == false)
        #expect(ExtractPreview.isUsableSubfolderName("a\r\nb") == false)
    }

    // MARK: Fix round 1

    /// APFS is case-insensitive and normalization-insensitive: with `A.txt`
    /// present, `unzip -n` of an archive holding `a.txt` creates nothing. A
    /// case-sensitive comparison says 0 collisions and then the entry is
    /// silently skipped, which is the dialog's whole purpose failing.
    @Test func aDifferentlyCasedNameInTheFolderIsACollision() {
        let preview = ExtractPreview.make(
            archiveName: "ar.zip", format: .zip,
            archiveEntries: ["a.txt"], namesInFolder: ["A.txt"])
        #expect(preview.collidingHere == 1)
    }

    /// `e` + U+0301 and U+00E9 are one name to the file system.
    ///
    /// A regression guard, not a pin on the
    /// `precomposedStringWithCanonicalMapping` call in
    /// `ArchiveNaming.folded`: this
    /// case was GREEN BEFORE the fold was added, because Swift's `String`
    /// equality is already canonical-equivalence based, so removing the fold
    /// does not turn it red. It guards the behaviour (one name, one
    /// collision), not the mechanism that currently provides it.
    @Test func aDifferentlyNormalizedNameInTheFolderIsACollision() {
        let preview = ExtractPreview.make(
            archiveName: "ar.zip", format: .zip,
            archiveEntries: ["caf\u{65}\u{301}"], namesInFolder: ["caf\u{E9}"])
        #expect(preview.collidingHere == 1)
    }

    /// Two entries that differ only by case are ONE name on such a file
    /// system, so they count once against one folder name.
    @Test func entriesThatFoldToTheSameNameCountOnce() {
        let preview = ExtractPreview.make(
            archiveName: "ar.zip", format: .zip,
            archiveEntries: ["a.txt", "A.TXT"], namesInFolder: ["A.txt"])
        #expect(preview.collidingHere == 1)
    }

    /// The prefill is held to the same comparison: with a folder `Backup`
    /// present, `backup.zip` must not propose `backup`, which would extract
    /// into the existing directory.
    @Test func theProposedSubfolderAvoidsADifferentlyCasedFolder() {
        let preview = ExtractPreview.make(
            archiveName: "backup.zip", format: .zip,
            archiveEntries: ["a"], namesInFolder: ["Backup"])
        #expect(preview.proposedSubfolder == "backup 2")
    }

    @Test func theProposedSubfolderKeepsTheArchivesOwnCaseWhenItIsFree() {
        let preview = ExtractPreview.make(
            archiveName: "Backup.zip", format: .zip,
            archiveEntries: ["a"], namesInFolder: ["other"])
        #expect(preview.proposedSubfolder == "Backup")
    }

    @Test func theProposedSubfolderSkipsEveryDifferentlyCasedCounterToo() {
        let preview = ExtractPreview.make(
            archiveName: "backup.zip", format: .zip,
            archiveEntries: ["a"], namesInFolder: ["BACKUP", "Backup 2"])
        #expect(preview.proposedSubfolder == "backup 3")
    }

    /// The entry count is the archive's entries, not its top-level names: a
    /// 300-entry archive under one folder is 300 entries.
    @Test func manyEntriesUnderOneTopAreStillManyEntries() {
        let entries = ["top/"] + (0..<299).map { "top/f\($0)" }
        let preview = ExtractPreview.make(
            archiveName: "ar.zip", format: .zip,
            archiveEntries: entries, namesInFolder: [])
        #expect(preview.entryCount == 300)
    }

    /// Every format drops ITS extension from the prefill.
    @Test(arguments: [
        ("site.zip", ArchiveExtractFormat.zip),
        ("site.tar", .tar),
        ("site.tar.gz", .tarGz),
        ("site.tgz", .tarGz),
        ("site.gz", .gz),
        ("SITE.ZIP", .zip),
    ] as [(String, ArchiveExtractFormat)])
    func everyFormatDropsItsOwnExtensionFromThePrefill(
        name: String, format: ArchiveExtractFormat
    ) {
        let preview = ExtractPreview.make(
            archiveName: name, format: format,
            archiveEntries: format == .gz ? nil : ["a"], namesInFolder: [])
        #expect(preview.proposedSubfolder == String(name.prefix(4)))
    }
}

// MARK: A typed subfolder name

extension ExtractPreviewTests {
    /// The sheet prefills a free name, but the user may type over it. A name
    /// that already exists would merge the archive into that folder -- or
    /// fail, where it is a file -- so the preview can say whether a typed
    /// name is taken, compared the way the file system compares.
    @Test func aTypedSubfolderNameThatExistsIsTaken() {
        let preview = ExtractPreview.make(
            archiveName: "ar.zip", format: .zip,
            archiveEntries: ["a"], namesInFolder: ["Docs", ".cache", "ar"])
        #expect(preview.isSubfolderNameTaken("Docs"))
        #expect(preview.isSubfolderNameTaken("docs"))
        #expect(preview.isSubfolderNameTaken("  Docs "))
        #expect(preview.isSubfolderNameTaken(".cache"))
        #expect(preview.isSubfolderNameTaken("caf\u{E9}") == false)
    }

    /// The positive beside the negatives above: the name the sheet prefills
    /// is by construction not taken, so the Extract button starts enabled.
    @Test func theProposedNameIsNeverTaken() {
        let preview = ExtractPreview.make(
            archiveName: "ar.zip", format: .zip,
            archiveEntries: ["a"], namesInFolder: ["ar", "AR 2"])
        #expect(preview.isSubfolderNameTaken(preview.proposedSubfolder) == false)
        #expect(preview.isSubfolderNameTaken("ar"))
        #expect(preview.isSubfolderNameTaken("Ar 2"))
    }
}
