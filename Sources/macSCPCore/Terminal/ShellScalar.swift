import Foundation

/// The unit every shell-syntax comparison in this project is made in:
/// `Unicode.Scalar`.
///
/// ## Why not `Character`
///
/// Swift's `Character` is an extended grapheme cluster — what a *reader*
/// perceives as one symbol. A shell reads *bytes*. The two disagree wherever
/// a combining mark follows a metacharacter: an apostrophe followed by
/// U+0308 COMBINING DIAERESIS is ONE `Character` that does not compare equal
/// to `"'"`, and that `String.replacingOccurrences(of: "'")` does not find
/// either, because Foundation matches on clusters and canonical equivalence
/// unless told otherwise. `bash` sees the apostrophe and opens a quoted
/// span; Swift sees a symbol it has no rule for.
///
/// A review round walked through that gap in two places at once: the quoter
/// did not escape such an apostrophe, so a VALUE broke out of its own single
/// quotes with no crafted template at all; and the recogniser did not see
/// such a quote, so a placeholder a shell reads as quoted was classified as
/// an unquoted argument. Both were verified by executing the result in real
/// `bash`. The instances were two; the cause was one — comparing in the
/// wrong alphabet.
///
/// The round after that found the sweep had missed a line: a `Character`
/// `contains("=")` sitting beside a scalar test of the same `=`, which is
/// how `A=̈1 eval {{X}}` was accepted and executed. Hence `ShellWord` below,
/// and hence the rule this file now states outright: **a comparison against
/// shell text is made on `Unicode.Scalar`s, and the types here are shaped so
/// that the other unit is not reachable rather than merely discouraged.**
///
/// ## Why `Unicode.Scalar` and not UTF-8
///
/// Everything a POSIX shell tokenizes on is ASCII, and every ASCII character
/// is exactly one scalar and exactly one UTF-8 byte, so the two units answer
/// every question asked here identically. Scalars win on mechanics: an index
/// into `String.UnicodeScalarView` IS a `String.Index`, so ranges produced by
/// a scalar walk can be compared with ranges produced by any other view
/// without conversion — which is what lets `SnippetCommandSurvey` hand its
/// spans to a caller that found its `{{NAME}}` occurrences by ordinary text
/// search.
///
/// ## The second rule: a predicate here must not be wider than `bash`'s
///
/// Choosing the right unit only moves the question. A predicate spelled in
/// scalars can still recognise a lexical event that `bash` does not, and
/// where it does, the placeholder ends up in a context this project
/// mis-modelled — which resolves to acceptance, because acceptance is what
/// "we understood this" means here.
///
/// That is exactly how the line predicate failed. `isNewline` reported CR,
/// VT, FF, NEL, U+2028 and U+2029 as line terminators, on the reasoning that
/// this is the set `Character.isNewline` reports. `bash` ends a line at
/// U+000A and at nothing else — measured, by running each of the six through
/// `bash` with a `#` comment in front of it: the comment ended at LF and ran
/// through all six others. So a comment ended for us where `bash`'s kept
/// running, the placeholder after it was classified `.argument`, and a value
/// carrying a newline (an imported `defaultValue` can) reopened code from
/// inside the comment.
///
/// The predicates below are therefore split by *whose* question they answer,
/// and each one names the measurement behind it:
///
/// - `isLineFeed` and `isBlank` are `bash`'s own lexical rules, no wider.
/// - `looksLikeALineBreak` is the WIDE set, and it is used in exactly one
///   direction: to refuse. Extending a refusal too far costs a nuisance;
///   ending a span too early costs the gate.
/// - `isAnyUnicodeWhitespace` is not a shell rule at all. It backs a ban
///   list on connection fields, where "any whitespace whatsoever" is the
///   intent and being wider than `bash` is the point.
///
/// ## What the scalar unit costs on line breaks
///
/// `"\r\n"` is one `Character` and two scalars. It no longer matters for
/// tokenizing — CR is ordinary word content now, exactly as `bash` has it —
/// but it still matters for `looksLikeALineBreak`, where CR and LF each
/// refuse a quoted span and refusing twice is the same as refusing once.
///
/// A line terminator cannot be decorated, which is worth knowing before
/// looking for that hole: Unicode's grapheme rules break *around* controls,
/// so LF followed by U+0308 is two `Character`s, not one. The combining-mark
/// trick that works on `'` and on `=` has no line-break variant.
enum ShellScalar {
    /// The one scalar `bash` ends a line with: U+000A LINE FEED.
    ///
    /// A `#` comment runs to the next one of these and a command ends at
    /// one; nothing else in Unicode does either job. Measured rather than
    /// reasoned: `ls # note<X>touch MARK` run through `/bin/bash` created
    /// the marker for LF and for no other candidate terminator.
    static func isLineFeed(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x0A
    }

    /// `bash`'s blanks — space and tab, and nothing else.
    ///
    /// Also measured: `printf "[%s]" a<X>b` produced two arguments for space
    /// and tab and ONE for CR, VT, FF and U+00A0. Treating those as word
    /// separators split words `bash` keeps whole, which put the tail of a
    /// command name into argument position; matching `bash` here removes a
    /// whole class of disagreement rather than picking a safe side of it.
    static func isBlank(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t"
    }

    /// Where a word ends for `bash`: a blank or a line feed.
    ///
    /// The caller breaks a word on more than this, and the rest are matched
    /// at the call site because it does not merely skip them, it classifies
    /// them. Counted there while writing this: eight, namely `;`, `&`, `|`,
    /// `<`, `>`, `(`, `)` — `bash`'s remaining metacharacters — and the
    /// backtick, which is not one of `bash`'s metacharacters but ends a word
    /// here anyway because it opens a command substitution this type
    /// refuses.
    static func endsAWord(_ scalar: Unicode.Scalar) -> Bool {
        isBlank(scalar) || isLineFeed(scalar)
    }

    /// Every scalar some Unicode-aware reader would call a line terminator:
    /// LF, CR, the vertical and form feeds, NEL, and the two Unicode
    /// separators — the set `Character.isNewline` reports.
    ///
    /// `bash` calls exactly one of them a line terminator (`isLineFeed`), so
    /// this set must never decide where a construct ENDS. It exists for the
    /// opposite direction: a quoted span that crosses any of these is
    /// refused rather than followed, and over-refusing there is the safe
    /// side — a multi-line quoted string is legal shell that this project
    /// simply declines to reason across.
    static func looksLikeALineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// Whitespace in the Unicode sense, line breaks included — NOT `bash`'s
    /// blanks. The one caller is a ban list on connection fields
    /// (`SSHConnectionConfig`), which rejects a value containing any
    /// whitespace at all; there, being wider than `bash` is the intent.
    /// Shell lexing must use `isBlank`.
    static func isAnyUnicodeWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        looksLikeALineBreak(scalar) || scalar.properties.isWhitespace
    }

    /// `[A-Za-z_]`. ASCII on purpose: a shell identifier is ASCII, and a
    /// letter-like scalar from another script must not be read as the start
    /// of a name this type would then treat as understood.
    static func isASCIILetterOrUnderscore(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "_": return true
        default: return false
        }
    }

    /// `[0-9]`, ASCII for the same reason.
    static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }
}

/// A run of scalars lifted out of a scalar walk for the one thing a `String`
/// is still needed for: comparing it against a fixed set of ASCII keywords.
///
/// It exists to close a route, not to add an ability. `SnippetCommandSurvey`
/// already held only its `String.UnicodeScalarView` so that a `Character`
/// comparison could not be written against its cursor — and a helper handed
/// out a plain `String` anyway, against which `word.contains("=")` was
/// written. That is a `Character` test: `"="` followed by a combining mark
/// is one cluster unequal to `"="`, so the test came out false beside a
/// scalar test of the same `=` that came out true, and the two answers
/// disagreeing is what let `A=̈1 eval {{X}}` through to a shell.
///
/// So the text is wrapped and no character access is offered: no `contains`,
/// no `first`, no subscript, no iteration. `isOneOf` is the whole surface,
/// and asking anything else does not compile.
///
/// Comparing whole words as `String`s is safe here, and an earlier version
/// of this comment gave the wrong reason for it. It claimed that no other
/// scalar sequence is canonically equivalent to an all-ASCII string. That is
/// false: `"\u{212A}" == "K"` is `true` in Swift, U+212A KELVIN SIGN having
/// a canonical decomposition to U+004B, and U+212B ÅNGSTRÖM SIGN behaves the
/// same way. Swift's `==` on `String` is canonical equivalence, not a byte
/// comparison, and no amount of the keywords being ASCII changes that.
///
/// The reason that does hold is about DIRECTION, and it holds for every
/// keyword set this is asked about. Each caller's true branch is the
/// stricter reading: a hit on `reparsingCommands` or `unmodelledKeywords` is
/// a refusal, and a hit on `commandIntroducers` keeps the reader expecting a
/// command name, which only adds checks. So a comparison that says yes too
/// often costs a nuisance. And it cannot say no too often in a way that
/// matters, because `bash` matches its own reserved words and builtins on
/// BYTES: a word whose bytes differ from `eval` is not `eval` to `bash`
/// either, so the two disagree about nothing. Measured on the obvious
/// candidate: `"ev\u{0308}al" == "eval"` is `false` here, and `bash` runs no
/// builtin for it.
///
/// `shellWordKeywordSetsAreASCII` still pins the sets as ASCII — a non-ASCII
/// keyword would be a question about equivalence classes rather than about
/// bytes, and nobody should have to reason about that here — but it is a
/// tidiness rule, not the thing that makes the comparison sound.
struct ShellWord {
    private let text: String

    init(_ scalars: String.UnicodeScalarView.SubSequence) {
        self.text = String(String.UnicodeScalarView(scalars))
    }

    /// Whether this word is exactly one of `keywords`. `keywords` must be
    /// ASCII for the comparison to be a byte comparison; every set passed in
    /// is a shell keyword list, and `shellWordKeywordSetsAreASCII` pins that.
    func isOneOf(_ keywords: Set<String>) -> Bool {
        keywords.contains(text)
    }
}
