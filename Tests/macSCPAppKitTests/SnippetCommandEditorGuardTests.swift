import Foundation
import Testing

/// Guards three properties of `SnippetCommandEditor.swift` and its wiring in
/// `SnippetsSheet.swift`, all three raised by the whole-branch review of the
/// snippet syntax-highlighting feature and none of them provable any other
/// way in this project (no test here renders an `NSViewRepresentable` — see
/// `SnippetsSheet.swift`'s own doc comment on that boundary):
///
/// 1. **Automatic substitutions disabled.** An `NSTextField`'s field editor
///    disables smart quotes/dashes/text-replacement/spelling/insert-delete
///    by default; a raw `NSTextView` does not. Losing any one of the five
///    explicit `= false` assignments in `makeNSView` silently reintroduces
///    corruption of a typed command under the system's "smart quotes and
///    dashes" setting.
/// 2. **Tab traverses focus.** A raw `NSTextView`'s own `insertTab:` inserts
///    a literal tab character by default. Losing the `Coordinator`'s
///    `textView(_:doCommandBy:)` handling (or its `return true`)
///    reintroduces stray `\t` bytes into stored, later shell-executed,
///    commands.
/// 3. **Accessibility label wired through.** `FormRow` hides its own visible
///    label from VoiceOver on the assumption that the wrapped control
///    supplies one itself (see `FormRow`'s doc comment, M6a). Losing the
///    `accessibilityLabel` wiring — either the `setAccessibilityLabel` call
///    in `SnippetCommandEditor` or the call-site argument in
///    `SnippetsSheet` — leaves the command field with no accessible name at
///    all, silently, since nothing else in this project exercises VoiceOver.
///
/// Each is a SOURCE-TEXT scan, same shape and same blind spots as
/// `SnippetActionSheetKeyboardShortcutGuardTests`/
/// `SnippetMenuItemsKeyboardShortcutGuardTests`: fooled by commented-out
/// code or an unusual reformat, and confirms the SHAPE of the wiring by
/// substring/pattern match, not that the runtime behaviour is actually
/// correct. Each scan fails closed — a marker it cannot find, or a file it
/// cannot read, is a thrown error (a test failure), never a silent pass —
/// and each has a self-test proving the scanner actually reacts to the
/// regression it exists to catch, not just to well-formed input.
@Suite("SnippetCommandEditor guard")
struct SnippetCommandEditorGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SnippetCommandEditorGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `SnippetActionSheetKeyboardShortcutGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let editorSourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SnippetCommandEditor.swift")
    private static let sheetSourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SnippetsSheet.swift")

    private enum ScanError: Error { case markerNotFound, unbalancedBraces }

    // MARK: - Finding 1: automatic substitutions

    private static let requiredDisabledProperties = [
        "isAutomaticQuoteSubstitutionEnabled",
        "isAutomaticDashSubstitutionEnabled",
        "isAutomaticTextReplacementEnabled",
        "isAutomaticSpellingCorrectionEnabled",
        "smartInsertDeleteEnabled",
    ]

    @Test func allFiveAutomaticSubstitutionsAreExplicitlyDisabled() throws {
        let source = try String(contentsOf: Self.editorSourceFile, encoding: .utf8)
        let body = try Self.functionBody(containing: "func makeNSView", in: source)
        for property in Self.requiredDisabledProperties {
            #expect(Self.disables(property, in: body), """
                \(property) must be set to `false` inside makeNSView -- an NSTextField's field \
                editor disables this by default, a raw NSTextView does not, and leaving it at \
                the system default silently corrupts a typed command under "smart quotes and \
                dashes". Not found as `\(property) = false` in the scanned body.
                """)
        }
    }

    @Test func scannerFlagsAMissingSubstitutionDisable() throws {
        let body = Self.syntheticMakeNSViewBody(omitting: "smartInsertDeleteEnabled")
        #expect(!Self.disables("smartInsertDeleteEnabled", in: body),
            "the scanner must notice when one of the five disables is missing")
    }

    @Test func scannerAcceptsAllFiveDisabled() throws {
        let body = Self.syntheticMakeNSViewBody(omitting: nil)
        for property in Self.requiredDisabledProperties {
            #expect(Self.disables(property, in: body))
        }
    }

    private static func disables(_ property: String, in body: String) -> Bool {
        body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { $0.contains("\(property) = false") }
    }

    private static func syntheticMakeNSViewBody(omitting skipped: String?) -> String {
        let lines = requiredDisabledProperties
            .filter { $0 != skipped }
            .map { "        textView.\($0) = false" }
        return (["func makeNSView(context: Context) -> NSScrollView {"]
            + lines + ["}"]).joined(separator: "\n")
    }

    // MARK: - Finding 2: Tab traversal

    @Test func tabAndBacktabClaimFocusTraversalInsteadOfInsertingATab() throws {
        let source = try String(contentsOf: Self.editorSourceFile, encoding: .utf8)
        let body = try Self.functionBody(containing: "doCommandBy selector", in: source)
        #expect(body.contains("#selector(NSResponder.insertTab(_:))"), """
            The Tab command selector must be matched explicitly in \
            textView(_:doCommandBy:) -- otherwise AppKit's default handling for a raw \
            NSTextView inserts a literal tab character instead of moving focus. Scanned body: \
            \(body)
            """)
        let tabCase = Self.linesAfterMarker(
            "#selector(NSResponder.insertTab(_:))", in: body)
        #expect(tabCase.contains { $0.trimmingCharacters(in: .whitespaces) == "return true" }, """
            The insertTab: case must return true (claiming the command) rather than falling \
            through to `default: return false`, which re-enables literal-tab insertion. Case \
            lines: \(tabCase)
            """)
    }

    @Test func scannerFlagsTheRegressionWhereTabFallsThroughToDefault() {
        let body = """
            func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
                switch selector {
                default:
                    return false
                }
            }
            """
        #expect(!body.contains("#selector(NSResponder.insertTab(_:))"),
            "the scanner must see that insertTab: is not even matched in the regressed source")
    }

    @Test func scannerAcceptsTheCorrectTabHandling() {
        let body = """
            func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
                switch selector {
                case #selector(NSResponder.insertTab(_:)):
                    textView.window?.selectNextKeyView(nil)
                    return true
                default:
                    return false
                }
            }
            """
        let tabCase = Self.linesAfterMarker("#selector(NSResponder.insertTab(_:))", in: body)
        #expect(tabCase.contains { $0.trimmingCharacters(in: .whitespaces) == "return true" })
    }

    // MARK: - Finding 4: accessibility label

    @Test func editorDeclaresAndWiresAnAccessibilityLabelParameter() throws {
        let source = try String(contentsOf: Self.editorSourceFile, encoding: .utf8)
        #expect(source.contains("let accessibilityLabel: String"), """
            SnippetCommandEditor must declare an `accessibilityLabel: String` property -- \
            without one, there is nothing for makeNSView to hand VoiceOver.
            """)
        let body = try Self.functionBody(containing: "func makeNSView", in: source)
        #expect(body.contains("setAccessibilityLabel(accessibilityLabel)"), """
            makeNSView must call textView.setAccessibilityLabel(accessibilityLabel) -- \
            FormRow hides its own visible label from VoiceOver on the assumption the wrapped \
            control supplies one itself (M6a); without this call the command field has no \
            accessible name at all. Scanned body: \(body)
            """)
    }

    @Test func sheetPassesTheSameLocalizedStringTheRowLabelUses() throws {
        let source = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        #expect(source.contains("FormRow(label: commandLabel)"), """
            Expected the command row to still be built as `FormRow(label: commandLabel)` -- if \
            this changed, the assertion below (that the editor gets the SAME `commandLabel`) \
            no longer proves anything.
            """)
        #expect(
            source.contains("SnippetCommandEditor(text: $command, accessibilityLabel: commandLabel)"),
            """
            SnippetCommandEditor must be constructed with `accessibilityLabel: commandLabel` \
            -- the exact same local the row's own (VoiceOver-hidden) label uses -- so the two \
            can never drift into two different wordings for the same field.
            """)
    }

    @Test func scannerFlagsAMissingAccessibilityLabelArgument() {
        let source = "SnippetCommandEditor(text: $command)\n    .frame(height: 24)"
        #expect(
            !source.contains("SnippetCommandEditor(text: $command, accessibilityLabel: commandLabel)"),
            "the scanner must see that the pre-fix call site (no accessibilityLabel argument) does not match")
    }

    // MARK: - Scanner (shared)
    //
    // Brace-balanced from the marker's own line onward -- deliberately NOT
    // line-based like the two `keyboardShortcut` guard scanners, because
    // this file's method signatures wrap across multiple lines and a
    // same-indentation-close-brace heuristic would be fragile against
    // reformatting. Counts raw `{`/`}` characters from the marker's line to
    // the first point balance returns to zero after having gone positive,
    // which is exactly "the block the marker's declaration opens."

    private static func functionBody(containing marker: String, in source: String) throws -> String {
        guard let markerRange = source.range(of: marker) else { throw ScanError.markerNotFound }
        let lineStart = source[..<markerRange.lowerBound].lastIndex(of: "\n")
            .map { source.index(after: $0) } ?? source.startIndex
        var depth = 0
        var enteredBlock = false
        var index = lineStart
        while index < source.endIndex {
            let ch = source[index]
            if ch == "{" { depth += 1; enteredBlock = true }
            if ch == "}" { depth -= 1 }
            index = source.index(after: index)
            if enteredBlock, depth == 0 {
                return String(source[lineStart..<index])
            }
        }
        throw ScanError.unbalancedBraces
    }

    /// Trimmed lines from the line containing `marker` up to (excluding) the
    /// next `case `/`default:` line, or the end of `body` -- one switch
    /// case's own lines, the same "scan to the next sibling marker" idiom
    /// `SnippetActionSheetKeyboardShortcutGuardTests.shortcutLines` uses for
    /// one button's own lines.
    private static func linesAfterMarker(_ marker: String, in body: String) -> [String] {
        let lines = body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains(marker) }) else { return [] }
        var end = lines.count
        for index in (start + 1)..<lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("case ") || trimmed.hasPrefix("default:") {
                end = index
                break
            }
        }
        return lines[start..<end].map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Scanner fails closed

    @Test func functionBodyFailsClosedWhenMarkerCannotBeFound() {
        #expect(throws: (any Error).self) {
            try Self.functionBody(containing: "func thisDoesNotExist", in: "struct Empty {}")
        }
    }

    @Test func functionBodyFailsClosedOnUnbalancedBraces() {
        #expect(throws: (any Error).self) {
            try Self.functionBody(containing: "func broken", in: "func broken() {\n    // no close")
        }
    }
}
