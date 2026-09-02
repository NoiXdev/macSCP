import Foundation

/// The pure decision logic behind the CLI's `name:` shell completion —
/// filtering and formatting session names from a `SessionCatalog` — plus
/// the one convenience that opens a `SessionStore` for a caller that only
/// has a directory.
///
/// Lives in Core, not `MacSCPCLI`, for the same reason `SessionCatalog`
/// itself does (M20 CLI design, "Decision logic moves to Core, CLI stays
/// wiring"; moved here in the fix round after `ae0078c`'s review, Important
/// finding I-2): `complete(prefix:in:)` depends on nothing CLI-specific —
/// no `ArgumentParser`, no shell, no subprocess — and every other
/// Core-layer test in this suite exercises logic like this directly,
/// without a subprocess or an extra test-target dependency. The CLI wrapper
/// (`Sources/MacSCPCLI/SessionNameCompletion.swift`) is left with only the
/// `CompletionKind` plumbing.
///
/// Reads `SessionStore`/`SessionCatalog` only — no secret, no keychain, no
/// connection — and answers `[]` rather than throwing, so a completion
/// request run in a subprocess by a generated shell script never has
/// anything to report but a list, no matter what fails underneath.
/// `CLISessionsCommandGuardTests` extends its forbidden-symbol scan to this
/// file for exactly that reason.
public enum SessionNameCompleter {
    /// Every name in `catalog` whose `"name:"` form starts with `prefix`,
    /// sorted, each carrying its trailing colon.
    ///
    /// `[]` once `prefix` already contains a `:` — the name has already
    /// been typed in full and the shell has moved on to the path, which
    /// this completer has no way to help with (no remote path completion;
    /// see the plan's "What is explicitly not in this plan"). The boundary
    /// is the COLON, deliberately not `/`: a session name is free text and
    /// may itself contain a `/` (this project's own fixtures use
    /// `"Prod / DB"`), so a prefix that has reached an embedded slash but
    /// not yet the colon must still be free to match by `hasPrefix` — an
    /// earlier version of this function rejected on `/` outright and,
    /// unnoticed, made exactly that fixture's own name uncompletable past
    /// its slash (`ae0078c`'s review, Important finding I-1).
    public static func complete(prefix: String, in catalog: SessionCatalog) -> [String] {
        guard !prefix.contains(":") else { return [] }
        let names = catalog.rows(matching: .init()).map { "\($0.name):" }
        return names.filter { $0.hasPrefix(prefix) }.sorted()
    }

    /// The store-opening convenience the CLI wrapper calls with the
    /// directory `SessionStore.defaultDirectory` resolves — the same
    /// injection point `SessionsCommand` uses. `[]` on any store failure
    /// (an unreadable file, a corrupt one) rather than throwing — silent,
    /// per this file's own doc comment above.
    public static func complete(prefix: String, storeDirectory: URL) -> [String] {
        do {
            let store = SessionStore(directory: storeDirectory)
            let catalog = SessionCatalog(sessions: try store.all(), groups: try store.allGroups())
            return complete(prefix: prefix, in: catalog)
        } catch {
            return []
        }
    }
}
