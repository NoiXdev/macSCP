import Foundation

/// Turning a snippet's template into the command that actually runs.
///
/// Pure: values in, resolved command out. Nothing here talks to a store, a
/// terminal or a view — which is what makes the quoting, the one part where
/// a wrong answer turns data into code, fully testable.
public enum SnippetVariableSubstitution {
    /// What is wrong with a set of declarations, if anything.
    public enum Problem: Equatable, Sendable {
        /// A name that is not a POSIX shell identifier
        /// (`SnippetVariable.isValidName`). For `.environment` such a name
        /// would not produce an assignment at all but extra commands —
        /// `A;touch /tmp/m;B='v' echo hi` is three of them.
        case invalidName(name: String)
        /// `SnippetCommandSurvey` could not read the command far enough to
        /// say anything about a placeholder's position. Not an accusation
        /// and not a defect in the command: it is the stated limit of a
        /// recogniser that refuses whatever it cannot survey.
        case unanalyzableContext(kind: Context)
        /// A placeholder declaration whose `{{NAME}}` appears nowhere: the
        /// user would be asked for a value that reaches nothing.
        case unusedPlaceholder(name: String)
        /// `echo "{{NAME}}"` — the value is already quoted by this type, so
        /// the surrounding quotes would both show up literally AND leave
        /// anything live in the value live.
        case placeholderInsideQuotes(name: String)
        /// The placeholder was reached but is not in the one position a
        /// single-quoted value survives: an unquoted argument of a
        /// top-level command. Command-name position, a redirection target,
        /// inside a comment, or straddling a boundary no rule classifies —
        /// all land here, because acceptance requires a positive answer and
        /// there was none.
        case placeholderNotInArgumentPosition(name: String)

        /// Which unsurveyable construct was found. Named, because a refusal
        /// that does not say what it saw cannot be acted on. The recogniser
        /// owns this vocabulary; aliasing rather than restating it is what
        /// keeps the two from drifting into two different lists.
        public typealias Context = SnippetCommandSurvey.Refusal
    }

    /// `command` with every declared variable applied.
    ///
    /// Placeholders are replaced by the quoted value; environment
    /// declarations are prepended as assignments in declaration order.
    /// A missing value is treated as the empty string rather than skipped —
    /// leaving `{{NAME}}` in a command that then runs would be worse than an
    /// empty argument.
    ///
    /// Placeholder substitution is a single left-to-right pass over the
    /// ORIGINAL `command`, not a chain of `replacingOccurrences` calls run
    /// one after another on the accumulating result. Chaining would re-scan
    /// an already-substituted value for the *next* variable's token: if an
    /// earlier value happened to contain a later `{{NAME}}` literally (a
    /// user can type anything into a prompt), that later pass would match it
    /// and substitute inside the first value's quotes, breaking them open.
    /// Scanning the original text once means a substituted value is only
    /// ever appended as literal output, never re-examined.
    ///
    /// A declaration whose NAME is not a POSIX shell identifier is skipped
    /// entirely — no assignment emitted, no placeholder substituted. This
    /// function is the one that turns declaration data into shell text, and
    /// it is reachable without anybody having called
    /// `firstDeclarationProblem` first (the prompt-and-run path never does);
    /// a rule only the checker enforces is not a boundary. `A;touch /tmp/m`
    /// as a name would otherwise be emitted verbatim as the left side of an
    /// assignment, which a shell reads as two extra commands. Skipping
    /// leaves the template's own `{{NAME}}` text standing, which is inert
    /// literal text rather than a value placed in an unknown context.
    public static func resolve(
        command: String, variables: [SnippetVariable], values: [String: String]
    ) -> String {
        let variables = variables.filter { SnippetVariable.isValidName($0.name) }
        var quotedByName: [String: String] = [:]
        for variable in variables where variable.placement == .placeholder {
            quotedByName[variable.name] = PosixQuoting.singleQuoted(values[variable.name] ?? "")
        }

        var substituted = ""
        var index = command.startIndex
        while index < command.endIndex {
            if let closing = closingBraces(in: command, afterOpeningAt: index) {
                let nameStart = command.index(index, offsetBy: 2)
                let name = command[nameStart..<closing.lowerBound]
                if let quoted = quotedByName[String(name)] {
                    substituted += quoted
                    index = closing.upperBound
                    continue
                }
            }
            substituted.append(command[index])
            index = command.index(after: index)
        }

        let assignments = variables
            .filter { $0.placement == .environment }
            .map { "\($0.name)=\(PosixQuoting.singleQuoted(values[$0.name] ?? ""))" }
        guard !assignments.isEmpty else { return substituted }

        // A leading `NAME=value command` assignment scopes to that ONE
        // command. For a multi-line body that would set it for the first
        // line only, so it becomes its own line instead -- which is why the
        // variable then outlives the run in that session, a fact the editor's
        // hint text states.
        let separator = substituted.contains(where: \.isNewline) ? "\n" : " "
        return assignments.joined(separator: " ") + separator + substituted
    }

    /// If `command[index...]` opens with `{{`, the range of the matching
    /// `}}` that follows it -- otherwise `nil`. A plain brace-pair finder,
    /// not a shell tokenizer: `resolve` only needs to recognise `{{NAME}}`
    /// spans, and undeclared ones (a Go template, say) are left untouched by
    /// the caller regardless of what this returns for their contents.
    private static func closingBraces(
        in command: String, afterOpeningAt index: String.Index
    ) -> Range<String.Index>? {
        guard command[index] == "{" else { return nil }
        let next = command.index(after: index)
        guard next < command.endIndex, command[next] == "{" else { return nil }
        let searchStart = command.index(after: next)
        return command.range(of: "}}", range: searchStart..<command.endIndex)
    }

    /// The first thing that would make these declarations wrong, or `nil`.
    ///
    /// The name rule (`SnippetVariable.isValidName`) is checked FIRST and
    /// here, not only in the editor where declarations are authored: import
    /// carries declarations over from a file, so a name can arrive without
    /// ever having passed an editor field. `resolve` additionally skips such
    /// a declaration — see its doc comment for why the emitter, not only the
    /// checker, has to hold that line.
    ///
    /// Then the command is handed to `SnippetCommandSurvey`, which either
    /// reports the spans it positively recognised or refuses. That call is
    /// deliberately scoped to commands that declare at least one
    /// `.placeholder`: it exists to decide where a VALUE may be placed, and
    /// a here-document in a snippet that declares no placeholder — or only
    /// `.environment` variables, which are prepended as their own
    /// assignments and never land inside the command's own quoting — is an
    /// ordinary thing to write and stays savable.
    ///
    /// The unused check applies to `.placeholder` **only**, and that is not
    /// an oversight: for `.environment` the intended and most common case is
    /// precisely that the command never mentions the name — `DB='x'
    /// ./backup.sh` sets it for a script that reads it itself. Checking for
    /// `$NAME` there would reject the natural usage.
    ///
    /// The position check inspects EVERY occurrence of a declared
    /// `{{NAME}}`, not just the first. An earlier version of this function
    /// checked only the first occurrence, on the reasoning that `resolve`
    /// quotes every occurrence the same way, so a later occurrence inside
    /// quotes seemed like it could only yield a harmless doubled-up literal.
    /// That reasoning was wrong: `PosixQuoting.singleQuoted` protects a
    /// value by wrapping it in single quotes, and single quotes have no
    /// special meaning to a shell once they are already *inside* the
    /// template's own double quotes -- they show up as literal characters
    /// there, while anything the value contained that IS special inside
    /// double quotes, such as `$(...)` command substitution, stays live and
    /// executes. `echo {{DB}} "{{DB}}"` with `DB = $(touch /tmp/marker)`
    /// resolves to `echo '$(touch /tmp/marker)' "'$(touch /tmp/marker)'"`,
    /// and bash runs the substitution in the second, double-quoted copy.
    /// The shape is ordinary, not contrived -- `scp -i {{KEY}} … && echo
    /// "used {{KEY}}"` is a completely normal thing to write.
    ///
    /// And the acceptance rule is POSITIVE: an occurrence passes only when
    /// the survey puts it inside one recognised `.argument` span. There is
    /// no "no objection found, carry on" branch, because that branch is what
    /// four review rounds walked through — every one of them a construct the
    /// recogniser did not understand, and not understanding meant accepting.
    public static func firstDeclarationProblem(
        command: String, variables: [SnippetVariable]
    ) -> Problem? {
        for variable in variables where !SnippetVariable.isValidName(variable.name) {
            return .invalidName(name: variable.name)
        }

        let placeholders = variables.filter { $0.placement == .placeholder }
        guard !placeholders.isEmpty else { return nil }

        let spans: [SnippetCommandSurvey.Span]
        switch SnippetCommandSurvey.survey(command) {
        case .refused(let refusal):
            return .unanalyzableContext(kind: refusal)
        case .surveyed(let surveyed):
            spans = surveyed
        }

        for variable in placeholders {
            let needle = "{{\(variable.name)}}"
            var searchRange = command.startIndex..<command.endIndex
            var foundAny = false
            while let occurrence = command.range(of: needle, range: searchRange) {
                foundAny = true
                switch SnippetCommandSurvey.placement(of: occurrence, in: spans) {
                case .argument:
                    break
                case .quoted:
                    return .placeholderInsideQuotes(name: variable.name)
                default:
                    return .placeholderNotInArgumentPosition(name: variable.name)
                }
                searchRange = occurrence.upperBound..<command.endIndex
            }
            guard foundAny else {
                return .unusedPlaceholder(name: variable.name)
            }
        }
        return nil
    }
}
