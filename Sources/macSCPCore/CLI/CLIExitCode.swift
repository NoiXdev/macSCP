import Foundation

/// Exit codes a script can branch on. 11 and 12 are deliberately different:
/// "new host" is a work item, "key changed" is an alarm. Collapsing them
/// throws away the distinction TOFU exists for.
///
/// Lives in Core, not the CLI target (M20 Task 10): the CLI has no test
/// target, and `CLIErrorMapping` — the decision logic that assigns one of
/// these codes to a thrown error — needs to be testable without a process
/// exit.
///
/// What each case means:
/// - `success`: the command did what it was asked; for `diagnose`
///   specifically, every step came back `ok`, `skipped`, or `unavailable` —
///   see `diagnosis` below for the one case that is not success.
/// - `usage`: the arguments themselves were wrong (bad flag, missing
///   argument) — never reached the network.
/// - `auth`: the server rejected the credential offered.
/// - `hostKeyUnknown`: TOFU saw a host it has no pinned key for.
/// - `hostKeyMismatch`: TOFU saw a host key that does not match the pinned
///   one — a hard stop, never auto-accepted.
/// - `connection`: the transport failed before authentication — DNS, TCP,
///   TLS. Also the code for a store on this machine that could not be used:
///   an unreadable forwarding list (`TunnelStoreError.unreadable`, mapped
///   here on purpose), an unreadable managed key store that cost a key its
///   passphrase (`SSHKeyError.managedKeyStoreUnreadable`, mapped here on
///   purpose) and, through `CLIErrorMapping`'s fallback arm, an
///   unreadable session store or a store write the file system refused. No
///   separate code exists for that case, and none was added: renumbering or
///   inserting one would change what an existing script branches on.
/// - `remote`: the server accepted the connection but refused the operation
///   asked of it (a path, a permission, a remote-side error).
/// - `conflict`: a local precondition the command itself enforces was not
///   met (e.g. a name already in use).
/// - `diagnosis`: `macscp-cli diagnose` returned its report, and at least
///   one step's outcome was `failed` or `timedOut` — a `skipped` or
///   `unavailable` step alone does not set this, only a step that actually
///   found something wrong with the server or the path to it
///   (`DiagnoseRendering.exitCode(for:)`). The report may be a cancelled
///   one: a `--scope throughput` run stopped by Ctrl-C exits by the rows it
///   kept, so 0 when they are ok, and 16 when its kept row says the test
///   file may remain. Also set with NO failed step at all: a throughput run
///   ABANDONED by a second Ctrl-C, before its removal confirmed, exits 16
///   because a file of this app's may be on the server
///   (`DiagnoseForegroundRun.exitCode(for:)`).
public enum CLIExitCode: Int32, Equatable, Sendable {
    case success = 0
    case usage = 2
    case auth = 10
    case hostKeyUnknown = 11
    case hostKeyMismatch = 12
    case connection = 13
    case remote = 14
    case conflict = 15
    case diagnosis = 16
}
