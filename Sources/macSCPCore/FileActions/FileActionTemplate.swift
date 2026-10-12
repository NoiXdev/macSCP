import Foundation

/// Whether an action can run at all, and on the sides it claims.
///
/// Everything here is a refusal the author sees in the editor before the
/// action is saved, so none of it is a run-time surprise.
public enum FileActionTemplate {
    public enum Problem: Equatable, Sendable {
        /// What `SnippetVariableSubstitution.firstDeclarationProblem`
        /// answered. It is always asked with the placement check ON: the
        /// third parameter defaults to `false` and is not passed here.
        case declaration(SnippetVariableSubstitution.Problem)
        /// A declared variable took one of the names the selection binds.
        case reservedVariableName(String)
        /// `.environment` placement prepends `export NAME='value';` as its
        /// own statement; the local path has no shell to run one in.
        case environmentPlacementIsNotRunnableLocally(variable: String)
        /// A local-capable action's command must be ONE simple command. An
        /// argv cannot interpret a pipeline or a redirection, and building
        /// one from a pipeline's words would drop the operator and run
        /// something else — silently.
        case notOneSimpleCommandForLocal
        /// `runsOn` is empty, so the action could never be offered anywhere.
        case noSideDeclared
        /// A reserved name that does not fit this action's selection form.
        /// `{{PATH}}` and `{{NAME}}` are one file's, so they need
        /// `.oncePerFile`; `{{PATHS}}` is the whole selection's, so it needs
        /// `.onceWithEveryPath`. `{{DIR}}` fits both, because a pane's
        /// listing never spans directories — `FileSearch` is "bounded
        /// strictly to the entries already loaded — no recursion into
        /// subdirectories".
        case reservedNameDoesNotFitTheForm(name: String, form: FileActionPerSelection)
    }

    /// Every name the selection supplies. A declared variable may not take
    /// one: it would have two sources, and for `PATH` with `.environment`
    /// placement it would overwrite the user's own `PATH` for the rest of
    /// that shell session.
    ///
    /// Four rather than three because the list has its own name. A single
    /// name meaning one file in one action and a list in another would read
    /// correctly while being written and change what a command does when
    /// the form is switched, with nothing on screen saying so.
    public static let reservedNames: Set<String> = ["PATH", "PATHS", "DIR", "NAME"]

    /// Which reserved names a selection form supplies.
    public static func names(fitting form: FileActionPerSelection) -> Set<String> {
        switch form {
        case .oncePerFile: return ["PATH", "DIR", "NAME"]
        case .onceWithEveryPath: return ["PATHS", "DIR"]
        }
    }

    /// The reserved names this command actually uses, as
    /// `SnippetVariable`s, so that the placement check covers them.
    ///
    /// **This is load-bearing, not bookkeeping.**
    /// `SnippetVariableSubstitution.firstDeclarationProblem` checks the
    /// placement of the variables it is GIVEN, and the selection-derived
    /// names are not declared by the author. Without synthesizing them, the
    /// position of `{{PATH}}` would never be checked -- and the position
    /// check is the whole of what stops a server-chosen name from being
    /// read as something other than one literal word.
    /// `PATHS` is included even though `FileActionPlanner` expands it
    /// before `resolve` is called rather than through `resolve`: a
    /// `{{PATHS}}` sitting inside quotes is exactly as wrong as a
    /// `{{PATH}}` there, so its POSITION is checked here either way.
    public static func syntheticVariables(for command: String) -> [SnippetVariable] {
        reservedNames.sorted()
            .filter { command.contains("{{\($0)}}") }
            .map {
                SnippetVariable(
                    name: $0, prompt: "", kind: .freeText, placement: .placeholder,
                    defaultValue: "", remembersLastValue: false)
            }
    }

    /// The first reason this action cannot run, or `nil`.
    public static func firstProblem(in action: FileAction) -> Problem? {
        if action.runsOn.isEmpty { return .noSideDeclared }

        for variable in action.variables where reservedNames.contains(variable.name) {
            return .reservedVariableName(variable.name)
        }

        let fitting = names(fitting: action.perSelection)
        for name in reservedNames.sorted()
        where !fitting.contains(name) && action.command.contains("{{\(name)}}") {
            return .reservedNameDoesNotFitTheForm(name: name, form: action.perSelection)
        }

        if action.runsOn.contains(.local) {
            for variable in action.variables where variable.placement == .environment {
                return .environmentPlacementIsNotRunnableLocally(variable: variable.name)
            }
            if !isOneSimpleCommand(action.command) {
                return .notOneSimpleCommandForLocal
            }
        }

        // The author's declarations AND the synthesized ones. The third
        // parameter of `firstDeclarationProblem` is `skipsPlacementCheck`,
        // it defaults to `false`, and it is deliberately not passed.
        if let problem = SnippetVariableSubstitution.firstDeclarationProblem(
            command: action.command,
            variables: action.variables + syntheticVariables(for: action.command))
        {
            return .declaration(problem)
        }
        return nil
    }

    /// Whether `command` is one simple command — no operator that begins a
    /// second command, and no redirection.
    ///
    /// Derived from `SnippetCommandSurvey`'s public reading rather than from
    /// a second tokenizer: the survey appends a span for every word and for
    /// a comment, and appends NONE for an operator (`|` and `&` are
    /// `advance()` then `beginCommand()`; a redirection operator is consumed
    /// by its own reader). So an operator is exactly a non-whitespace scalar
    /// that no span covers.
    ///
    /// Counting `.commandName` spans would have been the obvious derivation
    /// and it is wrong: an assignment prefix contributes `.commandName`
    /// spans of its own, which that placement's comment in the survey names
    /// in those terms.
    ///
    /// Where this is uncertain it refuses. An assignment prefix whose `=`
    /// falls outside a span reads as "not simple", and that is the right
    /// answer regardless — `VAR=x cmd` needs a shell, and an argv cannot
    /// express it.
    public static func isOneSimpleCommand(_ command: String) -> Bool {
        guard case .surveyed(let spans) = SnippetCommandSurvey.survey(command) else {
            return false
        }
        let scalars = command.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            defer { index = scalars.index(after: index) }
            if scalars[index].properties.isWhitespace { continue }
            let covered = spans.contains { $0.range.contains(index) }
            if !covered { return false }
        }
        return true
    }
}
