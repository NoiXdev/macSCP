import Foundation

/// Exit codes a script can branch on. 11 and 12 are deliberately different:
/// "new host" is a work item, "key changed" is an alarm. Collapsing them
/// throws away the distinction TOFU exists for.
enum CLIExitCode: Int32 {
    case success = 0
    case usage = 2
    case auth = 10
    case hostKeyUnknown = 11
    case hostKeyMismatch = 12
    case connection = 13
    case remote = 14
    case conflict = 15
}
