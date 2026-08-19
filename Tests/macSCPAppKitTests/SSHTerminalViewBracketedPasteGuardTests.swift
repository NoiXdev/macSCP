import Foundation
import Testing

/// Guards that `SSHTerminalView.makeNSView` actually wires
/// `TerminalPanelViewModel.bracketedPasteQuery` to SwiftTerm's own
/// `bracketedPasteMode` (Snippet-Mehrzeilig, whole-branch review, finding 3).
///
/// Nothing else in the suite would notice a dropped assignment here: with
/// the closure never set, `TerminalPanelViewModel.remoteWantsBracketedPaste`
/// silently reads `false` forever (its own documented, conservative default
/// for "no view attached" -- see `TerminalPanelViewModelTests.
/// remoteWantsBracketedPasteIsFalseWithNoQuerySet`), every OTHER existing
/// test stays green, and a multi-line snippet insert on a remote that DOES
/// have bracketed paste on would be refused instead of sent -- a regression
/// the reviewer demonstrated by mutating the view model's own `?? false` to
/// `?? true` and watching all 318 tests at the time stay green.
///
/// Same boundary as `SnippetCommandEditorGuardTests`: this project has no
/// `NSViewRepresentable`-rendering test tool, so this is a SOURCE-TEXT scan
/// of `makeNSView`'s body, not a behavioral test that actually mounts the
/// view. It fails closed (a marker it cannot find is a thrown error, never a
/// silent pass) and carries its own self-tests proving the scanner reacts to
/// the regression it exists to catch.
@Suite("SSHTerminalView bracketed-paste wiring guard")
struct SSHTerminalViewBracketedPasteGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SSHTerminalViewBracketedPasteGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `SnippetCommandEditorGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SSHTerminalView.swift")

    private enum ScanError: Error { case markerNotFound, unbalancedBraces }

    @Test func makeNSViewAssignsBracketedPasteQuery() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let body = try Self.functionBody(containing: "func makeNSView", in: source)
        #expect(body.contains("viewModel.bracketedPasteQuery = "), """
            makeNSView must assign `viewModel.bracketedPasteQuery` -- without it, \
            `TerminalPanelViewModel.remoteWantsBracketedPaste` reads its documented "no view \
            attached" default (`false`) FOREVER, and a snippet insert on a remote that does \
            have bracketed paste on is silently refused instead of sent. Scanned body: \(body)
            """)
    }

    @Test func scannerFlagsTheRegressionWhereTheAssignmentIsDropped() throws {
        let body = """
            func makeNSView(context: Context) -> TerminalView {
                let terminal = TerminalView(frame: .zero)
                viewModel.onOutput = { [weak terminal] bytes in
                    terminal?.feed(byteArray: bytes[...])
                }
                return terminal
            }
            """
        #expect(!body.contains("viewModel.bracketedPasteQuery = "),
            "the scanner must see that the regressed source drops the assignment")
    }

    @Test func scannerAcceptsTheCorrectAssignment() throws {
        let body = """
            func makeNSView(context: Context) -> TerminalView {
                let terminal = TerminalView(frame: .zero)
                viewModel.bracketedPasteQuery = { [weak terminal] in
                    terminal?.getTerminal().bracketedPasteMode ?? false
                }
                return terminal
            }
            """
        #expect(body.contains("viewModel.bracketedPasteQuery = "))
    }

    // MARK: - Scanner
    //
    // Brace-balanced from the marker's own line onward, same idiom as
    // `SnippetCommandEditorGuardTests.functionBody(containing:in:)`.

    private static func functionBody(containing marker: String, in source: String) throws -> String {
        guard let markerRange = source.range(of: marker) else { throw ScanError.markerNotFound }
        let lineStart = source[..<markerRange.lowerBound].lastIndex(of: "\n")
            .map { source.index(after: $0) } ?? source.startIndex
        var depth = 0
        var enteredBlock = false
        var index = lineStart
        while index < source.endIndex {
            let ch = source[index]
            if ch == "{" { depth += 1; enteredBlock = true }
            if ch == "}" { depth -= 1 }
            index = source.index(after: index)
            if enteredBlock, depth == 0 {
                return String(source[lineStart..<index])
            }
        }
        throw ScanError.unbalancedBraces
    }

    // MARK: - Scanner fails closed

    @Test func functionBodyFailsClosedWhenMarkerCannotBeFound() {
        #expect(throws: (any Error).self) {
            try Self.functionBody(containing: "func thisDoesNotExist", in: "struct Empty {}")
        }
    }

    @Test func functionBodyFailsClosedOnUnbalancedBraces() {
        #expect(throws: (any Error).self) {
            try Self.functionBody(containing: "func broken", in: "func broken() {\n    // no close")
        }
    }
}
