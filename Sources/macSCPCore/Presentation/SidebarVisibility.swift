import Foundation

/// What the session sidebar shows, for a given store snapshot and an
/// optional active tag filter — computed once, here, instead of decided
/// piecemeal in the view body.
///
/// This is the type P2's terminal-chrome sidebar work did not have: that
/// milestone's pane-visibility decision lived as two loose booleans in a
/// SwiftUI body, and by the time a defect surfaced (a combination that
/// rendered an empty window), the only test available to guard it read the
/// view file's source text. `SidebarVisibility.compute` exists so the same
/// mistake is not possible here — the decision is a value a test can
/// construct and inspect, and the view that renders it (a later task) has
/// nothing left to decide.
///
/// `compute` filters purely on `StoredSession.tags`; it never receives or
/// references `Snippet` in any form. That is not an oversight — `TagList`'s
/// doc comment states host tags and snippet tags are meant to stay
/// independent vocabularies, and the signature below is how this task keeps
/// that true: there is no parameter through which an active host tag could
/// reach a snippet, so no wiring mistake inside this function can hide one.
/// See `SidebarVisibilityTests.aHostTagNeverHidesASnippet` for the test that
/// pins this at the boundary where it becomes observable, and this file's
/// bottom note for the residual gap that test cannot close.
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
    /// Groups that have at least one session passing the filter, in
    /// `groups`'s order, each paired with exactly its matching sessions. A
    /// group with no matching session is omitted entirely, so a filtered
    /// sidebar never renders an empty section header.
    public let groupSections: [GroupSection]
    /// Whether the sidebar's "IMPORTED" section (unsaved `SSHConfigHost`
    /// entries) should render at all. `false` whenever a tag filter is
    /// active: imported hosts carry no tags, so a host tag can never match
    /// one, and rendering an unfilterable section next to filtered ones
    /// would misrepresent the filter as covering everything on screen.
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
    /// `activeTag`. `activeTag == nil` is "no filter": every session shows,
    /// every group with at least one session shows, and the imported
    /// section shows. A non-nil `activeTag` keeps only sessions whose
    /// `tags` contain it — compared exactly, the same case-sensitive rule
    /// `TagList.normalized` stores by and `SnippetTagFilter.matches` reads
    /// by, so a differently-cased spelling is a non-match here too.
    public static func compute(
        sessions: [StoredSession],
        groups: [StoredGroup],
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
            return inGroup.isEmpty ? nil : GroupSection(group: group, sessions: inGroup)
        }

        let emptiness: Emptiness
        if sessions.isEmpty {
            emptiness = .noSessionsAtAll
        } else if filtered.isEmpty {
            emptiness = .filterMatchesNothing
        } else {
            emptiness = .notEmpty
        }

        return SidebarVisibility(
            ungrouped: ungrouped,
            groupSections: groupSections,
            showsImportedSection: activeTag == nil,
            emptiness: emptiness
        )
    }

    /// Every tag carried by any of `sessions`, deduplicated and sorted —
    /// the sidebar's filter-chip row reads this so the chips stand in a
    /// stable order across refreshes rather than reshuffling with store
    /// order.
    public static func availableTags(in sessions: [StoredSession]) -> [String] {
        Array(Set(sessions.flatMap(\.tags))).sorted()
    }

    /// `activeTag` if some session still carries it, `nil` otherwise — so a
    /// caller that restores a persisted filter selection (or reacts to the
    /// last session with a tag being retagged or deleted) can fall back to
    /// "no filter" instead of holding a selection nothing can ever match.
    public static func resolvedTag(_ activeTag: String?, in sessions: [StoredSession]) -> String? {
        guard let activeTag, availableTags(in: sessions).contains(activeTag) else { return nil }
        return activeTag
    }
}
