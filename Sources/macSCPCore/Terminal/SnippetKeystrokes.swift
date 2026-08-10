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
    /// referenced nowhere, and the Kitty-keyboard-protocol input path encodes
    /// Return as CR as well. The full evidence trail lives on the
    /// `theTerminatorIsCarriageReturn` test in `SnippetKeystrokesTests`,
    /// which is where to re-check it.
    ///
    /// This matters: LF can be inert in a remote line discipline, which would
    /// leave a `runsImmediately` snippet sitting unexecuted in the input line.
    private static let terminator: UInt8 = 0x0D

    /// The keystrokes for `snippet`: its command as UTF-8, followed by the
    /// Return byte only when the snippet runs immediately. Without that byte
    /// the text merely lands in the input line, which is what an inserting
    /// snippet is meant to do.
    ///
    /// Exactly one terminator can be appended here, because `Snippet` rejects
    /// a command containing `\n` or `\r` at construction.
    public static func bytes(for snippet: Snippet) -> [UInt8] {
        var bytes = Array(snippet.command.utf8)
        if snippet.runsImmediately {
            bytes.append(terminator)
        }
        return bytes
    }
}
