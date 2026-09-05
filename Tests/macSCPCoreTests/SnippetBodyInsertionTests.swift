import Foundation
import Testing
@testable import macSCPCore

/// Where a `{{NAME}}` placeholder lands when the snippet editor's row
/// button inserts one -- the residual the backlog left open on 2026-09-02
/// ("the row's insert path appends at the end"). Pure and index-based, so
/// every case named in the backlog row is provable without an
/// `NSTextView`: no selection appends, a caret inserts in place, a
/// non-empty selection is replaced, a selection at the very start, and
/// unicode ahead of the caret still lands the cursor on a grapheme
/// boundary.
///
/// `SnippetsPresentation.swift`'s `snippetCommandInsertingPlaceholder`
/// (App layer, tested in `SnippetPlaceholderHelpTests`) delegates its own
/// append behaviour to this type's `nil`-selection branch, so there is one
/// algorithm for "no caret to speak of", not two that happen to agree.
@Suite("Snippet body insertion")
struct SnippetBodyInsertionTests {
    @Test func noSelectionAppendsAtTheEnd() {
        let result = SnippetBodyInsertion.insert("{{TARGET}}", into: "scp", at: nil)
        #expect(result.body == "scp {{TARGET}}")
        #expect(result.cursorAfter == result.body.endIndex)
    }

    @Test func noSelectionOnAnEmptyBodyWritesJustThePlaceholder() {
        let result = SnippetBodyInsertion.insert("{{TARGET}}", into: "", at: nil)
        #expect(result.body == "{{TARGET}}")
        #expect(result.cursorAfter == result.body.endIndex)
    }

    @Test func aCaretMidTextInsertsThereAndLeavesTheCursorAfterThePlaceholder() {
        let prefix = "cp "
        let suffix = "/dst"
        let body = prefix + suffix
        let caret = body.index(body.startIndex, offsetBy: prefix.count)
        let result = SnippetBodyInsertion.insert("{{SRC}}", into: body, at: caret..<caret)
        #expect(result.body == prefix + "{{SRC}}" + suffix)
        #expect(String(result.body[..<result.cursorAfter]) == prefix + "{{SRC}}")
    }

    @Test func aNonEmptySelectionIsReplaced() {
        let body = "echo OLD done"
        let range = body.range(of: "OLD")!
        let result = SnippetBodyInsertion.insert("{{NEW}}", into: body, at: range)
        #expect(result.body == "echo {{NEW}} done")
        #expect(String(result.body[..<result.cursorAfter]) == "echo {{NEW}}")
    }

    @Test func aSelectionAtTheVeryStartInsertsBeforeEverythingElse() {
        let body = "scp file"
        let start = body.startIndex
        let result = SnippetBodyInsertion.insert("{{HOST}}", into: body, at: start..<start)
        #expect(result.body == "{{HOST}}" + body)
        #expect(String(result.body[..<result.cursorAfter]) == "{{HOST}}")
    }

    /// An emoji and a combining sequence ahead of the caret: both are more
    /// than one UTF-16 code unit (the emoji) or more than one Unicode
    /// scalar (the combining accent) per `Character`, so an implementation
    /// that walked UTF-16 or scalars instead of `Character`s would land the
    /// cursor mid-grapheme.
    @Test func unicodeBeforeTheCaretLandsTheCursorCorrectly() {
        let prefix = "echo \u{1F680}e\u{0301} "  // rocket, then e + combining acute accent
        let body = prefix + "done"
        let caret = body.index(body.startIndex, offsetBy: prefix.count)
        let result = SnippetBodyInsertion.insert("{{X}}", into: body, at: caret..<caret)
        #expect(result.body == prefix + "{{X}}done")
        #expect(String(result.body[..<result.cursorAfter]) == prefix + "{{X}}")
    }
}
