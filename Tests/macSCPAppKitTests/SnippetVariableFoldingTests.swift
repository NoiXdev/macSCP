import Foundation
import Testing
import macSCPCore
@testable import MacSCPAppKit

/// Folding the snippet editor's variable rows
/// (`docs/superpowers/specs/2026-08-30-snippet-editor-interaction-design.md`,
/// section 1).
///
/// A declaration row carries a name, a kind, a prompt, a placement, a
/// default value and the remember flag. At three declarations the form is
/// longer than the sheet, and the sheet is 460 pt wide — space exists only
/// downward, so the rows fold.
///
/// Everything the design decides is decidable without a view, and that is
/// what this suite covers: which rows are drawn open, which of them can be
/// closed at all, which of the two bulk actions is offered, and which
/// declaration the current fault is about. What it cannot cover is whether
/// the folded form actually fits the sheet — maintainer's eye, named as
/// unprovable in the design itself.
@Suite("Snippet variable folding")
struct SnippetVariableFoldingTests {
    private static func row(_ hasProblem: Bool = false) -> SnippetVariableFoldRow {
        SnippetVariableFoldRow(id: UUID(), hasProblem: hasProblem)
    }

    private static func variable(
        _ name: String, kind: SnippetVariable.Kind = .freeText,
        placement: SnippetVariable.Placement = .placeholder
    ) -> SnippetVariable {
        SnippetVariable(
            name: name, prompt: "", kind: kind, placement: placement,
            defaultValue: "", remembersLastValue: false)
    }

    // MARK: - What an editor opens with

    /// No state is remembered anywhere, so an editor that just opened draws
    /// every declaration it loaded closed.
    @Test func everyDeclarationTheEditorLoadedStartsClosed() {
        let folding = SnippetVariableFolding()
        let rows = [Self.row(), Self.row(), Self.row()]
        #expect(rows.allSatisfy { !folding.isExpanded($0) })
    }

    /// "Add variable" opens the row it just created — otherwise nobody can
    /// type into it.
    @Test func aNewlyAddedDeclarationStartsOpen() {
        var folding = SnippetVariableFolding()
        let added = Self.row()
        folding.open(added.id)
        #expect(folding.isExpanded(added))
    }

    @Test func openingOneRowLeavesTheOthersClosed() {
        var folding = SnippetVariableFolding()
        let opened = Self.row()
        let other = Self.row()
        folding.open(opened.id)
        #expect(folding.isExpanded(opened))
        #expect(!folding.isExpanded(other))
    }

    @Test func aRowClosesAgainWhenItIsToggledTwice() {
        var folding = SnippetVariableFolding()
        let subject = Self.row()
        folding.toggle(subject)
        #expect(folding.isExpanded(subject))
        folding.toggle(subject)
        #expect(!folding.isExpanded(subject))
    }

    // MARK: - A declaration with a problem stays open

    /// It is drawn open without anybody having opened it, and it offers no
    /// control that would close it. A closed row with an error marker says
    /// that something is wrong and not what, and one opens it anyway.
    @Test func aDeclarationWithAProblemIsOpenAndCannotBeClosed() {
        let folding = SnippetVariableFolding()
        let faulty = Self.row(true)
        #expect(folding.isExpanded(faulty))
        #expect(!folding.canCollapse(faulty))
    }

    /// The property the fold rule gives away for free: "collapse all"
    /// leaves the faulty ones open, so it doubles as "show me only the
    /// problems".
    ///
    /// The faulty row is deliberately never opened by hand here: had it
    /// been, it would stay open on that alone, and the test would pass over
    /// a fold rule that had forgotten about problems entirely.
    @Test func collapseAllLeavesTheFaultyOnesOpen() {
        var folding = SnippetVariableFolding()
        let faulty = Self.row(true)
        let sound = [Self.row(), Self.row()]
        folding.expandAll(sound)

        folding.collapseAll([faulty] + sound)

        #expect(folding.isExpanded(faulty))
        #expect(!folding.canCollapse(faulty))
        #expect(sound.allSatisfy { !folding.isExpanded($0) })
    }

    /// And they stay open once the problem is gone. "Collapse all" is most
    /// useful as a way to get at the faulty rows, so the row a user then
    /// types the fix into must not shut under the cursor the moment the fix
    /// lands.
    @Test func aRowCollapseAllLeftOpenStaysOpenOnceItsProblemIsGone() {
        var folding = SnippetVariableFolding()
        let identity = UUID()
        let faulty = SnippetVariableFoldRow(id: identity, hasProblem: true)
        folding.collapseAll([faulty])

        let fixed = SnippetVariableFoldRow(id: identity, hasProblem: false)
        #expect(folding.isExpanded(fixed))
    }

    // MARK: - Only what is possible is offered

    @Test func neitherBulkActionIsOfferedWithoutDeclarations() {
        let folding = SnippetVariableFolding()
        #expect(!folding.offersExpandAll([]))
        #expect(!folding.offersCollapseAll([]))
    }

    @Test func expandAllIsGoneOnceEverythingIsOpen() {
        var folding = SnippetVariableFolding()
        let rows = [Self.row(), Self.row()]
        #expect(folding.offersExpandAll(rows))
        folding.expandAll(rows)
        #expect(!folding.offersExpandAll(rows))
    }

    @Test func collapseAllIsGoneOnceEverythingIsClosed() {
        var folding = SnippetVariableFolding()
        let rows = [Self.row(), Self.row()]
        folding.expandAll(rows)
        #expect(folding.offersCollapseAll(rows))
        folding.collapseAll(rows)
        #expect(!folding.offersCollapseAll(rows))
    }

    /// The two rules meeting: a faulty row is open and cannot be closed, so
    /// offering "collapse all" over nothing but faulty rows would offer a
    /// button that does nothing.
    @Test func collapseAllIsNotOfferedWhenTheOnlyOpenRowsAreFaulty() {
        var folding = SnippetVariableFolding()
        let faulty = Self.row(true)
        let closed = Self.row()
        #expect(!folding.offersCollapseAll([faulty, closed]))
        folding.open(closed.id)
        #expect(folding.offersCollapseAll([faulty, closed]))
    }

    /// A faulty row is already open, so it is not something "expand all"
    /// could still open.
    @Test func expandAllIsNotOfferedForAFaultyRowAlone() {
        let folding = SnippetVariableFolding()
        #expect(!folding.offersExpandAll([Self.row(true)]))
    }

    // MARK: - Which declaration the fault is about

    @Test func soundDeclarationsHaveNoFault() {
        let fault = snippetVariablesFault(
            command: "scp {{SOURCE}} {{TARGET}}",
            variables: [Self.variable("SOURCE"), Self.variable("TARGET")],
            skipsPlacementCheck: false)
        #expect(fault == nil)
    }

    /// Every row with an unusable name, not just the first: the message
    /// names one reason, but the fold rule has to hold all of them open.
    @Test func anInvalidNameNamesEveryRowThatHasOne() {
        let fault = snippetVariablesFault(
            command: "echo {{OK}}",
            variables: [Self.variable("no dash"), Self.variable("OK"), Self.variable("2nd")],
            skipsPlacementCheck: false)
        #expect(fault?.declarations == [0, 2])
        #expect(fault?.message.isEmpty == false)
    }

    @Test func aDuplicateNameNamesBothRowsThatShareIt() {
        let fault = snippetVariablesFault(
            command: "echo {{SAME}} {{OTHER}}",
            variables: [Self.variable("SAME"), Self.variable("OTHER"), Self.variable("SAME")],
            skipsPlacementCheck: false)
        #expect(fault?.declarations == [0, 2])
    }

    @Test func anUnusedPlaceholderNamesItsOwnRow() {
        let fault = snippetVariablesFault(
            command: "echo {{USED}}",
            variables: [Self.variable("USED"), Self.variable("NEVER")],
            skipsPlacementCheck: false)
        #expect(fault?.declarations == [1])
        #expect(fault?.message == snippetVariableProblemText(
            for: .unusedPlaceholder(name: "NEVER")))
    }

    /// A command the survey refuses is a fault about the COMMAND, and no
    /// declaration is at fault for it — so every row stays foldable.
    @Test func aCommandNobodyCanSurveyPutsNoRowAtFault() {
        let fault = snippetVariablesFault(
            command: "echo $(date) {{NAME}}",
            variables: [Self.variable("NAME")],
            skipsPlacementCheck: false)
        #expect(fault?.declarations.isEmpty == true)
        #expect(fault?.message.isEmpty == false)
    }

    /// The waiver reaches the fault, the same way it reaches Save: with it
    /// ticked, a placeholder inside quotes stops being a fault at all.
    @Test func theWaiverSilencesThePlacementFault() {
        let quoted = #"echo "{{NAME}}""#
        let variables = [Self.variable("NAME")]
        #expect(snippetVariablesFault(
            command: quoted, variables: variables, skipsPlacementCheck: false) != nil)
        #expect(snippetVariablesFault(
            command: quoted, variables: variables, skipsPlacementCheck: true) == nil)
    }

    // MARK: - What the closed row shows

    /// Name, kind and placement: enough to find the right declaration
    /// without opening it, and placement belongs there because it decides
    /// whether the declaration belongs in the command as a placeholder at
    /// all.
    @Test func aClosedRowNamesItsDeclarationItsKindAndItsPlacement() {
        let summary = snippetCollapsedVariableSummary(for: Self.variable("TARGET"))
        #expect(summary.contains("TARGET"))
        #expect(summary.contains(
            L10n.string("snippets.variables.kind.freeText", "Free text")))
        #expect(summary.contains(L10n.string(
            "snippets.variables.placement.placeholder", "Placeholder in the command")))
    }

    @Test func theClosedRowReadsDifferentlyForEveryKindAndPlacement() {
        let summaries = [
            snippetCollapsedVariableSummary(for: Self.variable("V")),
            snippetCollapsedVariableSummary(
                for: Self.variable("V", kind: .selection(["a", "b"]))),
            snippetCollapsedVariableSummary(for: Self.variable("V", placement: .environment)),
            snippetCollapsedVariableSummary(
                for: Self.variable("V", kind: .selection(["a", "b"]), placement: .environment)),
        ]
        #expect(Set(summaries).count == summaries.count)
    }

    /// The allowed values of a choice are not in the closed line. The
    /// design names three things it carries, and a list that grows with the
    /// declaration would push the other two off the row.
    @Test func theClosedRowDoesNotSpellOutAChoicesValues() {
        let summary = snippetCollapsedVariableSummary(
            for: Self.variable("V", kind: .selection(["staging", "production"])))
        #expect(!summary.contains("production"))
    }
}
