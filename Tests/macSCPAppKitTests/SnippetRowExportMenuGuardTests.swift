import Foundation
import Testing

/// Guards ONE property of `SnippetsSheet.swift`: the snippet row's
/// `.contextMenu` block, isolated from the rest of the file. Inside that
/// block, three things must hold — Edit → Export → Delete in that order (so
/// the destructive entry stays last), the Export entry sets `selectedID`
/// before calling `performExport([snippet])` (so it always acts on the
/// right-clicked snippet, not whatever was selected before), and
/// `"snippets.export"` occurs exactly once across the whole file — the row
/// is now its only user, the footer's own Export… having moved under the
/// three-dot menu, where `SheetOverflowAction` labels it. That count is what
/// actually catches the regression a plain `contains` cannot: a second,
/// drifted key added just for the row would leave a `contains` check green.
///
/// Known blind spots, same shape as `SnippetActionSheetKeyboardShortcutGuardTests`
/// and `SnippetMenuItemsKeyboardShortcutGuardTests`, whose block-isolation
/// idiom this suite reuses: a SOURCE-TEXT scan, fooled by commented-out code
/// or an unusual reformat; it confirms which localization key sits in which
/// position and which lines follow it, not that the closure each button runs
/// actually calls the SwiftUI APIs its text implies.
@Suite("Snippet row export menu")
struct SnippetRowExportMenuGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SnippetRowExportMenuGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `SnippetActionSheetKeyboardShortcutGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SnippetsSheet.swift")

    // MARK: - The guard

    @Test func rowMenuOffersEditExportDeleteInThatOrder() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let order = try Self.entryOrder(in: source)
        #expect(order == ["snippets.edit", "snippets.export", "snippets.delete"], """
            The row's .contextMenu must offer Edit -> Export -> Delete in that \
            order, keeping the destructive entry last -- found \(order) instead.
            """)
    }

    @Test func exportEntrySelectsTheRowThenExportsExactlyIt() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let block = try Self.exportButtonBlock(in: source)
        #expect(block.contains("selectedID = snippet.id"), """
            The row's Export entry must set selectedID first, so it always \
            targets the right-clicked row even if it wasn't already selected.
            """)
        #expect(block.contains("performExport([snippet])"), """
            The row's Export entry must call performExport with exactly the \
            right-clicked snippet, not the sheet's whole visible list.
            """)
    }

    @Test func exportLabelKeyBelongsToTheRowAlone() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let count = Self.occurrenceCount(of: "\"snippets.export\"", in: source)
        #expect(count == 1, """
            "snippets.export" must appear exactly once in SnippetsSheet.swift \
            -- the row's entry, now its only user -- found \(count). A new, \
            drifted key for the row would leave the other assertions in this \
            suite green; a second one reappearing in the footer would mean the \
            file action climbed back out of the three-dot menu.
            """)
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    /// The exact regression this guard exists to catch: the destructive
    /// entry moved off the end.
    @Test func scannerSeesTheDestructiveEntryMovedAheadOfExport() throws {
        let source = Self.syntheticSource(order: ["snippets.edit", "snippets.delete", "snippets.export"])
        let order = try Self.entryOrder(in: source)
        #expect(order == ["snippets.edit", "snippets.delete", "snippets.export"], """
            the scanner must report the entries in their actual source order, \
            not a hardcoded one -- otherwise it could never catch this regression
            """)
    }

    @Test func scannerAcceptsTheCorrectOrder() throws {
        let source = Self.syntheticSource(order: ["snippets.edit", "snippets.export", "snippets.delete"])
        #expect(try Self.entryOrder(in: source) == ["snippets.edit", "snippets.export", "snippets.delete"])
    }

    @Test func scannerSeesAnExportBlockMissingTheSelection() throws {
        let source = Self.syntheticSource(exportBody: "performExport([snippet])")
        let block = try Self.exportButtonBlock(in: source)
        #expect(!block.contains("selectedID = snippet.id"), """
            the scanner must report that selection was dropped from the Export \
            block, not assume it is always there
            """)
    }

    @Test func scannerAcceptsTheCorrectExportBody() throws {
        let source = Self.syntheticSource(
            exportBody: "selectedID = snippet.id\n                    performExport([snippet])")
        let block = try Self.exportButtonBlock(in: source)
        #expect(block.contains("selectedID = snippet.id"))
        #expect(block.contains("performExport([snippet])"))
    }

    @Test func scannerCountsOccurrencesRatherThanJustNoticingOne() {
        #expect(Self.occurrenceCount(of: "\"snippets.export\"", in: "no key here at all") == 0)
        #expect(Self.occurrenceCount(of: "\"snippets.export\"", in: "\"snippets.export\" once") == 1)
        #expect(Self.occurrenceCount(
            of: "\"snippets.export\"", in: "\"snippets.export\" and again \"snippets.export\"") == 2)
    }

    /// No `.contextMenu` block at all -- both scanners must FAIL CLOSED
    /// (throw) rather than silently report an empty result as an all-clear.
    @Test func scannerFailsClosedWhenTheContextMenuCannotBeFound() {
        let source = "struct Empty: View { var body: some View { Text(\"hi\") } }"
        #expect(throws: (any Error).self) { try Self.entryOrder(in: source) }
        #expect(throws: (any Error).self) { try Self.exportButtonBlock(in: source) }
    }

    /// A `.contextMenu` block that exists but never mentions the Export key
    /// -- the block-isolation half of the scan must still fail closed.
    @Test func scannerFailsClosedWhenTheExportKeyCannotBeFoundInsideTheBlock() {
        let source = """
            struct Fake: View {
                func row(_ snippet: Snippet) -> some View {
                    Text(snippet.name)
                        .contextMenu {
                            Button(L10n.string("snippets.edit", "Edit…")) { }
                        }
                }
            }
            """
        #expect(throws: (any Error).self) { try Self.exportButtonBlock(in: source) }
    }

    // MARK: - Scanner
    //
    // Deliberately line-based, like `SnippetMenuItemsKeyboardShortcutGuardTests`'s
    // scanner: find where the row's `.contextMenu { ... }` block starts and
    // count braces until it closes, then read within that isolated span --
    // so a same-named key or call elsewhere in the file never gets mistaken
    // for the row's.

    private enum ScanError: Error { case contextMenuNotFound, keyNotFound }

    /// The line range of the row's `.contextMenu { ... }` block, found by
    /// counting braces from the anchor line until depth returns to zero --
    /// same trick as `SnippetMenuItemsKeyboardShortcutGuardTests.range(ofFunctionNamed:)`.
    /// 0-based, inclusive of both the `.contextMenu {` line and its closing
    /// brace's line.
    private static func contextMenuRange(in lines: [String]) -> ClosedRange<Int>? {
        guard let start = lines.firstIndex(where: { $0.contains(".contextMenu {") }) else { return nil }
        var depth = 0
        var sawOpenBrace = false
        for index in start..<lines.count {
            for character in lines[index] {
                if character == "{" { depth += 1; sawOpenBrace = true }
                if character == "}" { depth -= 1 }
            }
            if sawOpenBrace && depth <= 0 {
                return start...index
            }
        }
        return nil
    }

    /// The three entries' localization keys, in the order they appear inside
    /// the row's `.contextMenu` block. Throws if the block itself cannot be
    /// located -- see `scannerFailsClosedWhenTheContextMenuCannotBeFound`.
    private static func entryOrder(in source: String) throws -> [String] {
        let lines = source.components(separatedBy: "\n")
        guard let range = contextMenuRange(in: lines) else { throw ScanError.contextMenuNotFound }
        let keys = ["snippets.edit", "snippets.export", "snippets.delete"]
        return lines[range].compactMap { line in keys.first { line.contains("\"\($0)\"") } }
    }

    /// The text of the Export button's own block inside the row's
    /// `.contextMenu`: from the line carrying `"snippets.export"` to the
    /// next `Button(` (or the end of the context menu block) -- same
    /// span-finding idiom as
    /// `SnippetActionSheetKeyboardShortcutGuardTests.shortcutLines`, joined
    /// back into one string so callers can `.contains(...)` a whole
    /// statement rather than match one array element exactly. Throws if the
    /// context menu block, or the key inside it, cannot be located.
    private static func exportButtonBlock(in source: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        guard let menuRange = contextMenuRange(in: lines) else { throw ScanError.contextMenuNotFound }
        guard let start = lines[menuRange].firstIndex(where: { $0.contains("\"snippets.export\"") }) else {
            throw ScanError.keyNotFound
        }
        var end = menuRange.upperBound
        if start < menuRange.upperBound {
            for index in (start + 1)...menuRange.upperBound where lines[index].contains("Button(") {
                end = index
                break
            }
        }
        return lines[start..<end].joined(separator: "\n")
    }

    /// Occurrences of `substring` in `source` -- a count, not just a
    /// yes/no `contains`, because a count is what catches a second key
    /// appearing where only one should.
    private static func occurrenceCount(of substring: String, in source: String) -> Int {
        source.components(separatedBy: substring).count - 1
    }

    /// A `.contextMenu` block shaped like the real row's, with the three
    /// entries emitted in the given order -- lets the self-tests above
    /// exercise `entryOrder` without touching the real file.
    private static func syntheticSource(order: [String]) -> String {
        let buttons = order.map { key in
            "                Button(L10n.string(\"\(key)\", \"Label\")) { selectedID = snippet.id }"
        }.joined(separator: "\n")
        return """
            struct Fake: View {
                func row(_ snippet: Snippet) -> some View {
                    Text(snippet.name)
                        .contextMenu {
            \(buttons)
                        }
                }
            }
            """
    }

    /// A `.contextMenu` block shaped like the real row's, in the correct
    /// Edit -> Export -> Delete order, with the Export button's own body
    /// swappable -- lets the self-tests above exercise `exportButtonBlock`
    /// without touching the real file.
    private static func syntheticSource(exportBody: String) -> String {
        """
            struct Fake: View {
                func row(_ snippet: Snippet) -> some View {
                    Text(snippet.name)
                        .contextMenu {
                            Button(L10n.string("snippets.edit", "Edit…")) { selectedID = snippet.id }
                            Button(L10n.string("snippets.export", "Export…")) {
                                \(exportBody)
                            }
                            Button(L10n.string("snippets.delete", "Delete…"), role: .destructive) {
                                selectedID = snippet.id
                            }
                        }
                }
            }
            """
    }
}
