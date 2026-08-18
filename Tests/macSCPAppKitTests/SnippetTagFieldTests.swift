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

    // MARK: - SnippetTagFieldHighlight

    @Test func clampedReturnsNilForAnEmptyRowList() {
        #expect(SnippetTagFieldHighlight.clamped(0, rowCount: 0) == nil)
    }

    @Test func clampedKeepsAnInBoundsIndexUnchanged() {
        #expect(SnippetTagFieldHighlight.clamped(1, rowCount: 3) == 1)
    }

    /// The claim that actually matters: a stored index from a longer,
    /// earlier row list must come back inside the new, shorter list — not
    /// past its end, where `rows[highlighted]` would be an out-of-bounds
    /// crash (see `SnippetTagFieldHighlight`'s doc comment).
    @Test func clampedPullsAnOutOfBoundsIndexBackToTheLastRow() {
        #expect(SnippetTagFieldHighlight.clamped(5, rowCount: 2) == 1)
    }

    /// No caller passes a negative index today — `highlightedIndex` starts
    /// at `0` and only ever moves through `CandidateCycle` — but the doc
    /// comment promises the result lands in `0..<rowCount`, so the lower
    /// bound must hold even for an input nothing in this codebase produces
    /// yet.
    @Test func clampedPullsANegativeIndexUpToTheFirstRow() {
        #expect(SnippetTagFieldHighlight.clamped(-1, rowCount: 3) == 0)
    }

    // MARK: - SnippetTagFieldRow.tag

    @Test func tagOfAnExistingRowIsTheStoredTagVerbatim() {
        #expect(SnippetTagFieldRow.existing(tag: "Docker", count: 3).tag == "Docker")
    }

    @Test func tagOfACreateNewRowIsTheCandidateText() {
        #expect(SnippetTagFieldRow.createNew(tag: "docker").tag == "docker")
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

    /// The doc comment specifically claims "first occurrence" — not
    /// reachable through normal use (`appending` never lets a duplicate
    /// in), but nothing enforces that from `removing`'s own signature, so a
    /// future caller relying on this from a duplicate-containing array
    /// should find the FIRST one gone, not all of them and not the last.
    @Test func removingWithADuplicateTagDropsOnlyTheFirstOccurrence() {
        #expect(SnippetTagCommit.removing("a", from: ["a", "b", "a"]) == ["b", "a"])
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

    // MARK: - Equivalence with TagList

    /// Guards against `commaSplit`'s committed segments drifting from the
    /// shared rule in `TagList` — a later change to what counts as empty or
    /// as whitespace there must reach this call site too, not just
    /// `Snippet`.
    @Test func commaSplitCommittedSegmentsAgreeWithTagListNormalized() {
        let inputs = ["docker,", "a,b,c", "  a  , b ,", ",,", "Docker,docker,", "a,a,b,"]
        for input in inputs {
            let allSegments = input.components(separatedBy: ",")
            let precedingLastSegments = Array(allSegments.dropLast())
            #expect(
                SnippetTagFieldInput.commaSplit(input).tagsToCommit
                    == TagList.normalized(precedingLastSegments))
        }
    }

    /// Guards against the create-new row's trim drifting from the same
    /// shared rule — the row's tag is exactly what `SnippetTagCommit.
    /// appending` puts in `tags` on commit, so it must always agree with
    /// what `TagList` would keep or drop for that one candidate string.
    @Test func createNewRowTagAgreesWithTagListNormalized() {
        let inputs = ["docker", "  Docker  ", "   ", "", "a b"]
        for input in inputs {
            let rows = SnippetTagFieldSuggestions.rows(typed: input, suggestions: [])
            if let expected = TagList.normalized([input]).first {
                #expect(rows == [.createNew(tag: expected)])
            } else {
                #expect(rows.isEmpty)
            }
        }
    }
}
