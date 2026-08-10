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

    /// Adds `snippet`, or replaces the existing entry with the same `id`.
    public func save(_ snippet: Snippet) throws {
        var snippets = try all()
        snippets.removeAll { $0.id == snippet.id }
        snippets.append(snippet)
        try persist(snippets)
    }

    /// Removes the snippet with `id`, if any. Idempotent: a missing id is
    /// not an error.
    public func remove(id: UUID) throws {
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
