# P3h — Ein Exportumfang für beide Sheets

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** „Exportieren" in der Fußzeile bedeutet in beiden Sheets dasselbe —
die Auswahl, falls sie auf dem Schirm ist, sonst alles auf dem Schirm — und
sagt vorher, wie viele Einträge geschrieben werden.

**Architecture:** Aus der P3f-Gesamtprüfung, Maintainer-Entscheidung. Heute
verzweigen die beiden Fußzeilen unterschiedlich: `LoginSetsSheet` beachtet
die Auswahl und nennt die Anzahl in seinem Export-Sheet, `SnippetsSheet`
exportiert immer die sichtbare Menge und öffnet sofort den Speichern-Dialog.

Die Regel wandert deshalb in den Core, als **eine** Implementierung, die
beide Sheets rufen — bisher steht sie als private Methode nur in einem der
beiden. Und der Snippet-Export bekommt den Schritt, der die Verengung
sichtbar macht: ohne ihn wäre „nur die Auswahl" genau die unsichtbare
Bedeutungsänderung, vor der die Spec warnt.

**Kein Optionen-Sheet für Snippets.** `SnippetExportCodec` kennt weder
Optionen noch Passwort; ein Sheet wie das der Login-Sets hätte nichts zu
zeigen. Es wird eine Bestätigung mit der Anzahl, nicht mehr.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, Swift Testing.

## Global Constraints

- Code, Kommentare, Bezeichner, Testnamen: **ausschließlich Englisch.**
- Nutzer-sichtbare Strings über `L10n.string`; die vier Kataloge
  (en/de/fr/pl) behalten identische Schlüsselmengen — Wächter prüfen das.
- Nie eine Zeilennummer in einen Kommentar schreiben.
- Kein Kommentar behauptet etwas, das der Code nicht tut.
- Tests: TDD rot→grün. `swift test` am Ende jeder Task grün.
- Conventional Commits, Footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: Die Umfangsregel in den Core

**Files:**
- Create: `Sources/macSCPCore/Sessions/ExportScope.swift`
- Test: `Tests/macSCPCoreTests/ExportScopeTests.swift` (neu)

**Interfaces:**
- Produces: `ExportScope.resolve(selectedID:from:)`. Task 2 ruft es zweimal.

- [ ] **Step 1: Write the failing tests**

Neue Datei `Tests/macSCPCoreTests/ExportScopeTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("ExportScope")
struct ExportScopeTests {
    private struct Row: Identifiable, Equatable {
        let id: Int
    }

    @Test func aSelectionThatIsOnScreenNarrowsTheScopeToIt() {
        let rows = [Row(id: 1), Row(id: 2), Row(id: 3)]
        #expect(ExportScope.resolve(selectedID: 2, from: rows) == [Row(id: 2)])
    }

    @Test func noSelectionMeansEverythingOnScreen() {
        let rows = [Row(id: 1), Row(id: 2)]
        #expect(ExportScope.resolve(selectedID: nil, from: rows) == rows)
    }

    /// The membership check is the whole point: a row the search has
    /// filtered away is still `selectedID`, and letting it through would
    /// export something the user cannot see.
    @Test func aSelectionFilteredOffScreenDoesNotNarrowTheScope() {
        let rows = [Row(id: 1), Row(id: 2)]
        #expect(ExportScope.resolve(selectedID: 99, from: rows) == rows)
    }

    @Test func anEmptyListStaysEmpty() {
        #expect(ExportScope.resolve(selectedID: 1, from: [Row]()) == [])
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "ExportScope"`
Expected: FAIL — `cannot find 'ExportScope' in scope`.

- [ ] **Step 3: Implement**

Neue Datei `Sources/macSCPCore/Sessions/ExportScope.swift`:

```swift
import Foundation

/// What an "Export…" button in a list's footer covers.
///
/// One rule for every such footer: the selection when it is one of the rows
/// currently on screen, otherwise every row on screen. The membership check
/// is what keeps a selection the search has filtered away from silently
/// widening — or narrowing — the scope, since a list's selection outlives
/// its filter.
///
/// Lives here rather than in a sheet so the two sheets that offer this
/// button cannot drift apart: a second copy is how "Export" came to mean
/// two different things in the first place.
public enum ExportScope {
    public static func resolve<Item: Identifiable>(
        selectedID: Item.ID?, from visible: [Item]
    ) -> [Item] {
        guard let selectedID, let selected = visible.first(where: { $0.id == selectedID })
        else { return visible }
        return [selected]
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "ExportScope"` → PASS (4 Tests).
Danach `swift test` — grün.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/ExportScope.swift Tests/macSCPCoreTests/ExportScopeTests.swift
git commit -m "feat(core): define one export scope rule for list footers"
```

---

### Task 2: Beide Fußzeilen auf die Regel, Snippets mit Anzahl

**Files:**
- Modify: `Sources/MacSCPAppKit/LoginSetsSheet.swift`
- Modify: `Sources/MacSCPAppKit/SnippetsSheet.swift`
- Modify: `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Test: `Tests/macSCPAppKitTests/SnippetExportConfirmGuardTests.swift` (neu)

**Interfaces:**
- Consumes: `ExportScope.resolve(selectedID:from:)` aus Task 1.

**Kontext, den du nicht raten musst:**
- `LoginSetsSheet` hat heute eine private Methode `exportScope(within:)` mit
  genau dieser Regel, aufgerufen an seinem Fußzeilen-Knopf. Ersetze den
  Aufruf durch `ExportScope.resolve(selectedID: selectedID, from: visibleSets)`
  und **lösche die private Methode**. Ihr Doc-Kommentar erklärt die Regel —
  der Kern davon steht jetzt am Core-Typ; lass an der Aufrufstelle nur
  stehen, was dort noch etwas erklärt, und wiederhole nichts doppelt.
  Das Verhalten bleibt unverändert; das ist der Punkt.
- `SnippetsSheet`s Fußzeile ruft heute `performExport(visibleSnippets)`.
  Sie soll stattdessen den aufgelösten Umfang **bestätigen lassen** und erst
  nach der Bestätigung exportieren.
- `snippetsCanExport` schaltet den Knopf ab, solange `visibleSnippets` leer
  ist — der aufgelöste Umfang kann daher nie leer sein. Halte das in einem
  kurzen Kommentar fest, statt einen unerreichbaren Zweig zu bauen.
- Das **Zeilen**-Kontextmenü bleibt unverändert: es exportiert weiterhin
  genau seine Zeile, ohne Bestätigung. Es gibt dort nichts zu verengen und
  nichts zu zählen — die Zeile, auf die geklickt wurde, ist die Aussage.

- [ ] **Step 1: Write the failing test**

Neue Datei `Tests/macSCPAppKitTests/SnippetExportConfirmGuardTests.swift`.
Baue sie im Idiom der Nachbarn — sieh dir
`Tests/macSCPAppKitTests/SnippetRowExportMenuGuardTests.swift` an und
übernimm dessen Block-Isolierung und Fail-Closed-Verhalten. Sie pinnt:

1. der Fußzeilen-Knopf ruft **nicht mehr** direkt `performExport(` mit
   `visibleSnippets`, sondern setzt den Bestätigungszustand;
2. der bestätigende Knopf ruft `performExport(` mit dem aufgelösten Umfang;
3. `ExportScope.resolve(` kommt in der Datei vor;
4. das Zeilenmenü ruft weiterhin unbestätigt `performExport([snippet])`.

Formuliere die Zusicherungen gegen die Anker, die du nach Step 3 tatsächlich
im Code hast — schreibe den Test zuerst gegen deinen geplanten Code, lass
ihn rot laufen, und passe nur die Anker an, nie die geprüfte Eigenschaft.

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter "SnippetExportConfirm"` → FAIL.

- [ ] **Step 3: Implement**

In `SnippetsSheet`:

```swift
    /// Non-nil while the export confirmation is up: the snippets the user
    /// is about to write, held rather than recomputed so what was confirmed
    /// is exactly what gets written even if the filter changes underneath.
    @State private var pendingExport: [Snippet]?
```

Fußzeilen-Knopf:

```swift
                Button(L10n.string("snippets.export", "Export…")) {
                    // `snippetsCanExport` already rules out an empty visible
                    // list, so the resolved scope always has at least one
                    // snippet in it.
                    pendingExport = ExportScope.resolve(
                        selectedID: selectedID, from: visibleSnippets)
                }
```

Und ein Alert am Sheet-Körper, im Stil der vorhandenen Alerts dieser Datei:

```swift
        .alert(
            L10n.string("snippets.export.confirm.title", "Export snippets?"),
            isPresented: Binding(
                get: { pendingExport != nil },
                set: { if !$0 { pendingExport = nil } })
        ) {
            Button(L10n.string("snippets.export", "Export…")) {
                if let pendingExport { performExport(pendingExport) }
                pendingExport = nil
            }
            .keyboardShortcut(.defaultAction)
            Button(L10n.string("cancel", "Cancel"), role: .cancel) {
                pendingExport = nil
            }
        } message: {
            Text(String(
                format: L10n.string(
                    "snippets.export.confirm.message %lld",
                    "%lld snippets will be written to the file."),
                pendingExport?.count ?? 0))
        }
```

**Prüfe den Abbrechen-Schlüssel:** `"cancel"` ist geraten. Suche in den
Katalogen nach dem Schlüssel, den die anderen Alerts dieser App für
„Abbrechen" verwenden, und nimm **genau den**. Lege keinen neuen an. Nenne
im Bericht, welchen du gefunden hast.

- [ ] **Step 4: Kataloge**

Zwei neue Schlüssel in allen vier Katalogen, neben die vorhandenen
`snippets.*`-Blöcke. Formuliere die Anzahl-Meldung parallel zu
`"logins.export.summary %lld"`, damit beide Sheets gleich klingen:

```
en: "snippets.export.confirm.title" = "Export snippets?";
    "snippets.export.confirm.message %lld" = "%lld snippets will be written to the file.";
de: "snippets.export.confirm.title" = "Snippets exportieren?";
    "snippets.export.confirm.message %lld" = "%lld Snippets werden in die Datei geschrieben.";
```

Für **fr** und **pl** formuliere selbst, parallel zur jeweiligen Fassung von
`logins.export.summary %lld` in derselben Datei — übernimm deren Satzbau und
Wortwahl, statt neu zu erfinden.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "SnippetExportConfirm"` → PASS.
Danach `swift test` — grün, einschließlich der Katalog-Wächter.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacSCPAppKit Tests/macSCPAppKitTests/SnippetExportConfirmGuardTests.swift
git commit -m "feat(app): give both export footers one scope and a count"
```
