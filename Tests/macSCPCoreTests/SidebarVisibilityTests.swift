import Foundation
import Testing
@testable import macSCPCore

private func session(
    _ name: String, group: UUID? = nil, tags: [String] = [], at position: Int = 0
) -> StoredSession {
    StoredSession(name: name, groupID: group, tags: tags, position: position)
}

/// A session that actually carries an SSH block, so its host and user name
/// exist to be searched. `session(_:)` above deliberately builds none: the
/// tag tests never needed one, and a blockless record is what a store file
/// written before M23 looks like.
private func sshSession(
    _ name: String, host: String, username: String,
    group: UUID? = nil, tags: [String] = [], at position: Int = 0
) -> StoredSession {
    StoredSession(
        name: name, groupID: group, kind: .ssh,
        ssh: StoredSSHConfig(host: host, username: username),
        tags: tags, position: position)
}

/// The compiled predicate for one query, the same way the sidebar compiles
/// its own. Every query spelled below is a literal in this file and none of
/// them is an invalid regex, so the failure arm is unreachable — what an
/// INVALID one does is the App layer's decision (`sheetSearchPredicate`),
/// not this type's.
private func searchFor(_ text: String, regex: Bool = false) -> FileSearch.FileSearchPredicate {
    switch FileSearch.compile(query: text, isRegex: regex) {
    case .success(let predicate): return predicate
    case .failure: preconditionFailure("the queries in this file all compile")
    }
}

struct SidebarVisibilityTests {
    @Test func withoutAFilterEverythingShows() {
        let g = StoredGroup(name: "prod")
        let inside = session("a", group: g.id)
        let outside = session("b")
        let v = SidebarVisibility.compute(
            sessions: [inside, outside],
            groups: [g], importedHostsCount: 1, tagFilter: .none, search: nil)
        #expect(v.children(of: nil) == [.group(g.id), .session(outside.id)])
        #expect(v.children(of: g.id) == [.session(inside.id)])
        #expect(v.showsImportedSection)
        #expect(v.emptiness == .notEmpty)
    }

    @Test func aTagFilterHidesGroupsWithoutAMatchAndTheImportedSection() {
        let hit = StoredGroup(name: "prod")
        let miss = StoredGroup(name: "lab")
        let kept = session("a", group: hit.id, tags: ["docker"])
        let v = SidebarVisibility.compute(
            sessions: [kept, session("b", group: miss.id)],
            groups: [hit, miss], importedHostsCount: 3, tagFilter: .one("docker"), search: nil)
        #expect(v.children(of: nil) == [.group(hit.id)])
        #expect(v.children(of: hit.id) == [.session(kept.id)])
        // Imported hosts are present (importedHostsCount: 3) — still hidden,
        // because a tag filter always hides the imported section.
        #expect(!v.showsImportedSection)
    }

    @Test func theTwoEmptyStatesAreDistinguishable() {
        let none = SidebarVisibility.compute(
            sessions: [], groups: [], importedHostsCount: 0, tagFilter: .none, search: nil)
        #expect(none.emptiness == .noSessionsAtAll)

        let filtered = SidebarVisibility.compute(
            sessions: [session("a", tags: ["web"])], groups: [], importedHostsCount: 0,
            tagFilter: .one("docker"), search: nil)
        #expect(filtered.emptiness == .filterMatchesNothing)
    }

    /// The case the round-1 review flagged: with no saved sessions at all,
    /// an active view used to have to compute
    /// `emptiness == .noSessionsAtAll && importedHosts.isEmpty` itself
    /// before it could tell "empty store" from "empty store, but there is
    /// an IMPORTED section to show". Folding `importedHostsCount` into
    /// `compute` removes that second question: a non-zero count with no
    /// tag filter is `.notEmpty`, because the imported section itself has
    /// something to draw.
    @Test func noSessionsButImportedHostsPresentIsNotTheEmptyState() {
        let v = SidebarVisibility.compute(
            sessions: [], groups: [], importedHostsCount: 3, tagFilter: .none, search: nil)
        #expect(v.emptiness == .notEmpty)
        #expect(v.showsImportedSection)
    }

    /// Same store, but a tag filter is active — the imported section always
    /// hides under a filter (imported hosts carry no tags), so this reduces
    /// back to the plain "nothing to show" case despite hosts being
    /// available to import.
    @Test func noSessionsAndImportedHostsHiddenByATagFilterIsTheEmptyState() {
        let v = SidebarVisibility.compute(
            sessions: [], groups: [], importedHostsCount: 3, tagFilter: .one("docker"), search: nil)
        #expect(v.emptiness == .noSessionsAtAll)
        #expect(!v.showsImportedSection)
    }

    @Test func tagComparisonIsExactSoTwoSpellingsStayTwoTags() {
        let v = SidebarVisibility.compute(
            sessions: [session("a", tags: ["Docker"])], groups: [], importedHostsCount: 0,
            tagFilter: .one("docker"), search: nil)
        #expect(v.emptiness == .filterMatchesNothing)
    }

    /// `""` never occurs in a stored tag (`TagList.normalized` drops empty
    /// entries), so an empty-string tag behaves like any other tag
    /// nothing carries: it matches nothing rather than being treated as
    /// "no filter".
    @Test func anEmptyStringTagMatchesNothingBecauseNoStoredTagIsEverEmpty() {
        let v = SidebarVisibility.compute(
            sessions: [session("a", tags: ["docker"])], groups: [], importedHostsCount: 0,
            tagFilter: .one(""), search: nil)
        #expect(v.emptiness == .filterMatchesNothing)
        #expect(v.children(of: nil).isEmpty)
    }

    /// Same reasoning for a whitespace-only tag: `TagList.normalized` trims
    /// before storing, so no stored tag is ever whitespace-only either.
    @Test func aWhitespaceOnlyTagMatchesNothingBecauseStoredTagsAreAlwaysTrimmed() {
        let v = SidebarVisibility.compute(
            sessions: [session("a", tags: ["docker"])], groups: [], importedHostsCount: 0,
            tagFilter: .one("   "), search: nil)
        #expect(v.emptiness == .filterMatchesNothing)
    }

    @Test func availableTagsAreSortedAndDeduplicatedAcrossSessions() {
        #expect(SidebarVisibility.availableTags(in: [
            session("a", tags: ["web", "docker"]),
            session("b", tags: ["docker"]),
        ]) == ["docker", "web"])
    }

    /// Two tags joined as "all": the intersection, applied through the same
    /// one filtering rule everything else here goes through — a session
    /// carrying one of them is as gone as one carrying neither.
    @Test func twoTagsJoinedAsAllKeepOnlySessionsCarryingBoth() {
        let both = session("both", tags: ["docker", "web"])
        let one = session("one", tags: ["docker"])
        let v = SidebarVisibility.compute(
            sessions: [both, one], groups: [], importedHostsCount: 0,
            tagFilter: SidebarTagFilter(tags: ["docker", "web"], join: .all), search: nil)
        #expect(v.children(of: nil) == [.session(both.id)])
    }

    /// The same two tags joined as "any": the union.
    @Test func twoTagsJoinedAsAnyKeepEverySessionCarryingEitherOne() {
        let both = session("both", tags: ["docker", "web"])
        let one = session("one", tags: ["docker"])
        let neither = session("neither", tags: ["db"])
        let v = SidebarVisibility.compute(
            sessions: [both, one, neither], groups: [], importedHostsCount: 0,
            tagFilter: SidebarTagFilter(tags: ["docker", "web"], join: .any), search: nil)
        #expect(v.children(of: nil) == [.session(both.id), .session(one.id)])
    }

    /// The ancestor rule from D1+D2 is unchanged by a filter of several
    /// tags: it is the same rule, only narrower. The single match sits two
    /// levels down and carries both tags; neither folder on the way to it
    /// carries a session of its own.
    @Test func aMultiTagFilterKeepsTheAncestorsOfADeepMatch() {
        let outer = StoredGroup(name: "outer")
        let inner = StoredGroup(name: "inner", parentID: outer.id)
        let deep = session("deep", group: inner.id, tags: ["docker", "web"])
        let v = SidebarVisibility.compute(
            sessions: [deep, session("other", tags: ["docker"])],
            groups: [outer, inner], importedHostsCount: 0,
            tagFilter: SidebarTagFilter(tags: ["docker", "web"], join: .all), search: nil)
        #expect(v.children(of: nil) == [.group(outer.id)])
        #expect(v.children(of: outer.id) == [.group(inner.id)])
        #expect(v.children(of: inner.id) == [.session(deep.id)])
    }

    /// A filter of several tags hides the imported section for the reason
    /// one tag always did: an imported host carries no tag this filter can
    /// examine, so drawing that section beside filtered ones would present
    /// the filter as covering everything on screen.
    @Test func aMultiTagFilterHidesTheImportedSectionToo() {
        let v = SidebarVisibility.compute(
            sessions: [session("a", tags: ["docker", "web"])], groups: [],
            importedHostsCount: 3,
            tagFilter: SidebarTagFilter(tags: ["docker", "web"], join: .any), search: nil)
        #expect(!v.showsImportedSection)
    }

    /// A filter carrying a non-default join but no tags is not a filter: the
    /// join says nothing on its own, so everything shows and the imported
    /// section comes back.
    @Test func anEmptySelectionIsNoFilterWhateverTheJoinSays() {
        let sessions = [session("a", tags: ["docker"])]
        let unfiltered = SidebarVisibility.compute(
            sessions: sessions, groups: [], importedHostsCount: 2,
            tagFilter: .none, search: nil)
        let joinOnly = SidebarVisibility.compute(
            sessions: sessions, groups: [], importedHostsCount: 2,
            tagFilter: SidebarTagFilter(tags: [], join: .any), search: nil)
        #expect(joinOnly == unfiltered)
        #expect(joinOnly.showsImportedSection)
    }

    /// Pins the claim that this type reorders nothing: two folders sharing
    /// the position every file on disk carries today (zero) come back in the
    /// order they were handed over, not sorted by `StoredGroup.id`.
    @Test func multipleMatchingGroupsKeepGroupsOrder() {
        let first = StoredGroup(name: "prod")
        let second = StoredGroup(name: "staging")
        let v = SidebarVisibility.compute(
            sessions: [session("a", group: second.id), session("b", group: first.id)],
            groups: [first, second], importedHostsCount: 0, tagFilter: .none, search: nil)
        #expect(v.children(of: nil) == [.group(first.id), .group(second.id)])
    }

    /// The same claim for connections: two top-level rows with equal
    /// positions keep `sessions`'s order rather than being sorted by name.
    @Test func multipleUngroupedSessionsKeepSessionsOrder() {
        let z = session("z")
        let a = session("a")
        let v = SidebarVisibility.compute(
            sessions: [z, a], groups: [], importedHostsCount: 0, tagFilter: .none, search: nil)
        #expect(v.children(of: nil) == [.session(z.id), .session(a.id)])
    }

    /// Positions, once written, decide the order — including across the two
    /// kinds of row, which share one rank space per parent.
    @Test func positionsDecideTheOrderWithinOneParent() {
        let folder = StoredGroup(name: "lab", parentID: nil, position: 1)
        let first = session("first", at: 0)
        let last = session("last", at: 2)
        let v = SidebarVisibility.compute(
            sessions: [last, first], groups: [folder], importedHostsCount: 0, tagFilter: .none, search: nil)
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
            sessions: sessions, groups: [group], importedHostsCount: 0, tagFilter: .none, search: nil)
        #expect(unfiltered.children(of: nil).contains(.group(group.id)))

        let filtered = SidebarVisibility.compute(
            sessions: sessions, groups: [group], importedHostsCount: 0, tagFilter: .one("docker"), search: nil)
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
            sessions: [], groups: [group], importedHostsCount: 0, tagFilter: .none, search: nil)
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
            importedHostsCount: 0, tagFilter: .none, search: nil)
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
            groups: [empty], importedHostsCount: 0, tagFilter: .one("docker"), search: nil)
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
            sessions: [deep], groups: [outer, inner], importedHostsCount: 0, tagFilter: .none, search: nil)
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
            groups: [outer, inner], importedHostsCount: 0, tagFilter: .one("docker"), search: nil)
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
            groups: [outer, inner], importedHostsCount: 0, tagFilter: .one("docker"), search: nil)
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
            importedHostsCount: 0, tagFilter: .one("docker"), search: nil)
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
            groups: [], importedHostsCount: 0, tagFilter: .none, search: nil)
        #expect(v.children(of: nil).isEmpty)
        #expect(v.group(danglingGroupID) == nil)
        #expect(v.emptiness != .notEmpty)
    }
    // MARK: - Search

    /// What a user types when looking for a connection, and the four places
    /// it is looked for. Host and user name are read through the backend's
    /// own `displaySummary`, which is where they live since `StoredSession`
    /// stopped carrying flat SSH columns.
    @Test func aSearchKeepsTheSessionsWhoseNameHostUsernameOrTagMatch() {
        let byName = sshSession("web-01", host: "10.0.0.5", username: "deploy")
        let byHost = sshSession("alpha", host: "web-gateway", username: "root")
        let byUsername = sshSession("beta", host: "10.0.0.9", username: "webmaster")
        let byTag = sshSession("gamma", host: "10.0.0.7", username: "root", tags: ["web"])
        let miss = sshSession("delta", host: "10.0.0.8", username: "root", tags: ["db"])
        let v = SidebarVisibility.compute(
            sessions: [byName, byHost, byUsername, byTag, miss], groups: [],
            importedHostsCount: 0, tagFilter: .none, search: searchFor("web"))
        #expect(v.children(of: nil) == [
            .session(byName.id), .session(byHost.id), .session(byUsername.id), .session(byTag.id),
        ])
        #expect(v.session(miss.id) == nil)
    }

    /// A folder is on screen because something IN it matches, never because
    /// it is called that: a folder name counting as a match would show its
    /// whole contents and claim hits that are not there.
    @Test func aFolderNameIsNotAMatch() {
        let folder = StoredGroup(name: "production")
        let inside = sshSession("web-01", host: "10.0.0.5", username: "deploy", group: folder.id)
        let v = SidebarVisibility.compute(
            sessions: [inside], groups: [folder],
            importedHostsCount: 0, tagFilter: .none, search: searchFor("production"))
        #expect(v.children(of: nil).isEmpty)
        #expect(v.emptiness == .filterMatchesNothing)
    }

    /// The ancestor rule the tag filter already answers to, applied to the
    /// new criterion: the match is two levels down, so neither folder on the
    /// way to it matches anything of its own.
    @Test func aSearchKeepsTheAncestorsOfAMatchDeepInTheTree() {
        let outer = StoredGroup(name: "outer")
        let inner = StoredGroup(name: "inner", parentID: outer.id)
        let deep = sshSession("deep", host: "10.0.0.5", username: "deploy", group: inner.id)
        let v = SidebarVisibility.compute(
            sessions: [deep, sshSession("other", host: "elsewhere", username: "root")],
            groups: [outer, inner],
            importedHostsCount: 0, tagFilter: .none, search: searchFor("deploy"))
        #expect(v.children(of: nil) == [.group(outer.id)])
        #expect(v.children(of: outer.id) == [.group(inner.id)])
        #expect(v.children(of: inner.id) == [.session(deep.id)])
    }

    /// Both criteria hold at once: typing searches WITHIN what the tag
    /// filter left, rather than replacing it. A session matching the text
    /// but not the tag is as gone as one matching neither.
    @Test func theSearchAndTheTagFilterNarrowTogether() {
        let both = sshSession("web-01", host: "10.0.0.5", username: "root", tags: ["docker"])
        let tagOnly = sshSession("db-01", host: "10.0.0.6", username: "root", tags: ["docker"])
        let textOnly = sshSession("web-02", host: "10.0.0.7", username: "root", tags: ["lab"])
        let v = SidebarVisibility.compute(
            sessions: [both, tagOnly, textOnly], groups: [],
            importedHostsCount: 0, tagFilter: .one("docker"), search: searchFor("web"))
        #expect(v.children(of: nil) == [.session(both.id)])
    }

    /// A predicate matching everything is not a search — which is exactly
    /// the shape the App layer hands over for an INVALID regular expression,
    /// so a half-typed pattern shows its error while the sidebar keeps
    /// drawing what it drew.
    @Test func aPredicateThatMatchesEverythingIsNotASearch() {
        let sessions = [sshSession("web-01", host: "10.0.0.5", username: "deploy")]
        let unsearched = SidebarVisibility.compute(
            sessions: sessions, groups: [], importedHostsCount: 2,
            tagFilter: .none, search: nil)
        let matchesAll = SidebarVisibility.compute(
            sessions: sessions, groups: [], importedHostsCount: 2,
            tagFilter: .none, search: searchFor(""))
        #expect(matchesAll == unsearched)
        #expect(matchesAll.showsImportedSection)
        #expect(!matchesAll.expandsFolders)
    }

    /// Imported hosts carry no name, host or tag this filter can see — the
    /// same reason a tag filter hides the section, and the same misreading
    /// avoided: an unfilterable section beside filtered ones would present
    /// the search as covering everything on screen.
    @Test func aSearchHidesTheImportedSection() {
        let v = SidebarVisibility.compute(
            sessions: [sshSession("web-01", host: "10.0.0.5", username: "deploy")],
            groups: [], importedHostsCount: 3, tagFilter: .none, search: searchFor("web"))
        #expect(!v.showsImportedSection)
    }

    /// The store is not empty; the search consumed everything. That is the
    /// invitation to clear a filter, not the one to create a connection.
    @Test func aSearchMatchingNothingIsTheFilterEmptyState() {
        let v = SidebarVisibility.compute(
            sessions: [sshSession("web-01", host: "10.0.0.5", username: "deploy")],
            groups: [], importedHostsCount: 0, tagFilter: .none, search: searchFor("zzz"))
        #expect(v.children(of: nil).isEmpty)
        #expect(v.emptiness == .filterMatchesNothing)
    }

    /// A match inside a folder the user closed is filtered and still
    /// invisible — so while a search narrows the tree, the tree draws open.
    /// An empty search leaves that decision to the user again.
    @Test func foldersDrawOpenWhileASearchNarrowsTheTree() {
        let folder = StoredGroup(name: "lab")
        let inside = sshSession(
            "web-01", host: "10.0.0.5", username: "deploy", group: folder.id, tags: ["docker"])
        let searched = SidebarVisibility.compute(
            sessions: [inside], groups: [folder],
            importedHostsCount: 0, tagFilter: .none, search: searchFor("web"))
        #expect(searched.expandsFolders)

        let untouched = SidebarVisibility.compute(
            sessions: [inside], groups: [folder],
            importedHostsCount: 0, tagFilter: .none, search: nil)
        #expect(!untouched.expandsFolders)

        // A tag filter is not a search: it narrows the tree without
        // claiming the user's collapse state.
        let tagged = SidebarVisibility.compute(
            sessions: [inside], groups: [folder],
            importedHostsCount: 0, tagFilter: .one("docker"), search: nil)
        #expect(tagged.children(of: folder.id) == [.session(inside.id)])
        #expect(!tagged.expandsFolders)
    }
}
