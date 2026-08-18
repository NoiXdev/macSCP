import Foundation

/// The one normalization every tag vocabulary in this app goes through:
/// trimmed, empties dropped, exact duplicates dropped, order of first
/// appearance kept, case left as typed.
///
/// Case is deliberately preserved — `Docker` and `docker` stay two tags.
/// Damping that is the input control's job (a case-insensitive suggestion
/// list), not this function's: folding case here would silently rewrite
/// what the user typed.
///
/// Design intent: host tags and snippet tags stay INDEPENDENT vocabularies —
/// a host tag hides no snippet. Pinned by
/// `SidebarFilterWiringTests.sessionRowsPassTheFullUnfilteredSnippetListRegardlessOfTheActiveTagFilter`
/// (P3a/T6): `SessionSidebar` is the one place `StoredSession.tags`
/// (filtering which sessions show) and `Snippet` (what a row's "Snippet"
/// submenu offers) are both in scope, so that is where the claim finally
/// became observable — `SidebarVisibility.compute` itself never receives a
/// `Snippet` in any form (see its own doc comment), so there was nothing to
/// pin against it directly. That test is a SOURCE-TEXT scan, not a
/// behavioral one (no view-instantiation tool in this project — see
/// `SessionSidebar`'s other guards for the same boundary): it pins that the
/// row constructor is handed the unfiltered `snippets` array verbatim, not
/// something derived from `activeTag`.
///
/// Independent VOCABULARIES, shared MACHINERY: two things now serve both
/// sides — the normalization rule below, and `TagSuggestionRanking`, the
/// counting-and-ranking engine behind both suggestion lists (extracted in
/// P3a/T5, which also folded the sidebar's filter-chip row onto it). Both
/// are shared for the same reason, that two copies of one rule drift apart
/// without any test noticing, and both carry an equivalence pin against
/// exactly that drift (`TagListTests`, `TagSuggestionRankingEquivalenceTests`).
/// What is NOT shared is the tag data itself: a host tag and a snippet tag
/// never meet.
public enum TagList {
    public static func normalized(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
