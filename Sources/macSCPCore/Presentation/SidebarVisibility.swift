import Foundation

/// What the session sidebar shows, for a given store snapshot, the current
/// imported-host count, a tag filter and an optional search — computed once,
/// here, instead of decided piecemeal in the view body.
///
/// This is the type P2's terminal-chrome sidebar work did not have: that
/// milestone's pane-visibility decision lived as two loose booleans in a
/// SwiftUI body, and by the time a defect surfaced (a combination that
/// rendered an empty window), the only test available to guard it read the
/// view file's source text. `SidebarVisibility.compute` exists so the same
/// mistake is not possible here — the decision is a value a test can
/// construct and inspect, and the view that renders it has nothing left to
/// decide, including whether the imported section counts toward "nothing to
/// show": `emptiness` already folds in `importedHostsCount`, so a caller does
/// not need its own `emptiness == .noSessionsAtAll && importedHosts.isEmpty`
/// check.
///
/// ## Why this answers a tree and not two flat lists
///
/// It used to hand over `ungrouped` plus one section per group, which is
/// exactly as much shape as a sidebar drawing one level could use. Folders
/// nest now (`StoredGroup.parentID`), and a flat answer cannot express that:
/// a sub-folder drawn beside its own parent is not a smaller mistake than a
/// wrong one, it is a different tree. What the view reads instead is
/// `children(of:)` — one parent at a time, in `SidebarOrdering`'s order —
/// which is also the only shape in which the filter rule below can be stated
/// truthfully.
///
/// `compute` filters on a session's own fields — its `tags`, its name, and
/// the identity line its backend prints; it never receives or references
/// `Snippet` in any form, and `SnippetMenuModel.build` never receives
/// `tagFilter` — the two computations share no parameter, so a host tag
/// cannot reach a snippet through this type. That separation holds by
/// construction, not by a test in this file: a test that calls both functions
/// independently and checks their outputs would keep passing even if
/// `compute` were deleted entirely, since nothing here connects them. The
/// meaningful regression test — whether a caller accidentally threads
/// the tag filter into the `snippets` list it hands to a trigger surface —
/// needs that filter and `snippets` in scope together, which only happens in
/// `SessionSidebar`/`ContentView`; that is where that pin lives
/// (`SidebarFilterWiringTests`), not here.
public struct SidebarVisibility: Equatable, Sendable {
    /// Distinguishes "there is nothing to show because the store is empty"
    /// from "there is nothing to show because the filter — the tag filter,
    /// the search, or the two together — matched nothing". The sidebar needs
    /// different copy for each (an empty store invites creating a session; a
    /// filter matching nothing invites clearing it), and deliberately not
    /// copy per CAUSE: one message that names no specific filter is true
    /// whichever of them emptied the list, and the sidebar offers one way
    /// back from all of them.
    public enum Emptiness: Equatable, Sendable {
        case notEmpty
        case noSessionsAtAll
        case filterMatchesNothing
    }

    /// Everything that survived the filter, still carrying its nesting and
    /// its positions. Read through `children(of:)`, `session(_:)` and
    /// `group(_:)` rather than directly: those are the three questions a
    /// sidebar has, and going around them is how a view starts deriving an
    /// order of its own.
    public let visibleTree: SidebarOrdering.Tree
    /// Whether the sidebar's "IMPORTED" section (unsaved `SSHConfigHost`
    /// entries) should render at all: nothing is narrowing the list —
    /// an EMPTY `tagFilter` and no search — AND `importedHostsCount > 0` (an
    /// empty section has nothing to draw either way).
    ///
    /// One reason covers both narrowings: an imported host is not a
    /// `StoredSession`, so it carries neither a tag nor a name this filter
    /// ever examines, and rendering an unfilterable section next to filtered
    /// ones would misrepresent the filter as covering everything on screen.
    public let showsImportedSection: Bool
    public let emptiness: Emptiness
    /// Whether every folder draws OPEN regardless of what the user collapsed
    /// (D3): true exactly while a search is narrowing the tree.
    ///
    /// Nesting is what makes this necessary — a match inside a closed folder
    /// passes the filter and is still invisible, so one filters on something
    /// one cannot see. It is a fact about what the sidebar SHOWS, which is
    /// why it is answered here; what it does to the remembered collapse state
    /// (nothing — it overlays it, never writes it) is
    /// `SidebarFolderDisclosure`'s half.
    ///
    /// A tag filter does not set it. The tag row is a deliberate choice that
    /// stays on screen until it is cleared; a search is typed a character at
    /// a time, and it is the one that would otherwise hide its own results.
    public let expandsFolders: Bool

    public init(
        visibleTree: SidebarOrdering.Tree,
        showsImportedSection: Bool,
        emptiness: Emptiness,
        expandsFolders: Bool
    ) {
        self.visibleTree = visibleTree
        self.showsImportedSection = showsImportedSection
        self.emptiness = emptiness
        self.expandsFolders = expandsFolders
    }

    /// The rows to draw directly under one folder (`nil` = the top level), in
    /// display order.
    ///
    /// The order is `SidebarOrdering`'s and nothing else's: by position, and
    /// — for the zeroes every file written before this milestone is full of —
    /// folders first, then connections, each in the order `compute` was
    /// handed them. A view that draws this list in the order it arrives has
    /// derived no place for anything.
    public func children(of parentID: UUID?) -> [SidebarItem] {
        SidebarOrdering.children(of: parentID, in: visibleTree)
    }

    /// The connection one row names, or `nil` when the filter removed it.
    /// Answers from the same snapshot `children(of:)` walks, so a row handed
    /// out by one of these calls always resolves through the others.
    public func session(_ id: UUID) -> StoredSession? {
        visibleTree.sessions.first { $0.id == id }
    }

    /// The folder one row names, under the same rule as `session(_:)`.
    public func group(_ id: UUID) -> StoredGroup? {
        visibleTree.groups.first { $0.id == id }
    }

    /// Computes what the sidebar shows for `sessions`/`groups` under
    /// `tagFilter`, given `importedHostsCount` unsaved `SSHConfigHost`
    /// entries currently available to import (the sidebar's "IMPORTED"
    /// section — `SSHConfigHost` lives outside `StoredSession`, so only its
    /// count crosses into this decision, not the hosts themselves).
    ///
    /// An EMPTY `tagFilter` is "no filter": every session shows, every folder
    /// shows — including one with nothing in it, because a folder is a thing
    /// the user made, so a freshly created one is present before anything is
    /// in it, and one whose last session was just dragged out stays present —
    /// and the imported section shows whenever `importedHostsCount > 0`.
    ///
    /// A non-empty `tagFilter` keeps only the sessions it matches — which
    /// tags a session must carry, and whether all or any of them, is
    /// `SidebarTagFilter.matches(tags:)`'s answer, including why the
    /// comparison is exact. A non-empty `tagFilter` also always hides the
    /// imported section, regardless of `importedHostsCount`.
    ///
    /// `search` is the SECOND criterion in this same rule (D3), not a second
    /// filtering path: it narrows what is left, so a user who filters by tag
    /// and then types searches WITHIN the filtered list. A session matches
    /// when the predicate matches its NAME, any one of its TAGS, or the
    /// backend's own `displaySummary` — which is where a session's host and
    /// user name live since `StoredSession` stopped carrying flat SSH
    /// columns, and which is the same one-line identity the sidebar row's
    /// tooltip and the audit trail show. What that line contains is each
    /// backend's answer, not this type's: SSH spells `user@host`, while S3
    /// spells its bucket and endpoint host and names no user at all.
    ///
    /// A FOLDER NAME is never a match. A folder is on screen because
    /// something in it matched; matching the folder itself would put its
    /// whole contents on screen and claim hits that are not there.
    ///
    /// `nil` and a predicate that matches everything mean the same thing here
    /// — no search — and the second spelling is load-bearing: the App layer
    /// answers a matches-everything predicate for an INVALID regular
    /// expression, so a half-typed pattern shows its error beside a sidebar
    /// that goes on drawing what it drew. An empty sidebar from a stray `(`
    /// would look like data loss. For the same reason an invalid pattern also
    /// leaves `expandsFolders` false: nothing is being narrowed, so there is
    /// nothing to unfold for.
    ///
    /// A search hides the imported section on the same grounds an active tag
    /// does: an unfilterable section drawn beside filtered ones presents the
    /// filter as covering everything on screen.
    ///
    /// **A folder survives a filter when anything BELOW it matches**, not
    /// when its own sessions do. Nesting is what forces that: with the match
    /// two levels down, neither folder on the way to it carries a matching
    /// session, so dropping a folder for having none of its own takes the
    /// match off screen with it — the connection is in the store, passes the
    /// filter, and is reachable by no route at all. The chain is kept alive
    /// by walking upward from each match (`GroupTree.selfAndAncestors`),
    /// which is also why an ancestor can never be dropped while a descendant
    /// stays: the walk keeps both or neither.
    ///
    /// `emptiness` is `.notEmpty` whenever the top level has a row to draw or
    /// the imported section does. Otherwise — nothing anywhere — it is
    /// `.noSessionsAtAll` when `sessions` itself was empty, or
    /// `.filterMatchesNothing` when it was not (an active filter, or a
    /// dangling `groupID` naming no group in `groups`, consumed everything
    /// that would otherwise have drawn).
    public static func compute(
        sessions: [StoredSession],
        groups: [StoredGroup],
        importedHostsCount: Int,
        tagFilter: SidebarTagFilter,
        search: FileSearch.FileSearchPredicate?
    ) -> SidebarVisibility {
        // A predicate that matches everything is not a search — see this
        // method's doc comment for why that spelling has to keep meaning
        // "nothing is being filtered".
        let searching = search.map { !$0.isEmpty } ?? false

        func matchesSearch(_ session: StoredSession) -> Bool {
            guard searching, let search else { return true }
            if search.matches(session.name) { return true }
            if session.tags.contains(where: search.matches) { return true }
            let descriptor = BackendDescriptor.descriptor(for: session.kind)
            return search.matches(descriptor.displaySummary(descriptor.sessionValues(session)))
        }

        func passes(_ session: StoredSession) -> Bool {
            guard tagFilter.matches(tags: session.tags) else { return false }
            return matchesSearch(session)
        }

        let visibleSessions = sessions.filter(passes)
        let visibleGroups: [StoredGroup]
        if tagFilter.isEmpty && !searching {
            visibleGroups = groups
        } else {
            var reachable: Set<UUID> = []
            for session in visibleSessions {
                guard let groupID = session.groupID else { continue }
                reachable.formUnion(GroupTree.selfAndAncestors(of: groupID, in: groups))
            }
            visibleGroups = groups.filter { reachable.contains($0.id) }
        }

        let visibleTree = SidebarOrdering.Tree(groups: visibleGroups, sessions: visibleSessions)
        let showsImportedSection = tagFilter.isEmpty && !searching && importedHostsCount > 0

        // Structural, not incidental: this is the actual "is there anything
        // to draw" question, asked of the level the sidebar starts drawing at
        // rather than inferred from `visibleSessions.isEmpty` — which would
        // say `.notEmpty` for a session whose `groupID` names no group in
        // `groups` even though such a session hangs off a parent that draws
        // nowhere and is therefore never asked for.
        let hasAnythingToDraw =
            !SidebarOrdering.children(of: nil, in: visibleTree).isEmpty || showsImportedSection

        let emptiness: Emptiness
        if hasAnythingToDraw {
            emptiness = .notEmpty
        } else {
            emptiness = sessions.isEmpty ? .noSessionsAtAll : .filterMatchesNothing
        }

        return SidebarVisibility(
            visibleTree: visibleTree,
            showsImportedSection: showsImportedSection,
            emptiness: emptiness,
            expandsFolders: searching
        )
    }

    /// Every tag carried by any of `sessions`, deduplicated and sorted —
    /// the sidebar's filter-chip row reads this so the chips stand in a
    /// stable order across refreshes rather than reshuffling with store
    /// order.
    ///
    /// Built on `TagSuggestionRanking.counts(tagLists:)` (Task 5, fix round
    /// 2) rather than its own `sessions.flatMap(\.tags)` walk: that walk was
    /// a THIRD independent collection of tags across sessions alongside
    /// `HostTagSuggestions`' own (counts, for the suggestion list) and this
    /// method's own (no counts, for this filter-chip row) — same data,
    /// answering a related question, walked twice. Discarding the counts
    /// this method doesn't need is cheaper than maintaining a second walk.
    public static func availableTags(in sessions: [StoredSession]) -> [String] {
        Array(TagSuggestionRanking.counts(tagLists: sessions.map(\.tags)).keys).sorted()
    }

}
