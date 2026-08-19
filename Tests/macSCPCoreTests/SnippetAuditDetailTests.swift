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

    /// The audit log records the TEMPLATE, never a value. This is free today
    /// — `SnippetAuditDetail` reads `snippet.command`, which is the template
    /// — and a rule that is free is broken for free at the next rework.
    ///
    /// Fix round 1: the original version of this test asserted
    /// `!text.contains("kunden")` without ever putting `"kunden"` anywhere
    /// near the input — the review proved by mutation (rewiring
    /// `ContentView.runSnippet`'s audit call to log the resolved command
    /// instead of the template, full suite still green) that the assertion
    /// could not fail on its own terms. This version actually resolves
    /// `"kunden"` into a command via `SnippetVariableSubstitution.resolve`
    /// first, so `resolved` genuinely carries it — proving the substitution
    /// step really would leak the value into the text it produces — and only
    /// then checks that `SnippetAuditDetail.text(for:)`, built from the
    /// UNMODIFIED `snippet` (never from `resolved`), does not.
    ///
    /// This still cannot see `ContentView.runSnippet`'s own call site — no
    /// Core-layer test can, since `SnippetAuditDetail.text(for:)` takes a
    /// `Snippet`, not a resolved string, and the wrong-argument mistake the
    /// review demonstrated lives entirely in the App layer. That half of the
    /// property is pinned separately, by
    /// `SnippetVariablePromptWiringGuardTests.runSnippetAuditsTheTemplateNotTheResolvedCommand`
    /// in the App-layer test target — a source-text scan of the actual call
    /// site, the shape this project already uses (`SnippetAuditWiringGuardTests`,
    /// `PaneVisibilityWiringGuardTests`) for exactly this "no functional test
    /// can reach it" boundary.
    @Test("a variable value never reaches the audit text")
    func variableValuesStayOutOfTheAuditLog() {
        let variable = SnippetVariable(
            name: "DB", prompt: "Database", kind: .freeText, placement: .placeholder,
            defaultValue: "", remembersLastValue: false)
        let snippet = Snippet(
            name: "dump", command: "mysqldump {{DB}}", variables: [variable])
        let resolved = SnippetVariableSubstitution.resolve(
            command: snippet.command, variables: snippet.variables, values: ["DB": "kunden"])
        // The value genuinely reaches a resolved command -- so the check
        // below is not vacuous: there is now something for it to catch.
        #expect(resolved.contains("kunden"))
        let text = SnippetAuditDetail.text(for: snippet)
        #expect(text.contains("{{DB}}"))
        #expect(!text.contains("kunden"))
    }
}
