import Foundation
import Testing

@testable import macSCPCore

@Suite("SnippetTagSuggestions")
struct SnippetTagSuggestionsTests {
    /// The whole point of the suggestion list: typing lowercase must surface an
    /// existing differently-cased tag, so the user picks it instead of creating
    /// a second one. The store keeps the case; only the search ignores it.
    @Test func aLowercasePrefixFindsADifferentlyCasedTag() throws {
        let snippets = [try #require(Snippet(name: "n", command: "c", tags: ["Docker"]))]

        let matches = SnippetTagSuggestions.matching("doc", in: snippets, excluding: [])

        #expect(matches.map(\.tag) == ["Docker"])
    }

    /// A tag already on the snippet being edited is not offered again.
    @Test func aTagAlreadyTakenIsNotOffered() throws {
        let snippets = [try #require(Snippet(name: "n", command: "c", tags: ["docker"]))]

        let matches = SnippetTagSuggestions.matching("doc", in: snippets, excluding: ["docker"])

        #expect(matches.isEmpty)
    }

    /// Counts drive the order, so the tags in heaviest use come first.
    @Test func theMostUsedTagComesFirst() throws {
        let snippets = [
            try #require(Snippet(name: "a", command: "c", tags: ["rare", "common"])),
            try #require(Snippet(name: "b", command: "c", tags: ["common"])),
        ]

        let all = SnippetTagSuggestions.all(in: snippets)

        #expect(all.map(\.tag) == ["common", "rare"])
        #expect(all.map(\.count) == [2, 1])
    }

    /// An empty prefix offers everything not already taken — that is what the
    /// list shows when the field is focused but empty.
    @Test func anEmptyPrefixOffersEverythingUntaken() throws {
        let snippets = [try #require(Snippet(name: "n", command: "c", tags: ["a", "b"]))]

        let matches = SnippetTagSuggestions.matching("", in: snippets, excluding: ["a"])

        #expect(matches.map(\.tag) == ["b"])
    }

    /// A non-empty prefix filters out tags that do not start with it, even
    /// when none of them is excluded — the four brief-mandated tests above
    /// each involve only one tag or an empty prefix, so none of them alone
    /// would fail if `matching` ignored the prefix entirely and only applied
    /// `excluding`. This test exists to close that gap.
    @Test func aPrefixExcludesNonMatchingTags() throws {
        let snippets = [try #require(Snippet(name: "n", command: "c", tags: ["docker", "vim"]))]

        let matches = SnippetTagSuggestions.matching("doc", in: snippets, excluding: [])

        #expect(matches.map(\.tag) == ["docker"])
    }

    /// Ties break alphabetically, case-insensitively — pinning the order is
    /// the point: a test that only checked membership would not catch a
    /// broken tie-break (e.g. a case-sensitive compare that puts every
    /// capitalized tag before every lowercase one).
    @Test func tiedCountsBreakAlphabeticallyCaseInsensitively() throws {
        let snippets = [
            try #require(Snippet(name: "a", command: "c", tags: ["Banana", "apple", "cherry"])),
        ]

        let all = SnippetTagSuggestions.all(in: snippets)

        #expect(all.map(\.tag) == ["apple", "Banana", "cherry"])
    }
}
