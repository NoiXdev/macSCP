import Foundation
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
/// section while Save is disabled, and `ContentView` shows it in the alert
/// that refuses to run a snippet whose declarations never passed an editor
/// — an imported one. Two switches over the same enum would drift, and the
/// half that drifted would be the one nobody looks at.
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
                "“%@” isn't a plain argument of the command. macSCP can only keep a value safe there — take it out of the command name, a redirection target or a comment."),
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
