import ArgumentParser
import Foundation
import macSCPCore

/// Wires `GroupTagCompleter` (`macSCPCore` — decision logic belongs in
/// Core, this file stays wiring, same split as `SessionNameCompletion`)
/// onto `SessionsCommand`'s `--group` and `--tag` options — the value
/// completion left open in `docs/BACKLOG.md`'s "CLI: completion, help,
/// host list" after session-name completion shipped (2026-09-02).
///
/// Opens the store at `SessionStore.defaultDirectory` and reads nothing
/// else: no secret, no keychain, no connection.
/// `CLISessionsCommandGuardTests` extends its forbidden-symbol scan to
/// this file for exactly that reason, even though the actual store-opening
/// work happens in `GroupTagCompleter`, which the guard scans too.
enum GroupTagCompletion {
    /// Wired onto `SessionsCommand.group`'s `completion:` parameter. See
    /// `SessionNameCompletion.kind`'s doc comment for why the
    /// three-parameter, synchronous overload of `CompletionKind.custom` is
    /// the right one — the same reasoning applies here.
    static let group: CompletionKind = .custom { _, _, prefix in
        GroupTagCompleter.completeGroups(prefix: prefix, storeDirectory: SessionStore.defaultDirectory)
    }

    /// Wired onto `SessionsCommand.tag`'s `completion:` parameter.
    static let tag: CompletionKind = .custom { _, _, prefix in
        GroupTagCompleter.completeTags(prefix: prefix, storeDirectory: SessionStore.defaultDirectory)
    }
}
