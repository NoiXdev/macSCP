import Foundation
import Testing

/// Guards how the transfer bar offers a row's FULL paths on demand: a hover
/// hint carrying both, and a "Copy paths" item in the row's context menu.
///
/// Same shape and same reasoning as `TransferQueueBarCancelGuardTests`, and
/// literally the same scanner — `declarationBody(of:in:)` and
/// `occurrenceCount(of:in:)` are reused from it rather than copied, so the
/// brace counter has one implementation and one set of self-tests. Each
/// affordance is a named declaration in `TransferQueueBar.swift`, so the
/// region searched is a brace-balanced body rather than a guessed window.
///
/// What is left for a scan, again, is the WIRING. The mapping from an item
/// to two display paths is a Core value type held by
/// `TransferRowPathsTests` over every direction/`crossRemote` combination;
/// nothing here re-tests it. What no Core test can see is whether the view
/// asks for it at all, whether the answer reaches a `.help` and a context
/// menu, and whether the bar is handed the session name that qualifies a
/// remote path — three facts that live only in this file and in the one
/// line of `ContentView+Detail.swift` that builds the bar.
///
/// Known blind spots, so a green run is not read as more than it is:
/// - SOURCE TEXT, never a rendered view. Nothing here can tell whether a
///   tooltip appears on hover or whether the menu item is reachable.
/// - The scanner does not know about string literals or comments; CLAUDE.md
///   records a case where a guard read an explanatory comment that quoted
///   the code it described. The bodies read here are short and carry no
///   quoting comment today.
/// - The catalogue keys are spelled as literals below. That is a second
///   copy of each key, and it is the copy a rename has to update — the
///   checks are positive, so a rename turns them red rather than passing
///   over a bar that no longer offers the affordance.
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

    private static func barSource() throws -> String {
        try String(contentsOf: barFile, encoding: .utf8)
    }

    private static func body(of declaration: String) throws -> String {
        try TransferQueueBarCancelGuardTests.declarationBody(
            of: declaration, in: try barSource())
    }

    // MARK: - The guard

    @Test func theHintIsBuiltFromTheQueuesOwnPathFold() throws {
        let body = try Self.body(of: Self.hintDeclaration)
        #expect(body.contains("TransferRowPaths(item: item, sessionName: sessionName)"), """
            The row's hint must come from the Core fold, asked with the bar's own \
            session name -- a second derivation here would decide which side of a \
            transfer is local all over again, and would drift from what the \
            clipboard text says.
            """)
        #expect(body.contains("\"transfers.paths.hint %1$@ %2$@\""), """
            The two-line hint must be assembled from the transfers.paths.hint \
            catalogue key, so a translation can label and order the two paths \
            itself.
            """)
    }

    @Test func copyPathsIsOfferedAndPutsTheSameTwoLinesOnThePasteboard() throws {
        let body = try Self.body(of: Self.copyDeclaration)
        #expect(body.contains("\"transfers.paths.copy\""), """
            The context-menu item must take its label from the \
            transfers.paths.copy catalogue key, not from a hardcoded string.
            """)
        #expect(body.contains("TransferRowPaths(item: item, sessionName: sessionName)"), """
            Copy paths must copy the same fold the hint shows -- a copy assembled \
            separately would be free to disagree with what the row displayed.
            """)
        #expect(body.contains(".clipboardText"), """
            The pasteboard text is the fold's own one-path-per-line rendering, \
            held by TransferRowPathsTests; the bar must not re-join the two \
            paths with a separator of its own.
            """)
        #expect(body.contains("NSPasteboard.general"), """
            Copy paths must actually reach the pasteboard.
            """)
    }

    /// The positive anchor the checks above need. Both read a DECLARATION;
    /// a declaration that nothing places in the row would leave them green
    /// over an affordance the user can never reach. Each name must
    /// therefore occur twice: once declared, once placed.
    @Test func bothAffordancesAreActuallyPlacedOnTheRow() throws {
        let source = try Self.barSource()
        let hintUses = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: "pathsHint(", in: source)
        #expect(hintUses == 2, """
            pathsHint( must be declared once and called once from the row \
            builder -- found \(hintUses) mentions.
            """)
        let copyUses = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: "copyPathsButton(", in: source)
        #expect(copyUses == 2, """
            copyPathsButton( must be declared once and called once from the row \
            builder -- found \(copyUses) mentions.
            """)

        let rowBody = try Self.body(of: Self.rowDeclaration)
        #expect(rowBody.contains(".help(pathsHint(item))"), """
            The hint must hang on the row itself, so hovering anywhere on the \
            row answers "which file, going where?".
            """)
        #expect(rowBody.contains(".contextMenu {"), """
            Copy paths must live in the row's own context menu -- that is the \
            "on demand" the row has room for.
            """)
        #expect(rowBody.contains("copyPathsButton(item)"), """
            The context menu must be built from the named declaration this \
            suite reads, not from an inline button that no check can find.
            """)
    }

    /// The session name is what turns a bare remote path into one the user
    /// can place. It is not something the bar can derive, so it has to be
    /// handed in -- and a stored property nobody passes would silently be
    /// `nil` for every row.
    @Test func theBarIsHandedTheSessionNameThatQualifiesARemotePath() throws {
        // Computed before the expectation, so a failure reports the claim
        // rather than dumping a whole source file into the run's output.
        let barTakesIt = try Self.barSource().contains("let sessionName: String?")
        #expect(barTakesIt, """
            The bar must take the queue's own session name as an input; without \
            it every remote path in the hint reads as an unqualified path.
            """)

        let detail = try String(contentsOf: Self.detailFile, encoding: .utf8)
        let windowPassesIt = detail.contains(
            "TransferQueueBar(viewModel: tab.transferQueue, sessionName: tab.titleName)")
        #expect(windowPassesIt, """
            The window must pass the TAB's own display name -- titleName rather \
            than displayTitle, so a tab that has no name yet qualifies nothing \
            instead of qualifying every path with "New Connection".
            """)
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    @Test func scannerSeesAHintAssembledWithoutTheFold() throws {
        let source = """
            \(Self.hintDeclaration)_ item: Item) -> String {
                "\\(item.fileName) -> \\(item.destinationDirectory)"
            }
            """
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.hintDeclaration, in: source)
        #expect(!body.contains("TransferRowPaths(item: item, sessionName: sessionName)"), """
            the scanner must report a hint the view derived itself, not wave it \
            through because it mentions the item's paths at all
            """)
    }

    @Test func scannerSeesACopyThatRejoinsThePathsItself() throws {
        let source = """
            \(Self.copyDeclaration)_ item: Item) -> some View {
                Button(L10n.string("transfers.paths.copy", "Copy paths")) {
                    let paths = TransferRowPaths(item: item, sessionName: sessionName)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        paths.source + " | " + paths.destination, forType: .string)
                }
            }
            """
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.copyDeclaration, in: source)
        #expect(!body.contains(".clipboardText"), """
            the scanner must report a separator invented in the view, not accept \
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
