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
    public static func resolve(
        command: String, variables: [SnippetVariable], values: [String: String]
    ) -> String {
        var resolved = command
        for variable in variables where variable.placement == .placeholder {
            resolved = resolved.replacingOccurrences(
                of: "{{\(variable.name)}}",
                with: PosixQuoting.singleQuoted(values[variable.name] ?? ""))
        }

        let assignments = variables
            .filter { $0.placement == .environment }
            .map { "\($0.name)=\(PosixQuoting.singleQuoted(values[$0.name] ?? ""))" }
        guard !assignments.isEmpty else { return resolved }

        // A leading `NAME=value command` assignment scopes to that ONE
        // command. For a multi-line body that would set it for the first
        // line only, so it becomes its own line instead -- which is why the
        // variable then outlives the run in that session, a fact the editor's
        // hint text states.
        let separator = resolved.contains(where: \.isNewline) ? "\n" : " "
        return assignments.joined(separator: " ") + separator + resolved
    }

    /// The first thing that would make these declarations wrong, or `nil`.
    ///
    /// The unused check applies to `.placeholder` **only**, and that is not
    /// an oversight: for `.environment` the intended and most common case is
    /// precisely that the command never mentions the name — `DB='x'
    /// ./backup.sh` sets it for a script that reads it itself. Checking for
    /// `$NAME` there would reject the natural usage.
    public static func firstDeclarationProblem(
        command: String, variables: [SnippetVariable]
    ) -> Problem? {
        let stringRanges = SnippetHighlighter.tokens(in: command, language: .shell)
            .filter { $0.kind == .string }
            .map(\.range)

        for variable in variables where variable.placement == .placeholder {
            let needle = "{{\(variable.name)}}"
            guard let first = command.range(of: needle) else {
                return .unusedPlaceholder(name: variable.name)
            }
            if stringRanges.contains(where: { $0.contains(first.lowerBound) }) {
                return .placeholderInsideQuotes(name: variable.name)
            }
        }
        return nil
    }
}
