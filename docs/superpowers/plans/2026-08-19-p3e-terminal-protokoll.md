# P3e — snippet executions in the session log

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Anyone who runs a snippet in the terminal can find it again
later in the session log — with the command that actually ran.

**Architecture:** The feasibility measurement has decided what NOT to
build here: free-typed keyboard input is not logged, because the client
cannot recognize a password prompt (see the spec addendum,
2026-08-19). What is logged is exclusively what macSCP itself sends and
whose text it knows — snippets, which by project rule carry no
credentials.

Two measurements keep this phase small: the audit machinery from M9b
stands complete (`AuditEvent.Kind`, `AuditRecorder.recordAction(_:)`, the
sheet with search and filter), and all four snippet surfaces run through
**one** funnel, `ContentView.triggerSnippet(_:execute:)`. So: one new
event kind, one Core formatter for the text, one recording line in the
funnel, one filter category.

**Executions only, never insertions.** An inserted snippet sits in the
prompt and can still be changed before it is sent; logging it as
"executed" would be a false entry. `execute == false` writes nothing.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, Swift Testing.

## Global Constraints

- Code, comments, identifiers, test names: **English only.**
- User-visible strings via `L10n.string`; the key sets of the four
  catalogs (en/de/fr/pl) must stay **identical** — a guard test already
  checks this.
- `AuditEvent.detail` is finished English plain text; the sheet only
  localizes the kind's label.
- A secret must never be printed, logged, or embedded in a message.
  Snippets carry no credentials by project rule — this rule is the
  precondition of this phase, not an assumption about it.
- Never write a line number into a comment.
- No doc comment claims something the code does not do.
- Tests: TDD red→green. `swift test` green at the end of every task.
- Conventional Commits, footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: Event kind + text formatter (Core)

**Files:**
- Modify: `Sources/macSCPCore/Sessions/AuditEvent.swift`
- Create: `Sources/macSCPCore/Terminal/SnippetAuditDetail.swift`
- Test: `Tests/macSCPCoreTests/SnippetAuditDetailTests.swift` (new)

**Interfaces:**
- Produces: `AuditEvent.Kind.snippetExecuted` and
  `SnippetAuditDetail.text(for: Snippet) -> String`. Task 2 uses both.

**Why a dedicated formatter in Core:** The text must be single-line,
free of control characters, and bounded — the log is a skimmable list,
not a transcript. A multi-line snippet would blow up the sheet's row
height. This rule belongs where it can be tested.

- [ ] **Step 1: Write the failing tests**

New file `Tests/macSCPCoreTests/SnippetAuditDetailTests.swift`:

```swift
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
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "SnippetAuditDetail"`
Expected: FAIL — `cannot find 'SnippetAuditDetail' in scope`.

If the `Snippet` initializer requires different arguments: read
`Sources/macSCPCore/Terminal/Snippet.swift` and adjust **only** the
`snippet(name:command:)` helper, not the checked expectations.

- [ ] **Step 3: Implement**

`Sources/macSCPCore/Sessions/AuditEvent.swift` — in `enum Kind`, add
after `crossSessionTransfer`:

```swift
        /// A snippet the user ran in the session's terminal (P3e). Only
        /// EXECUTIONS are recorded: an inserted snippet still sits in the
        /// prompt and can be edited before it runs, so logging it as run
        /// would be a false entry. Free-typed input is never recorded --
        /// the client cannot tell a password prompt from any other input
        /// (see the P3e feasibility note in the design spec), so there is
        /// no honest way to log it.
        case snippetExecuted
```

New file `Sources/macSCPCore/Terminal/SnippetAuditDetail.swift`:

```swift
import Foundation

/// Builds the audit log's plain-text line for a snippet execution.
///
/// The audit log is a list to skim, not a transcript: the text is forced
/// onto ONE line and capped, so a multi-line or very long command cannot
/// blow up a row. `AuditEvent.detail` is finished English by contract --
/// the UI localizes only the event kind's label.
public enum SnippetAuditDetail {
    /// Characters of command text kept before the ellipsis.
    private static let commandLimit = 200

    public static func text(for snippet: Snippet) -> String {
        let name = snippet.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = truncated(collapsingWhitespace(in: snippet.command))
        guard !name.isEmpty else { return "ran snippet: \(command)" }
        return "ran snippet \u{201C}\(name)\u{201D}: \(command)"
    }

    /// Newlines, tabs and runs of spaces all become a single space, so a
    /// two-line command reads as one sentence rather than breaking the row.
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "SnippetAuditDetail"`
Expected: PASS (5 tests). Then `swift test` — must be green.

Watch that the suite does **not** fail against an
`AuditEvent.Kind.allCases` completeness guard (there are L10n guards
that require every case). If it does: that is Task 2's job (the
catalogs) — report it rather than adding catalog entries ahead of time
here.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/AuditEvent.swift Sources/macSCPCore/Terminal/SnippetAuditDetail.swift Tests/macSCPCoreTests/SnippetAuditDetailTests.swift
git commit -m "feat(core): describe a snippet execution for the audit log"
```

---

### Task 2: Record, filter, translate (App)

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView.swift` (`triggerSnippet(_:execute:)`)
- Modify: `Sources/MacSCPAppKit/AuditLogSheet.swift` (filter category)
- Modify: `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Test: `Tests/macSCPAppKitTests/SnippetAuditWiringGuardTests.swift` (new)

**Interfaces:**
- Consumes: `AuditEvent.Kind.snippetExecuted` and
  `SnippetAuditDetail.text(for:)` from Task 1.

**Context you don't have to guess:**
- `triggerSnippet(_:execute:)` ends with
  `terminal.send(SnippetKeystrokes.bytes(for: snippet, execute: execute))`.
  The recording call belongs **after** this `send` — what gets logged is
  what actually went out, not what was about to go out.
- The recorder hangs off the tab: `activeTab.auditRecorder` (optional).
  If it is `nil`, nothing is recorded and nothing crashes.
- The sheet labels kinds via `L10n.string("audit.kind.\(kind.rawValue)", …)`
  and filters via `audit.filter.<case>`.

- [ ] **Step 1: Write the failing test**

There is no renderer for SwiftUI views in this suite, and
`triggerSnippet` hangs off `@State`. The checkable part is the
completeness of the catalogs — and that is the part that experience
shows gets forgotten.

New file `Tests/macSCPAppKitTests/SnippetAuditWiringGuardTests.swift`:

```swift
import Foundation
import Testing
import macSCPCore
@testable import MacSCPAppKit

/// The audit sheet looks a kind's label up as `audit.kind.<rawValue>`; a
/// missing entry silently renders the raw case name to the user. This pins
/// the new kind in every catalog, and pins the new filter's label with it.
@Suite("Snippet audit wiring")
struct SnippetAuditWiringGuardTests {
    private static let languages = ["en", "de", "fr", "pl"]

    private func catalog(_ language: String) throws -> String {
        let url = try #require(
            Bundle.module.url(
                forResource: "Localizable", withExtension: "strings",
                subdirectory: "\(language).lproj"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func everyCatalogLabelsTheSnippetKind() throws {
        for language in Self.languages {
            let text = try catalog(language)
            #expect(text.contains("\"audit.kind.snippetExecuted\""), "missing in \(language)")
        }
    }

    @Test func everyCatalogLabelsTheTerminalFilter() throws {
        for language in Self.languages {
            let text = try catalog(language)
            #expect(text.contains("\"audit.filter.terminal\""), "missing in \(language)")
        }
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter "Snippet audit wiring"`
Expected: FAIL — both tests, because the keys are missing.

If `Bundle.module` does not find the catalogs that way: look at
`Tests/macSCPAppKitTests/L10nTests.swift` for how the catalogs are
accessed there, and adopt **exactly that** approach.

- [ ] **Step 3: Record in the funnel**

In `Sources/MacSCPAppKit/ContentView.swift`, `triggerSnippet(_:execute:)`,
after the existing `terminal.send(...)`:

```swift
        // Only an EXECUTION is an event: an inserted snippet still sits in
        // the prompt and can be edited before it runs. Recorded after the
        // send, so the log says what actually went out.
        if execute {
            activeTab.auditRecorder?.recordAction(
                AuditEvent(kind: .snippetExecuted, detail: SnippetAuditDetail.text(for: snippet)))
        }
```

- [ ] **Step 4: Filter category**

In `Sources/MacSCPAppKit/AuditLogSheet.swift`:

`case all, transfers, fileOps, connection, errors`
→ `case all, transfers, fileOps, terminal, connection, errors`

In the picker, after the `fileOps` entry:

```swift
                Text(L10n.string("audit.filter.terminal", "Terminal")).tag(Filter.terminal)
```

In `matchesFilter(_:)`, as a new case:

```swift
        case .terminal:
            switch event.kind {
            case .snippetExecuted:
                return true
            default:
                return false
            }
```

- [ ] **Step 5: Catalogs (all four)**

Two keys each, next to the existing `audit.kind.*` resp.
`audit.filter.*` blocks:

```
en: "audit.kind.snippetExecuted" = "Snippet run";
    "audit.filter.terminal" = "Terminal";
de: "audit.kind.snippetExecuted" = "Snippet ausgeführt";
    "audit.filter.terminal" = "Terminal";
fr: "audit.kind.snippetExecuted" = "Extrait exécuté";
    "audit.filter.terminal" = "Terminal";
pl: "audit.kind.snippetExecuted" = "Wykonano fragment";
    "audit.filter.terminal" = "Terminal";
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter "Snippet audit wiring"` → PASS.
Then the full suite: `swift test` — must be green, including the
existing L10n guards for key equality across the four catalogs.

- [ ] **Step 7: Commit**

```bash
git add Sources/MacSCPAppKit Tests/macSCPAppKitTests/SnippetAuditWiringGuardTests.swift
git commit -m "feat(app): record snippet executions in the session log"
```
