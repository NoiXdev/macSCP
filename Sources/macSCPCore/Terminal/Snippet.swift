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
    /// Switches off the placeholder PLACEMENT check for THIS snippet, and
    /// nothing else.
    ///
    /// What it switches off is one question: `SnippetVariableSubstitution
    /// .firstDeclarationProblem` stops asking `SnippetCommandSurvey` where
    /// a `{{NAME}}` sits in the command, so the four refusals that answer
    /// that question — a placeholder inside quotes, one that is not a plain
    /// unquoted argument, one whose own command re-parses its arguments,
    /// and a command the survey cannot read at all — no longer arise.
    ///
    /// What it leaves alone: the name rule
    /// (`SnippetVariable.isValidName`), the unused-placeholder check, the
    /// `PosixQuoting.singleQuoted` wrapping every value still gets in
    /// `resolve`, and `SnippetSendPlanner`'s refusal of a multi-line
    /// insert. That last one is a different question — it is about how
    /// bytes reach a shell, not about where a value sits — and
    /// `SnippetSendPlanner.plan` takes a command, not a `Snippet`, so this
    /// field has no way of reaching it.
    ///
    /// `false` means the check runs. That is the default, and it is what an
    /// absent key decodes to (see `init(from:)`), so every store file
    /// written before this field existed keeps loading with the check on.
    ///
    /// **It does not travel.** `ExportedSnippet` does not name it, so an
    /// export file cannot express it and an imported snippet always arrives
    /// with the check on — a capability boundary rather than an import-side
    /// cleanup rule someone has to remember. See `ExportedSnippet`'s doc
    /// comment.
    public let skipsPlaceholderPlacementCheck: Bool

    /// Normalizes `tags` via `TagList.normalized` — see that type's doc
    /// comment for the exact rule.
    ///
    /// No longer failable (snippet editor, part 2): the single-line rule was
    /// the only thing this initializer ever rejected, and a command may now
    /// span lines. How a multi-line command reaches the shell is
    /// `SnippetSendPlanner`'s decision, not the model's.
    public init(
        id: UUID = UUID(), name: String, command: String, tags: [String] = [],
        variables: [SnippetVariable] = [], skipsPlaceholderPlacementCheck: Bool = false
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.tags = TagList.normalized(tags)
        self.variables = variables
        self.skipsPlaceholderPlacementCheck = skipsPlaceholderPlacementCheck
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Via the normalizing init — otherwise decode would be a second
        // write path that a hand-edited store file could use to smuggle an
        // untrimmed or duplicate tag past the normalization above.
        let id = try container.decode(UUID.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let command = try container.decode(String.self, forKey: .command)
        // A store file written before tags (or variables, or the placement
        // waiver) existed carries no "tags", "variables" or
        // "skipsPlaceholderPlacementCheck" key at all — each of those
        // decodes as the field's own default, not as an error, so the
        // user's pre-existing snippets keep loading. `decodeIfPresent` is
        // what makes that true and it is not optional politeness:
        // `Codable` synthesizes no default for a MISSING key, it throws, so
        // a plain `decode` here would reject every file written before this
        // field. Any leftover "runsImmediately" key from that era is simply
        // not decoded: an unknown key does not trouble `JSONDecoder`, and
        // the flag it carried no longer means anything (see the type's doc
        // comment).
        //
        // The waiver's absent-key default is `false` — the check ON. That
        // direction is the whole point: a file that says nothing about the
        // check must not be read as switching it off.
        let tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        let variables =
            try container.decodeIfPresent([SnippetVariable].self, forKey: .variables) ?? []
        let skipsPlaceholderPlacementCheck =
            try container.decodeIfPresent(
                Bool.self, forKey: .skipsPlaceholderPlacementCheck) ?? false
        self = Self(
            id: id, name: name, command: command, tags: tags, variables: variables,
            skipsPlaceholderPlacementCheck: skipsPlaceholderPlacementCheck)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, command, tags, variables, skipsPlaceholderPlacementCheck
    }
}
