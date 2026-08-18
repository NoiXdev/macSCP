import Foundation
import Testing
@testable import macSCPCore

private func session(_ name: String, group: UUID? = nil, tags: [String] = [])
    -> StoredSession {
    StoredSession(name: name, groupID: group, tags: tags)
}

struct SidebarVisibilityTests {
    @Test func withoutAFilterEverythingShows() {
        let g = StoredGroup(name: "prod")
        let v = SidebarVisibility.compute(
            sessions: [session("a", group: g.id), session("b")],
            groups: [g], activeTag: nil)
        #expect(v.groupSections.map(\.group) == [g])
        #expect(v.groupSections.first?.sessions.map(\.name) == ["a"])
        #expect(v.ungrouped.map(\.name) == ["b"])
        #expect(v.showsImportedSection)
        #expect(v.emptiness == .notEmpty)
    }

    @Test func anActiveTagHidesGroupsWithoutAMatchAndTheImportedSection() {
        let hit = StoredGroup(name: "prod")
        let miss = StoredGroup(name: "lab")
        let v = SidebarVisibility.compute(
            sessions: [session("a", group: hit.id, tags: ["docker"]),
                       session("b", group: miss.id)],
            groups: [hit, miss], activeTag: "docker")
        #expect(v.groupSections.map(\.group) == [hit])
        #expect(v.groupSections.first?.sessions.map(\.name) == ["a"])
        #expect(!v.showsImportedSection)
    }

    @Test func theTwoEmptyStatesAreDistinguishable() {
        let none = SidebarVisibility.compute(sessions: [], groups: [], activeTag: nil)
        #expect(none.emptiness == .noSessionsAtAll)

        let filtered = SidebarVisibility.compute(
            sessions: [session("a", tags: ["web"])], groups: [], activeTag: "docker")
        #expect(filtered.emptiness == .filterMatchesNothing)
    }

    @Test func tagComparisonIsExactSoTwoSpellingsStayTwoTags() {
        let v = SidebarVisibility.compute(
            sessions: [session("a", tags: ["Docker"])], groups: [], activeTag: "docker")
        #expect(v.emptiness == .filterMatchesNothing)
    }

    @Test func availableTagsAreSortedAndDeduplicatedAcrossSessions() {
        #expect(SidebarVisibility.availableTags(in: [
            session("a", tags: ["web", "docker"]),
            session("b", tags: ["docker"]),
        ]) == ["docker", "web"])
    }

    @Test func aTagNobodyCarriesAnymoreResolvesToNoFilter() {
        #expect(SidebarVisibility.resolvedTag("gone", in: [session("a", tags: ["web"])]) == nil)
        #expect(SidebarVisibility.resolvedTag("web", in: [session("a", tags: ["web"])]) == "web")
    }

    /// Pins the "in `groups`'s order" claim in `SidebarVisibility`'s doc
    /// comment: with two groups that both keep a session, `groupSections`
    /// does not reorder them by, say, `StoredGroup.id`.
    @Test func multipleMatchingGroupsKeepGroupsOrder() {
        let first = StoredGroup(name: "prod")
        let second = StoredGroup(name: "staging")
        let v = SidebarVisibility.compute(
            sessions: [session("a", group: second.id), session("b", group: first.id)],
            groups: [first, second], activeTag: nil)
        #expect(v.groupSections.map(\.group) == [first, second])
    }

    /// Pins the "in `sessions`'s order" claim on `ungrouped`: with two
    /// ungrouped sessions, the result keeps `sessions`'s order rather than,
    /// say, sorting by name.
    @Test func multipleUngroupedSessionsKeepSessionsOrder() {
        let v = SidebarVisibility.compute(
            sessions: [session("z"), session("a")],
            groups: [], activeTag: nil)
        #expect(v.ungrouped.map(\.name) == ["z", "a"])
    }

    /// A group with sessions that all fail the filter is omitted entirely —
    /// not present as an empty `GroupSection` — so the sidebar never draws a
    /// header with nothing under it.
    @Test func aGroupWhoseOnlySessionIsFilteredOutIsOmittedEntirely() {
        let empty = StoredGroup(name: "lab")
        let v = SidebarVisibility.compute(
            sessions: [session("a", group: empty.id, tags: ["web"])],
            groups: [empty], activeTag: "docker")
        #expect(v.groupSections.isEmpty)
    }

    /// Pins the independence `TagList`'s doc comment states as design
    /// intent: a host tag filters `StoredSession`s only. `SnippetMenuModel`
    /// takes no `activeTag` and `SidebarVisibility.compute` takes no
    /// `Snippet`, so the same tag string active as a host filter cannot make
    /// a snippet carrying that tag disappear from the snippet menu — the two
    /// computations simply do not share an input. See this file's own
    /// `SidebarVisibility` doc comment for the residual gap this test does
    /// not close (whether a future View-layer caller wires `activeTag` into
    /// the `snippets` list it hands to `SnippetMenuModel.build`).
    @Test func aHostTagNeverHidesASnippet() {
        let dockerSnippet = Snippet(name: "restart", command: "docker restart", tags: ["docker"])!
        let hostWithoutDockerTag = session("a", tags: ["web"])

        _ = SidebarVisibility.compute(
            sessions: [hostWithoutDockerTag], groups: [], activeTag: "docker")

        let menu = SnippetMenuModel.build(
            snippets: [dockerSnippet], isConnected: true, supportsShell: true)
        #expect(menu.groups.flatMap(\.snippets) == [dockerSnippet])
    }
}
