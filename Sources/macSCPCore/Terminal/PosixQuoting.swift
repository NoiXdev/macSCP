import Foundation

/// Turning an arbitrary string into exactly one POSIX shell word.
///
/// Extracted from `SSHCommandBuilder`, which had this as a private helper,
/// so the snippet variable substitution can use the same rule instead of a
/// second implementation. Two quoting routines that drift apart is the
/// failure this extraction exists to prevent — and quoting is where a value
/// stops being data and becomes code if it is wrong.
public enum PosixQuoting {
    /// `value` wrapped in single quotes, with any embedded `'` written as
    /// `'\''` — close the quote, an escaped literal quote, reopen.
    ///
    /// Single quotes because a POSIX shell expands nothing inside them:
    /// `$`, backtick and backslash are all literal. `'` is the sole
    /// exception, which is what the escape handles.
    public static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
