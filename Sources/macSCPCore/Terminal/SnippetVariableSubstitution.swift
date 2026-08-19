import Foundation

/// Turning a snippet's template into the command that actually runs.
///
/// Pure: values in, resolved command out. Nothing here talks to a store, a
/// terminal or a view — which is what makes the quoting, the one part where
/// a wrong answer turns data into code, fully testable.
public enum SnippetVariableSubstitution {
    /// What is wrong with a set of declarations, if anything.
    public enum Problem: Equatable {
        /// A placeholder declaration whose `{{NAME}}` appears nowhere: the
        /// user would be asked for a value that reaches nothing.
        case unusedPlaceholder(name: String)
        /// `echo "{{NAME}}"` — the value is already quoted by this type, so
        /// surrounding quotes would show up literally in the output.
        case placeholderInsideQuotes(name: String)
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
    public static func resolve(
        command: String, variables: [SnippetVariable], values: [String: String]
    ) -> String {
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
        let stringRanges = SnippetHighlighter.tokens(in: command, language: .shell)
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
}
