import Foundation

/// One value a snippet asks for before it runs (snippet editor, part 3).
///
/// Declaring the variables rather than scraping them out of the command text
/// is the whole point: a declaration is visible, ordered and can carry a
/// prompt, a default and a list of allowed values. The command text alone
/// could carry none of that.
public struct SnippetVariable: Codable, Equatable, Sendable {
    /// What the user is asked for.
    public enum Kind: Codable, Equatable, Sendable {
        case freeText
        /// The allowed values, offered as a list. Prevents a typo in a value
        /// like `prod` — the kind of mistake that is expensive on the far
        /// side of a connection.
        case selection([String])
    }

    /// How the value reaches the command.
    public enum Placement: String, Codable, Equatable, Sendable {
        /// `{{NAME}}` in the command text is replaced by the quoted value.
        case placeholder
        /// `NAME='value'` is prepended, and the command uses `$NAME` — or
        /// does not mention it at all and lets a called script read it.
        case environment
    }

    public let name: String
    public let prompt: String
    public let kind: Kind
    public let placement: Placement
    public let defaultValue: String
    /// Whether the last value is kept for the next run. **Off by default,
    /// and deliberately so:** a remembered value is written to a plain JSON
    /// file, so the choice to store one is made when the declaration is
    /// created — before any value exists — rather than after someone has
    /// typed something they did not mean to persist.
    public let remembersLastValue: Bool

    public init(
        name: String, prompt: String, kind: Kind, placement: Placement,
        defaultValue: String, remembersLastValue: Bool
    ) {
        self.name = name
        self.prompt = prompt
        self.kind = kind
        self.placement = placement
        self.defaultValue = defaultValue
        self.remembersLastValue = remembersLastValue
    }

    /// Whether `name` is a POSIX shell identifier: a letter or underscore,
    /// then letters, digits or underscores.
    ///
    /// Required for `.environment`, where the name becomes the left side of
    /// a shell assignment — a name carrying a space or a `;` would not be an
    /// assignment at all but a second command. Applied to `.placeholder` too:
    /// the substitution itself would tolerate anything, but two rules for one
    /// field is a defect source that buys nothing.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        guard first.isLetter && first.isASCII || first == "_" else { return false }
        return name.allSatisfy { ($0.isLetter || $0.isNumber) && $0.isASCII || $0 == "_" }
    }
}
