import Foundation
import Testing

/// Guards how the transfer bar offers a row's FULL paths on demand: a hover
/// hint carrying both, a hit region that covers the whole row, and a "Copy
/// paths" item in the row's context menu.
///
/// Same shape and same reasoning as `TransferQueueBarCancelGuardTests`, and
/// literally the same scanner — `declarationBodyRange(of:in:)` and
/// `occurrenceCount(of:in:)` are reused from it rather than copied, so the
/// brace counter has one implementation and one set of self-tests. Each
/// affordance is a named declaration in `TransferQueueBar.swift`, so the
/// region searched is a brace-balanced body rather than a guessed window.
///
/// What is left for a scan is the WIRING. The mapping from an item to two
/// display paths is a Core value type held by `TransferRowPathsTests` over
/// every direction/`crossRemote` combination; nothing here re-tests it.
/// What no Core test can see is whether the view asks for it at all,
/// whether the answer reaches a `.help` and a context menu, and whether the
/// bar is handed the session name that qualifies a remote path — facts that
/// live only in this file and in the one line of `ContentView+Detail.swift`
/// that builds the bar.
///
/// Every scan here reads STRIPPED source (`SwiftSource`), never the raw
/// file. The first version of this suite read the file verbatim, and the
/// hole was not theoretical: deleting `.help(pathsHint(item))` from the row
/// and leaving a sentence naming it in its place held the count anchor at
/// two, satisfied the row-body check, and left the whole suite green over
/// an affordance the user could no longer reach. Structural claims are made
/// against the strict view (comments AND string literals blanked); the two
/// catalogue-key claims are about a literal, so they read the view that
/// blanks comments only.
///
/// Known blind spots, so a green run is not read as more than it is:
/// - SOURCE TEXT, never a rendered view. Nothing here can tell whether a
///   tooltip appears on hover, whether the menu opens, or over which pixels
///   — only which expression the source hands to each modifier.
/// - The stripper is hand-rolled and refuses raw strings rather than
///   guessing (`SwiftSourceStrippingTests`); a bar that grew one would fail
///   this suite closed rather than be scanned wrongly.
/// - The catalogue keys and symbols are spelled as literals below. That is
///   a second copy of each name, and it is the copy a rename has to update
///   — the checks are positive, so a rename turns them red rather than
///   passing over a bar that no longer offers the affordance.
@Suite("Transfer bar full paths")
struct TransferQueueBarPathsGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/TransferQueueBarPathsGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let barFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/TransferQueueBar.swift")
    private static let detailFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Detail.swift")

    private static let hintDeclaration = "private func pathsHint("
    private static let copyDeclaration = "private func copyPathsButton("
    private static let rowDeclaration = "private func row("

    // The needles. One spelling each, shared by the checks against the real
    // files and by the scanner self-tests below, so a self-test cannot go
    // on demonstrating a rule the real check has stopped enforcing.
    private static let foldCall = "TransferRowPaths(item: item, sessionName: sessionName)"
    private static let hintKey = "\"transfers.paths.hint %1$@ %2$@\""
    private static let copyKey = "\"transfers.paths.copy\""
    private static let clipboardRendering = ".clipboardText"
    private static let pasteboard = "NSPasteboard.general"
    private static let hitRegion = ".contentShape(Rectangle())"
    private static let hintPlacement = ".help(pathsHint(item))"
    private static let menuPlacement = ".contextMenu {"
    private static let menuItemPlacement = "copyPathsButton(item)"
    private static let sessionNameInput = "let sessionName: String?"
    private static let barConstruction =
        "TransferQueueBar(viewModel: tab.transferQueue, sessionName: tab.titleName)"

    /// The two views of the bar this suite reads, both derived from one read
    /// of the file and both the same length as it (see `SwiftSource`), so a
    /// body span found in one can be sliced out of the other.
    private static func barViews() throws -> (code: String, withLiterals: String) {
        let raw = try String(contentsOf: barFile, encoding: .utf8)
        return (try SwiftSource.blankingCommentsAndStrings(raw),
                try SwiftSource.blankingComments(raw))
    }

    /// The window that builds the bar. Only ever read structurally, so the
    /// strict view is the only one needed.
    private static func detailCode() throws -> String {
        try SwiftSource.blankingCommentsAndStrings(
            try String(contentsOf: detailFile, encoding: .utf8))
    }

    private static func bodies(
        of declaration: String
    ) throws -> (code: String, withLiterals: String) {
        let views = try barViews()
        // The balance is counted on the strict view, where no brace can hide
        // inside a literal or a sentence; the literal view is sliced at the
        // same character positions.
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: declaration, in: views.code)
        return (TransferQueueBarCancelGuardTests.slice(range, of: views.code),
                TransferQueueBarCancelGuardTests.slice(range, of: views.withLiterals))
    }

    // MARK: - The guard

    @Test func theHintIsBuiltFromTheQueuesOwnPathFold() throws {
        let body = try Self.bodies(of: Self.hintDeclaration)
        #expect(body.code.contains(Self.foldCall), """
            The row's hint must come from the Core fold, asked with the bar's own \
            session name -- a second derivation here would decide which side of a \
            transfer is local all over again, and would drift from what the \
            clipboard text says.
            """)
        #expect(body.withLiterals.contains(Self.hintKey), """
            The two-line hint must be assembled from the transfers.paths.hint \
            catalogue key, so a translation can label and order the two paths \
            itself.
            """)
    }

    @Test func copyPathsIsOfferedAndPutsTheFoldsOwnRenderingOnThePasteboard() throws {
        let body = try Self.bodies(of: Self.copyDeclaration)
        #expect(body.withLiterals.contains(Self.copyKey), """
            The context-menu item must take its label from the \
            transfers.paths.copy catalogue key, not from a hardcoded string.
            """)
        #expect(body.code.contains(Self.foldCall), """
            Copy paths must copy the same fold the hint shows -- a copy assembled \
            separately would be free to disagree with what the row displayed.
            """)
        #expect(body.code.contains(Self.clipboardRendering), """
            The pasteboard text is the fold's own one-RAW-path-per-line rendering, \
            held by TransferRowPathsTests; a bar that re-joined the fold's two \
            DISPLAY strings would paste "/var/www/index.html (on prod-web)", \
            which is not a path.
            """)
        #expect(body.code.contains(Self.pasteboard), """
            Copy paths must actually reach the pasteboard.
            """)
    }

    /// The positive anchor the checks above need. Both read a DECLARATION;
    /// a declaration that nothing places in the row would leave them green
    /// over an affordance the user can never reach. Each name must
    /// therefore occur twice: once declared, once placed.
    ///
    /// Counted on the strict view, so prose about an affordance cannot
    /// stand in for the affordance.
    @Test func bothAffordancesAreActuallyPlacedOnTheRow() throws {
        let code = try Self.barViews().code
        let hintUses = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: "pathsHint(", in: code)
        #expect(hintUses == 2, """
            pathsHint( must be declared once and called once from the row \
            builder -- found \(hintUses) mentions in code.
            """)
        let copyUses = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: "copyPathsButton(", in: code)
        #expect(copyUses == 2, """
            copyPathsButton( must be declared once and called once from the row \
            builder -- found \(copyUses) mentions in code.
            """)

        let rowBody = try Self.bodies(of: Self.rowDeclaration).code
        #expect(rowBody.contains(Self.hintPlacement), """
            The hint must hang on the row itself, so hovering anywhere on the \
            row answers "which file, going where?".
            """)
        #expect(rowBody.contains(Self.menuPlacement), """
            Copy paths must live in the row's own context menu -- that is the \
            "on demand" the row has room for.
            """)
        #expect(rowBody.contains(Self.menuItemPlacement), """
            The context menu must be built from the named declaration this \
            suite reads, not from an inline button that no check can find.
            """)
    }

    /// The row is an `HStack` with no background and a `Spacer` that is most
    /// of its width for a short file name. SwiftUI hit-tests the drawn
    /// subviews, not the container's frame, so without a shape the hint and
    /// the menu answer only over the file name itself — and the check above
    /// cannot tell the difference, because it reads which modifiers are
    /// there and never where they respond.
    ///
    /// The idiom is the tree's own, three times over: `SessionSidebar`,
    /// `TabStripView` and `ContentView+Detail` each put
    /// `.contentShape(Rectangle())` immediately before the interaction
    /// modifier it is there to serve.
    /// PRESENCE is not placement, which is the same lesson one level down:
    /// a `.contentShape` that sits BELOW the two interaction modifiers
    /// shapes nothing they can use, because a modifier applies to what
    /// precedes it. The row would draw identically, this suite's other
    /// checks would all stay green, and the dead `Spacer` would be back.
    /// So the offsets are compared, in the strict view where a sentence
    /// naming a modifier cannot supply one.
    @Test func theRowCarriesAHitRegionCoveringItsEmptySpace() throws {
        let rowBody = try Self.bodies(of: Self.rowDeclaration).code
        // Computed before the expectation, so a failure reports the claim
        // rather than dumping the whole row builder into the output.
        let carriesHitRegion = rowBody.contains(Self.hitRegion)
        #expect(carriesHitRegion, """
            The row no longer sets .contentShape(Rectangle()) -- its hint and its \
            context menu would answer only over the drawn file name, not over the \
            Spacer that is most of a short row's width.
            """)

        let shapeAt = try #require(
            rowBody.range(of: Self.hitRegion)?.lowerBound,
            "no .contentShape(Rectangle()) in the row body -- see the check above")
        let hintAt = try #require(
            rowBody.range(of: Self.hintPlacement)?.lowerBound,
            "no .help(pathsHint(item)) in the row body -- re-anchor this check")
        let menuAt = try #require(
            rowBody.range(of: Self.menuPlacement)?.lowerBound,
            "no .contextMenu on the row -- re-anchor this check")
        let shapedBeforeTheHint = shapeAt < hintAt
        let shapedBeforeTheMenu = shapeAt < menuAt
        #expect(shapedBeforeTheHint, """
            .contentShape(Rectangle()) sits AFTER .help(pathsHint(item)), so the \
            hint attaches to the unshaped HStack and answers only over the drawn \
            file name.
            """)
        #expect(shapedBeforeTheMenu, """
            .contentShape(Rectangle()) sits AFTER .contextMenu, so the menu \
            attaches to the unshaped HStack and opens only over the drawn file \
            name -- not over the Spacer that is most of a short row's width.
            """)
    }

    /// The session name is what turns a bare remote path into one the user
    /// can place. It is not something the bar can derive, so it has to be
    /// handed in — and a stored property nobody passes would silently be
    /// `nil` for every row.
    @Test func theBarIsHandedTheSessionNameThatQualifiesARemotePath() throws {
        // Both computed before the expectation, so a failure reports the
        // claim rather than dumping a whole source file into the output.
        let barTakesIt = try Self.barViews().code.contains(Self.sessionNameInput)
        #expect(barTakesIt, """
            The bar must take the queue's own session name as an input; without \
            it every remote path in the hint reads as an unqualified path.
            """)

        let windowPassesIt = try Self.detailCode().contains(Self.barConstruction)
        #expect(windowPassesIt, """
            The window must pass the TAB's own display name -- titleName rather \
            than displayTitle, so a tab that has no name yet qualifies nothing \
            instead of qualifying every path with "New Connection".
            """)
    }

    /// What the two whole-file checks above would be worth nothing without:
    /// the strict views must actually be reaching the files they name. An
    /// empty or unreadable read makes every `contains` false — which those
    /// notice — but it would also satisfy any `!contains` in this suite.
    @Test func theStrictViewsStillContainTheCodeTheyName() throws {
        let readsTheBar = try Self.barViews().code.contains("struct TransferQueueBar: View")
        #expect(readsTheBar, """
            the strict view of TransferQueueBar.swift no longer contains the bar's \
            own declaration -- the stripper or the path is wrong, and every scan in \
            this suite is reading something other than the file it names
            """)
        let readsTheWindow = try Self.detailCode().contains("TransferQueueBar(")
        #expect(readsTheWindow, """
            the strict view of ContentView+Detail.swift no longer mentions the bar \
            at all -- the path is wrong, or the bar is placed somewhere this suite \
            does not look
            """)
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    /// The needles the negative self-tests use are the same constants the
    /// real-file checks read, so a needle can never name a string that
    /// appears nowhere in the tree — the way an unanchored copy would, going
    /// on passing while demonstrating nothing.
    @Test func theSelfTestsUseNeedlesTheBarActuallyContains() throws {
        let views = try Self.barViews()
        #expect(views.code.contains(Self.foldCall), """
            the fold needle names an expression TransferQueueBar.swift does not \
            contain, so scannerSeesAHintAssembledWithoutTheFold would be satisfied \
            by any body at all
            """)
        #expect(views.code.contains(Self.clipboardRendering), """
            the clipboard needle names an expression TransferQueueBar.swift does \
            not contain, so scannerSeesACopyThatRejoinsThePathsItself would be \
            satisfied by any body at all
            """)
        #expect(views.withLiterals.contains(Self.copyKey), """
            the catalogue-key needle names a literal TransferQueueBar.swift does \
            not contain
            """)
    }

    /// The probe that defeated the first version of this suite: the real
    /// placement deleted, a sentence naming it left behind. Against the raw
    /// file the count stays at two and the row body still "contains" the
    /// modifier; against the strict view both collapse.
    @Test func scannerSeesThroughACommentThatNamesTheAffordance() throws {
        let source = """
            \(Self.rowDeclaration)_ item: Item) -> some View {
                HStack { Text(item.fileName) }
                    .font(.system(size: 12))
                    // The row's hint comes from \(Self.hintPlacement).
                    \(Self.menuPlacement)
                        \(Self.menuItemPlacement)
                    }
            }
            """
        // Positive first: the scanner did read this body, and the placement
        // that is really there is found -- so the two negatives below report
        // the DELETED hint rather than an empty read.
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.rowDeclaration, in: code)
        #expect(body.contains(Self.menuItemPlacement))
        #expect(!body.contains(Self.hintPlacement), """
            the strict view must not let a sentence naming .help(pathsHint(item)) \
            stand in for the modifier itself
            """)
        #expect(TransferQueueBarCancelGuardTests.occurrenceCount(of: "pathsHint(", in: code) == 0,
                "a commented mention must not be counted as a placement")
    }

    /// The fixture is a hint the view assembled itself, out of the item's
    /// own fields, without asking the Core fold.
    ///
    /// The body carries a `return` that is NOT inside the literal, and that
    /// is the anchor rather than decoration: this fixture's payload is one
    /// interpolated string literal, which the strict view blanks whole —
    /// interpolations included. Without a token of its own outside the
    /// literal the negative below would be true of an empty read, of an
    /// off-by-one in `slice(_:of:)`, and of a `declarationBodyRange` that
    /// returned an empty span for every declaration — CLAUDE.md's "without
    /// one it is not a guard, it is a comment that runs". Both sibling
    /// self-tests carry such an anchor; this one used to be the exception.
    @Test func scannerSeesAHintAssembledWithoutTheFold() throws {
        let source = """
            \(Self.hintDeclaration)_ item: Item) -> String {
                return "\\(item.fileName) -> \\(item.destinationDirectory)"
            }
            """
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.hintDeclaration, in: try SwiftSource.blankingCommentsAndStrings(source))
        // Positive first: the body was really read, so the negative below
        // reports the missing fold rather than an empty span.
        #expect(body.contains("return"), """
            the strict view of this fixture's body is empty -- the scanner read \
            nothing, and the negative below would hold over any declaration at all
            """)
        #expect(!body.contains(Self.foldCall), """
            the scanner must report a hint the view derived itself, not wave it \
            through because it mentions the item's paths at all
            """)
    }

    @Test func scannerSeesACopyThatRejoinsThePathsItself() throws {
        let source = """
            \(Self.copyDeclaration)_ item: Item) -> some View {
                Button(L10n.string("transfers.paths.copy", "Copy paths")) {
                    let paths = \(Self.foldCall)
                    \(Self.pasteboard).clearContents()
                    \(Self.pasteboard).setString(
                        paths.source + "\\n" + paths.destination, forType: .string)
                }
            }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.copyDeclaration, in: code)
        // Positive first: the body was read and the fold IS consulted here,
        // so the negative below reports the invented rendering rather than
        // an empty read.
        #expect(body.contains(Self.foldCall))
        #expect(!body.contains(Self.clipboardRendering), """
            the scanner must report a rendering invented in the view, not accept \
            it because the fold was consulted for the two halves
            """)
    }

    @Test func scannerFailsClosedWhenAnAffordanceIsGone() {
        let source = "struct Bar: View { var body: some View { Text(\"hi\") } }"
        #expect(throws: (any Error).self) {
            try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.hintDeclaration, in: source)
        }
        #expect(throws: (any Error).self) {
            try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.copyDeclaration, in: source)
        }
    }
}
