import Foundation

/// What the session sidebar shows, for a given store snapshot, the current
/// imported-host count, and an optional active tag filter — computed once,
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
/// `compute` filters purely on `StoredSession.tags`; it never receives or
/// references `Snippet` in any form, and `SnippetMenuModel.build` never
/// receives `activeTag` — the two computations share no parameter, so a host
/// tag cannot reach a snippet through this type. That separation holds by
/// construction, not by a test in this file: a test that calls both functions
/// independently and checks their outputs would keep passing even if
/// `compute` were deleted entirely, since nothing here connects them. The
/// meaningful regression test — whether a caller accidentally threads
/// `activeTag` into the `snippets` list it hands to a trigger surface — needs
/// `activeTag` and `snippets` in scope together, which only happens in
/// `SessionSidebar`/`ContentView`; that is where that pin lives
/// (`SidebarFilterWiringTests`), not here.
public struct SidebarVisibility: Equatable, Sendable {
    /// Distinguishes "there is nothing to show because the store is empty"
    /// from "there is nothing to show because the active tag matched
    /// nothing" — the sidebar needs different copy for each (an empty store
    /// invites creating a session; a filter matching nothing invites
    /// clearing the filter).
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
    /// entries) should render at all: `activeTag == nil` (imported hosts
    /// carry no tags, so a tag filter can never match one, and rendering an
    /// unfilterable section next to filtered ones would misrepresent the
    /// filter as covering everything on screen) AND `importedHostsCount > 0`
    /// (an empty section has nothing to draw either way).
    public let showsImportedSection: Bool
    public let emptiness: Emptiness

    public init(
        visibleTree: SidebarOrdering.Tree,
        showsImportedSection: Bool,
        emptiness: Emptiness
    ) {
        self.visibleTree = visibleTree
        self.showsImportedSection = showsImportedSection
        self.emptiness = emptiness
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
    /// `activeTag`, given `importedHostsCount` unsaved `SSHConfigHost`
    /// entries currently available to import (the sidebar's "IMPORTED"
    /// section — `SSHConfigHost` lives outside `StoredSession`, so only its
    /// count crosses into this decision, not the hosts themselves).
    ///
    /// `activeTag == nil` is "no filter": every session shows, every folder
    /// shows — including one with nothing in it, because a folder is a thing
    /// the user made, so a freshly created one is present before anything is
    /// in it, and one whose last session was just dragged out stays present —
    /// and the imported section shows whenever `importedHostsCount > 0`.
    ///
    /// A non-nil `activeTag` keeps only sessions whose `tags` contain it,
    /// compared exactly — against the case `TagList.normalized` deliberately
    /// preserves instead of folding, so a differently-cased spelling is a
    /// non-match here. Damping near-duplicates is the input control's job (a
    /// case-insensitive suggestion list), which is what lets this comparison
    /// stay exact. A non-nil `activeTag` also always hides the imported
    /// section, regardless of `importedHostsCount`.
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
        activeTag: String?
    ) -> SidebarVisibility {
        func passes(_ session: StoredSession) -> Bool {
            guard let activeTag else { return true }
            return session.tags.contains(activeTag)
        }

        let visibleSessions = sessions.filter(passes)
        let visibleGroups: [StoredGroup]
        if activeTag == nil {
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
        let showsImportedSection = activeTag == nil && importedHostsCount > 0

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
            emptiness: emptiness
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

    /// `activeTag` if some session still carries it, `nil` otherwise — so a
    /// caller that restores a persisted filter selection (or reacts to the
    /// last session with a tag being retagged or deleted) can fall back to
    /// "no filter" instead of holding a selection nothing can ever match.
    public static func resolvedTag(_ activeTag: String?, in sessions: [StoredSession]) -> String? {
        guard let activeTag, sessions.contains(where: { $0.tags.contains(activeTag) }) else {
            return nil
        }
        return activeTag
    }
}
