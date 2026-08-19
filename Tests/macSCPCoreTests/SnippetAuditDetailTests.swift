import Foundation
import Testing
@testable import macSCPCore

@Suite("SnippetAuditDetail")
struct SnippetAuditDetailTests {
    private func snippet(name: String, command: String) -> Snippet {
        Snippet(name: name, command: command, tags: [])
    }

    @Test func namesTheSnippetAndQuotesItsCommand() {
        let text = SnippetAuditDetail.text(
            for: snippet(name: "Restart nginx", command: "systemctl restart nginx"))
        #expect(text == "ran snippet \u{201C}Restart nginx\u{201D}: systemctl restart nginx")
    }

    @Test func collapsesRunsOfWhitespaceAndTrims() {
        let text = SnippetAuditDetail.text(
            for: snippet(name: "Spaced", command: "  echo \t\t hello  "))
        #expect(text == "ran snippet \u{201C}Spaced\u{201D}: echo hello")
    }

    @Test func truncatesAVeryLongCommand() {
        let long = String(repeating: "x", count: 400)
        let text = SnippetAuditDetail.text(for: snippet(name: "Long", command: long))
        let command = text.replacingOccurrences(
            of: "ran snippet \u{201C}Long\u{201D}: ", with: "")
        #expect(command.count == 201)
        #expect(command.hasSuffix("\u{2026}"))
    }

    @Test func aNamelessSnippetIsDescribedByItsCommandAlone() {
        let text = SnippetAuditDetail.text(for: snippet(name: "   ", command: "uptime"))
        #expect(text == "ran snippet: uptime")
    }

    /// The audit log is one line per event. `SnippetAuditDetail` already
    /// collapsed whitespace when a command could not contain a newline —
    /// this pins that the rule actually covers newlines, now that a command
    /// can carry them. In Swift every `isNewline` character is also
    /// `isWhitespace`, which is why the existing rule suffices.
    @Test("a multi-line command is logged on a single line")
    func multilineCommandLogsOnOneLine() {
        let snippet = Snippet(name: "deploy", command: "cd /srv\nmake all")
        let text = SnippetAuditDetail.text(for: snippet)
        #expect(!text.contains { $0.isNewline })
        #expect(text.contains("cd /srv make all"))
    }
}
