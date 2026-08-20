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
/// ## What the choice costs, and where it was checked rather than assumed
///
/// `"\r\n"` is one `Character` and two scalars, so a scalar walk sees two
/// line breaks where a character walk saw one. Every use of a line break in
/// this project is a state RESET — begin a new command, or refuse because a
/// quoted span crossed a line — and applying a reset twice is the same as
/// applying it once. That is the whole of the difference; it was walked
/// through rather than presumed, and `SnippetCommandSurveyTests` pins both
/// `\r` and `\r\n`.
///
/// The choice is also the strict direction everywhere else it differs: a
/// metacharacter carrying a combining mark now IS seen, which turns silent
/// acceptance into a refusal or a correctly-classified quoted span.
enum ShellScalar {
    /// The scalars that end a line. Exactly the set `Character.isNewline`
    /// reports, so replacing a character walk with a scalar walk cannot
    /// quietly drop a line terminator: CR, LF, the vertical and form feeds,
    /// NEL, and the two Unicode separators.
    static func isNewline(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// Whitespace, line breaks included — the Unicode `White_Space`
    /// property, which is what `Character.isWhitespace` reports too.
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        isNewline(scalar) || scalar.properties.isWhitespace
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
