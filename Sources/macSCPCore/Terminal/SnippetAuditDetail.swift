import Foundation

/// Builds the audit log's plain-text line for a snippet execution.
///
/// The audit log is a list to skim, not a transcript: whitespace is
/// normalized and the command is capped, so an oddly-spaced or very long
/// command stays scannable in a row. `AuditEvent.detail` is finished
/// English by contract -- the UI localizes only the event kind's label.
public enum SnippetAuditDetail {
    /// Characters of command text kept before the ellipsis.
    private static let commandLimit = 200

    public static func text(for snippet: Snippet) -> String {
        let name = snippet.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = truncated(collapsingWhitespace(in: snippet.command))
        guard !name.isEmpty else { return "ran snippet: \(command)" }
        return "ran snippet \u{201C}\(name)\u{201D}: \(command)"
    }

    /// Tabs and runs of spaces become a single space. Newlines cannot occur
    /// here because `Snippet` rejects them at construction, but the predicate
    /// includes `isNewline` as a defensive belt-and-braces check.
    private static func collapsingWhitespace(in command: String) -> String {
        command
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// Counts CHARACTERS, not bytes: cutting a `String` by UTF-8 offset can
    /// split a grapheme and produce mojibake in the log.
    private static func truncated(_ command: String) -> String {
        guard command.count > commandLimit else { return command }
        return String(command.prefix(commandLimit)) + "\u{2026}"
    }
}
