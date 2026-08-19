import Foundation
import Testing
@testable import MacSCPAppKit

/// The snippet row was the last list in the app whose context menu had no
/// "Export…" entry. This reads the source of `SnippetsSheet` and pins that
/// the row menu offers it, exports exactly the right-clicked snippet, and
/// keeps the destructive entry last.
@Suite("Snippet row export menu")
struct SnippetRowExportMenuGuardTests {
    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // macSCPAppKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/MacSCPAppKit/SnippetsSheet.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func theRowMenuExportsExactlyTheRightClickedSnippet() throws {
        let text = try source()
        #expect(text.contains("performExport([snippet])"))
    }

    @Test func theRowMenuReusesTheExistingExportLabel() throws {
        let text = try source()
        // One key, two triggers -- a second key would let the footer and the
        // row drift apart in translation.
        #expect(text.contains("\"snippets.export\""))
    }

    @Test func theDestructiveEntryStaysLastInTheRowMenu() throws {
        let text = try source()
        let exportIndex = try #require(text.range(of: "performExport([snippet])")).lowerBound
        let deleteIndex = try #require(text.range(of: "isShowingDeleteConfirm = true")).lowerBound
        #expect(exportIndex < deleteIndex)
    }
}
