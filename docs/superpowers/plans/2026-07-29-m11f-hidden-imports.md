# M11f — Ausgeblendete Importe: Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Importierte Einträge aus `~/.ssh/config` lassen sich aus der Seitenleiste ausblenden und über ein eigenes Sheet zurückholen — ohne dass die config-Datei je angefasst wird.

**Architecture:** Ein eigener JSON-Store (`hidden-imports.json`) hält die ausgeblendeten Aliase; eine reine Core-Funktion trennt den geladenen config-Bestand in sichtbar / ausgeblendet / verwaist; die App zeigt ein Kontextmenü in der Seitenleiste und ein Verwaltungs-Sheet im Sitzungen-Menü.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-29-m11f-hidden-imports-design.md`

## Global Constraints

- Code und Kommentare **nur Englisch**; Anzeigetexte über die Kataloge
  (`Localizable.strings`, EN Default + DE), niemals hartkodiert.
- `~/.ssh/config` wird **nie** geschrieben — in keiner Variante.
- Gespeichert wird ausschließlich der **Alias**, kein Host/Benutzer/Pfad.
- Alias-Vergleich **exakt**, nicht case-insensitiv.
- Die Ausblend-Liste reist **nicht** im Sessions-Export (M9a) mit.
- Kein Audit-Eintrag (reine Anzeige-Einstellung).
- Tests: Swift Testing, TDD rot→grün. Baseline vor T1: **720 Tests / 52 Suiten**.
- Kein Release, kein Merge auf `main`, kein Tag.

---

### Task 1: HiddenImportStore + reine Trennfunktion (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/HiddenImportStore.swift`
- Test: `Tests/macSCPCoreTests/HiddenImportStoreTests.swift`

**Interfaces:**
- Consumes: `SSHConfigHost` (`Sources/macSCPCore/Sessions/SSHConfigParser.swift`), `SessionStore.defaultDirectory`.
- Produces (T2 verlässt sich wörtlich darauf):
  - `public struct HiddenImportStore: Sendable`
    - `public init(directory: URL)`
    - `public func allHidden() throws -> [String]` — alphabetisch, `localizedCaseInsensitiveCompare`
    - `public func hide(_ alias: String) throws`
    - `public func unhide(_ alias: String) throws`
    - `public func isHidden(_ alias: String) throws -> Bool`
  - `public enum ImportedHostPartition`
    - `public struct Result: Equatable, Sendable { public let visible: [SSHConfigHost]; public let hidden: [SSHConfigHost]; public let orphaned: [String] }`
    - `public static func split(hosts: [SSHConfigHost], hiddenAliases: [String]) -> Result`

- [x] **Step 1: Failing tests schreiben** (`Tests/macSCPCoreTests/HiddenImportStoreTests.swift`)

Struktur wie `LoginSetStoreTests`: je Test ein frisches temporäres Verzeichnis, am Ende aufgeräumt.

Store-Fälle:
- fehlende Datei ⇒ `allHidden()` liefert `[]`, `isHidden("x") == false`
- `hide("a")` dann `allHidden() == ["a"]`, `isHidden("a") == true`
- `hide("a")` zweimal ⇒ weiterhin genau ein Eintrag (idempotent)
- `unhide("a")` ⇒ leer; `unhide("nichtda")` wirft nicht und ändert nichts
- Sortierung: `hide("zulu")`, `hide("alpha")` ⇒ `["alpha", "zulu"]`
- exakter Vergleich: `hide("Prod")` ⇒ `isHidden("prod") == false`
- Vorwärtskompatibilität: eine Datei mit zusätzlichem unbekanntem Feld
  (`{"aliases":["a"],"futureField":42}`) lädt und liefert `["a"]`
- leere Datei-Struktur `{}` ⇒ `[]`

Partition-Fälle (rein, ohne Dateizugriff — Hosts via
`SSHConfigHost(alias:hostName:user:port:identityFile:)`):
- keine ausgeblendeten ⇒ `visible` gleich Eingabe, `hidden`/`orphaned` leer
- ein Alias ausgeblendet ⇒ er fehlt in `visible`, steht in `hidden`
- ausgeblendeter Alias fehlt in den Hosts ⇒ steht in `orphaned`, nicht in `hidden`
- Reihenfolge: `visible` behält die Eingabereihenfolge (Importer sortiert bereits)
- Umbenennungs-Fall: Hosts `["neu"]`, hidden `["alt"]` ⇒ `visible == ["neu"]`, `orphaned == ["alt"]`

- [x] **Step 2: Rot beweisen.** `swift test --filter HiddenImportStore` → FAIL (Typ existiert nicht).

- [x] **Step 3: Implementierung** (`HiddenImportStore.swift`)

Muster wörtlich von `LoginSetStore`: privates `StoreFile: Codable` mit
`var aliases: [String] = []`, `load()` liefert bei fehlender Datei ein
leeres `StoreFile`, `persist` legt das Verzeichnis an und schreibt
`.atomic` mit `outputFormatting = [.prettyPrinted, .sortedKeys]`,
Dateiname `hidden-imports.json`.

`ImportedHostPartition.split` ist pur: ein `Set` der ausgeblendeten Aliase
für die Zugehörigkeitsprüfung, `visible` = Hosts nicht im Set (Reihenfolge
erhalten), `hidden` = Hosts im Set, `orphaned` = Aliase des Sets ohne
passenden Host, alphabetisch sortiert.

Doc-Kommentare (Englisch) müssen festhalten: nur der Alias wird
gespeichert (die Liste soll keine zweite, veraltende Kopie der config
werden); der Vergleich ist exakt, weil ssh `Host`-Aliase als exakte
Zeichenketten behandelt und eine großzügigere Regel Einträge ausblenden
würde, die niemand gemeint hat.

- [x] **Step 4: Grün.** `swift test --filter HiddenImportStore` → PASS, danach volle `swift test` → 720 + neue Tests.

- [x] **Step 5: Commit.** `feat: remember which imported hosts are hidden`

---

### Task 2: Kontextmenü, Sheet, Menüeintrag (App)

**Files:**
- Create: `Sources/MacSCPApp/HiddenImportsSheet.swift`
- Modify: `Sources/MacSCPApp/SessionSidebar.swift` (importedSection), `Sources/MacSCPApp/ContentView.swift` (State, Filterung, Sheet, tabCommands), `Sources/MacSCPApp/MacSCPApp.swift` (Sitzungen-Menü), `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: alles aus Task 1 (`HiddenImportStore`, `ImportedHostPartition`), `SessionStore.defaultDirectory`, das bestehende `tabCommands`-Muster (siehe `showKnownHosts`).
- Produces: nichts für spätere Tasks.

- [x] **Step 1: ContentView — Bestand und Filterung.**
  `@State private var importedHosts` hält weiterhin die SICHTBAREN Hosts
  (die Sidebar bleibt unverändert verdrahtet). Zusätzlich ein State für den
  vollen geladenen Bestand und die ausgeblendeten Aliase. Eine private
  Methode `refreshImportedHosts()` liest den Store, ruft
  `ImportedHostPartition.split` und setzt beide States; `ContentView.task`
  ruft sie statt der heutigen direkten Zuweisung. Nach Ausblenden/
  Einblenden wird sie erneut gerufen — **ohne** die config-Datei neu zu
  lesen (der volle Bestand liegt im State).

- [x] **Step 2: Sidebar-Kontextmenü.**
  In `importedSection` bekommt jede Zeile ein `.contextMenu` mit genau
  einem Eintrag „Ausblenden" (`sidebar.imported.hide`), der einen neuen
  Closure-Parameter `onHideImported: (SSHConfigHost) -> Void` aufruft.
  Kein Bestätigungsdialog. Der bestehende `onTapGesture` und der `.help`
  bleiben unverändert.

- [x] **Step 3: Sheet** (`HiddenImportsSheet.swift`).
  Aufbau und Maße wie `KnownHostsSheet` (dort abschauen, nicht neu
  erfinden): Titel, Liste, Schließen-Knopf mit `.keyboardShortcut(.defaultAction)`,
  `PolishedButtonStyle`. Je Zeile der Alias und „Wieder einblenden".
  Verwaiste Aliase tragen zusätzlich einen Sekundärtext „nicht mehr in
  ~/.ssh/config" und statt dessen „Aus der Liste entfernen" — beide Wege
  rufen `unhide`. Leerzustand: ein Satz, der erklärt, wie Einträge hierher
  kommen (Rechtsklick in der Seitenleiste → Ausblenden).
  Fehler aus dem Store werden angezeigt, nicht verschluckt.

- [x] **Step 4: Menüeintrag.**
  Im `CommandMenu("Sessions")` nach „Logins…" ein Eintrag „Ausgeblendete
  Importe…" mit `.keyboardShortcut("i", modifiers: [.command, .shift])`,
  verdrahtet über `tabCommands.showHiddenImports` nach dem Muster von
  `showKnownHosts` (inkl. Key-Window-Guard in `ContentView.task`).
  Solange etwas ausgeblendet ist, trägt der Titel die Anzahl
  (`menu.hiddenImports %@` mit Format-Argument) — ohne diesen Hinweis wäre
  der Rückweg unauffindbar, sobald die Sektion IMPORTIERT leer ist.
  Denselben Eintrag zusätzlich im `backgroundMenu` der Sidebar (dort
  stehen Known Hosts und Logins bereits).

- [x] **Step 5: EN/DE-Kataloge.**
  Alle neuen Keys in BEIDE App-Kataloge, Englisch zuerst, Deutsch mit
  typografischen Anführungszeichen („…“) — ein ASCII-`"` macht die ganze
  deutsche Datei ungültig (M11d-Blocker). `plutil -lint` auf alle vier
  Kataloge muss OK sein und `LocalizableStringsTests` grün bleiben.

- [x] **Step 6: Verifikation.**
  `swift build` (0 Fehler, keine neuen Warnungen), volle `swift test`,
  `plutil -lint` auf alle vier Kataloge.

- [x] **Step 7: Commit.** `feat: hide imported hosts and manage them in a sheet`

---

### Task 3: Abschluss-Verifikation (Koordinator)

- [x] Gated Suiten am finalen Stand: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → alle grün, zero skips.
- [x] Visueller Smoke — an den Maintainer delegiert (Checkliste: Ausblenden per Rechtsklick wirkt sofort; Menüeintrag trägt die Anzahl; Sheet blendet wieder ein; ein in `~/.ssh/config` umbenannter Alias erscheint als verwaist und lässt sich entfernen; `~/.ssh/config` ist nach allem byte-identisch — vorher/nachher per `md5`).
- [x] Plan-Checkboxen, Ledger, Opus-Final-Review (Package über `git merge-base origin/develop HEAD`), Fix-Runden bis „Yes", Push develop, `gh run watch`, Memory. KEIN Release.
