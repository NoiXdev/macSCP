import Foundation
import Testing
import macSCPCore
@testable import MacSCPAppKit

/// Placeholder help in the snippet editor
/// (`docs/superpowers/specs/2026-08-30-snippet-editor-interaction-design.md`,
/// section 2): the hint about a `{{NAME}}` nothing declares, the way to put
/// a declared name into the command without typing it, and the completion
/// that opens at `{{`.
///
/// All three rest on functions that decide something without a view, and
/// that is what this suite covers: which names either entrance offers for a
/// given set of declarations, and which `{{NAME}}` in a command text no
/// declaration carries. What it cannot cover is whether the list at the
/// `NSTextView` feels right while typing — named as unprovable in the
/// design itself.
///
/// **Nothing here is about sending.** The hint is an editor display;
/// `SnippetVariableSubstitution` decides what may be sent, and an
/// undeclared placeholder was sendable before this suite existed and stays
/// sendable. `SnippetCommandEditorGuardTests` holds that line from the
/// other side, by counting the `Problem` cases.
@Suite("Snippet placeholder help")
struct SnippetPlaceholderHelpTests {
    private static func variable(
        _ name: String, placement: SnippetVariable.Placement = .placeholder
    ) -> SnippetVariable {
        SnippetVariable(
            name: name, prompt: "", kind: .freeText, placement: placement,
            defaultValue: "", remembersLastValue: false)
    }

    // MARK: - What belongs in the command as {{NAME}}

    @Test func aPlaceholderDeclarationBelongsInTheCommand() {
        #expect(snippetBelongsInCommandAsPlaceholder(Self.variable("TARGET")))
    }

    /// The rule the design states outright: an environment variable is
    /// prepended as an assignment, so offering it as `{{NAME}}` would
    /// produce the exact opposite of what its placement says.
    @Test func anEnvironmentDeclarationDoesNotBelongInTheCommand() {
        #expect(!snippetBelongsInCommandAsPlaceholder(
            Self.variable("DB", placement: .environment)))
    }

    /// A name that is not a shell identifier is not offered either:
    /// `SnippetVariableSubstitution.resolve` skips such a declaration, so
    /// inserting its `{{NAME}}` would put text in the command that nothing
    /// ever fills in.
    @Test func aNameNothingCouldResolveIsNotOffered() {
        #expect(!snippetBelongsInCommandAsPlaceholder(Self.variable("no dash")))
    }

    @Test func theOfferedNamesKeepDeclarationOrderAndDropRepeats() {
        let names = snippetInsertablePlaceholderNames(in: [
            Self.variable("TARGET"), Self.variable("SOURCE"), Self.variable("TARGET"),
        ])
        #expect(names == ["TARGET", "SOURCE"])
    }

    /// The proof for the row entrance and the completion entrance at once:
    /// both read this one list, so an environment declaration is missing
    /// from both by construction rather than by two agreeing filters.
    @Test func anEnvironmentDeclarationIsMissingFromTheOfferedNames() {
        let names = snippetInsertablePlaceholderNames(in: [
            Self.variable("HOST"), Self.variable("DB", placement: .environment),
        ])
        #expect(names == ["HOST"])
    }

    // MARK: - Inserting from the variable row

    @Test func insertingIntoAnEmptyCommandWritesJustThePlaceholder() {
        #expect(snippetCommandInsertingPlaceholder("TARGET", into: "") == "{{TARGET}}")
    }

    @Test func insertingBehindAWordSeparatesItWithOneSpace() {
        #expect(snippetCommandInsertingPlaceholder("TARGET", into: "scp")
            == "scp {{TARGET}}")
    }

    @Test func insertingBehindWhitespaceAddsNoSecondSpace() {
        #expect(snippetCommandInsertingPlaceholder("TARGET", into: "scp ")
            == "scp {{TARGET}}")
    }

    /// A command may span lines, and a line break is whitespace that
    /// separates already — turning it into "line break plus space" would
    /// indent the new line for no reason.
    @Test func insertingBehindALineBreakKeepsTheLineBreak() {
        #expect(snippetCommandInsertingPlaceholder("TARGET", into: "cd /tmp\n")
            == "cd /tmp\n{{TARGET}}")
    }

    // MARK: - Completion at {{

    @Test func completionOpensOnTheOpeningBracesWithEveryOfferedName() {
        let entries = snippetPlaceholderCompletions(
            in: [Self.variable("HOST"), Self.variable("PORT")],
            textBeforePartialWord: "ssh {{", partialWord: "", textAfterPartialWord: "")
        #expect(entries == ["HOST}}", "PORT}}"])
    }

    /// The entry is what gets inserted, closing braces included: completing
    /// leaves a finished `{{HOST}}` rather than a half-open one the user
    /// has to close by hand.
    @Test func anEntryCarriesTheClosingBracesItWouldNeed() {
        let entries = snippetPlaceholderCompletions(
            in: [Self.variable("HOST")],
            textBeforePartialWord: "ssh {{", partialWord: "H", textAfterPartialWord: "")
        #expect(entries == ["HOST}}"])
    }

    /// And it carries only the braces that are missing — a placeholder
    /// being edited in place is already closed, and a second pair would
    /// leave `{{HOST}}}}` behind.
    @Test func anEntryAddsNoBraceTheTextAlreadyHas() {
        let variables = [Self.variable("HOST")]
        #expect(snippetPlaceholderCompletions(
            in: variables, textBeforePartialWord: "ssh {{", partialWord: "H",
            textAfterPartialWord: "}}") == ["HOST"])
        #expect(snippetPlaceholderCompletions(
            in: variables, textBeforePartialWord: "ssh {{", partialWord: "H",
            textAfterPartialWord: "}") == ["HOST}"])
    }

    /// Typed in lower case, offered in the spelling that was declared —
    /// otherwise the completion would insert a name no declaration
    /// carries.
    @Test func aPartialWordMatchesWithoutRegardToCase() {
        let entries = snippetPlaceholderCompletions(
            in: [Self.variable("HOST")],
            textBeforePartialWord: "ssh {{", partialWord: "ho", textAfterPartialWord: "")
        #expect(entries == ["HOST}}"])
    }

    @Test func aPartialWordThatMatchesNothingOffersNothing() {
        let entries = snippetPlaceholderCompletions(
            in: [Self.variable("HOST")],
            textBeforePartialWord: "ssh {{", partialWord: "zz", textAfterPartialWord: "")
        #expect(entries.isEmpty)
    }

    /// The trigger is the opening braces and nothing else: an ordinary word
    /// in the command must not turn into a variable list.
    @Test func nothingIsOfferedAwayFromTheOpeningBraces() {
        let variables = [Self.variable("HOST")]
        #expect(snippetPlaceholderCompletions(
            in: variables, textBeforePartialWord: "ssh ", partialWord: "ho",
            textAfterPartialWord: "").isEmpty)
        #expect(snippetPlaceholderCompletions(
            in: variables, textBeforePartialWord: "ssh {", partialWord: "",
            textAfterPartialWord: "").isEmpty)
    }

    /// The second half of the design's rule, and the one that is easy to
    /// get wrong: an environment variable is not offered as `{{DB}}`, and
    /// it is not offered as `$DB` either. In a single-line assignment
    /// prefix the shell expands `$DB` before the assignment takes effect,
    /// so a completion that inserted it would be silently wrong — and
    /// "offer it depending on line count" is a rule that changes while you
    /// type. Whoever writes `$DB` by hand sees the consequence in the dry
    /// run.
    @Test func anEnvironmentDeclarationIsOfferedInNeitherSpelling() {
        let entries = snippetPlaceholderCompletions(
            in: [Self.variable("DB", placement: .environment)],
            textBeforePartialWord: "ssh {{", partialWord: "", textAfterPartialWord: "")
        #expect(entries.isEmpty)
        #expect(!entries.contains { $0.contains("$") })
        // And there is no second entrance that would spell it that way:
        // the row's insert button writes `snippetCommandInsertingPlaceholder`
        // for a name this list never produced.
        #expect(snippetInsertablePlaceholderNames(
            in: [Self.variable("DB", placement: .environment)]).isEmpty)
    }

    // MARK: - The hint about a placeholder nothing declares

    @Test func aDeclaredPlaceholderIsNotReportedAsUndeclared() {
        #expect(snippetUndeclaredPlaceholders(
            in: "scp {{SOURCE}} {{TARGET}}",
            variables: [Self.variable("SOURCE"), Self.variable("TARGET")]).isEmpty)
    }

    @Test func aPlaceholderNoDeclarationCarriesIsReported() {
        #expect(snippetUndeclaredPlaceholders(in: "echo {{DB}}", variables: []) == ["DB"])
    }

    @Test func theSameUndeclaredNameIsReportedOnce() {
        #expect(snippetUndeclaredPlaceholders(in: "echo {{DB}} {{DB}}", variables: [])
            == ["DB"])
    }

    @Test func severalUndeclaredNamesAreReportedInTheOrderTheyAppear() {
        #expect(snippetUndeclaredPlaceholders(in: "cp {{TO}} {{FROM}}", variables: [])
            == ["TO", "FROM"])
    }

    /// A declaration whose placement is the environment still counts as a
    /// declaration here: the sentence says the name is not declared, and
    /// for that name it would be false.
    @Test func anEnvironmentDeclarationCountsAsADeclaration() {
        #expect(snippetUndeclaredPlaceholders(
            in: "echo {{DB}}",
            variables: [Self.variable("DB", placement: .environment)]).isEmpty)
    }

    /// Only what could ever be filled in is reported. `{{ DB }}` and
    /// `{{a-b}}` are not names any declaration could carry
    /// (`SnippetVariable.isValidName`), so `resolve` would leave them
    /// standing whatever was declared — reporting them as "not declared"
    /// would promise that declaring them helps.
    @Test func aBraceRunThatIsNotANameIsNotAPlaceholder() {
        #expect(snippetUndeclaredPlaceholders(in: "echo {{ DB }}", variables: []).isEmpty)
        #expect(snippetUndeclaredPlaceholders(in: "echo {{a-b}}", variables: []).isEmpty)
        #expect(snippetUndeclaredPlaceholders(in: "echo {{}}", variables: []).isEmpty)
    }

    /// The same spans `SnippetVariableSubstitution.occurrences` would find:
    /// a third opening brace is a literal character before the placeholder,
    /// and a third closing brace is one after it.
    @Test func anExtraBraceOnEitherSideLeavesThePlaceholderIntact() {
        #expect(snippetUndeclaredPlaceholders(in: "echo {{{DB}}", variables: []) == ["DB"])
        #expect(snippetUndeclaredPlaceholders(in: "echo {{DB}}}}", variables: []) == ["DB"])
    }

    @Test func twoPlaceholdersBackToBackAreBothSeen() {
        #expect(snippetUndeclaredPlaceholders(in: "echo {{A}}{{B}}", variables: [])
            == ["A", "B"])
    }

    @Test func aCommandWithoutPlaceholdersProducesNoHint() {
        #expect(snippetUndeclaredPlaceholderHint(command: "ls -la", variables: []) == nil)
    }

    @Test func theHintNamesEveryPlaceholderNothingDeclares() {
        let hint = snippetUndeclaredPlaceholderHint(
            command: "cp {{TO}} {{FROM}}", variables: [Self.variable("TO")])
        #expect(hint?.contains("FROM") == true)
        #expect(hint?.contains("TO") == false)
    }

    /// The hint is a display, not a gate. A command with an undeclared
    /// placeholder still has no declaration fault, so Save stays reachable
    /// and the send path is untouched.
    @Test func anUndeclaredPlaceholderIsNotADeclarationFault() {
        let fault = snippetVariablesFault(
            command: "echo {{DB}} {{USED}}", variables: [Self.variable("USED")],
            skipsPlacementCheck: false)
        #expect(fault == nil)
        #expect(snippetUndeclaredPlaceholderHint(
            command: "echo {{DB}} {{USED}}", variables: [Self.variable("USED")]) != nil)
    }
}
