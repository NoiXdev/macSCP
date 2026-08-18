# P3b: Snippets exportieren und importieren — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Snippets lassen sich in eine Datei schreiben und wieder einlesen —
über dieselbe Envelope wie Sitzungen und Login-Sets, immer ohne Passwort.

**Architecture:** Ein Codec über `ExportEnvelopeCodec` mit eigenem
Formatnamen, ein Planer auf dem **geteilten** `ImportConflictArbiter`, und
zwei Sheets nach dem Muster der vorhandenen. Nichts an der Envelope selbst
wird angefasst.

**Tech Stack:** Swift 6, `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+,
SwiftUI, Swift Testing, zwei Testtargets.

Spec: `docs/superpowers/specs/2026-08-18-p3-ordnung-design.md`, Abschnitt P3b.

## Global Constraints

- **Code, Kommentare, Testnamen: Englisch.** Interne Doku (`docs/`) Deutsch.
- **Jeder neue L10n-Schlüssel in allen vier Katalogen** (en/de/fr/pl),
  identische Schlüsselmengen. Nachweis:
  `for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done`
- **Nie eine Zeilennummer in einen Kommentar.**
- **Kein Secret in Log, Fehler oder Testfehlermeldung.** Snippets enthalten
  keine — und dieses Format bekommt **keinen Krypto-Pfad**, der etwas
  anderes suggeriert.
- **Die Prosa dieses Plans ist eine zu prüfende Behauptung.** In der
  Vorphase steckte in **fünf** Task-Beschreibungen ein sachlicher Fehler
  über den Code. Weicht etwas ab, ist **der Plan** falsch — melden, nicht
  anpassen.
- **Zwei Proben vor jedem Commit**, beide:
  1. Bliebe ein Test grün, wenn die Funktion konstant zurückgäbe?
  2. **Welche Behauptung meines Doc-Kommentars beobachtet kein Test?**
     Diese Frage hat in den letzten drei Phasen jedes Mal etwas gefunden,
     zweimal eine schlicht falsche Aussage.
- **Die GUI wird nicht gestartet.** `scripts/package-app` erlaubt,
  `scripts/release` nicht.
- Conventional Commits, Englisch, Footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Volle Suite grün vor jedem Commit. Ausgangsstand: **2024 Tests in 174
  Suiten** — selbst nachmessen, nie abschreiben.

## Gemessener Ist-Zustand

Selbst nachgeprüft, bevor der Plan geschrieben wurde — prüfe es trotzdem:

- `ExportEnvelopeCodec` ist bereits generisch:
  `encode<P: Codable>(_:format:version:password:)`, `probe`, `decode`.
  Bei `password == nil` entsteht ein Klartext-Payload mit
  `encrypted: false`. **Ein Klartextpfad existiert also schon.**
- Zwei Formate nutzen sie: `SessionExportCodec` (`macscp-sessions`) und
  `LoginSetExportCodec` (`macscp-logins`). Beide bestehen aus
  `static let formatName`, `static let currentVersion` und drei dünnen
  `encode/probe/decode`-Wrappern über die Envelope.
- `LoginSetImportPlanner` ist der Präzedenzfall für **namensbasierte**
  Duplikate: `plan(existing:incoming:arbiter:) async -> LoginSetImportPlan`,
  Kollisionsschlüssel **getrimmter, groß-/kleinschreibungsunabhängiger
  Name**, `takenNames` mit dem Bestand vorbelegt und bei jedem vergebenen
  Namen erweitert, `replacedExistingIDs` gegen Doppelersetzung, und
  **Abbruch verwirft den ganzen Lauf**, nicht nur den Rest.
- `ImportConflict(itemName:kindLabel:reason:)` mit `reason: .name`.
- `SnippetStore` schreibt `snippets.json` als **nacktes Array ohne
  Versionsfeld**; Methoden `all() throws`, `save(_:) throws`,
  `remove(id:) throws`. Ein Export- oder Importpfad existiert nicht.
- `SnippetsLoad` (App) unterscheidet `.loaded([Snippet])` von `.unreadable`.
- Die UTTypes stehen in `Sources/MacSCPAppKit/SessionExportImportSheets.swift`
  als `UTType(exportedAs: "dev.noix.macscp.…", conformingTo: .json)`.

## Dateien

| Datei | Zuständig für |
|---|---|
| `Sources/macSCPCore/Terminal/SnippetExportCodec.swift` (neu) | Payload + Format `macscp-snippets` |
| `Sources/macSCPCore/Terminal/SnippetImportPlanner.swift` (neu) | Duplikate am Namen, geteilter Arbiter |
| `Sources/MacSCPAppKit/SessionExportImportSheets.swift` | neuer UTType |
| `Sources/MacSCPAppKit/SnippetsSheet.swift` | Export-/Import-Knöpfe |
| die vier `Localizable.strings` | neue Schlüssel |

---

### Task 1: Das Austauschformat

**Files:**
- Create: `Sources/macSCPCore/Terminal/SnippetExportCodec.swift`
- Create: `Tests/macSCPCoreTests/SnippetExportCodecTests.swift`

**Interfaces:**
- Produces:
```swift
public struct SnippetExportPayload: Codable, Equatable, Sendable {
    public var snippets: [Snippet]
    public init(snippets: [Snippet])
}

public enum SnippetExportCodec {
    public static func encode(_ payload: SnippetExportPayload) throws -> Data
    public static func probe(_ data: Data) throws -> Bool
    public static func decode(_ data: Data) throws -> SnippetExportPayload
}
```

**Beachte die Asymmetrie zu den beiden vorhandenen Codecs:** deren
`encode`/`decode` nehmen ein `password: String?`. **Dieser nicht.** Das
Format trägt keine Secrets, und ein Passwort-Parameter wäre eine Einladung,
später eine Verschlüsselung anzubieten, die nichts schützt. Intern wird
`password: nil` übergeben — **und genau das ist zu pinnen**, nicht bloß zu
kommentieren.

- [ ] **Schritt 1: Die Tests zuerst**

```swift
@Test func aRoundTripPreservesNameCommandAndTags() throws {
    let snippet = Snippet(name: "Clean up", command: "docker system prune -f",
                          tags: ["docker"])!
    let data = try SnippetExportCodec.encode(SnippetExportPayload(snippets: [snippet]))
    let restored = try SnippetExportCodec.decode(data)
    #expect(restored.snippets == [snippet])
}

@Test func theWrittenFileIsPlainTextAndSaysSoInsteadOfClaimingEncryption() throws {
    let snippet = Snippet(name: "Clean up", command: "docker system prune -f")!
    let data = try SnippetExportCodec.encode(SnippetExportPayload(snippets: [snippet]))
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("docker system prune -f"))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["encrypted"] as? Bool == false)
}

@Test func probeAcceptsOurFormatAndRejectsASessionExport() throws {
    let ours = try SnippetExportCodec.encode(SnippetExportPayload(snippets: []))
    #expect(try SnippetExportCodec.probe(ours))
    // Eine Login-Set- oder Sitzungsdatei bauen und ablehnen lassen; die
    // genaue Bau-Stelle am Code ablesen, nicht raten.
}

@Test func aFileWithADamagedSnippetFailsTheWholeDecodeRatherThanDroppingItSilently() throws {
    // Snippet.init(from:) verweigert einen mehrzeiligen Befehl.
    // Wörtliches JSON verwenden, nicht neu kodiertes.
}
```

Die letzten beiden **ausformulieren**, sobald du die Bau-Stellen gelesen
hast. Ein Entwurf, der stehen bleibt, ist ein Planfehler.

- [ ] **Schritt 2: Rot, dann der Codec**

Nach dem Muster von `LoginSetExportCodec`: `formatName = "macscp-snippets"`,
`currentVersion = 1`, drei dünne Wrapper über `ExportEnvelopeCodec` mit
`password: nil`.

- [ ] **Schritt 3: Das Passwort pinnen, nicht kommentieren**

Ein Test, der rot wird, wenn jemand später doch ein Passwort durchreicht.
**Wie** du das prüfbar machst, entscheidest du — über das erzeugte
`encrypted`-Feld, über einen Quelltext-Wächter nach dem Muster der
vorhandenen, oder anders. Begründe die Wahl im Bericht; ein Wächter ist
hier ausdrücklich **nicht** die einzige Möglichkeit, und das Projekt hat
davon bereits sieben.

- [ ] **Schritt 4: Volle Suite + Commit**

```bash
swift test
git commit -m "feat(core): give snippets an exchange format without a crypto path"
```

---

### Task 2: Der Import-Planer

**Files:**
- Create: `Sources/macSCPCore/Terminal/SnippetImportPlanner.swift`
- Create: `Tests/macSCPCoreTests/SnippetImportPlannerTests.swift`

**Interfaces:**
- Consumes: `SnippetExportPayload`, `ImportConflictArbiter`, `ImportConflict`
- Produces:
```swift
public struct PlannedSnippet: Equatable, Sendable {
    public var snippet: Snippet
    public var replacesExisting: Bool
}

public struct SnippetImportPlan: Equatable, Sendable {
    public var snippetsToImport: [PlannedSnippet]
    public var skipped: [String]
    public var replaced: [String]
    public var renamed: [String]
    public var cancelled: Bool
}

public enum SnippetImportPlanner {
    public static let kindLabel = "snippet"
    public static func plan(
        existing: [Snippet], incoming: SnippetExportPayload,
        arbiter: ImportConflictArbiter
    ) async -> SnippetImportPlan
}
```

**Lies `LoginSetImportPlanner` vollständig, bevor du anfängst.** Es ist der
Präzedenzfall, und es löst vier Probleme, die dir sonst einzeln begegnen:
der Kollisionsschlüssel ist der **getrimmte, groß-/kleinschreibungs-
unabhängige** Name; `takenNames` wird mit dem Bestand vorbelegt **und bei
jedem vergebenen Namen erweitert**, damit zwei umbenannte Einträge aus
derselben Datei nicht miteinander kollidieren; ein vorhandener Eintrag darf
pro Lauf **höchstens einmal** ersetzt werden; und **Abbruch verwirft den
gesamten Lauf**, nicht nur den Rest. Übernimm alle vier, oder begründe im
Bericht, warum eines für Snippets nicht gilt.

**Warum groß-/kleinschreibungsunabhängig, obwohl Tags case-sensitiv sind:**
ein Snippet-*Name* ist ein Name wie ein Login-Set-Name, kein Tag. Die beiden
Importflüsse sollen sich gleich anfühlen, und das Konflikt-Sheet zeigt beide.

- [ ] **Schritt 1: Die Tests zuerst**

```swift
private func snippet(_ name: String, _ command: String = "echo hi") -> Snippet {
    Snippet(name: name, command: command)!
}

@Test func aFreshNameImportsWithoutAskingAnybody() async {
    let plan = await SnippetImportPlanner.plan(
        existing: [], incoming: SnippetExportPayload(snippets: [snippet("Clean up")]),
        arbiter: arbiterThatMustNotBeAsked())
    #expect(plan.snippetsToImport.map(\.snippet.name) == ["Clean up"])
}

@Test func aNameCollidingOnlyByCaseAndWhitespaceStillCollides() async {
    let plan = await SnippetImportPlanner.plan(
        existing: [snippet("Clean up")],
        incoming: SnippetExportPayload(snippets: [snippet("  clean UP ")]),
        arbiter: arbiterAnswering(.skip))
    #expect(plan.snippetsToImport.isEmpty)
    #expect(plan.skipped == ["clean UP"])
}

@Test func cancellingDiscardsEverythingIncludingWhatWasAlreadyPlanned() async {
    let plan = await SnippetImportPlanner.plan(
        existing: [snippet("B")],
        incoming: SnippetExportPayload(snippets: [snippet("A"), snippet("B")]),
        arbiter: arbiterAnswering(nil))
    #expect(plan.cancelled)
    #expect(plan.snippetsToImport.isEmpty)   // "A" war schon geplant
}

@Test func twoRenamedSnippetsFromOneFileDoNotCollideWithEachOther() async {
    // Zwei eingehende Einträge desselben Namens, beide "umbenennen".
    // Die vergebenen Namen müssen sich unterscheiden.
}
```

Die Arbiter-Helfer und den letzten Test **ausformulieren**, nachdem du
gelesen hast, wie `LoginSetImportPlannerTests` seinen Arbiter baut.

- [ ] **Schritt 2: Rot, dann der Planer**

- [ ] **Schritt 3: Volle Suite + Commit**

```bash
swift test
git commit -m "feat(core): plan a snippet import on the shared conflict arbiter"
```

---

### Task 3: Exportieren aus dem Snippet-Sheet

**Files:**
- Modify: `Sources/MacSCPAppKit/SessionExportImportSheets.swift` (UTType)
- Modify: `Sources/MacSCPAppKit/SnippetsSheet.swift`
- Modify: die vier `Localizable.strings`

**Gemessener Ist-Zustand:** `SnippetsSheet` hat bereits Suchfeld,
Tag-Filterreihe und Fehleranzeige, und liest den Store über `SnippetsLoad`,
das `.loaded` von `.unreadable` unterscheidet. Sieh dir an, wie das
Sitzungs-Sheet seinen `fileExporter` aufruft, und folge dem.

- [ ] **Schritt 1: UTType**

`dev.noix.macscp.snippets`, konform zu `.json`, nach dem Muster der beiden
vorhandenen.

- [ ] **Schritt 2: Der Export**

Ein Knopf im Snippet-Sheet, der die **aktuell sichtbaren** Snippets
exportiert — also das, was Suche und Tag-Filter übrig lassen. Das ist die
Auswahlmechanik, die das Sheet schon hat; ein zweites Auswahl-UI wäre
doppelt.

**Bei `.unreadable` darf kein Export angeboten werden** — eine leere Datei
aus einem unlesbaren Store zu schreiben wäre stiller Datenverlust in
Dateiform. Prüfe, wie das Sheet diesen Zustand heute anzeigt, und schließe
dich an.

Neue Schlüssel (alle vier Kataloge):
- `snippets.export` — „Export…"
- `snippets.export.filename` — Vorschlagsname der Datei

- [ ] **Schritt 3: Katalog-Nachweis + volle Suite + Commit**

```bash
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
swift test
git commit -m "feat(app): export the visible snippets to a file"
```

---

### Task 4: Importieren, mit dem geteilten Konflikt-Sheet

**Files:**
- Modify: `Sources/MacSCPAppKit/SnippetsSheet.swift`
- Modify: die vier `Localizable.strings`
- Modify/Create: Tests

**Gemessener Ist-Zustand:** Das geteilte Konflikt-Sheet aus M19 wird bereits
von zwei Importflüssen benutzt. Finde es, sieh nach, wie der Sitzungs- oder
Login-Set-Import es an den `ImportConflictArbiter` hängt, und mach es
genauso. `SnippetImportPlanner.kindLabel` ist der stabile Bezeichner, den
die App auf eine übersetzte Bezeichnung abbildet — Core kennt keine
Anzeigesprache.

- [ ] **Schritt 1: Der Import**

`fileImporter` → `probe` → `decode` → `plan` → anwenden. Das Anwenden
schreibt über `SnippetStore.save(_:)`; ein `replace` muss den vorhandenen
Eintrag treffen, kein zweites Snippet danebenlegen. **Prüfe am Store, wie
`save` einen vorhandenen Eintrag behandelt**, statt es anzunehmen.

Neue Schlüssel (alle vier Kataloge):
- `snippets.import` — „Import…"
- `snippets.import.error` — Fehlertext für eine unlesbare Datei
- `snippets.import.result %lld` — wie viele importiert wurden
- die übersetzte Bezeichnung für `kindLabel` im Konflikt-Sheet

- [ ] **Schritt 2: Was passiert, wenn die Datei nicht passt**

Eine Sitzungs- oder Login-Set-Datei muss eine verständliche Absage
bekommen, keinen Absturz und keinen leeren Import. `probe` beantwortet das;
verdrahte die Antwort.

- [ ] **Schritt 3: Katalog-Nachweis + volle Suite + Commit**

```bash
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
swift test
git commit -m "feat(app): import snippets through the shared conflict sheet"
```

---

### Task 5: Phasenabschluss

**Files:**
- Create: `docs/superpowers/specs/2026-08-18-p3b-abschluss.md`

- [ ] **Schritt 1: Messen**

```bash
swift test 2>&1 | tail -3
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
MACSCP_VERSION="1.2.0-dev" MACSCP_BUILD="$(git rev-list --count HEAD)" ./scripts/package-app
```

Den Build **im Hintergrund** starten und weiterarbeiten; danach beide
Binaries (`lipo -archs`), beide Ressourcen-Bundles, alle vier `.lproj` und
`plutil -lint` auf die Info.plist prüfen. **Die App wird nicht gestartet.**

- [ ] **Schritt 2: Bericht**

Er nennt die gemessenen Zahlen; was durch Tests gehalten wird und was nur
durch Review; wie das fehlende Passwort gepinnt wurde und warum so; ob der
Planer alle vier Eigenschaften des Login-Set-Präzedenzfalls übernommen hat;
und **ausdrücklich**, dass die GUI nicht gestartet wurde — mit der Liste
dessen, was der Maintainer ansehen muss: Export mit aktivem Filter, Import
einer Datei mit Namenskonflikt, und die Absage bei einer Sitzungsdatei.

- [ ] **Schritt 3: Commit**

```bash
git commit -m "docs(app): record the snippet exchange phase"
```

---

## Selbstreview dieses Plans

**Spec-Abdeckung:** Format ohne Krypto-Pfad → Task 1. Duplikat am Namen auf
dem geteilten Arbiter → Task 2. Eigener UTType, Sheets nach vorhandenem
Muster, Auswahl beim Export → Tasks 3 und 4.

**Platzhalter:** Vier Tests sind bewusst als Entwurf markiert, weil ihre
Fixtures von Bau-Stellen abhängen, die am Code zu lesen sind. Jeder sagt das
ausdrücklich und verlangt Ausformulierung — ein Entwurf, der stehen bleibt,
ist ein Planfehler.

**Typkonsistenz:** `SnippetExportPayload` in den Tasks 1 und 2 gleich;
`SnippetImportPlanner.plan(existing:incoming:arbiter:)` einmal definiert;
`kindLabel` in den Tasks 2 und 4 gleich geschrieben.
