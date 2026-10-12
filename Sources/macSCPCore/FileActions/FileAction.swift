import Foundation

/// Whether one invocation covers the whole selection or each file gets its
/// own. `zip -r out.zip a b c` wants the first; `gzip a` wants the second,
/// because the tool takes one operand.
public enum FileActionPerSelection: String, Codable, Equatable, Sendable {
    case onceWithEveryPath
    case oncePerFile
}

/// A user-authored command template, run from the file context menu on the
/// current selection.
///
/// Deliberately NOT a `Snippet`, on the maintainer's ruling of 2026-10-12,
/// so that an export of one kind cannot carry the other. What it shares with
/// a snippet is the security machinery, not the type: both
/// `SnippetVariableSubstitution.resolve` and `.firstDeclarationProblem` take
/// a command and `[SnippetVariable]` rather than a `Snippet`, so they are
/// used here directly.
///
/// **There is no `skipsPlaceholderPlacementCheck`, and that is the point.**
/// A snippet's values are typed by the user, so waiving the position check
/// is a decision about their own input. An action's values come from the
/// server's directory listing, where the check is the protection rather than
/// a hurdle. The waiver is therefore not expressible, rather than available
/// and discouraged.
public struct FileAction: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let command: String
    public let variables: [SnippetVariable]
    /// The panes this action may run on. The type does not keep this
    /// non-empty — the initializer and the decoder both accept an empty set.
    /// `FileActionTemplate.firstProblem` is what refuses an action that
    /// declares no side, so an action that has not passed it may be empty.
    public let runsOn: Set<BrowserPaneSide>
    public let perSelection: FileActionPerSelection

    /// `perSelection` defaults to `.oncePerFile`: it is the commoner shape for
    /// a context-menu action (`gzip`, `chmod`, `wc -l` take one operand), and
    /// it is the form in which `{{PATH}}` — the first placeholder an author
    /// reaches for — has a single value. Under `.onceWithEveryPath`
    /// `FileActionTemplate` refuses `{{PATH}}`.
    public init(
        id: UUID = UUID(), name: String, command: String,
        variables: [SnippetVariable] = [],
        runsOn: Set<BrowserPaneSide> = [.remote],
        perSelection: FileActionPerSelection = .oncePerFile
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.variables = variables
        self.runsOn = runsOn
        self.perSelection = perSelection
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, command, variables, runsOn, perSelection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        variables = try container.decodeIfPresent([SnippetVariable].self, forKey: .variables) ?? []
        runsOn = Set(try container.decode([BrowserPaneSide].self, forKey: .runsOn))
        perSelection = try container.decode(FileActionPerSelection.self, forKey: .perSelection)
    }

    /// Writes `runsOn` in the declaration order of `BrowserPaneSide`, by
    /// walking `allCases` and keeping the members the set holds. A `Set`'s
    /// own iteration order is not stable across process launches, so
    /// encoding it directly would make the store file's bytes change on a
    /// save that changed nothing. `allCases` is the ordered source: a side
    /// added later is written in its declared position with no edit here.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(command, forKey: .command)
        try container.encode(variables, forKey: .variables)
        try container.encode(
            BrowserPaneSide.allCases.filter(runsOn.contains).map(\.rawValue), forKey: .runsOn)
        try container.encode(perSelection, forKey: .perSelection)
    }
}
