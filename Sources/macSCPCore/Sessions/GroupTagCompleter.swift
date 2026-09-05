import Foundation

/// The pure decision logic behind the CLI's `--group` and `--tag` shell
/// VALUE completion — the same completer family as `SessionNameCompleter`
/// (`docs/BACKLOG.md`, "CLI: completion, help, host list", left open after
/// session-name completion shipped 2026-09-02), split into its own type
/// because it completes an OPTION's value rather than a positional
/// `name:/path` target, and reads a different slice of the catalog
/// (`SessionCatalog.groupNames`/`tagNames`, not `rows(matching:)`).
///
/// Reads `SessionStore`/`SessionCatalog` only — no secret, no keychain, no
/// connection — the same constraint `SessionNameCompleter` carries and for
/// the same reason: a completion request runs silently in a subprocess a
/// shell spawns, so it answers `[]` rather than throwing, and neither
/// prints nor writes to standard error. `CLISessionsCommandGuardTests`
/// extends its forbidden-symbol scan to this file for exactly that reason.
public enum GroupTagCompleter {
    /// Every group name in `catalog` that starts with `prefix`
    /// (case-sensitive — same convention as
    /// `SessionNameCompleter.complete(prefix:in:)`), sorted, EXCLUDING any
    /// name containing whitespace (see `hasNoWhitespace` below for why).
    public static func completeGroups(prefix: String, in catalog: SessionCatalog) -> [String] {
        catalog.groupNames.filter { $0.hasPrefix(prefix) && Self.hasNoWhitespace($0) }
    }

    /// Every tag in use across any session in `catalog` that starts with
    /// `prefix`, sorted, EXCLUDING any tag containing whitespace (see
    /// `hasNoWhitespace` below for why).
    public static func completeTags(prefix: String, in catalog: SessionCatalog) -> [String] {
        catalog.tagNames.filter { $0.hasPrefix(prefix) && Self.hasNoWhitespace($0) }
    }

    /// Whether `value` carries no whitespace or newline character.
    ///
    /// `swift-argument-parser`'s generated BASH script hands a `.custom`
    /// completion's answers to `compgen -W`, which splits its word list on
    /// IFS (whitespace) with no quoting — a group like `"Work / Prod"` or
    /// a tag like `"needs review"` would therefore complete as two or more
    /// separate words instead of one, silently offering a value the user
    /// never typed and the CLI would then read as something else entirely.
    /// Zsh's own completion function does not have this problem (it
    /// receives the list as an array, not a word-split string), so this
    /// filter costs zsh nothing while keeping bash honest: a name WITH a
    /// space is simply absent from completion there, rather than present
    /// and wrong. `SessionNameCompleter.complete(prefix:in:)` carries the
    /// identical limit for session names and was not revisited here —
    /// see docs/BACKLOG.md, "CLI: completion, help, host list".
    private static func hasNoWhitespace(_ value: String) -> Bool {
        !value.contains(where: \.isWhitespace)
    }

    /// The store-opening convenience the CLI wrapper calls with the
    /// directory `SessionStore.defaultDirectory` resolves — the same
    /// injection point `SessionNameCompleter.complete(prefix:storeDirectory:)`
    /// uses. `[]` on any store failure (an unreadable file, a corrupt one)
    /// rather than throwing.
    public static func completeGroups(prefix: String, storeDirectory: URL) -> [String] {
        guard let catalog = try? catalog(at: storeDirectory) else { return [] }
        return completeGroups(prefix: prefix, in: catalog)
    }

    /// The store-opening convenience for tags — see
    /// `completeGroups(prefix:storeDirectory:)` above.
    public static func completeTags(prefix: String, storeDirectory: URL) -> [String] {
        guard let catalog = try? catalog(at: storeDirectory) else { return [] }
        return completeTags(prefix: prefix, in: catalog)
    }

    private static func catalog(at directory: URL) throws -> SessionCatalog {
        let store = SessionStore(directory: directory)
        return SessionCatalog(sessions: try store.all(), groups: try store.allGroups())
    }
}
