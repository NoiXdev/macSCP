import Foundation
import Testing

/// Guards ONE property of `SnippetActionSheet.swift`: the P3d keyboard
/// assignment the spec fixes as non-negotiable — Return activates Insert,
/// ⌘Return activates Execute, and Escape (via `role: .cancel`, the app-wide
/// sheet convention `KeyboardShortcutsCatalog` documents) activates Cancel.
/// See that file's own doc comment for the full reasoning and for why this
/// is the smaller sibling of `SnippetMenuItemsKeyboardShortcutGuardTests`
/// rather than a second copy of it: three flat, top-level buttons need no
/// brace-depth function isolation, only "find each button's own block by
/// its localization key, then read the modifier lines inside it."
///
/// Known blind spots, same limits as its precedent
/// (`SnippetMenuItemsKeyboardShortcutGuardTests`), not re-proven here to
/// keep this guard smaller: a SOURCE-TEXT scan, fooled by commented-out
/// code or an unusual reformat; it confirms WHICH button carries WHICH
/// modifier by localization key, not that the closure each button runs
/// actually calls `onInsert`/`onExecute`/`onCancel` rather than something
/// else with the same key.
@Suite("SnippetActionSheet keyboard shortcut guard")
struct SnippetActionSheetKeyboardShortcutGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SnippetActionSheetKeyboardShortcutGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `SnippetMenuItemsKeyboardShortcutGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SnippetActionSheet.swift")

    // MARK: - The guard

    @Test func insertCarriesExactlyDefaultAction() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let shortcuts = try Self.shortcutLines(forKey: "snippets.action.insert", in: source)
        #expect(shortcuts == [".keyboardShortcut(.defaultAction)"], """
            Insert must carry exactly \(".keyboardShortcut(.defaultAction)") (Return) — \
            found \(shortcuts) instead. See SnippetActionSheet's doc comment: Return must \
            never move onto Execute.
            """)
    }

    @Test func executeCarriesExactlyCommandReturn() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let shortcuts = try Self.shortcutLines(forKey: "snippets.action.execute", in: source)
        #expect(shortcuts == [".keyboardShortcut(.return, modifiers: .command)"], """
            Execute must carry exactly ⌘Return — found \(shortcuts) instead. A bare Return \
            here is exactly the regression this guard exists to catch.
            """)
    }

    @Test func cancelCarriesNoExplicitShortcut() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let shortcuts = try Self.shortcutLines(forKey: "snippets.action.cancel", in: source)
        #expect(shortcuts.isEmpty, """
            Cancel should rely on \("role: .cancel") alone (the app-wide sheet convention \
            for Escape) — found an explicit \(shortcuts) instead.
            """)
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    /// The exact regression this guard exists to catch: Return moved from
    /// Insert onto Execute.
    @Test func scannerFlagsDefaultActionMovedToExecute() {
        let source = Self.syntheticSource(
            cancelShortcut: nil,
            executeShortcut: ".keyboardShortcut(.defaultAction)",
            insertShortcut: nil)
        #expect(
            (try? Self.shortcutLines(forKey: "snippets.action.execute", in: source))
                == [".keyboardShortcut(.defaultAction)"],
            "the scanner must see a shortcut hand-moved onto the Execute button")
    }

    @Test func scannerAcceptsTheCorrectAssignment() throws {
        let source = Self.syntheticSource(
            cancelShortcut: nil,
            executeShortcut: ".keyboardShortcut(.return, modifiers: .command)",
            insertShortcut: ".keyboardShortcut(.defaultAction)")
        #expect(try Self.shortcutLines(forKey: "snippets.action.insert", in: source)
            == [".keyboardShortcut(.defaultAction)"])
        #expect(try Self.shortcutLines(forKey: "snippets.action.execute", in: source)
            == [".keyboardShortcut(.return, modifiers: .command)"])
        #expect(try Self.shortcutLines(forKey: "snippets.action.cancel", in: source) == [])
    }

    /// No button carrying this key at all — the scan must FAIL CLOSED
    /// (throw, so the caller records a failure) rather than silently
    /// report "no shortcuts found" as if that were an all-clear.
    @Test func scannerFailsClosedWhenAKeyCannotBeFound() {
        let source = "struct Empty {}"
        #expect(throws: (any Error).self) {
            try Self.shortcutLines(forKey: "snippets.action.insert", in: source)
        }
    }

    // MARK: - Scanner
    //
    // Deliberately line-based, like `SnippetMenuItemsKeyboardShortcutGuardTests`'s
    // scanner: find the line carrying a button's localization key, then read
    // every `.keyboardShortcut(` line between it and the NEXT `Button(` (or
    // end of source) — that span is exactly one button's own modifier chain
    // in this file's flat, non-nested layout.

    private enum ScanError: Error { case keyNotFound }

    /// Trimmed `.keyboardShortcut(...)` lines inside the block belonging to
    /// the button whose `Button(L10n.string("<key>"...` call this scans for.
    /// Throws if `key` cannot be located at all — see
    /// `scannerFailsClosedWhenAKeyCannotBeFound`.
    private static func shortcutLines(forKey key: String, in source: String) throws -> [String] {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("\"\(key)\"") }) else {
            throw ScanError.keyNotFound
        }
        var end = lines.count
        for index in (start + 1)..<lines.count where lines[index].contains("Button(") {
            end = index
            break
        }
        return lines[start..<end]
            .filter { $0.contains(".keyboardShortcut(") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A minimal three-button source shaped like `SnippetActionSheet.body`,
    /// with each button's shortcut line swappable — lets the self-tests
    /// above exercise the scanner without touching the real file.
    private static func syntheticSource(
        cancelShortcut: String?, executeShortcut: String?, insertShortcut: String?
    ) -> String {
        """
        struct Fake: View {
            var body: some View {
                Button(L10n.string("snippets.action.cancel", "Cancel"), role: .cancel) { }
                \(cancelShortcut ?? "")
                Button(L10n.string("snippets.action.execute", "Execute")) { }
                \(executeShortcut ?? "")
                Button(L10n.string("snippets.action.insert", "Insert")) { }
                \(insertShortcut ?? "")
            }
        }
        """
    }
}
