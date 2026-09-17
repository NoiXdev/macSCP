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
        let atStart: String?
        let atEnd: String?
        let toggled: Bool
        let expected: String?

        var testDescription: String {
            "start=\(atStart.debugDescription) end=\(atEnd.debugDescription) toggled=\(toggled) → \(expected.debugDescription)"
        }
    }

    /// The enabled half. Start values: none, empty, "ls". End values: none,
    /// empty, the same "ls", a different "ls -la".
    static let copyTable: [CopyRow] = [
        // No selection at the end: nothing to copy, whatever came before.
        CopyRow(atStart: nil, atEnd: nil, toggled: false, expected: nil),
        CopyRow(atStart: nil, atEnd: nil, toggled: true, expected: nil),
        CopyRow(atStart: "", atEnd: nil, toggled: false, expected: nil),
        CopyRow(atStart: "", atEnd: nil, toggled: true, expected: nil),
        CopyRow(atStart: "ls", atEnd: nil, toggled: false, expected: nil),
        // A plain click that clears an existing selection.
        CopyRow(atStart: "ls", atEnd: nil, toggled: true, expected: nil),
        // An empty selection is never copied — it would only wipe the
        // clipboard.
        CopyRow(atStart: nil, atEnd: "", toggled: false, expected: nil),
        CopyRow(atStart: nil, atEnd: "", toggled: true, expected: nil),
        CopyRow(atStart: "", atEnd: "", toggled: false, expected: nil),
        CopyRow(atStart: "", atEnd: "", toggled: true, expected: nil),
        CopyRow(atStart: "ls", atEnd: "", toggled: false, expected: nil),
        CopyRow(atStart: "ls", atEnd: "", toggled: true, expected: nil),
        // A new selection where there was none (drag, double or triple click).
        CopyRow(atStart: nil, atEnd: "ls", toggled: false, expected: "ls"),
        CopyRow(atStart: nil, atEnd: "ls", toggled: true, expected: "ls"),
        // The same text before and after with no toggle: the gesture did not
        // select anything (a click the remote application took for mouse
        // reporting). Copying here would put a stale selection back over
        // whatever the user copied since.
        CopyRow(atStart: "ls", atEnd: "ls", toggled: false, expected: nil),
        // The same text, but the selection went away and came back during
        // the gesture: a fresh selection that happens to match.
        CopyRow(atStart: "ls", atEnd: "ls", toggled: true, expected: "ls"),
        // A changed selection (shift-click extend, a new drag).
        CopyRow(atStart: "", atEnd: "ls", toggled: false, expected: "ls"),
        CopyRow(atStart: "", atEnd: "ls", toggled: true, expected: "ls"),
        CopyRow(atStart: nil, atEnd: "ls -la", toggled: false, expected: "ls -la"),
        CopyRow(atStart: nil, atEnd: "ls -la", toggled: true, expected: "ls -la"),
        CopyRow(atStart: "", atEnd: "ls -la", toggled: false, expected: "ls -la"),
        CopyRow(atStart: "", atEnd: "ls -la", toggled: true, expected: "ls -la"),
        CopyRow(atStart: "ls", atEnd: "ls -la", toggled: false, expected: "ls -la"),
        CopyRow(atStart: "ls", atEnd: "ls -la", toggled: true, expected: "ls -la"),
    ]

    @Test("The copy table holds every combination exactly once")
    func theCopyTableIsComplete() {
        struct Key: Hashable { let start: String?; let end: String?; let toggled: Bool }
        let keys = Set(Self.copyTable.map { Key(start: $0.atStart, end: $0.atEnd, toggled: $0.toggled) })
        // start ∈ {nil, "", "ls"} × end ∈ {nil, "", "ls", "ls -la"} × toggled ∈ {false, true}
        #expect(Self.copyTable.count == 24)
        #expect(keys.count == 24)
    }

    @Test("Copy on select, enabled", arguments: copyTable)
    func copyOnSelectEnabled(_ row: CopyRow) {
        #expect(TerminalCopyOnSelectPlan.textToCopy(
            enabled: true,
            selectionAtGestureStart: row.atStart,
            selectionAtGestureEnd: row.atEnd,
            selectionToggledDuringGesture: row.toggled) == row.expected)
    }

    /// The disabled half: every row of the enabled table, nothing copied.
    @Test("Copy on select, disabled, copies nothing", arguments: copyTable)
    func copyOnSelectDisabled(_ row: CopyRow) {
        #expect(TerminalCopyOnSelectPlan.textToCopy(
            enabled: false,
            selectionAtGestureStart: row.atStart,
            selectionAtGestureEnd: row.atEnd,
            selectionToggledDuringGesture: row.toggled) == nil)
    }
}
