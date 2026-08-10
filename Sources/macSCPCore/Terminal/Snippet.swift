import Foundation

/// A reusable command line the Terminal menu can insert into the SSH
/// terminal panel (Terminal-Snippets milestone).
///
/// Never holds credentials: `SnippetStore` persists snippets as plain JSON
/// (`snippets.json`), and this project keeps secrets exclusively in the
/// Keychain (see `SecretStore`) — nothing that belongs there belongs in a
/// snippet's `command`.
///
/// `command` is restricted to a single line, because insertion is meant to
/// paste the text and, when `runsImmediately` is set, follow it with one
/// Return: a command containing a line break would run every line but the
/// last on its own the moment it was inserted, with nobody having pressed
/// Return for those lines. Insertion itself is a later task in this
/// milestone; this type only carries the data and enforces the rule that
/// makes that insertion safe.
public struct Snippet: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    /// A single command line — never contains `\n` or `\r`. Kept `let` so
    /// this invariant cannot be broken by an in-place mutation after
    /// construction; changing the command means constructing a new
    /// `Snippet`.
    public let command: String
    public var runsImmediately: Bool

    /// Fails when `command` contains a line break (`\n` or `\r`) — see the
    /// type's doc comment for why a snippet must be a single line.
    public init?(id: UUID = UUID(), name: String, command: String, runsImmediately: Bool) {
        guard !command.contains("\n"), !command.contains("\r") else { return nil }
        self.id = id
        self.name = name
        self.command = command
        self.runsImmediately = runsImmediately
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Via the normalizing (and validating) init — otherwise decode
        // would be a second, unchecked write path that a hand-edited
        // store file could use to smuggle a multi-line command past the
        // rule the initializer above enforces.
        let id = try container.decode(UUID.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let command = try container.decode(String.self, forKey: .command)
        let runsImmediately = try container.decode(Bool.self, forKey: .runsImmediately)
        guard let snippet = Self(id: id, name: name, command: command, runsImmediately: runsImmediately) else {
            throw DecodingError.dataCorruptedError(
                forKey: .command, in: container,
                debugDescription: "Snippet command must be a single line, without \\n or \\r."
            )
        }
        self = snippet
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, command, runsImmediately
    }
}
