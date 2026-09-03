import Foundation
import Testing

/// Guards how the transfer bar's two cancel controls are GATED — that the
/// "Cancel all" button beside "Clean up" is enabled exactly while the queue
/// reports open work, and that a row's cancel appears exactly while that row
/// can still be stopped.
///
/// Why a source scan at all, and why it can be aimed precisely here: the
/// decision itself does not live in this file. Both gates read a predicate
/// the queue owns and `macSCPCoreTests` pins over every status it can
/// produce (`isActive` in `isActiveReflectsPendingWork`, `isCancellable` in
/// `onlyQueuedAndRunningItemsAreCancellable`). What is left for a scan is
/// the wiring: that the view asks those predicates rather than re-deriving
/// the answer next to them, where the two spellings would drift apart
/// without either suite noticing. To make that a question a scan can answer
/// exactly, each control is a named declaration of its own in
/// `TransferQueueBar.swift`, so the region searched is a brace-balanced
/// body rather than a guessed window — the failure mode CLAUDE.md records
/// from the snippets guard, where a check looked for `.disabled(` inside an
/// argument list while the real greying attached after the trailing
/// closure, and therefore could not have matched a violation anywhere.
///
/// Every scan here reads STRIPPED source (`SwiftSource`), never the raw
/// file. The first version of this suite did read the raw file, and the hole
/// was not theoretical: a doc comment on `row(_:)` reading "the row's
/// trailing control comes from `cancelButton(item)`", planted together with
/// the deletion of the real placement, held the count anchor at two and left
/// all sixteen transfer-bar guard tests green — the anchor that exists to
/// catch a control the user can never reach was reading the sentence about
/// the control. Structural claims are made against the strict view (comments
/// AND string literals blanked); the two catalogue-key claims are about a
/// literal, so they read the view that blanks comments only.
///
/// Known blind spots, so a green run is not read as more than it is:
/// - SOURCE TEXT, never a rendered view. Nothing here can tell whether a
///   button is actually greyed out on screen, whether the row's cancel is
///   hit-testable, or what VoiceOver actually announces — only which
///   expression the source hands to each modifier.
/// - The stripper is hand-rolled and refuses raw strings rather than
///   guessing (`SwiftSourceStrippingTests`); a bar that grew one would fail
///   this suite closed rather than be scanned wrongly.
/// - The required expressions are spelled out as literals here. That is a
///   second copy of `isActive`/`isCancellable`, and it is the copy that
///   would need updating on a rename — the checks are positive, so a rename
///   turns them red rather than silently satisfying them. The negative
///   self-tests share those same constants and are held to the real file by
///   `theNegativeSelfTestsUseNeedlesTheBarActuallyContains`, so a needle
///   cannot drift into naming a string that exists nowhere.
@Suite("Transfer bar cancel controls")
struct TransferQueueBarCancelGuardTests {
    private enum ScanError: Error {
        case declarationNotFound(String)
        case bodyNotFound(String)
        case unbalancedBraces(String)
    }

    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/TransferQueueBarCancelGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/TransferQueueBar.swift")

    private static let cancelAllDeclaration = "private var cancelAllButton: some View"
    private static let rowCancelDeclaration = "private func cancelButton("

    // The needles. One spelling each, shared by the checks against the real
    // file and by the scanner self-tests below, so a self-test cannot go on
    // demonstrating a rule the real check has stopped enforcing.
    private static let cancelAllGate = ".disabled(!viewModel.isActive)"
    private static let cancelAllAction = "cancelAll(reason: .userRequested)"
    private static let cancelAllKey = "\"transfers.cancelAll\""
    private static let rowCancelGate = "if item.status.isCancellable {"
    private static let rowCancelAction = "viewModel.cancel(itemID: item.id)"
    private static let rowCancelKey = "\"transfers.cancel\""
    private static let helpModifier = ".help("
    private static let accessibilityLabelModifier = ".accessibilityLabel("

    /// The two views of the bar this suite reads, both derived from one read
    /// of the file and both the same length as it (see `SwiftSource`).
    ///
    /// `code` is the strict view — comments and string literals blanked — and
    /// every structural claim is made against it, because a guard reading raw
    /// source cannot tell a call from a sentence about a call. `withLiterals`
    /// blanks comments only, and exists for the two claims that are ABOUT a
    /// literal: which catalogue key a control takes its label from.
    private static func barViews() throws -> (code: String, withLiterals: String) {
        let raw = try String(contentsOf: sourceFile, encoding: .utf8)
        return (try SwiftSource.blankingCommentsAndStrings(raw),
                try SwiftSource.blankingComments(raw))
    }

    /// Character offsets of the brace-balanced body that follows
    /// `declaration`'s first `{`. Offsets rather than a substring, so the
    /// same span can be read out of either view — the balance is counted on
    /// the strict view, where no brace can hide inside a literal or a
    /// sentence, and the literal view is then sliced at the same positions.
    ///
    /// Throws rather than returning an empty range when the declaration is
    /// gone: a check that cannot find what it watches must fail, not report
    /// an all-clear.
    static func declarationBodyRange(
        of declaration: String, in source: String
    ) throws -> Range<Int> {
        guard let declarationRange = source.range(of: declaration) else {
            throw ScanError.declarationNotFound(declaration)
        }
        let rest = declarationRange.upperBound..<source.endIndex
        guard let openBrace = source.range(of: "{", range: rest) else {
            throw ScanError.bodyNotFound(declaration)
        }
        var depth = 0
        var index = openBrace.lowerBound
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return source.distance(from: source.startIndex, to: openBrace.upperBound)
                        ..< source.distance(from: source.startIndex, to: index)
                }
            default:
                break
            }
            index = source.index(after: index)
        }
        throw ScanError.unbalancedBraces(declaration)
    }

    /// The characters at `range` of `text`. Safe across the two views only
    /// because both preserve the raw source's length, which
    /// `SwiftSourceStrippingTests.bothModesPreserveLengthAndLineStructure`
    /// holds them to.
    static func slice(_ range: Range<Int>, of text: String) -> String {
        let characters = Array(text)
        guard range.lowerBound >= 0, range.upperBound <= characters.count else { return "" }
        return String(characters[range])
    }

    /// The brace-balanced body that follows `declaration`'s first `{`, as
    /// text. Kept for callers that read one view only — including
    /// `TransferQueueBarPathsGuardTests`, which shares this scanner.
    static func declarationBody(of declaration: String, in source: String) throws -> String {
        slice(try declarationBodyRange(of: declaration, in: source), of: source)
    }

    static func occurrenceCount(of needle: String, in source: String) -> Int {
        var count = 0
        var searchRange = source.startIndex..<source.endIndex
        while let found = source.range(of: needle, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<source.endIndex
        }
        return count
    }

    // MARK: - The guard

    @Test func cancelAllButtonIsGatedOnTheQueuesOwnActivityPredicate() throws {
        let views = try Self.barViews()
        let range = try Self.declarationBodyRange(of: Self.cancelAllDeclaration, in: views.code)
        let code = Self.slice(range, of: views.code)
        let withLiterals = Self.slice(range, of: views.withLiterals)
        #expect(withLiterals.contains(Self.cancelAllKey), """
            The Cancel-all button must take its label from the transfers.cancelAll \
            catalogue key, not from a hardcoded string.
            """)
        #expect(code.contains(Self.cancelAllAction), """
            Pressing Cancel all is a deliberate stop by the person at the keyboard, \
            so it must pass .userRequested -- .connectionLost would mark every swept \
            item as a failure and light the tab's attention dot.
            """)
        #expect(code.contains(Self.cancelAllGate), """
            Cancel all must be enabled exactly while the queue reports open work, \
            by asking the queue's own isActive predicate -- a gate re-derived here \
            from the item list would drift from what the rows show.
            """)
    }

    @Test func perRowCancelIsOfferedOnlyWhileTheRowCanStillBeStopped() throws {
        let views = try Self.barViews()
        let range = try Self.declarationBodyRange(of: Self.rowCancelDeclaration, in: views.code)
        let code = Self.slice(range, of: views.code)
        let withLiterals = Self.slice(range, of: views.withLiterals)
        #expect(code.contains(Self.rowCancelGate), """
            A row's cancel must be gated on the status predicate the queue owns, \
            so the button that is shown and the call that is answered can never \
            disagree about which rows are still stoppable.
            """)
        #expect(withLiterals.contains(Self.rowCancelKey), """
            The row cancel carries no visible text, so its catalogue key is its \
            whole label -- it must come from transfers.cancel.
            """)
        #expect(code.contains(Self.rowCancelAction), """
            A row's cancel must stop exactly that row's transfer, by id -- not \
            the whole queue.
            """)
    }

    /// A control whose only label is a symbol needs BOTH: `.help` produces
    /// the hover tooltip a pointer user gets, `.accessibilityLabel` is what
    /// VoiceOver reads. They are different affordances rather than a
    /// duplication, which is why they intentionally share one key --
    /// `SettingsView`'s remove button states the rule in the tree's own
    /// words, and `LivenessDotWiringGuardTests` pins the same pair on the
    /// liveness dot. Without the second one, the row's only control
    /// announces itself as the name of an SF Symbol.
    @Test func theRowCancelCarriesBothHelpAndAccessibilityLabel() throws {
        let views = try Self.barViews()
        let range = try Self.declarationBodyRange(of: Self.rowCancelDeclaration, in: views.code)
        let code = Self.slice(range, of: views.code)
        // Both computed before the expectation, so a failure reports the
        // claim rather than dumping the whole declaration into the output.
        let carriesHelp = code.contains(Self.helpModifier)
        let carriesAccessibilityLabel = code.contains(Self.accessibilityLabelModifier)
        #expect(carriesHelp, """
            The row cancel no longer sets .help( -- a pointer user would have no \
            way to learn what the symbol does.
            """)
        #expect(carriesAccessibilityLabel, """
            The row cancel no longer sets .accessibilityLabel( -- VoiceOver would \
            announce the SF Symbol name instead of what the button does.
            """)
    }

    /// The positive anchor the checks above need. Each reads a DECLARATION;
    /// a declaration that nothing places in the bar would leave them green
    /// over a control the user can never reach. Each name must therefore
    /// occur twice: once declared, once placed.
    ///
    /// Counted on the strict view, so prose about a control cannot stand in
    /// for the control. That is not hypothetical: a doc comment naming
    /// `cancelButton(item)`, planted together with the deletion of the real
    /// placement, held this count at two and left the whole suite green.
    @Test func bothCancelControlsAreActuallyPlacedInTheBar() throws {
        let code = try Self.barViews().code
        let cancelAllUses = Self.occurrenceCount(of: "cancelAllButton", in: code)
        #expect(cancelAllUses == 2, """
            cancelAllButton must be declared once and placed once in the bar's \
            header row -- found \(cancelAllUses) mentions in code.
            """)
        let rowCancelUses = Self.occurrenceCount(of: "cancelButton(", in: code)
        #expect(rowCancelUses == 2, """
            cancelButton( must be declared once and called once from the row \
            builder -- found \(rowCancelUses) mentions in code.
            """)
    }

    /// What the check above would be worth nothing without: the strict view
    /// must actually be reaching the file. An empty or unreadable read makes
    /// every count zero, which a `== 2` notices — but a scan that silently
    /// read a blanked file would satisfy any `!contains` in this suite.
    @Test func theStrictViewStillContainsTheBarsCode() throws {
        let readsTheBar = try Self.barViews().code.contains("struct TransferQueueBar: View")
        #expect(readsTheBar, """
            the strict view of TransferQueueBar.swift no longer contains the bar's \
            own declaration -- the stripper or the path is wrong, and every scan in \
            this suite is reading something other than the file it names
            """)
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    @Test func scannerFailsClosedWhenADeclarationIsGone() {
        let source = "struct Bar: View { var body: some View { Text(\"hi\") } }"
        #expect(throws: (any Error).self) {
            try Self.declarationBody(of: Self.cancelAllDeclaration, in: source)
        }
        #expect(throws: (any Error).self) {
            try Self.declarationBody(of: Self.rowCancelDeclaration, in: source)
        }
    }

    @Test func scannerFailsClosedOnAnUnterminatedBody() {
        let source = "\(Self.cancelAllDeclaration) { Button { nested { } "
        #expect(throws: (any Error).self) {
            try Self.declarationBody(of: Self.cancelAllDeclaration, in: source)
        }
    }

    /// The body must end at its OWN closing brace: a following declaration's
    /// content must not leak in, or a gate written on the wrong control
    /// would satisfy the check for the right one.
    @Test func bodyStopsAtItsOwnClosingBrace() throws {
        let source = """
            \(Self.cancelAllDeclaration) {
                Button { }
                    .disabled(!viewModel.isActive)
            }
            private var otherButton: some View {
                Button { }.disabled(!viewModel.hasInterrupted)
            }
            """
        let body = try Self.declarationBody(of: Self.cancelAllDeclaration, in: source)
        #expect(body.contains(Self.cancelAllGate))
        #expect(!body.contains("hasInterrupted"), """
            the extractor must stop at the first balanced close, otherwise a \
            neighbouring declaration's modifiers count as this one's
            """)
    }

    /// The needles the two negative self-tests below use are the same
    /// constants the real-file checks read, so a needle can never name a
    /// string that appears nowhere in the tree — the way an unanchored copy
    /// would, going on passing while demonstrating nothing. This holds them
    /// to the file as well: both must occur in the bar's own strict view.
    @Test func theNegativeSelfTestsUseNeedlesTheBarActuallyContains() throws {
        let code = try Self.barViews().code
        #expect(code.contains(Self.cancelAllGate), """
            the gate needle names an expression TransferQueueBar.swift does not \
            contain, so scannerSeesAWrongGateOnTheCancelAllButton would be \
            satisfied by any body at all
            """)
        #expect(code.contains(Self.rowCancelGate), """
            the row-gate needle names an expression TransferQueueBar.swift does \
            not contain, so scannerSeesAnUngatedRowCancel would be satisfied by \
            any body at all
            """)
    }

    @Test func scannerSeesAWrongGateOnTheCancelAllButton() throws {
        let source = """
            \(Self.cancelAllDeclaration) {
                Button(L10n.string("transfers.cancelAll", "Cancel all")) {
                    Task { await viewModel.\(Self.cancelAllAction) }
                }
                .disabled(viewModel.items.isEmpty)
            }
            """
        let body = try Self.declarationBody(of: Self.cancelAllDeclaration, in: source)
        // Positive first: the scanner did read a body, and one that carries a
        // gate -- so the negative below reports the WRONG gate rather than an
        // empty read.
        #expect(body.contains(".disabled("))
        #expect(body.contains(Self.cancelAllAction))
        #expect(!body.contains(Self.cancelAllGate), """
            the scanner must report a re-derived gate as missing the queue's own \
            predicate, not wave it through because a .disabled is present at all
            """)
    }

    @Test func scannerSeesAnUngatedRowCancel() throws {
        let source = """
            \(Self.rowCancelDeclaration)_ item: Item) -> some View {
                Button { \(Self.rowCancelAction) } label: {
                    Image(systemName: "xmark.circle")
                }
                \(Self.helpModifier)L10n.string("transfers.cancel", "Cancel this transfer"))
            }
            """
        let body = try Self.declarationBody(of: Self.rowCancelDeclaration, in: source)
        // Positive first, same reason: the button's own wiring IS present,
        // which is what makes the missing gate the only thing reported.
        #expect(body.contains(Self.rowCancelAction))
        #expect(body.contains(Self.helpModifier))
        #expect(!body.contains(Self.rowCancelGate), """
            the scanner must report an always-shown row cancel, not accept it \
            because the button's own wiring is right
            """)
    }

    /// The stripping the real-file checks depend on, demonstrated on a body
    /// that says the right things only in prose and in a literal.
    @Test func scannerSeesThroughAGateThatExistsOnlyInACommentOrALiteral() throws {
        let source = """
            \(Self.cancelAllDeclaration) {
                // gated with \(Self.cancelAllGate), honest
                Button("cancel") { }
                let note = "\(Self.cancelAllGate)"
            }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let body = Self.slice(
            try Self.declarationBodyRange(of: Self.cancelAllDeclaration, in: code), of: code)
        #expect(body.contains("Button("), "the scanner must still see the code around them")
        #expect(!body.contains(Self.cancelAllGate), """
            the scanner must not accept a gate that exists only as prose or as a \
            quoted string -- that is the whole point of reading the stripped view
            """)
    }

    @Test func scannerCountsMentionsRatherThanNoticingOne() {
        #expect(Self.occurrenceCount(of: "cancelAllButton", in: "nothing here") == 0)
        #expect(Self.occurrenceCount(of: "cancelAllButton", in: "var cancelAllButton: some View") == 1)
        #expect(Self.occurrenceCount(
            of: "cancelAllButton", in: "var cancelAllButton: some View\n cancelAllButton") == 2)
    }
}
