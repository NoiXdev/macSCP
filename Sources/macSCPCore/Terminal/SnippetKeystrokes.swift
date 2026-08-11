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
    /// TEMPORARY (Terminal-Snippets, Task 1): unused for now. The
    /// immediate-execution decision used to live on `Snippet.runsImmediately`
    /// and has been removed from the model (see `Snippet`'s doc comment) —
    /// the maintainer's call is that the decision belongs at the trigger,
    /// where the host is visible, not at snippet-creation time. Nothing yet
    /// re-attaches that decision here, so `bytes(for:)` below always inserts.
    /// A later task reintroduces it as an explicit parameter and starts
    /// appending this byte again.
    private static let terminator: UInt8 = 0x0D

    /// The keystrokes for `snippet`: its command as UTF-8.
    ///
    /// TEMPORARY (Terminal-Snippets, Task 1): never appends a terminator.
    /// This used to append `terminator` when the snippet's now-removed
    /// `runsImmediately` flag was set; with that flag gone from the model,
    /// every snippet inserts — the text lands in the input line and waits
    /// for the user to press Return. A later task gives this function back
    /// the ability to execute, driven by the trigger rather than the model.
    public static func bytes(for snippet: Snippet) -> [UInt8] {
        Array(snippet.command.utf8)
    }
}
