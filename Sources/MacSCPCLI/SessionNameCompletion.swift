import ArgumentParser
import Foundation
import macSCPCore

/// Completes the `name:` half of a `name:/path` target from the saved
/// session store — nothing else. Wired onto the target `@Argument` of every
/// command that parses one through `SessionReference.parse` (`ls`, `get`'s
/// SOURCE, `put`'s DESTINATION, `rm`, `mkdir`); `put`'s SOURCE stays on the
/// default file completion, since it names a local path, not a session.
///
/// Opens the store exactly the way `SessionsCommand` does
/// (`SessionStore(directory: SessionStore.defaultDirectory)` +
/// `SessionCatalog(...)`) and reads nothing else — no secret, no keychain,
/// no connection. `CLISessionsCommandGuardTests` extends its
/// forbidden-symbol scan to this file for exactly that reason.
///
/// Runs in a subprocess the generated shell script spawns
/// (`macscp-cli ---completion ...`), so it stays SILENT — it writes to
/// neither standard output nor standard error of its own accord, and never
/// prompts — and answers an empty list on any failure instead of throwing,
/// rather than leaving a stray line in the user's terminal or hanging a
/// completion request. (Deliberately described here without quoting the
/// forbidden calls themselves: `CLISessionsCommandGuardTests` scans this
/// file's source text, comments included, and a comment that quotes what it
/// forbids would trip the very check it is explaining — CLAUDE.md,
/// "Source-scanning guards read comments too".)
enum SessionNameCompletion {
    /// Wired onto a target `@Argument`'s `completion:` parameter.
    ///
    /// The three-parameter, synchronous overload of `CompletionKind.custom`
    /// (`swift-argument-parser` 1.8.2, `CompletionKind.swift` line ~174:
    /// `custom(_ completion: @Sendable ([String], Int, String) -> [String])
    /// -> CompletionKind`) is the one that hands the closure the PREFIX —
    /// its third parameter, the only piece `complete(prefix:)` needs. Its
    /// two siblings are wrong for different reasons: the async overload
    /// (line ~185) buys nothing since `complete(prefix:)` never suspends —
    /// it is a synchronous local-file read — and the deprecated
    /// one-parameter overload (line ~202) receives no prefix at all, so it
    /// could not filter by what the user has already typed.
    static let kind: CompletionKind = .custom { _, _, prefix in
        complete(prefix: prefix)
    }

    /// Every saved session name whose `"name:"` form starts with `prefix`,
    /// sorted, each carrying its trailing colon.
    ///
    /// `[]` once `prefix` already contains a `/` — the path has started, and
    /// this completer has no way to list a remote directory without a
    /// connection (no remote path completion; see the plan's "What is
    /// explicitly not in this plan").
    ///
    /// `[]` on any store failure too (an unreadable file, a corrupt one) —
    /// silent, per this file's own doc comment above: a completion request
    /// that fails should look like "no matches", never a stack trace on the
    /// user's terminal.
    static func complete(prefix: String) -> [String] {
        guard !prefix.contains("/") else { return [] }
        do {
            let store = SessionStore(directory: SessionStore.defaultDirectory)
            let catalog = SessionCatalog(sessions: try store.all(), groups: try store.allGroups())
            let names = catalog.rows(matching: .init()).map { "\($0.name):" }
            return names.filter { $0.hasPrefix(prefix) }.sorted()
        } catch {
            return []
        }
    }
}
