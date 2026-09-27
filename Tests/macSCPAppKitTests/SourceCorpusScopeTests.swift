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

    /// The corpus's own claim that nothing under `Sources/` or `Tests/` is
    /// written by a test, enforced (backlog: "The source-corpus guard plan's
    /// deferred minors", M6). Every write-API call site in `Tests/` is read,
    /// and none of them is handed a path rooted at the package —
    /// `TreeWriteScan`'s doc comment has what that can and cannot see.
    ///
    /// Only the files whose RAW text carries both a write spelling and a
    /// root spelling are blanked. The raw read is what the corpus caches
    /// anyway; blanking every Swift file under `Tests/` to reach the handful
    /// that carry both would be the expensive half of this scan and would
    /// change no answer.
    @Test func noTestWritesUnderTheTreeTheCorpusReads() throws {
        var examined = 0
        var violations: [String] = []
        var matched: Set<String> = []
        var rootsSeen: Set<String> = []
        for url in try SourceCorpus.files(under: SourceCorpus.url(of: .tests))
        where url.pathExtension == "swift" {
            let text = try SourceCorpus.text(of: url)
            let roots = TreeWriteScan.rootSpellings.filter { text.contains($0) }
            rootsSeen.formUnion(roots)
            let writes = TreeWriteScan.markers.filter { text.contains($0) }
            guard !writes.isEmpty else { continue }
            guard !roots.isEmpty else { continue }
            let sites = TreeWriteScan.sites(
                in: try SourceCorpus.code(of: url), file: url.lastPathComponent, markers: writes)
            examined += sites.count
            matched.formUnion(sites.map(\.marker))
            for site in sites {
                let roots = site.rootsNamed(among: TreeWriteScan.rootSpellings)
                guard !roots.isEmpty else { continue }
                violations.append(
                    "\(site.file):\(site.line) \(site.marker) names \(roots.joined(separator: ", "))")
            }
        }
        #expect(violations.isEmpty, """
            a test writes under a root the source corpus reads:
            \(violations.joined(separator: "\n"))
            The corpus reads a file the first time anything asks for it, so a write to a tree
            file mid-run is read before or after it depending on which test ran first. Write
            fixtures into a temporary directory instead.
            """)
        // The positives beside that filter. Without them it would go on
        // passing the day the spellings stopped matching anything — which
        // is exactly how a negative check goes stale in silence.
        // A lower bound, not the count, because a bound survives a file
        // being added. Measured 2026-09-27: the raw pre-filter admits 23
        // files, 19 of them produce sites, and those 19 produce 151. The
        // four that produce none spell every write marker they carry inside
        // a string literal or a comment — `TreeWriteScan` itself, this file
        // in both targets, and `CLISessionsCommandGuardTests` — which is
        // the blanking doing its job, not the scan missing them.
        #expect(examined > 100, """
            only \(examined) write call sites were examined in the files that name a package
            root at all — this scan is reading almost nothing.
            """)
        let dead = TreeWriteScan.liveMarkers.filter { !matched.contains($0) }
        #expect(dead.isEmpty, """
            \(dead.joined(separator: ", ")): recorded on 2026-09-27 as producing a site in
            these files, and producing none now. A renamed or retired API is not a violation,
            but a marker that matches nothing checks nothing — re-measure
            TreeWriteScan.liveMarkers.
            """)
        let unseenRoots = TreeWriteScan.rootSpellings.filter { !rootsSeen.contains($0) }
        #expect(unseenRoots.isEmpty, """
            \(unseenRoots.joined(separator: ", ")): no file under Tests/ spells the package
            root that way any more — the violation this scan looks for could no longer be
            written the way it looks for it.
            """)
    }

    /// The scanner reacts, over synthetic source: a write into the tree is
    /// seen, and the temporary-directory write it sits beside is not. Both
    /// halves in one fixture, because the value of this scan is exactly that
    /// it separates them — the two live in the same files and often in the
    /// same function.
    @Test func theWriteScanSeparatesATreeWriteFromATemporaryOne() {
        let source = """
            func plant(data: Data) throws {
                let temporary = FileManager.default.temporaryDirectory
                try data.write(to: temporary.appendingPathComponent("fixture.swift"))
                try data.write(to: repoRoot.appendingPathComponent("Sources/x.swift"))
                try FileManager.default.removeItem(at: temporary)
            }
            """
        let sites = TreeWriteScan.sites(
            in: source, file: "planted.swift", markers: TreeWriteScan.markers)
        #expect(sites.count == 3)
        let flagged = sites.filter { !$0.rootsNamed(among: TreeWriteScan.rootSpellings).isEmpty }
        #expect(flagged.count == 1)
        #expect(flagged.first?.line == 4)
        #expect(flagged.first?.marker == ".write(")
    }

    /// And the span is the CALL's, not the line's: a multi-line write whose
    /// root spelling sits on a later line is still one site, and a root
    /// spelling on a line of its own outside any call is not a site at all.
    @Test func theWriteScanReadsACallThatSpansLines() {
        let source = """
            func plant(data: Data) throws {
                let elsewhere = repoRoot.appendingPathComponent("Sources")
                try data.write(
                    to: repoRoot
                        .appendingPathComponent("Sources/x.swift"),
                    options: .atomic)
            }
            """
        let sites = TreeWriteScan.sites(
            in: source, file: "planted.swift", markers: TreeWriteScan.markers)
        #expect(sites.count == 1)
        #expect(sites.first?.rootsNamed(among: TreeWriteScan.rootSpellings) == ["repoRoot"])
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
