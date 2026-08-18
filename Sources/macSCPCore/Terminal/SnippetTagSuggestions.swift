import Foundation

/// Suggests existing tags while a tag field is being typed into, so a user
/// who types `doc` is offered the already-existing `Docker` instead of
/// creating a second, differently-cased tag.
///
/// `Snippet.tags` is normalized only by trimming — case is kept exactly as
/// typed (see that type's doc comment), so `Docker` and `docker` are two
/// distinct tags in the store. That is a deliberate maintainer decision; this
/// type dampens the duplicate risk it creates, but only at the input: the
/// search that finds candidates is case-insensitive, while the tag text it
/// hands back is always the one exactly as stored. It never lowercases (or
/// otherwise rewrites) what it returns — offering a normalized string instead
/// of the stored one would recreate the very duplicates this type exists to
/// prevent.
///
/// A thin adapter over `TagSuggestionRanking` (Task 5, fix round 2) — this
/// type's own job is just handing `Snippet.tags` to the shared engine;
/// `HostTagSuggestions` is the same adapter for `StoredSession.tags`. Kept
/// as its own public type (rather than callers using `TagSuggestionRanking`
/// directly) so `Snippet`, the vocabulary this type is FOR, stays out of the
/// shared engine entirely.
///
/// Pure computation over the snippets handed in — no store, no I/O.
public enum SnippetTagSuggestions {
    /// Every distinct tag across `snippets`, each paired with how many
    /// snippets carry it, sorted descending by count and, for ties,
    /// alphabetically with a case-insensitive comparison.
    public static func all(in snippets: [Snippet]) -> [(tag: String, count: Int)] {
        TagSuggestionRanking.all(tagLists: snippets.map(\.tags))
    }

    /// The subset of `all(in:)` whose tag starts with `prefix`
    /// (case-insensitively) and is not already in `taken`
    /// (case-insensitively). An empty `prefix` matches every tag, which is
    /// what an empty, focused tag field should offer.
    public static func matching(
        _ prefix: String,
        in snippets: [Snippet],
        excluding taken: [String]
    ) -> [(tag: String, count: Int)] {
        TagSuggestionRanking.matching(prefix, tagLists: snippets.map(\.tags), excluding: taken)
    }
}
