import Foundation
import Testing
@testable import macSCPCore

private func session(
    _ name: String, group: UUID? = nil, tags: [String] = [], at position: Int = 0
) -> StoredSession {
    StoredSession(name: name, groupID: group, tags: tags, position: position)
}

struct SidebarVisibilityTests {
    @Test func withoutAFilterEverythingShows() {
        let g = StoredGroup(name: "prod")
        let inside = session("a", group: g.id)
        let outside = session("b")
        let v = SidebarVisibility.compute(
            sessions: [inside, outside],
            groups: [g], importedHostsCount: 1, activeTag: nil)
        #expect(v.children(of: nil) == [.group(g.id), .session(outside.id)])
        #expect(v.children(of: g.id) == [.session(inside.id)])
        #expect(v.showsImportedSection)
        #expect(v.emptiness == .notEmpty)
    }

    @Test func anActiveTagHidesGroupsWithoutAMatchAndTheImportedSection() {
        let hit = StoredGroup(name: "prod")
        let miss = StoredGroup(name: "lab")
        let kept = session("a", group: hit.id, tags: ["docker"])
        let v = SidebarVisibility.compute(
            sessions: [kept, session("b", group: miss.id)],
            groups: [hit, miss], importedHostsCount: 3, activeTag: "docker")
        #expect(v.children(of: nil) == [.group(hit.id)])
        #expect(v.children(of: hit.id) == [.session(kept.id)])
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
        #expect(v.children(of: nil).isEmpty)
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

    /// Pins the claim that this type reorders nothing: two folders sharing
    /// the position every file on disk carries today (zero) come back in the
    /// order they were handed over, not sorted by `StoredGroup.id`.
    @Test func multipleMatchingGroupsKeepGroupsOrder() {
        let first = StoredGroup(name: "prod")
        let second = StoredGroup(name: "staging")
        let v = SidebarVisibility.compute(
            sessions: [session("a", group: second.id), session("b", group: first.id)],
            groups: [first, second], importedHostsCount: 0, activeTag: nil)
        #expect(v.children(of: nil) == [.group(first.id), .group(second.id)])
    }

    /// The same claim for connections: two top-level rows with equal
    /// positions keep `sessions`'s order rather than being sorted by name.
    @Test func multipleUngroupedSessionsKeepSessionsOrder() {
        let z = session("z")
        let a = session("a")
        let v = SidebarVisibility.compute(
            sessions: [z, a], groups: [], importedHostsCount: 0, activeTag: nil)
        #expect(v.children(of: nil) == [.session(z.id), .session(a.id)])
    }

    /// Positions, once written, decide the order — including across the two
    /// kinds of row, which share one rank space per parent.
    @Test func positionsDecideTheOrderWithinOneParent() {
        let folder = StoredGroup(name: "lab", parentID: nil, position: 1)
        let first = session("first", at: 0)
        let last = session("last", at: 2)
        let v = SidebarVisibility.compute(
            sessions: [last, first], groups: [folder], importedHostsCount: 0, activeTag: nil)
        #expect(v.children(of: nil) == [.session(first.id), .group(folder.id), .session(last.id)])
    }

    /// Dropping an empty group is FILTER behaviour, not general behaviour.
    /// One store, one group nothing is in, computed twice: without a filter
    /// the group still draws, with a filter active it is gone. Hiding it
    /// unconditionally took the group's header off screen together with its
    /// Rename/Export/Dissolve menu and its drop target, leaving a group that
    /// exists in the store and in every row's "Move to" submenu but can no
    /// longer be dissolved or dropped into.
    @Test func anEmptyGroupIsHiddenOnlyWhileATagIsActive() {
        let group = StoredGroup(name: "lab")
        let sessions = [session("a", tags: ["docker"])]

        let unfiltered = SidebarVisibility.compute(
            sessions: sessions, groups: [group], importedHostsCount: 0, activeTag: nil)
        #expect(unfiltered.children(of: nil).contains(.group(group.id)))

        let filtered = SidebarVisibility.compute(
            sessions: sessions, groups: [group], importedHostsCount: 0, activeTag: "docker")
        #expect(!filtered.children(of: nil).contains(.group(group.id)))
    }

    /// The first consequence of hiding empty groups unconditionally: a
    /// group created from the sidebar's context menu is written to the
    /// store with no session in it, so it never appeared at all — inviting
    /// the user to create it again, and again, accumulating groups they
    /// could not see. It must be on screen the moment it exists, which also
    /// makes the store non-empty for `emptiness`: there is a header to draw.
    @Test func aFreshlyCreatedGroupShowsBeforeItHasAnySession() {
        let group = StoredGroup(name: "lab")
        let v = SidebarVisibility.compute(
            sessions: [], groups: [group], importedHostsCount: 0, activeTag: nil)
        #expect(v.children(of: nil) == [.group(group.id)])
        #expect(v.emptiness == .notEmpty)
    }

    /// The second consequence: dragging the last session out of a group
    /// used to make the group itself disappear, taking its drop target with
    /// it — so the session could never be dragged back.
    @Test func aGroupThatJustLostItsLastSessionStaysOnScreen() {
        let group = StoredGroup(name: "lab")
        let moved = session("moved-out")
        let v = SidebarVisibility.compute(
            sessions: [moved], groups: [group],
            importedHostsCount: 0, activeTag: nil)
        #expect(v.children(of: nil) == [.group(group.id), .session(moved.id)])
        #expect(v.children(of: group.id).isEmpty)
    }

    /// A group whose sessions all fail the filter is omitted entirely, so
    /// the sidebar never draws a header with nothing under it while a filter
    /// is narrowing the list.
    @Test func aGroupWhoseOnlySessionIsFilteredOutIsOmittedEntirely() {
        let empty = StoredGroup(name: "lab")
        let v = SidebarVisibility.compute(
            sessions: [session("a", group: empty.id, tags: ["web"])],
            groups: [empty], importedHostsCount: 0, activeTag: "docker")
        #expect(v.children(of: nil).isEmpty)
    }

    // MARK: - Nesting

    /// A sub-folder is reached through its parent and appears nowhere else —
    /// the flat sidebar drew every folder side by side, whatever its
    /// `parentID` said.
    @Test func aSubFolderIsReachedThroughItsParentAndNotAtTheTopLevel() {
        let outer = StoredGroup(name: "outer")
        let inner = StoredGroup(name: "inner", parentID: outer.id)
        let deep = session("deep", group: inner.id)
        let v = SidebarVisibility.compute(
            sessions: [deep], groups: [outer, inner], importedHostsCount: 0, activeTag: nil)
        #expect(v.children(of: nil) == [.group(outer.id)])
        #expect(v.children(of: outer.id) == [.group(inner.id)])
        #expect(v.children(of: inner.id) == [.session(deep.id)])
    }

    /// The rule nesting forced this type to grow, and the one a flat filter
    /// gets wrong: the only match sits two levels down, so neither folder on
    /// the way to it carries a matching session of its own. Dropping a
    /// folder because ITS OWN sessions do not match takes the match with it —
    /// the connection is in the store, passes the filter, and cannot be
    /// reached on screen by any route.
    @Test func anAncestorSurvivesTheFilterSoADeepMatchStaysReachable() {
        let outer = StoredGroup(name: "outer")
        let inner = StoredGroup(name: "inner", parentID: outer.id)
        let deep = session("deep", group: inner.id, tags: ["docker"])
        let v = SidebarVisibility.compute(
            sessions: [deep, session("other", tags: ["web"])],
            groups: [outer, inner], importedHostsCount: 0, activeTag: "docker")
        #expect(v.children(of: nil) == [.group(outer.id)])
        #expect(v.children(of: outer.id) == [.group(inner.id)])
        #expect(v.children(of: inner.id) == [.session(deep.id)])
        #expect(v.emptiness == .notEmpty)
    }

    /// The other half of the same rule: a folder with nothing matching
    /// anywhere below it is gone, ancestors included, and the store is not
    /// empty — a filter matched nothing, which is a different invitation.
    @Test func aFolderWithNoMatchAnywhereBelowItIsGoneWithItsAncestors() {
        let outer = StoredGroup(name: "outer")
        let inner = StoredGroup(name: "inner", parentID: outer.id)
        let v = SidebarVisibility.compute(
            sessions: [session("deep", group: inner.id, tags: ["web"])],
            groups: [outer, inner], importedHostsCount: 0, activeTag: "docker")
        #expect(v.children(of: nil).isEmpty)
        #expect(v.children(of: outer.id).isEmpty)
        #expect(v.emptiness == .filterMatchesNothing)
    }

    /// The row lookups answer from the SAME filtered snapshot `children(of:)`
    /// walks, so a view drawing a row it was handed can never resolve one
    /// the filter removed.
    @Test func theRowLookupsAnswerOnlyForWhatSurvivedTheFilter() {
        let folder = StoredGroup(name: "lab")
        let kept = session("kept", group: folder.id, tags: ["docker"])
        let dropped = session("dropped", tags: ["web"])
        let v = SidebarVisibility.compute(
            sessions: [kept, dropped], groups: [folder],
            importedHostsCount: 0, activeTag: "docker")
        #expect(v.session(kept.id)?.name == "kept")
        #expect(v.session(dropped.id) == nil)
        #expect(v.group(folder.id)?.name == "lab")
        #expect(v.group(UUID()) == nil)
    }

    /// The reviewer-confirmed unreachable edge case (no dangling `groupID`
    /// reaches this type: `SessionStore.load` nils one out, and
    /// `dissolveGroup` re-points the dissolved group's sessions at its
    /// PARENT, which is a group that is still there — `nil`, the top level,
    /// when the dissolved group had no parent): a session whose `groupID`
    /// names no group in `groups` passes the tag filter (there is none
    /// active here) but hangs off a parent that draws nowhere, so the
    /// sidebar — which starts at the top level and only ever descends into
    /// folders it has drawn — never asks for it. `emptiness` must reflect
    /// that structurally: asking what the top level actually draws, not
    /// whether the tag filter matched anything, is what makes this hold even
    /// though nothing here is filtering by tag.
    @Test func aSessionInAnUnknownGroupDrawsNothingAndEmptinessSaysSo() {
        let danglingGroupID = UUID()
        let v = SidebarVisibility.compute(
            sessions: [session("a", group: danglingGroupID)],
            groups: [], importedHostsCount: 0, activeTag: nil)
        #expect(v.children(of: nil).isEmpty)
        #expect(v.group(danglingGroupID) == nil)
        #expect(v.emptiness != .notEmpty)
    }
}
