import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// What an old version is called on disk, and that opening one is read-only.
///
/// The name is `VersionLocalName.forDownload`, which lives in Core; it is
/// tested here beside the open it serves because the two are one feature, and
/// the App is where the rule about the edit session is carried out.
@Suite("Version download and read-only open")
struct VersionDownloadTests {
    // MARK: - The local name

    @Test func twoVersionsOfOneKeyDoNotCollideOnDisk() {
        let a = VersionLocalName.forDownload(fileName: "doc.txt", versionId: "abc")
        let b = VersionLocalName.forDownload(fileName: "doc.txt", versionId: "def")
        #expect(a != b)
        #expect(a.hasSuffix(".txt"))
    }

    @Test func aVersionIdThatIsAPathSeparatorCannotEscapeTheName() {
        let name = VersionLocalName.forDownload(fileName: "doc.txt", versionId: "../../etc/x")
        let escapes = name.contains("/")
        #expect(escapes == false)
    }

    /// A version id is opaque text the STORE supplied. The brief's own check
    /// is a blacklist of one separator; these are the four shapes it lets
    /// through, and the name has to survive every one of them, plus the
    /// separators of the other platforms. The positive beside the list is the
    /// ordinary id, whose name carries the id it was given.
    @Test(arguments: [
        "../../etc/x", "..", ".", ".hidden", "a/b", "a\\b", "a\0b", "a:b", "\n", "  ",
        String(repeating: "x", count: 600), "ü\u{0301}ñ", "",
    ])
    func noIdProducesAnUnsafeName(_ id: String) {
        let name = VersionLocalName.forDownload(fileName: "doc.txt", versionId: id)
        #expect(name.contains("/") == false)
        #expect(name.contains("\0") == false)
        #expect(name.contains("\\") == false)
        #expect(name.contains(":") == false)
        #expect(name.contains("..") == false)
        #expect(name.hasPrefix(".") == false)
        #expect(name.hasSuffix(".txt"))
        #expect(name.utf8.count <= VersionLocalName.maxComponentBytes)
        #expect(name.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F })
    }

    @Test func anOrdinaryIdIsVisibleInTheNameItProduced() {
        let name = VersionLocalName.forDownload(
            fileName: "doc.txt", versionId: "3f2c9a10-0b7e-4c1d-9a55-6d1e2f3a4b5c")
        #expect(name.contains("3f2c9a10-0b7e-4c1d-9a55-6d1e2f3a4b5c"))
        #expect(name.hasPrefix("doc"))
        #expect(name.hasSuffix(".txt"))
    }

    /// The collision the first test exists to prevent, arriving through the
    /// sanitizer instead of through the id: ids that differ only in what is
    /// removed or replaced must still produce different names.
    @Test func idsThatSanitizeToTheSameTextStillGetDifferentNames() {
        let ids = [
            "a/b", "a?b", "a\0b", "a b", "ab", "a..b", "a\\b", "a:b",
            "Abc", "abc", "ABC",  // case-insensitive volumes fold these together
            "", " ", "..", ".", "...",
            String(repeating: "x", count: 300) + "1", String(repeating: "x", count: 300) + "2",
            "ü", "u\u{0308}", "é", "e\u{0301}",
        ]
        let names = ids.map { VersionLocalName.forDownload(fileName: "doc.txt", versionId: $0) }
        #expect(Set(names).count == ids.count)
        // Case-folded, as APFS compares by default.
        #expect(Set(names.map { $0.lowercased() }).count == ids.count)
        // And decomposed/precomposed forms of one name are one name there too.
        #expect(Set(names.map { $0.decomposedStringWithCanonicalMapping.lowercased() }).count == ids.count)
    }

    @Test func theSameInputsAlwaysGiveTheSameName() {
        let first = VersionLocalName.forDownload(fileName: "doc.txt", versionId: "a/b?c")
        let second = VersionLocalName.forDownload(fileName: "doc.txt", versionId: "a/b?c")
        #expect(first == second)
    }

    /// A name that is already near the component limit has no room for a
    /// suffix, so the stem gives way: the result fits, keeps its extension,
    /// and stays valid text where a multi-byte character straddled the cut.
    @Test func aLongFileNameIsShortenedNotOverflowed() {
        let cases: [(fileName: String, ext: String)] = [
            (String(repeating: "a", count: 250) + ".txt", ".txt"),
            (String(repeating: "é", count: 120) + ".txt", ".txt"),
            (String(repeating: "日", count: 90) + ".md", ".md"),
            (String(repeating: "👩‍👩‍👧‍👦", count: 20) + ".bin", ".bin"),
        ]
        for (fileName, ext) in cases {
            let name = VersionLocalName.forDownload(fileName: fileName, versionId: "3f2c9a10-0b7e")
            #expect(name.utf8.count <= VersionLocalName.maxComponentBytes)
            #expect(name.hasSuffix(ext))
            #expect(name.contains("3f2c9a10-0b7e"))
        }
        // The positive beside the limit: a short name is left whole.
        let short = VersionLocalName.forDownload(fileName: "short.txt", versionId: "3f2c9a10-0b7e")
        #expect(short.hasPrefix("short"))
    }

    @Test func aNameWithoutAnExtensionGetsTheSuffixAtTheEnd() {
        let name = VersionLocalName.forDownload(fileName: "Makefile", versionId: "abc")
        #expect(name.hasPrefix("Makefile"))
        #expect(name.contains("abc"))
        // A leading dot is not an extension: the suffix does not split it.
        let hidden = VersionLocalName.forDownload(fileName: ".bashrc", versionId: "abc")
        #expect(hidden.hasPrefix(".bashrc"))
        #expect(hidden.contains("abc"))
    }

    // MARK: - Read-only open

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func code(_ name: String) throws -> String {
        try SourceCorpus.code(of: repoRoot.appendingPathComponent("Sources/MacSCPAppKit/\(name)"))
    }

    /// Spec section 11.1: an old version is READ-ONLY. The edit session is
    /// what carries `destinationForUploads` (and starts the watcher that
    /// writes a save back), so opening a version must not go through it: a
    /// save in the opening application would otherwise overwrite the CURRENT
    /// object with an edit of an old one.
    ///
    /// The assertion is an ABSENCE, and an absence scanned for in a body that
    /// moved reads exactly like a satisfied check. So the positive half sits
    /// beside it: the ordinary open DOES register an upload destination
    /// (`beginEditing` with `destinationForUploads:`), the scan finds both
    /// bodies by name, and the version open DOES do what it is for.
    @Test func openingAnOldVersionRegistersNoUploadDestination() throws {
        let transfers = try Self.code("ContentView+Transfers.swift")

        // Positive: the ordinary open registers one.
        let ordinary = try #require(SourceSpan.body(after: "func openInEditor(", in: transfers))
        #expect(ordinary.contains("beginEditing("))
        #expect(ordinary.contains("destinationForUploads:"))

        // The version open exists, downloads through the version queue call
        // and takes its directory from the edit session's read-only area.
        let version = try #require(SourceSpan.body(after: "func openVersionReadOnly(", in: transfers))
        #expect(version.contains("enqueueAndWaitVersion("))
        #expect(version.contains("makeReadOnlyCopyDirectory("))

        // Negative: and none of the three ways to register a write-back.
        let registersEdit = version.contains("beginEditing")
        let namesUploadDestination = version.contains("destinationForUploads")
        let enqueuesWriteBack = version.contains("enqueueEditUpload")
        #expect(registersEdit == false)
        #expect(namesUploadDestination == false)
        #expect(enqueuesWriteBack == false)
    }

    /// The failure frame goes through the app's own label, as the ordinary
    /// open's does (`TransferFailureLabelGuardTests` holds that file to it),
    /// and its key is in all four catalogues.
    @Test func theOpenFailureFrameIsLocalizedInAllFourCatalogues() throws {
        let transfers = try SourceCorpus.commentFree(
            of: Self.repoRoot.appendingPathComponent("Sources/MacSCPAppKit/ContentView+Transfers.swift"))
        let key = "versions.openFailed"
        #expect(transfers.contains("\"\(key)\""))
        for locale in ["en", "de", "fr", "pl"] {
            let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent(
                "Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings"))
            let catalogue = try #require(
                try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            let text = try #require(catalogue[key], "\(locale) lacks \(key)")
            #expect(text.contains("%@"), "\(locale) lost the placeholder")
        }
    }
}
