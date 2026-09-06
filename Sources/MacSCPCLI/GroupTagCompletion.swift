import ArgumentParser
import Foundation
import macSCPCore

/// Wires `GroupTagCompleter` (`macSCPCore` — decision logic belongs in
/// Core, this file stays wiring, same split as `SessionNameCompletion`)
/// onto the `--group` and `--tag` options wherever they are declared — the
/// value completion left open in `docs/BACKLOG.md`'s "CLI: completion,
/// help, host list" after session-name completion shipped (2026-09-02).
///
/// Each is declared TWICE, counted 2026-09-06: once on
/// `SessionsListCommand`, where the two are filters, and once on
/// `SessionFieldOptions`, where they are fields to write. Because the
/// second is an option group that both `sessions add` and `sessions edit`
/// take, the completion reaches three commands from those two
/// declarations — which is what the generated zsh script shows, and what
/// `CLISessionNameCompletionTests` reads off the binary rather than
/// restating here.
///
/// Opens the store at `SessionStore.defaultDirectory` and reads nothing
/// else: no secret, no keychain, no connection.
/// `CLISessionsCommandGuardTests` extends its forbidden-symbol scan to
/// this file for exactly that reason, even though the actual store-opening
/// work happens in `GroupTagCompleter`, which the guard scans too.
enum GroupTagCompletion {
    /// Wired onto every `--group` option's `completion:` parameter. See
    /// `SessionNameCompletion.kind`'s doc comment for why the
    /// three-parameter, synchronous overload of `CompletionKind.custom` is
    /// the right one — the same reasoning applies here.
    static let group: CompletionKind = .custom { _, _, prefix in
        GroupTagCompleter.completeGroups(prefix: prefix, storeDirectory: SessionStore.defaultDirectory)
    }

    /// Wired onto every `--tag` option's `completion:` parameter.
    static let tag: CompletionKind = .custom { _, _, prefix in
        GroupTagCompleter.completeTags(prefix: prefix, storeDirectory: SessionStore.defaultDirectory)
    }
}
