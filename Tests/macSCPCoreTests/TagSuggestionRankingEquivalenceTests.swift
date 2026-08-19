import Foundation
import Testing
@testable import macSCPCore

/// Pins that `SnippetTagSuggestions` and `HostTagSuggestions` still agree
/// with the shared `TagSuggestionRanking` engine they were extracted onto
/// (Task 5, fix round 2) — the same shape `SnippetTests`'s "Guards against
/// the two rules drifting apart" test pins for `TagList.normalized`
/// (Task 1). Neither `SnippetTagSuggestionsTests` nor
/// `HostTagSuggestionsTests` would notice a regression where one caller's
/// `matching`/`all` were edited to inline its own count/rank/filter logic
/// again instead of delegating: each of those suites only ever exercises
/// its own type in isolation, and a reimplementation that merely LOOKS the
/// same would still pass both. These tests compare each public entry point
/// against `TagSuggestionRanking` directly, and against each other on
/// identical tag data, so a drift in either direction fails here even if it
/// fails nowhere else.
///
/// Scope, precisely: every case below passes `prefix: ""`, so what is
/// pinned is drift in COUNTING and RANKING, not in prefix matching. A
/// caller that reimplemented prefix filtering differently would slip past
/// this suite; that is caught instead by each type's own prefix tests
/// (`HostTagSuggestionsTests`, `SnippetTagSuggestionsTests`), which is why
/// broadening this suite would duplicate coverage rather than add it.
@Suite("Tag suggestion ranking equivalence")
struct TagSuggestionRankingEquivalenceTests {
    private static let sampleTagLists = [["Docker", "rare"], ["docker", "common"], ["common"]]

    /// `[(tag, count)]` as an unordered `[String: Int]` — comparing CONTENT,
    /// not order. Order between two entries the ranking treats as tied
    /// (equal count, case-insensitively equal tag — e.g. "Docker" vs
    /// "docker") depends on `Dictionary`'s own iteration order inside
    /// `TagSuggestionRanking`, which is not guaranteed identical across two
    /// separately-built dictionaries with the same content even in the same
    /// process. Pinning exact order for that case would pin an accident of
    /// hashing, not a behavior these types promise — the SAME reason
    /// `HostTagSuggestionsTests.differentlyCasedTagsAreCountedSeparately`/
    /// `SnippetTagSuggestionsTests`'s counterpart compare via `Set`, not
    /// array order, for exactly this tie.
    private static func contentMap(_ results: [(tag: String, count: Int)]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: results)
    }

    @Test func snippetTagSuggestionsAgreesWithTheSharedRankingEngine() throws {
        let snippets = try Self.sampleTagLists.enumerated().map { index, tags in
            Snippet(name: "s\(index)", command: "c", tags: tags)
        }

        let expected = TagSuggestionRanking.matching("", tagLists: Self.sampleTagLists, excluding: ["rare"])
        let actual = SnippetTagSuggestions.matching("", in: snippets, excluding: ["rare"])

        #expect(Self.contentMap(actual) == Self.contentMap(expected))
    }

    @Test func hostTagSuggestionsAgreesWithTheSharedRankingEngine() {
        let sessions = Self.sampleTagLists.enumerated().map { index, tags -> StoredSession in
            var session = sshSession(name: "h\(index)", host: "h", username: "u")
            session.tags = tags
            return session
        }

        let expected = TagSuggestionRanking.matching("", tagLists: Self.sampleTagLists, excluding: ["rare"])
        let actual = HostTagSuggestions.matching("", in: sessions, excluding: ["rare"])

        #expect(Self.contentMap(actual) == Self.contentMap(expected))
    }

    /// Cross-vocabulary: feeding IDENTICAL tag data through both public
    /// entry points must produce identical output, since both are now the
    /// same engine underneath a different element type.
    @Test func snippetAndHostSuggestionsAgreeOnIdenticalTagData() throws {
        let snippets = try Self.sampleTagLists.enumerated().map { index, tags in
            Snippet(name: "s\(index)", command: "c", tags: tags)
        }
        let sessions = Self.sampleTagLists.enumerated().map { index, tags -> StoredSession in
            var session = sshSession(name: "h\(index)", host: "h", username: "u")
            session.tags = tags
            return session
        }

        let snippetResult = SnippetTagSuggestions.matching("", in: snippets, excluding: [])
        let hostResult = HostTagSuggestions.matching("", in: sessions, excluding: [])

        #expect(Self.contentMap(snippetResult) == Self.contentMap(hostResult))
    }

    /// `SidebarVisibility.availableTags(in:)` now also routes through
    /// `TagSuggestionRanking.counts(tagLists:)` (fix round 2, closing the
    /// "third walk" the reviewer found) — pins that its distinct-tag answer
    /// still agrees with the engine's own key set for the same sessions.
    @Test func availableTagsAgreesWithTheSharedRankingEngine() {
        let sessions = Self.sampleTagLists.enumerated().map { index, tags -> StoredSession in
            var session = sshSession(name: "h\(index)", host: "h", username: "u")
            session.tags = tags
            return session
        }

        let expected = Array(TagSuggestionRanking.counts(tagLists: Self.sampleTagLists).keys).sorted()
        let actual = SidebarVisibility.availableTags(in: sessions)

        #expect(actual == expected)
    }
}
