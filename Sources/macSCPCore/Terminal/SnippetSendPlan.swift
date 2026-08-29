import Foundation

/// What should go to the shell for one snippet trigger — or why nothing
/// should.
///
/// A plain `[UInt8]` cannot express the one case that matters: inserting a
/// multi-line command into a shell that has not enabled bracketed paste
/// would EXECUTE its leading lines, because the embedded line breaks are
/// what a Return keypress sends. The menu entry says "insert"; bytes that
/// run things are not an insert. So the refusal is part of the result type
/// and the caller has to look at it.
///
/// `Sendable` because `SnippetDryRun` carries one and is itself a value the
/// App layer moves around. Both payloads are value types; the conformance
/// adds no case and changes no verdict.
public enum SnippetSendPlan: Equatable, Sendable {
    case send([UInt8])
    /// Inserting is impossible here without also executing — the caller
    /// explains and offers to execute instead.
    case refusedMultilineInsert
}

/// Decides what a snippet trigger sends.
///
/// Pure: the caller supplies whether the remote has bracketed paste on,
/// which the App layer reads from SwiftTerm's `Terminal`. Core neither
/// imports SwiftTerm nor needs a terminal to be tested.
public enum SnippetSendPlanner {
    /// `ESC [ 2 0 0 ~` — the sequence a terminal emits before pasted text
    /// while the remote has mode 2004 on. Byte-for-byte SwiftTerm's
    /// `EscapeSequences.bracketedPasteStart`; spelled out here because Core
    /// does not import SwiftTerm, and pinned by this file's tests.
    private static let bracketedPasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    /// `ESC [ 2 0 1 ~` — the matching closing sequence
    /// (`EscapeSequences.bracketedPasteEnd`).
    private static let bracketedPasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]

    /// The bytes for `command`, or a refusal.
    ///
    /// A single-line command takes the path it always took and is **never**
    /// bracketed: that keeps the overwhelmingly common case byte-identical
    /// to what shipped before multi-line snippets existed.
    ///
    /// Between the brackets goes the command's raw UTF-8, unchanged — that
    /// is what SwiftTerm's own ⌘V does with the clipboard's string, with no
    /// line-ending translation. The line-by-line fallback does normalize,
    /// because there each line ends with the byte a Return keypress sends.
    public static func plan(
        command: String, execute: Bool, bracketedPaste: Bool
    ) -> SnippetSendPlan {
        // `\r\n` is ONE `Character` in Swift, so `isNewline` per character is
        // the whole rule -- `contains("\n")` would miss a CRLF command.
        guard command.contains(where: \.isNewline) else {
            return .send(SnippetKeystrokes.bytes(forLine: command, execute: execute))
        }
        if bracketedPaste {
            var bytes = bracketedPasteStart
            bytes.append(contentsOf: Array(command.utf8))
            bytes.append(contentsOf: bracketedPasteEnd)
            if execute {
                bytes.append(SnippetKeystrokes.terminator)
            }
            return .send(bytes)
        }
        guard execute else { return .refusedMultilineInsert }
        let lines = command.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var bytes: [UInt8] = []
        for line in lines {
            bytes.append(contentsOf: SnippetKeystrokes.bytes(forLine: String(line), execute: true))
        }
        return .send(bytes)
    }
}
