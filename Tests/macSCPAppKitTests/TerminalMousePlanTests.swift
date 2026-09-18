import Testing

@testable import MacSCPAppKit

/// The two pure decisions behind the terminal's mouse settings (next build
/// of 2026-09-17, Task 6): where a right click goes, and whether the end of
/// a mouse gesture copies the selection. Both are written out as full truth
/// tables, row by row, rather than recomputed from a rule — a table that
/// restates the implementation's own formula agrees with any formula.
@Suite("Terminal mouse plans")
struct TerminalMousePlanTests {

    // MARK: - Right click

    struct RightClickRow: Sendable, CustomTestStringConvertible {
        let pasteOnRightClick: Bool
        let optionPressed: Bool
        let snippetsExist: Bool
        let expected: TerminalRightClickPlan

        var testDescription: String {
            "paste=\(pasteOnRightClick) option=\(optionPressed) snippets=\(snippetsExist) → \(expected)"
        }
    }

    static let rightClickTable: [RightClickRow] = [
        // Setting off: exactly the behaviour before this setting existed —
        // the snippet menu when there are snippets, nothing otherwise, and
        // Option changes neither.
        RightClickRow(pasteOnRightClick: false, optionPressed: false, snippetsExist: false, expected: .systemDefault),
        RightClickRow(pasteOnRightClick: false, optionPressed: false, snippetsExist: true, expected: .snippetMenu),
        RightClickRow(pasteOnRightClick: false, optionPressed: true, snippetsExist: false, expected: .systemDefault),
        RightClickRow(pasteOnRightClick: false, optionPressed: true, snippetsExist: true, expected: .snippetMenu),
        // Setting on: a plain right click pastes, with or without snippets…
        RightClickRow(pasteOnRightClick: true, optionPressed: false, snippetsExist: false, expected: .paste),
        RightClickRow(pasteOnRightClick: true, optionPressed: false, snippetsExist: true, expected: .paste),
        // …and the snippet menu moves to Option-right-click. With no
        // snippets, Option-right-click neither pastes nor opens anything.
        RightClickRow(pasteOnRightClick: true, optionPressed: true, snippetsExist: false, expected: .systemDefault),
        RightClickRow(pasteOnRightClick: true, optionPressed: true, snippetsExist: true, expected: .snippetMenu),
    ]

    @Test("The right-click table holds every combination exactly once")
    func theRightClickTableIsComplete() {
        let combinations = Set(Self.rightClickTable.map {
            [$0.pasteOnRightClick, $0.optionPressed, $0.snippetsExist]
        })
        #expect(Self.rightClickTable.count == 8)
        #expect(combinations.count == 8)
    }

    @Test("Right click routing", arguments: rightClickTable)
    func rightClickRouting(_ row: RightClickRow) {
        #expect(TerminalRightClickPlan.action(
            pasteOnRightClick: row.pasteOnRightClick,
            optionPressed: row.optionPressed,
            snippetsExist: row.snippetsExist) == row.expected)
    }

    // MARK: - Copy on select

    struct CopyRow: Sendable, CustomTestStringConvertible {
        let enabled: Bool
        let changed: Bool
        let selection: String?
        let expected: String?
        /// Whether the plan builds the selection text at all. Building it
        /// walks the buffer, so it happens only for a gesture that changed
        /// the selection with the setting on — not on every click.
        let reads: Bool

        var testDescription: String {
            "enabled=\(enabled) changed=\(changed) selection=\(selection.debugDescription) → \(expected.debugDescription), reads=\(reads)"
        }
    }

    static let copyTable: [CopyRow] = [
        // Setting off: nothing copied, and the selection never read.
        CopyRow(enabled: false, changed: false, selection: nil, expected: nil, reads: false),
        CopyRow(enabled: false, changed: false, selection: "", expected: nil, reads: false),
        CopyRow(enabled: false, changed: false, selection: "ls", expected: nil, reads: false),
        CopyRow(enabled: false, changed: true, selection: nil, expected: nil, reads: false),
        CopyRow(enabled: false, changed: true, selection: "", expected: nil, reads: false),
        CopyRow(enabled: false, changed: true, selection: "ls", expected: nil, reads: false),
        // Setting on, the gesture changed nothing (a click the remote
        // application took for mouse reporting, or a click with no
        // selection anywhere): the old selection, if there is one, is not
        // copied again over whatever the user copied since, and it is not
        // even read.
        CopyRow(enabled: true, changed: false, selection: nil, expected: nil, reads: false),
        CopyRow(enabled: true, changed: false, selection: "", expected: nil, reads: false),
        CopyRow(enabled: true, changed: false, selection: "ls", expected: nil, reads: false),
        // Setting on, the gesture changed the selection: read it. Gone (a
        // plain click that cleared it) or empty (a drag that never left its
        // first cell) copies nothing — it would only wipe the clipboard.
        CopyRow(enabled: true, changed: true, selection: nil, expected: nil, reads: true),
        CopyRow(enabled: true, changed: true, selection: "", expected: nil, reads: true),
        CopyRow(enabled: true, changed: true, selection: "ls", expected: "ls", reads: true),
    ]

    @Test("The copy table holds every combination exactly once")
    func theCopyTableIsComplete() {
        struct Key: Hashable { let enabled: Bool; let changed: Bool; let selection: String? }
        let keys = Set(Self.copyTable.map { Key(enabled: $0.enabled, changed: $0.changed, selection: $0.selection) })
        // enabled × changed × selection ∈ {nil, "", "ls"}
        #expect(Self.copyTable.count == 12)
        #expect(keys.count == 12)
    }

    @Test("Copy on select", arguments: copyTable)
    func copyOnSelect(_ row: CopyRow) {
        var reads = 0
        let copied = TerminalCopyOnSelectPlan.textToCopy(
            enabled: row.enabled,
            selectionChangedDuringGesture: row.changed,
            selection: {
                reads += 1
                return row.selection
            })
        #expect(copied == row.expected)
        #expect(reads == (row.reads ? 1 : 0))
    }
}
