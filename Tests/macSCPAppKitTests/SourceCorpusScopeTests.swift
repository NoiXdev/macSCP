import Foundation
import MacSCPTestSupport
import Testing

/// Pins `SourceCorpus` — the one read of `Sources/` and `Tests/` every
/// source-scanning guard in this target goes through — to the tree on
/// disk. The corpus replaced each guard's own walk; if its listing ever
/// came back short, every guard reading it would scan less and still pass,
/// because most of them look for something that must be ABSENT. So this is
/// the positive beside all of those negatives: every directory's listing,
/// recursive and direct, equals a direct walk of it, in the enumerator's
/// order, and every file's text and blanked views belong to that file.
///
/// The same check runs in both test targets because each test process
/// builds its own corpus (`SourceCorpusScope.check`).
@Suite("Source corpus scope")
struct SourceCorpusScopeTests {
    @Test(arguments: SourceCorpus.Root.allCases)
    func everyListingEqualsADirectWalk(root: SourceCorpus.Root) throws {
        let report = try SourceCorpusScope.check(root)
        #expect(report.mismatches.isEmpty, "\(report.mismatches.joined(separator: "\n"))")
        // Lower bounds, not the counts: a walk that collapsed would agree
        // with a corpus that collapsed the same way. Measured 2026-09-19
        // with `find <root> -name '*.swift' | wc -l`, counting this task's
        // own files: 384 under Sources, 506 under Tests.
        #expect(report.swiftFiles > 300, "only \(report.swiftFiles) Swift files under \(root.rawValue)")
        #expect(report.directWalkDirectories > 3, "only \(report.directWalkDirectories) directories")
    }

    /// The views are the shared stripper's output for the file they are
    /// looked up by, and the strict one really is blanked. Checked on the
    /// first Swift file of `Sources/` — a root whose views the guards in
    /// both targets read anyway, so this builds nothing extra — chosen by
    /// walk order rather than by name, so no rename can empty it.
    @Test func theViewsAreTheStrippersOutputForTheFile() throws {
        let url = try #require(
            try SourceCorpus.files(under: SourceCorpus.url(of: .sources)).first { $0.pathExtension == "swift" })
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(try SourceCorpus.text(of: url) == text)
        #expect(try SourceCorpus.code(of: url) == SwiftSource.blankingCommentsAndStrings(text))
        #expect(try SourceCorpus.commentFree(of: url) == SwiftSource.blankingComments(text))
        #expect(try SourceCorpus.code(of: url) != text, "nothing in \(url.lastPathComponent) was blanked")
    }

    /// A walk that meets an entry it cannot classify fails, as the type
    /// says a walk error does, instead of leaving the entry out of both the
    /// files and the directories (fix round 1, review M5). The entry is the
    /// first file a plain walk of `Sources/` lists, so no rename can empty
    /// the check.
    @Test func aWalkThatCannotClassifyAnEntryFailsRatherThanDroppingIt() throws {
        struct Unclassifiable: Error {}
        let root = SourceCorpus.url(of: .sources)
        let victim = try #require(SourceCorpus.walk(root).urls.first)
        let listing = SourceCorpus.walk(root) { url in
            if SourceCorpus.key(url) == SourceCorpus.key(victim) { throw Unclassifiable() }
            return try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        }
        #expect(listing.failure != nil, "a walk that could not classify an entry reported no failure")
        #expect(listing.failure?.contains(victim.lastPathComponent) == true)
    }

    /// A view that is not as long as its text is refused, so every guard
    /// that finds an offset in one view and slices another can rely on it
    /// for every file it reads (fix round 1, review M2). Beside it, the
    /// real stripper's view of the same text passes.
    @Test func aViewThatIsNotAsLongAsItsTextIsRefused() throws {
        let text = "let x = 1 // note"
        #expect(throws: SourceCorpus.CorpusError.self) {
            try SourceCorpus.lengthCheckedView(of: text, path: "planted.swift") {
                String(try SwiftSource.blankingComments($0).dropLast())
            }
        }
        let view = try SourceCorpus.lengthCheckedView(
            of: text, path: "planted.swift", blank: SwiftSource.blankingComments)
        #expect(view == (try SwiftSource.blankingComments(text)))
    }

    /// A path outside both roots, a directory the walk never saw, and a
    /// view of a file that is not Swift all throw — never an empty answer
    /// a guard could read as "nothing to find".
    @Test func whatTheCorpusDoesNotHoldIsRefused() {
        let root = SourceCorpus.packageRoot
        #expect(throws: SourceCorpus.CorpusError.self) {
            try SourceCorpus.text(of: root.appendingPathComponent("Package.swift"))
        }
        #expect(throws: SourceCorpus.CorpusError.self) {
            try SourceCorpus.files(under: root.appendingPathComponent("Sources/NoSuchDirectory"))
        }
        #expect(throws: SourceCorpus.CorpusError.self) {
            try SourceCorpus.code(
                of: root.appendingPathComponent("Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings"))
        }
        #expect(SourceCorpus.contains(URL(fileURLWithPath: #filePath)))
    }
}
