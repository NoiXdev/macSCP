# P3f — Exportieren an der Snippet-Zeile

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die Snippet-Liste bekommt „Exportieren…" in ihr
Zeilen-Kontextmenü — mit derselben Bedeutung, die dieser Eintrag überall
sonst in der App schon hat: genau diese eine Zeile.

**Architecture:** Die Messung vor dem Planen hat den Umfang der Phase auf
ein Fünftel geschrumpft und die offene Frage der Spec beantwortet, indem
sie zeigte, dass der ausgelieferte Code sie längst beantwortet:

| Liste | „Exportieren" in der Zeile |
|---|---|
| Sitzung (Sidebar) | vorhanden (`export.menu.single`) |
| Gruppe (Sidebar) | vorhanden (`export.menu.group`) |
| Login-Sets | vorhanden (`logins.export.action`) |
| SSH-Schlüssel | vorhanden (öffentlich und privat) |
| **Snippets** | **fehlt** |

Die Spec fragte, ob „Exportieren" an der Zeile dasselbe meint wie im
Sheet. `LoginSetsSheet` beantwortet das im Code, mit Kommentar: *„the
footer button covers 'all' (or whatever is selected); this one always
means THIS row."* Der Zeileneintrag setzt außerdem vorher die Auswahl, damit
sichtbare Auswahl und wirksamer Umfang nie auseinanderlaufen. Diese Phase
überträgt genau dieses Muster — sie erfindet keine zweite Regel.

**Bewusst NICHT in dieser Phase:** die Fußzeilen der beiden Sheets meinen
Verschiedenes (Login-Sets: die Auswahl, sonst die sichtbaren, mit
Anzahl-Bestätigung; Snippets: immer die sichtbaren, ohne Bestätigung). Das
ist vorbestehend, betrifft keinen Kontextmenü-Eintrag und ist eine
Verhaltensänderung an ausgeliefertem Code — sie gehört in eine eigene
Entscheidung, nicht in diese.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, Swift Testing.

## Global Constraints

- Code, Kommentare, Bezeichner, Testnamen: **ausschließlich Englisch.**
- Nutzer-sichtbare Strings über `L10n.string`; die Schlüsselmengen der vier
  Kataloge (en/de/fr/pl) bleiben identisch — ein Wächtertest prüft das.
- Nie eine Zeilennummer in einen Kommentar schreiben.
- Kein Kommentar behauptet etwas, das der Code nicht tut.
- Tests: TDD rot→grün. `swift test` am Ende grün.
- Conventional Commits, Footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: „Exportieren…" im Snippet-Zeilenmenü

**Files:**
- Modify: `Sources/MacSCPAppKit/SnippetsSheet.swift`
- Test: `Tests/macSCPAppKitTests/SnippetRowExportMenuGuardTests.swift` (neu)

**Interfaces:** keine neuen öffentlichen APIs.

**Kontext, den du nicht raten musst:**
- Das Zeilen-Kontextmenü existiert bereits und enthält heute genau zwei
  Einträge: „Bearbeiten…" und „Löschen…". Beide setzen als erstes
  `selectedID = snippet.id`. Der neue Eintrag folgt demselben Muster —
  der Kommentar über dem Menü erklärt bereits, warum.
- `performExport(_ snippets: [Snippet])` ist eine vorhandene private
  Methode desselben Typs. Sie kodiert, legt das Dokument an und öffnet den
  `fileExporter`. Der neue Eintrag ruft sie mit **genau einem** Snippet.
- Der Schlüssel `snippets.export` (englisch „Export…") existiert bereits in
  allen vier Katalogen — er ist die Beschriftung des Fußzeilen-Knopfs.
  Verwende ihn wieder; **lege keinen neuen Schlüssel an.** Login-Sets machen
  es an dieser Stelle genauso (ein Schlüssel, zwei Auslöser).
- Der Eintrag gehört **zwischen** „Bearbeiten…" und „Löschen…", damit die
  zerstörende Aktion die letzte im Menü bleibt (so ist es in allen anderen
  Zeilenmenüs der App).

- [ ] **Step 1: Write the failing test**

Es gibt keinen SwiftUI-Renderer in dieser Suite. Prüfbar und wertvoll ist,
dass der Eintrag im Menükörper überhaupt existiert und die vorhandene
Beschriftung wiederverwendet. Neue Datei
`Tests/macSCPAppKitTests/SnippetRowExportMenuGuardTests.swift`:

```swift
import Foundation
import Testing
@testable import MacSCPAppKit

/// The snippet row was the last list in the app whose context menu had no
/// "Export…" entry. This reads the source of `SnippetsSheet` and pins that
/// the row menu offers it, exports exactly the right-clicked snippet, and
/// keeps the destructive entry last.
@Suite("Snippet row export menu")
struct SnippetRowExportMenuGuardTests {
    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // macSCPAppKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/MacSCPAppKit/SnippetsSheet.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func theRowMenuExportsExactlyTheRightClickedSnippet() throws {
        let text = try source()
        #expect(text.contains("performExport([snippet])"))
    }

    @Test func theRowMenuReusesTheExistingExportLabel() throws {
        let text = try source()
        // One key, two triggers -- a second key would let the footer and the
        // row drift apart in translation.
        #expect(text.contains("\"snippets.export\""))
    }

    @Test func theDestructiveEntryStaysLastInTheRowMenu() throws {
        let text = try source()
        let exportIndex = try #require(text.range(of: "performExport([snippet])")).lowerBound
        let deleteIndex = try #require(text.range(of: "isShowingDeleteConfirm = true")).lowerBound
        #expect(exportIndex < deleteIndex)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter "Snippet row export menu"`
Expected: FAIL — der erste und dritte Test, weil `performExport([snippet])`
im Quelltext nicht vorkommt. (Der zweite Test ist bereits grün, weil der
Fußzeilen-Knopf denselben Schlüssel nutzt — das ist beabsichtigt: er pinnt
die Wiederverwendung, nicht die Neuheit. Sag im Bericht, dass dir das
aufgefallen ist.)

Falls der Pfadaufbau über `#filePath` nicht trägt: sieh in den vorhandenen
quelltextlesenden Wächtertests unter `Tests/macSCPAppKitTests/` nach
(z. B. `PaneVisibilityWiringGuardTests.swift`) und übernimm **genau deren**
Weg zur Datei.

- [ ] **Step 3: Implement**

In `Sources/MacSCPAppKit/SnippetsSheet.swift`, im Zeilen-Kontextmenü,
zwischen „Bearbeiten…" und „Löschen…":

```swift
            Button(L10n.string("snippets.export", "Export…")) {
                selectedID = snippet.id
                performExport([snippet])
            }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "Snippet row export menu"` → PASS (3 Tests).
Danach die volle Suite: `swift test` — muss grün sein.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPAppKit/SnippetsSheet.swift Tests/macSCPAppKitTests/SnippetRowExportMenuGuardTests.swift
git commit -m "feat(app): offer Export in the snippet row context menu"
```
