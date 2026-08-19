import Foundation
import Testing
@testable import macSCPCore

@Suite("SnippetAuditDetail")
struct SnippetAuditDetailTests {
    private func snippet(name: String, command: String) -> Snippet {
        let normalized = command.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return Snippet(name: name, command: normalized, tags: [])!
    }

    @Test func namesTheSnippetAndQuotesItsCommand() {
        let text = SnippetAuditDetail.text(
            for: snippet(name: "Restart nginx", command: "systemctl restart nginx"))
        #expect(text == "ran snippet \u{201C}Restart nginx\u{201D}: systemctl restart nginx")
    }

    @Test func collapsesAMultiLineCommandOntoOneLine() {
        let text = SnippetAuditDetail.text(
            for: snippet(name: "Two steps", command: "cd /srv\nls -la"))
        #expect(text == "ran snippet \u{201C}Two steps\u{201D}: cd /srv ls -la")
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
}
