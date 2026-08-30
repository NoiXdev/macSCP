import Foundation
import Testing

/// Guards seven properties of `SnippetsSheet.swift`'s snippet editor: five
/// in `SnippetCommandEditor.swift`'s own wiring, raised by the whole-branch
/// review of the snippet syntax-highlighting feature, plus two in
/// `SnippetEditorView` itself (variable-declaration Save-gating, Task 5,
/// and the per-snippet placement-check waiver).
/// None of the seven are provable any other way in this project (no test here
/// renders an `NSViewRepresentable` or a `View` body — see `SnippetsSheet
/// .swift`'s own doc comment on that boundary):
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
/// 4. **Return inserts a line break.** Part 2 made a snippet command
///    multi-line, so a typed Return has something to insert and must NOT be
///    claimed at the command layer. A reappearing `insertNewline(_:)` case
///    in `textView(_:doCommandBy:)` would silently make the field
///    single-line again, and the failure would look like "Return does
///    nothing" rather than like a bug.
/// 5. **Save moved to command-Return.** The Save button's own shortcut is
///    `.keyboardShortcut(.return, modifiers: .command)`, not the plain
///    default action: Return now belongs to the command field. A Save
///    button that reverted to `.defaultAction` would take Return back and
///    make line breaks untypeable, and the failure would present as "the
///    editor saves when I try to add a line".
/// 6. **Variable declarations gate Save, and say why (Task 5).**
///    `isSaveDisabled` must also test `variablesError != nil`, and
///    `variablesError` must actually run `SnippetVariable.isValidName`, a
///    duplicate-name check and `SnippetVariableSubstitution
///    .firstDeclarationProblem` — losing any one would let Save write a
///    snippet with an invalid, duplicate, unused or mis-quoted declaration.
///    Separately, `variablesSection` must render `variablesError` as its own
///    `Text` whenever it is non-nil: the brief is explicit that a greyed-out
///    Save button must not be the only signal, because a user who cannot
///    tell why does not experiment, they give up.
/// 7. **The placement-check waiver is offered, consulted and stored.**
///    `Snippet.skipsPlaceholderPlacementCheck` is the one per-snippet
///    setting with no other surface in the app: `variablesSection` must
///    render a control bound to it under its localized key,
///    `variablesError` must pass it to `firstDeclarationProblem`, and
///    `save()` must write it onto the `Snippet`. Losing the first makes it
///    unreachable, the second makes it decoration, and the third — the
///    quiet one — compiles, because `Snippet`'s initializer defaults the
///    field to `false`.
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

    // MARK: - Finding 4: Return inserts a line break (insertNewline not claimed)

    @Test func insertNewlineIsNotClaimedInDoCommandBy() throws {
        let source = try String(contentsOf: Self.editorSourceFile, encoding: .utf8)
        let body = try Self.functionBody(containing: "doCommandBy selector", in: source)
        #expect(!body.contains("#selector(NSResponder.insertNewline(_:))"), """
            The insertNewline: command selector must NOT be matched in \
            textView(_:doCommandBy:) -- a snippet command may now span lines (part 2), so a \
            typed Return must fall through to AppKit's default handling and actually insert \
            the line break. A reappearing case here would silently claim it again and make the \
            field single-line, and the failure would look like "Return does nothing" rather \
            than like a bug. Scanned body: \(body)
            """)
    }

    @Test func scannerFlagsTheRegressionWhereInsertNewlineIsClaimedAgain() {
        let body = """
            func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
                switch selector {
                case #selector(NSResponder.insertNewline(_:)):
                    return true
                default:
                    return false
                }
            }
            """
        #expect(body.contains("#selector(NSResponder.insertNewline(_:))"),
            "the scanner must see that insertNewline: is matched again in the regressed source")
    }

    @Test func scannerAcceptsTheCorrectMissingInsertNewlineHandling() {
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
        #expect(!body.contains("#selector(NSResponder.insertNewline(_:))"))
    }

    // MARK: - Save moved to command-Return

    /// The snippet editor's Save button carries ⌘Return, not the plain
    /// default action: Return belongs to the command field now, which is
    /// multi-line. A Save button that reverted to `.defaultAction` would
    /// take Return back and make line breaks untypeable — and the failure
    /// would present as "the editor saves when I try to add a line".
    ///
    /// The scan is anchored on the struct declaration, not on
    /// `SnippetCommandEditor(` itself: `functionBody`'s brace counter walks
    /// forward from the marker's own line, so a marker that is a call site
    /// buried inside one `FormRow` closure among several sibling closures
    /// hits a spurious depth-zero the moment the PRECEDING closure's `}` is
    /// cancelled out by the FOLLOWING closure's `{` — long before the Save
    /// button is reached. The struct's own declaration line carries its
    /// opening brace right there, so the walk is balanced from a true depth
    /// of zero and correctly spans the whole `SnippetEditorView` body,
    /// editor call site and Save button included.
    @Test("the snippet editor saves on command-Return")
    func snippetEditorSavesOnCommandReturn() throws {
        let source = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        let body = try Self.functionBody(
            containing: "private struct SnippetEditorView: View {", in: source)
        #expect(body.contains("SnippetCommandEditor("), """
            Sanity check: the scanned struct body must still contain the editor call site, or \
            this test would pass for the wrong reason (a struct that no longer builds the \
            editor at all).
            """)
        #expect(body.contains("keyboardShortcut(.return, modifiers: .command)"))
        #expect(!body.contains("keyboardShortcut(.defaultAction)"))
    }

    @Test("the command-Return scan reacts to a reverted shortcut")
    func commandReturnScanReactsToRegression() throws {
        let reverted = """
            private struct SnippetEditorView: View {
                var body: some View {
                    SnippetCommandEditor(text: $command)
                    Button("Save") { save() }.keyboardShortcut(.defaultAction)
                }
            }
            """
        let body = try Self.functionBody(
            containing: "private struct SnippetEditorView: View {", in: reverted)
        #expect(!body.contains("keyboardShortcut(.return, modifiers: .command)"))
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

    // MARK: - Finding 6: variable declarations gate Save, and say why (Task 5)

    @Test("isSaveDisabled also gates on the variables error")
    func isSaveDisabledGatesOnVariablesError() throws {
        let source = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        let body = try Self.functionBody(
            containing: "private var isSaveDisabled: Bool {", in: source)
        #expect(body.contains("variablesError != nil"), """
            isSaveDisabled must also test variablesError != nil -- Task 5 requires Save to \
            stay disabled while a variable name is invalid or duplicate, or while \
            SnippetVariableSubstitution.firstDeclarationProblem finds a problem. Scanned body: \
            \(body)
            """)
    }

    @Test("the isSaveDisabled scan reacts to a reverted, variables-blind gate")
    func isSaveDisabledScanReactsToRegression() throws {
        let reverted = """
            private var isSaveDisabled: Bool {
                name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            """
        let body = try Self.functionBody(
            containing: "private var isSaveDisabled: Bool {", in: reverted)
        #expect(!body.contains("variablesError != nil"))
    }

    /// `SnippetVariable.isValidName` has no caller before this feature (see
    /// `SnippetVariable`'s own doc comment) -- this scan is what keeps that
    /// true going forward, alongside the duplicate-name check and
    /// `firstDeclarationProblem`, which together are the two things Step 2
    /// of the brief names explicitly.
    @Test("variablesError runs all three declaration checks")
    func variablesErrorRunsAllThreeChecks() throws {
        let source = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        let body = try Self.functionBody(
            containing: "private var variablesError: String? {", in: source)
        #expect(body.contains("SnippetVariable.isValidName("), """
            variablesError must call SnippetVariable.isValidName -- an invalid variable name \
            (Step 2 of the brief) would otherwise reach Snippet.save unchecked. Scanned body: \
            \(body)
            """)
        #expect(body.contains("Set(trimmedNames).count != trimmedNames.count"), """
            variablesError must detect two variables sharing a name (Step 2 of the brief). \
            Scanned body: \(body)
            """)
        #expect(body.contains("SnippetVariableSubstitution.firstDeclarationProblem("), """
            variablesError must call SnippetVariableSubstitution.firstDeclarationProblem -- \
            an unused placeholder or one sitting inside quotes (Step 2 of the brief) would \
            otherwise reach Snippet.save unchecked. Scanned body: \(body)
            """)
    }

    @Test("the variablesError scan reacts to a check silently dropped")
    func variablesErrorScanReactsToADroppedCheck() throws {
        let missingIsValidName = """
            private var variablesError: String? {
                let trimmedNames = variableDrafts.map { $0.name }
                if Set(trimmedNames).count != trimmedNames.count { return "duplicate" }
                if let problem = SnippetVariableSubstitution.firstDeclarationProblem(
                    command: command, variables: variables) { return "problem" }
                return nil
            }
            """
        let body = try Self.functionBody(
            containing: "private var variablesError: String? {", in: missingIsValidName)
        #expect(!body.contains("SnippetVariable.isValidName("))
    }

    /// A greyed-out Save button alone does not say why (brief, Step 2) --
    /// this proves the reason is rendered as its own `Text`, not only used
    /// to compute `isSaveDisabled`.
    @Test("the variables section renders variablesError, not only uses it to disable Save")
    func variablesSectionRendersTheError() throws {
        let source = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        let body = try Self.functionBody(
            containing: "private var variablesSection: some View {", in: source)
        #expect(body.contains("if let variablesError {"), """
            variablesSection must show variablesError as its own Text whenever it is \
            non-nil -- otherwise the only signal a blocked save gives is a disabled button, \
            which the brief calls out by name as not enough. Scanned body: \(body)
            """)
    }

    @Test("the rendered-error scan reacts to the text silently removed")
    func variablesSectionScanReactsToARemovedErrorText() throws {
        let withoutErrorText = """
            private var variablesSection: some View {
                VStack {
                    Text("Variables")
                    ForEach($variableDrafts) { draft in
                        variableRow(draft) {}
                    }
                }
            }
            """
        let body = try Self.functionBody(
            containing: "private var variablesSection: some View {", in: withoutErrorText)
        #expect(!body.contains("if let variablesError {"))
    }

    // MARK: - Finding 7: the placement-check waiver is offered, consulted and stored

    /// The three halves have to hold TOGETHER, which is why they are three
    /// checks and not one: a checkbox nobody consults is decoration, a
    /// consulted flag nobody stores is forgotten on Save, and a stored flag
    /// with no control is unreachable. Each of the three is a positive
    /// `contains` — it names something that must be PRESENT, so it fails
    /// loudly the moment the thing it names is renamed or moved, rather
    /// than going quiet the way a `!contains` would.
    @Test("the variables section offers the placement-check waiver as a control")
    func variablesSectionOffersTheWaiver() throws {
        let source = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        let body = try Self.functionBody(
            containing: "private var variablesSection: some View {", in: source)
        #expect(body.contains("isOn: $skipsPlacementCheck"), """
            variablesSection must render a control bound to $skipsPlacementCheck -- the \
            per-snippet exit from the placeholder placement check is only reachable where a \
            snippet is edited, and nothing else in this project offers it. Scanned body: \
            \(body)
            """)
        #expect(body.contains("snippets.editor.skipPlacementCheck"), """
            the waiver's control must carry its localized label key -- a hardcoded English \
            string would leave the German, French and Polish catalogs with nothing to \
            translate. Scanned body: \(body)
            """)
    }

    @Test("variablesError consults the waiver rather than checking regardless")
    func variablesErrorConsultsTheWaiver() throws {
        let source = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        let body = try Self.functionBody(
            containing: "private var variablesError: String? {", in: source)
        #expect(body.contains("skipsPlacementCheck: skipsPlacementCheck"), """
            variablesError must pass skipsPlacementCheck to firstDeclarationProblem -- \
            otherwise the checkbox is drawn, stored and ignored, and Save stays disabled \
            with no way for the user to tell why ticking it changed nothing. Scanned body: \
            \(body)
            """)
    }

    /// The anchor is `draftSnippet` rather than `save()`: the editor's
    /// "Test" button (Snippet-Probelauf, Task 4) rehearses the same draft
    /// Save writes, so the `Snippet(...)` construction moved out of `save()`
    /// into one property both read. That move is exactly why the waiver has
    /// to be checked here — a rehearsal built without it would be refused
    /// where the saved snippet is not, or the other way round.
    @Test("the draft the editor saves and tests carries the waiver")
    func theDraftCarriesTheWaiver() throws {
        let source = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        let body = try Self.functionBody(
            containing: "private var draftSnippet: Snippet {", in: source)
        #expect(body.contains("skipsPlaceholderPlacementCheck: skipsPlacementCheck"), """
            draftSnippet must hand skipsPlacementCheck to Snippet's initializer -- the field \
            defaults to false there, so a forgotten argument compiles and silently discards \
            the setting on every save AND on every test run. Scanned body: \(body)
            """)
    }

    /// One synthetic editor with all three anchors removed, scanned by all
    /// three checks: each must react, so none of them is passing on
    /// something a neighbouring line happens to contain.
    @Test("the waiver scans react to a waiver that was dropped from the editor")
    func waiverScansReactToARemovedWaiver() throws {
        let withoutWaiver = """
            private var variablesSection: some View {
                VStack {
                    Toggle("Remember last value", isOn: draft.remembersLastValue)
                    if let variablesError {
                        Text(variablesError)
                    }
                }
            }
            private var variablesError: String? {
                guard let problem = SnippetVariableSubstitution.firstDeclarationProblem(
                    command: command, variables: variables) else { return nil }
                return snippetVariableProblemText(for: problem)
            }
            private var draftSnippet: Snippet {
                Snippet(
                    id: draftID, name: name, command: command,
                    tags: tags, variables: variables)
            }
            """
        let section = try Self.functionBody(
            containing: "private var variablesSection: some View {", in: withoutWaiver)
        #expect(!section.contains("isOn: $skipsPlacementCheck"))
        #expect(!section.contains("snippets.editor.skipPlacementCheck"))

        let error = try Self.functionBody(
            containing: "private var variablesError: String? {", in: withoutWaiver)
        #expect(!error.contains("skipsPlacementCheck: skipsPlacementCheck"))

        let draft = try Self.functionBody(
            containing: "private var draftSnippet: Snippet {", in: withoutWaiver)
        #expect(!draft.contains("skipsPlaceholderPlacementCheck: skipsPlacementCheck"))
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
