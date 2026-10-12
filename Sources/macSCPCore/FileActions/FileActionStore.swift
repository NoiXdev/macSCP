import Foundation

/// JSON persistence for user-defined file actions (`file-actions.json`),
/// following the same stateless, atomic-write pattern as `SnippetStore`.
///
/// Its **own file**, which is the point rather than a detail: an action and
/// a snippet are different kinds with different trust properties, and a
/// single file holding both would be one decode away from treating one as
/// the other. Secret-free by construction — a `FileAction` holds a command
/// template and nothing else.
public struct FileActionStore: Sendable {
    private let directory: URL
    private let fileURL: URL

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("file-actions.json")
    }

    public func all() throws -> [FileAction] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return []
        }
        return try JSONDecoder().decode([FileAction].self, from: try Data(contentsOf: fileURL))
    }

    /// Adds `action` at the end, or replaces the entry with the same `id`
    /// **in place**. In place rather than remove-and-append because the
    /// context menu lists actions in exactly this order, and an edit that
    /// moved one to the end would reorder the menu with nothing asking for
    /// it.
    public func save(_ action: FileAction) throws {
        var actions = try all()
        if let index = actions.firstIndex(where: { $0.id == action.id }) {
            actions[index] = action
        } else {
            actions.append(action)
        }
        try persist(actions)
    }

    /// Removes the action with `id`, if any. Idempotent: a missing id is
    /// not an error. Returns nothing, unlike `SnippetStore.remove`, which
    /// reports on the remembered variable values a snippet can have — an
    /// action has no such memory.
    public func remove(id: UUID) throws {
        try persist(try all().filter { $0.id != id })
    }

    private func persist(_ actions: [FileAction]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(actions)
        try data.write(to: fileURL, options: .atomic)
    }
}
