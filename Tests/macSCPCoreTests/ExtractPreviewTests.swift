import Testing
import Foundation
@testable import macSCPCore

@Suite(.timeLimit(.minutes(1)))
struct ExtractPreviewTests {
    @Test func thelistingCommandForAZipAsksUnzipForNamesOnly() {
        let plan = ArchivePlan.listing(
            of: "ar.zip", format: .zip, workingDirectory: "/d")
        #expect(plan.tool == "unzip")
        #expect(plan.words == [.flag("-Z1"), .operand("./ar.zip")])
    }

    @Test func thelistingCommandForATarballAsksTarForNamesOnly() {
        let plan = ArchivePlan.listing(
            of: "ar.tar.gz", format: .tarGz, workingDirectory: "/d")
        #expect(plan.tool == "tar")
        #expect(plan.words == [.flag("-tzf"), .operand("./ar.tar.gz")])
    }

    /// The uncompressed tarball has its own flag; reading it with `-tzf`
    /// would ask `gzip` to decompress something that is not gzip.
    @Test func thelistingCommandForAPlainTarDoesNotAskForDecompression() {
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
    @Test func agzNeedsNoListingBecauseItsOneEntryIsItsName() {
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

    @Test func agzRefusesASubfolderPlanBelowTheUserInterfaceToo() {
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
}
