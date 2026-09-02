import ArgumentParser
import Foundation
import macSCPCore

/// Wires `SessionNameCompleter` (`macSCPCore` — decision logic belongs in
/// Core, this file stays wiring, M20 CLI design) onto a target
/// `@Argument`'s `completion:` parameter, completing the `name:` half of a
/// `name:/path` target from the saved session store. Wired onto every
/// command that parses one through `SessionReference.parse` (`ls`, `get`'s
/// SOURCE, `put`'s DESTINATION, `rm`, `mkdir`); `put`'s SOURCE stays on the
/// default file completion, since it names a local path, not a session.
///
/// Opens the store at `SessionStore.defaultDirectory` — the same injection
/// point `SessionsCommand` uses — and reads nothing else: no secret, no
/// keychain, no connection. `CLISessionsCommandGuardTests` extends its
/// forbidden-symbol scan to this file for exactly that reason, even though
/// this file itself now does none of the store-opening work directly —
/// `SessionNameCompleter.complete(prefix:storeDirectory:)` does, and the
/// guard scans that file too.
enum SessionNameCompletion {
    /// Wired onto a target `@Argument`'s `completion:` parameter.
    ///
    /// The three-parameter, synchronous overload of `CompletionKind.custom`
    /// (`swift-argument-parser` 1.8.2, `CompletionKind.swift` line ~174:
    /// `custom(_ completion: @Sendable ([String], Int, String) -> [String])
    /// -> CompletionKind`) is the one that hands the closure the PREFIX —
    /// its third parameter, the only piece `SessionNameCompleter.complete`
    /// needs. Its two siblings are wrong for different reasons: the async
    /// overload (line ~185) buys nothing since the completer never
    /// suspends — it is a synchronous local-file read — and the deprecated
    /// one-parameter overload (line ~202) receives no prefix at all, so it
    /// could not filter by what the user has already typed.
    static let kind: CompletionKind = .custom { _, _, prefix in
        SessionNameCompleter.complete(prefix: prefix, storeDirectory: SessionStore.defaultDirectory)
    }
}
