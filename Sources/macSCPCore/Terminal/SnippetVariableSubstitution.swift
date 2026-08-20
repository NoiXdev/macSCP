import Foundation

/// Turning a snippet's template into the command that actually runs.
///
/// Pure: values in, resolved command out. Nothing here talks to a store, a
/// terminal or a view — which is what makes the quoting, the one part where
/// a wrong answer turns data into code, fully testable.
public enum SnippetVariableSubstitution {
    /// What is wrong with a set of declarations, if anything.
    public enum Problem: Equatable {
        /// A name that is not a POSIX shell identifier
        /// (`SnippetVariable.isValidName`). For `.environment` such a name
        /// would not produce an assignment at all but extra commands —
        /// `A;touch /tmp/m;B='v' echo hi` is three of them.
        case invalidName(name: String)
        /// The command carries a shell context the quote-position check
        /// below cannot analyse, so no answer it gives about a placeholder
        /// would mean anything. Not an accusation and not a defect in the
        /// command: it is the limit of a check that reads quote positions
        /// rather than parsing a shell.
        case unanalyzableContext(kind: Context)
        /// A placeholder declaration whose `{{NAME}}` appears nowhere: the
        /// user would be asked for a value that reaches nothing.
        case unusedPlaceholder(name: String)
        /// `echo "{{NAME}}"` — the value is already quoted by this type, so
        /// surrounding quotes would show up literally in the output.
        case placeholderInsideQuotes(name: String)

        /// Which unanalysable context was found. Named, because a refusal
        /// that does not say what it saw cannot be acted on.
        public enum Context: Equatable, Sendable {
            /// A here-document operator (`<<`, `<<-`, `<<<`, quoted
            /// delimiter or not). Everything between the operator and its
            /// delimiter is a quoting context of its own, invisible to a
            /// scan over quote characters.
            case heredoc
            /// A quoted span that never closes, or one that runs across a
            /// line break. Either way the quoting state of every position
            /// after it is a guess.
            case unbalancedQuoting
        }
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
    /// Then, before any quote position is read, the command is checked for a
    /// context this function cannot analyse (see `Problem.Context`). That
    /// check is deliberately scoped to commands that declare at least one
    /// `.placeholder`: it exists to protect the quote-position check below,
    /// and a here-document in a snippet that declares no placeholder — or
    /// only `.environment` variables, which are prepended as their own
    /// assignments and never land inside the command's own quoting — is an
    /// ordinary thing to write and stays savable.
    ///
    /// The unused check applies to `.placeholder` **only**, and that is not
    /// an oversight: for `.environment` the intended and most common case is
    /// precisely that the command never mentions the name — `DB='x'
    /// ./backup.sh` sets it for a script that reads it itself. Checking for
    /// `$NAME` there would reject the natural usage.
    ///
    /// The quote-context check inspects EVERY occurrence of a declared
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
    /// "used {{KEY}}"` is a completely normal thing to write. So every
    /// occurrence is checked, and the first one found inside a `.string`
    /// token rejects the declaration.
    public static func firstDeclarationProblem(
        command: String, variables: [SnippetVariable]
    ) -> Problem? {
        for variable in variables where !SnippetVariable.isValidName(variable.name) {
            return .invalidName(name: variable.name)
        }

        let tokens = SnippetHighlighter.tokens(in: command, language: .shell)
        let declaresPlaceholder = variables.contains { $0.placement == .placeholder }
        if declaresPlaceholder, let context = unanalyzableContext(in: command, tokens: tokens) {
            return .unanalyzableContext(kind: context)
        }

        let stringRanges = tokens
            .filter { $0.kind == .string }
            .map(\.range)

        for variable in variables where variable.placement == .placeholder {
            let needle = "{{\(variable.name)}}"
            var searchRange = command.startIndex..<command.endIndex
            var foundAny = false
            while let occurrence = command.range(of: needle, range: searchRange) {
                foundAny = true
                if stringRanges.contains(where: { $0.contains(occurrence.lowerBound) }) {
                    return .placeholderInsideQuotes(name: variable.name)
                }
                searchRange = occurrence.upperBound..<command.endIndex
            }
            guard foundAny else {
                return .unusedPlaceholder(name: variable.name)
            }
        }
        return nil
    }

    /// The context that makes a quote-position answer meaningless, or `nil`.
    ///
    /// A here-document is found as two adjacent `<` operator tokens. Reading
    /// TOKENS rather than the raw text is what keeps `echo "a << b"` and
    /// `# pipe it with <<` out of it: a `<<` inside a string or a comment is
    /// part of that token and never appears as an operator. Adjacency is
    /// required, so `<` and `<` separated by a space — process substitution,
    /// `cmd < <(other)` — is not mistaken for one. `<<-` and `<<<` and a
    /// quoted delimiter all open with the same two characters and are
    /// therefore all covered.
    ///
    /// Neither shape is a defect in the command. A here-document is a
    /// perfectly good way to write one; it just carries a quoting context of
    /// its own that a scan over quote characters cannot see into.
    private static func unanalyzableContext(
        in command: String, tokens: [SnippetToken]
    ) -> Problem.Context? {
        for (left, right) in zip(tokens, tokens.dropFirst())
        where left.kind == .operator && right.kind == .operator
            && left.range.upperBound == right.range.lowerBound
            && command[left.range] == "<" && command[right.range] == "<" {
            return .heredoc
        }
        guard SnippetHighlighter.quotingBalancesPerLine(in: command) else {
            return .unbalancedQuoting
        }
        return nil
    }
}
