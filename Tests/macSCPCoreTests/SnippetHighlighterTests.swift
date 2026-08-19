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

    // --- newline rejection ----------------------------------------------

    /// `Snippet.init?` refuses any newline, and an `NSTextView` accepts
    /// Return by default. Pasting a two-line command must therefore become
    /// one line rather than a value the model rejects on save.
    @Test func newlinesBecomeSpaces() {
        #expect(SnippetCommandInput.sanitized("a\nb") == "a b")
    }

    /// CRLF is ONE `Character` in Swift, so a naive `contains("\n")` misses
    /// it -- the same trap `Snippet.init?` was fixed for in P3e.
    @Test func aCarriageReturnLineFeedAlsoBecomesOneSpace() {
        #expect(SnippetCommandInput.sanitized("a\r\nb") == "a b")
    }

    @Test func textWithoutNewlinesIsUnchanged() {
        #expect(SnippetCommandInput.sanitized("docker ps -a") == "docker ps -a")
    }
}
