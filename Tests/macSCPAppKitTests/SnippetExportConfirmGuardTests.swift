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
/// 3. the footer button's own block resolves that scope through
///    `ListExportScope.resolve(`, the one shared rule both export footers
///    use;
/// 4. the exact call `performExport([snippet])` appears somewhere in the
///    file (`SnippetRowExportMenuGuardTests` is what pins it to the row).
///
/// Known blind spots, same shape as `SnippetRowExportMenuGuardTests`: a
/// SOURCE-TEXT scan, fooled by commented-out code or an unusual reformat; it
/// confirms which call sits where for 1-3, but assertion 4 is a file-wide
/// `contains` check -- it pins neither the row's placement nor that the call
/// is reached unconfirmed.
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

    @Test func footerBlockResolvesThroughListExportScope() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let block = try Self.footerExportButtonBlock(in: source)
        #expect(block.contains("ListExportScope.resolve("), """
            The footer's Export… button's own block must resolve its scope \
            via ListExportScope.resolve(, the one shared rule both export \
            footers use -- scoped to the footer's own block so a stray \
            mention elsewhere in the file cannot satisfy this check.
            """)
    }

    @Test func performExportWithExactlyTheSnippetStillAppearsInTheFile() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        #expect(source.contains("performExport([snippet])"), """
            The exact call performExport([snippet]) must still appear \
            somewhere in SnippetsSheet.swift. This is a file-wide check: it \
            does not prove the call sits in the row's block or that it runs \
            unconfirmed -- SnippetRowExportMenuGuardTests is what pins the \
            row's own block.
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
            footerBody: "pendingExport = ListExportScope.resolve(selectedID: selectedID, from: visibleSnippets)")
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
