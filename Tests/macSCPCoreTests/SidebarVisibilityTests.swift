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
            groups: [g], importedHostsCount: 1, activeTag: nil)
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
            groups: [hit, miss], importedHostsCount: 3, activeTag: "docker")
        #expect(v.groupSections.map(\.group) == [hit])
        #expect(v.groupSections.first?.sessions.map(\.name) == ["a"])
        // Imported hosts are present (importedHostsCount: 3) — still hidden,
        // because an active tag always hides the imported section.
        #expect(!v.showsImportedSection)
    }

    @Test func theTwoEmptyStatesAreDistinguishable() {
        let none = SidebarVisibility.compute(
            sessions: [], groups: [], importedHostsCount: 0, activeTag: nil)
        #expect(none.emptiness == .noSessionsAtAll)

        let filtered = SidebarVisibility.compute(
            sessions: [session("a", tags: ["web"])], groups: [], importedHostsCount: 0,
            activeTag: "docker")
        #expect(filtered.emptiness == .filterMatchesNothing)
    }

    /// The case the round-1 review flagged: with no saved sessions at all,
    /// an active view used to have to compute
    /// `emptiness == .noSessionsAtAll && importedHosts.isEmpty` itself
    /// before it could tell "empty store" from "empty store, but there is
    /// an IMPORTED section to show". Folding `importedHostsCount` into
    /// `compute` removes that second question: a non-zero count with no
    /// active tag is `.notEmpty`, because the imported section itself has
    /// something to draw.
    @Test func noSessionsButImportedHostsPresentIsNotTheEmptyState() {
        let v = SidebarVisibility.compute(
            sessions: [], groups: [], importedHostsCount: 3, activeTag: nil)
        #expect(v.emptiness == .notEmpty)
        #expect(v.showsImportedSection)
    }

    /// Same store, but a tag filter is active — the imported section always
    /// hides under a filter (imported hosts carry no tags), so this reduces
    /// back to the plain "nothing to show" case despite hosts being
    /// available to import.
    @Test func noSessionsAndImportedHostsHiddenByAnActiveTagIsTheEmptyState() {
        let v = SidebarVisibility.compute(
            sessions: [], groups: [], importedHostsCount: 3, activeTag: "docker")
        #expect(v.emptiness == .noSessionsAtAll)
        #expect(!v.showsImportedSection)
    }

    @Test func tagComparisonIsExactSoTwoSpellingsStayTwoTags() {
        let v = SidebarVisibility.compute(
            sessions: [session("a", tags: ["Docker"])], groups: [], importedHostsCount: 0,
            activeTag: "docker")
        #expect(v.emptiness == .filterMatchesNothing)
    }

    /// `""` never occurs in a stored tag (`TagList.normalized` drops empty
    /// entries), so an empty-string active tag behaves like any other tag
    /// nothing carries: it matches nothing rather than being treated as
    /// "no filter".
    @Test func emptyStringActiveTagMatchesNothingBecauseNoStoredTagIsEverEmpty() {
        let v = SidebarVisibility.compute(
            sessions: [session("a", tags: ["docker"])], groups: [], importedHostsCount: 0,
            activeTag: "")
        #expect(v.emptiness == .filterMatchesNothing)
        #expect(v.ungrouped.isEmpty)
    }

    /// Same reasoning for a whitespace-only tag: `TagList.normalized` trims
    /// before storing, so no stored tag is ever whitespace-only either.
    @Test func whitespaceOnlyActiveTagMatchesNothingBecauseStoredTagsAreAlwaysTrimmed() {
        let v = SidebarVisibility.compute(
            sessions: [session("a", tags: ["docker"])], groups: [], importedHostsCount: 0,
            activeTag: "   ")
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
            groups: [first, second], importedHostsCount: 0, activeTag: nil)
        #expect(v.groupSections.map(\.group) == [first, second])
    }

    /// Pins the "in `sessions`'s order" claim on `ungrouped`: with two
    /// ungrouped sessions, the result keeps `sessions`'s order rather than,
    /// say, sorting by name.
    @Test func multipleUngroupedSessionsKeepSessionsOrder() {
        let v = SidebarVisibility.compute(
            sessions: [session("z"), session("a")],
            groups: [], importedHostsCount: 0, activeTag: nil)
        #expect(v.ungrouped.map(\.name) == ["z", "a"])
    }

    /// A group with sessions that all fail the filter is omitted entirely —
    /// not present as an empty `GroupSection` — so the sidebar never draws a
    /// header with nothing under it.
    @Test func aGroupWhoseOnlySessionIsFilteredOutIsOmittedEntirely() {
        let empty = StoredGroup(name: "lab")
        let v = SidebarVisibility.compute(
            sessions: [session("a", group: empty.id, tags: ["web"])],
            groups: [empty], importedHostsCount: 0, activeTag: "docker")
        #expect(v.groupSections.isEmpty)
    }

    /// The reviewer-confirmed unreachable edge case (`SessionStore.load` and
    /// `dissolveGroup` both nil out a dangling `groupID` before this type
    /// ever sees it): a session whose `groupID` names no group in `groups`
    /// passes the tag filter (there is none active here) but still lands in
    /// neither `ungrouped` nor any `groupSections` entry, so there is
    /// nothing on screen for it. `emptiness` must reflect that structurally
    /// — deriving it from `ungrouped`/`groupSections` themselves, not from
    /// whether the tag filter matched anything, is what makes this hold
    /// even though nothing here is actually filtering by tag.
    @Test func aSessionInAnUnknownGroupDrawsNothingAndEmptinessSaysSo() {
        let danglingGroupID = UUID()
        let v = SidebarVisibility.compute(
            sessions: [session("a", group: danglingGroupID)],
            groups: [], importedHostsCount: 0, activeTag: nil)
        #expect(v.ungrouped.isEmpty)
        #expect(v.groupSections.isEmpty)
        #expect(v.emptiness != .notEmpty)
    }
}
