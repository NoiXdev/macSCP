import Foundation

/// The one computed shape for every trigger surface that lists snippets —
/// the menu bar, a session's context menu, the terminal panel's header
/// button, and the terminal's right-click menu. Each of those four views
/// used to derive its own grouping and its own disabled state; this type
/// computes both once so the four surfaces render a shared answer instead
/// of four hand-guessed ones.
///
/// Pure computation over the snippets handed in — no store, no I/O.
public struct SnippetMenuModel: Equatable, Sendable {
    /// Why the entries are present but not actionable. The entries stay
    /// visible in both cases — a disabled entry teaches where the feature
    /// lives; a missing one teaches nothing.
    public enum DisabledReason: Equatable, Sendable {
        /// This tab has a shell, but no connection is open right now.
        /// Connecting removes this reason.
        case notConnected
        /// This tab's backend (S3, WebDAV) has no shell at all. Connecting
        /// never removes this reason — it is a property of the backend, not
        /// of the connection.
        case backendHasNoShell
    }

    /// One tag's snippets, in store order. `tag == nil` marks the trailing
    /// group of snippets that carry no tag at all.
    public struct Group: Identifiable, Equatable, Sendable {
        public var id: String { tag ?? "" }
        public let tag: String?
        public let snippets: [Snippet]
    }

    /// Tag groups in alphabetical (case-insensitive) order, ties broken by
    /// first appearance across `snippets`, with the untagged group — if any
    /// snippet is untagged — always last. A snippet carrying two tags
    /// appears once per tag: that duplication is what a tag means, and it
    /// is deliberate, not an oversight. Empty (no matching snippets) groups
    /// are never produced; `groups` is `[]` when `snippets` is `[]`.
    public let groups: [Group]
    public let disabledReason: DisabledReason?
    public var isEmpty: Bool { groups.isEmpty }

    /// Groups `snippets` by tag and decides whether the entries are usable
    /// right now.
    ///
    /// When `isConnected` is `false` and `supportsShell` is also `false`,
    /// `backendHasNoShell` wins over `notConnected`. Reasoning: shell-lessness
    /// is a permanent property of the backend (S3, WebDAV) that connecting
    /// can never change, while `notConnected` implies the feature starts
    /// working once the user connects. Reporting `notConnected` here would
    /// promise a fix that does not exist; `backendHasNoShell` tells the
    /// truth regardless of connection state.
    public static func build(
        snippets: [Snippet], isConnected: Bool, supportsShell: Bool
    ) -> SnippetMenuModel {
        let disabledReason: DisabledReason?
        if !supportsShell {
            disabledReason = .backendHasNoShell
        } else if !isConnected {
            disabledReason = .notConnected
        } else {
            disabledReason = nil
        }

        // Tags in order of first appearance, deduplicated, then sorted
        // case-insensitively. Swift's `sorted(by:)` is a stable sort, so
        // tags that compare equal case-insensitively (e.g. "Docker" and
        // "docker") keep their first-appearance order relative to each
        // other rather than being reshuffled by the sort.
        var orderedTags: [String] = []
        var seenTags = Set<String>()
        for snippet in snippets {
            for tag in snippet.tags where seenTags.insert(tag).inserted {
                orderedTags.append(tag)
            }
        }
        let sortedTags = orderedTags.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }

        var groups = sortedTags.map { tag in
            Group(tag: tag, snippets: snippets.filter { $0.tags.contains(tag) })
        }

        let untagged = snippets.filter { $0.tags.isEmpty }
        if !untagged.isEmpty {
            groups.append(Group(tag: nil, snippets: untagged))
        }

        return SnippetMenuModel(groups: groups, disabledReason: disabledReason)
    }
}
