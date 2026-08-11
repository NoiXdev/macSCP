import Foundation
import Testing

@testable import macSCPCore

@Suite("SnippetKeystrokes")
struct SnippetKeystrokesTests {
    /// Every snippet lands in the input line and waits: the user still
    /// presses Return. Nothing may be appended.
    ///
    /// TEMPORARY (Terminal-Snippets, Task 1): this used to hold only for an
    /// inserting snippet, distinguished from an executing one by the
    /// now-removed `Snippet.runsImmediately`. With that flag gone from the
    /// model, `bytes(for:)` never appends a terminator for ANY snippet —
    /// see its doc comment. Task 2 reintroduces the distinction as an
    /// explicit `execute` parameter and restores this test's original,
    /// narrower name and scope.
    @Test func aSnippetEndsWithoutATerminator() throws {
        let snippet = try #require(Snippet(name: "Disk", command: "df -h"))

        #expect(SnippetKeystrokes.bytes(for: snippet) == Array("df -h".utf8))
    }

    /// Dormant: `bytes(for:)` currently has no way to produce an executing
    /// snippet's bytes (see `aSnippetEndsWithoutATerminator`'s doc comment),
    /// so this cannot pass today. Left disabled rather than deleted because
    /// the assertion it makes — exactly one terminator, not two — is the one
    /// Task 2 must restore. See `theTerminatorIsCarriageReturn` for which
    /// byte that is and where the value was measured.
    @Test(.disabled("Dormant until Task 2 reintroduces bytes(for:execute:)."))
    func anExecutingSnippetAppendsExactlyOneTerminator() throws {
        let snippet = try #require(Snippet(name: "Disk", command: "df -h"))

        let bytes = SnippetKeystrokes.bytes(for: snippet)

        #expect(bytes.dropLast() == ArraySlice("df -h".utf8))
        #expect(bytes.count == Array("df -h".utf8).count + 1)
    }

    /// Non-ASCII survives as UTF-8 — paths and messages are not ASCII-only.
    @Test func nonASCIICommandsAreEncodedAsUTF8() throws {
        let snippet = try #require(Snippet(name: "Echo", command: "echo Grüße"))

        #expect(SnippetKeystrokes.bytes(for: snippet) == Array("echo Grüße".utf8))
    }

    /// The measured terminator: **CR (`0x0D`), never LF**.
    ///
    /// Evidence, read in the SwiftTerm revision this package pins (see the
    /// `SwiftTerm` entry in `Package.swift` / `Package.resolved`), following
    /// the path an ordinary Return keypress takes into
    /// `TerminalPanelViewModel.send(_:)`:
    ///
    /// 1. `SSHTerminalView.Coordinator.send(source:data:)` — this app's
    ///    `TerminalViewDelegate` — hands every byte the terminal view emits
    ///    for a keypress straight to `TerminalPanelViewModel.send(_:)`. That
    ///    is the same seam a snippet is submitted through, so a snippet must
    ///    supply the identical bytes.
    /// 2. In SwiftTerm's AppKit `TerminalView` (`MacTerminalView.swift`),
    ///    `keyDown(with:)` forwards an unmodified Return to
    ///    `interpretKeyEvents(_:)`; AppKit turns it into the
    ///    `insertNewline(_:)` command, and `doCommand(by:)` answers that
    ///    selector with `send(EscapeSequences.cmdRet)`.
    /// 3. `EscapeSequences.cmdRet` is `[13]` — a single CR, no LF.
    ///
    /// Cross-checks, because the wrong byte would make a `runsImmediately`
    /// snippet silently do nothing:
    ///
    /// - SwiftTerm also defines `EscapeSequences.cmdNewLine` (`[10]`, LF),
    ///   and no code in the library references it. LF is a byte the library
    ///   never sends for a keypress, in any mode.
    /// - When the remote program negotiates the Kitty keyboard protocol
    ///   (`Terminal.keyboardEnhancementFlags` non-empty), Return goes through
    ///   `sendKittyFunctionalKey(.enter, ...)` into
    ///   `KittyKeyboardEncoder.encode(_:)` instead. That encoder yields a bare
    ///   CR for an ordinary Return only on its legacy branch: with
    ///   report-all-keys OFF, `.enter` carries no associated text, so it
    ///   reaches `encodeFunctionalKey`, where an unmodified press has no
    ///   modifier field to disambiguate and falls to
    ///   `legacySpecialKeySequence` — `[ControlCodes.CR]`, and
    ///   `ControlCodes.CR` is `0x0d`.
    ///
    /// **The terminator is therefore NOT mode-independent, and this test does
    /// not claim it is.** With report-all-keys ON, `encode(_:)` routes
    /// `.enter` to `encodeCsiU(overrideKeyCode: 13, ...)` — `ESC [ 13 u`, not
    /// a bare `0x0D`. (The same CSI-u form also appears with report-all-keys
    /// off when disambiguation is on AND the press carries modifiers, which an
    /// ordinary Return does not.) So a program in that mode would see a
    /// snippet's CR differ from a real keypress.
    ///
    /// That is accepted scope, not an oversight: a snippet is a shell command
    /// line aimed at a shell prompt (see `Snippet`), where the legacy encoding
    /// is what is in force. A full-screen program driving the Kitty
    /// report-all-keys mode is not what snippets target. If that ever changes,
    /// the terminator has to become mode-aware, and this comment is the
    /// warning.
    ///
    /// Dormant (Terminal-Snippets, Task 1): `bytes(for:)` cannot currently
    /// produce a terminator for any snippet (see `aSnippetEndsWithoutATerminator`),
    /// so this assertion cannot pass today. Disabled rather than deleted —
    /// the measurement above is the evidence trail `SnippetKeystrokes.terminator`'s
    /// doc comment still points to, and Task 2 is expected to re-enable this
    /// exact test once `bytes(for:execute:)` exists.
    @Test(.disabled("Dormant until Task 2 reintroduces bytes(for:execute:)."))
    func theTerminatorIsCarriageReturn() throws {
        let snippet = try #require(Snippet(name: "Disk", command: "df -h"))

        #expect(SnippetKeystrokes.bytes(for: snippet).last == 0x0D)
    }
}
