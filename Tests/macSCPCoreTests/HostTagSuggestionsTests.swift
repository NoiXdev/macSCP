import Foundation
import Testing
@testable import macSCPCore

/// Mirrors `SnippetTagSuggestionsTests` — same case-insensitive-search,
/// case-preserving-return, count-then-alphabetical contract, exercised over
/// `StoredSession.tags` instead of `Snippet.tags`. See `HostTagSuggestions`'s
/// own doc comment for why this is a separate type rather than that one
/// reused or generalized.
@Suite("HostTagSuggestions")
struct HostTagSuggestionsTests {
    /// The whole point of the suggestion list, and the reason it exists at
    /// all: typing lowercase must surface an existing differently-cased tag,
    /// so the user picks it instead of creating a second one that
    /// `SidebarVisibility.compute`'s exact comparison would treat as
    /// unrelated.
    @Test func aLowercasePrefixFindsADifferentlyCasedTag() {
        var session = sshSession(name: "web", host: "h", username: "u")
        session.tags = ["Docker"]

        let matches = HostTagSuggestions.matching("doc", in: [session], excluding: [])

        #expect(matches.map(\.tag) == ["Docker"])
    }

    /// A tag already chosen in the field being typed into is not offered
    /// again.
    @Test func aTagAlreadyTakenIsNotOffered() {
        var session = sshSession(name: "web", host: "h", username: "u")
        session.tags = ["docker"]

        let matches = HostTagSuggestions.matching("doc", in: [session], excluding: ["docker"])

        #expect(matches.isEmpty)
    }

    /// The exclusion is case-insensitive too, not just the prefix search —
    /// the exact near-twin this type exists to prevent would otherwise slip
    /// through: a session tagged `docker` offering `Docker` (carried by
    /// another session) right back.
    @Test func aTagTakenInADifferentCaseIsNotOffered() {
        var sessionA = sshSession(name: "a", host: "h", username: "u")
        sessionA.tags = ["docker"]
        var sessionB = sshSession(name: "b", host: "h", username: "u")
        sessionB.tags = ["Docker"]

        let matches = HostTagSuggestions.matching("doc", in: [sessionA, sessionB], excluding: ["docker"])

        #expect(matches.isEmpty)
    }

    /// Counts drive the order, so the tags in heaviest use come first.
    @Test func theMostUsedTagComesFirst() {
        var sessionA = sshSession(name: "a", host: "h", username: "u")
        sessionA.tags = ["rare", "common"]
        var sessionB = sshSession(name: "b", host: "h", username: "u")
        sessionB.tags = ["common"]

        let matches = HostTagSuggestions.matching("", in: [sessionA, sessionB], excluding: [])

        #expect(matches.map(\.tag) == ["common", "rare"])
        #expect(matches.map(\.count) == [2, 1])
    }

    /// An empty prefix offers everything not already taken — what an empty,
    /// focused tag field should show.
    @Test func anEmptyPrefixOffersEverythingUntaken() {
        var session = sshSession(name: "web", host: "h", username: "u")
        session.tags = ["a", "b"]

        let matches = HostTagSuggestions.matching("", in: [session], excluding: ["a"])

        #expect(matches.map(\.tag) == ["b"])
    }

    /// A non-empty prefix filters out non-matching tags even when none is
    /// excluded — closes the gap a test that only combined a single tag
    /// with an empty prefix would leave (would still pass if `matching`
    /// ignored the prefix and only applied `excluding`).
    @Test func aPrefixExcludesNonMatchingTags() {
        var session = sshSession(name: "web", host: "h", username: "u")
        session.tags = ["docker", "vim"]

        let matches = HostTagSuggestions.matching("doc", in: [session], excluding: [])

        #expect(matches.map(\.tag) == ["docker"])
    }

    /// Ties break alphabetically, case-insensitively.
    @Test func tiedCountsBreakAlphabeticallyCaseInsensitively() {
        var session = sshSession(name: "web", host: "h", username: "u")
        session.tags = ["Banana", "apple", "cherry"]

        let matches = HostTagSuggestions.matching("", in: [session], excluding: [])

        #expect(matches.map(\.tag) == ["apple", "Banana", "cherry"])
    }

    /// Differently-cased tags are counted as separate entries, never merged
    /// — matching `StoredSession`'s case-preserving storage
    /// (`TagList.normalized` trims and dedupes exact duplicates only).
    @Test func differentlyCasedTagsAreCountedSeparately() {
        var sessionA = sshSession(name: "a", host: "h", username: "u")
        sessionA.tags = ["Docker"]
        var sessionB = sshSession(name: "b", host: "h", username: "u")
        sessionB.tags = ["docker"]

        let matches = HostTagSuggestions.matching("", in: [sessionA, sessionB], excluding: [])

        #expect(Set(matches.map(\.tag)) == ["Docker", "docker"])
        #expect(matches.allSatisfy { $0.count == 1 })
    }
}
