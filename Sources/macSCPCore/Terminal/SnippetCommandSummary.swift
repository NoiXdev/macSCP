import Foundation

/// One line standing in for a command that may have several.
///
/// Three surfaces show a command in a single line — the snippets sheet's
/// row, the terminal panel's hover preview, and the action sheet's header.
/// `.lineLimit(1)` alone would show the first line and silently drop the
/// rest, so "cd /srv" and "cd /srv" + "rm -rf build" would look identical
/// in the list. The count is the whole point.
public enum SnippetCommandSummary {
    /// `command`'s first line, plus how many lines follow when there are
    /// any. Returns the command unchanged when it is a single line, so the
    /// common case gains no decoration at all.
    public static func firstLine(of command: String) -> (text: String, moreLines: Int) {
        let lines = command.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let first = lines.first, lines.count > 1 else { return (command, 0) }
        return (String(first), lines.count - 1)
    }
}
