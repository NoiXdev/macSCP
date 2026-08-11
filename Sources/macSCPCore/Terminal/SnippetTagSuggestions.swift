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
/// Pure computation over the snippets handed in — no store, no I/O.
public enum SnippetTagSuggestions {
    /// Every distinct tag across `snippets`, each paired with how many
    /// snippets carry it, sorted descending by count and, for ties,
    /// alphabetically with a case-insensitive comparison.
    public static func all(in snippets: [Snippet]) -> [(tag: String, count: Int)] {
        rank(counts(in: snippets))
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
        let lowercasedPrefix = prefix.lowercased()
        let takenLowercased = Set(taken.map { $0.lowercased() })
        let candidates = counts(in: snippets).filter { tag, _ in
            tag.lowercased().hasPrefix(lowercasedPrefix) && !takenLowercased.contains(tag.lowercased())
        }
        return rank(candidates)
    }

    /// How many snippets carry each exact tag string. `Docker` and `docker`
    /// are counted as separate entries, matching how `Snippet` stores them.
    private static func counts(in snippets: [Snippet]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for snippet in snippets {
            for tag in snippet.tags {
                counts[tag, default: 0] += 1
            }
        }
        return counts
    }

    /// Descending by count; ties broken alphabetically, case-insensitively.
    private static func rank(_ counts: [String: Int]) -> [(tag: String, count: Int)] {
        counts
            .map { (tag: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count {
                    return lhs.count > rhs.count
                }
                return lhs.tag.localizedCaseInsensitiveCompare(rhs.tag) == .orderedAscending
            }
    }
}
