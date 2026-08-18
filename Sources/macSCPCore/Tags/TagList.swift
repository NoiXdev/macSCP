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
/// Design intent, not yet pinned by any test: host tags and snippet tags
/// are meant to stay INDEPENDENT vocabularies — a host tag should hide no
/// snippet. `StoredSession.tags` exists now, but nothing yet reads it to
/// filter or hide anything, so there is still no behavior for a test to
/// observe the claim against; whichever later task adds the sidebar filter
/// is expected to add a test that does. Only the normalization rule below
/// is shared today, because two copies of one rule drift apart without any
/// test noticing.
public enum TagList {
    public static func normalized(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
