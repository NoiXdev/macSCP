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
    ///
    /// Written as a walk over `Unicode.Scalar`s — the unit `ShellScalar`
    /// documents — and NOT as `replacingOccurrences(of: "'", with: "'\\''")`.
    /// That call matches on extended grapheme clusters and canonical
    /// equivalence, so an apostrophe carrying a combining mark is not an
    /// occurrence of `'` to it, is left unescaped, and meets the closing
    /// quote of this very wrapper as live shell syntax. `echo {{X}}` plus
    /// such a value executed arbitrary commands in real `bash`. A scalar
    /// walk cannot have that bug, and it cannot be reverted to the one-line
    /// form without the reverter having to delete this paragraph.
    public static func singleQuoted(_ value: String) -> String {
        var quoted = "'"
        for scalar in value.unicodeScalars {
            if scalar == "'" {
                quoted += "'\\''"
            } else {
                quoted.unicodeScalars.append(scalar)
            }
        }
        quoted.unicodeScalars.append("'")
        return quoted
    }
}
