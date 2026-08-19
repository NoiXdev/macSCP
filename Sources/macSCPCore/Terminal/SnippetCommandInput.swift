import Foundation

/// What may enter a snippet's command field (snippet editor, part 1).
///
/// `Snippet.init?` refuses a command containing any newline, and an
/// `NSTextView` accepts Return by default. Without this, the editor would
/// happily build a value the model rejects on save, and the user would see
/// only that saving does nothing.
///
/// Newlines become a single space rather than being dropped: pasting a
/// two-line command should stay runnable, not silently glue two words
/// together.
public enum SnippetCommandInput {
    public static func sanitized(_ text: String) -> String {
        // `\r\n` is ONE `Character` in Swift, so a search for "\n" alone
        // misses it -- the same trap `Snippet.init?` was fixed for in P3e.
        String(text.map { $0.isNewline ? " " : $0 })
    }
}
