import Foundation
import Testing
import macSCPCore
@testable import MacSCPAppKit

/// Covers `TerminalSnippetSearch.matching` — the one decision the terminal
/// panel header's snippet popover (Task 8) adds on top of what
/// `SnippetMenuModel`/`SnippetMenuPlan` already own: which snippets a search
/// query narrows the list to, BEFORE that narrowed list is handed to
/// `SnippetMenuModel.build`. Grouping, untagged-last, and the disabled
/// reason are `SnippetMenuModelTests`' territory, not repeated here.
@Suite("TerminalSnippetSearch")
struct TerminalSnippetSearchTests {
    private func predicate(_ text: String, isRegex: Bool = false) -> FileSearch.FileSearchPredicate {
        guard case .success(let predicate) = FileSearch.compile(query: text, isRegex: isRegex) else {
            preconditionFailure("a plain, non-regex query must always compile")
        }
        return predicate
    }

    @Test func emptyQueryMatchesEverySnippet() throws {
        let a = try #require(Snippet(name: "a", command: "df -h"))
        let b = try #require(Snippet(name: "b", command: "uptime"))

        #expect(TerminalSnippetSearch.matching([a, b], predicate: predicate("")) == [a, b])
    }

    @Test func matchesByNameCaseInsensitively() throws {
        let disk = try #require(Snippet(name: "Disk usage", command: "df -h"))
        let uptime = try #require(Snippet(name: "Uptime", command: "uptime"))

        #expect(
            TerminalSnippetSearch.matching([disk, uptime], predicate: predicate("disk")) == [disk])
    }

    /// Matching the COMMAND, not just the name, is the point of concatenating
    /// "name command" — the same two fields `SnippetsSheet`'s own inline
    /// search filters on (see that view's search line).
    @Test func matchesByCommandNotJustName() throws {
        let disk = try #require(Snippet(name: "Disk usage", command: "df -h"))
        let load = try #require(Snippet(name: "Load", command: "uptime"))

        #expect(
            TerminalSnippetSearch.matching([disk, load], predicate: predicate("uptime")) == [load])
    }

    @Test func noMatchYieldsAnEmptyList() throws {
        let snippet = try #require(Snippet(name: "a", command: "b"))

        #expect(TerminalSnippetSearch.matching([snippet], predicate: predicate("zzz")).isEmpty)
    }

    @Test func regexQueriesAreHonored() throws {
        let matching = try #require(Snippet(name: "restart-nginx", command: "systemctl restart nginx"))
        let other = try #require(Snippet(name: "uptime", command: "uptime"))

        let regexPredicate = predicate("^restart", isRegex: true)

        #expect(
            TerminalSnippetSearch.matching([matching, other], predicate: regexPredicate) == [matching])
    }

    /// The claim the brief's own constraint is about: composing this with
    /// `SnippetMenuModel.build` narrows the INPUT — tags, untagged-last, and
    /// the disabled reason all still come out of `SnippetMenuModel`, not a
    /// second implementation grown here. If this test passed while `build`'s
    /// own grouping tests failed, that would mean the two disagree; it does
    /// not re-prove `build`'s grouping rules itself.
    @Test func theNarrowedListStillGroupsThroughSnippetMenuModel() throws {
        let match = try #require(Snippet(name: "match", command: "c", tags: ["x"]))
        let other = try #require(Snippet(name: "other", command: "c", tags: ["x"]))

        let narrowed = TerminalSnippetSearch.matching([match, other], predicate: predicate("match"))
        let model = SnippetMenuModel.build(snippets: narrowed, isConnected: true, supportsShell: true)

        #expect(model.groups.map(\.tag) == ["x"])
        #expect(model.groups.first?.snippets == [match])
    }
}
