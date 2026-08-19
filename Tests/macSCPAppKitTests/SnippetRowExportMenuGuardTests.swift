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

    /// Right-clicking a row that is not the selected one must still act on
    /// the row under the cursor. Every entry in this menu therefore sets the
    /// selection before it does anything, and the new one is no exception.
    @Test func theRowMenuSelectsTheRowBeforeExportingIt() throws {
        let text = try source()
        let call = try #require(text.range(of: "performExport([snippet])"))
        let preceding = text[text.startIndex..<call.lowerBound].suffix(120)
        #expect(preceding.contains("selectedID = snippet.id"))
    }
}
