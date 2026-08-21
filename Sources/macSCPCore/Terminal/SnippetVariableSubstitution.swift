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
        /// `export A;touch /tmp/m;B='v'; echo hi` is three of them.
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
        /// top-level command. Command-name position, anywhere behind a
        /// redirection operator, inside a comment, or straddling a boundary
        /// no rule classifies — all land here, because acceptance requires a
        /// positive answer and there was none.
        case placeholderNotInArgumentPosition(name: String)
        /// The placeholder IS a plain unquoted argument — of a command that
        /// hands its own arguments back to the shell. `[ -f {{PATH}} ]`,
        /// `printf '%s' {{X}}`, `export FOO={{VALUE}}`, `exit {{CODE}}`.
        /// Quoting produces one literal word and the shell evaluates that
        /// word anyway, so this is the one refusal that is about the
        /// COMMAND rather than about the position.
        ///
        /// Separate from `placeholderNotInArgumentPosition` because the
        /// advice differs: there is nothing to move the placeholder out of,
        /// and the sentence that says "take it out of the command name, a
        /// redirection or a comment" would be wrong here.
        case placeholderIsReparsedByItsCommand(name: String)

        /// Which unsurveyable construct was found. Named, because a refusal
        /// that does not say what it saw cannot be acted on. The recogniser
        /// owns this vocabulary; aliasing rather than restating it is what
        /// keeps the two from drifting into two different lists.
        public typealias Context = SnippetCommandSurvey.Refusal
    }

    /// `command` with every declared variable applied.
    ///
    /// Placeholders are replaced by the quoted value; environment
    /// declarations are prepended, in declaration order, as one
    /// `export NAME='value';` statement each.
    /// A missing value is treated as the empty string rather than skipped —
    /// leaving `{{NAME}}` in a command that then runs would be worse than an
    /// empty argument.
    ///
    /// Placeholder substitution works from ranges taken out of the ORIGINAL
    /// `command` — the ones `occurrences(of:in:)` reports — and not from a
    /// chain of `replacingOccurrences` calls run one after another on the
    /// accumulating result. Chaining would re-scan an already-substituted
    /// value for the *next* variable's token: if an earlier value happened
    /// to contain a later `{{NAME}}` literally (a user can type anything
    /// into a prompt), that later pass would match it and substitute inside
    /// the first value's quotes, breaking them open. Reading positions out
    /// of the original text means a substituted value is only ever appended
    /// as literal output, never re-examined.
    ///
    /// The result is assembled through the scalar view rather than by
    /// slicing the `String`. An occurrence is scalar-aligned and a
    /// scalar-aligned index need not sit on a grapheme cluster boundary, so
    /// asking a `String` for that slice is not a well-defined request.
    ///
    /// A declaration whose NAME is not a POSIX shell identifier is skipped
    /// entirely — no assignment emitted, no placeholder substituted. This
    /// function is the one that turns declaration data into shell text, and
    /// nothing in its signature makes a prior `firstDeclarationProblem` call
    /// a precondition: it is public and pure, and any future path may reach
    /// it directly. The prompt-and-run path in the App layer does check
    /// first today, and a wiring guard pins that it checks BEFORE opening
    /// the prompt — but that is a property of one caller, and a rule only
    /// the checker enforces is not a boundary. `A;touch /tmp/m`
    /// as a name would otherwise be emitted verbatim as the left side of an
    /// assignment, which a shell reads as two extra commands. Skipping
    /// leaves the template's own `{{NAME}}` text standing, which is inert
    /// literal text rather than a value placed in an unknown context.
    public static func resolve(
        command: String, variables: [SnippetVariable], values: [String: String]
    ) -> String {
        let variables = variables.filter { SnippetVariable.isValidName($0.name) }
        var replacements: [(range: Range<String.Index>, quoted: String)] = []
        for variable in variables where variable.placement == .placeholder {
            let quoted = PosixQuoting.singleQuoted(values[variable.name] ?? "")
            for range in occurrences(of: variable.name, in: command) {
                replacements.append((range, quoted))
            }
        }
        replacements.sort { $0.range.lowerBound < $1.range.lowerBound }

        let scalars = command.unicodeScalars
        var assembled = String.UnicodeScalarView()
        var cursor = scalars.startIndex
        for replacement in replacements {
            // Two occurrences cannot overlap: a declared name is a POSIX
            // identifier, so it holds no brace, so `{{A}}` and `{{B}}` are
            // disjoint spans and repeats of one name are consumed whole.
            // Skipping rather than trusting that keeps a future name rule
            // from producing a torn value — the placeholder would simply
            // stay in the text as inert literal characters.
            //
            // Which makes this guard UNREACHABLE today, and it is written
            // down here so nobody mistakes it for tested: deleting the line
            // leaves the suite green, as a review measured. That is the
            // correct outcome, not a coverage hole — a test that reached it
            // would have to declare a name the name rule forbids, and would
            // then be pinning a shape the product cannot produce.
            guard replacement.range.lowerBound >= cursor else { continue }
            assembled.append(contentsOf: scalars[cursor..<replacement.range.lowerBound])
            assembled.append(contentsOf: replacement.quoted.unicodeScalars)
            cursor = replacement.range.upperBound
        }
        assembled.append(contentsOf: scalars[cursor...])
        let substituted = String(assembled)

        // One `export NAME='value';` STATEMENT per declaration, ahead of the
        // body, whatever the body looks like. Both halves of that shape are
        // measured rather than argued (bash 3.2.57, bash 5.2, zsh 5.9, dash,
        // mksh, ksh93; the probe reads the value in the body and in a child
        // `sh -c`):
        //
        // - As a PREFIX -- `NAME='value' command` -- the assignment scopes to
        //   that one simple command, so `V='x' true && printf "$V"` and every
        //   `;` or `|` continuation read an empty value in all six shells.
        //   The prefix does not even reach the first command's own arguments,
        //   because expansion happens before the assignment takes effect.
        // - WITHOUT `export`, as its own statement, the body sees the value
        //   but a child process does not -- and a called script reading the
        //   value itself is the case this placement exists for.
        //
        // The separator is `; ` and not a line break, on a difference that is
        // not about shells at all: both forms measured identical in all six.
        // A `; ` keeps a single-line body single-line, so `SnippetSendPlanner`
        // still takes the single-line path for it -- a line break would turn
        // every snippet with an environment variable into a multi-line send,
        // which without bracketed paste is refused for insert and split into
        // separate Return-terminated lines for execute.
        //
        // Emitting `export` here is not the shape `SnippetCommandSurvey`
        // refuses as a reparsing command name. That refusal is about a
        // placeholder standing among the arguments of an `export` the USER
        // typed, where `export {{X}}` with a value of `a[$(touch M)]=1` runs
        // the substitution in zsh and mksh (measured, both). Here the name is
        // the left side of the assignment and passed `isValidName`, and the
        // value is `PosixQuoting.singleQuoted` on the right side of the `=`;
        // the same payload measured inert in all six shells.
        let assignments = variables
            .filter { $0.placement == .environment }
            .map { "export \($0.name)=\(PosixQuoting.singleQuoted(values[$0.name] ?? "")); " }
        guard !assignments.isEmpty else { return substituted }
        return assignments.joined() + substituted
    }

    /// Every occurrence of `{{name}}` in `command`, non-overlapping, left to
    /// right, as ranges into `command`.
    ///
    /// THE occurrence finder, and the reason it is one function: the gate
    /// asks it where to check a value's position and the emitter asks it
    /// where to put the value. Those were two different searches — a
    /// `range(of:)` in the checker, a walk over `{{` and `}}` in the emitter
    /// — and a corpus of sixty-six decorated templates found them agreeing
    /// on every one. Agreeing is not the property that matters, though;
    /// being the same question is. Two searches that agree today can drift
    /// tomorrow, and the drift that costs the gate is silent: a value
    /// substituted at a position nothing classified.
    ///
    /// Read one `Unicode.Scalar` at a time, for the reason `ShellScalar`
    /// sets out. The cluster search this replaces could not see `{{X}}` when
    /// the next scalar was a combining mark, because that mark and the final
    /// `}` are one `Character`; a scalar walk sees it. That widens what
    /// counts as an occurrence, and it widens it for BOTH callers at once —
    /// the survey classifies the position and the emitter fills it, or
    /// neither does.
    ///
    /// Only declared names are ever passed in, so a `{{…}}` belonging to
    /// some other template language is not an occurrence of anything here
    /// and is left in the text untouched.
    static func occurrences(of name: String, in command: String) -> [Range<String.Index>] {
        let needle = Array("{{\(name)}}".unicodeScalars)
        guard !needle.isEmpty else { return [] }
        let scalars = command.unicodeScalars
        var found: [Range<String.Index>] = []
        var start = scalars.startIndex
        while start < scalars.endIndex {
            var scan = start
            var matched = 0
            while matched < needle.count, scan < scalars.endIndex,
                  scalars[scan] == needle[matched] {
                matched += 1
                scan = scalars.index(after: scan)
            }
            if matched == needle.count {
                found.append(start..<scan)
                start = scan
            } else {
                start = scalars.index(after: start)
            }
        }
        return found
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
    /// `.environment` variables, which are prepended as their own `export`
    /// statements and never land inside the command's own quoting — is an
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
    /// review round after review round walked through — every one of them a
    /// construct the recogniser did not understand, and not understanding
    /// meant accepting.
    ///
    /// `.reparsedArgument` is the one placement that is a plain argument and
    /// still fails. It is what the survey emits for the arguments of a
    /// command whose NAME re-parses them — `[`, `printf`, `exit` — and it
    /// exists so that such a name refuses the placeholder standing in ITS
    /// argument list rather than every placeholder in the template. The
    /// names that can change what a LATER word means (`eval`, `alias`,
    /// `hash -p`) do not come through here at all: the survey refuses those
    /// whole, and they arrive as `.unanalyzableContext(.evaluation)`.
    ///
    /// A `nil` placement — the occurrence lies in no single recognised span
    /// — is the structural default and lands on
    /// `placeholderNotInArgumentPosition` through the `default` arm below.
    /// It is reachable (`echo \{{X}}`: the escape swallows the first brace,
    /// so the argument span starts one scalar inside the occurrence), and it
    /// is pinned by its own cases in the test corpus, because a default
    /// nothing exercises is a default nothing protects.
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
            let found = occurrences(of: variable.name, in: command)
            guard !found.isEmpty else {
                return .unusedPlaceholder(name: variable.name)
            }
            for occurrence in found {
                switch SnippetCommandSurvey.placement(of: occurrence, in: spans) {
                case .argument:
                    break
                case .quoted:
                    return .placeholderInsideQuotes(name: variable.name)
                case .reparsedArgument:
                    return .placeholderIsReparsedByItsCommand(name: variable.name)
                default:
                    return .placeholderNotInArgumentPosition(name: variable.name)
                }
            }
        }
        return nil
    }
}
