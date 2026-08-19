import Foundation

/// Turns a `Snippet` into the exact bytes to hand to
/// `TerminalPanelViewModel.send(_:)` — the same seam the terminal view's
/// keyboard delegate writes to, so a snippet reaches the shell as if it had
/// been typed.
public enum SnippetKeystrokes {
    /// The byte the Return key sends in this app's terminal: CR (`0x0D`),
    /// not LF.
    ///
    /// Measured, not assumed. In the SwiftTerm revision this package pins,
    /// the AppKit `TerminalView` answers AppKit's `insertNewline(_:)` command
    /// — what an unmodified Return keypress becomes — with
    /// `send(EscapeSequences.cmdRet)`, and `cmdRet` is `[13]`. Those bytes
    /// arrive at `TerminalPanelViewModel.send(_:)` through
    /// `SSHTerminalView.Coordinator.send(source:data:)` unchanged. The
    /// library's `EscapeSequences.cmdNewLine` (`[10]`, LF) exists but is
    /// referenced nowhere in it.
    ///
    /// Scope: this is the legacy input encoding — the one in force at a shell
    /// prompt, which is what a snippet targets. It is NOT mode-independent. A
    /// program that negotiates the Kitty keyboard protocol's report-all-keys
    /// mode makes a real Return keypress encode as `ESC [ 13 u` instead, so in
    /// that mode a snippet's bare CR is not byte-identical to a keypress.
    /// `SnippetKeystrokesTests.theTerminatorIsCarriageReturn` carries the full
    /// evidence trail for both encodings and is where to re-check them.
    ///
    /// Why the byte matters at all: LF can be inert in a POSIX line
    /// discipline, which would leave an executed snippet sitting unexecuted
    /// in the input line. That is general background — the reason the
    /// terminator was measured rather than guessed — not a claim measured
    /// against this app's remote shells.
    ///
    /// The immediate-execution decision used to live on the now-removed
    /// `Snippet.runsImmediately` (see `Snippet`'s doc comment) — the
    /// maintainer's call is that the decision belongs at the trigger, where
    /// the host is visible, not at snippet-creation time. `bytes(for:execute:)`
    /// below carries that decision as an explicit parameter and appends this
    /// byte only when the caller asks for it.
    static let terminator: UInt8 = 0x0D

    /// The keystrokes for a single command line: `line` as UTF-8, followed
    /// by `terminator` only when `execute` is `true`.
    ///
    /// `bytes(for:execute:)` below is this function applied to a snippet's
    /// whole command, which is the right thing only while that command is a
    /// single line. `SnippetSendPlanner` calls this one per line for the
    /// multi-line fallback.
    public static func bytes(forLine line: String, execute: Bool) -> [UInt8] {
        var bytes = Array(line.utf8)
        if execute {
            bytes.append(terminator)
        }
        return bytes
    }

    /// The keystrokes for `snippet`: its command as UTF-8, followed by
    /// `terminator` only when `execute` is `true`.
    ///
    /// Inserting (`execute: false`) never appends a terminator, whatever else
    /// changes here — the text lands in the input line exactly as if typed,
    /// and the user still presses Return. That guarantee is asserted once, at
    /// this seam, rather than at each surface that calls it.
    public static func bytes(for snippet: Snippet, execute: Bool) -> [UInt8] {
        bytes(forLine: snippet.command, execute: execute)
    }
}
