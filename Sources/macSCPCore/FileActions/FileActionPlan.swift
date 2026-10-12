import Foundation

/// One direct spawn. There is no shell on this path, so there is no quoting
/// and shell injection is not prevented but impossible; the only way a value
/// can stop being a value here is by being read as an option, and
/// `FileActionPlanner` refuses that rather than guessing a `./` prefix.
public struct FileActionInvocation: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

/// What will run, in order.
public enum FileActionPlan: Equatable, Sendable {
    /// Lines to type into the session's shell. More than one only for
    /// `.oncePerFile`. The shell runs them in order and **a failure does not
    /// stop the rest**: nothing here reads the shell's output, so nothing
    /// here has anything to decide on.
    case shellLines([String])
    /// Direct spawns, in order.
    case invocations([FileActionInvocation])
}

/// Turns an action plus a selection into the thing that will run.
///
/// **This is the one place server data becomes something that runs.** Every
/// value a selection supplies came out of a directory listing, so it is
/// whatever a server (or whoever put a file on it) chose to call a file.
///
/// Two rules hold the whole type, and both are about substitution being ONE
/// PASS over the template's own text:
///
/// - A value is never scanned for placeholders after it has been placed. A
///   file called `{{DIR}}` is a file called `{{DIR}}`.
/// - A placeholder is found with `SnippetVariableSubstitution.occurrences`,
///   which reads one `Unicode.Scalar` at a time. `String.contains` and
///   `replacingOccurrences` compare `Character`s and miss a placeholder
///   followed by a combining mark; see `ShellScalar`.
///
/// This file lexes no shell text. The remote line is assembled by
/// `SnippetVariableSubstitution.resolve`, and the local argv is cut along the
/// spans `SnippetCommandSurvey` reports.
public enum FileActionPlanner {
    public enum Refusal: Error, Equatable, Sendable {
        case template(FileActionTemplate.Problem)
        case sideNotDeclared(BrowserPaneSide)
        /// An empty selection. Reported rather than returned as an empty
        /// list, which a caller would read as "planned, nothing to do".
        case nothingToRun
        /// A selection-derived value would be the first thing in a local
        /// argument and begins with `-`, so a tool would read it as an
        /// option. Only `{{NAME}}` can reach this: `{{PATH}}`, `{{DIR}}` and
        /// `{{PATHS}}` are absolute.
        case valueWouldBeReadAsAnOption(name: String, value: String)
        /// A local-capable template holds quoting. The argv is cut along
        /// the survey's word spans, and a quoted span is not one: it would
        /// have to be unquoted, and nothing on this path interprets quoting.
        case quotingIsNotRunnableLocally
        /// `{{PATHS}}` stands inside a longer local word. It becomes
        /// several arguments, so it can only be a word of its own.
        case everyPathNeedsAWordOfItsOwn
    }

    public static func plan(
        action: FileAction, selection: [RemoteFileItem], side: BrowserPaneSide,
        promptedValues: [String: String] = [:]
    ) -> Result<FileActionPlan, Refusal> {
        if let problem = FileActionTemplate.firstProblem(in: action) {
            return .failure(.template(problem))
        }
        guard action.runsOn.contains(side) else { return .failure(.sideNotDeclared(side)) }
        guard !selection.isEmpty else { return .failure(.nothingToRun) }

        let groups: [[RemoteFileItem]]
        switch action.perSelection {
        case .oncePerFile: groups = selection.map { [$0] }
        case .onceWithEveryPath: groups = [selection]
        }

        switch side {
        case .remote:
            return .success(.shellLines(groups.map { remoteLine(action, $0, promptedValues) }))
        case .local:
            var invocations: [FileActionInvocation] = []
            for group in groups {
                switch localInvocation(action, group, promptedValues) {
                case .success(let invocation): invocations.append(invocation)
                case .failure(let refusal): return .failure(refusal)
                }
            }
            return .success(.invocations(invocations))
        }
    }

    // MARK: - Remote

    /// `{{PATHS}}` is not a value `resolve` can place: it substitutes one
    /// single-quoted value per name, and a list is not one value.
    ///
    /// It is not expanded into the command BEFORE `resolve` either, which is
    /// the obvious way and the wrong one. `resolve` would then scan the
    /// expanded text for the other placeholders, and a path that spells one
    /// (`/tmp/$(id)/{{DIR}}` is a legal file name) would be substituted
    /// inside the quotes of its own list entry — closing them, and leaving
    /// whatever else the value holds unquoted. So the command is cut at each
    /// `{{PATHS}}`, every piece is resolved on its own, and the list is
    /// joined in between, after resolution, where nothing reads it again.
    private static func remoteLine(
        _ action: FileAction, _ group: [RemoteFileItem], _ promptedValues: [String: String]
    ) -> String {
        var values = promptedValues
        if let first = group.first {
            let bound = FileActionSelectionValues.values(for: first)
            switch action.perSelection {
            case .oncePerFile:
                values.merge(bound) { _, new in new }
            case .onceWithEveryPath:
                // Only `DIR` is well defined for a whole selection, and every
                // item shares it: a pane's listing never spans directories.
                values["DIR"] = bound["DIR"]
            }
        }
        let command = action.command
        let variables = action.variables + FileActionTemplate.syntheticVariables(for: command)

        let listPositions = action.perSelection == .onceWithEveryPath
            ? SnippetVariableSubstitution.occurrences(of: "PATHS", in: command) : []
        guard !listPositions.isEmpty else {
            return SnippetVariableSubstitution.resolve(
                command: command, variables: variables, values: values)
        }

        let list = group.map { PosixQuoting.singleQuoted(path(of: $0)) }.joined(separator: " ")
        // `PATHS` is among the synthetic variables so that its position was
        // checked; here it is placed by hand, so `resolve` must not see it.
        let others = variables.filter { $0.name != "PATHS" }
        let placeholders = others.filter { $0.placement == .placeholder }
        let environment = others.filter { $0.placement == .environment }

        // Environment variables are one `export` statement each AHEAD of the
        // whole line, so they are emitted once, from an empty body.
        var line = SnippetVariableSubstitution.resolve(
            command: "", variables: environment, values: values)
        let scalars = command.unicodeScalars
        var cursor = scalars.startIndex
        for position in listPositions {
            line += SnippetVariableSubstitution.resolve(
                command: String(scalars[cursor..<position.lowerBound]),
                variables: placeholders, values: values)
            line += list
            cursor = position.upperBound
        }
        line += SnippetVariableSubstitution.resolve(
            command: String(scalars[cursor...]), variables: placeholders, values: values)
        return line
    }

    // MARK: - Local

    /// One value that goes into a local argument, found in the template.
    private struct Replacement {
        let range: Range<String.Index>
        let value: String
        /// The reserved name, when the value came from the selection and so
        /// from the server; `nil` for a value the user typed.
        let selectionName: String?
    }

    /// The argv is cut along the survey's word spans, not along whitespace.
    ///
    /// Splitting on `Character.isWhitespace` would also split at U+00A0 and
    /// at the other blanks a shell does not treat as word breaks, and would
    /// have to be re-derived for a comment. A template that passes the checks
    /// below has exactly one non-comment span per word, because the survey
    /// ends a span at a blank or at a construct that is refused here
    /// (quoting, an escape, an expansion, an operator).
    private static func localInvocation(
        _ action: FileAction, _ group: [RemoteFileItem], _ promptedValues: [String: String]
    ) -> Result<FileActionInvocation, Refusal> {
        // Checked again here rather than trusted from the gate: this is the
        // function that is about to spawn, and it must not depend on a
        // property that only `firstProblem` establishes.
        guard case .surveyed(let spans) = SnippetCommandSurvey.survey(action.command) else {
            return .failure(.template(.notOneSimpleCommandForLocal))
        }
        guard spans.allSatisfy({ $0.placement != .quoted }) else {
            return .failure(.quotingIsNotRunnableLocally)
        }
        guard FileActionTemplate.isOneSimpleCommand(action.command) else {
            return .failure(.template(.notOneSimpleCommandForLocal))
        }
        // A comment is covered by a span and so counts as part of one simple
        // command. It is not a word.
        let words = spans.filter { $0.placement != .comment }
        // Two spans in one word would mean a split the checks above refuse.
        let adjacent = zip(words, words.dropFirst()).contains {
            $0.range.upperBound >= $1.range.lowerBound
        }
        guard let program = words.first, program.placement == .commandName, !adjacent else {
            return .failure(.template(.notOneSimpleCommandForLocal))
        }

        let scalars = action.command.unicodeScalars
        let replacements = localReplacements(action, group, promptedValues)

        // The program is the template's own text, never a substituted word.
        // The gate refuses a placeholder there; leaving the text alone means
        // that a gate which ever stopped refusing it would produce a program
        // called `{{NAME}}` rather than one a server named.
        var arguments: [String] = []
        for word in words.dropFirst() {
            let inside = replacements.filter {
                word.range.lowerBound <= $0.range.lowerBound
                    && $0.range.upperBound <= word.range.upperBound
            }
            // `{{PATHS}}` alone in its word is every path as its own
            // argument; the list is told apart from a value by its being
            // the only replacement that is not for one file.
            if inside.count == 1, let only = inside.first, only.range == word.range,
                only.selectionName == "PATHS"
            {
                arguments.append(contentsOf: group.map { path(of: $0) })
                continue
            }
            if inside.contains(where: { $0.selectionName == "PATHS" }) {
                return .failure(.everyPathNeedsAWordOfItsOwn)
            }

            var assembled = String.UnicodeScalarView()
            // Which replacement supplied the word's first scalar, if one did:
            // the author's own text before it means the word begins with
            // something the author wrote.
            var leader: Replacement?
            var leaderKnown = false
            var cursor = word.range.lowerBound
            for replacement in inside {
                assembled.append(contentsOf: scalars[cursor..<replacement.range.lowerBound])
                if !assembled.isEmpty, !leaderKnown { leaderKnown = true }
                assembled.append(contentsOf: replacement.value.unicodeScalars)
                if !assembled.isEmpty, !leaderKnown {
                    leaderKnown = true
                    leader = replacement
                }
                cursor = replacement.range.upperBound
            }
            assembled.append(contentsOf: scalars[cursor..<word.range.upperBound])
            if let leader, let name = leader.selectionName, assembled.first == "-" {
                return .failure(.valueWouldBeReadAsAnOption(name: name, value: leader.value))
            }
            arguments.append(String(assembled))
        }
        return .success(
            FileActionInvocation(
                executable: String(scalars[program.range]), arguments: arguments))
    }

    /// Every placeholder in the template that has a value, with its value,
    /// in template order. Found on the ORIGINAL command, so no value is ever
    /// read for a placeholder.
    ///
    /// `{{PATHS}}` is recorded with the name `PATHS` and an empty value; the
    /// caller expands it, because it is several arguments and not one.
    private static func localReplacements(
        _ action: FileAction, _ group: [RemoteFileItem], _ promptedValues: [String: String]
    ) -> [Replacement] {
        var found: [Replacement] = []
        let command = action.command
        if let first = group.first {
            let fitting = FileActionTemplate.names(fitting: action.perSelection)
            for (name, value) in FileActionSelectionValues.values(for: first)
            where fitting.contains(name) {
                for range in SnippetVariableSubstitution.occurrences(of: name, in: command) {
                    found.append(Replacement(range: range, value: value, selectionName: name))
                }
            }
        }
        if action.perSelection == .onceWithEveryPath {
            for range in SnippetVariableSubstitution.occurrences(of: "PATHS", in: command) {
                found.append(Replacement(range: range, value: "", selectionName: "PATHS"))
            }
        }
        // Declared variables, as `resolve` treats them: an invalid name is
        // skipped and a missing value is the empty string. A prompted key
        // that no variable declares is not a placeholder of anything.
        for variable in action.variables
        where SnippetVariable.isValidName(variable.name) && variable.placement == .placeholder {
            let value = promptedValues[variable.name] ?? ""
            for range in SnippetVariableSubstitution.occurrences(of: variable.name, in: command) {
                found.append(Replacement(range: range, value: value, selectionName: nil))
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The absolute path of `item`, normalized as the other selection values
    /// are.
    private static func path(of item: RemoteFileItem) -> String {
        FileActionSelectionValues.values(for: item)["PATH"] ?? ""
    }
}
