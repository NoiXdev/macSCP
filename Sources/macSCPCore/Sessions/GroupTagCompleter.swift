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
    /// `SessionNameCompleter.complete(prefix:in:)`), sorted.
    public static func completeGroups(prefix: String, in catalog: SessionCatalog) -> [String] {
        catalog.groupNames.filter { $0.hasPrefix(prefix) }
    }

    /// Every tag in use across any session in `catalog` that starts with
    /// `prefix`, sorted.
    public static func completeTags(prefix: String, in catalog: SessionCatalog) -> [String] {
        catalog.tagNames.filter { $0.hasPrefix(prefix) }
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
