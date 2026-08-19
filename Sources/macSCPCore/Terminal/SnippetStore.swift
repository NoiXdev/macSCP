import Foundation

/// JSON persistence for reusable terminal snippets (`snippets.json`),
/// following the `ManagedKeyStore`/`KnownHostsStore` pattern: stateless,
/// atomic writes. Secret-free by construction — `Snippet` never holds
/// credentials (see its own doc comment).
public struct SnippetStore: Sendable {
    private let directory: URL
    private let fileURL: URL

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("snippets.json")
    }

    public func all() throws -> [Snippet] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([Snippet].self, from: data)
    }

    /// Adds `snippet` at the end, or replaces the existing entry with the
    /// same `id` **in place**.
    ///
    /// Replacing in place rather than removing and appending keeps the list
    /// order stable across an edit. The order is not cosmetic: the Terminal
    /// menu lists snippets in exactly this order and hands the first three
    /// inserting ones a ⌃⌘n shortcut, so a remove-and-append would silently
    /// move an edited snippet to the end and reassign those shortcuts.
    public func save(_ snippet: Snippet) throws {
        var snippets = try all()
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
        try persist(snippets)
    }

    /// What `remove(id:)` was able to do about the snippet's remembered
    /// variable values.
    public enum VariableCleanupOutcome: Sendable, Equatable {
        /// The snippet had no remembered values, or they were forgotten.
        case forgotten
        /// `snippet-variables.json` could not be read or written, so
        /// whatever was remembered for the snippet is still on disk. Never
        /// blocks the snippet's own removal — see `remove(id:)`.
        case skipped
    }

    /// Removes the snippet with `id`, if any, and best-effort forgets any
    /// variable values remembered for it (`SnippetVariableMemoryStore`,
    /// next to `snippets.json` in the same directory) — the same coupling
    /// deleting a session has with its Keychain entry: a remembered value
    /// that outlives the snippet it belonged to is an orphan nothing will
    /// ever look up again, since every lookup goes through a snippet id
    /// resolved from the still-listed snippet.
    ///
    /// Best-effort, unlike `ManagedKeyStore.remove`'s Keychain step: that
    /// step (`secrets.deletePassword(for:)`) touches exactly the ONE
    /// Keychain item for the id being removed, so a failure there is
    /// specific to this deletion and right to abort it.
    /// `SnippetVariableMemoryStore.init` instead decodes the WHOLE shared
    /// `snippet-variables.json` — a file a hand edit or an unrelated bug's
    /// partial write can corrupt independently of any particular snippet.
    /// Letting that failure abort `remove` would make deleting ANY
    /// snippet impossible, including one that never had a remembered
    /// value, until someone fixed a file this deletion has nothing to do
    /// with. So the cleanup step is caught here instead of propagated, and
    /// its result comes back as `VariableCleanupOutcome` rather than
    /// vanishing unreported: a swallowed read that only skips cleanup,
    /// never one that decides whether the deletion happens. A genuine
    /// failure to remove the snippet itself — `persist` unable to write
    /// `snippets.json` — still throws, same as before.
    ///
    /// Idempotent: a missing id is not an error.
    @discardableResult
    public func remove(id: UUID) throws -> VariableCleanupOutcome {
        let outcome: VariableCleanupOutcome
        do {
            try SnippetVariableMemoryStore(directory: directory).forget(snippetID: id)
            outcome = .forgotten
        } catch {
            outcome = .skipped
        }
        var snippets = try all()
        snippets.removeAll { $0.id == id }
        try persist(snippets)
        return outcome
    }

    private func persist(_ snippets: [Snippet]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snippets).write(to: fileURL, options: .atomic)
    }
}
