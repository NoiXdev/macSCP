import Foundation

/// What a dry run of one snippet SHOWS — assembled here, so that a view
/// only renders it.
///
/// Two surfaces reach the same dry run: the way out of a refusal when a
/// snippet is triggered, and the "Test" button in the editor. Composing the
/// four parts in each of them would be two descriptions of one thing, and
/// the one that drifted would be whichever gets looked at less.
///
/// The four parts are the backlog entry's own list: the RESOLVED command as
/// it would go on the wire rather than the template, which send form it
/// would take, the reason when it would be refused, and the colouring.
///
/// ## The value on the screen, and nowhere else
///
/// `resolvedCommand` carries what somebody typed into a placeholder. That
/// is the point — it is their own screen. From there it goes into no
/// record: `SnippetAuditDetail` reads the snippet's TEMPLATE,
/// `ExportedSnippet` copies the template, and the reason a refusal names
/// (`SnippetVariableSubstitution.Problem`) carries declaration names only.
/// `SnippetDryRunTests.aSubstitutedValueReachesNoRecord` is where that is
/// stated, because it is a promise about a value that can be a secret and
/// therefore belongs in something that runs.
///
/// ## Why there is no sentence in here
///
/// A refusal carries its reason as data, not as text. The App layer already
/// turns a `SnippetVariableSubstitution.Problem` into the sentence a person
/// reads, for the editor and for the trigger-time alert both; a second
/// wording produced here would be a second answer to a question that has
/// one.
public struct SnippetDryRun: Equatable, Sendable {
    /// Why nothing would be sent.
    public enum Refusal: Equatable, Sendable {
        /// The declarations themselves were refused —
        /// `SnippetVariableSubstitution.firstDeclarationProblem` said so,
        /// asked about THIS snippet, with this snippet's own placement
        /// waiver. Carries that verdict unchanged rather than restating a
        /// selection of it.
        case declarationProblem(SnippetVariableSubstitution.Problem)
        /// The resolved command spans lines, the remote has not enabled
        /// bracketed paste, and the entry promised to insert rather than
        /// execute — `SnippetSendPlan.refusedMultilineInsert`.
        case multilineInsert
    }

    /// How the resolved command would reach the shell, in the vocabulary
    /// the entry asks the dry run to speak: single line, bracketed insert,
    /// line by line, or refused.
    public enum SendForm: Equatable, Sendable {
        case singleLine
        case bracketedInsert
        case lineByLine
        case refused(Refusal)
    }

    /// The command with every declared value applied, exactly as
    /// `SnippetVariableSubstitution.resolve` produces it — including when
    /// the dry run is a refusal, because a refusal the reader cannot see
    /// the command for is the state this whole feature replaces.
    public let resolvedCommand: String
    public let sendForm: SendForm
    /// The planner's own answer for `resolvedCommand`, kept so a surface
    /// offering "send anyway" has the bytes rather than planning a second
    /// time from a command it reassembled itself.
    ///
    /// Computed even when `sendForm` is `.refused(.declarationProblem)`:
    /// that refusal is about where a value sits, not about how bytes reach
    /// a shell, and overriding "send anyway" is precisely the case it is
    /// kept for.
    public let plan: SnippetSendPlan
    /// `SnippetHighlighter`'s tokens for `resolvedCommand`. Ranges index
    /// into `resolvedCommand`, never into the template — a substituted
    /// value changes the text's length in both directions, so template
    /// ranges would paint the wrong characters.
    public let tokens: [SnippetToken]

    /// Private, so a `SnippetDryRun` can only come from `describing`. A
    /// value whose four parts were passed in separately could describe a
    /// send form that does not match its own plan, and nothing about the
    /// type would say so.
    private init(
        resolvedCommand: String, sendForm: SendForm, plan: SnippetSendPlan,
        tokens: [SnippetToken]
    ) {
        self.resolvedCommand = resolvedCommand
        self.sendForm = sendForm
        self.plan = plan
        self.tokens = tokens
    }

    /// What triggering `snippet` with `values` would show.
    ///
    /// Takes the whole `Snippet` rather than a command, its declarations
    /// and a flag. `SnippetVariableSubstitution.firstDeclarationProblem`'s
    /// `skipsPlacementCheck` parameter carries the SAFE default, so a
    /// caller holding a `Snippet` can leave it out and be answered about a
    /// different snippet than the one in its hand, silently and with the
    /// compiler content. Here there is no argument to leave out: the field
    /// is read off `snippet`, and the two verdicts that depend on it are
    /// pinned in `SnippetDryRunTests
    /// .theWaiverOnTheSnippetIsTheOneThatCounts`.
    ///
    /// The declaration verdict is asked about the TEMPLATE and outranks the
    /// send plan's own refusal when both apply, because that is the order
    /// the trigger path runs them in: it stops before a value is asked for,
    /// let alone turned into bytes. `plan` still reports the other refusal
    /// for a caller that wants it.
    ///
    /// `SnippetLanguage` is a parameter of the highlighter and not a field
    /// on `Snippet` — see `SnippetLanguage`'s own doc comment for why. When
    /// a second language arrives it belongs on `Snippet`, and this reads it
    /// from there instead of naming a case.
    public static func describing(
        _ snippet: Snippet, values: [String: String], execute: Bool, bracketedPaste: Bool
    ) -> SnippetDryRun {
        let resolved = SnippetVariableSubstitution.resolve(
            command: snippet.command, variables: snippet.variables, values: values)
        let plan = SnippetSendPlanner.plan(
            command: resolved, execute: execute, bracketedPaste: bracketedPaste)
        let problem = SnippetVariableSubstitution.firstDeclarationProblem(
            command: snippet.command, variables: snippet.variables,
            skipsPlacementCheck: snippet.skipsPlaceholderPlacementCheck)

        let sendForm: SendForm
        if let problem {
            sendForm = .refused(.declarationProblem(problem))
        } else {
            switch plan {
            case .refusedMultilineInsert:
                sendForm = .refused(.multilineInsert)
            case .send:
                // The planner reports bytes, not which of its branches
                // produced them, so the LABEL is derived here from the same
                // two facts the planner branches on. That is a second
                // reading of one rule, and the way it is kept from drifting
                // into a caption under the wrong picture is that each label
                // is pinned to the bytes rather than to this line: the
                // suite checks that `.bracketedInsert` really is bracketed,
                // that `.singleLine` is not bracketed even with the mode
                // on, and that `.lineByLine` ends every line with the byte
                // a Return sends.
                //
                // `\.isNewline` per `Character` is `SnippetSendPlanner`'s
                // own test for a multi-line command, spelled the same way
                // for the same reason: `\r\n` is one `Character`, so
                // `contains("\n")` would miss a CRLF command.
                if resolved.contains(where: \.isNewline) {
                    sendForm = bracketedPaste ? .bracketedInsert : .lineByLine
                } else {
                    sendForm = .singleLine
                }
            }
        }

        return SnippetDryRun(
            resolvedCommand: resolved, sendForm: sendForm, plan: plan,
            tokens: SnippetHighlighter.tokens(in: resolved, language: .shell))
    }
}
