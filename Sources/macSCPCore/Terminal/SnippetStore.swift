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

    /// Removes the snippet with `id`, if any, and forgets any variable
    /// values remembered for it (`SnippetVariableMemoryStore`, next to
    /// `snippets.json` in the same directory) — the same coupling deleting
    /// a session has with its Keychain entry: a remembered value that
    /// outlives the snippet it belonged to is an orphan nothing will ever
    /// look up again, since every lookup goes through a snippet id resolved
    /// from the still-listed snippet.
    ///
    /// Forgetting runs FIRST, mirroring `ManagedKeyStore.remove`'s
    /// Keychain-first order: on a `forget` failure this throws before
    /// touching `snippets.json`, leaving the snippet fully listed — visible
    /// and retryable — rather than gone while its values are stranded on
    /// disk.
    ///
    /// Idempotent: a missing id is not an error.
    public func remove(id: UUID) throws {
        try SnippetVariableMemoryStore(directory: directory).forget(snippetID: id)
        var snippets = try all()
        snippets.removeAll { $0.id == id }
        try persist(snippets)
    }

    private func persist(_ snippets: [Snippet]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snippets).write(to: fileURL, options: .atomic)
    }
}
