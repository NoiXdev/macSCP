import Foundation
import Testing

/// Guards ONE property of `SnippetsSheet.swift`: the footer's "Export…"
/// button no longer exports directly, but arms a confirmation whose own
/// button carries the resolved scope to `performExport`. Isolated from the
/// rest of the file the same way `SnippetRowExportMenuGuardTests` isolates
/// the row's `.contextMenu` block, this suite pins:
///
/// 1. the footer button no longer calls `performExport(` with
///    `visibleSnippets` directly, but sets the confirmation state instead;
/// 2. the confirming button calls `performExport(` with the resolved scope;
/// 3. `ExportScope.resolve(` occurs in the file;
/// 4. the row menu still calls `performExport([snippet])` unconfirmed.
///
/// Known blind spots, same shape as `SnippetRowExportMenuGuardTests`: a
/// SOURCE-TEXT scan, fooled by commented-out code or an unusual reformat; it
/// confirms which call sits where, not that the closure each button runs
/// actually calls the SwiftUI APIs its text implies.
@Suite("Snippet export confirmation")
struct SnippetExportConfirmGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SnippetExportConfirmGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `SnippetRowExportMenuGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SnippetsSheet.swift")

    // MARK: - The guard

    @Test func footerButtonNoLongerExportsDirectly() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let block = try Self.footerExportButtonBlock(in: source)
        #expect(!block.contains("performExport(visibleSnippets)"), """
            The footer's Export… button must no longer call performExport( \
            with visibleSnippets directly -- it should set the confirmation \
            state and let the alert's own button perform the export.
            """)
        #expect(block.contains("pendingExport ="), """
            The footer's Export… button must set pendingExport to the \
            resolved scope so the confirmation alert has something to show.
            """)
    }

    @Test func confirmingButtonExportsTheResolvedScope() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        #expect(source.contains("performExport(pendingExport)"), """
            The confirmation alert's own button must call performExport( \
            with the resolved (pending) scope, not visibleSnippets again.
            """)
    }

    @Test func exportScopeResolveIsUsed() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        #expect(source.contains("ExportScope.resolve("), """
            SnippetsSheet.swift must resolve the footer's export scope via \
            ExportScope.resolve(, the one shared rule both export footers use.
            """)
    }

    @Test func rowMenuStillExportsUnconfirmed() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        #expect(source.contains("performExport([snippet])"), """
            The row's context-menu Export entry must keep exporting exactly \
            the right-clicked snippet without going through the \
            confirmation -- narrowing to one row already IS the confirmation.
            """)
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    @Test func scannerSeesTheFooterButtonStillExportingDirectly() throws {
        let source = Self.syntheticSource(footerBody: "performExport(visibleSnippets)")
        let block = try Self.footerExportButtonBlock(in: source)
        #expect(block.contains("performExport(visibleSnippets)"))
    }

    @Test func scannerAcceptsTheCorrectFooterBody() throws {
        let source = Self.syntheticSource(
            footerBody: "pendingExport = ExportScope.resolve(selectedID: selectedID, from: visibleSnippets)")
        let block = try Self.footerExportButtonBlock(in: source)
        #expect(!block.contains("performExport(visibleSnippets)"))
        #expect(block.contains("pendingExport ="))
    }

    /// No footer `.disabled(!snippetsCanExport` anchor at all -- the scanner
    /// must FAIL CLOSED (throw) rather than silently report an empty result
    /// as an all-clear.
    @Test func scannerFailsClosedWhenTheFooterButtonCannotBeFound() {
        let source = "struct Empty: View { var body: some View { Text(\"hi\") } }"
        #expect(throws: (any Error).self) { try Self.footerExportButtonBlock(in: source) }
    }

    // MARK: - Scanner
    //
    // Deliberately line-based, like `SnippetRowExportMenuGuardTests`'s
    // scanner: find the footer Export… button by its neighboring
    // `snippetsCanExport` anchor (unique to the footer, unlike the shared
    // `"snippets.export"` key) and read forward to the matching close.

    private enum ScanError: Error { case footerButtonNotFound }

    /// The text of the footer Export… button's own block, found by locating
    /// its `.disabled(!snippetsCanExport` line (unique to the footer button
    /// among the file's uses of `"snippets.export"`) and walking backward to
    /// the nearest enclosing `Button(` line, then forward to that line's own
    /// close.
    private static func footerExportButtonBlock(in source: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        guard let disabledLine = lines.firstIndex(where: { $0.contains(".disabled(!snippetsCanExport") })
        else { throw ScanError.footerButtonNotFound }
        guard let buttonLine = (0..<disabledLine).reversed()
            .first(where: { lines[$0].contains("Button(") })
        else { throw ScanError.footerButtonNotFound }
        return lines[buttonLine...disabledLine].joined(separator: "\n")
    }

    /// A footer Export… button shaped like the real one, with its own body
    /// swappable -- lets the self-tests above exercise
    /// `footerExportButtonBlock` without touching the real file.
    private static func syntheticSource(footerBody: String) -> String {
        """
            struct Fake: View {
                var body: some View {
                    Button(L10n.string("snippets.export", "Export…")) {
                        \(footerBody)
                    }
                    .buttonStyle(.polished)
                    .disabled(!snippetsCanExport(load: load, visibleSnippets: visibleSnippets))
                }
            }
            """
    }
}
