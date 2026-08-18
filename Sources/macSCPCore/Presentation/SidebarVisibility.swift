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
/// construct and inspect, and the view that renders it (a later task) has
/// nothing left to decide, including whether the imported section counts
/// toward "nothing to show": `emptiness` already folds in
/// `importedHostsCount`, so a caller does not need its own
/// `emptiness == .noSessionsAtAll && importedHosts.isEmpty` check.
///
/// `compute` filters purely on `StoredSession.tags`; it never receives or
/// references `Snippet` in any form, and `SnippetMenuModel.build` never
/// receives `activeTag` — the two computations share no parameter, so a
/// host tag cannot reach a snippet through this type. That separation holds
/// by construction, not by a test in this file: a test that calls both
/// functions independently and checks their outputs would keep passing even
/// if `compute` were deleted entirely, since nothing here connects them.
/// The meaningful regression test — whether a caller accidentally threads
/// `activeTag` into the `snippets` list it hands to a trigger surface —
/// needs `activeTag` and `snippets` in scope together, which only happens
/// once the next task wires `SessionSidebar`/`ContentView`; that is where
/// that pin belongs, not here.
public struct SidebarVisibility: Equatable, Sendable {
    /// A group section the sidebar can render directly: the group header,
    /// plus the sessions to list under it. Paired rather than split into a
    /// `[StoredGroup]` list and a side dictionary keyed by group id — two
    /// values that would have to be kept in sync (every group in the list
    /// has a non-empty entry in the dictionary, and vice versa) for no
    /// benefit, since nothing here reorders groups relative to `sessions`
    /// by id.
    public struct GroupSection: Equatable, Sendable {
        public let group: StoredGroup
        public let sessions: [StoredSession]

        public init(group: StoredGroup, sessions: [StoredSession]) {
            self.group = group
            self.sessions = sessions
        }
    }

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

    /// Ungrouped sessions that pass the active tag filter, in `sessions`'s
    /// order.
    public let ungrouped: [StoredSession]
    /// One entry per group the sidebar should render, in `groups`'s order,
    /// each paired with exactly the sessions to list under it.
    ///
    /// With NO active tag every group gets an entry, including one with no
    /// sessions at all — a group is a thing the user made, and its header
    /// carries its Rename/Export/Dissolve menu and its drop target, so a
    /// freshly created group has to be on screen before anything is in it
    /// and a group whose last session was just dragged out has to stay
    /// there. Omitting an empty group is FILTER behaviour and nothing else:
    /// only while `activeTag` is non-nil is a group with no matching
    /// session dropped, so a narrowed sidebar does not show headers with
    /// nothing under them.
    public let groupSections: [GroupSection]
    /// Whether the sidebar's "IMPORTED" section (unsaved `SSHConfigHost`
    /// entries) should render at all: `activeTag == nil` (imported hosts
    /// carry no tags, so a tag filter can never match one, and rendering an
    /// unfilterable section next to filtered ones would misrepresent the
    /// filter as covering everything on screen) AND `importedHostsCount > 0`
    /// (an empty section has nothing to draw either way).
    public let showsImportedSection: Bool
    public let emptiness: Emptiness

    public init(
        ungrouped: [StoredSession],
        groupSections: [GroupSection],
        showsImportedSection: Bool,
        emptiness: Emptiness
    ) {
        self.ungrouped = ungrouped
        self.groupSections = groupSections
        self.showsImportedSection = showsImportedSection
        self.emptiness = emptiness
    }

    /// Computes what the sidebar shows for `sessions`/`groups` under
    /// `activeTag`, given `importedHostsCount` unsaved `SSHConfigHost`
    /// entries currently available to import (the sidebar's "IMPORTED"
    /// section — `SSHConfigHost` lives outside `StoredSession`, so only its
    /// count crosses into this decision, not the hosts themselves).
    ///
    /// `activeTag == nil` is "no filter": every session shows, every group
    /// shows (empty ones included — see `groupSections`), and the imported
    /// section shows whenever `importedHostsCount > 0`.
    ///
    /// A non-nil `activeTag` keeps only sessions whose `tags` contain it,
    /// compared exactly — against the case `TagList.normalized` deliberately
    /// preserves instead of folding, so a differently-cased spelling is a
    /// non-match here. Damping near-duplicates is the input control's job (a
    /// case-insensitive suggestion list), which is what lets this comparison
    /// stay exact. A non-nil `activeTag` also always hides the imported
    /// section, regardless of `importedHostsCount`.
    ///
    /// `emptiness` is `.notEmpty` whenever there is at least one ungrouped
    /// session, one group section (which without a filter includes an empty
    /// group — its header is something to draw), or a visible imported
    /// section.
    /// Otherwise — nothing anywhere to draw — it is `.noSessionsAtAll` when
    /// `sessions` itself was empty, or `.filterMatchesNothing` when it was
    /// not (an active filter, or a dangling `groupID` naming no group in
    /// `groups`, consumed everything that would otherwise have drawn).
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

        let filtered = sessions.filter(passes)

        let ungrouped = filtered.filter { $0.groupID == nil }
        let groupSections: [GroupSection] = groups.compactMap { group in
            let inGroup = filtered.filter { $0.groupID == group.id }
            // Gated on `activeTag`, not on `inGroup` alone: dropping an
            // empty group is how a FILTER narrows the sidebar, not how the
            // sidebar renders in general. Unconditionally, it deletes a
            // just-created group from the screen and takes a drained
            // group's header — menu and drop target with it — out of reach.
            if activeTag != nil, inGroup.isEmpty { return nil }
            return GroupSection(group: group, sessions: inGroup)
        }

        let showsImportedSection = activeTag == nil && importedHostsCount > 0

        // Structural, not incidental: this is the actual "is there anything
        // to draw" question, asked directly of the three things the sidebar
        // renders, rather than inferred from `filtered.isEmpty` — which
        // would say `.notEmpty` for a session whose `groupID` names no
        // group in `groups` even though such a session lands in neither
        // `ungrouped` nor any `groupSections` entry and so draws nothing.
        let hasAnythingToDraw = !ungrouped.isEmpty || !groupSections.isEmpty || showsImportedSection

        let emptiness: Emptiness
        if hasAnythingToDraw {
            emptiness = .notEmpty
        } else {
            emptiness = sessions.isEmpty ? .noSessionsAtAll : .filterMatchesNothing
        }

        return SidebarVisibility(
            ungrouped: ungrouped,
            groupSections: groupSections,
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
