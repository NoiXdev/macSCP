import Foundation

/// A conservative reading of a snippet command: which spans of it are
/// positions where a value quoted by `PosixQuoting.singleQuoted` is
/// *provably* still one literal word — and, when the text cannot be read
/// that far, what stopped the reading.
///
/// ## Why this is not the highlighter
///
/// `SnippetHighlighter` answers a colouring question, and a colouring
/// question tolerates approximation: a token boundary a shade off is
/// invisible. This type answers a security question, where the same
/// approximation decides whether a typed value is data or code. Every review
/// round that broke this gate broke it through exactly that gap — the
/// tokenizer did not understand a construct, and *not understanding meant
/// accepting*. Sharing one recogniser between the two meant a change made
/// for colour could move the gate, silently.
///
/// So there is no shared code with `SnippetHighlighter`, on purpose. The
/// duplication (both know what a quoted span is) is the price of the two
/// being able to answer to different masters: the highlighter may keep
/// approximating, this one may not.
///
/// ## The rule that makes it fail closed
///
/// `survey` never returns "nothing found, carry on". It returns either the
/// spans it positively recognised — and a position covered by no span is
/// not safe — or a `Refusal`. Every construct whose effect on quoting this
/// type cannot state exactly is a `Refusal`: a here-document, a command
/// substitution, a subshell, an expansion other than a plain `$NAME`, a
/// quote that does not close on its line, a command name it cannot read as
/// a literal word, a `eval`-style re-parse of its own arguments, a dangling
/// escape. Breadth of acceptance is explicitly not a goal; a legitimate
/// command refused is a nuisance, a hostile one accepted is a shell running
/// a stranger's text.
///
/// This is deliberately NOT a shell parser. It reads a small, flat subset —
/// words, separators, redirections, comments, quoted spans — and refuses
/// everything else. Nesting of any kind is a refusal rather than a
/// recursion.
///
/// ## The alphabet it reads in
///
/// `Unicode.Scalar`, for the reasons `ShellScalar` sets out. Reading shell
/// text in `Character`s meant a quote carrying a combining mark was one
/// symbol that compared unequal to `"'"`, so this type stayed in the
/// unquoted state across it and emitted an `.argument` span over a
/// placeholder a shell reads as quoted. Positive recognition does not save
/// you there: the span is not missing, it is *wrong*. Containment in one
/// span can only be as good as the span.
public enum SnippetCommandSurvey {
    /// What stopped the reading. Each case names a construct, not a
    /// mistake: every one of these is a perfectly good thing to write in a
    /// shell — it is this type that cannot survey it.
    public enum Refusal: Equatable, Sendable {
        /// A here-document operator (`<<`, `<<-`, `<<<`). Its body is a
        /// quoting context of its own, delimited by a word rather than by a
        /// character, and nothing here can express that.
        case heredoc
        /// A quoted span that never closes, or one that runs across a line
        /// break. Either way the quoting state of every later position
        /// would be a guess.
        case unbalancedQuoting
        /// `$(…)`, a backtick, `(…)`, or a process substitution `<(…)`,
        /// `>(…)`: a command inside a command. Its text has its own quoting
        /// state, and a value placed anywhere near it would be read by a
        /// shell twice.
        case commandSubstitution
        /// An expansion other than a plain `$NAME` or `$1`: `${…}`, `$((…))`,
        /// `$'…'`, `$"…"`, or a `$` this type cannot read at all.
        case expansion
        /// A command that re-parses its own arguments as shell text
        /// (`eval`, and the `command`/`builtin` wrappers that can front
        /// it). Quoting a value into one literal word protects nothing when
        /// the word is then handed back to the parser.
        case evaluation
        /// The text ran out mid-construct, or a shape appeared that no rule
        /// here covers — including a command name that is not a plain
        /// literal word. The structural default, and the case that makes
        /// "not recognised" mean "refused" rather than "accepted".
        case unrecognizedSyntax
    }

    /// What a recognised span of text *is*. Only `.argument` is a position
    /// where a single-quoted value stays one literal word.
    public enum Placement: Equatable, Sendable {
        /// Unquoted literal text inside a word that is an argument of a
        /// top-level simple command. The one safe placement.
        case argument
        /// Inside a single- or double-quoted span. A single-quoted value
        /// placed here contributes its quotes as literal characters while
        /// anything live inside it stays live.
        case quoted
        /// The word a shell would run as the command itself, or an
        /// assignment prefix standing in front of it. A value here would
        /// name the program rather than be handed to one.
        case commandName
        /// A `#` comment, to the end of its line. Unsafe despite looking
        /// inert: a value containing a newline ends the comment, and
        /// everything after the newline is code again.
        case comment
        /// The word after a redirection operator. Not an argument of the
        /// command, and refused rather than reasoned about.
        case redirectionTarget
    }

    /// One recognised span of `command`.
    public struct Span: Equatable, Sendable {
        public let placement: Placement
        public let range: Range<String.Index>

        public init(placement: Placement, range: Range<String.Index>) {
            self.placement = placement
            self.range = range
        }
    }

    /// The whole answer: spans, or the reason there are none.
    public enum Reading: Equatable, Sendable {
        /// Every span the reading positively recognised. Text covered by no
        /// span was reached but not classified, and is therefore not safe —
        /// the caller must require containment, never absence of a hit.
        case surveyed([Span])
        case refused(Refusal)
    }

    /// Reads `command` and reports the spans it recognised, or refuses.
    public static func survey(_ command: String) -> Reading {
        var reader = Reader(text: command)
        return reader.read()
    }

    /// Whether `range` sits entirely inside one recognised `.argument`
    /// span. Containment in ONE span is the requirement, not overlap with
    /// several: a `{{NAME}}` straddling a quote boundary, an escape, or a
    /// word break is exactly the shape no rule here classifies, and it must
    /// come out unsafe.
    public static func placement(
        of range: Range<String.Index>, in spans: [Span]
    ) -> Placement? {
        spans.first {
            $0.range.lowerBound <= range.lowerBound && range.upperBound <= $0.range.upperBound
        }?.placement
    }
}

extension SnippetCommandSurvey {
    /// The single left-to-right pass. Kept as a struct with one cursor so
    /// there is exactly one notion of "where we are" — the earlier design
    /// derived quoting state from a token list produced elsewhere, and the
    /// gap between "how the tokenizer split it" and "how a shell reads it"
    /// is where every past escape lived.
    ///
    /// It holds the command's `String.UnicodeScalarView` and NOT the
    /// `String`, so the unit `ShellScalar` settles on is the only unit
    /// available in here: a `Character` comparison cannot be written against
    /// this cursor without first putting the `String` back as a property,
    /// which is a visible edit rather than a slip. Scalar-view indices are
    /// `String.Index` values, so the spans handed out stay comparable with
    /// ranges a caller found by ordinary text search.
    private struct Reader {
        let scalars: String.UnicodeScalarView
        var index: String.Index
        var spans: [Span] = []
        /// True where the next word would be the command a shell runs.
        var expectsCommandName = true
        /// True immediately after a redirection operator.
        var expectsRedirectionTarget = false

        init(text: String) {
            self.scalars = text.unicodeScalars
            self.index = text.startIndex
        }

        /// Words that introduce another command rather than being one, so
        /// the word after them is still a command name. Listed because
        /// staying in "expects a command name" is the STRICT direction: it
        /// makes the next word be read as a name (which must be a plain
        /// literal and is checked against the re-parsing set) instead of as
        /// an argument. Missing an entry over-refuses; a wrong extra entry
        /// cannot open a hole.
        static let commandIntroducers: Set<String> = [
            "if", "then", "elif", "else", "while", "until", "do", "time", "!", "{", "}",
        ]

        /// Command names that hand their arguments back to the shell parser.
        /// `command` and `builtin` are here because `command eval …` runs
        /// `eval`. This is not a claim to have enumerated every program that
        /// interprets its argv — `bash -c`, `python -c` and friends do too,
        /// and no quoting rule can help there; it is the set where the
        /// SHELL itself re-parses, which is the question this type answers.
        static let reparsingCommands: Set<String> = ["eval", "command", "builtin"]

        mutating func read() -> Reading {
            while index < scalars.endIndex {
                let scalar = scalars[index]

                if ShellScalar.isNewline(scalar) {
                    advance()
                    beginCommand()
                    continue
                }
                if ShellScalar.isWhitespace(scalar) {
                    advance()
                    continue
                }
                // A `#` that reaches the top of this loop always begins a
                // comment, exactly as a shell has it, because every path
                // back to the top is a word boundary: the start of the
                // text, a line break, unquoted whitespace, a separator, a
                // redirection operator. A `#` in the MIDDLE of a word never
                // arrives here — `readWord` does not treat `#` as a word
                // terminator, so it is consumed inside the word and
                // `echo a#b` passes a literal `a#b`. That, and nothing
                // else, is what stops a mid-word `#` from being read as a
                // comment; reading it as one is what let fifteen templates
                // through a previous round.
                if scalar == "#" {
                    let start = index
                    while index < scalars.endIndex, !ShellScalar.isNewline(scalars[index]) {
                        advance()
                    }
                    spans.append(Span(placement: .comment, range: start..<index))
                    continue
                }
                if scalar == ";" || scalar == "&" || scalar == "|" || scalar == ")" {
                    advance()
                    beginCommand()
                    continue
                }
                if scalar == "(" || scalar == "`" {
                    return .refused(.commandSubstitution)
                }
                if scalar == "<" || scalar == ">" {
                    if let refusal = readRedirectionOperator(scalar) {
                        return .refused(refusal)
                    }
                    continue
                }
                if let refusal = readWord() {
                    return .refused(refusal)
                }
            }
            return .surveyed(spans)
        }

        private mutating func advance() {
            index = scalars.index(after: index)
        }

        private mutating func beginCommand() {
            expectsCommandName = true
            expectsRedirectionTarget = false
        }

        /// The scalars of `start..<end` as a `String`. Built through the
        /// scalar view rather than by subscripting the original `String`,
        /// because a scalar-aligned index need not sit on a grapheme
        /// cluster boundary and slicing a `String` at one is not a
        /// well-defined thing to ask for.
        private func text(from start: String.Index, to end: String.Index) -> String {
            String(String.UnicodeScalarView(scalars[start..<end]))
        }

        /// `<`, `<<`, `<<<`, `>`, `>>` and the process substitutions that
        /// open with them. `<<` in any of its forms is a here-document —
        /// the two characters are read here, in the unquoted state, so a
        /// `<<` inside a string or a comment never reaches this branch.
        private mutating func readRedirectionOperator(_ scalar: Unicode.Scalar) -> Refusal? {
            let next = scalars.index(after: index)
            if next < scalars.endIndex {
                if scalar == "<", scalars[next] == "<" { return .heredoc }
                if scalars[next] == "(" { return .commandSubstitution }
            }
            advance()
            if scalar == ">", index < scalars.endIndex, scalars[index] == ">" { advance() }
            expectsRedirectionTarget = true
            return nil
        }

        /// One word: its literal runs, its quoted spans, its expansions.
        ///
        /// The word ends at whitespace or at any unquoted metacharacter,
        /// which is left for `read()` to classify — this method never
        /// consumes a separator.
        private mutating func readWord() -> Refusal? {
            let placement: Placement =
                expectsRedirectionTarget ? .redirectionTarget
                : expectsCommandName ? .commandName : .argument
            let wordStart = index
            var runStart: String.Index? = index
            var isPlainLiteral = true

            while index < scalars.endIndex {
                let scalar = scalars[index]
                if ShellScalar.isWhitespace(scalar) || scalar == ";" || scalar == "&"
                    || scalar == "|" || scalar == "<" || scalar == ">"
                    || scalar == "(" || scalar == ")" || scalar == "`" {
                    break
                }
                if scalar == "'" || scalar == "\"" {
                    closeRun(&runStart, placement: placement)
                    isPlainLiteral = false
                    if let refusal = readQuotedSpan(quote: scalar) { return refusal }
                    runStart = index
                    continue
                }
                if scalar == "\\" {
                    closeRun(&runStart, placement: placement)
                    isPlainLiteral = false
                    let escaped = scalars.index(after: index)
                    // A backslash with nothing after it is the text running
                    // out mid-construct, which is a refusal and not a
                    // literal backslash.
                    guard escaped < scalars.endIndex else { return .unrecognizedSyntax }
                    index = scalars.index(after: escaped)
                    runStart = index
                    continue
                }
                if scalar == "$" {
                    closeRun(&runStart, placement: placement)
                    isPlainLiteral = false
                    if let refusal = readExpansion() { return refusal }
                    runStart = index
                    continue
                }
                advance()
            }
            closeRun(&runStart, placement: placement)

            if placement == .commandName {
                let word = text(from: wordStart, to: index)
                // A word a shell reads as an assignment is not a command
                // name at all, so it need not be readable as one:
                // `PGPASSWORD='secret' psql -h {{HOST}}` is an everyday
                // snippet, and requiring a plain literal here refused the
                // whole command over the quotes around `secret`. The value
                // side stays fully surveyed — its literal runs are
                // `.commandName` and its quoted spans are `.quoted`, so a
                // placeholder *inside* the assignment is still refused, and
                // anything the value contains that this type cannot read
                // (`$(…)`, a backtick, `${…}`) still refuses the command.
                //
                // The test for "this is an assignment" is the STRICT one
                // (`opensAssignment`: a POSIX identifier then `=`, read out
                // of plain literal scalars), because it is the test that
                // lets a word through without the name checks below.
                if !opensAssignment(from: wordStart) {
                    // A command name that is not one plain literal word
                    // cannot be compared against the re-parsing set at all,
                    // and a name this type cannot read is precisely the
                    // "unknown shape" case that must land on refusal.
                    // `"eval" {{X}}` is the shape that makes this
                    // load-bearing rather than tidy.
                    guard isPlainLiteral else { return .unrecognizedSyntax }
                    if Reader.reparsingCommands.contains(word) { return .evaluation }
                }
                // An assignment prefix (`DB=x cmd …`) and a word that
                // introduces another command both leave the command name
                // still to come. `contains("=")` is the LOOSE test on
                // purpose, and deliberately not the same one as above: a
                // false positive here only keeps the reader expecting a
                // name, which makes the NEXT word be checked as one instead
                // of accepted as an argument — the strict direction.
                if !word.contains("="), !Reader.commandIntroducers.contains(word) {
                    expectsCommandName = false
                }
            }
            expectsRedirectionTarget = false
            return nil
        }

        /// Whether the word starting at `start` is what a shell reads as an
        /// assignment: a POSIX identifier (`[A-Za-z_][A-Za-z0-9_]*`)
        /// followed by `=`, spelled in plain literal scalars.
        ///
        /// Read from the raw scalars rather than from the assembled word,
        /// so a quote, an escape or a `$` anywhere in the name makes it
        /// false: `"A"=1 cmd` is refused as an unreadable command name even
        /// though a shell may treat it as an assignment. Over-refusing is
        /// the safe direction for a test whose true answer skips checks.
        private func opensAssignment(from start: String.Index) -> Bool {
            var scan = start
            guard scan < index, ShellScalar.isASCIILetterOrUnderscore(scalars[scan])
            else { return false }
            scan = scalars.index(after: scan)
            while scan < index,
                  ShellScalar.isASCIILetterOrUnderscore(scalars[scan])
                  || ShellScalar.isASCIIDigit(scalars[scan]) {
                scan = scalars.index(after: scan)
            }
            return scan < index && scalars[scan] == "="
        }

        private mutating func closeRun(_ runStart: inout String.Index?, placement: Placement) {
            if let start = runStart, start < index {
                spans.append(Span(placement: placement, range: start..<index))
            }
            runStart = nil
        }

        /// A quoted span, appended whole as `.quoted` and consumed through
        /// its closing quote.
        ///
        /// Single quotes honour NO escape in POSIX — every character up to
        /// the next `'` is literal, backslash included. Double quotes do
        /// honour one, so `"a\"b"` is a single span. A span that does not
        /// close on the line it opens is refused rather than followed: a
        /// multi-line quoted string is legal shell, this type simply
        /// declines to reason across the break.
        private mutating func readQuotedSpan(quote: Unicode.Scalar) -> Refusal? {
            let start = index
            advance()
            while index < scalars.endIndex {
                let scalar = scalars[index]
                if ShellScalar.isNewline(scalar) { return .unbalancedQuoting }
                if scalar == quote {
                    advance()
                    spans.append(Span(placement: .quoted, range: start..<index))
                    return nil
                }
                if quote == "\"" {
                    if scalar == "`" { return .commandSubstitution }
                    if scalar == "$" {
                        if let refusal = readExpansion() { return refusal }
                        continue
                    }
                    if scalar == "\\" {
                        let escaped = scalars.index(after: index)
                        guard escaped < scalars.endIndex else { return .unbalancedQuoting }
                        index = scalars.index(after: escaped)
                        continue
                    }
                }
                advance()
            }
            return .unbalancedQuoting
        }

        /// A `$…`. Only a plain `$NAME` or `$1` is read; everything else —
        /// `$(`, `$((`, `${`, `$'`, `$"`, a bare `$`, a `$` before anything
        /// non-ASCII — is refused. Accepting a plain variable costs nothing:
        /// it cannot contain a `{{NAME}}`, and no span is emitted for it, so
        /// a placeholder overlapping one is uncontained and therefore
        /// unsafe.
        private mutating func readExpansion() -> Refusal? {
            let next = scalars.index(after: index)
            guard next < scalars.endIndex else { return .expansion }
            let scalar = scalars[next]
            if scalar == "(" {
                let afterParenthesis = scalars.index(after: next)
                if afterParenthesis < scalars.endIndex, scalars[afterParenthesis] == "(" {
                    return .expansion
                }
                return .commandSubstitution
            }
            if scalar == "{" || scalar == "'" || scalar == "\"" { return .expansion }
            if ShellScalar.isASCIILetterOrUnderscore(scalar) {
                var scan = next
                while scan < scalars.endIndex,
                      ShellScalar.isASCIILetterOrUnderscore(scalars[scan])
                      || ShellScalar.isASCIIDigit(scalars[scan]) {
                    scan = scalars.index(after: scan)
                }
                index = scan
                return nil
            }
            if ShellScalar.isASCIIDigit(scalar) {
                index = scalars.index(after: next)
                return nil
            }
            return .expansion
        }
    }
}
