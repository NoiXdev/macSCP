import Foundation
import Testing
@testable import MacSCPAppKit

/// Guards ONE property of `SnippetsSheet.swift`: the footer's "Export…"
/// entry no longer exports directly, but arms a confirmation whose own
/// button carries the resolved scope to `performExport`. That entry now
/// lives in the footer's three-dot menu rather than in a button of its own
/// (backlog 2026-08-20, point 5), so the scan anchors on the menu's
/// `case .export:` arm; `SheetOverflowMenuWiringGuardTests` is what pins the
/// menu's placement and labelling. Isolated from the rest of the file the
/// same way `SnippetRowExportMenuGuardTests` isolates the row's
/// `.contextMenu` block, this suite pins:
///
/// 1. the export arm no longer calls `performExport(` with `visibleSnippets`
///    directly, but sets the confirmation state instead;
/// 2. the confirming button calls `performExport(` with the resolved scope;
/// 3. the export arm resolves that scope through `ListExportScope.resolve(`,
///    the one shared rule both export footers use;
/// 4. the entry is OFFERED only when `snippetsCanExport` says so, rather
///    than offered always and greyed out;
/// 5. the exact call `performExport([snippet])` appears somewhere in the
///    file (`SnippetRowExportMenuGuardTests` is what pins it to the row).
///
/// Known blind spots, same shape as `SnippetRowExportMenuGuardTests`: a
/// SOURCE-TEXT scan, fooled by commented-out code or an unusual reformat; it
/// confirms which call sits where for 1-4, but assertion 5 is a file-wide
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

    @Test func footerExportEntryNoLongerExportsDirectly() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let block = try Self.footerExportArm(in: source)
        #expect(!block.contains("performExport(visibleSnippets)"), """
            The footer's Export… entry must no longer call performExport( \
            with visibleSnippets directly -- it should set the confirmation \
            state and let the alert's own button perform the export.
            """)
        #expect(block.contains("pendingExport ="), """
            The footer's Export… entry must set pendingExport to the \
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

    @Test func footerExportArmResolvesThroughListExportScope() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let block = try Self.footerExportArm(in: source)
        #expect(block.contains("ListExportScope.resolve("), """
            The footer's Export… arm must resolve its scope via \
            ListExportScope.resolve(, the one shared rule both export footers \
            use -- scoped to that arm so a stray mention elsewhere in the \
            file cannot satisfy this check.
            """)
    }

    /// "Show only what is possible": the enablement that used to grey the
    /// footer button out now decides whether the entry EXISTS. Pinned in
    /// the footer's own menu construction, so an edit that offers the entry
    /// unconditionally fails here. That the menu is never greyed out either
    /// is `SheetOverflowMenuWiringGuardTests`' job -- it holds for every
    /// sheet, not only this one.
    @Test func theExportEntryIsOfferedOnlyWhenSnippetsCanExport() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let construction = try Self.footerMenuConstruction(in: source)
        #expect(construction.contains("snippetsCanExport("), """
            The footer's three-dot menu must decide its Export… entry with \
            snippetsCanExport( -- which also rules out an unreadable store, \
            unlike a bare visibleSnippets.isEmpty test.
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

    @Test func scannerSeesTheExportArmStillExportingDirectly() throws {
        let source = Self.syntheticSource(exportArmBody: "performExport(visibleSnippets)")
        let block = try Self.footerExportArm(in: source)
        #expect(block.contains("performExport(visibleSnippets)"))
    }

    @Test func scannerAcceptsTheCorrectExportArmBody() throws {
        let source = Self.syntheticSource(
            exportArmBody: "pendingExport = ListExportScope.resolve(selectedID: selectedID, from: visibleSnippets)")
        let block = try Self.footerExportArm(in: source)
        #expect(!block.contains("performExport(visibleSnippets)"))
        #expect(block.contains("pendingExport ="))
    }

    /// The arm scan stops at the next `case`, so the import arm's body can
    /// never be read as the export arm's -- otherwise assertion 1 could be
    /// satisfied by a line that belongs to a different action.
    @Test func scannerStopsTheExportArmAtTheNextCase() throws {
        let source = Self.syntheticSource(exportArmBody: "pendingExport = nil")
        let block = try Self.footerExportArm(in: source)
        #expect(!block.contains("showImportFileImporter"), """
            the arm scan must end where the import arm begins, or every \
            assertion about the export arm silently covers both.
            """)
    }

    /// Neither anchor present -- both scanners must FAIL CLOSED (throw)
    /// rather than silently report an empty result as an all-clear.
    @Test func scannersFailClosedWhenTheFooterMenuCannotBeFound() {
        let source = "struct Empty: View { var body: some View { Text(\"hi\") } }"
        #expect(throws: (any Error).self) { try Self.footerExportArm(in: source) }
        #expect(throws: (any Error).self) { try Self.footerMenuConstruction(in: source) }
    }

    // MARK: - Scanner
    //
    // Deliberately line-based, like `SnippetRowExportMenuGuardTests`'s
    // scanner: find the footer's three-dot menu by its construction, then
    // read the two spans this suite judges -- the construction's own
    // argument list, and the `case .export:` arm of the closure it takes.

    private enum ScanError: Error { case menuNotFound, exportArmNotFound }

    /// The line index of the footer's `SheetOverflowMenu(` construction.
    /// The key is read off the type rather than spelled, so renaming the
    /// menu moves this scan with it.
    private static let menuConstruction = "\(SheetOverflowMenu.self)("

    private static func menuLine(in lines: [String]) -> Int? {
        lines.firstIndex { $0.contains(menuConstruction) }
    }

    /// The menu construction's own argument list: from the construction
    /// line to the line that closes it (`) { action in`). Throws when the
    /// menu cannot be located.
    private static func footerMenuConstruction(in source: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        guard let start = menuLine(in: lines) else { throw ScanError.menuNotFound }
        guard let end = (start..<lines.count).first(where: { lines[$0].contains(") {") })
        else { throw ScanError.menuNotFound }
        return lines[start...end].joined(separator: "\n")
    }

    /// The text of the `case .export:` arm inside the footer menu's action
    /// closure: from that line to the next `case ` line, or to the closure's
    /// end. Throws when the menu, or the arm inside it, cannot be located.
    private static func footerExportArm(in source: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        guard let menu = menuLine(in: lines) else { throw ScanError.menuNotFound }
        guard let start = (menu..<lines.count).first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces) == "case .export:"
        }) else { throw ScanError.exportArmNotFound }
        let end = ((start + 1)..<lines.count).first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("case ")
                || lines[$0].trimmingCharacters(in: .whitespaces) == "}"
        }) ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }

    /// A footer menu shaped like the real one, with the export arm's body
    /// swappable -- lets the self-tests above exercise both scanners
    /// without touching the real file.
    private static func syntheticSource(exportArmBody: String) -> String {
        """
            struct Fake: View {
                var body: some View {
                    SheetOverflowMenu(
                        actions: SheetOverflowAction.offered(
                            canExport: snippetsCanExport(
                                load: load, visibleSnippets: visibleSnippets),
                            canImport: true)
                    ) { action in
                        switch action {
                        case .export:
                            \(exportArmBody)
                        case .import:
                            showImportFileImporter = true
                        }
                    }
                }
            }
            """
    }
}
