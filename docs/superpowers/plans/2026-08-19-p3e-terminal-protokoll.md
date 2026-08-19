# P3e — Snippet-Ausführungen im Sitzungsprotokoll

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wer ein Snippet im Terminal ausführt, findet das später im
Sitzungsprotokoll wieder — mit dem Befehl, der tatsächlich lief.

**Architecture:** Die Machbarkeitsmessung hat entschieden, was hier NICHT
gebaut wird: freie Tastatureingabe wird nicht protokolliert, weil der Client
einen Passwortprompt nicht erkennen kann (siehe Spec-Nachtrag 2026-08-19).
Protokolliert wird ausschließlich, was macSCP selbst absendet und dessen
Text es kennt — Snippets, die laut Projektregel keine Zugangsdaten tragen.

Zwei Messungen machen die Phase klein: die Audit-Maschinerie aus M9b steht
komplett (`AuditEvent.Kind`, `AuditRecorder.recordAction(_:)`, das Sheet mit
Suche und Filter), und alle vier Snippet-Oberflächen laufen durch **einen**
Trichter, `ContentView.triggerSnippet(_:execute:)`. Also: eine neue
Ereignisart, ein Core-Formatierer für den Text, eine Aufzeichnungszeile im
Trichter, eine Filterkategorie.

**Nur Ausführungen, nie Einfügungen.** Ein eingefügtes Snippet steht im
Prompt und kann vor dem Absenden noch geändert werden; es als „ausgeführt"
zu protokollieren wäre ein falscher Eintrag. `execute == false` schreibt
nichts.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, Swift Testing.

## Global Constraints

- Code, Kommentare, Bezeichner, Testnamen: **ausschließlich Englisch.**
- Nutzer-sichtbare Strings über `L10n.string`; die Schlüsselmengen der vier
  Kataloge (en/de/fr/pl) müssen **identisch** bleiben — ein Wächtertest
  prüft das bereits.
- `AuditEvent.detail` ist fertiger englischer Klartext; das Sheet
  lokalisiert nur das Label der Art.
- Ein Geheimnis darf nie gedruckt, geloggt oder in eine Meldung eingebettet
  werden. Snippets tragen laut Projektregel keine Zugangsdaten — diese
  Regel ist die Voraussetzung dieser Phase, nicht eine Annahme darüber.
- Nie eine Zeilennummer in einen Kommentar schreiben.
- Kein Doc-Kommentar behauptet etwas, das der Code nicht tut.
- Tests: TDD rot→grün. `swift test` am Ende jeder Task grün.
- Conventional Commits, Footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: Ereignisart + Textformatierer (Core)

**Files:**
- Modify: `Sources/macSCPCore/Sessions/AuditEvent.swift`
- Create: `Sources/macSCPCore/Terminal/SnippetAuditDetail.swift`
- Test: `Tests/macSCPCoreTests/SnippetAuditDetailTests.swift` (neu)

**Interfaces:**
- Produces: `AuditEvent.Kind.snippetExecuted` und
  `SnippetAuditDetail.text(for: Snippet) -> String`. Task 2 nutzt beide.

**Warum ein eigener Formatierer im Core:** Der Text muss einzeilig, ohne
Steuerzeichen und begrenzt sein — das Protokoll ist eine überfliegbare
Liste, kein Mitschnitt. Ein mehrzeiliges Snippet würde die Zeilenhöhe des
Sheets sprengen. Diese Regel gehört dorthin, wo sie geprüft werden kann.

- [ ] **Step 1: Write the failing tests**

Neue Datei `Tests/macSCPCoreTests/SnippetAuditDetailTests.swift`:

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

Falls der `Snippet`-Initializer andere Argumente verlangt: lies
`Sources/macSCPCore/Terminal/Snippet.swift` und passe **nur** den
`snippet(name:command:)`-Helfer an, nicht die geprüften Erwartungen.

- [ ] **Step 3: Implement**

`Sources/macSCPCore/Sessions/AuditEvent.swift` — im `enum Kind` hinter
`crossSessionTransfer` ergänzen:

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

Neue Datei `Sources/macSCPCore/Terminal/SnippetAuditDetail.swift`:

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
Expected: PASS (5 Tests). Danach `swift test` — muss grün sein.

Achte darauf, dass die Suite **nicht** an einem Vollständigkeits-Wächter
über `AuditEvent.Kind.allCases` scheitert (es gibt L10n-Wächter, die jeden
Fall verlangen). Falls doch: das ist Task 2's Aufgabe (die Kataloge) — melde
es, statt hier Katalogeinträge vorzuziehen.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/AuditEvent.swift Sources/macSCPCore/Terminal/SnippetAuditDetail.swift Tests/macSCPCoreTests/SnippetAuditDetailTests.swift
git commit -m "feat(core): describe a snippet execution for the audit log"
```

---

### Task 2: Aufzeichnen, filtern, übersetzen (App)

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView.swift` (`triggerSnippet(_:execute:)`)
- Modify: `Sources/MacSCPAppKit/AuditLogSheet.swift` (Filterkategorie)
- Modify: `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Test: `Tests/macSCPAppKitTests/SnippetAuditWiringGuardTests.swift` (neu)

**Interfaces:**
- Consumes: `AuditEvent.Kind.snippetExecuted` und
  `SnippetAuditDetail.text(for:)` aus Task 1.

**Kontext, den du nicht raten musst:**
- `triggerSnippet(_:execute:)` endet mit
  `terminal.send(SnippetKeystrokes.bytes(for: snippet, execute: execute))`.
  Der Eintrag gehört **hinter** dieses `send` — protokolliert wird, was
  wirklich rausging, nicht was vorhatte rauszugehen.
- Der Recorder hängt am Tab: `activeTab.auditRecorder` (optional). Ist er
  `nil`, wird nichts protokolliert und nichts abgestürzt.
- Das Sheet labelt Arten über `L10n.string("audit.kind.\(kind.rawValue)", …)`
  und Filter über `audit.filter.<case>`.

- [ ] **Step 1: Write the failing test**

Es gibt keinen Renderer für SwiftUI-Views in dieser Suite, und
`triggerSnippet` hängt an `@State`. Der prüfbare Teil ist die
Vollständigkeit der Kataloge — und die ist der Teil, der erfahrungsgemäß
vergessen wird.

Neue Datei `Tests/macSCPAppKitTests/SnippetAuditWiringGuardTests.swift`:

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
Expected: FAIL — beide Tests, weil die Schlüssel fehlen.

Falls `Bundle.module` die Kataloge nicht so findet: sieh in
`Tests/macSCPAppKitTests/L10nTests.swift` nach, wie dort auf die Kataloge
zugegriffen wird, und übernimm **genau diesen** Weg.

- [ ] **Step 3: Aufzeichnen im Trichter**

In `Sources/MacSCPAppKit/ContentView.swift`, `triggerSnippet(_:execute:)`,
hinter dem vorhandenen `terminal.send(...)`:

```swift
        // Only an EXECUTION is an event: an inserted snippet still sits in
        // the prompt and can be edited before it runs. Recorded after the
        // send, so the log says what actually went out.
        if execute {
            activeTab.auditRecorder?.recordAction(
                AuditEvent(kind: .snippetExecuted, detail: SnippetAuditDetail.text(for: snippet)))
        }
```

- [ ] **Step 4: Filterkategorie**

In `Sources/MacSCPAppKit/AuditLogSheet.swift`:

`case all, transfers, fileOps, connection, errors`
→ `case all, transfers, fileOps, terminal, connection, errors`

Im Picker, hinter dem `fileOps`-Eintrag:

```swift
                Text(L10n.string("audit.filter.terminal", "Terminal")).tag(Filter.terminal)
```

In `matchesFilter(_:)`, als neuer Fall:

```swift
        case .terminal:
            switch event.kind {
            case .snippetExecuted:
                return true
            default:
                return false
            }
```

- [ ] **Step 5: Kataloge (alle vier)**

Je zwei Schlüssel, neben die vorhandenen `audit.kind.*`- bzw.
`audit.filter.*`-Blöcke:

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
Danach die volle Suite: `swift test` — muss grün sein, einschließlich der
vorhandenen L10n-Wächter über die Schlüsselgleichheit der vier Kataloge.

- [ ] **Step 7: Commit**

```bash
git add Sources/MacSCPAppKit Tests/macSCPAppKitTests/SnippetAuditWiringGuardTests.swift
git commit -m "feat(app): record snippet executions in the session log"
```
