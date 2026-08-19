import Foundation

/// A reusable command line the Terminal menu can insert into the SSH
/// terminal panel (Terminal-Snippets milestone).
///
/// Never holds credentials: `SnippetStore` persists snippets as plain JSON
/// (`snippets.json`), and this project keeps secrets exclusively in the
/// Keychain (see `SecretStore`) — nothing that belongs there belongs in a
/// snippet's `command`.
///
/// `command` is restricted to a single line, because a snippet is submitted
/// as keystrokes into the terminal (see `SnippetKeystrokes`): a command
/// containing a line break would have every line but the last land in the
/// input line and, if the trigger appends a Return, run before the rest of
/// the text had even arrived — nobody chose to press Return for those
/// lines. Insertion itself is a later task in this milestone; this type
/// only carries the data and enforces the rule that makes that insertion
/// safe.
public struct Snippet: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    /// A single command line — never contains a character for which
    /// `Character.isNewline` is true (that covers `\n`, `\r`, `\r\n` as one
    /// grapheme cluster, and a handful of other line/paragraph separators —
    /// see the initializer). Kept `let` so this invariant cannot be broken
    /// by an in-place mutation after construction; changing the command
    /// means constructing a new `Snippet`.
    public let command: String
    /// Free-form labels that order snippets and group the trigger surfaces.
    /// Normalized at construction via `TagList.normalized` — see that
    /// type's doc comment for the exact rule. `let` for the same reason
    /// `command` is — an in-place mutation would be a second, unchecked
    /// write path around that normalization.
    public let tags: [String]

    /// Fails when `command` contains any character Swift considers a
    /// newline (`Character.isNewline`) — see the type's doc comment for why
    /// a snippet must be a single line. Checking per-character rather than
    /// with `contains("\n")`/`contains("\r")` matters: Swift's `String`
    /// compares grapheme clusters, and `"\r\n"` is ONE grapheme cluster, so
    /// those two substring checks do not see a CRLF command at all.
    public init?(id: UUID = UUID(), name: String, command: String, tags: [String] = []) {
        guard !command.contains(where: \.isNewline) else { return nil }
        self.id = id
        self.name = name
        self.command = command
        self.tags = TagList.normalized(tags)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Via the normalizing (and validating) init — otherwise decode
        // would be a second, unchecked write path that a hand-edited
        // store file could use to smuggle a multi-line command, or an
        // untrimmed/duplicate tag, past the rules the initializer above
        // enforces.
        let id = try container.decode(UUID.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let command = try container.decode(String.self, forKey: .command)
        // A store file written before tags existed carries no "tags" key
        // at all — that decodes as "no tags", not an error, so the user's
        // pre-existing snippets keep loading. Any leftover "runsImmediately"
        // key from that era is simply not decoded: an unknown key does not
        // trouble `JSONDecoder`, and the flag it carried no longer means
        // anything (see the type's doc comment).
        let tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        guard let snippet = Self(id: id, name: name, command: command, tags: tags) else {
            throw DecodingError.dataCorruptedError(
                forKey: .command, in: container,
                debugDescription: "Snippet command must be a single line, with no newline character."
            )
        }
        self = snippet
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, command, tags
    }
}
