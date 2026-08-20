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
///
/// ## And its predicates are `bash`'s, not Unicode's
///
/// The unit is half the answer. A scalar predicate that recognises a
/// lexical event `bash` does not is the same defect in a new spelling: the
/// placeholder lands in a context modelled wrongly, and a wrong model here
/// resolves to acceptance. Each predicate this type reads shell text with —
/// what ends a line, what separates words — was run through `/bin/bash` and
/// matched to what `bash` actually did; where the answers differed, the
/// predicate moved to `bash`'s. `ShellScalar` records those measurements
/// next to the predicates themselves.
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
        /// A command name from `reparsingCommands` — one where the shell
        /// itself turns an argument into shell code, at once (`eval`) or on
        /// a later signal (`trap`) or out of a file it names (`source`).
        /// Quoting a value into one literal word protects nothing when the
        /// word is then handed back to the parser.
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
    /// Words that introduce another command rather than being one, so the
    /// word after them is still a command name. Listed because staying in
    /// "expects a command name" is the STRICT direction: it makes the next
    /// word be read as a name (which must be a plain literal and is checked
    /// against the re-parsing set) instead of as an argument. Missing an
    /// entry over-refuses; a wrong extra entry cannot open a hole.
    ///
    /// It holds every reserved word after which `bash` reads a COMMAND NAME,
    /// and `everyBashKeywordIsClassified` asks `compgen -k` for the list and
    /// fails on a keyword classified nowhere. That is the shape that hurts:
    /// a keyword read as an ordinary command name makes the reader stop
    /// expecting a name, so the word `bash` runs as the command gets checked
    /// as an argument and is never compared against `reparsingCommands`.
    ///
    /// The reserved words that take a WORD rather than a command name —
    /// `case`, `for`, `select`, `in`, `function` — are deliberately NOT here.
    /// Listing them would refuse `case "$1" in`, an everyday snippet, and
    /// buy nothing: each was run through `bash` with a payload in the
    /// position after it and none of them executed anything (`for` and
    /// `select` are syntax errors there, `case` matches a word, `function`
    /// names a function). `[[` is the reserved word where that measurement
    /// came out the other way, and it is in `unmodelledKeywords`.
    ///
    /// `exec` is a builtin rather than a keyword and sits here because
    /// `bash` reads the word after it as the command name, so this reader
    /// does too. Measured, `exec` will not run a builtin at all (`exec eval
    /// 'touch M'` left no marker), so what follows it is an external program
    /// — the parked class — but reading it as a name is the strict side and
    /// costs nothing.
    static let commandIntroducers: Set<String> = [
        "if", "then", "elif", "else", "fi",
        "while", "until", "do", "done", "esac",
        "time", "coproc", "!", "{", "}",
        "exec",
    ]

    /// Command names where the SHELL turns an argument into shell code —
    /// now, or later, or by naming a file of it.
    ///
    /// ## What "re-parses" had to cover
    ///
    /// The list started as `eval` plus the two wrappers that can front it,
    /// and stayed that way until a review executed `trap {{X}} EXIT` and
    /// found the marker. A deny-list inside an allow-list is only as good as
    /// the day it was written, so the members are now decided against
    /// `/bin/bash` itself and pinned by `everyBashBuiltinIsClassified`, which
    /// asks `compgen -b` and fails on any builtin classified nowhere. These
    /// are the shapes that had to be considered, each with the member that
    /// carries it:
    ///
    /// - evaluated at once — `eval`, `let` (arithmetic, and an array
    ///   subscript inside arithmetic is a command substitution);
    /// - stored now and evaluated later — `trap`, `alias`, `bind`, `fc`,
    ///   `history`, `complete`;
    /// - naming a file of shell code — `source`, `.`, and `enable -f`,
    ///   which loads a builtin out of a shared object;
    /// - dispatching to another builtin — `command`, `builtin`;
    /// - assigning through an evaluated subscript — `declare`, `typeset`,
    ///   `local`, `export`, `readonly`, `unset`, `read`, `mapfile`,
    ///   `readarray`;
    /// - running a command to produce completions — `compgen`, `complete`.
    ///
    /// Replacing the shell (`exec`) is a shape of its own and is handled in
    /// `commandIntroducers` instead, because what follows `exec` is a
    /// command name rather than text `exec` itself re-reads.
    ///
    /// ## The boundary this list does NOT reach
    ///
    /// It is the set where the SHELL re-parses. It is emphatically not a
    /// list of every danger: a PROGRAM that interprets its own argument —
    /// `bash -c`, `sh -c`, `python -c`, `perl -e`, `awk`, `find -exec`,
    /// `xargs`, an `ssh` command string — reads a perfectly quoted word as
    /// code, and no quoting rule reaches inside it. Those are out of scope
    /// by standing decision, not covered here, and a snippet author placing
    /// a value into one is placing it into another language's parser.
    static let reparsingCommands: Set<String> = [
        "eval", "command", "builtin",
        "trap", "let", "source", ".", "alias",
        "declare", "typeset", "local", "export", "readonly", "unset", "read",
        "compgen", "complete", "bind", "fc", "history", "enable",
        "mapfile", "readarray",
    ]

    /// Reserved words this reader does not model, refused when they would be
    /// the command name.
    ///
    /// `[[` opens a conditional expression whose operators bring their own
    /// sub-languages: measured, `[[ 1 -eq 'a[$(touch M)]' ]]` runs the
    /// substitution, because a numeric comparison evaluates its operands as
    /// arithmetic and an array subscript in arithmetic is expanded. `test`
    /// and `[` do NOT — the same payload through either leaves no marker,
    /// they parse a number and stop — so they stay ordinary commands and
    /// `[ -f {{PATH}} ]` keeps working. `]]` is listed with it because a
    /// reader that refuses the opener has no business claiming to know the
    /// closer.
    static let unmodelledKeywords: Set<String> = ["[[", "]]"]

    /// The single left-to-right pass. Kept as a struct with one cursor so
    /// there is exactly one notion of "where we are" — the earlier design
    /// derived quoting state from a token list produced elsewhere, and the
    /// gap between "how the tokenizer split it" and "how a shell reads it"
    /// is where every past escape lived.
    ///
    /// It holds the command's `String.UnicodeScalarView` and NOT the
    /// `String`. Scalar-view indices are `String.Index` values, so the spans
    /// handed out stay comparable with ranges a caller found by ordinary
    /// text search.
    ///
    /// An earlier version of this comment claimed that holding only the
    /// scalar view made a `Character` comparison unwritable in here. It did
    /// not: a helper built a `String` out of the cursor's scalars, and
    /// `word.contains("=")` was written against that `String` — a
    /// `Character` test, sitting one line below a scalar test of the same
    /// `=`, disagreeing with it, and accepting `A=̈1 eval {{X}}` because it
    /// disagreed. The route is closed now by giving the helper a return type
    /// with no character access at all (`ShellWord`), so the claim is about
    /// a type rather than about a habit.
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

        mutating func read() -> Reading {
            while index < scalars.endIndex {
                let scalar = scalars[index]

                if ShellScalar.isLineFeed(scalar) {
                    advance()
                    beginCommand()
                    continue
                }
                if ShellScalar.isBlank(scalar) {
                    advance()
                    continue
                }
                // A `#` that reaches the top of this loop always begins a
                // comment, exactly as a shell has it, because every path
                // back to the top is a word boundary. Counted rather than
                // recalled, there are seven of them: the start of the text,
                // a line feed, an unquoted blank, a `#` comment, a
                // separator, a redirection operator, and the return from
                // `readWord`. The last two are the ones an earlier version
                // of this list left out, and both are still boundaries: the
                // comment branch stops ON a line feed or at the end of the
                // text, and `readWord` never breaks on `#`, so neither can
                // carry a mid-word `#` up here. A `#` in the MIDDLE of a word never
                // arrives here — `readWord` does not treat `#` as a word
                // terminator, so it is consumed inside the word and
                // `echo a#b` passes a literal `a#b`. That, and nothing
                // else, is what stops a mid-word `#` from being read as a
                // comment; reading it as one let a batch of templates
                // through a previous round.
                //
                // The comment then runs to the next LINE FEED and to
                // nothing else, because that is where `bash` ends one —
                // measured, not assumed (`ShellScalar.isLineFeed`). Ending
                // it at a CR, a VT, a NEL or a U+2028 the way
                // `Character.isNewline` would meant reading the rest of
                // `bash`'s comment as a fresh command and the placeholder
                // in it as an argument, while `bash` kept the value inside
                // the comment — where a value carrying a newline reopens
                // code. Running off the end of the text without finding a
                // line feed is the correct outcome, not a missing case: the
                // comment reaches the end for `bash` too.
                if scalar == "#" {
                    let start = index
                    while index < scalars.endIndex, !ShellScalar.isLineFeed(scalars[index]) {
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

        /// The scalars of `start..<end` as a `ShellWord` — a whole word, for
        /// comparison against a keyword set and for nothing else.
        ///
        /// It returns `ShellWord` rather than `String` because the `String`
        /// this used to return was the way back into the wrong alphabet:
        /// `word.contains("=")` was a `Character` test written against a
        /// cursor that is otherwise scalars all the way down. `ShellWord`
        /// offers no character access, so the same line does not compile any
        /// more. Built through the scalar view rather than by subscripting
        /// the original `String`, because a scalar-aligned index need not sit
        /// on a grapheme cluster boundary and slicing a `String` at one is
        /// not a well-defined thing to ask for.
        private func word(from start: String.Index, to end: String.Index) -> ShellWord {
            ShellWord(scalars[start..<end])
        }

        /// Whether the word `start..<end` contains a `=` SCALAR anywhere.
        ///
        /// The loose companion to `opensAssignment`, and loose on purpose:
        /// a false positive here only keeps the reader expecting a command
        /// name, which makes the NEXT word be checked as one instead of
        /// accepted as an argument. A false NEGATIVE is the unsafe
        /// direction, and it is what a `Character` `contains("=")` produced
        /// for `A=̈1`: `bash` reads that as an assignment (measured — the
        /// variable is set and the mark lands in its value), so `eval` after
        /// it is the command name, while the cluster test said "no `=`
        /// here" and handed `eval` on as an ordinary argument.
        ///
        /// Asking it in scalars also makes it a provable superset of
        /// `opensAssignment`, which scans the same scalars for the same `=`:
        /// wherever that one is true, this one is true too, so the branch
        /// that skips the command-name checks can never be the branch that
        /// also stops expecting a command name.
        private func containsAssignmentScalar(from start: String.Index, to end: String.Index)
            -> Bool {
            scalars[start..<end].contains { $0 == "=" }
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
        /// The word ends at a blank, at a line feed, or at any unquoted
        /// metacharacter, which is left for `read()` to classify — this
        /// method never consumes a separator. That is `bash`'s word
        /// boundary and no other: a CR, a VT, a form feed or a U+00A0 are
        /// ordinary word content, measured by printing the argument vector
        /// `bash` builds for `a<scalar>b`. Splitting a word `bash` keeps
        /// whole would put the tail of a command NAME into argument
        /// position, which is the wrong side to be wrong on.
        private mutating func readWord() -> Refusal? {
            let placement: Placement =
                expectsRedirectionTarget ? .redirectionTarget
                : expectsCommandName ? .commandName : .argument
            let wordStart = index
            var runStart: String.Index? = index
            var isPlainLiteral = true

            while index < scalars.endIndex {
                let scalar = scalars[index]
                if ShellScalar.endsAWord(scalar) || scalar == ";" || scalar == "&"
                    || scalar == "|" || scalar == "<" || scalar == ">"
                    || scalar == "(" || scalar == ")" || scalar == "`" {
                    break
                }
                if scalar == "'" || scalar == "\"" {
                    closeRun(&runStart, placement: placement)
                    isPlainLiteral = false
                    if let refusal = readQuotedSpan(quoteScalar: scalar) { return refusal }
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
                let word = word(from: wordStart, to: index)
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
                    if word.isOneOf(SnippetCommandSurvey.reparsingCommands) {
                        return .evaluation
                    }
                    // A reserved word this reader does not model. Refused
                    // here rather than read on as an ordinary command,
                    // because reading on is what turns "we have no rule for
                    // this" into acceptance.
                    if word.isOneOf(SnippetCommandSurvey.unmodelledKeywords) {
                        return .unrecognizedSyntax
                    }
                }
                // An assignment prefix (`DB=x cmd …`) and a word that
                // introduces another command both leave the command name
                // still to come — so the next word gets read as a name and
                // checked against the re-parsing set instead of being
                // accepted as an argument.
                //
                // Both questions about this word's `=` are now asked in the
                // same alphabet: `opensAssignment` above and
                // `containsAssignmentScalar` here read the same scalars, so
                // the strict test cannot say "assignment, skip the checks"
                // while the loose one says "no assignment, stop expecting a
                // name". Those two answers disagreeing over a `=` carrying a
                // combining mark is precisely how `A=̈1 eval {{X}}` was
                // accepted and ran its payload.
                if !containsAssignmentScalar(from: wordStart, to: index),
                   !word.isOneOf(SnippetCommandSurvey.commandIntroducers) {
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
        ///
        /// This is the ONE place the wide `looksLikeALineBreak` set is
        /// right, and it is right because the outcome is a refusal. `bash`
        /// would carry the span across a CR or a U+2028 happily; refusing
        /// there costs a legitimate command a nuisance, whereas the
        /// corresponding mistake in the other direction — deciding a
        /// construct ENDS at a scalar `bash` reads straight through — is
        /// what put a placeholder inside a `bash` comment while this type
        /// thought it was an argument.
        private mutating func readQuotedSpan(quoteScalar: Unicode.Scalar) -> Refusal? {
            let start = index
            advance()
            while index < scalars.endIndex {
                let scalar = scalars[index]
                if ShellScalar.looksLikeALineBreak(scalar) { return .unbalancedQuoting }
                if scalar == quoteScalar {
                    advance()
                    spans.append(Span(placement: .quoted, range: start..<index))
                    return nil
                }
                if quoteScalar == "\"" {
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
