import Foundation

/// The one counting/ranking/prefix-filter engine every tag-suggestion list
/// in this app goes through (Task 5, fix round 2) — `SnippetTagSuggestions`
/// (`Snippet.tags`) and `HostTagSuggestions` (`StoredSession.tags`) are both
/// thin adapters over this, each supplying its own vocabulary's tag lists
/// and nothing else. Extracted after review found the two types' `counts`/
/// `rank`/`matching` were structurally identical — same case-insensitive
/// prefix filter and exclusion, same count-then-alphabetical sort — and
/// differed only in the element type they walked and which property held
/// the tags. This is exactly the "two copies of one rule, correct today,
/// drifting tomorrow" shape `TagList.normalized` exists to prevent for
/// normalization; this type is the same fix for RANKING.
///
/// Host tags and snippet tags stay independent VOCABULARIES regardless
/// (`TagList`'s own doc comment) — this engine never sees `Snippet` or
/// `StoredSession`, only the flat `[[String]]` each caller extracts from its
/// own model, so the two vocabularies' DATA never crosses. Sharing the
/// algorithm is not the same as sharing the data.
///
/// `internal`, not `public`: both current callers live in this module, and
/// making this part of `macSCPCore`'s public surface before a second module
/// needs it would be a promise nothing yet asks for.
///
/// Pure computation over the tag lists handed in — no store, no I/O.
enum TagSuggestionRanking {
    /// Every distinct tag across `tagLists` (each element is one item's own
    /// `tags`), paired with how many items carry it, ranked by count
    /// descending then alphabetically (case-insensitively) on ties.
    static func all(tagLists: [[String]]) -> [(tag: String, count: Int)] {
        rank(counts(tagLists: tagLists))
    }

    /// The subset of `all(tagLists:)` whose tag starts with `prefix`
    /// (case-insensitively) and is not already in `taken`
    /// (case-insensitively). An empty `prefix` matches every untaken tag —
    /// what an empty, focused tag field should offer.
    static func matching(
        _ prefix: String, tagLists: [[String]], excluding taken: [String]
    ) -> [(tag: String, count: Int)] {
        let lowercasedPrefix = prefix.lowercased()
        let takenLowercased = Set(taken.map { $0.lowercased() })
        let candidates = counts(tagLists: tagLists).filter { tag, _ in
            tag.lowercased().hasPrefix(lowercasedPrefix) && !takenLowercased.contains(tag.lowercased())
        }
        return rank(candidates)
    }

    /// How many items carry each exact tag string. `Docker` and `docker`
    /// are counted as separate entries — case is never folded here, only
    /// searched case-insensitively (see `matching`).
    static func counts(tagLists: [[String]]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for tags in tagLists {
            for tag in tags {
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
