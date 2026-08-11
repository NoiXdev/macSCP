import Foundation
import Testing
@testable import macSCPCore

@Suite("Snippet")
struct SnippetTests {
    /// Whitespace around a tag is typing noise, not part of the tag.
    @Test func aTagIsTrimmed() throws {
        let snippet = try #require(Snippet(name: "n", command: "c", tags: ["  docker  "]))
        #expect(snippet.tags == ["docker"])
    }

    /// A tag that is only whitespace carries no meaning and would render as an
    /// empty chip nobody can aim at.
    @Test func anEmptyTagIsDropped() throws {
        let snippet = try #require(Snippet(name: "n", command: "c", tags: ["docker", "   ", ""]))
        #expect(snippet.tags == ["docker"])
    }

    /// Case is preserved — the maintainer's decision. `Docker` and `docker` are
    /// two tags, and the suggestion list (not the store) is what keeps users
    /// from creating both by accident.
    @Test func caseIsPreserved() throws {
        let snippet = try #require(Snippet(name: "n", command: "c", tags: ["Docker", "docker"]))
        #expect(snippet.tags == ["Docker", "docker"])
    }

    /// Exact duplicates collapse; order is the order they were entered in.
    @Test func exactDuplicatesCollapseAndOrderSurvives() throws {
        let snippet = try #require(
            Snippet(name: "n", command: "c", tags: ["b", "a", "b"]))
        #expect(snippet.tags == ["b", "a"])
    }

    /// A store file written before tags existed still loads, and the flag it
    /// carries is ignored rather than rejected — the user keeps their snippets.
    @Test func aRoundOneStoreFileLoadsWithoutTags() throws {
        let json = Data("""
            {"id":"11111111-1111-1111-1111-111111111111","name":"Restart",
             "command":"systemctl restart nginx","runsImmediately":true}
            """.utf8)

        let snippet = try JSONDecoder().decode(Snippet.self, from: json)

        #expect(snippet.tags.isEmpty)
        #expect(snippet.command == "systemctl restart nginx")
    }

    /// The tag rule is a model rule, so a hand-edited file cannot smuggle an
    /// untrimmed tag past it — the same reason the newline rule lives here.
    @Test func aHandEditedTagIsNormalizedOnDecode() throws {
        let json = Data("""
            {"id":"22222222-2222-2222-2222-222222222222","name":"n",
             "command":"c","tags":["  docker  ","",  "docker  "]}
            """.utf8)

        let snippet = try JSONDecoder().decode(Snippet.self, from: json)

        #expect(snippet.tags == ["docker"])
    }
}
