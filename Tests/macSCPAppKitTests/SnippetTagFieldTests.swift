import Foundation
import Testing
import macSCPCore
@testable import MacSCPAppKit

/// Covers the pure decisions `SnippetTagField` defers to rather than making
/// inline — which rows the suggestion list shows, what committing a tag or
/// removing a chip does to the `tags` array, and how typed text splits on
/// commas. The view itself renders none of this directly: it calls these
/// functions and displays their results, so nothing here needs SwiftUI or a
/// rendered view (see `SnippetsSheet`'s doc comment on that boundary, which
/// this file's target shares).
@Suite("SnippetTagField logic")
struct SnippetTagFieldTests {
    // MARK: - SnippetTagFieldSuggestions.rows

    @Test func suggestionsBecomeExistingRowsInOrder() {
        let rows = SnippetTagFieldSuggestions.rows(
            typed: "", suggestions: [(tag: "Docker", count: 3), (tag: "compose", count: 1)])

        #expect(rows == [.existing(tag: "Docker", count: 3), .existing(tag: "compose", count: 1)])
    }

    @Test func nonEmptyTypedTextAppendsACreateNewRow() {
        let rows = SnippetTagFieldSuggestions.rows(typed: "docker", suggestions: [])

        #expect(rows == [.createNew(tag: "docker")])
    }

    @Test func emptyTypedTextAppendsNoCreateNewRow() {
        let rows = SnippetTagFieldSuggestions.rows(
            typed: "", suggestions: [(tag: "Docker", count: 1)])

        #expect(rows == [.existing(tag: "Docker", count: 1)])
    }

    @Test func whitespaceOnlyTypedTextAppendsNoCreateNewRow() {
        let rows = SnippetTagFieldSuggestions.rows(typed: "   ", suggestions: [])

        #expect(rows.isEmpty)
    }

    /// The create-new row is trimmed, and appended even when it exactly
    /// duplicates a suggestion already in the list — see
    /// `SnippetTagFieldSuggestions`'s doc comment on why this function does
    /// not special-case that instead of leaving it to `SnippetTagCommit.
    /// appending` at commit time.
    @Test func createNewRowIsTrimmedAndAppearsEvenIfItDuplicatesASuggestion() {
        let rows = SnippetTagFieldSuggestions.rows(
            typed: "  Docker  ", suggestions: [(tag: "Docker", count: 2)])

        #expect(rows == [.existing(tag: "Docker", count: 2), .createNew(tag: "Docker")])
    }

    // MARK: - SnippetTagCommit

    @Test func appendingANewTagAddsItAtTheEnd() {
        #expect(SnippetTagCommit.appending("b", to: ["a"]) == ["a", "b"])
    }

    @Test func appendingAnAlreadyPresentTagIsANoOp() {
        #expect(SnippetTagCommit.appending("a", to: ["a", "b"]) == ["a", "b"])
    }

    /// Exact (case-sensitive) comparison — the same rule `Snippet.tags`
    /// itself normalizes by (see that type's doc comment): "docker" and
    /// "Docker" are two different tags, so both may coexist.
    @Test func appendingIsCaseSensitive() {
        #expect(SnippetTagCommit.appending("docker", to: ["Docker"]) == ["Docker", "docker"])
    }

    @Test func removingAnExistingTagDropsExactlyThatOne() {
        #expect(SnippetTagCommit.removing("b", from: ["a", "b", "c"]) == ["a", "c"])
    }

    @Test func removingAnAbsentTagIsANoOp() {
        #expect(SnippetTagCommit.removing("x", from: ["a", "b"]) == ["a", "b"])
    }

    @Test func removingLastDropsTheLastTag() {
        #expect(SnippetTagCommit.removingLast(from: ["a", "b"]) == ["a"])
    }

    @Test func removingLastFromAnEmptyListIsANoOp() {
        #expect(SnippetTagCommit.removingLast(from: []).isEmpty)
    }

    // MARK: - SnippetTagFieldInput.commaSplit

    @Test func textWithNoCommaCommitsNothingAndKeepsTheWholeText() {
        let result = SnippetTagFieldInput.commaSplit("docker")

        #expect(result.tagsToCommit.isEmpty)
        #expect(result.remaining == "docker")
    }

    @Test func oneTrailingCommaCommitsTheTagBeforeItAndClearsTheField() {
        let result = SnippetTagFieldInput.commaSplit("docker,")

        #expect(result.tagsToCommit == ["docker"])
        #expect(result.remaining.isEmpty)
    }

    @Test func multipleCommasCommitEverySegmentButTheLast() {
        let result = SnippetTagFieldInput.commaSplit("a,b,c")

        #expect(result.tagsToCommit == ["a", "b"])
        #expect(result.remaining == "c")
    }

    @Test func segmentsAreTrimmedBeforeBeingCommitted() {
        let result = SnippetTagFieldInput.commaSplit("  a  , b ,")

        #expect(result.tagsToCommit == ["a", "b"])
        #expect(result.remaining.isEmpty)
    }

    @Test func emptySegmentsCommitNothing() {
        let result = SnippetTagFieldInput.commaSplit(",,")

        #expect(result.tagsToCommit.isEmpty)
        #expect(result.remaining.isEmpty)
    }
}
