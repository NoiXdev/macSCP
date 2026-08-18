import Foundation

/// Suggests existing HOST tags (`StoredSession.tags`) while `ConnectionFormView`'s
/// tag field is being typed into — the `SnippetTagSuggestions` counterpart
/// for the other tag vocabulary this app has.
///
/// This is not decoration: `TagList.normalized` deliberately preserves case
/// (see its own doc comment) and explicitly assigns damping the resulting
/// near-duplicates to "the input control's job (a case-insensitive
/// suggestion list)". `SidebarVisibility.compute` compares tags exactly, so
/// without a suggestion list here, a user who types `Docker` on one host and
/// `docker` on another gets two sidebar filter chips that mean the same
/// thing, each matching only half the intended hosts. This type is that
/// suggestion list's data source.
///
/// A thin adapter over `TagSuggestionRanking` (Task 5, fix round 2) — this
/// type's own job is just handing `StoredSession.tags` to the shared engine;
/// `SnippetTagSuggestions` is the same adapter for `Snippet.tags`. Kept as
/// its own public type (rather than callers using `TagSuggestionRanking`
/// directly) so `StoredSession`, the vocabulary this type is FOR, stays out
/// of the shared engine entirely — host tags and snippet tags remain
/// independent vocabularies (`TagList`'s own doc comment), only the ranking
/// ALGORITHM is shared.
///
/// `SidebarVisibility.availableTags(in:)` walks the same `StoredSession
/// .tags` to answer a different question (every distinct tag, no counts,
/// for the sidebar's filter-chip row) — it now shares `TagSuggestionRanking
/// .counts(tagLists:)` with this type rather than each running its own
/// independent walk over `sessions`, so there is exactly one place that
/// collects tags across sessions, not two.
///
/// Pure computation over the sessions handed in — no store, no I/O.
public enum HostTagSuggestions {
    /// The subset of every distinct tag across `sessions` whose text starts
    /// with `prefix` (case-insensitively) and is not already in `taken`
    /// (case-insensitively), each paired with how many sessions carry it,
    /// ranked by count descending then alphabetically (case-insensitively)
    /// on ties. An empty `prefix` matches every untaken tag — what an empty,
    /// focused tag field should offer.
    public static func matching(
        _ prefix: String, in sessions: [StoredSession], excluding taken: [String]
    ) -> [(tag: String, count: Int)] {
        TagSuggestionRanking.matching(prefix, tagLists: sessions.map(\.tags), excluding: taken)
    }
}
