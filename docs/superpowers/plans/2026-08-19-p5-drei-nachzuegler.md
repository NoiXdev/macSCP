# P5 — Drei Nachzügler aus P3

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drei benannte Grenzen aus den P3-Abschlüssen schließen: stiller
Historienverlust im Protokoll, falsche Pluralformen, und ein
Protokolleintrag, der eine Ausführung behauptet, die nie stattfand.

**Architecture:** Drei unabhängige Aufgaben, nach Risiko geordnet.
Task 1 verhindert Datenverlust und geht zuerst.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, Swift Testing.

## Global Constraints

- Code, Kommentare, Bezeichner, Testnamen: **ausschließlich Englisch.**
- Die vier Kataloge (en/de/fr/pl) behalten identische Schlüsselmengen.
- Nie eine Zeilennummer in einen Kommentar schreiben.
- **Kein Kommentar behauptet etwas, das der Code nicht tut.** Und: wer eine
  Zahl oder Aufzählung von Aufrufstellen schreibt, zählt sie nach
  (`CLAUDE.md`, Abschnitt „Kommentare über anderen Code").
- Tests: TDD rot→grün. `swift test` am Ende jeder Task grün.
- Conventional Commits, Footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: Ein kaputter Eintrag darf kein Protokoll löschen (Core)

**Files:**
- Modify: `Sources/macSCPCore/Sessions/AuditLogStore.swift`
- Test: `Tests/macSCPCoreTests/AuditLogStoreDecodingTests.swift` (neu)

**Der Fehler, gemessen:** `loadIfNeeded` dekodiert das ganze Array auf
einmal und schluckt jeden Fehler:

```swift
cache[sessionID] = (try? JSONDecoder().decode([AuditEvent].self, from: data)) ?? []
```

Ein einziger nicht dekodierbarer Eintrag macht daraus `[]`. Der nächste
`append` schreibt die Datei mit **nur dem neuen Eintrag** neu — die ganze
Historie dieser Sitzung ist weg, ohne Meldung.

Erreichbar durch jede Ereignisart, die eine ältere App-Version nicht kennt:
`AuditEvent.Kind` ist ein `String`-Enum, und ein unbekannter `rawValue`
wirft beim Dekodieren. Gilt für jede je hinzugefügte Art
(`crossSessionTransfer`, `plaintextConfirmed`, `snippetExecuted`).

**Zwei Änderungen, beide nötig:**

1. **Elementweise dekodieren.** Ein kaputter Eintrag kostet dann diesen
   einen, nicht die anderen 999.
2. **Ein unvollständig gelesenes Protokoll nicht überschreiben.** Sonst
   schreibt die ältere Version die von der neueren erzeugten Einträge
   beim nächsten `append` endgültig weg. Merke dir pro Sitzung, dass beim
   Laden etwas verworfen wurde, und **überspringe das Persistieren** für
   diese Sitzung, solange das gilt. Der Eintrag landet trotzdem im Cache,
   die laufende Sitzung sieht ihn also — nur die Datei bleibt unangetastet.

- [ ] **Step 1: Write the failing tests**

Neue Datei `Tests/macSCPCoreTests/AuditLogStoreDecodingTests.swift`. Sieh
dir zuerst die vorhandenen `AuditLogStore`-Tests an (Namen und Aufbau des
Temp-Verzeichnisses übernehmen). Die Tests:

1. **Ein unbekannter `kind` kostet nur seinen Eintrag.** Schreibe von Hand
   eine JSON-Datei mit drei Einträgen, davon einer mit
   `"kind": "somethingFromTheFuture"`. `events(for:)` liefert die anderen
   zwei.
2. **Ein teilweise gelesenes Protokoll wird nicht überschrieben.** Nach dem
   Laden aus (1) ein `append`; danach die Datei erneut roh einlesen und
   prüfen, dass der unbekannte Eintrag **noch drinsteht**.
3. **Ein sauberes Protokoll verhält sich unverändert:** laden, anhängen,
   Datei enthält alte plus neue Einträge.

Baue die JSON-Datei aus einem `AuditEvent`-Array, das du kodierst, und
ersetze danach im Text gezielt einen `kind`-Wert — dann bleibt der Rest des
Formats garantiert echt, statt von Hand nachgebaut.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "AuditLogStore"` — Test 1 und 2 rot.

- [ ] **Step 3: Implement**

In `loadIfNeeded`: statt `[AuditEvent].self` in einem Zug ein
`[FailableEvent]` dekodieren, wobei `FailableEvent` ein privater Wrapper
ist, dessen `init(from:)` `try? container.decode(AuditEvent.self)`
speichert. Zähle die `nil`-Fälle. Setze den Cache auf die erfolgreichen und
merke dir bei `nil > 0` die Sitzung in einem `Set<UUID>`
(z. B. `partiallyRead`). In `persist` (bzw. an der Stelle, die schreibt)
früh zurückkehren, wenn die Sitzung dort steht.

Kommentiere die zweite Hälfte so, dass klar wird, **warum** nicht
geschrieben wird — sonst liest sich der frühe Rücksprung wie ein Bug.

- [ ] **Step 4: Run the tests to verify they pass**

`swift test --filter "AuditLogStore"` grün, danach `swift test` gesamt.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/AuditLogStore.swift Tests/macSCPCoreTests/AuditLogStoreDecodingTests.swift
git commit -m "fix(core): keep an audit log a bad entry cannot erase"
```

---

### Task 2: Pluralformen für die beiden Anzahl-Meldungen

**Files:**
- Create: `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.stringsdict`
- Modify: dieselben vier `Localizable.strings`
- Test: `Tests/macSCPAppKitTests/PluralCatalogTests.swift` (neu)

**Warum:** `"%lld snippets will be written to the file."` liest sich bei
einer Auswahl als „1 snippets" — und seit P3h ist die Eins bei Snippets der
**Regelfall** (Zeile auswählen → Exportieren). Betroffen sind zwei
Schlüssel: `snippets.export.confirm.message %lld` und, gleicher Wortlaut,
`logins.export.summary %lld`.

**Warum `.stringsdict` und nicht zwei Strings:** Polnisch hat drei
Pluralkategorien (one/few/many), Französisch behandelt die Null wie den
Singular. Eine Zwei-Wege-Verzweigung im Code wäre für zwei der vier
Sprachen falsch.

**Vorher zu prüfen (nicht raten):**
- `L10n.string` ruft `NSLocalizedString(key, bundle:, value:, comment:)`.
  Bestätige an einem Testfall, dass ein `.stringsdict`-Eintrag darüber
  gefunden wird und `String(format:)` daraus die richtige Form wählt.
- `Package.swift` deklariert `.process("Resources/<lang>.lproj")`. Prüfe,
  dass eine dort abgelegte `.stringsdict` im Bundle landet.
- Die vorhandenen Katalog-Wächter vergleichen `Localizable.strings`. Wenn
  ein Schlüssel dorthin **nicht** mehr gehört, muss er aus allen vier
  gleichermaßen verschwinden, sonst geht die Schlüsselgleichheit kaputt.
  **Empfehlung: den Schlüssel in `.strings` belassen** (die `.stringsdict`
  gewinnt zur Laufzeit) — dann bleiben alle Wächter unberührt und der
  Rückfalltext existiert weiter. Entscheide nach deiner Messung und
  begründe es im Bericht.

- [ ] **Step 1: Write the failing test**

`Tests/macSCPAppKitTests/PluralCatalogTests.swift`: für beide Schlüssel und
alle vier Sprachen die Formen für 1 und für 2 auflösen und prüfen, dass sie
sich unterscheiden. Für Polnisch zusätzlich 5 (Kategorie *many*).

Wie du die Sprache im Test erzwingst, musst du an den vorhandenen
L10n-Tests ablesen — falls sich eine Sprache dort nicht gezielt ansprechen
lässt, prüfe stattdessen die `.stringsdict`-Dateien strukturell (enthält
`NSStringPluralRuleType`, hat für `pl` die Schlüssel `one`/`few`/`many`)
und sag im Bericht, dass die Laufzeitauflösung nicht testbar war.

- [ ] **Step 2: Run it to verify it fails** — die Dateien existieren nicht.

- [ ] **Step 3: Implement**

Vier `.stringsdict` mit je beiden Schlüsseln. Englisch/Deutsch: `one`/`other`.
Französisch: `one` (deckt 0 und 1) / `other`. Polnisch: `one`/`few`/`many`.
Formuliere die Sätze parallel zu den heutigen Fassungen in `.strings`.

- [ ] **Step 4: Run the tests** — Filter grün, dann `swift test` gesamt.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPAppKit/Resources Tests/macSCPAppKitTests/PluralCatalogTests.swift
git commit -m "fix(app): give the two export counts real plural forms"
```

---

### Task 3: Kein Protokolleintrag ohne Zustellung

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TerminalPanelViewModel.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift` (`triggerSnippet`)
- Test: `Tests/macSCPCoreTests/TerminalPanelViewModelTests.swift` (erweitern)

**Der Fehler, gemessen:** `send` ist fire-and-forget. Bei `state ==
.opening` landen die Bytes in `pendingBytes`; scheitert das Öffnen, setzt
der Fehlerzweig `pendingBytes = []` — die Bytes gehen nie raus. Der
Audit-Eintrag „ran snippet …" steht trotzdem, weil `triggerSnippet` direkt
nach dem `send`-Aufruf protokolliert. Realistisch bei einem Konto mit
`ForceCommand`, das den Shell-Kanal ablehnt.

**Entwurf:** `send` bekommt einen optionalen Rückruf, der **nur** feuert,
wenn die Bytes tatsächlich abgingen:

```swift
public func send(_ bytes: [UInt8], onDelivered: (@MainActor () -> Void)? = nil)
```

Der Vorgabewert `nil` lässt jede vorhandene Aufrufstelle unverändert.

- Bei vorhandenem `shell`: nach erfolgreichem `shell.send` feuern. Beim
  heutigen `try?` also nur im Erfolgsfall — der geschluckte Fehler darf
  **nicht** als Zustellung durchgehen.
- Bei `state == .opening`: den Rückruf neben den gepufferten Bytes merken
  (`pendingBytes` ist ein flaches Byte-Array, mehrere Sends verschmelzen —
  du brauchst also eine parallele Liste von Rückrufen) und beim Ausspülen
  feuern.
- Auf **jedem** Weg, der `pendingBytes` verwirft, die gemerkten Rückrufe
  mitverwerfen, ohne sie zu feuern. Zähle diese Stellen nach, statt dich
  auf diese Beschreibung zu verlassen.

In `ContentView.triggerSnippet` wandert die Aufzeichnung in den Rückruf.
Der Kommentar dort behauptet derzeit ausdrücklich das Gegenteil („recorded
after the send CALL … a shell that fails to open drops the bytes and leaves
this entry standing") — er muss mit.

- [ ] **Step 1: Write the failing tests**

In der vorhandenen `TerminalPanelViewModel`-Suite (Aufbau und Fake-Shell von
dort übernehmen):

1. Bei laufender Shell feuert der Rückruf genau einmal.
2. Während `.opening` gepufferte Bytes: Rückruf feuert erst beim Ausspülen.
3. Scheitert das Öffnen, feuert der Rückruf **nie**.

- [ ] **Step 2: Run them to verify they fail** — die Signatur gibt es nicht.

- [ ] **Step 3: Implement** — Core zuerst, dann die App-Seite.

- [ ] **Step 4: Run the tests** — Filter grün, dann `swift test` gesamt.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Presentation/TerminalPanelViewModel.swift Sources/MacSCPAppKit/ContentView.swift Tests/macSCPCoreTests/TerminalPanelViewModelTests.swift
git commit -m "fix(core): report snippet delivery instead of assuming it"
```
