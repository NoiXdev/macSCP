import Foundation
import Testing

@testable import macSCPCore

/// `SnippetDryRun` — what showing a snippet before it runs consists of.
///
/// The value composes; a view renders. Both entrances to the dry run (the
/// way out of a refusal at trigger time, and the editor's "Test" button)
/// ask this one function, so they show the same thing rather than two
/// similar things.
///
/// **The promise about a substituted value covers this suite's own output.**
/// A value standing for something a person typed is held in `typedValue`,
/// and every assertion about it is made on a `Bool` computed beforehand —
/// so a failure reports `inAuditLine → true` and not the value. The literal
/// never appears inside an expectation either, because `#expect` reports the
/// SOURCE TEXT of its expression alongside the runtime values. The rest of
/// the suite uses visibly non-secret payloads and compares resolved text as
/// a whole, the convention `SnippetPlacementCheckWaiverTests` established.
///
/// That is the same promise this project holds for secrets, applied to a
/// value that can be one — and a promise that only held while the suite was
/// green would not be one.
@Suite("Snippet dry run")
struct SnippetDryRunTests {
    /// `ESC [ 2 0 0 ~`, the sequence a terminal emits before pasted text.
    /// Transcribed here to tie the `.bracketedInsert` LABEL to the bytes
    /// that carry it: without it, the label would be this type's own claim
    /// about a plan it did not have to agree with.
    private static let bracketedPasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    private static let carriageReturn: UInt8 = 0x0D

    private func placeholder(_ name: String) -> SnippetVariable {
        SnippetVariable(
            name: name, prompt: name, kind: .freeText, placement: .placeholder,
            defaultValue: "", remembersLastValue: false)
    }

    private func environmentVariable(_ name: String) -> SnippetVariable {
        SnippetVariable(
            name: name, prompt: name, kind: .freeText, placement: .environment,
            defaultValue: "", remembersLastValue: false)
    }

    // MARK: - The resolved command, not the template

    @Test("the dry run shows the resolved command, not the template")
    func showsTheResolvedCommandRatherThanTheTemplate() {
        let snippet = Snippet(
            name: "dump", command: "mysqldump {{DB}}", variables: [placeholder("DB")])
        let dryRun = SnippetDryRun.describing(
            snippet, values: ["DB": "kunden"], execute: true, bracketedPaste: false)
        #expect(dryRun.resolvedCommand == "mysqldump 'kunden'")
    }

    @Test("a snippet with no declarations resolves to its own command verbatim")
    func aSnippetWithoutDeclarationsResolvesVerbatim() {
        let snippet = Snippet(name: "ps", command: "docker ps -a")
        let dryRun = SnippetDryRun.describing(
            snippet, values: [:], execute: false, bracketedPaste: false)
        #expect(dryRun.resolvedCommand == "docker ps -a")
    }

    // MARK: - Which send form

    @Test("a single-line command is shown as a single-line send")
    func singleLineCommandIsSingleLine() {
        let snippet = Snippet(name: "ps", command: "docker ps -a")
        let dryRun = SnippetDryRun.describing(
            snippet, values: [:], execute: false, bracketedPaste: false)
        #expect(dryRun.sendForm == .singleLine)
        #expect(
            dryRun.plan == SnippetSendPlanner.plan(
                command: "docker ps -a", execute: false, bracketedPaste: false))
    }

    /// The label tied to the bytes for the case where the two could most
    /// easily disagree: the mode is ON and the send is still not bracketed,
    /// because the planner never brackets a single line.
    @Test("a single line is called a single line even with the paste mode on")
    func singleLineStaysSingleLineWithTheModeOn() throws {
        let snippet = Snippet(name: "ps", command: "docker ps -a")
        let dryRun = SnippetDryRun.describing(
            snippet, values: [:], execute: false, bracketedPaste: true)
        #expect(dryRun.sendForm == .singleLine)
        let bytes = try #require(sentBytes(of: dryRun))
        #expect(!bytes.starts(with: Self.bracketedPasteStart))
    }

    /// The label and the bytes are checked together. A `.bracketedInsert`
    /// that did not actually produce a bracketed paste would be a caption
    /// under the wrong picture, and the caption is the only part a reader
    /// of the dry run can see.
    @Test("a multi-line insert with bracketed paste is shown as a bracketed insert")
    func multilineInsertWithBracketedPasteIsBracketed() throws {
        let snippet = Snippet(name: "two", command: "echo one\necho two")
        let dryRun = SnippetDryRun.describing(
            snippet, values: [:], execute: false, bracketedPaste: true)
        #expect(dryRun.sendForm == .bracketedInsert)
        let bytes = try #require(sentBytes(of: dryRun))
        #expect(bytes.starts(with: Self.bracketedPasteStart))
    }

    @Test("a multi-line execute without bracketed paste is shown as line by line")
    func multilineExecuteWithoutBracketedPasteIsLineByLine() throws {
        let snippet = Snippet(name: "two", command: "echo one\necho two")
        let dryRun = SnippetDryRun.describing(
            snippet, values: [:], execute: true, bracketedPaste: false)
        #expect(dryRun.sendForm == .lineByLine)
        let bytes = try #require(sentBytes(of: dryRun))
        #expect(bytes.filter { $0 == Self.carriageReturn }.count == 2)
        #expect(!bytes.starts(with: Self.bracketedPasteStart))
    }

    @Test("a multi-line insert without bracketed paste is shown as refused, with the reason")
    func multilineInsertWithoutBracketedPasteIsRefused() {
        let snippet = Snippet(name: "two", command: "echo one\necho two")
        let dryRun = SnippetDryRun.describing(
            snippet, values: [:], execute: false, bracketedPaste: true)
        #expect(dryRun.sendForm == .bracketedInsert)
        let refused = SnippetDryRun.describing(
            snippet, values: [:], execute: false, bracketedPaste: false)
        #expect(refused.sendForm == .refused(.multilineInsert))
        #expect(refused.plan == .refusedMultilineInsert)
        // The text is still shown — that is the whole point of showing a
        // refusal rather than only reporting one.
        #expect(refused.resolvedCommand == "echo one\necho two")
    }

    // MARK: - A refused placement, with its reason

    @Test("a placeholder the placement check refuses is shown as refused, with the reason")
    func refusedPlacementCarriesItsReason() {
        let snippet = Snippet(
            name: "exists", command: "[ -f {{PATH}} ]", variables: [placeholder("PATH")])
        let dryRun = SnippetDryRun.describing(
            snippet, values: ["PATH": "/etc/hosts"], execute: true, bracketedPaste: false)
        #expect(
            dryRun.sendForm
                == .refused(.declarationProblem(.placeholderIsReparsedByItsCommand(name: "PATH"))))
        // Refused, and still resolved: the reader sees the command the
        // refusal is about, which is the evidence the design asks for.
        #expect(dryRun.resolvedCommand == "[ -f '/etc/hosts' ]")
        #expect(
            dryRun.plan == SnippetSendPlanner.plan(
                command: "[ -f '/etc/hosts' ]", execute: true, bracketedPaste: false))
    }

    /// Both refusals at once. The declaration one is what the dry run
    /// names, because on the real trigger path it is the earlier gate: it
    /// stops before a value is asked for, let alone turned into bytes.
    @Test("when both refusals apply the declaration one is the reason shown")
    func declarationRefusalOutranksTheMultilineOne() {
        let snippet = Snippet(
            name: "both", command: "echo hello\n[ -f {{PATH}} ]", variables: [placeholder("PATH")])
        let dryRun = SnippetDryRun.describing(
            snippet, values: ["PATH": "/etc/hosts"], execute: false, bracketedPaste: false)
        #expect(
            dryRun.sendForm
                == .refused(.declarationProblem(.placeholderIsReparsedByItsCommand(name: "PATH"))))
        // The other refusal has not been talked away — it is what the plan
        // still says.
        #expect(dryRun.plan == .refusedMultilineInsert)
    }

    @Test("a declaration problem that is not about placement is shown too")
    func anUnusedDeclarationIsAReasonAsWell() {
        let snippet = Snippet(
            name: "unused", command: "echo hi", variables: [placeholder("DB")])
        let dryRun = SnippetDryRun.describing(
            snippet, values: ["DB": "kunden"], execute: true, bracketedPaste: false)
        #expect(
            dryRun.sendForm == .refused(.declarationProblem(.unusedPlaceholder(name: "DB"))))
    }

    // MARK: - The waiver reaches the dry run

    /// `firstDeclarationProblem`'s `skipsPlacementCheck` defaults to the
    /// SAFE answer, so a call site that forgets it compiles and quietly
    /// asks a different question than the snippet in its hand. `describing`
    /// takes the `Snippet` and reads the field off it, so there is no
    /// parameter to forget — and these two cases are what says so: the same
    /// template, the same values, one verdict per setting of the field.
    @Test("the snippet's own placement waiver decides which question is asked")
    func theWaiverOnTheSnippetIsTheOneThatCounts() {
        let variables = [placeholder("PATH")]
        let checked = Snippet(
            name: "exists", command: "[ -f {{PATH}} ]", variables: variables,
            skipsPlaceholderPlacementCheck: false)
        let waived = Snippet(
            name: "exists", command: "[ -f {{PATH}} ]", variables: variables,
            skipsPlaceholderPlacementCheck: true)
        let values = ["PATH": "/etc/hosts"]
        #expect(
            SnippetDryRun.describing(
                checked, values: values, execute: true, bracketedPaste: false
            ).sendForm
                == .refused(.declarationProblem(.placeholderIsReparsedByItsCommand(name: "PATH"))))
        #expect(
            SnippetDryRun.describing(
                waived, values: values, execute: true, bracketedPaste: false
            ).sendForm == .singleLine)
    }

    @Test("the waiver does not reach the multi-line insert refusal")
    func theWaiverLeavesTheSendPlanAlone() {
        let waived = Snippet(
            name: "two", command: "echo one\necho two", skipsPlaceholderPlacementCheck: true)
        let dryRun = SnippetDryRun.describing(
            waived, values: [:], execute: false, bracketedPaste: false)
        #expect(dryRun.sendForm == .refused(.multilineInsert))
    }

    // MARK: - The colouring

    @Test("the colouring is the highlighter's, over the resolved text")
    func colouringComesFromTheHighlighterOverTheResolvedText() {
        let snippet = Snippet(
            name: "dump", command: "mysqldump {{DB}}", variables: [placeholder("DB")])
        let dryRun = SnippetDryRun.describing(
            snippet, values: ["DB": "kunden"], execute: true, bracketedPaste: false)
        #expect(
            dryRun.tokens == SnippetHighlighter.tokens(in: dryRun.resolvedCommand, language: .shell))
        // Both sides being empty would satisfy the equality above without
        // any colouring having happened.
        #expect(!dryRun.tokens.isEmpty)
    }

    /// The ranges index into the RESOLVED text. Ranges taken from the
    /// template would be shorter than the resolved string in one place and
    /// longer in another, and a view slicing with them would paint the
    /// wrong characters or trap.
    @Test("a token range slices the resolved text, not the template")
    func tokenRangesIndexIntoTheResolvedText() throws {
        let snippet = Snippet(
            name: "dump", command: "mysqldump {{DB}}", variables: [placeholder("DB")])
        let dryRun = SnippetDryRun.describing(
            snippet, values: ["DB": "kunden"], execute: true, bracketedPaste: false)
        let strings = dryRun.tokens
            .filter { $0.kind == .string }
            .map { String(dryRun.resolvedCommand[$0.range]) }
        #expect(strings == ["'kunden'"])
    }

    // MARK: - The case from the backlog entry

    /// The trap, measured against `bash`: with a single-line assignment
    /// PREFIX the shell expands `$P` before the assignment takes effect, so
    ///
    ///     P='neu' echo "$P"
    ///
    /// prints the OLD value of `P`, or nothing. Somebody who works around a
    /// refused `[ -f {{PATH}} ]` by writing the assignment into the command
    /// themselves gets that silently — today it shows up as a wrong result
    /// on the far side.
    ///
    /// The dry run shows the resolved text, and the resolved text is where
    /// this is readable. `'neu'` rather than `neu` is
    /// `PosixQuoting.singleQuoted`'s doing and changes nothing about the
    /// trap: a shell reads `P='neu'` and `P=neu` as the same assignment.
    ///
    /// Reached with the waiver on, because that is who ends up here: the
    /// placement check refuses a placeholder in an assignment prefix, and
    /// switching it off is the workaround the entry describes.
    @Test("the resolved text shows an assignment prefix expanding before it takes effect")
    func theAssignmentPrefixTrapIsVisibleInTheResolvedText() {
        let snippet = Snippet(
            name: "prefix", command: "P={{VALUE}} echo \"$P\"", variables: [placeholder("VALUE")],
            skipsPlaceholderPlacementCheck: true)
        let dryRun = SnippetDryRun.describing(
            snippet, values: ["VALUE": "neu"], execute: true, bracketedPaste: false)
        #expect(dryRun.resolvedCommand == "P='neu' echo \"$P\"")
        #expect(dryRun.sendForm == .singleLine)
    }

    /// Without the waiver the same template does not get that far: the
    /// placement check refuses a placeholder standing in an assignment
    /// prefix, which is a command-name position and not a plain argument.
    @Test("the same prefix template is refused while the placement check is on")
    func theAssignmentPrefixTemplateIsRefusedWithTheCheckOn() {
        let snippet = Snippet(
            name: "prefix", command: "P={{VALUE}} echo \"$P\"", variables: [placeholder("VALUE")])
        let dryRun = SnippetDryRun.describing(
            snippet, values: ["VALUE": "neu"], execute: true, bracketedPaste: false)
        #expect(
            dryRun.sendForm
                == .refused(
                    .declarationProblem(.placeholderNotInArgumentPosition(name: "VALUE"))))
    }

    /// The other half of the entry's table, and the reason the trap is
    /// worth showing rather than forbidding: an `.environment` declaration
    /// is emitted as its own `export` STATEMENT, not as a prefix, and there
    /// the body does see the value. Two resolved texts that differ by one
    /// `export` and one `;` behave completely differently, which is exactly
    /// what a reader of the dry run is being given the chance to notice.
    @Test("an environment declaration resolves to a statement, not a prefix")
    func anEnvironmentDeclarationResolvesToItsOwnStatement() {
        let snippet = Snippet(
            name: "env", command: "echo \"$P\"", variables: [environmentVariable("P")])
        let dryRun = SnippetDryRun.describing(
            snippet, values: ["P": "neu"], execute: true, bracketedPaste: false)
        #expect(dryRun.resolvedCommand == "export P='neu'; echo \"$P\"")
        #expect(dryRun.sendForm == .singleLine)
    }

    // MARK: - The promise

    /// A value someone typed into a placeholder. Held in a constant so it
    /// never appears in the source text of an expectation — `#expect`
    /// reports that source text on failure, so a literal inside one would
    /// be a failure message carrying the value.
    private static let typedValue = "aardvark-marmoset-quokka"

    /// The dry run puts a substituted value on the screen of whoever typed
    /// it. From there it reaches no record: not the audit line, not an
    /// export file, not the reason a refusal names.
    ///
    /// Every assertion is made on a `Bool` computed first, for the reason
    /// the suite comment gives. The first one is what keeps the rest from
    /// being vacuous: the value really is in the resolved text, so there is
    /// something for the others to catch.
    @Test("a substituted value reaches no audit line, no export and no reason")
    func aSubstitutedValueReachesNoRecord() throws {
        let snippet = Snippet(
            name: "exists", command: "[ -f {{PATH}} ]", variables: [placeholder("PATH")])
        let dryRun = SnippetDryRun.describing(
            snippet, values: ["PATH": Self.typedValue], execute: true, bracketedPaste: false)

        let shownOnScreen = dryRun.resolvedCommand.contains(Self.typedValue)
        #expect(shownOnScreen)

        let auditLine = SnippetAuditDetail.text(for: snippet)
        let inAuditLine = auditLine.contains(Self.typedValue)
        #expect(inAuditLine == false)
        // Positive counterpart: the audit line carries the TEMPLATE, and
        // keeps doing so. Without this, the check above would also pass
        // over an audit line that had stopped saying anything at all.
        #expect(auditLine.contains("{{PATH}}"))

        let exported = try SnippetExportCodec.encode(
            SnippetExportPayload(snippets: [ExportedSnippet(snippet)]))
        let exportedText = try #require(String(data: exported, encoding: .utf8))
        let inExport = exportedText.contains(Self.typedValue)
        #expect(inExport == false)
        #expect(exportedText.contains("{{PATH}}"))

        // The reason a refusal names, reflected whole rather than
        // case by case: whatever `SendForm` carries — today a
        // `SnippetVariableSubstitution.Problem`, tomorrow whatever a
        // reason grows into — is checked, so a payload added later is
        // covered without this test being edited.
        let reason = String(describing: dryRun.sendForm)
        let inReason = reason.contains(Self.typedValue)
        #expect(inReason == false)
        // And the reason is genuinely there to be inspected, rather than
        // an empty description that trivially contains nothing.
        #expect(reason.contains("PATH"))
    }

    /// The same promise for the send form that is not a refusal: the bytes
    /// carry the value, because that is what a send IS — but nothing that
    /// describes the dry run does.
    @Test("the send form describes the value without naming it")
    func theSendFormNamesNoValue() {
        let snippet = Snippet(
            name: "dump", command: "mysqldump {{DB}}", variables: [placeholder("DB")])
        let dryRun = SnippetDryRun.describing(
            snippet, values: ["DB": Self.typedValue], execute: true, bracketedPaste: false)
        let shownOnScreen = dryRun.resolvedCommand.contains(Self.typedValue)
        #expect(shownOnScreen)
        let inForm = String(describing: dryRun.sendForm).contains(Self.typedValue)
        #expect(inForm == false)
    }

    // MARK: - Helper

    private func sentBytes(of dryRun: SnippetDryRun) -> [UInt8]? {
        guard case .send(let bytes) = dryRun.plan else { return nil }
        return bytes
    }
}
