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
/// Known blind spots, so a green run is not read as more than it is:
/// - SOURCE TEXT, never a rendered view. Nothing here can tell whether a
///   button is actually greyed out on screen, only which expression the
///   source hands to `.disabled`.
/// - The brace counter does not know about string literals or comments, so
///   a brace inside either would misplace a body's end. None of the bodies
///   it reads contains one today; `bodyStopsAtItsOwnClosingBrace` below is
///   what would notice the counter going wrong on the shape it does read.
/// - The required expressions are spelled out as literals here. That is a
///   second copy of `isActive`/`isCancellable`, and it is the copy that
///   would need updating on a rename — the checks are positive, so a rename
///   turns them red rather than silently satisfying them.
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

    private static func barSource() throws -> String {
        try String(contentsOf: sourceFile, encoding: .utf8)
    }

    /// The brace-balanced body that follows `declaration`'s first `{`.
    /// Throws rather than returning an empty string when the declaration is
    /// gone: a check that cannot find what it watches must fail, not report
    /// an all-clear.
    static func declarationBody(of declaration: String, in source: String) throws -> String {
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
                    return String(source[openBrace.upperBound..<index])
                }
            default:
                break
            }
            index = source.index(after: index)
        }
        throw ScanError.unbalancedBraces(declaration)
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
        let body = try Self.declarationBody(of: Self.cancelAllDeclaration, in: try Self.barSource())
        #expect(body.contains("\"transfers.cancelAll\""), """
            The Cancel-all button must take its label from the transfers.cancelAll \
            catalogue key, not from a hardcoded string.
            """)
        #expect(body.contains("cancelAll(reason: .userRequested)"), """
            Pressing Cancel all is a deliberate stop by the person at the keyboard, \
            so it must pass .userRequested -- .connectionLost would mark every swept \
            item as a failure and light the tab's attention dot.
            """)
        #expect(body.contains(".disabled(!viewModel.isActive)"), """
            Cancel all must be enabled exactly while the queue reports open work, \
            by asking the queue's own isActive predicate -- a gate re-derived here \
            from the item list would drift from what the rows show.
            """)
    }

    @Test func perRowCancelIsOfferedOnlyWhileTheRowCanStillBeStopped() throws {
        let body = try Self.declarationBody(of: Self.rowCancelDeclaration, in: try Self.barSource())
        #expect(body.contains("if item.status.isCancellable {"), """
            A row's cancel must be gated on the status predicate the queue owns, \
            so the button that is shown and the call that is answered can never \
            disagree about which rows are still stoppable.
            """)
        #expect(body.contains("\"transfers.cancel\""), """
            The row cancel is icon-only, so its hover hint is its whole label -- \
            it must come from the transfers.cancel catalogue key.
            """)
        #expect(body.contains("viewModel.cancel(itemID: item.id)"), """
            A row's cancel must stop exactly that row's transfer, by id -- not \
            the whole queue.
            """)
    }

    /// The positive anchor the two checks above need. Both read a
    /// DECLARATION; a declaration that nothing places in the bar would leave
    /// them green over a control the user can never reach. Each name must
    /// therefore occur twice: once declared, once placed.
    @Test func bothCancelControlsAreActuallyPlacedInTheBar() throws {
        let source = try Self.barSource()
        let cancelAllUses = Self.occurrenceCount(of: "cancelAllButton", in: source)
        #expect(cancelAllUses == 2, """
            cancelAllButton must be declared once and placed once in the bar's \
            header row -- found \(cancelAllUses) mentions.
            """)
        let rowCancelUses = Self.occurrenceCount(of: "cancelButton(", in: source)
        #expect(rowCancelUses == 2, """
            cancelButton( must be declared once and called once from the row \
            builder -- found \(rowCancelUses) mentions.
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
        #expect(body.contains(".disabled(!viewModel.isActive)"))
        #expect(!body.contains("hasInterrupted"), """
            the extractor must stop at the first balanced close, otherwise a \
            neighbouring declaration's modifiers count as this one's
            """)
    }

    @Test func scannerSeesAWrongGateOnTheCancelAllButton() throws {
        let source = """
            \(Self.cancelAllDeclaration) {
                Button(L10n.string("transfers.cancelAll", "Cancel all")) {
                    Task { await viewModel.cancelAll(reason: .userRequested) }
                }
                .disabled(viewModel.items.isEmpty)
            }
            """
        let body = try Self.declarationBody(of: Self.cancelAllDeclaration, in: source)
        #expect(!body.contains(".disabled(!viewModel.isActive)"), """
            the scanner must report a re-derived gate as missing the queue's own \
            predicate, not wave it through because a .disabled is present at all
            """)
    }

    @Test func scannerSeesAnUngatedRowCancel() throws {
        let source = """
            \(Self.rowCancelDeclaration)_ item: Item) -> some View {
                Button { viewModel.cancel(itemID: item.id) } label: {
                    Image(systemName: "xmark.circle")
                }
                .help(L10n.string("transfers.cancel", "Cancel this transfer"))
            }
            """
        let body = try Self.declarationBody(of: Self.rowCancelDeclaration, in: source)
        #expect(!body.contains("if item.status.isCancellable {"), """
            the scanner must report an always-shown row cancel, not accept it \
            because the button's own wiring is right
            """)
    }

    @Test func scannerCountsMentionsRatherThanNoticingOne() {
        #expect(Self.occurrenceCount(of: "cancelAllButton", in: "nothing here") == 0)
        #expect(Self.occurrenceCount(of: "cancelAllButton", in: "var cancelAllButton: some View") == 1)
        #expect(Self.occurrenceCount(
            of: "cancelAllButton", in: "var cancelAllButton: some View\n cancelAllButton") == 2)
    }
}
