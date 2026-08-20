import Foundation
import Testing
@testable import macSCPCore

/// Covers what the snippet editor colours BEFORE any view is involved:
/// which ranges of a command are what. No colours here -- Core does not
/// know any; the App layer maps kinds to design tokens.
@Suite("Snippet highlighter")
struct SnippetHighlighterTests {
    /// Reads a token back as the substring it covers, so the expectations
    /// below stay readable and do not depend on index arithmetic.
    private func spans(_ text: String, _ kind: SnippetToken.Kind) -> [String] {
        SnippetHighlighter.tokens(in: text, language: .shell)
            .filter { $0.kind == kind }
            .map { String(text[$0.range]) }
    }

    @Test func theFirstWordIsTheCommand() {
        #expect(spans("docker ps -a", .command) == ["docker"])
    }

    @Test func dashedWordsAreOptions() {
        #expect(spans("tail -f --lines 20 x.log", .option) == ["-f", "--lines"])
    }

    @Test func quotedRunsAreStrings() {
        #expect(spans("echo 'a b' \"c d\"", .string) == ["'a b'", "\"c d\""])
    }

    @Test func dollarNamesAreVariables() {
        #expect(spans("echo $HOME ${TAG}", .variable) == ["$HOME", "${TAG}"])
    }

    @Test func hashStartsACommentToEndOfLine() {
        #expect(spans("ls # list them", .comment) == ["# list them"])
    }

    @Test func pipesAndSemicolonsAreOperators() {
        #expect(spans("a | b && c ; d > e", .operator) == ["|", "&&", ";", ">"])
    }

    // --- the traps -------------------------------------------------------

    /// An unterminated quote runs to the end rather than swallowing the
    /// tokenizer or producing nothing.
    @Test func anUnterminatedStringRunsToTheEnd() {
        #expect(spans("echo \"abc", .string) == ["\"abc"])
    }

    /// A `#` INSIDE a string is text, not a comment -- the single most
    /// common way a naive scanner breaks.
    @Test func aHashInsideAStringIsNotAComment() {
        #expect(spans("echo 'a # b'", .comment).isEmpty)
        #expect(spans("echo 'a # b'", .string) == ["'a # b'"])
    }

    /// A `$` with no name after it is not a variable.
    @Test func aDollarWithoutANameIsNotAVariable() {
        #expect(spans("echo $", .variable).isEmpty)
    }

    /// Constant-return probe, the other direction: a tokenizer that marks
    /// EVERYTHING as the command fails here, and one that marks everything
    /// plain fails every test above.
    @Test func onlyTheFirstWordIsTheCommand() {
        let text = "cp source target"
        #expect(spans(text, .command) == ["cp"])
        #expect(spans(text, .plain) == ["source", "target"])
    }

    // --- multi-line and escapes ------------------------------------------

    /// A comment ends at the LINE break, not at the end of the text. The
    /// branch used to run to `text.endIndex` and stop tokenising there, so
    /// in a multi-line command the first `#` swallowed every later line --
    /// wrong colouring. It was also, at the time, a hole in the snippet
    /// variable gate, which read these tokens; that gate has its own
    /// recogniser now (`SnippetCommandSurveyTests`), and nothing here is
    /// load-bearing for it any more.
    @Test func aCommentEndsAtTheLineBreakNotAtTheEndOfTheText() {
        let text = "ls # list them\necho \"still a string\""
        #expect(spans(text, .comment) == ["# list them"])
        #expect(spans(text, .string) == ["\"still a string\""])
    }

    /// The same fix seen from the first line: a command that OPENS with a
    /// comment still colours everything below it.
    @Test func aLeadingCommentDoesNotSwallowTheLinesBelowIt() {
        let text = "# note\necho \"value\""
        #expect(spans(text, .comment) == ["# note"])
        #expect(spans(text, .string) == ["\"value\""])
        #expect(spans(text, .command) == ["echo"])
    }

    /// Inside a DOUBLE-quoted span a backslash escapes the next character,
    /// so `\"` does not close the span.
    @Test func aBackslashEscapesTheClosingDoubleQuote() {
        #expect(spans(#"echo "a\"b" tail"#, .string) == [#""a\"b""#])
    }

    /// A trailing backslash inside a double-quoted span escapes the quote
    /// that would have closed it, so the span is unterminated and runs to
    /// the end rather than looping forever.
    @Test func aDoubleQuotedSpanEndingInAnEscapedQuoteIsUnterminated() {
        #expect(spans(#"echo "a\""#, .string) == [#""a\""#])
    }

    /// The POSIX asymmetry: a SINGLE-quoted span honours no escape at all.
    /// Everything up to the next `'` is literal, backslash included, so
    /// `'a\'` closes at that second quote and `b'` opens a new span.
    @Test func aBackslashDoesNotEscapeInsideASingleQuotedSpan() {
        #expect(spans(#"echo 'a\' b'c'"#, .string) == [#"'a\'"#, "'c'"])
    }
}
