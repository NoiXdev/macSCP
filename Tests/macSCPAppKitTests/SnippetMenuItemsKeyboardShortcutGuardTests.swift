import Foundation
import Testing

/// Guards ONE property of `SnippetMenuItems.swift`: `.keyboardShortcut` may
/// appear only inside `insertButton` — the one place the Terminal-Snippets
/// milestone's non-negotiable rule allows it. ⌃⌘1–3 insert the first three
/// snippets in store order; EXECUTE never gets a shortcut at all, because a
/// keystroke that fires a command on a remote host the instant it is pressed
/// has no good failure mode — no undo, no confirmation.
///
/// `SnippetMenuPlan.Entry` already enforces the safe half of this
/// structurally: it carries only `insertShortcutDigit`, and there is no
/// field an execute shortcut could travel through. What that does NOT cover
/// is someone hand-writing `.keyboardShortcut(...)` directly on the Execute
/// `Button` in `entryButtons` — that compiles, ships, and `swift test` stays
/// green apart from this one file. A type-level fix cannot close that gap:
/// the danger is a local, syntactic slip on one `Button` call, not a change
/// to `SnippetMenuModel` or `SnippetMenuPlan` — neither would even notice.
/// A source-text scan is the right tool for exactly that shape of risk, the
/// same reasoning `IconTooltipLintTests` (M19a) already established for a
/// different invariant in this app target.
///
/// Known blind spots, so a green run is not mistaken for a proof:
/// - This is a SOURCE-TEXT scan, same limits as `IconTooltipLintTests`:
///   commented-out code, an unusual reformat, or a rename of `insertButton`
///   itself could fool it. `scannerFailsClosedWhenInsertButtonCannotBeFound`
///   below at least pins that the LAST of those fails closed (flags rather
///   than silently passing) instead of failing open.
/// - It does not verify that `insertButton` is actually wired to the INSERT
///   action rather than some other one — only that whatever `.keyboardShortcut`
///   calls exist all sit inside the function of that name. Renaming
///   `insertButton` to wrap the Execute button instead would defeat this
///   scan; nothing but a human reading the diff catches that swap.
@Suite("SnippetMenuItems keyboard shortcut guard")
struct SnippetMenuItemsKeyboardShortcutGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SnippetMenuItemsKeyboardShortcutGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `LocalizableStringsTests`/`IconTooltipLintTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SnippetMenuItems.swift")

    // MARK: - The guard

    @Test func keyboardShortcutAppearsOnlyInsideInsertButton() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let violations = Self.keyboardShortcutViolations(in: source)
        #expect(violations.isEmpty, """
            .keyboardShortcut found outside insertButton at line(s) \
            \(violations.map { $0 + 1 }) of \(Self.sourceFile.lastPathComponent). \
            EXECUTE must never carry a keyboard shortcut — see this suite's doc comment.
            """)
    }

    /// A present-tense check that `insertButton` still carries ITS OWN
    /// shortcut. Without this, a scanner that quietly stopped recognizing
    /// any `.keyboardShortcut` call at all (say, `insertButton` got renamed
    /// or the call reformatted past what `range(ofFunctionNamed:)` expects)
    /// would report the all-clear above for the wrong reason: zero
    /// violations because zero calls were seen, not because the one real
    /// call is correctly placed.
    @Test func insertButtonStillCarriesTheShortcut() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        guard let range = Self.range(ofFunctionNamed: "insertButton", in: lines) else {
            Issue.record(
                "insertButton not found in \(Self.sourceFile.lastPathComponent) — re-anchor this guard")
            return
        }
        let shortcutLinesInRange = Self.lineNumbers(ofKeyboardShortcutCalls: lines)
            .filter { range.contains($0) }
        #expect(!shortcutLinesInRange.isEmpty, "insertButton no longer contains a .keyboardShortcut call")
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    /// The exact regression this guard exists to catch: a `.keyboardShortcut`
    /// hand-added to the Execute button, outside `insertButton` entirely.
    @Test func scannerFlagsAShortcutAddedToTheExecuteButton() {
        let source = """
            private func insertButton(_ entry: Entry) -> some View {
                let button = Button("Insert") { action(entry.snippet, false) }
                if let digit = entry.insertShortcutDigit {
                    button.keyboardShortcut(KeyEquivalent(Character("\\(digit)")), modifiers: [.control, .command])
                } else {
                    button
                }
            }

            private func entryButtons(_ entries: [Entry]) -> some View {
                ForEach(entries) { entry in
                    Menu(entry.snippet.name) {
                        insertButton(entry)
                        Button("Execute") { action(entry.snippet, true) }
                            .keyboardShortcut("9", modifiers: [.control, .command])
                    }
                }
            }
            """
        #expect(
            !Self.keyboardShortcutViolations(in: source).isEmpty,
            "the scanner must flag a shortcut hand-added to the Execute button")
    }

    @Test func scannerAcceptsAShortcutOnlyOnInsertButton() {
        let source = """
            private func insertButton(_ entry: Entry) -> some View {
                let button = Button("Insert") { action(entry.snippet, false) }
                button.keyboardShortcut("1", modifiers: [.control, .command])
            }

            private func entryButtons(_ entries: [Entry]) -> some View {
                ForEach(entries) { entry in
                    Menu(entry.snippet.name) {
                        insertButton(entry)
                        Button("Execute") { action(entry.snippet, true) }
                    }
                }
            }
            """
        #expect(Self.keyboardShortcutViolations(in: source).isEmpty)
    }

    /// No `insertButton` function at all — the scan must FAIL CLOSED (flag
    /// every shortcut it finds) rather than silently pass because it found
    /// nothing to compare against.
    @Test func scannerFailsClosedWhenInsertButtonCannotBeFound() {
        let source = """
            private func somethingElse() -> some View {
                Button("Insert") { }.keyboardShortcut("1", modifiers: [.control, .command])
            }
            """
        #expect(!Self.keyboardShortcutViolations(in: source).isEmpty)
    }

    @Test func scannerIsQuietWhenThereIsNoShortcutAtAll() {
        let source = """
            private func insertButton(_ entry: Entry) -> some View {
                Button("Insert") { action(entry.snippet, false) }
            }
            """
        #expect(Self.keyboardShortcutViolations(in: source).isEmpty)
    }

    // MARK: - Scanner
    //
    // Deliberately line-based, like `IconTooltipLintTests`'s scanner: it
    // reads `{`/`}` to find where `insertButton`'s body ends and looks for
    // the literal text `.keyboardShortcut(` anywhere else. Brittle to a
    // determined rewrite, precise enough for an accidental one — which is
    // the failure mode this guard is actually aimed at.

    /// The line range of `private func <name>(...) { ... }`, found by
    /// counting braces from the line the signature appears on until depth
    /// returns to zero. 0-based, inclusive of both the signature line and
    /// the closing brace's line.
    private static func range(ofFunctionNamed name: String, in lines: [String]) -> ClosedRange<Int>? {
        guard let start = lines.firstIndex(where: { $0.contains("func \(name)(") }) else { return nil }
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

    /// 0-based line indices containing a `.keyboardShortcut(` call.
    private static func lineNumbers(ofKeyboardShortcutCalls lines: [String]) -> [Int] {
        lines.indices.filter { lines[$0].contains(".keyboardShortcut(") }
    }

    /// Every `.keyboardShortcut(` call NOT inside `insertButton`. An
    /// unrecoverable `insertButton` (see `scannerFailsClosedWhenInsertButtonCannotBeFound`
    /// above) makes every call a violation — there is nothing to vouch for
    /// its placement.
    private static func keyboardShortcutViolations(in source: String) -> [Int] {
        let lines = source.components(separatedBy: "\n")
        let shortcutLines = lineNumbers(ofKeyboardShortcutCalls: lines)
        guard let insertRange = range(ofFunctionNamed: "insertButton", in: lines) else {
            return shortcutLines
        }
        return shortcutLines.filter { !insertRange.contains($0) }
    }
}
