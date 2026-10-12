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
    /// Three plus the list name, because the list has its own. A single
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
            .filter { uses($0, in: command) }
            .map {
                SnippetVariable(
                    name: $0, prompt: "", kind: .freeText, placement: .placeholder,
                    defaultValue: "", remembersLastValue: false)
            }
    }

    /// Whether `command` contains `{{name}}`, asked of the one finder the
    /// substitution itself uses. `String.contains` would not do: it compares
    /// by `Character`, and a combining mark after the closing braces fuses
    /// with the last `}`, so a cluster search misses a placeholder that the
    /// scalar-based finder, at resolve time, does find and fill. A gate that
    /// searched differently from the emitter could pass a template whose
    /// server-chosen name then lands somewhere nothing checked.
    private static func uses(_ name: String, in command: String) -> Bool {
        !SnippetVariableSubstitution.occurrences(of: name, in: command).isEmpty
    }

    /// The first reason this action cannot run, or `nil`.
    public static func firstProblem(in action: FileAction) -> Problem? {
        if action.runsOn.isEmpty { return .noSideDeclared }

        for variable in action.variables where reservedNames.contains(variable.name) {
            return .reservedVariableName(variable.name)
        }

        let fitting = names(fitting: action.perSelection)
        for name in reservedNames.sorted()
        where !fitting.contains(name) && uses(name, in: action.command) {
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
    /// second command, no redirection, and no assignment prefix.
    ///
    /// Derived from `SnippetCommandSurvey`'s public reading rather than from
    /// a second tokenizer. The survey appends a span for every word and for
    /// a comment, and appends none for an operator (`|` and `&` are
    /// `advance()` then `beginCommand()`; a redirection operator is consumed
    /// by its own reader) nor for a line feed, which it treats as a command
    /// separator. So an operator is an uncovered scalar that is not a blank
    /// or a tab. Those two are skipped by `ShellScalar.isBlank` and by
    /// nothing wider: that file says "Shell lexing must use `isBlank`", and
    /// the wider Unicode whitespace test would skip the line feed too.
    ///
    /// Coverage is a test for the absence of an operator, not a definition
    /// of one: it can refuse a command that is in fact one simple command,
    /// because the survey leaves some ordinary text uncovered — a plain
    /// `$NAME`, and a backslash with the scalar it escapes. `ls $HOME` and `ls my\ file` are therefore refused. That is
    /// the safe direction for the local side, because an argv does no
    /// expansion and no unescaping.
    ///
    /// Counting `.commandName` spans would have been the obvious derivation
    /// and it is wrong: an assignment prefix contributes `.commandName`
    /// spans of its own.
    ///
    /// An assignment prefix is refused by looking at exactly that: the
    /// survey closes the literal run `VAR=` as one `.commandName` span, so
    /// the `=` is covered, and the coverage test alone accepts
    /// `VAR=x cmd`. A `.commandName` span that contains `=` is refused
    /// instead, wherever the prefix sits. `--flag=x` is an `.argument` and
    /// is not touched. `VAR=x cmd` needs a shell, and an argv built from it
    /// would run a binary named `VAR=x`.
    ///
    /// A trailing comment is covered by a `.comment` span, so
    /// `wc -l {{PATH}} # note` counts as one simple command. That is right
    /// as shell, but whoever builds an argv from the words must drop the
    /// comment spans.
    public static func isOneSimpleCommand(_ command: String) -> Bool {
        guard case .surveyed(let spans) = SnippetCommandSurvey.survey(command) else {
            return false
        }
        let scalars = command.unicodeScalars
        for span in spans where span.placement == .commandName {
            if scalars[span.range].contains { scalar in scalar == "=" } { return false }
        }
        var scalarIndex = scalars.startIndex
        while scalarIndex < scalars.endIndex {
            defer { scalarIndex = scalars.index(after: scalarIndex) }
            if ShellScalar.isBlank(scalars[scalarIndex]) { continue }
            let covered = spans.contains { span in span.range.contains(scalarIndex) }
            if !covered { return false }
        }
        return true
    }
}
