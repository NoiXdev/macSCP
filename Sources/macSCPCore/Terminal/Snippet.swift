import Foundation

/// A reusable command line the Terminal menu can insert into the SSH
/// terminal panel (Terminal-Snippets milestone).
///
/// Never holds credentials: `SnippetStore` persists snippets as plain JSON
/// (`snippets.json`), and this project keeps secrets exclusively in the
/// Keychain (see `SecretStore`) — nothing that belongs there belongs in a
/// snippet's `command`.
public struct Snippet: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    /// Kept `let` so the command cannot be mutated in place; changing it
    /// means constructing a new `Snippet`.
    public let command: String
    /// Free-form labels that order snippets and group the trigger surfaces.
    /// Normalized at construction via `TagList.normalized` — see that
    /// type's doc comment for the exact rule. `let` for the same reason
    /// `command` is — an in-place mutation would be a second, unchecked
    /// write path around that normalization.
    public let tags: [String]
    /// Values this snippet asks for before it runs (snippet editor, part 3).
    /// See `SnippetVariable`'s doc comment.
    public let variables: [SnippetVariable]

    /// Normalizes `tags` via `TagList.normalized` — see that type's doc
    /// comment for the exact rule.
    ///
    /// No longer failable (snippet editor, part 2): the single-line rule was
    /// the only thing this initializer ever rejected, and a command may now
    /// span lines. How a multi-line command reaches the shell is
    /// `SnippetSendPlanner`'s decision, not the model's.
    public init(
        id: UUID = UUID(), name: String, command: String, tags: [String] = [],
        variables: [SnippetVariable] = []
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.tags = TagList.normalized(tags)
        self.variables = variables
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Via the normalizing init — otherwise decode would be a second
        // write path that a hand-edited store file could use to smuggle an
        // untrimmed or duplicate tag past the normalization above.
        let id = try container.decode(UUID.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let command = try container.decode(String.self, forKey: .command)
        // A store file written before tags (or variables) existed carries
        // no "tags" or "variables" key at all — that decodes as "no tags" /
        // "no variables", not an error, so the user's pre-existing snippets
        // keep loading. Any leftover "runsImmediately" key from that era is
        // simply not decoded: an unknown key does not trouble
        // `JSONDecoder`, and the flag it carried no longer means anything
        // (see the type's doc comment).
        let tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        let variables =
            try container.decodeIfPresent([SnippetVariable].self, forKey: .variables) ?? []
        self = Self(id: id, name: name, command: command, tags: tags, variables: variables)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, command, tags, variables
    }
}
