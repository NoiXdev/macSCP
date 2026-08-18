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
/// A separate type from `SnippetTagSuggestions`, not that type reused or
/// generalized: host tags and snippet tags are independent vocabularies
/// (`TagList`'s own doc comment) — this counts and ranks `StoredSession
/// .tags`, never `Snippet.tags`, and the two never share a data source. The
/// counting/ranking SHAPE mirrors that type on purpose (same case-insensitive
/// search, case-preserving return, count-then-alphabetical order contract),
/// but the two are independent implementations over independent inputs, not
/// a shared engine — merging them would either leak `[Snippet]` into this
/// module's session-only concerns or leak `StoredSession` into
/// `SnippetTagSuggestions`'s.
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
        let lowercasedPrefix = prefix.lowercased()
        let takenLowercased = Set(taken.map { $0.lowercased() })
        let candidates = counts(in: sessions).filter { tag, _ in
            tag.lowercased().hasPrefix(lowercasedPrefix) && !takenLowercased.contains(tag.lowercased())
        }
        return rank(candidates)
    }

    /// How many sessions carry each exact tag string. `Docker` and `docker`
    /// are counted as separate entries, matching how `StoredSession` stores
    /// them (`TagList.normalized` trims and dedupes exact duplicates only).
    private static func counts(in sessions: [StoredSession]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for session in sessions {
            for tag in session.tags {
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
