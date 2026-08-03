import Foundation

/// Exit codes a script can branch on. 11 and 12 are deliberately different:
/// "new host" is a work item, "key changed" is an alarm. Collapsing them
/// throws away the distinction TOFU exists for.
///
/// Lives in Core, not the CLI target (M20 Task 10): the CLI has no test
/// target, and `CLIErrorMapping` — the decision logic that assigns one of
/// these codes to a thrown error — needs to be testable without a process
/// exit.
public enum CLIExitCode: Int32, Equatable, Sendable {
    case success = 0
    case usage = 2
    case auth = 10
    case hostKeyUnknown = 11
    case hostKeyMismatch = 12
    case connection = 13
    case remote = 14
    case conflict = 15
}
