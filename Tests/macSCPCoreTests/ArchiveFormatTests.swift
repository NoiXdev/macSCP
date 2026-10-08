import Testing
import Foundation
@testable import macSCPCore

@Suite(.timeLimit(.minutes(1)))
struct ArchiveFormatTests {
    private func file(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/d/" + name, kind: .file)
    }
    private func folder(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/d/" + name, kind: .directory)
    }

    @Test func eachCompressionFormatNamesItsOwnExtension() {
        #expect(ArchiveFormat.zip.fileExtension == "zip")
        #expect(ArchiveFormat.tarGz.fileExtension == "tar.gz")
        #expect(ArchiveFormat.gz.fileExtension == "gz")
    }

    @Test(arguments: [
        ("a.zip", ArchiveExtractFormat.zip),
        ("a.ZIP", ArchiveExtractFormat.zip),
        ("a.tar.gz", ArchiveExtractFormat.tarGz),
        ("a.tgz", ArchiveExtractFormat.tarGz),
        ("a.tar", ArchiveExtractFormat.tar),
        ("a.gz", ArchiveExtractFormat.gz),
    ])
    func anExtensionNamesTheExtractionFormat(name: String, expected: ArchiveExtractFormat) {
        #expect(ArchiveExtractFormat.detected(inName: name) == expected)
    }

    /// `.tar.gz` must win over `.gz`, or every tarball extracts as one
    /// gzipped file. The order of the checks is the whole content of this
    /// case, so it is pinned separately from the table above.
    @Test func tarGzIsNotReadAsGz() {
        #expect(ArchiveExtractFormat.detected(inName: "backup.tar.gz") == .tarGz)
        #expect(ArchiveExtractFormat.detected(inName: "backup.gz") == .gz)
    }

    @Test(arguments: ["a", "a.txt", "a.tar.bz2", "", ".gz "])
    func aNameThatClaimsNoKnownFormatIsNotDetected(name: String) {
        #expect(ArchiveExtractFormat.detected(inName: name) == nil)
    }

    @Test func oneFolderLendsItsNameToTheArchive() throws {
        let name = try ArchiveNaming.proposedName(format: .zip, selection: [folder("project")])
        #expect(name == "project.zip")
    }

    @Test func oneFileKeepsItsWholeNameIncludingItsExtension() throws {
        let name = try ArchiveNaming.proposedName(format: .tarGz, selection: [file("notes.txt")])
        #expect(name == "notes.txt.tar.gz")
    }

    /// Several objects have no shared name to inherit, so the archive gets a
    /// fixed one from Core's catalogue rather than the first row's name,
    /// which would read as if only that row were in it.
    ///
    /// Asserted against the CATALOGUE's answer, not against a literal, and
    /// with a positive beside it that the answer is not the fallback:
    /// `CoreL10n.string(_:)` returns the KEY when the key is missing
    /// (`localizedString(forKey: key, value: key, table: nil)`), so a case
    /// that only checked the suffix and the two row names would pass with no
    /// catalogue entry at all.
    @Test func severalObjectsGetTheCatalogueName() throws {
        let fallbackIsNotWhatWeGot = CoreL10n.string("core.archive.defaultName")
            != "core.archive.defaultName"
        #expect(fallbackIsNotWhatWeGot)
        let name = try ArchiveNaming.proposedName(
            format: .zip, selection: [file("a"), folder("b")])
        #expect(name == CoreL10n.string("core.archive.defaultName") + ".zip")
    }

    @Test func gzRefusesMoreThanOneObject() {
        #expect(throws: ArchiveRefusal.gzTakesExactlyOneFile(count: 2)) {
            try ArchiveNaming.proposedName(format: .gz, selection: [file("a"), file("b")])
        }
    }

    /// The positive beside the two gz refusals above. Without it a guard
    /// that refused EVERY gz selection would leave both of them green,
    /// which the reviewer demonstrated by forcing the kind guard false.
    @Test func gzAcceptsASingleFileAndAppendsItsExtension() throws {
        let name = try ArchiveNaming.proposedName(format: .gz, selection: [file("notes.txt")])
        #expect(name == "notes.txt.gz")
    }

    @Test func gzRefusesAFolder() {
        #expect(throws: ArchiveRefusal.gzTakesAFileNotAFolder(name: "d")) {
            try ArchiveNaming.proposedName(format: .gz, selection: [folder("d")])
        }
    }

    @Test func anEmptySelectionIsRefused() {
        #expect(throws: ArchiveRefusal.emptySelection) {
            try ArchiveNaming.proposedName(format: .zip, selection: [])
        }
    }

    @Test func afreeNameIsTheProposedOneWhenNothingIsTaken() {
        #expect(ArchiveNaming.free("a.zip", takenNames: ["b.zip"]) == "a.zip")
    }

    /// Every known extension, not only `.tar.gz`. `split`'s `known` list is
    /// a second copy of the format knowledge, and a missing entry sends the
    /// counter to the wrong side of the dot with nothing else going red:
    /// drop `"zip"` from it and `a.zip` counts up to `a.zip 2`, which is no
    /// longer a zip. The last two rows pin the uppercase path and the
    /// no-known-extension path the doc comment claims.
    @Test(arguments: [
        ("a.zip", "a 2.zip"),
        ("a.tar.gz", "a 2.tar.gz"),
        ("a.tgz", "a 2.tgz"),
        ("a.tar", "a 2.tar"),
        ("a.gz", "a 2.gz"),
        ("A.ZIP", "A 2.ZIP"),
        ("report.2026", "report.2026 2"),
        ("folder", "folder 2"),
    ])
    func afreeNameCountsBeforeEveryKnownExtension(taken: String, expected: String) {
        #expect(ArchiveNaming.free(taken, takenNames: [taken]) == expected)
    }

    @Test func afreeNameKeepsCountingWhileTheCandidateIsTaken() {
        #expect(
            ArchiveNaming.free("a.tar.gz", takenNames: ["a.tar.gz", "a 2.tar.gz"])
                == "a 3.tar.gz")
    }
}
