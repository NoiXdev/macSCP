import Foundation
import Testing

/// Guards ten properties of the snippet editor — `SnippetsSheet.swift`
/// and the presentation functions it calls: five in
/// `SnippetCommandEditor.swift`'s own wiring, raised by the whole-branch
/// review of the snippet syntax-highlighting feature, plus five in
/// `SnippetEditorView` itself (variable-declaration Save-gating, Task 5,
/// the per-snippet placement-check waiver, folding the variable rows, the
/// two entrances that put a declared name into the command, and the hint
/// about a placeholder no declaration carries).
/// None of the ten are provable any other way in this project (no test here
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
///    `isSaveDisabled` must also test `variablesFault != nil`, and
///    `snippetVariablesFault` must actually run `SnippetVariable
///    .isValidName`, a duplicate-name check and `SnippetVariableSubstitution
///    .firstDeclarationProblem` — losing any one would let Save write a
///    snippet with an invalid, duplicate, unused or mis-quoted declaration.
///    Separately, `variablesSection` must render `variablesFault` as its own
///    `Text` whenever it is non-nil: the brief is explicit that a greyed-out
///    Save button must not be the only signal, because a user who cannot
///    tell why does not experiment, they give up.
/// 7. **The placement-check waiver is offered, consulted and stored.**
///    `Snippet.skipsPlaceholderPlacementCheck` is the one per-snippet
///    setting with no other surface in the app: `variablesSection` must
///    render a control bound to it under its localized key, the editor's
///    `variablesFault` must hand it to `snippetVariablesFault` and that
///    function must hand it on to `firstDeclarationProblem`, and `save()`
///    must write it onto the `Snippet`. Losing the first makes it
///    unreachable, either half of the second makes it decoration, and the
///    third — the quiet one — compiles, because `Snippet`'s initializer
///    defaults the field to `false`.
/// 8. **The variable rows fold, and only where folding is possible.**
///    `SnippetVariableFolding` decides all of it and is covered without a
///    view by `SnippetVariableFoldingTests` — but a value nothing consults
///    would leave that suite green over an editor that folds nothing. So:
///    `variablesSection` must gate each bulk action on the matching
///    `offers…` question rather than drawing it always, the add button must
///    `open` the row it just created, and `variableRow` must consult
///    `isExpanded` and `canCollapse`. Losing the first draws a control that
///    does nothing, the second adds a row nobody can type into, and the
///    third — the one the design turns on — would let a declaration with a
///    problem be folded away behind a marker that says something is wrong
///    without saying what.
/// 9. **Both ways into the command ask one question.** A declared name
///    reaches the command from the variable row's insert control and from
///    the completion list at the opening braces, and both must gate on
///    `snippetBelongsInCommandAsPlaceholder`. An environment declaration
///    offered by either would produce the exact opposite of what its
///    placement says — its value is prepended as an assignment, so the
///    placeholder would be text nothing fills in. The sheet must also hand
///    the editor its declarations, or the list fails as silence.
/// 10. **The undeclared hint is a display and stays one.**
///    `variablesSection` must show it and `undeclaredPlaceholderHint` must
///    come from `snippetUndeclaredPlaceholderHint` — but `isSaveDisabled`
///    must NOT consult it, and `SnippetVariableSubstitution.Problem` must
///    still carry six cases. An undeclared `{{NAME}}` was savable and
///    sendable before the hint existed and stays so; a check that refused
///    it would be a behaviour change at the one gate this project treats
///    as security-critical.
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
    /// Where the declaration checks live now that the editor needs both
    /// halves of their answer — the sentence AND which row it is about
    /// (`SnippetVariablesFault`). They moved out of the view so they can be
    /// tested directly; the scans below moved with them rather than being
    /// dropped.
    private static let presentationSourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SnippetsPresentation.swift")
    /// Core's own file, read by exactly one check below: the one that
    /// counts the verdicts and so proves the placeholder hint did not
    /// become one.
    private static let substitutionSourceFile = repoRoot
        .appendingPathComponent("Sources/macSCPCore/Terminal/SnippetVariableSubstitution.swift")

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

    /// Re-anchored when the editor gained its `variables:` argument for the
    /// completion list: the call no longer fits one line, so a scan for the
    /// whole call as one string would have gone from "the label is wired"
    /// to "this exact formatting". It now reads the command row's own
    /// closure and asks the two things that actually matter inside it —
    /// that the editor is built there at all, and that the argument it gets
    /// is the row's own `commandLabel` local.
    @Test func sheetPassesTheSameLocalizedStringTheRowLabelUses() throws {
        let source = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        #expect(source.contains("FormRow(label: commandLabel)"), """
            Expected the command row to still be built as `FormRow(label: commandLabel)` -- if \
            this changed, the assertion below (that the editor gets the SAME `commandLabel`) \
            no longer proves anything.
            """)
        let row = try Self.functionBody(
            containing: "FormRow(label: commandLabel) {", in: source)
        #expect(row.contains("SnippetCommandEditor("), """
            Sanity check: the command row must still build the editor, or the argument check \
            below would pass for the wrong reason. Scanned row: \(row)
            """)
        #expect(row.contains("accessibilityLabel: commandLabel"), """
            SnippetCommandEditor must be constructed with `accessibilityLabel: commandLabel` \
            -- the exact same local the row's own (VoiceOver-hidden) label uses -- so the two \
            can never drift into two different wordings for the same field. Scanned row: \(row)
            """)
    }

    @Test func scannerFlagsAMissingAccessibilityLabelArgument() throws {
        let source = """
            FormRow(label: commandLabel) {
                SnippetCommandEditor(text: $command)
                    .frame(height: 24)
            }
            """
        let row = try Self.functionBody(
            containing: "FormRow(label: commandLabel) {", in: source)
        #expect(row.contains("SnippetCommandEditor("))
        #expect(!row.contains("accessibilityLabel: commandLabel"),
            "the scanner must see that the pre-fix call site (no accessibilityLabel argument) does not match")
    }

    // MARK: - Finding 6: variable declarations gate Save, and say why (Task 5)

    @Test("isSaveDisabled also gates on the variables fault")
    func isSaveDisabledGatesOnVariablesFault() throws {
        let source = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        let body = try Self.functionBody(
            containing: "private var isSaveDisabled: Bool {", in: source)
        #expect(body.contains("variablesFault != nil"), """
            isSaveDisabled must also test variablesFault != nil -- Task 5 requires Save to \
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
        #expect(!body.contains("variablesFault != nil"))
    }

    /// `SnippetVariable.isValidName` has no caller before this feature (see
    /// `SnippetVariable`'s own doc comment) -- this scan is what keeps that
    /// true going forward, alongside the duplicate-name check and
    /// `firstDeclarationProblem`, which together are the two things Step 2
    /// of the brief names explicitly.
    @Test("the declaration fault runs all three checks")
    func theDeclarationFaultRunsAllThreeChecks() throws {
        let source = try String(contentsOf: Self.presentationSourceFile, encoding: .utf8)
        let body = try Self.functionBody(containing: "func snippetVariablesFault(", in: source)
        #expect(body.contains("SnippetVariable.isValidName("), """
            snippetVariablesFault must call SnippetVariable.isValidName -- an invalid variable \
            name (Step 2 of the brief) would otherwise reach Snippet.save unchecked. Scanned \
            body: \(body)
            """)
        // Anchored on what the check REPORTS rather than on how it counts:
        // the catalogue key is the outcome, and the same idiom the waiver
        // scan below uses for its own control.
        #expect(body.contains("snippets.variables.error.duplicateName"), """
            snippetVariablesFault must detect two variables sharing a name (Step 2 of the \
            brief). Scanned body: \(body)
            """)
        #expect(body.contains("SnippetVariableSubstitution.firstDeclarationProblem("), """
            snippetVariablesFault must call SnippetVariableSubstitution \
            .firstDeclarationProblem -- an unused placeholder or one sitting inside quotes \
            (Step 2 of the brief) would otherwise reach Snippet.save unchecked. Scanned body: \
            \(body)
            """)
    }

    /// And the editor must ASK it. The checks moved into a function that is
    /// tested on its own, which is worth nothing to a sheet that stopped
    /// calling it.
    @Test("the editor asks for the declaration fault")
    func theEditorAsksForTheDeclarationFault() throws {
        let source = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        let body = try Self.functionBody(
            containing: "private var variablesFault: SnippetVariablesFault? {", in: source)
        #expect(body.contains("snippetVariablesFault("), """
            the editor's variablesFault must call snippetVariablesFault -- it is the one place \
            the three declaration checks run, and Save is gated on its answer. Scanned body: \
            \(body)
            """)
    }

    @Test("the declaration-fault scan reacts to a check silently dropped")
    func theDeclarationFaultScanReactsToADroppedCheck() throws {
        let missingIsValidName = """
            func snippetVariablesFault(
                command: String, variables: [SnippetVariable], skipsPlacementCheck: Bool
            ) -> SnippetVariablesFault? {
                var rowsByName: [String: Set<Int>] = [:]
                for (index, variable) in variables.enumerated() {
                    rowsByName[variable.name, default: []].insert(index)
                }
                if rowsByName.values.contains(where: { $0.count > 1 }) {
                    return SnippetVariablesFault(
                        message: L10n.string("snippets.variables.error.duplicateName", ""),
                        declarations: [])
                }
                guard let problem = SnippetVariableSubstitution.firstDeclarationProblem(
                    command: command, variables: variables) else { return nil }
                return SnippetVariablesFault(message: "problem", declarations: [])
            }
            """
        let body = try Self.functionBody(
            containing: "func snippetVariablesFault(", in: missingIsValidName)
        #expect(!body.contains("SnippetVariable.isValidName("))
    }

    /// A greyed-out Save button alone does not say why (brief, Step 2) --
    /// this proves the reason is rendered as its own `Text`, not only used
    /// to compute `isSaveDisabled`.
    @Test("the variables section renders variablesFault, not only uses it to disable Save")
    func variablesSectionRendersTheError() throws {
        let source = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        let body = try Self.functionBody(
            containing: "private var variablesSection: some View {", in: source)
        #expect(body.contains("if let variablesFault {"), """
            variablesSection must show variablesFault's message as its own Text whenever it is \
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
        #expect(!body.contains("if let variablesFault {"))
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

    /// Both halves of the hand-over, because the checks now sit one call
    /// away from the checkbox: the editor has to pass the flag on, and the
    /// function has to pass it further. Either half missing leaves the
    /// checkbox drawn, stored and ignored.
    @Test("the waiver reaches the check rather than being checked regardless")
    func theWaiverReachesTheCheck() throws {
        let sheet = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        let editorBody = try Self.functionBody(
            containing: "private var variablesFault: SnippetVariablesFault? {", in: sheet)
        #expect(editorBody.contains("skipsPlacementCheck: skipsPlacementCheck"), """
            the editor's variablesFault must pass skipsPlacementCheck to snippetVariablesFault \
            -- otherwise the checkbox is drawn, stored and ignored, and Save stays disabled \
            with no way for the user to tell why ticking it changed nothing. Scanned body: \
            \(editorBody)
            """)

        let presentation = try String(contentsOf: Self.presentationSourceFile, encoding: .utf8)
        let faultBody = try Self.functionBody(
            containing: "func snippetVariablesFault(", in: presentation)
        #expect(faultBody.contains("skipsPlacementCheck: skipsPlacementCheck"), """
            snippetVariablesFault must pass skipsPlacementCheck on to \
            firstDeclarationProblem -- receiving the flag and then checking regardless is the \
            same silence as never receiving it. Scanned body: \(faultBody)
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
                    if let variablesFault {
                        Text(variablesFault.message)
                    }
                }
            }
            private var variablesFault: SnippetVariablesFault? {
                snippetVariablesFault(command: command, variables: variables)
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
            containing: "private var variablesFault: SnippetVariablesFault? {", in: withoutWaiver)
        #expect(!error.contains("skipsPlacementCheck: skipsPlacementCheck"))

        let draft = try Self.functionBody(
            containing: "private var draftSnippet: Snippet {", in: withoutWaiver)
        #expect(!draft.contains("skipsPlaceholderPlacementCheck: skipsPlacementCheck"))
    }

    // MARK: - Finding 8: the variable rows fold, and only where possible

    /// Each bulk action must sit behind its own `offers…` question. A
    /// `Button` drawn unconditionally is the failure the design names by
    /// name: a control that is present when it can do nothing.
    @Test("the variables section offers each bulk fold action only when it is possible")
    func variablesSectionGatesTheBulkFoldActions() throws {
        let source = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        let body = try Self.functionBody(
            containing: "private var variablesSection: some View {", in: source)
        #expect(body.contains("if folding.offersExpandAll(rows) {"), """
            variablesSection must draw "expand all" only when SnippetVariableFolding says it \
            would do something -- the design asks for absent, not greyed out. Scanned body: \
            \(body)
            """)
        #expect(body.contains("if folding.offersCollapseAll(rows) {"), """
            variablesSection must draw "collapse all" only when SnippetVariableFolding says it \
            would do something -- with every open row faulty, and therefore unfoldable, the \
            button would do nothing at all. Scanned body: \(body)
            """)
        #expect(body.contains("folding.open("), """
            the add button must open the row it just created -- a row that is added closed is \
            a row nobody can type into. Scanned body: \(body)
            """)
    }

    /// The rule the whole design turns on, at the one place it is applied:
    /// the row asks whether it is expanded AND whether it may fold at all.
    /// Dropping the second question is the regression that matters — it
    /// hides a declaration with a problem behind a marker that says
    /// something is wrong without saying what.
    @Test("a variable row consults the folding value for both of its questions")
    func variableRowConsultsTheFolding() throws {
        let source = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        let body = try Self.functionBody(containing: "private func variableRow(", in: source)
        #expect(body.contains("folding.isExpanded(row)"), """
            variableRow must ask the folding value whether this row is open -- otherwise the \
            row draws its six fields whatever the fold state says. Scanned body: \(body)
            """)
        #expect(body.contains("folding.canCollapse(row)"), """
            variableRow must ask the folding value whether this row may fold at all -- \
            without it a declaration with a problem can be closed, and a closed row with an \
            error marker says that something is wrong and not what. Scanned body: \(body)
            """)
    }

    /// One synthetic section and one synthetic row, both reverted to the
    /// shape they had before folding: every check above must react.
    @Test("the folding scans react to an editor that folds nothing")
    func foldingScansReactToAnEditorThatFoldsNothing() throws {
        let unfolded = """
            private var variablesSection: some View {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Variables")
                        Spacer()
                        Button { variableDrafts.append(VariableDraft()) } label: {
                            Label("Add variable", systemImage: "plus")
                        }
                    }
                    ForEach($variableDrafts) { draft in
                        variableRow(draft) {}
                    }
                }
            }
            private func variableRow(
                _ draft: Binding<VariableDraft>, onRemove: @escaping () -> Void
            ) -> some View {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: draft.name)
                }
            }
            """
        let section = try Self.functionBody(
            containing: "private var variablesSection: some View {", in: unfolded)
        #expect(!section.contains("if folding.offersExpandAll(rows) {"))
        #expect(!section.contains("if folding.offersCollapseAll(rows) {"))
        #expect(!section.contains("folding.open("))

        let row = try Self.functionBody(containing: "private func variableRow(", in: unfolded)
        #expect(!row.contains("folding.isExpanded(row)"))
        #expect(!row.contains("folding.canCollapse(row)"))
    }

    // MARK: - Finding 9: both entrances into the command ask the same question

    /// The variable row's way into the command. Two positive checks,
    /// because either half alone is useless: a control that inserts without
    /// asking `snippetBelongsInCommandAsPlaceholder` would offer an
    /// environment declaration a `{{NAME}}` its placement says it must not
    /// have, and a gate with nothing behind it is a row that offers
    /// nothing.
    @Test("the variable row offers a way into the command, only where one belongs")
    func variableRowOffersTheInsertion() throws {
        let source = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        let body = try Self.functionBody(containing: "private func variableRow(", in: source)
        #expect(body.contains("snippetBelongsInCommandAsPlaceholder("), """
            variableRow must gate its insert control on \
            snippetBelongsInCommandAsPlaceholder -- it is the one rule about what belongs in \
            the command as a placeholder, and an environment declaration inserted that way \
            produces the exact opposite of what its placement says. Scanned body: \(body)
            """)
        #expect(body.contains("snippetCommandInsertingPlaceholder("), """
            variableRow must actually write the placeholder through \
            snippetCommandInsertingPlaceholder -- the gate above is worth nothing without a \
            control behind it. Scanned body: \(body)
            """)
    }

    /// The completion entrance, in two places: the sheet has to hand the
    /// declarations down, and the coordinator has to ask the same rule
    /// about them. Handing them down and then offering something else is
    /// the failure this pair catches.
    @Test("the completion list is built from the declarations, by the same rule")
    func theCompletionListAsksTheSameRule() throws {
        let sheet = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        let row = try Self.functionBody(
            containing: "FormRow(label: commandLabel) {", in: sheet)
        #expect(row.contains("variables: variables"), """
            the command row must hand the editor the current declarations -- without them the \
            completion list has nothing to offer, and it would fail as silence rather than as \
            an error. Scanned row: \(row)
            """)

        let editor = try String(contentsOf: Self.editorSourceFile, encoding: .utf8)
        let completions = try Self.functionBody(
            containing: "forPartialWordRange charRange: NSRange", in: editor)
        #expect(completions.contains("snippetPlaceholderCompletions("), """
            the coordinator's completion callback must answer with \
            snippetPlaceholderCompletions -- a second list built here would be a second \
            answer to "what belongs in the command", and the half that drifted would be the \
            one no test covers. Scanned body: \(completions)
            """)
    }

    @Test("the entrance scans react to controls that ask nothing")
    func entranceScansReactToUngatedControls() throws {
        let ungated = """
            private func variableRow(
                _ draft: Binding<VariableDraft>, row: SnippetVariableFoldRow,
                onRemove: @escaping () -> Void
            ) -> some View {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: draft.name)
                    Button { command += draft.wrappedValue.name } label: {
                        Image(systemName: "curlybraces")
                    }
                }
            }
            """
        let row = try Self.functionBody(containing: "private func variableRow(", in: ungated)
        #expect(!row.contains("snippetBelongsInCommandAsPlaceholder("))
        #expect(!row.contains("snippetCommandInsertingPlaceholder("))

        let spellChecked = """
            func textView(
                _ textView: NSTextView, completions words: [String],
                forPartialWordRange charRange: NSRange,
                indexOfSelectedItem index: UnsafeMutablePointer<Int>?
            ) -> [String] {
                return words
            }
            """
        let completions = try Self.functionBody(
            containing: "forPartialWordRange charRange: NSRange", in: spellChecked)
        #expect(!completions.contains("snippetPlaceholderCompletions("))
    }

    // MARK: - Finding 10: the undeclared hint is a display, and stays one

    /// Shown, and computed by the one function that decides it.
    @Test("the variables section shows the hint about an undeclared placeholder")
    func variablesSectionShowsTheUndeclaredHint() throws {
        let source = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        let section = try Self.functionBody(
            containing: "private var variablesSection: some View {", in: source)
        #expect(section.contains("if let undeclaredPlaceholderHint {"), """
            variablesSection must render the hint about a `{{NAME}}` no declaration carries -- \
            it is the one signal that such a placeholder reaches the shell as the characters \
            it is, and without it the command goes on doing something other than what its \
            author believes. Scanned body: \(section)
            """)
        let hint = try Self.functionBody(
            containing: "private var undeclaredPlaceholderHint: String? {", in: source)
        #expect(hint.contains("snippetUndeclaredPlaceholderHint("), """
            the editor's hint must come from snippetUndeclaredPlaceholderHint -- it is where \
            the rule is tested without a view. Scanned body: \(hint)
            """)
    }

    /// The hint must not become a gate. A NEGATIVE check, so it is paired
    /// with the positive one beside it: `isSaveDisabled` still has to name
    /// the fault it does gate on, which is what keeps this scan from going
    /// quiet over a property that was renamed or deleted.
    @Test("the hint does not reach the Save gate")
    func theHintDoesNotGateSave() throws {
        let source = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        let body = try Self.functionBody(
            containing: "private var isSaveDisabled: Bool {", in: source)
        #expect(body.contains("variablesFault != nil"), """
            Sanity check: isSaveDisabled must still gate on the declaration fault, or the \
            check below would pass over a gate that had been rewritten entirely.
            """)
        #expect(!body.contains("undeclaredPlaceholder"), """
            isSaveDisabled must NOT consult the undeclared-placeholder hint. An undeclared \
            `{{NAME}}` was savable and sendable before the hint existed and stays so -- it \
            just goes out literally. A check that blocked it would be a behaviour change \
            wearing a display's clothes. Scanned body: \(body)
            """)
    }

    /// And no new `Problem` case arrived to carry it. The design is
    /// explicit that the hint is an editor display rather than a seventh
    /// case: `SnippetVariableSubstitution` decides what may be sent, and
    /// nothing about that changed.
    ///
    /// Six, counted in the pass that writes this: `invalidName`,
    /// `unanalyzableContext`, `unusedPlaceholder`, `placeholderInsideQuotes`,
    /// `placeholderNotInArgumentPosition`,
    /// `placeholderIsReparsedByItsCommand`.
    @Test("the substitution's verdict still carries six cases")
    func theSubstitutionProblemStillCarriesSixCases() throws {
        let source = try String(contentsOf: Self.substitutionSourceFile, encoding: .utf8)
        let body = try Self.functionBody(containing: "public enum Problem", in: source)
        #expect(Self.caseCount(in: body) == 6, """
            SnippetVariableSubstitution.Problem must still carry exactly six cases. The hint \
            about an undeclared placeholder is an EDITOR DISPLAY, not a seventh verdict: a \
            check that refused to send such a snippet would be a behaviour change at the one \
            gate this project treats as security-critical. Scanned body: \(body)
            """)
    }

    @Test("the case count reacts to a seventh verdict")
    func theCaseCountReactsToASeventhVerdict() throws {
        let widened = """
            public enum Problem: Equatable, Sendable {
                case invalidName(name: String)
                case unanalyzableContext(kind: Context)
                case unusedPlaceholder(name: String)
                case placeholderInsideQuotes(name: String)
                case placeholderNotInArgumentPosition(name: String)
                case placeholderIsReparsedByItsCommand(name: String)
                case undeclaredPlaceholder(name: String)
            }
            """
        let body = try Self.functionBody(containing: "public enum Problem", in: widened)
        #expect(Self.caseCount(in: body) == 7)
    }

    /// Lines whose own text starts a case. Doc comments start with `///`
    /// and so cannot be counted by accident.
    private static func caseCount(in body: String) -> Int {
        body.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("case ") }
            .count
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
