import Foundation

/// JSON persistence for the values a person typed into an opted-in snippet
/// variable (`SnippetVariable.remembersLastValue`), so the next run can
/// pre-fill them. Lives in `snippet-variables.json`, next to
/// `SnippetStore`'s `snippets.json` in the same directory — never inside
/// `Snippet` itself: a value someone typed is not part of the template, and
/// keeping it out means export and sharing a snippet never carries a typed
/// value along with it.
///
/// This store does not know which declarations opted in — `remember` is
/// only ever called for a declaration that did, and that opt-in check lives
/// at the declaration, not here. It just stores what it is told.
///
/// A class, not a struct like `SnippetStore`/`HiddenImportStore`:
/// `value(snippetID:name:)` cannot throw — a caller asks it while filling in
/// a form, where a decode failure must read as "nothing remembered" rather
/// than interrupt whatever they were doing — so the file is decoded once,
/// at `init`, into an in-memory cache that every read afterward consults
/// directly. `remember`/`forget` update that cache and persist it
/// (`options: .atomic`, the same write `SnippetStore` uses) in one call.
public final class SnippetVariableMemoryStore {
    private struct Entry: Codable, Equatable {
        var snippetID: UUID
        var name: String
        var value: String
    }

    private let directory: URL
    private let fileURL: URL
    private var entries: [Entry]

    public init(directory: URL) throws {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("snippet-variables.json")
        if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: fileURL))
        } else {
            entries = []
        }
    }

    /// The remembered value for `name` on the snippet `snippetID`, or `nil`
    /// if nothing was ever remembered for that pair.
    public func value(snippetID: UUID, name: String) -> String? {
        entries.first { $0.snippetID == snippetID && $0.name == name }?.value
    }

    /// Remembers `value` for `name` on the snippet `snippetID`, replacing
    /// whatever was remembered for that pair before.
    public func remember(_ value: String, snippetID: UUID, name: String) throws {
        if let index = entries.firstIndex(where: { $0.snippetID == snippetID && $0.name == name }) {
            entries[index].value = value
        } else {
            entries.append(Entry(snippetID: snippetID, name: name, value: value))
        }
        try persist()
    }

    /// Forgets every remembered value for the snippet `snippetID`.
    /// Idempotent: a snippet with nothing remembered is not an error, and
    /// skips the write entirely rather than touching disk for no reason.
    public func forget(snippetID: UUID) throws {
        let countBefore = entries.count
        entries.removeAll { $0.snippetID == snippetID }
        guard entries.count != countBefore else { return }
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
    }
}
