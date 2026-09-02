import Foundation
import SwiftUI
import macSCPCore

/// The outcome of reading `snippets.json`, in the two shapes the UI has to
/// tell apart: a list (possibly empty) or a store that could not be read.
///
/// `SnippetStore.all()` throws for a file it cannot decode — a missing
/// required field is enough to get there, which
/// `SnippetsPresentationTests.anUndecodableStoreIsUnreadableRatherThanEmpty`
/// pins. Both readers of the store used to collapse that into `[]`, so an
/// unreadable store looked exactly like an empty one: the Terminal menu
/// showed no snippet entries, and the management sheet said "No snippets
/// yet." over a file that still holds every snippet the user wrote. Nothing
/// is lost in that state — `save`/`remove` read the file first and throw
/// too, so no write lands on top of it — but the user got no signal at all.
///
/// Both call sites now say which case they are in: `SnippetsSheet` shows the
/// read error in the error slot it already had and suppresses its "No
/// snippets yet." line, and the Terminal menu shows a disabled notice entry.
enum SnippetsLoad: Equatable {
    case loaded([Snippet])
    case unreadable

    /// Reads `store` once. Anything `all()` throws lands in `.unreadable` —
    /// the error itself is not carried, because neither call site shows it:
    /// a decoder's `debugDescription` is not a user-facing sentence, and a
    /// snippet's own text could appear in it.
    init(reading store: SnippetStore) {
        if let snippets = try? store.all() {
            self = .loaded(snippets)
        } else {
            self = .unreadable
        }
    }

    /// The snippets to list — empty for `.unreadable`, so a caller that only
    /// enumerates entries needs no special case. A caller that would
    /// otherwise CLAIM the store is empty must check `isUnreadable` instead.
    var snippets: [Snippet] {
        switch self {
        case .loaded(let snippets): return snippets
        case .unreadable: return []
        }
    }

    var isUnreadable: Bool { self == .unreadable }
}

/// The management sheet's tag filter row (Terminal-Snippets, Task 5): "All"
/// (no restriction), one specific tag, or "untagged". Single-valued by
/// construction — the filter chips are mutually exclusive, so there is no
/// separate `Set` of active tags or an "is All selected" bool that could
/// disagree with the rest — `.all` is both the default and what the "All"
/// chip resets to.
enum SnippetTagFilter: Equatable {
    case all
    case tag(String)
    case untagged

    /// Whether `snippet` passes this filter. `.tag` compares EXACTLY
    /// (case-sensitive) — the same rule `Snippet.tags` itself stores by (see
    /// that type's doc comment): a filter chip's tag string comes verbatim
    /// from `SnippetTagSuggestions`, already in its stored case, so
    /// comparing case-insensitively here could match a snippet whose tag
    /// differs only in case from the one the chip names.
    func matches(_ snippet: Snippet) -> Bool {
        switch self {
        case .all: return true
        case .tag(let tag): return snippet.tags.contains(tag)
        case .untagged: return snippet.tags.isEmpty
        }
    }
}

/// Whether `SnippetsSheet` counts as "filtered" right now — used only to
/// choose its empty-state wording: with neither the search text nor the tag
/// filter active, an empty visible list means "No snippets yet."; with
/// either active, it means "No matches." — the store itself is not empty,
/// the filters just rule out everything it has (same distinction
/// `SnippetsLoad.isUnreadable` draws for the read-failure case, one layer
/// up).
func snippetsAreFiltered(searchText: String, tagFilter: SnippetTagFilter) -> Bool {
    !searchText.isEmpty || tagFilter != .all
}

/// Whether `SnippetsSheet`'s Export… button may be enabled (P3b, Task 3):
/// there must be at least one visible row AND the store must have actually
/// loaded. `visibleSnippets` is already empty whenever `load` is
/// `.unreadable` (`SnippetsLoad.snippets` returns `[]` for that case), so
/// the emptiness check alone would already keep the button disabled there —
/// but that would be a coincidence of today's filtering logic, not a stated
/// rule. Naming `load.isUnreadable` explicitly is what turns "no export from
/// an unreadable store" (writing an empty file over one that still holds
/// every snippet would be silent data loss) into something this function
/// documents and a test can pin, rather than something that happens to hold.
func snippetsCanExport(load: SnippetsLoad, visibleSnippets: [Snippet]) -> Bool {
    !load.isUnreadable && !visibleSnippets.isEmpty
}

// MARK: - Import (P3b/T4)

/// How many planned snippets an import actually wrote, split from how many
/// failed to write. `SnippetsSheet.applyImport` is the only caller.
struct SnippetImportApplyResult: Equatable {
    var imported: Int
    var storeFailures: Int
}

/// Writes every snippet `plan` resolved, through `SnippetStore.save`.
///
/// `SnippetStore.save` replaces an existing id IN PLACE rather than
/// appending (see its own doc comment), and `SnippetImportPlanner` gives a
/// `replacesExisting` `PlannedSnippet` the ORIGINAL snippet's id — so
/// calling `save` for every planned snippet, replace or not, is the whole
/// of "apply": there is no separate branch that could get replace wrong by
/// appending instead. The caller is responsible for checking
/// `plan.cancelled` first — this function writes whatever
/// `plan.snippetsToImport` holds, unconditionally.
func applySnippetImportPlan(_ plan: SnippetImportPlan, to store: SnippetStore) -> SnippetImportApplyResult {
    var imported = 0
    var storeFailures = 0
    for planned in plan.snippetsToImport {
        do {
            try store.save(planned.snippet)
            imported += 1
        } catch {
            storeFailures += 1
        }
    }
    return SnippetImportApplyResult(imported: imported, storeFailures: storeFailures)
}

/// The multi-line body of the "Import Complete" alert `SnippetsSheet` shows
/// after a non-cancelled apply. Mirrors the shape `ImportFeedbackText
/// .importResultText` builds for sessions, reduced to what this format
/// actually has to say: a snippet carries no secret and no key file, so
/// there is nothing here to report beyond how many landed, how many of
/// those were a replace/rename, how many the planner refused for having no
/// name, and whether any write failed.
func snippetImportResultText(plan: SnippetImportPlan, applied: SnippetImportApplyResult) -> String {
    var lines = [String(format: L10n.string(
        "snippets.import.result %lld", "%lld imported"), applied.imported)]
    // Reuses the generic line the session import already shows for the same
    // two facts — nothing snippet-specific to say about a replace or a
    // rename.
    if !plan.replaced.isEmpty || !plan.renamed.isEmpty {
        lines.append(String(format: L10n.string(
            "import.result.resolved %lld %lld", "%lld replaced, %lld renamed"),
            plan.replaced.count, plan.renamed.count))
    }
    // Not a write failure and not a user decision: the planner refused
    // these outright (see `SnippetImportPlanner.plan`), so the count would
    // otherwise vanish between "the file held N" and "N-1 landed".
    if plan.namelessDiscarded > 0 {
        lines.append(String(format: L10n.string(
            "snippets.import.nameless %lld", "Not imported without a name: %lld"),
            plan.namelessDiscarded))
    }
    if applied.storeFailures > 0 {
        lines.append(String(format: L10n.string(
            "import.result.storeFailures %lld", "Not saved due to an error: %lld"),
            applied.storeFailures))
    }
    return lines.joined(separator: "\n")
}

/// Maps the `SessionExportError` cases `SnippetExportCodec.probe`/`.decode`
/// can throw to display text. `.unsupportedVersion` reuses the same "newer
/// app" message the other two import flows already show; everything else —
/// a file of the wrong kind (a session or login-set export) or a corrupted
/// one — gets the one generic refusal text this task's brief asks for.
/// `.passwordRequired` DOES reach this format, from a file this app cannot
/// have written: an envelope claiming our format name with
/// `"encrypted" : true` makes `decode` — which has no password to pass —
/// throw it (pinned by `SnippetExportCodecTests
/// .aForeignFileClaimingEncryptionProbesTrueAndRefusesToDecode`). It
/// belongs in the generic bucket on purpose rather than defensively:
/// prompting for a password would offer a key path this format does not
/// have, so "this file couldn't be read as macSCP snippets" is the honest
/// answer. `.wrongPasswordOrCorrupted` and `.randomnessUnavailable` are the
/// two that genuinely cannot arrive — both live beyond a password check
/// that always refuses first — and they are here defensively.
func snippetImportErrorText(for error: SessionExportError) -> String {
    switch error {
    case .unsupportedVersion:
        return L10n.string(
            "import.error.newerVersion",
            "This file was created by a newer version of macSCP.")
    case .notAnExportFile, .passwordRequired, .wrongPasswordOrCorrupted, .randomnessUnavailable:
        return L10n.string(
            "snippets.import.error",
            "This file couldn't be read as macSCP snippets. It may be a different kind of export, or damaged.")
    }
}

/// Maps a `SnippetVariableSubstitution.Problem` to the sentence the user
/// reads.
///
/// One mapping for two surfaces: the editor shows it under the variables
/// section while Save is disabled, and `snippetDryRunRefusalText` shows it
/// in the dry run that refuses to run a snippet whose declarations never
/// passed an editor — an imported one. Two switches over the same enum
/// would drift, and the half that drifted would be the one nobody looks
/// at.
///
/// Names are interpolated, values are NOT: a `Problem` never carries one,
/// and this project's rule keeps a typed value out of every message.
/// `.invalidName` deliberately drops even the name into a name-free
/// sentence — an imported declaration can carry an arbitrary string there,
/// and quoting a hostile one back at the user buys nothing.
/// `.unanalyzableContext` says what was found and why the value cannot be
/// placed, without suggesting the command is wrong: a here-document is an
/// ordinary way to write one, and so is every other construct
/// `SnippetCommandSurvey` refuses. Each of those sentences is a statement
/// about macSCP's reach, never about the user's command.
func snippetVariableProblemText(for problem: SnippetVariableSubstitution.Problem) -> String {
    switch problem {
    case .invalidName:
        return L10n.string(
            "snippets.variables.error.invalidName",
            "A variable name must start with a letter or underscore and may contain only letters, digits and underscores.")
    case .unanalyzableContext(.heredoc):
        return L10n.string(
            "snippets.variables.error.heredoc",
            "This command uses a here-document (<<). macSCP can't see which parts of it are quoted, so it can't tell where a value would end up — and won't place one there.")
    case .unanalyzableContext(.unbalancedQuoting):
        return L10n.string(
            "snippets.variables.error.unbalancedQuoting",
            "A quote in this command doesn't close on the line it opens. macSCP can't tell whether a value would end up inside quotes, so it won't place one there.")
    case .unusedPlaceholder(let name):
        return String(
            format: L10n.string(
                "snippets.variables.error.unusedPlaceholder %@",
                "“%@” is never used in the command."),
            name)
    case .placeholderInsideQuotes(let name):
        return String(
            format: L10n.string(
                "snippets.variables.error.quotedPlaceholder %@",
                "“%@” sits inside quotes. Remove them — the value is quoted for you."),
            name)
    case .placeholderNotInArgumentPosition(let name):
        return String(
            format: L10n.string(
                "snippets.variables.error.placeholderPosition %@",
                "“%@” isn't a plain argument of the command. macSCP can only keep a value safe there — take it out of the command name, a redirection or a comment."),
            name)
    case .placeholderIsReparsedByItsCommand(let name):
        return String(
            format: L10n.string(
                "snippets.variables.error.reparsedArgument %@",
                "The command that “%@” belongs to reads its arguments back as shell code (like [, test, printf -v or exit). Quoting can't keep a value safe there, so macSCP won't place one."),
            name)
    case .unanalyzableContext(.commandSubstitution):
        return L10n.string(
            "snippets.variables.error.commandSubstitution",
            "This command runs another command inside itself ($(…), backticks or a subshell). macSCP can't tell where a value would end up in there, so it won't place one.")
    case .unanalyzableContext(.expansion):
        return L10n.string(
            "snippets.variables.error.expansion",
            "This command uses an expansion macSCP can't read (${…}, $((…)) or $'…'). It can't tell where a value would end up, so it won't place one.")
    case .unanalyzableContext(.evaluation):
        return L10n.string(
            "snippets.variables.error.evaluation",
            "This command hands its arguments back to the shell (eval). Quoting can't keep a value safe there, so macSCP won't place one.")
    case .unanalyzableContext(.unrecognizedSyntax):
        return L10n.string(
            "snippets.variables.error.unrecognizedSyntax",
            "macSCP can't read this command far enough to tell where a value would end up. It places values only into plain, unquoted arguments and refuses whatever it can't survey.")
    }
}

// MARK: - The dry run, as one description for both entrances

/// Which colour one highlighter token gets. Core supplies none — see
/// `SnippetToken`'s own doc comment — so this is where a kind becomes a
/// design token.
///
/// The one map. `SnippetCommandEditor` colours an `NSTextView` while the
/// user types and the dry-run sheet colours a SwiftUI `Text`; both read
/// this, the editor bridging each answer through `NSColor(_:)`. Four of the
/// seven kinds already went through that bridge before this function
/// existed (`NSColor(DesignTokens.remoteBlue)` and its three siblings), and
/// the other three name tokens whose `Color` is itself built from the
/// `NSColor` the editor used (`DesignTokens.ink` is `Color(nsColor:
/// inkNS)`), so nothing here asks the bridge for something it was not
/// already doing.
func snippetTokenColour(for kind: SnippetToken.Kind) -> Color {
    switch kind {
    case .command: return DesignTokens.remoteBlue
    case .option: return DesignTokens.agentGreen
    case .string: return DesignTokens.localAmber
    // Its own hue: `.command` and `.variable` shared `remoteBlue` until a
    // whole-branch review separated them.
    case .variable: return DesignTokens.s3Violet
    case .comment: return DesignTokens.inkTertiary
    case .operator: return DesignTokens.inkSecondary
    case .plain: return DesignTokens.ink
    }
}

/// How the resolved command would reach the shell, as the sentence under
/// the command in the dry-run sheet.
///
/// Reads `SnippetDryRun.SendForm` and nothing else: the four words are the
/// value's, not this function's, so a surface cannot decide that a
/// bracketed insert "is basically a single line".
func snippetSendFormText(for form: SnippetDryRun.SendForm) -> String {
    switch form {
    case .singleLine:
        return L10n.string("snippets.dryRun.form.singleLine", "Goes out as a single line.")
    case .bracketedInsert:
        return L10n.string(
            "snippets.dryRun.form.bracketedInsert",
            "Inserted in one piece: the remote shell takes every line without running any of them.")
    case .lineByLine:
        return L10n.string(
            "snippets.dryRun.form.lineByLine", "Goes out line by line; each line runs as it arrives.")
    case .refused:
        return L10n.string("snippets.dryRun.form.refused", "Nothing would be sent.")
    }
}

/// The heading and the reason for a refused dry run, or `nil` when nothing
/// was refused.
///
/// The declaration arm hands straight to `snippetVariableProblemText` — the
/// project's one mapping from that enum to a sentence — rather than
/// wording the same verdict a second time.
///
/// The multi-line arm is not reachable from either entrance today: the
/// trigger path opens a dry run only on a declaration refusal, and the
/// editor's rehearsal describes an execution, which the planner never
/// refuses. It is written as a statement rather than borrowing the alert's
/// "Execute it instead?" body, because a dry run asks nothing.
func snippetDryRunRefusalText(
    for form: SnippetDryRun.SendForm
) -> (title: String, reason: String)? {
    guard case .refused(let refusal) = form else { return nil }
    switch refusal {
    case .declarationProblem(let problem):
        return (
            L10n.string(
                "snippets.variables.refused.title", "This snippet's values can't be filled in"),
            snippetVariableProblemText(for: problem)
        )
    case .multilineInsert:
        return (
            L10n.string(
                "snippets.insert.multilineRefused.title", "This snippet has several lines"),
            L10n.string(
                "snippets.dryRun.refusal.multilineInsert",
                "The remote shell cannot take these lines in one piece, so inserting them would run every line but the last.")
        )
    }
}

/// The values a snippet-variable prompt opens with: what was remembered for
/// a declaration, else its `defaultValue`.
///
/// One function for both prompts. The trigger path opens the prompt to run
/// a snippet and the editor's "Test" button opens the same prompt to
/// rehearse one; computing the starting values twice would be two answers
/// to "what is this value right now", and the one that drifted would be the
/// rehearsal — the half nobody checks against a real run.
///
/// `remembered` is a READ, and that is the whole of the editor's access to
/// what was remembered: a closure that returns a value can never store one,
/// so the rehearsal cannot pre-fill the next real run even by mistake.
func snippetVariablePromptValues(
    for snippet: Snippet, remembered: (_ name: String) -> String?
) -> [String: String] {
    var values: [String: String] = [:]
    for variable in snippet.variables {
        values[variable.name] = remembered(variable.name) ?? variable.defaultValue
    }
    return values
}

// MARK: - The variable section's fault, and which declaration it is about

/// What is wrong with a set of variable declarations right now: the one
/// sentence the editor shows below them, and which of the declarations that
/// sentence is about.
///
/// Two questions with one answer, deliberately. The editor asked only the
/// first until folding needed the second, and the shortest way to the
/// second would have been a separate pass over the same declarations — a
/// second opinion on "is this one wrong", which is exactly the kind of pair
/// that agrees on the day it is written.
struct SnippetVariablesFault: Equatable {
    /// The sentence. One fault at a time: the editor has a single line for
    /// it, and a list of every complaint at once is what a user reads past.
    let message: String
    /// The declarations the fault is about, as offsets into the array that
    /// was checked.
    ///
    /// EMPTY is a real answer, not a missing one: `.unanalyzableContext` is
    /// a statement about the command — macSCP cannot read it far enough to
    /// say where a value would land — and no declaration is at fault for
    /// it. Rows stay foldable in that state, because opening them would
    /// show nothing that explains the sentence.
    let declarations: Set<Int>
}

/// The fault in `variables` for `command`, or `nil` when there is none.
///
/// The order is the order the editor has always checked in, and it is not
/// arbitrary: an unusable name makes every question below it unanswerable
/// (`SnippetVariableSubstitution.resolve` skips such a declaration outright),
/// and two declarations sharing a name make "which row is this problem
/// about" undecidable — which is why the name checks run before the one
/// question whose answer arrives as a NAME.
///
/// Both name checks report EVERY row they find, while the command-side
/// check reports the one row `SnippetVariableSubstitution
/// .firstDeclarationProblem` names. That asymmetry is that function's,
/// unchanged by this one: it answers with the first problem it meets, and
/// folding is presentation — no reason to widen a security-critical gate
/// for a layout question.
func snippetVariablesFault(
    command: String, variables: [SnippetVariable], skipsPlacementCheck: Bool
) -> SnippetVariablesFault? {
    let unusable = variables.indices.filter { !SnippetVariable.isValidName(variables[$0].name) }
    if !unusable.isEmpty {
        return SnippetVariablesFault(
            message: L10n.string(
                "snippets.variables.error.invalidName",
                "A variable name must start with a letter or underscore and may contain only letters, digits and underscores."),
            declarations: Set(unusable))
    }

    var rowsByName: [String: Set<Int>] = [:]
    for (index, variable) in variables.enumerated() {
        rowsByName[variable.name, default: []].insert(index)
    }
    let shared = rowsByName.values.filter { $0.count > 1 }.reduce(into: Set<Int>()) {
        $0.formUnion($1)
    }
    if !shared.isEmpty {
        return SnippetVariablesFault(
            message: L10n.string(
                "snippets.variables.error.duplicateName", "Two variables share a name."),
            declarations: shared)
    }

    guard
        let problem = SnippetVariableSubstitution.firstDeclarationProblem(
            command: command, variables: variables, skipsPlacementCheck: skipsPlacementCheck)
    else { return nil }
    let named = snippetFaultedDeclarationName(problem)
    return SnippetVariablesFault(
        message: snippetVariableProblemText(for: problem),
        declarations: Set(variables.indices.filter { variables[$0].name == named }))
}

/// The declaration a `Problem` names, or `nil` for one that names none.
///
/// Reads the payload the enum already carries rather than re-deriving which
/// declaration is meant — the case that says `name:` is the mapping, and a
/// second one would be a second answer.
///
/// `.invalidName` cannot arrive from `snippetVariablesFault`, its only
/// caller, which returns on an unusable name before the survey is
/// consulted. It is bound with its four siblings rather than sent to `nil`
/// through a `default`, because a case that carries a name and answers "no
/// name" would be wrong for any caller that did reach it.
private func snippetFaultedDeclarationName(
    _ problem: SnippetVariableSubstitution.Problem
) -> String? {
    switch problem {
    case .invalidName(let name), .unusedPlaceholder(let name),
        .placeholderInsideQuotes(let name), .placeholderNotInArgumentPosition(let name),
        .placeholderIsReparsedByItsCommand(let name):
        return name
    case .unanalyzableContext:
        return nil
    }
}

// MARK: - Folding the variable rows (snippet editor operation, part 1)

/// One variable row as folding sees it: which row it is, and whether
/// something is wrong with it right now.
///
/// `hasProblem` is a fact about this moment, not a stored property of the
/// declaration — the editor recomputes it from `snippetVariablesFault` on
/// every keystroke, and a row can acquire and lose it while a name is being
/// typed.
struct SnippetVariableFoldRow: Equatable, Identifiable {
    let id: UUID
    let hasProblem: Bool
}

/// Which of the snippet editor's variable rows are drawn open, and which of
/// the two bulk actions it offers.
///
/// **Nothing here is remembered.** Every opening of the editor starts with
/// this value freshly built, so there is no question about where a fold
/// state lives, whether it still matches its snippet after an edit, what
/// happens to it when a declaration is deleted, or whether it travels with
/// an export. Not having the state is the shorter answer than answering
/// four questions about it.
///
/// A row is drawn open when the user opened it OR when it has a problem,
/// and the second half is not a preference the first can override: a closed
/// row with an error marker says that something is wrong and not what, so
/// one opens it anyway. That single rule is what makes "collapse all"
/// double as "show me only the problems".
struct SnippetVariableFolding: Equatable {
    /// The rows somebody asked to see. Not "the rows that are open" — a
    /// faulty row is open without being in here, and stays open however
    /// this set changes.
    private var opened: Set<UUID> = []

    func isExpanded(_ row: SnippetVariableFoldRow) -> Bool {
        row.hasProblem || opened.contains(row.id)
    }

    /// Whether this row offers a control that would close it at all. A
    /// faulty row does not — absent rather than disabled, the same choice
    /// the editor's "Test" button already makes, because a greyed-out
    /// control asks the reader to work out why.
    func canCollapse(_ row: SnippetVariableFoldRow) -> Bool { !row.hasProblem }

    /// What "Add variable" calls for the row it just created. The row is
    /// unnamed at that moment and therefore faulty anyway, so this changes
    /// nothing one keystroke later — and everything the keystroke after
    /// that, when the name becomes valid and the row would otherwise shut
    /// under the cursor.
    mutating func open(_ id: UUID) { opened.insert(id) }

    /// Records the opposite of what the user is looking at. No special case
    /// for a faulty row: this expresses what somebody asked to see, and the
    /// fault decides what is drawn. The editor draws no toggle on a faulty
    /// row, so the question does not arise there either.
    mutating func toggle(_ row: SnippetVariableFoldRow) {
        if opened.contains(row.id) {
            opened.remove(row.id)
        } else {
            opened.insert(row.id)
        }
    }

    mutating func expandAll(_ rows: [SnippetVariableFoldRow]) {
        opened.formUnion(rows.map(\.id))
    }

    /// Closes everything that can close, and REMEMBERS the faulty rows as
    /// opened.
    ///
    /// Forgetting them instead would leave them open on the fault alone —
    /// which reads the same until the fault is fixed, and then shuts the
    /// row under the cursor of the person who just fixed it. "Collapse all"
    /// is most useful as the way to get at exactly those rows, so it must
    /// not take the row away as a reward for using it.
    mutating func collapseAll(_ rows: [SnippetVariableFoldRow]) {
        opened = Set(rows.filter(\.hasProblem).map(\.id))
    }

    /// Offered only when there is something left to open, and only when
    /// there is something left to close — show what is possible, rather
    /// than showing a control greyed out.
    func offersExpandAll(_ rows: [SnippetVariableFoldRow]) -> Bool {
        rows.contains { !isExpanded($0) }
    }

    /// A faulty row is open and cannot be closed, so a section whose only
    /// open rows are faulty offers no "collapse all": it would be a button
    /// that does nothing.
    func offersCollapseAll(_ rows: [SnippetVariableFoldRow]) -> Bool {
        rows.contains { isExpanded($0) && canCollapse($0) }
    }
}

/// The one line a closed variable row shows: its name, its kind and its
/// placement.
///
/// Enough to find the right declaration without opening it — and placement
/// belongs there because it decides whether the declaration belongs in the
/// command as a placeholder at all.
///
/// The kind and the placement are read through the same localization keys
/// the editor's own two pickers use, so the closed row and the open one
/// cannot end up wording the same choice differently. What a `.selection`
/// actually allows is deliberately not here: that list grows with the
/// declaration and would push the other two facts off a 460 pt row.
func snippetCollapsedVariableSummary(for variable: SnippetVariable) -> String {
    let kind: String
    switch variable.kind {
    case .freeText:
        kind = L10n.string("snippets.variables.kind.freeText", "Free text")
    case .selection:
        kind = L10n.string("snippets.variables.kind.selection", "Choice")
    }
    let placement: String
    switch variable.placement {
    case .placeholder:
        placement = L10n.string(
            "snippets.variables.placement.placeholder", "Placeholder in the command")
    case .environment:
        placement = L10n.string(
            "snippets.variables.placement.environment", "Environment variable")
    }
    return String(
        format: L10n.string("snippets.variables.summary %@ %@ %@", "%@ · %@ · %@"),
        variable.name, kind, placement)
}

// MARK: - Placeholder help (snippet editor operation, part 2)

/// Whether `variable` belongs in the command as `{{NAME}}` — the ONE
/// question both entrances ask before offering a name.
///
/// One question, so an environment declaration is missing from the row's
/// insert control and from the completion list by construction, rather than
/// through two filters that agree today. Its value is prepended as an
/// `export NAME='value';` statement (see `SnippetVariable.Placement
/// .environment`), so a `{{NAME}}` for it would produce the exact opposite
/// of what its placement says: text nothing fills in, next to a value the
/// command never mentions.
///
/// **And it is not offered as `$NAME` either**, in either entrance. In a
/// single-line assignment PREFIX the shell expands `$NAME` before the
/// assignment takes effect (`P=neu echo "$P"` prints the old value), so a
/// control that inserted it would be silently wrong in a single-line
/// command — and "offer it when the command has several lines" is a rule
/// that changes while the command is being typed. Whoever writes `$NAME`
/// by hand sees the consequence in the dry run, which resolves the command
/// the same way the run path does.
///
/// A name `SnippetVariable.isValidName` rejects is not offered either:
/// `SnippetVariableSubstitution.resolve` skips such a declaration, so its
/// `{{NAME}}` would be text nothing ever fills in.
func snippetBelongsInCommandAsPlaceholder(_ variable: SnippetVariable) -> Bool {
    variable.placement == .placeholder && SnippetVariable.isValidName(variable.name)
}

/// The names either entrance may offer, in declaration order, without
/// repeats.
///
/// Repeats are dropped because two declarations sharing a name is a state
/// the editor lets the user be in while they fix it
/// (`snippetVariablesFault`'s duplicate check) — offering the same name
/// twice would say nothing about which of the two rows is meant.
func snippetInsertablePlaceholderNames(in variables: [SnippetVariable]) -> [String] {
    var seen: Set<String> = []
    return variables
        .filter { snippetBelongsInCommandAsPlaceholder($0) }
        .map(\.name)
        .filter { seen.insert($0).inserted }
}

/// `command` with `{{name}}` put at its end.
///
/// The end, because SwiftUI hands a `View` no caret position in the
/// `NSTextView` below it — and a control that claimed to insert "where you
/// are" while actually appending would be worse than one that says where it
/// writes. Separated from what stands before it by one space, unless the
/// command is empty or already ends in whitespace: a line break separates
/// on its own, and turning it into a break plus a space would indent the
/// new line for no reason.
func snippetCommandInsertingPlaceholder(_ name: String, into command: String) -> String {
    let placeholder = "{{\(name)}}"
    guard let last = command.last else { return placeholder }
    return last.isWhitespace ? command + placeholder : command + " " + placeholder
}

/// The entries the command field's completion list offers, given the text
/// on either side of the partial word AppKit is completing.
///
/// Takes the surrounding text rather than a text view, so the whole rule is
/// decidable without one: the list opens only where the opening braces
/// stand immediately before the partial word, and nowhere else — an
/// ordinary word in a command must not turn into a variable list.
///
/// An entry is what gets INSERTED, closing braces included, so completing
/// leaves a finished `{{NAME}}` rather than a half-open one to close by
/// hand. Only the braces that are missing are added: a placeholder being
/// edited in place already carries its own, and a second pair would leave
/// two closing braces too many behind.
///
/// Matching ignores case while the ENTRY keeps the declared spelling —
/// inserting the spelling that was typed would write a name no declaration
/// carries, and `SnippetVariableSubstitution.occurrences` compares
/// exactly.
func snippetPlaceholderCompletions(
    in variables: [SnippetVariable], textBeforePartialWord: String,
    partialWord: String, textAfterPartialWord: String
) -> [String] {
    guard textBeforePartialWord.hasSuffix("{{") else { return [] }
    let alreadyClosed = textAfterPartialWord.prefix(2).prefix { $0 == "}" }.count
    let closing = String(repeating: "}", count: 2 - alreadyClosed)
    let typed = partialWord.lowercased()
    return snippetInsertablePlaceholderNames(in: variables)
        .filter { $0.lowercased().hasPrefix(typed) }
        .map { $0 + closing }
}

/// Every `{{NAME}}` in `command`, left to right, as the names inside the
/// braces.
///
/// A recogniser of its own rather than a call into
/// `SnippetVariableSubstitution`: that type's finder answers "where does
/// THIS declared name occur", which is the question the gate and the
/// emitter ask, and it is not this one — nothing here knows a name to look
/// for. The two agree about what a placeholder is by both deferring to
/// `SnippetVariable.isValidName`, which is also what makes the agreement
/// checkable: a brace run that is not a name is not a placeholder for
/// either of them, and `resolve` would leave it standing whatever was
/// declared.
///
/// Extra braces behave the way `occurrences` treats them, and for the same
/// reason: a third opening brace is a literal character before the
/// placeholder (the scan advances one scalar and finds `{{NAME}}` at the
/// next position), and a third closing brace is one after it.
private func snippetPlaceholderNames(in command: String) -> [String] {
    let scalars = Array(command.unicodeScalars)
    var names: [String] = []
    var index = 0
    while index < scalars.count {
        guard scalars[index] == "{", index + 1 < scalars.count, scalars[index + 1] == "{"
        else {
            index += 1
            continue
        }
        var cursor = index + 2
        var name = String.UnicodeScalarView()
        while cursor < scalars.count, scalars[cursor] != "}" {
            name.append(scalars[cursor])
            cursor += 1
        }
        let candidate = String(name)
        guard cursor + 1 < scalars.count, scalars[cursor] == "}", scalars[cursor + 1] == "}",
            SnippetVariable.isValidName(candidate)
        else {
            index += 1
            continue
        }
        names.append(candidate)
        index = cursor + 2
    }
    return names
}

/// The `{{NAME}}` placeholders in `command` that no declaration carries, in
/// the order they appear, without repeats.
///
/// A declaration whose placement is the ENVIRONMENT counts as a
/// declaration here. The sentence this feeds says the name is not declared,
/// and for such a name that would be false — the mistake it makes is a
/// different one, and naming it wrongly is worse than not naming it. (It is
/// a real gap: `{{DB}}` for an environment declaration is left standing by
/// `resolve` exactly like an undeclared one, and nothing says so. Recorded
/// in the branch report rather than fixed here, because a second sentence
/// is a design decision, not a rename.)
func snippetUndeclaredPlaceholders(
    in command: String, variables: [SnippetVariable]
) -> [String] {
    let declared = Set(variables.map(\.name))
    var seen: Set<String> = []
    return snippetPlaceholderNames(in: command)
        .filter { !declared.contains($0) && seen.insert($0).inserted }
}

/// What the editor says about a `{{NAME}}` nothing declares, or `nil` when
/// there is none.
///
/// **A display, not a gate.** `SnippetVariableSubstitution` decides what
/// may be sent and none of that changed: an undeclared placeholder was
/// sendable before this sentence existed and stays sendable — it just goes
/// to the shell as the literal characters it is. Which is precisely why the
/// user is told: the command then does something other than what its author
/// believes, and until now nothing said so.
///
/// Every name at once rather than the first: unlike
/// `SnippetVariablesFault`, this sentence blocks nothing, so there is no
/// "fix this one, then see the next" to walk through.
func snippetUndeclaredPlaceholderHint(
    command: String, variables: [SnippetVariable]
) -> String? {
    let undeclared = snippetUndeclaredPlaceholders(in: command, variables: variables)
    guard !undeclared.isEmpty else { return nil }
    let quoted = undeclared
        .map { String(format: L10n.string("snippets.variables.quotedName %@", "“%@”"), $0) }
        .joined(separator: ", ")
    return String(
        format: L10n.string(
            "snippets.variables.undeclared %@",
            "Not declared as a variable: %@. Nothing is filled in there — the text goes to the shell exactly as it stands."),
        quoted)
}

/// The `{{NAME}}` placeholders in `command` whose declaration carries
/// `placement == .environment`, in declaration order (the `variables`
/// array), without repeats.
///
/// Declaration order rather than the order names appear in `command`: every
/// name in this list has a declaration to order by, unlike
/// `snippetUndeclaredPlaceholders`, where there is none. Disjoint from that
/// list by construction — a name here has a declaration, so it cannot be
/// undeclared, and a name there has none, so it cannot carry
/// `.environment` either. Which is also why this is a second function and
/// not a reworded `snippetUndeclaredPlaceholders`: "declared" is the wrong
/// word for `{{DB}}` when `DB` is an environment declaration — it IS
/// declared — but `resolve` still leaves the placeholder standing, because
/// an environment declaration is prepended as an assignment, not
/// substituted into the text. Naming that gap wrongly would be worse than
/// not naming it, which is why the undeclared sentence excludes it, and why
/// this one exists to say what actually happened instead.
func snippetEnvironmentPlaceholders(
    in command: String, variables: [SnippetVariable]
) -> [String] {
    let mentioned = Set(snippetPlaceholderNames(in: command))
    var seen: Set<String> = []
    return variables
        .filter { $0.placement == .environment && mentioned.contains($0.name) }
        .map(\.name)
        .filter { seen.insert($0).inserted }
}

/// What the editor says about a `{{NAME}}` that IS declared, but as an
/// environment variable, or `nil` when there is none.
///
/// **A display, not a gate**, for the same reason
/// `snippetUndeclaredPlaceholderHint` is one: `SnippetVariableSubstitution`
/// decides what may be sent and none of that changed. `{{DB}}` for an
/// environment declaration was left standing by `resolve` before this
/// sentence existed and stays left standing — it goes to the shell as the
/// literal characters it is, exactly like an undeclared placeholder does,
/// which is precisely why the user is told: the command then does
/// something other than what its author believes.
///
/// Every name at once rather than the first, for the same reason as the
/// sibling hint: this sentence blocks nothing, so there is no "fix this
/// one, then see the next" to walk through.
func snippetEnvironmentPlaceholderHint(
    command: String, variables: [SnippetVariable]
) -> String? {
    let environment = snippetEnvironmentPlaceholders(in: command, variables: variables)
    guard !environment.isEmpty else { return nil }
    let quoted = environment
        .map { String(format: L10n.string("snippets.variables.quotedName %@", "“%@”"), $0) }
        .joined(separator: ", ")
    return String(
        format: L10n.string(
            "snippets.variables.environmentPlaceholder %@",
            "Declared as an environment variable, not a placeholder: %@. Nothing is filled in there either — write it as $NAME to use the exported value."),
        quoted)
}
