import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

/// Guards the halves of "a bucket row opens, nothing else" that no Core test
/// can reach: the four App-layer doors a transfer can be started from
/// (2026-09-02, Task 4; extended in fix round 1 after review C-1 found three
/// of them ungated).
///
/// The decision itself is Core's and is tested there
/// (`BrowserContextMenuTests`, `BrowserScopeTests`). What cannot be tested
/// there is whether each door ASKS it — the doors are SwiftUI modifiers and
/// `.disabled(...)` expressions, and this project renders no view in a test.
/// So this is a source scan, the same arrangement as
/// `GenerateKeyCaptionWiringGuardTests` and `SheetFacetWiringGuardTests`.
///
/// The doors, counted against the scans below — FOUR:
///
/// 1. the Finder drop (`BrowserPane.swift`, at both the handler and the
///    highlight — two places, one gate);
/// 2. the window toolbar's Upload button (`ContentView+Transfers.swift`);
/// 3. the same file's Download button — the one C-1 caught: a selected
///    bucket row enabled it and one click enqueued the whole bucket;
/// 4. the context menu and the Space key, which reach the destination
///    question through `RemoteFileTableView`'s `destinationScope` — checked
///    here as "the panes hand it over", since the two menus' own use of it
///    is Core's.
///
/// Most checks are POSITIVE — they require a name to be present. The
/// negative ones are the two "a pane does not build its OWN scope" checks
/// in `bothPanesHandTheirTableTheOtherPanesScope`, and each sits beside a
/// positive over the same brace-matched closure body, under a count that
/// must be exactly 2 — because a `!contains` alone starts matching nothing
/// the moment a symbol is renamed and reads exactly like a check that is
/// satisfied (CLAUDE.md, "Guards that name what they watch").
@Suite("Bucket-list transfer wiring")
struct BucketListTransferGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/BucketListTransferGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func sourceFile(_ relativePath: String) -> URL {
        repoRoot.appendingPathComponent(relativePath)
    }

    private static let paneSourceFile = sourceFile("Sources/MacSCPAppKit/BrowserPane.swift")
    private static let transfersSourceFile =
        sourceFile("Sources/MacSCPAppKit/ContentView+Transfers.swift")
    private static let detailSourceFile =
        sourceFile("Sources/MacSCPAppKit/ContentView+Detail.swift")
    private static let tableSourceFile =
        sourceFile("Sources/MacSCPAppKit/RemoteFileTableView.swift")

    /// Doc comments in every scanned file NAME the symbols the scans look
    /// for, so an unstripped read would find the prose and call it wiring —
    /// the exact collision CLAUDE.md records ("Source-scanning guards read
    /// comments too").
    ///
    /// BOTH comment kinds (review m-3): `ContentView+Detail.swift` has an
    /// inline `set: { _ in /* … */ }`, where a line comment cannot go.
    /// Read through `SwiftSource.blankingComments`: comments blanked,
    /// string literals KEPT. Not the strict view, which blanks a literal's
    /// interpolations too — the two negatives in
    /// `bothPanesHandTheirTableTheOtherPanesScope` must still see a
    /// `session.local.` read written inside `"\(…)"` (task 9 fix round 1:
    /// planted in the local pane's closure, that read was green under the
    /// strict view and is red here). Both comment strippers this suite used
    /// before 2026-09-18 kept literals too.
    ///
    /// The shared stripper blanks in place rather than removing, so the
    /// region windows below count a blanked comment's width where the old
    /// strippers counted one space (a block comment) or nothing (a line
    /// comment's tail). A long comment inside a window can push the gate
    /// out of it — a loud false red, never a silent pass.
    private static func strippedSource(_ url: URL) throws -> String {
        try stripped(try SourceCorpus.text(of: url))
    }

    /// The one view every scan in this suite reads, so the self-tests below
    /// measure the mode the scans use rather than a neighbour of it.
    private static func stripped(_ text: String) throws -> String {
        try SwiftSource.blankingComments(text)
    }

    /// The stripper does what the scans below assume, measured on a fixture
    /// that plants exactly the failure m-3 describes: a block comment
    /// QUOTING a gate name, beside a real line of wiring.
    ///
    /// Both halves matter — that the quoted name is gone (or every scan can
    /// be satisfied by prose) and that the wiring survives (or every scan
    /// finds nothing and says the gate is missing).
    @Test func theStripperRemovesQuotedProseAndKeepsWiring() throws {
        let planted = """
            /* the highlight reads \(Self.dropGate) here, or it used to */
            .strokeBorder(tint, lineWidth: isDropTargeted ? 2.5 : 0)
            let real = \(Self.dropGate)
            """

        let stripped = try Self.stripped(planted)

        #expect(stripped.contains("let real = \(Self.dropGate)"))
        #expect(!stripped.contains("or it used to"))
        // The name appears twice in the fixture; exactly the wiring one
        // survives.
        #expect(stripped.components(separatedBy: Self.dropGate).count - 1 == 1)
    }

    /// …and it does so on the REAL files. A line comment and a block
    /// comment, each quoting the anchor a scan depends on, are appended to
    /// each scanned file; after stripping, the anchor occurs exactly as
    /// often as in the stripped file alone, so both planted quotes were
    /// blanked in that file's own parse. (Until fix round 1 this test
    /// asserted no `/*` and no `//` survived in the strict view — which the
    /// strict view can never contain, since the shared stripper throws on an
    /// unterminated comment or literal and blanks every literal; the two
    /// checks could not fire.)
    ///
    /// The positive anchor beside it: the stripped text still carries a
    /// token each scan depends on, so this cannot be passing over an empty
    /// string.
    @Test func theScannedSourcesAreFullyStripped() throws {
        let files: [(URL, String)] = [
            (Self.paneSourceFile, ".onDrop(of: [.fileURL]"),
            (Self.transfersSourceFile, "func \(Self.toolbarGate)("),
            (Self.detailSourceFile, "BrowserPane("),
            (Self.tableSourceFile, "BrowserContextMenu.entries("),
        ]
        for (url, anchor) in files {
            let raw = try SourceCorpus.text(of: url)
            let stripped = try Self.stripped(raw)
            let planted = try Self.stripped(raw + "\n// \(anchor)\n/* \(anchor) */\n")
            let alone = stripped.components(separatedBy: anchor).count - 1
            let withQuotes = planted.components(separatedBy: anchor).count - 1
            #expect(withQuotes == alone, """
                \(url.lastPathComponent): a comment quoting "\(anchor)" survived the \
                stripper (\(withQuotes) occurrences, \(alone) without the quotes) — every \
                scan in this suite would then read that prose as wiring.
                """)
            #expect(stripped.contains(anchor), """
                \(url.lastPathComponent) lost "\(anchor)" to the stripper — \
                the scans below are reading a text that no longer holds the \
                code they are pointed at.
                """)
        }
    }

    // MARK: - Door 1: the Finder drop

    /// The pane's own drop gate, and the fact that it asks Core rather than
    /// re-deciding. Also the positive anchor for the two region scans below:
    /// without it, a pane that dropped the gate entirely would leave them
    /// scanning for a name that exists nowhere.
    @Test func theDropGateExistsAndAsksTheScopeForItsAnswer() throws {
        let source = try Self.strippedSource(Self.paneSourceFile)

        #expect(source.contains("private var \(Self.dropGate): Bool"), """
            BrowserPane.swift no longer declares `\(Self.dropGate)`. Either the \
            drop gate was renamed — rename it here too — or it was removed, \
            in which case a local folder can be dropped onto the bucket list \
            again and this guard has nothing left to watch.
            """)
        #expect(source.contains("scope.\(Self.sharedRule)"), """
            BrowserPane's drop gate no longer reads \
            `BrowserScope.\(Self.sharedRule)`; a second copy of the rule has \
            appeared in the App layer.
            """)
    }

    /// The drop HANDLER consults it — so a folder dropped on the bucket list
    /// is declined before a single transfer is queued.
    @Test func theDropHandlerConsultsTheGate() throws {
        let source = try Self.strippedSource(Self.paneSourceFile)
        let region = try Self.region(after: ".onDrop(of: [.fileURL]", in: source, length: 300)

        #expect(region.contains(Self.dropGate), """
            the .onDrop handler does not mention `\(Self.dropGate)` within 300 \
            characters of the modifier: \(region)
            """)
    }

    /// …and so does the HIGHLIGHT, so the pane never invites a drop it is
    /// going to refuse. Two doors, two checks: a gate wired into only the
    /// handler still lights the border up under the user's cursor.
    @Test func theDropHighlightConsultsTheGateToo() throws {
        let source = try Self.strippedSource(Self.paneSourceFile)
        let region = try Self.region(after: ".strokeBorder(tint", in: source, length: 200)

        #expect(region.contains(Self.dropGate), """
            the drop highlight does not mention `\(Self.dropGate)` within 200 \
            characters of `.strokeBorder(tint`: \(region)
            """)
    }

    // MARK: - Doors 2 and 3: the window toolbar's Upload and Download

    /// Both toolbar buttons ask the Core predicate rather than deciding for
    /// themselves — the C-1 fix. The old rule they carried is named in the
    /// failure message so a reader knows what regressing looks like.
    @Test func bothToolbarButtonsAskTheSharedPredicate() throws {
        let source = try Self.strippedSource(Self.transfersSourceFile)

        #expect(source.contains("BrowserContextMenu.entries("), """
            ContentView+Transfers.swift no longer asks \
            `BrowserContextMenu.entries` at all — the toolbar has gone back \
            to deciding for itself, and a selected bucket row enables \
            Download again.
            """)
        for button in ["uploadButton", "downloadButton"] {
            let region = try Self.region(after: "func \(button)(", in: source, length: 700)
            #expect(region.contains(".disabled(!\(Self.toolbarGate)("), """
                \(button)'s `.disabled(...)` no longer calls \
                `\(Self.toolbarGate)` — it decides for itself again \
                (the rule it used to carry, and that C-1 caught, was \
                `.disabled(!selected.contains { $0.kind != .symlink })`, \
                which a bucket row satisfies): \(region)
                """)
        }
    }

    /// …and that predicate really passes BOTH scopes, in both directions —
    /// a `destination:` that always said `.ordinary` would leave Upload
    /// enabled at the bucket list while looking wired.
    @Test func theToolbarPredicateCarriesBothDirections() throws {
        let source = try Self.strippedSource(Self.transfersSourceFile)
        let region = try Self.region(after: "func \(Self.toolbarGate)(", in: source, length: 600)

        #expect(region.contains("scope:") && region.contains("destination:"), """
            \(Self.toolbarGate) does not pass both `scope:` and \
            `destination:`, so one of the two directions is ungated: \(region)
            """)
        #expect(region.contains("localScope(session)") && region.contains("remoteScope(session)"), """
            \(Self.toolbarGate) no longer builds both panes' scopes, so it \
            cannot be answering for both directions: \(region)
            """)
    }

    // MARK: - Door 4: the context menu and the Space key

    /// Both panes hand their table the OTHER pane's scope. Without it the
    /// menu's `.transferToOtherPane` and the Space key fall back to
    /// `.ordinary` — offering a transfer into a bucket list.
    @Test func bothPanesHandTheirTableTheOtherPanesScope() throws {
        let detail = try Self.strippedSource(Self.detailSourceFile)

        let constructions = Self.paneConstructions(in: detail)
        // A COUNT that must match, and the positive anchor for everything
        // below: a file with no `BrowserPane(` left would otherwise give two
        // empty regions that satisfy every negative check in sight.
        #expect(constructions.count == 2, """
            ContentView+Detail.swift builds \(constructions.count) BrowserPane(s), \
            expected 2 — one per side. This guard reads them by position, so \
            it cannot say anything about a file of another shape.
            """)
        let localIndex = try #require(
            constructions.firstIndex { $0.contains("side: .local,") },
            "no BrowserPane construction in ContentView+Detail.swift says `side: .local,`")
        let remoteIndex = try #require(
            constructions.firstIndex { $0.contains("side: .remote,") },
            "no BrowserPane construction in ContentView+Detail.swift says `side: .remote,`")
        #expect(localIndex != remoteIndex, """
            one construction claims both sides, so the two regions below are \
            the same text and a swap between them cannot be seen.
            """)

        // The LOCAL pane's transfer destination is the REMOTE pane...
        let localDestination = try Self.destinationClosureBody(in: constructions[localIndex])
        #expect(localDestination.contains("session.remoteFS.rootIsContainerList")
            && localDestination.contains("session.remote.currentPath"), """
            the LOCAL pane's `destinationScope` does not build the REMOTE \
            pane's scope, so its "To the other pane" entry and its Space key \
            are decided against the wrong pane: \(localDestination)
            """)
        #expect(!localDestination.contains("session.localFS")
            && !localDestination.contains("session.local."), """
            the LOCAL pane's `destinationScope` builds its OWN scope — a pane \
            cannot be its own transfer destination, and a local pane always \
            answers "yes", so this offers a transfer into a bucket list: \
            \(localDestination)
            """)

        // ...and the REMOTE pane's is the LOCAL pane. The mirror, in its own
        // region, which is the whole point: the two used to be checked by a
        // file-wide `contains`, so exchanging the two closures satisfied
        // both while restoring half of C-1 (final review, I-4).
        let remoteDestination = try Self.destinationClosureBody(in: constructions[remoteIndex])
        #expect(remoteDestination.contains("session.localFS.rootIsContainerList")
            && remoteDestination.contains("session.local.currentPath"), """
            the REMOTE pane's `destinationScope` does not build the LOCAL \
            pane's scope: \(remoteDestination)
            """)
        #expect(!remoteDestination.contains("session.remoteFS")
            && !remoteDestination.contains("session.remote."), """
            the REMOTE pane's `destinationScope` builds its OWN scope: \
            \(remoteDestination)
            """)
    }

    /// And the pane forwards what it was handed. Separate from the check
    /// above because it reads a different file, and because these two are
    /// the "is it wired at all" half — the half that a swap leaves alone.
    @Test func bothPanesForwardTheScopesToTheirTable() throws {
        let pane = try Self.strippedSource(Self.paneSourceFile)

        #expect(pane.contains("destinationScope: destinationScope"), """
            BrowserPane no longer forwards `destinationScope` to \
            RemoteFileTableView, so both menus and the Space key fall back to \
            `BrowserScope.ordinary`.
            """)
        #expect(pane.contains("scope: scope"), """
            BrowserPane no longer forwards its own `scope` to \
            RemoteFileTableView, so the context menu and the keyboard fall \
            back to `BrowserScope.ordinary` and a bucket row offers \
            everything again.
            """)
    }

    /// One region per `BrowserPane(` construction, each running from its
    /// own marker to the NEXT construction (or the end of the file).
    ///
    /// The point is the boundary, not the extraction: every check on a
    /// pane's arguments has to be unable to read the other pane's. The
    /// version this replaced asked the whole file, so exchanging the two
    /// `destinationScope` closures left both of its `contains` satisfied
    /// while each pane was decided against itself (final review, I-4).
    private static func paneConstructions(in source: String) -> [String] {
        var starts: [String.Index] = []
        var searchStart = source.startIndex
        while let found = source.range(of: "BrowserPane(", range: searchStart..<source.endIndex) {
            starts.append(found.upperBound)
            searchStart = found.upperBound
        }
        return starts.enumerated().map { offset, start in
            String(source[start..<(offset + 1 < starts.count ? starts[offset + 1] : source.endIndex)])
        }
    }

    /// The body of one construction's `destinationScope:` closure,
    /// BRACE-MATCHED rather than taken as a fixed window.
    ///
    /// A window would have to be long enough to hold the closure and short
    /// enough to stop before the arguments after it — and the local pane's
    /// next arguments include `ChecksumAvailability.isOffered(byLocalFileSystem:
    /// session.localFS)`, which the negative check above is looking for. A
    /// span that reaches it fails for a reason that has nothing to do with
    /// the property (CLAUDE.md: a check whose span is wrong is not a check).
    private static func destinationClosureBody(in construction: String) throws -> String {
        let marker = "destinationScope: {"
        let markerRange = try #require(construction.range(of: marker), """
            this BrowserPane construction has no `\(marker)` — the pane is not \
            handed a transfer destination at all, and decides with \
            `BrowserScope.ordinary`.
            """)
        var depth = 1
        var index = markerRange.upperBound
        while index < construction.endIndex {
            switch construction[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(construction[markerRange.upperBound..<index]) }
            default: break
            }
            index = construction.index(after: index)
        }
        let balanced: String? = nil
        return try #require(balanced, """
            `\(marker)`'s braces are unbalanced in this construction, so its \
            body cannot be delimited.
            """)
    }

    /// …and the table then USES what it was handed, at both of the places
    /// that decide a transfer.
    ///
    /// This check exists because it was missing: a probe that left
    /// `BrowserPane`'s forwarding intact and made the coordinator's
    /// `currentDestinationScope` return `.ordinary` outright passed every
    /// other scan in this suite. CLAUDE.md's third guard rule, met in
    /// person — "mutation testing verifies a guard's sensitivity, never its
    /// scope"; the hole was found by planting a violation the author's own
    /// enumeration did not contain.
    ///
    /// A COUNT, not a `contains`: both consumers must pass it, and a count
    /// that must match fails loudly when one of them stops.
    @Test func theTableUsesTheScopesItWasHandedAtBothDecidingPlaces() throws {
        let source = try Self.strippedSource(Self.tableSourceFile)

        let derivation = try Self.region(
            after: "var currentDestinationScope: BrowserScope", in: source, length: 80)
        #expect(derivation.contains("destinationScope"), """
            `currentDestinationScope` no longer reads the `destinationScope`             it was handed — it answers out of thin air, and both menus fall             back to `BrowserScope.ordinary` while every wiring scan above             still passes: \(derivation)
            """)

        for (argument, expected) in [("destination: currentDestinationScope", 2), ("scope: scope", 2)] {
            let uses = source.components(separatedBy: argument).count - 1
            #expect(uses == expected, """
                `\(argument)` is passed \(uses) time(s) in                 RemoteFileTableView.swift, expected \(expected): the context                 menu (`menuNeedsUpdate`) and the keyboard (`dispatch`). A                 consumer that stopped passing it decides with                 `BrowserScope.ordinary`.
                """)
        }
    }

    // MARK: - Names, and the compile-time half

    /// The names the scans spell, in one place each. Spelled rather than
    /// derived because they name PRIVATE members of SwiftUI views, which no
    /// test can reach through the type system — the compile-time half is
    /// `coreStillOffersTheRuleTheAppLayerAsksFor` below, which stops
    /// compiling if Core's own rule is renamed out from under them.
    private static let dropGate = "acceptsDrop"
    private static let toolbarGate = "offersTransfer"
    private static let sharedRule = "acceptsIncomingFiles"

    /// Fails loudly when `marker` is absent, rather than returning an empty
    /// region that every `contains` below would then report as a miss with
    /// a misleading message — or, worse, that a `!contains` would report as
    /// satisfied.
    private static func region(
        after marker: String, in source: String, length: Int
    ) throws -> String {
        let markerRange = try #require(source.range(of: marker), """
            the scanned file no longer contains "\(marker)" — this guard is \
            pointed at a region that does not exist.
            """)
        let end = source.index(
            markerRange.upperBound, offsetBy: length, limitedBy: source.endIndex)
            ?? source.endIndex
        return String(source[markerRange.upperBound..<end])
    }

    /// The compile-time half of `sharedRule`: Core's property is referenced
    /// by name here, so renaming it breaks this file rather than leaving the
    /// scans above quietly looking for a string nothing writes any more.
    @Test func coreStillOffersTheRuleTheAppLayerAsksFor() {
        #expect(BrowserScope.ordinary.acceptsIncomingFiles)
        #expect(!BrowserScope(rootIsContainerList: true, currentPath: "/").acceptsIncomingFiles)
    }
}
