import Foundation

/// The one place the shell-completion setup lines are spelled.
///
/// `macscp-cli --generate-completion-script <shell>` is
/// swift-argument-parser's built-in generator. The line this type produces
/// loads that output at every shell start rather than writing a generated
/// script into a completions directory, so an updated CLI never leaves a
/// stale script behind — the maintainer's decision, recorded in
/// `docs/superpowers/specs/2026-09-08-shell-completion-settings-design.md`.
///
/// Pure string work, no process and no file system: the Settings section
/// SHOWS the line for the user to paste, and macSCP never edits a shell
/// configuration itself (same rule as `CLIToolInstaller`'s system-wide
/// command, which is handed over as text for the same reason).
///
/// Core stays UI-free; the App layer supplies the tool token and renders
/// the surrounding sentences from its own catalogue.
public enum ShellCompletionRecipe {
    /// The shells `macscp-cli` can generate a completion script for, and
    /// therefore the shells the Settings picker offers: this enum is the
    /// list, and `CLICompletionScriptTests` runs the real binary for every
    /// case, so a case added here without CLI support goes red.
    ///
    /// The raw values are the words the CLI takes on the command line AND
    /// the labels the picker shows — a shell's name is not translated.
    public enum Shell: String, CaseIterable, Sendable {
        case zsh
        case bash
        case fish
    }

    /// The flag, spelled once. Every line below interpolates it, so there
    /// is no second copy to drift.
    private static let generateFlag = "--generate-completion-script"

    /// The line that loads `tool`'s completion for `shell` at shell start.
    ///
    /// `tool` is substituted VERBATIM: the caller decides whether it is the
    /// bare `macscp-cli` (the shortcut is installed and on `PATH`) or a
    /// path already run through `quotedForShell(_:)`. Quoting here as well
    /// would produce a doubly quoted token no shell can resolve.
    ///
    /// zsh and bash share the process-substitution form; fish has no
    /// `<(…)` and pipes into its own `source` builtin instead.
    public static func line(for shell: Shell, tool: String) -> String {
        switch shell {
        case .zsh, .bash:
            return "source <(\(tool) \(generateFlag) \(shell.rawValue))"
        case .fish:
            return "\(tool) \(generateFlag) \(shell.rawValue) | source"
        }
    }

    /// The shell named by a login-shell PATH — `$SHELL`'s value, which is
    /// where the shell's binary lives, not what it is called.
    ///
    /// Anything unrecognised, and a missing value, fall back to zsh: it is
    /// macOS's default login shell, so a wrong guess is at worst the same
    /// line the picker would have opened on anyway, and the user can switch
    /// the picker in one click.
    public static func shell(fromLoginShellPath path: String?) -> Shell {
        guard let path, !path.isEmpty else { return .zsh }
        return Shell(rawValue: (path as NSString).lastPathComponent) ?? .zsh
    }

    /// `path` as a single shell word, through `PosixQuoting.singleQuoted`:
    /// wrapped in single quotes, with any single quote inside written as
    /// `'\''` — close the quoted run, an escaped quote, reopen.
    ///
    /// Not a second implementation, and deliberately not the one-line
    /// `replacingOccurrences` form: that matches on grapheme clusters, so
    /// an apostrophe carrying a combining mark survives unescaped and meets
    /// the closing quote as live syntax. `PosixQuoting` walks
    /// `Unicode.Scalar`s and cannot have that bug — see its own doc
    /// comment, and `SnippetCommandSurveyTests`, which bans the one-liner
    /// across Core.
    ///
    /// Single quotes are also the one form all three shells read alike:
    /// inside them nothing expands, and the `'\''` idiom needs nothing of
    /// the shell but concatenation. fish's `\'` escape INSIDE single quotes
    /// would be wrong in zsh and bash, and the section builds every shell's
    /// line from this one function.
    ///
    /// A thin wrapper on purpose: it names, in the CLI's own vocabulary,
    /// the one quoting rule the completion line needs, so a caller cannot
    /// reach for a different quoter. Outside tests it has ONE caller,
    /// counted on 2026-09-10: the Settings section's `completionTool`.
    public static func quotedForShell(_ path: String) -> String {
        PosixQuoting.singleQuoted(path)
    }
}
