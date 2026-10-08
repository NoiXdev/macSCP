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
    @Test func severalObjectsGetTheCatalogueName() throws {
        let name = try ArchiveNaming.proposedName(
            format: .zip, selection: [file("a"), folder("b")])
        #expect(name.hasSuffix(".zip"))
        #expect(name != "a.zip")
        #expect(name != "b.zip")
    }

    @Test func gzRefusesMoreThanOneObject() {
        #expect(throws: ArchiveRefusal.gzTakesExactlyOneFile(count: 2)) {
            try ArchiveNaming.proposedName(format: .gz, selection: [file("a"), file("b")])
        }
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

    /// The counter goes before the whole extension, not before the last dot,
    /// or `a.tar.gz` becomes `a.tar 2.gz` and stops being a tarball.
    @Test func afreeNameCountsUpBeforeTheWholeExtension() {
        #expect(ArchiveNaming.free("a.tar.gz", takenNames: ["a.tar.gz"]) == "a 2.tar.gz")
        #expect(
            ArchiveNaming.free("a.tar.gz", takenNames: ["a.tar.gz", "a 2.tar.gz"])
                == "a 3.tar.gz")
    }

    @Test func afreeNameWithoutAnExtensionCountsAtItsEnd() {
        #expect(ArchiveNaming.free("folder", takenNames: ["folder"]) == "folder 2")
    }
}
