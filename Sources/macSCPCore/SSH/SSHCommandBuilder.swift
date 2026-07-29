import Foundation

/// Builds the `ssh` command line an external terminal app will run (M11d).
///
/// This type is pure: it never touches the filesystem, spawns a process, or
/// reads the environment. That is what makes it exhaustively testable and
/// what keeps the one security-critical property — no secret ever leaves
/// the app, and every argument is quoted so a malicious host/username/path
/// cannot break out of its argument position — provable in isolation from
/// the process-launching code in the App layer (M11d Task 2).
public enum SSHCommandBuilder {
    /// The `ssh` argument vector for `config`, in the fixed order external
    /// tooling (and the round-trip test) can rely on: `-p <port>` (only when
    /// non-default), `-l <username>`, `-i <keyPath>` (only for
    /// `.privateKey`), `-J <jumpUser>@<jumpHost>[:<jumpPort>]` (only when a
    /// jump is configured), then a literal `--` end-of-options marker, then
    /// the target host last.
    ///
    /// The `--` matters even though every argument is shell-quoted
    /// (`shellCommand(for:)`/`scriptContents(for:)`): quoting only stops the
    /// *shell* from splitting the host into extra words, it does nothing to
    /// stop *ssh itself* from parsing a host that starts with `-` as one of
    /// its own options (e.g. a host of `-V` makes ssh print its version and
    /// exit 0 instead of connecting, silently changing what the generated
    /// command does). `--` tells ssh's own argument parser that everything
    /// after it is positional, so the host is always treated as a literal
    /// hostname, never as an option.
    ///
    /// `.agent` and `.password` never contribute an argument of their own:
    /// with `.password`, `ssh` prompts interactively — no secret is ever
    /// passed on the command line or written anywhere by this builder.
    /// With `.privateKey`, only the key *path* is passed via `-i`; the
    /// passphrase (if any) is not representable in the ssh argument vector
    /// and is never read by this type.
    public static func arguments(for config: SSHConnectionConfig) -> [String] {
        var args: [String] = []

        if config.port != 22 {
            args.append("-p")
            args.append(String(config.port))
        }

        args.append("-l")
        args.append(config.username)

        if case .privateKey(let keyPath, _) = config.auth {
            args.append("-i")
            args.append(keyPath)
        }

        if let jump = config.jump {
            args.append("-J")
            args.append(jumpTarget(for: jump))
        }

        args.append("--")
        args.append(config.host)
        return args
    }

    /// The full `ssh …` shell line, with every argument individually
    /// single-quoted (embedded `'` escaped as `'\''`). Quoting is the
    /// security boundary here: a host/username/key path containing shell
    /// metacharacters (`;`, `` ` ``, `$(...)`, whitespace, a quote) can never
    /// take effect, because it is always a value inside `'...'`, never
    /// unquoted shell syntax.
    public static func shellCommand(for config: SSHConnectionConfig) -> String {
        let quotedArguments = arguments(for: config).map(posixSingleQuote)
        return (["ssh"] + quotedArguments).joined(separator: " ")
    }

    /// The full disposable-script text: a `#!/bin/sh` shebang, a line that
    /// removes the script file itself before anything else runs, then
    /// `exec` into the quoted ssh command exactly once. Task 2 writes this
    /// text to a 0700 temp file and hands it to the external terminal app —
    /// this function only produces the text; it never touches a file.
    public static func scriptContents(for config: SSHConnectionConfig) -> String {
        """
        #!/bin/sh
        rm -f -- "$0"
        exec \(shellCommand(for: config))

        """
    }

    private static func jumpTarget(for jump: SSHConnectionConfig.Jump) -> String {
        if jump.port != 22 {
            return "\(jump.username)@\(jump.host):\(jump.port)"
        }
        return "\(jump.username)@\(jump.host)"
    }

    /// Wraps `value` in single quotes for a POSIX shell, escaping any
    /// embedded `'` as `'\''` (close quote, escaped literal quote, reopen
    /// quote) — the standard technique for making an arbitrary string safe
    /// as a single shell word.
    private static func posixSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
