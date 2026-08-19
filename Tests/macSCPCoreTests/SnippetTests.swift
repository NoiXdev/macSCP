import Foundation
import Testing
@testable import macSCPCore

@Suite("Snippet")
struct SnippetTests {
    /// Whitespace around a tag is typing noise, not part of the tag.
    @Test func aTagIsTrimmed() throws {
        let snippet = Snippet(name: "n", command: "c", tags: ["  docker  "])
        #expect(snippet.tags == ["docker"])
    }

    /// A tag that is only whitespace carries no meaning and would render as an
    /// empty chip nobody can aim at.
    @Test func anEmptyTagIsDropped() throws {
        let snippet = Snippet(name: "n", command: "c", tags: ["docker", "   ", ""])
        #expect(snippet.tags == ["docker"])
    }

    /// Case is preserved — the maintainer's decision. `Docker` and `docker` are
    /// two tags, and the suggestion list (not the store) is what keeps users
    /// from creating both by accident.
    @Test func caseIsPreserved() throws {
        let snippet = Snippet(name: "n", command: "c", tags: ["Docker", "docker"])
        #expect(snippet.tags == ["Docker", "docker"])
    }

    /// Exact duplicates collapse; order is the order they were entered in.
    @Test func exactDuplicatesCollapseAndOrderSurvives() {
        let snippet = Snippet(name: "n", command: "c", tags: ["b", "a", "b"])
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

    /// Guards against the two rules drifting apart: whatever `TagList`
    /// decides, `Snippet.tags` must land on exactly the same result.
    @Test func snippetTagsGoThroughTheSharedRule() {
        let inputs: [[String]] = [
            ["  docker ", "", "web", "docker"],
            ["Docker", "docker"],
            [],
            ["   "],
            ["a", "b", "a", "b"],
        ]
        for input in inputs {
            let snippet = Snippet(name: "n", command: "c", tags: input)
            #expect(snippet.tags == TagList.normalized(input))
        }
    }

    /// Part 2: a snippet may span lines. `"\r\n"` is ONE `Character` in
    /// Swift, so it gets its own case — a rule written with
    /// `contains("\n")` would not see it.
    @Test("a multi-line command is accepted and kept verbatim")
    func multilineCommandIsKept() {
        let snippet = Snippet(name: "deploy", command: "cd /srv\r\nmake all\n")
        #expect(snippet.command == "cd /srv\r\nmake all\n")
    }

    @Test("a multi-line command survives a store round trip")
    func multilineCommandSurvivesEncoding() throws {
        let original = Snippet(name: "deploy", command: "cd /srv\r\nmake all")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Snippet.self, from: data)
        #expect(decoded.command == original.command)
    }
}
