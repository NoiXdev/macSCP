import Foundation

/// The words `macscp-cli sessions rm` uses for the forwardings that go with
/// a session: in its question, and in its `--verbose` summary.
///
/// Lives in Core for the reason `CLIErrorMapping` gives: the command-line
/// target has no test target, and the question is asked only on a terminal,
/// which no subprocess test has — so what it says has to be callable here.
/// The command's own file keeps the `[y/N]` and the confirmation call.
///
/// **A count that could not be read is not zero** (next build of
/// 2026-09-17, Task 2). `nil` is what the caller passes when `tunnels.json`
/// could not be decoded; the lenient reader would have answered that file
/// with no profiles, and the question and the summary said "0 forwardings"
/// about a file that still held them.
public enum SessionRemovalWording {
    /// The question, without the `[y/N]` the command appends.
    ///
    /// With no count it asks about the session alone and says the
    /// forwardings stay: over an unreadable file `StoreEditing
    /// .deleteSession(_:)` warns past the refused `deleteAll` and leaves
    /// them in it, so "delete … and its forwardings" would promise a
    /// deletion that does not happen.
    public static func question(sessionName: String, forwardings count: Int?) -> String {
        guard let count else {
            return "Delete session \(sessionName)? Its forwardings could not be read "
                + "and will be left in the forwarding list."
        }
        return "Delete session \(sessionName) and \(count) forwardings?"
    }

    /// The `--verbose` line written after the session was removed.
    ///
    /// With no count it does not say the forwardings were deleted: over an
    /// unreadable file they were not, and the warning printed before this
    /// line says they are still in it.
    public static func summary(sessionName: String, forwardings count: Int?) -> String {
        guard let count else {
            return "Deleted \(sessionName); the number of its forwardings is unknown "
                + "(\(unreadable)); keychain entry left in place."
        }
        return "Deleted \(sessionName) and \(count) forwardings; keychain entry left in place."
    }

    private static let unreadable = "the forwarding list could not be read"
}
