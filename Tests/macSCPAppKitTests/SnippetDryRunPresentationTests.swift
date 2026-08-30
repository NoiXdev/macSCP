import Foundation
import SwiftUI
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// What the dry-run sheet is handed before any view exists: the sentence
/// naming the send form, the heading and reason for a refusal, the colour
/// one token kind gets, and the values a variable prompt opens with.
///
/// Nothing here renders `SnippetDryRunSheet` — no test in this project
/// renders a SwiftUI view — so what is proved is that the values the sheet
/// is given say the right thing, and that a substituted value stops at the
/// screen.
///
/// **The promise about a substituted value covers this suite's own
/// output**, the way `SnippetDryRunTests` states it in Core: the value
/// stands in `typedValue`, every assertion about it is made on a `Bool`
/// computed beforehand, and the literal never appears inside an
/// expectation — `#expect` prints the source text of the expression it
/// checks alongside the runtime values, so a value written into an
/// expectation would be printed by a failure.
@Suite("Snippet dry run presentation")
struct SnippetDryRunPresentationTests {
    /// Stands for something a person typed into a placeholder. Held in a
    /// constant so no expectation, and therefore no failure message, ever
    /// spells it.
    private static let typedValue = "s3cr3t-in-the-prompt"

    private func placeholder(_ name: String, defaultValue: String = "") -> SnippetVariable {
        SnippetVariable(
            name: name, prompt: name, kind: .freeText, placement: .placeholder,
            defaultValue: defaultValue, remembersLastValue: false)
    }

    // MARK: - The send form, in four words

    @Test func eachSendFormGetsItsOwnSentence() {
        let sentences = [
            snippetSendFormText(for: .singleLine),
            snippetSendFormText(for: .bracketedInsert),
            snippetSendFormText(for: .lineByLine),
            snippetSendFormText(for: .refused(.multilineInsert)),
        ]
        #expect(sentences.allSatisfy { !$0.isEmpty })
        #expect(Set(sentences).count == sentences.count)
    }

    /// Every refusal says the same thing about the sending, whatever the
    /// reason is: nothing goes out. The reason is the other half of the
    /// sheet, not this sentence.
    @Test func everyRefusalSharesTheOneSendFormSentence() {
        let problem = SnippetVariableSubstitution.Problem.unusedPlaceholder(name: "PATH")
        #expect(
            snippetSendFormText(for: .refused(.declarationProblem(problem)))
                == snippetSendFormText(for: .refused(.multilineInsert)))
    }

    // MARK: - The reason, when there is one

    @Test func nothingIsRefusedUntilSomethingIsRefused() {
        #expect(snippetDryRunRefusalText(for: .singleLine) == nil)
        #expect(snippetDryRunRefusalText(for: .bracketedInsert) == nil)
        #expect(snippetDryRunRefusalText(for: .lineByLine) == nil)
    }

    /// The declaration reason is the project's ONE mapping from that enum
    /// to a sentence, not a second wording produced for this sheet.
    @Test func aDeclarationRefusalReadsTheProjectsOneWording() {
        let problem = SnippetVariableSubstitution.Problem.placeholderInsideQuotes(name: "PATH")
        let text = snippetDryRunRefusalText(for: .refused(.declarationProblem(problem)))
        #expect(text?.reason == snippetVariableProblemText(for: problem))
        #expect(text?.title.isEmpty == false)
    }

    /// A dry run asks nothing, so its multi-line reason must not borrow the
    /// insert alert's "Execute it instead?" body.
    @Test func theMultilineReasonIsAStatementAndNotAQuestion() {
        let text = snippetDryRunRefusalText(for: .refused(.multilineInsert))
        #expect(text?.reason.isEmpty == false)
        #expect(text?.reason.hasSuffix("?") == false)
        #expect(text?.title.isEmpty == false)
    }

    // MARK: - The value on the screen, and in no sentence

    /// The dry run's own promise, re-checked at the layer that turns it
    /// into text: the substituted value is in the command the sheet shows
    /// (without which the rest is vacuous), and in neither sentence beside
    /// it.
    @Test func aSubstitutedValueReachesNoSentenceTheSheetShows() {
        let snippet = Snippet(
            name: "check", command: "[ -f {{PATH}} ]", variables: [placeholder("PATH")])
        let dryRun = SnippetDryRun.describing(
            snippet, values: ["PATH": Self.typedValue], execute: true, bracketedPaste: false)

        let onScreen = dryRun.resolvedCommand.contains(Self.typedValue)
        #expect(onScreen)

        guard let refusal = snippetDryRunRefusalText(for: dryRun.sendForm) else {
            Issue.record("the fixture stopped being refused — re-anchor this test")
            return
        }
        let inTitle = refusal.title.contains(Self.typedValue)
        let inReason = refusal.reason.contains(Self.typedValue)
        let inSendForm = snippetSendFormText(for: dryRun.sendForm).contains(Self.typedValue)
        #expect(inTitle == false)
        #expect(inReason == false)
        #expect(inSendForm == false)
        // Positive beside the three negatives: the reason really is about
        // this declaration, so the checks above ran over the sentence they
        // are named for rather than over an empty string.
        #expect(refusal.reason.contains("PATH"))
    }

    // MARK: - The values a prompt opens with

    @Test func thePromptOpensOnWhatWasRemembered() {
        let snippet = Snippet(
            name: "dump", command: "mysqldump {{DB}}",
            variables: [placeholder("DB", defaultValue: "vorgabe")])
        let values = snippetVariablePromptValues(for: snippet) { _ in "gemerkt" }
        #expect(values == ["DB": "gemerkt"])
    }

    @Test func thePromptFallsBackToTheDeclarationsDefault() {
        let snippet = Snippet(
            name: "dump", command: "mysqldump {{DB}}",
            variables: [placeholder("DB", defaultValue: "vorgabe")])
        let values = snippetVariablePromptValues(for: snippet) { _ in nil }
        #expect(values == ["DB": "vorgabe"])
    }

    @Test func aSnippetWithNoDeclarationsOpensOnNothing() {
        let snippet = Snippet(name: "ps", command: "docker ps -a")
        var asked: [String] = []
        let values = snippetVariablePromptValues(for: snippet) { name in
            asked.append(name)
            return "gemerkt"
        }
        #expect(values.isEmpty)
        #expect(asked.isEmpty)
    }

    /// Step 3 of the brief, at the layer that can hold it: what the editor
    /// has of the remembered values is a function that RETURNS one. It is
    /// asked once per declaration and has no way to store anything, so an
    /// editor rehearsal cannot pre-fill the next real run — not because
    /// nothing calls a write, but because it holds nothing that could
    /// write. `SnippetDryRunEntranceGuardTests.theEditorsRehearsalRemembersNothing`
    /// pins the other half: that the editor is handed only this closure.
    @Test func theRehearsalCanOnlyReadWhatWasRemembered() {
        let snippet = Snippet(
            name: "dump", command: "mysqldump {{DB}} {{HOST}}",
            variables: [placeholder("DB"), placeholder("HOST")])
        var asked: [String] = []
        _ = snippetVariablePromptValues(for: snippet) { name in
            asked.append(name)
            return nil
        }
        #expect(asked.sorted() == ["DB", "HOST"])
    }

    // MARK: - Colours

    /// All seven kinds map, and the two that a whole-branch review pulled
    /// apart are still apart. `SnippetToken.Kind` has no `CaseIterable`
    /// conformance in Core, so the list is spelled here — and the switch in
    /// `snippetTokenColour` is exhaustive, so an eighth kind stops the
    /// build rather than slipping past this list.
    @Test func everyTokenKindHasAColourAndCommandIsNotVariable() {
        let kinds: [SnippetToken.Kind] = [
            .command, .option, .string, .variable, .comment, .operator, .plain,
        ]
        let colours = kinds.map(snippetTokenColour(for:))
        #expect(colours.count == kinds.count)
        #expect(snippetTokenColour(for: .command) != snippetTokenColour(for: .variable))
        #expect(snippetTokenColour(for: .plain) == DesignTokens.ink)
    }
}
