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
/// This file cuts no shell text itself: the remote line is assembled by
/// `SnippetVariableSubstitution.resolve`, and the local argv is cut along the
/// spans `SnippetCommandSurvey` reports. It is on `shellLexingFileNames` in
/// `SnippetCommandSurveyTests` all the same, because it asks scalar-level
/// questions of server-chosen values on their way into an argv, and so it is
/// held to that list's `Character` ban.
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
        /// `{{PATHS}}` stands inside a longer local word. It becomes
        /// several arguments, so it can only be a word of its own.
        case everyPathNeedsAWordOfItsOwn
        /// A selection-derived value holds U+0000. A POSIX path cannot, but
        /// an SFTP name is a length-prefixed string, so a hostile server can
        /// send one, and `execve` truncates an argument at the first NUL.
        /// The program would then run on a different file than the one the
        /// confirmation sheet displayed, and that sheet is the user's only
        /// check. Refused on the local path, the only one that spawns
        /// without a shell.
        case valueHoldsANulCharacter(name: String, value: String)
        /// A selection-derived value holds a C0 control character
        /// (U+0000 to U+001F) or DEL (U+007F). Refused on the REMOTE path.
        ///
        /// **Quoting cannot help, because the interpretation happens below
        /// the parser.** A single-line remote command is typed into the
        /// terminal as keystrokes, with no bracketed paste, so these bytes
        /// reach the line discipline and the line editor before any shell
        /// parses a quote. U+0015 (^U) kills the line typed so far, and the
        /// rest of the name then types a command of the server's choosing,
        /// whose trailing `#` comments out the stray closing quote; a tab
        /// triggers completion; a newline is Enter; DEL erases. The remote
        /// side's argument that every value is single-quoted never reached
        /// this layer.
        ///
        /// Only a SELECTION-derived value that the template places is
        /// refused HERE (`PATH`, `PATHS`, `DIR`, `NAME`), because this is
        /// the refusal that can only be made once a selection exists. The
        /// template's own command is refused one layer earlier, in the gate
        /// — `FileActionTemplate.Problem.commandHoldsAControlCharacter` —
        /// and that refusal is NOT about the author trusting themselves: an
        /// action can be imported, so a command is text out of somebody
        /// else's file. A prompted value is the user's own text, typed into
        /// the prompt sheet in this session, and is not refused anywhere.
        /// The confirmation sheet still draws these scalars as markers, as
        /// defence in depth and not as the control: a user recognising
        /// `<U+0015>` is not a security property.
        ///
        /// Scalars above U+007F are not covered, and whether they need to be
        /// has not been measured; see `holdsLineEditorControl`.
        ///
        /// This overlaps `valueHoldsANulCharacter` on U+0000 for a different
        /// reason on a different path (`execve` truncating an argument,
        /// there; a byte the line editor acts on, here). The overlap is
        /// deliberate and neither refusal subsumes the other: the local path
        /// accepts every other control character, because no line editor sits
        /// between an argv and a program.
        case valueHoldsAControlCharacter(name: String, value: String)
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
            for group in groups {
                if let refusal = controlCharacterRefusal(action, group) { return .failure(refusal) }
            }
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

    /// The first selection-derived value this group would place into a
    /// remote line that holds a C0 control character or DEL; see
    /// `Refusal.valueHoldsAControlCharacter` for why.
    ///
    /// Asked of the values the template PLACES, found with
    /// `SnippetVariableSubstitution.occurrences` as `resolve` finds them, so
    /// a name the template never uses reaches no shell and does not stop the
    /// action. Names are asked in sorted order, and `PATHS` item by item.
    ///
    /// **The names are read, not spelled**: the values are what
    /// `FileActionSelectionValues.values` binds, filtered by
    /// `FileActionTemplate.names(fitting:)` exactly as the local path does
    /// (`localReplacements`). A selection value added to either would reach
    /// this check by construction, instead of being quoted into a remote
    /// line with nothing asking about it.
    private static func controlCharacterRefusal(
        _ action: FileAction, _ group: [RemoteFileItem]
    ) -> Refusal? {
        guard !group.isEmpty else { return nil }
        let bound = FileActionSelectionValues.values(for: group[0])
        let fitting = FileActionTemplate.names(fitting: action.perSelection)
        func placed(_ name: String) -> Bool {
            !SnippetVariableSubstitution.occurrences(of: name, in: action.command).isEmpty
        }
        for name in bound.keys.sorted() where fitting.contains(name) && placed(name) {
            if let value = bound[name], holdsLineEditorControl(value) {
                return .valueHoldsAControlCharacter(name: name, value: value)
            }
        }
        if fitting.contains(listName), placed(listName) {
            for item in group {
                let itemPath = path(of: item)
                if holdsLineEditorControl(itemPath) {
                    return .valueHoldsAControlCharacter(name: listName, value: itemPath)
                }
            }
        }
        return nil
    }

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
        if !group.isEmpty {
            let bound = FileActionSelectionValues.values(for: group[0])
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
            ? SnippetVariableSubstitution.occurrences(of: listName, in: command) : []
        guard !listPositions.isEmpty else {
            return SnippetVariableSubstitution.resolve(
                command: command, variables: variables, values: values)
        }

        let list = group.map { PosixQuoting.singleQuoted(path(of: $0)) }.joined(separator: " ")
        // The list name is among the synthetic variables so that its position
        // was checked; here it is placed by hand, so `resolve` must not see it.
        let others = variables.filter { $0.name != listName }
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

    /// Where a local replacement's value came from.
    private enum Source: Equatable {
        /// The selection, and so the server. Carries the reserved name.
        case selection(name: String)
        /// The whole selection's list. Its value is expanded by the caller,
        /// because it is several arguments and not one.
        case everyPath
        /// A prompted value: text the user typed.
        case typed
    }

    /// One value that goes into a local argument, found in the template.
    private struct Replacement {
        let range: Range<String.Index>
        let value: String
        let source: Source
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
        // The gate refuses a template the survey cannot read before this runs,
        // so the reason is carried through only so that a disagreement between
        // the two shows which construct stopped the reading.
        let spans: [SnippetCommandSurvey.Span]
        switch SnippetCommandSurvey.survey(action.command) {
        case .surveyed(let read):
            spans = read
        case .refused(let refusal):
            return .failure(.template(.declaration(.unanalyzableContext(kind: refusal))))
        }
        guard spans.allSatisfy({ $0.placement != .quoted }) else {
            return .failure(.template(.quotingIsNotRunnableLocally))
        }
        guard FileActionTemplate.isOneSimpleCommand(action.command) else {
            return .failure(.template(.notOneSimpleCommandForLocal))
        }
        // A comment is covered by a span and so counts as part of one simple
        // command. It is not a word.
        let words = spans.filter { $0.placement != .comment }
        guard !words.isEmpty, words[0].placement == .commandName else {
            return .failure(.template(.notOneSimpleCommandForLocal))
        }
        // Two spans in one word would mean a split the checks above refuse.
        for (before, after) in zip(words, words.dropFirst())
        where before.range.upperBound >= after.range.lowerBound {
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
            // The list is every path as its own argument, so it can only be
            // a word of its own.
            if !inside.filter({ $0.source == .everyPath }).isEmpty {
                guard inside.count == 1, inside[0].range == word.range else {
                    return .failure(.everyPathNeedsAWordOfItsOwn)
                }
                for item in group {
                    let itemPath = path(of: item)
                    if holdsNul(itemPath) {
                        return .failure(.valueHoldsANulCharacter(name: listName, value: itemPath))
                    }
                }
                arguments.append(contentsOf: group.map { path(of: $0) })
                continue
            }

            var assembled = String.UnicodeScalarView()
            // Which replacement supplied the word's first scalar, if one did:
            // the author's own text before it means the word begins with
            // something the author wrote.
            var leader: Replacement?
            var leaderKnown = false
            var cursor = word.range.lowerBound
            for replacement in inside {
                // Skips a replacement that starts before the last one ended.
                // That IS reachable: nothing stops an author declaring one
                // variable name twice, and neither gate rejects it, so the
                // template then holds two identical ranges for it.
                // `resolve` has the same guard in its own assembly loop.
                guard replacement.range.lowerBound >= cursor else { continue }
                if case .selection(let name) = replacement.source,
                    holdsNul(replacement.value)
                {
                    return .failure(
                        .valueHoldsANulCharacter(name: name, value: replacement.value))
                }
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
            if let leader, case .selection(let name) = leader.source,
                beginsWithHyphen(assembled)
            {
                return .failure(.valueWouldBeReadAsAnOption(name: name, value: leader.value))
            }
            arguments.append(String(assembled))
        }
        return .success(
            FileActionInvocation(
                executable: String(scalars[words[0].range]), arguments: arguments))
    }

    /// Every placeholder in the template that has a value, with its value,
    /// in template order. Found on the ORIGINAL command, so no value is ever
    /// read for a placeholder.
    ///
    /// The list is recorded with an empty value; the caller expands it.
    private static func localReplacements(
        _ action: FileAction, _ group: [RemoteFileItem], _ promptedValues: [String: String]
    ) -> [Replacement] {
        var found: [Replacement] = []
        let command = action.command
        if !group.isEmpty {
            let fitting = FileActionTemplate.names(fitting: action.perSelection)
            for (name, value) in FileActionSelectionValues.values(for: group[0])
            where fitting.contains(name) {
                for range in SnippetVariableSubstitution.occurrences(of: name, in: command) {
                    found.append(
                        Replacement(range: range, value: value, source: .selection(name: name)))
                }
            }
        }
        if action.perSelection == .onceWithEveryPath {
            for range in SnippetVariableSubstitution.occurrences(of: listName, in: command) {
                found.append(Replacement(range: range, value: "", source: .everyPath))
            }
        }
        // Declared variables, as `resolve` treats them: an invalid name is
        // skipped and a missing value is the empty string. A prompted key
        // that no variable declares is not a placeholder of anything.
        for variable in action.variables
        where SnippetVariable.isValidName(variable.name) && variable.placement == .placeholder {
            let value = promptedValues[variable.name] ?? ""
            for range in SnippetVariableSubstitution.occurrences(of: variable.name, in: command) {
                found.append(Replacement(range: range, value: value, source: .typed))
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The name of the whole selection's list.
    private static let listName = "PATHS"

    /// The absolute path of `item`, normalized as the other selection values
    /// are.
    ///
    /// A missing `PATH` stops the process rather than becoming an empty
    /// string, which would put an empty element into an argv or a quoted
    /// `''` into a command, silently. `FileActionSelectionValues.values`
    /// binds all of its keys for every item, so this is a violated
    /// invariant and not a state a listing can produce; the duplicate
    /// declaration above is different, because an author can write it.
    private static func path(of item: RemoteFileItem) -> String {
        guard let path = FileActionSelectionValues.values(for: item)["PATH"] else {
            preconditionFailure("FileActionSelectionValues.values(for:) did not bind PATH")
        }
        return path
    }

    /// Whether the first scalar of `scalars` is a hyphen. Asked of the
    /// scalars and not of a `String`, whose first element is a `Character`:
    /// a hyphen followed by a combining mark is one `Character` that is not
    /// `-`, while a tool reads the bytes and sees an option.
    private static func beginsWithHyphen(_ scalars: String.UnicodeScalarView) -> Bool {
        for scalar in scalars { return scalar == "-" }
        return false
    }

    /// Whether `value` holds a scalar in U+0000 to U+001F, or U+007F, asked
    /// scalar by scalar.
    ///
    /// **Scalars above U+007F are NOT covered, and whether that is safe has
    /// not been measured.** The actor at a shell prompt is the shell's own
    /// line editor, not the terminal's line discipline, and readline's
    /// defaults (`input-meta` off, `convert-meta` on whenever the locale's
    /// codeset is not eight-bit) can turn a high scalar into a control or
    /// an `ESC`-prefixed command. A server with no generated locales gives
    /// exactly that codeset, and macSCP sends no `LANG` or `LC_*` with the
    /// shell channel. So whether a remote line editor takes U+0080 and above
    /// literally is an open question, not a settled one; this function's
    /// range is where the boundary stands today and nothing more.
    private static func holdsLineEditorControl(_ value: String) -> Bool {
        for scalar in value.unicodeScalars where scalar.value <= 0x1F || scalar.value == 0x7F {
            return true
        }
        return false
    }

    /// Whether `value` holds U+0000, asked scalar by scalar.
    private static func holdsNul(_ value: String) -> Bool {
        for scalar in value.unicodeScalars where scalar == "\u{0}" { return true }
        return false
    }
}
