import Foundation
import macSCPCore

// Presentation for the file-action editor and its management sheet: the
// decisions the views render, held away from them because no test in this
// project draws a SwiftUI view.

/// The last read of the actions store, as the OUTCOME and not just a list, so
/// an unreadable file cannot be shown as "no file actions yet" — the same
/// reasoning as `SnippetsLoad`. Nothing is lost in that state: `save` and
/// `remove` read the file first and throw too, so no write lands on top of it.
enum FileActionsLoad: Equatable {
    case loaded([FileAction])
    case unreadable

    /// Reads `store` once. The error is not carried: a decoder's description
    /// is not a user-facing sentence, and an action's own text could appear
    /// in it.
    init(reading store: FileActionStore) {
        if let actions = try? store.all() {
            self = .loaded(actions)
        } else {
            self = .unreadable
        }
    }

    /// The actions to list — empty for `.unreadable`, so a caller that only
    /// enumerates needs no special case. A caller that would otherwise CLAIM
    /// there are none must check `isUnreadable` instead.
    var actions: [FileAction] {
        switch self {
        case .loaded(let actions): return actions
        case .unreadable: return []
        }
    }

    var isUnreadable: Bool { self == .unreadable }
}

// MARK: - The gate's refusals, as sentences

/// The sentence for one refusal of `FileActionTemplate.firstProblem`.
///
/// Every case has its own, and each says what to do and not only what is
/// wrong. No `default`: a case added to the enum must fail to compile here,
/// not fall into a sentence written for another case.
///
/// **Names are interpolated through `FileActionPlanDisplay.visible`.** The
/// editor shows the author's own draft, but the same sentences are shown for
/// an action refused on IMPORT, where a declared variable's name is text
/// from a file; a name carrying a bidirectional override or a line break
/// must not rearrange or hide the sentence around it.
func fileActionProblemText(for problem: FileActionTemplate.Problem) -> String {
    switch problem {
    case .declaration(let inner):
        return fileActionDeclarationText(for: inner)
    case .reservedVariableName(let name):
        return String(
            format: L10n.string(
                "fileAction.problem.reservedName",
                "“%@” is a name the selected file supplies, so it can't also be asked for. Rename the variable, or delete it and use the placeholder as it is."),
            FileActionPlanDisplay.visible(name))
    case .environmentPlacementIsNotRunnableLocally(let variable):
        return String(
            format: L10n.string(
                "fileAction.problem.environmentLocal",
                "“%@” is passed as an environment variable, which needs a shell, and this action also runs in the local pane, where there is none. Make it a placeholder in the command, or switch off the local pane."),
            FileActionPlanDisplay.visible(variable))
    case .notOneSimpleCommandForLocal:
        return L10n.string(
            "fileAction.problem.notOneCommand",
            "An action that runs in the local pane is one command, with no pipe, no redirection and no second line, because nothing there interprets them. Simplify the command, or switch off the local pane.")
    case .noSideDeclared:
        return L10n.string(
            "fileAction.problem.noSide",
            "Choose where this action runs: in the remote pane, in the local pane, or in both.")
    case .reservedNameDoesNotFitTheForm(let name, let form):
        return fileActionFormMismatchText(name: name, form: form)
    case .quotingIsNotRunnableLocally:
        return L10n.string(
            "fileAction.problem.quotingLocal",
            "Quotes can't be used in an action that runs in the local pane, because nothing there interprets them. Take the quotes out, or switch off the local pane.")
    }
}

/// The three `SnippetVariableSubstitution.Problem` cases about where a
/// placeholder stands get the sentence written for actions; the rest are
/// about the declarations or about the command as a whole and are the
/// snippet editor's own sentences, shared rather than worded twice. Names go
/// through `FileActionPlanDisplay.visible` before either path sees them.
private func fileActionDeclarationText(for problem: SnippetVariableSubstitution.Problem) -> String {
    switch problem {
    case .placeholderInsideQuotes(let name), .placeholderNotInArgumentPosition(let name):
        return String(
            format: L10n.string(
                "fileAction.problem.declaration",
                "“%@” stands where a value may not. A placeholder has to be a plain, unquoted argument of the command: take it out of quotes, out of the command name, and out of redirections and comments."),
            FileActionPlanDisplay.visible(name))
    case .invalidName(let name):
        return snippetVariableProblemText(
            for: .invalidName(name: FileActionPlanDisplay.visible(name)))
    case .unusedPlaceholder(let name):
        return snippetVariableProblemText(
            for: .unusedPlaceholder(name: FileActionPlanDisplay.visible(name)))
    case .placeholderIsReparsedByItsCommand(let name):
        return snippetVariableProblemText(
            for: .placeholderIsReparsedByItsCommand(name: FileActionPlanDisplay.visible(name)))
    case .unanalyzableContext:
        return snippetVariableProblemText(for: problem)
    }
}

/// Which name fits which form, naming the other one: `{{PATH}}` for once per
/// file and `{{PATHS}}` for once for the whole selection. An author who meets
/// this has written the right idea with the wrong name, so the sentence says
/// the name to write.
///
/// The replacement is spelled here, because "the path placeholder of the
/// other form" has no derivation from `FileActionTemplate.names(fitting:)`
/// (a per-file form has two single-file names, `PATH` and `NAME`, and no rule
/// says which one an author who wrote `PATHS` meant). It is pinned instead:
/// `FileActionsPresentationTests` asks that the name the sentence gives is a
/// member of the set the gate says fits the form, for both forms.
private func fileActionFormMismatchText(
    name: String, form: FileActionPerSelection
) -> String {
    let replacement: String
    switch form {
    case .oncePerFile:
        // `PATHS` is the whole selection's; the per-file counterpart of a
        // path is `PATH`.
        replacement = "PATH"
    case .onceWithEveryPath:
        // `PATH` and `NAME` are one file's; the whole selection's path
        // list is `PATHS`.
        replacement = "PATHS"
    }
    return String(
        format: L10n.string(
            "fileAction.problem.formMismatch",
            "%1$@ doesn't fit an action that runs %3$@. Write %2$@ instead, or change how the action runs."),
        "{{\(FileActionPlanDisplay.visible(name))}}", "{{\(replacement)}}",
        fileActionFormPhrase(form))
}

/// How the form reads inside a sentence, which is the picker's label in
/// lower case. One source for both, so the picker and the sentence cannot
/// name a form differently.
func fileActionFormPhrase(_ form: FileActionPerSelection) -> String {
    fileActionFormLabel(form).lowercased()
}

func fileActionFormLabel(_ form: FileActionPerSelection) -> String {
    switch form {
    case .oncePerFile:
        return L10n.string("fileAction.editor.form.perFile", "Once per file")
    case .onceWithEveryPath:
        return L10n.string("fileAction.editor.form.everyPath", "Once for the whole selection")
    }
}

/// The sentence for an imported action that was not stored. A refusal by the
/// gate reads as the editor would have read it.
func fileActionImportReasonText(for reason: FileActionAuthoring.Reason) -> String {
    switch reason {
    case .template(let problem):
        return fileActionProblemText(for: problem)
    case .emptyName:
        return L10n.string(
            "fileAction.import.refused.emptyName", "It has no name.")
    }
}

// MARK: - Import and export

/// The body of the "Import Complete" alert: how many actions landed, how many
/// were already there, and which were refused and why.
///
/// The refused names are text from the file and go through
/// `FileActionPlanDisplay.visible`.
func fileActionImportResultText(
    review: FileActionAuthoring.ImportReview, storeFailures: Int
) -> String {
    var lines = [String(format: L10n.string(
        "fileAction.import.result.added", "Imported: %lld"), review.accepted.count - storeFailures)]
    if review.alreadyPresent > 0 {
        lines.append(String(format: L10n.string(
            "fileAction.import.result.present", "Already there: %lld"),
            review.alreadyPresent))
    }
    if storeFailures > 0 {
        lines.append(String(format: L10n.string(
            "import.result.storeFailures %lld", "Not saved due to an error: %lld"),
            storeFailures))
    }
    if !review.refused.isEmpty {
        lines.append(String(format: L10n.string(
            "fileAction.import.result.refused", "Not imported: %lld"),
            review.refused.count))
        for refused in review.refused {
            lines.append(String(format: L10n.string(
                "fileAction.import.result.refusedLine", "• “%1$@”: %2$@"),
                FileActionPlanDisplay.visible(refused.name),
                fileActionImportReasonText(for: refused.reason)))
        }
    }
    return lines.joined(separator: "\n")
}

/// Maps what `FileActionExportCodec.probe` and `.decode` throw to the
/// sentence the user reads. A thrown `.notAnExportFile` is the answer for a
/// file of another kind — a snippets, sessions or logins export — because
/// `probe` answers whether the file is ENCRYPTED and throws for a foreign
/// one; this format has no password, so an encrypted claim is refused with
/// the same generic sentence.
func fileActionImportErrorText(for error: SessionExportError) -> String {
    switch error {
    case .unsupportedVersion:
        return L10n.string(
            "import.error.newerVersion",
            "This file was created by a newer version of macSCP.")
    case .notAnExportFile, .passwordRequired, .wrongPasswordOrCorrupted, .randomnessUnavailable:
        return L10n.string(
            "fileAction.import.error",
            "This file couldn't be read as macSCP file actions. It may be a different kind of export, or damaged.")
    }
}

// MARK: - The rows

/// The sides an action runs on, as the pane names the app already shows
/// (`browser.paneLocal`, `browser.paneRemote`), in declaration order.
func fileActionSidesText(_ runsOn: Set<BrowserPaneSide>) -> String {
    BrowserPaneSide.allCases.filter(runsOn.contains).map { side in
        switch side {
        case .local: return L10n.string("browser.paneLocal", "Local")
        case .remote: return L10n.string("browser.paneRemote", "Remote")
        }
    }.joined(separator: " · ")
}

/// A stored action the gate refuses is not offered in any menu. It can only
/// have got into the store by a hand-edited file (the editor and the import
/// both refuse it), so the list says so rather than leaving the user to
/// wonder why it never appears.
func fileActionNotOfferedText(for problem: FileActionTemplate.Problem) -> String {
    String(format: L10n.string(
        "fileAction.sheet.notOffered", "Not offered in the menu: %@"),
        fileActionProblemText(for: problem))
}

// MARK: - The editor's preview

/// The files a preview acts on. A per-file action is shown on one, an
/// every-path action on two, so the list form is visible. Fixed sample
/// names: they stand for nothing the server said.
func fileActionPreviewSelection(for form: FileActionPerSelection) -> [RemoteFileItem] {
    let report = RemoteFileItem(name: "report.txt", path: "/home/user/report.txt", kind: .file)
    let notes = RemoteFileItem(name: "notes.md", path: "/home/user/notes.md", kind: .file)
    switch form {
    case .oncePerFile: return [report]
    case .onceWithEveryPath: return [report, notes]
    }
}

/// The value a preview gives a declared variable: its default, else the
/// first option of a choice, else a neutral word. The point is that the
/// preview reads like a finished command, not that the value is meaningful.
func fileActionPreviewValue(for variable: SnippetVariable) -> String {
    if !variable.defaultValue.isEmpty { return variable.defaultValue }
    if case .selection(let options) = variable.kind, let first = options.first { return first }
    return L10n.string("snippets.editor.preview.sample", "sample")
}
