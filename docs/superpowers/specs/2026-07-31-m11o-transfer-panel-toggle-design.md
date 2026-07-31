# M11o — Transfer-Leiste ein-/ausblendbar Design

**Status:** freigegeben (Brainstorming 2026-07-31)
**Meilenstein:** M11o
**Sprache:** Design-Doc DE; Code/Kommentare/Strings EN (App-UI lokalisiert EN+DE)

## Ziel

Die Transfer-Leiste (aktive + abgeschlossene Übertragungen) soll per
Toolbar-Icon **neben dem Terminal-Icon** — plus Menüeintrag und Tastenkürzel —
ein- und ausgeblendet werden können. Heute blendet sich die Leiste nur
automatisch ein/aus (an `items.isEmpty`); es gibt keinen manuellen Schalter.

Maintainer-Entscheidungen aus dem Brainstorming:
- **Verhalten:** Auto-Einblenden bleibt; das Icon kann die Leiste zusätzlich
  **auch leer** öffnen (Leerzustand „Keine Übertragungen"), um Abgeschlossene
  zu prüfen/aufzuräumen. Das Icon hat immer einen sichtbaren Effekt.
- **Auto-Einblenden:** **jede** neu eingereihte Übertragung klappt die Leiste
  wieder auf (auch nach manuellem Wegklappen).
- **Bedienelemente:** Toolbar-Icon **+** Menüeintrag **+** Tastenkürzel.
- **Icon:** `tray.full`. **Kürzel:** ⌘⇧Y. **Menü-Ort:** bei den
  Ansichts-Umschaltern (dieselbe Gruppe wie „Versteckte Dateien ein-/ausblenden").
- Das neue Kürzel ist später in die geplante **Tastenkürzel-Übersicht in den
  Einstellungen** (eigener Meilenstein) mit aufzunehmen; diese Übersicht ist
  **nicht** Teil von M11o.

## Kontext / Ist-Zustand

- **`TransferQueueBar`** (`Sources/MacSCPApp/TransferQueueBar.swift`): zeigt
  aktive + abgeschlossene Übertragungen. Wird in `ContentView` als letztes
  Element des Pro-Tab-`VStack(spacing: 0)` gerendert (unten im Fenster,
  volle Breite). **Aktuelle Sichtbarkeitsbedingung:** `if
  viewModel.items.isEmpty { EmptyView() }` — reines Auto-Ausblenden, kein
  Bool. `items` enthält aktive **und** abgeschlossene Einträge; „Aufräumen"
  (`clearCompleted()`) leert sie.
- **Terminal-Toggle (Vorlage):**
  - Toolbar-Icon in `ContentView`s nativer `.toolbar`,
    `ToolbarItemGroup(placement: .primaryAction)` — Kinder: Upload → Download
    → **Terminal-Button** → Disconnect. Die Gruppe rendert **nur bei aktiver
    Session** (`if let session = activeTab.session`). SF-Symbol `"terminal"`,
    `.keyboardShortcut("t", modifiers: .command)`, Hilfetext.
  - Menüeintrag in `MacSCPApp` `.commands`, `CommandMenu("Terminal")`,
    `tabCommands.toggleTerminal?()`, disabled unless
    `tabCommands.isActiveTabConnected`.
  - **Zustand:** `session.terminal.isVisible` (`var` auf
    `TerminalPanelViewModel`), **pro Tab**, **nicht persistiert**.
- **Ansichts-Umschalter-Menügruppe:** `CommandGroup(after: .sidebar)` in
  `MacSCPApp` enthält „Show/Hide Hidden Files" ⌘⇧. — hier kommt der neue
  Eintrag dazu.
- **`TabCommands`** (App-weite Menü-Brücke): `MacSCPApp` baut die Menüs ohne
  `ContentView`-Referenz; `ContentView` setzt die Closures in `.task` und
  spiegelt Zustand (`isActiveTabConnected`) per `.onChange`. Vorlage für einen
  neuen `toggleTransfers`-Closure + gespiegelten Aktiv-Zustand.
- **`SessionTab`** (`@Observable`): hält `session`, `transferQueue:
  TransferQueueViewModel` (pro Tab). Natürlicher Ort für das neue
  Sichtbarkeits-Bool.
- **L10n:** `L10n.string(key, "English default")`; Kataloge
  `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`,
  typografische Anführungszeichen/`…`, kein ASCII-`"` in DE-Werten. Vorlage:
  `"browser.terminalToggle"`, `"browser.terminalToggleHelp"`,
  `"menu.terminal.toggle"`.

## Architektur

Rein App-Schicht; keine Core-Änderung.

### Zustand (pro Tab, nicht persistiert)

- Neues `var transfersPanelVisible = false` auf `SessionTab` — spiegelt das
  Muster von `TerminalPanelViewModel.isVisible` (pro Tab, in-memory, kein
  `SettingsStore`-Key).

### Sichtbarkeit der Leiste

- `TransferQueueBar` wird gerendert, wenn `activeTab.transfersPanelVisible ==
  true` — **unabhängig** vom Inhalt. Die bisherige
  `items.isEmpty`-Selbstausblendung entfällt als alleinige Bedingung.
- Sichtbar **und** leer ⇒ Leerzustand: eine schlanke Zeile „Keine
  Übertragungen" (gleiche Kopfzeilen-Höhe/-Optik wie sonst, nur ohne Liste).
- Der Umschalt-Ort in `ContentView` (letztes `VStack`-Element) bleibt; nur die
  Bedingung wechselt von „nicht leer" auf „Bool sichtbar".

### Auto-Einblenden

- `ContentView` beobachtet `activeTab.transferQueue.items.count` per
  `.onChange`; **steigt** der Wert (neue Übertragung eingereiht), setzt es
  `activeTab.transfersPanelVisible = true`. Das reproduziert das heutige
  „erscheint, sobald etwas übertragen wird" und deckt „jede neue Übertragung
  klappt wieder auf" ab.
- Nur der aktive Tab wird so beobachtet (die Leiste zeigt ohnehin den aktiven
  Tab). Cross-Tab-Ziel-Transfers (M8b) in einen Hintergrund-Tab klappen dessen
  Leiste nicht auf — bewusst außerhalb v1.

### Toggle

- Toolbar-Icon und Menüeintrag rufen dieselbe Aktion: `activeTab
  .transfersPanelVisible.toggle()`.

## UI

### Toolbar-Icon

- Neuer `Button`/`Label` in derselben `ToolbarItemGroup(.primaryAction)`,
  **direkt neben dem Terminal-Button** (verbindungs-gated, erscheint also nur
  bei aktiver Session).
- SF-Symbol **`tray.full`**. Zeigt den Ein-/Aus-Zustand an (aktiv
  hervorgehoben, wenn `activeTab.transfersPanelVisible`), analog zum
  Terminal-Knopf.
- `.keyboardShortcut("y", modifiers: [.command, .shift])`.
- Hilfetext (localized): „Show/hide transfers (⌘⇧Y)".

### Menüeintrag

- In `MacSCPApp` `.commands`, `CommandGroup(after: .sidebar)` (bei „Show/Hide
  Hidden Files"): „Show/Hide Transfers", `tabCommands.toggleTransfers?()`,
  `.keyboardShortcut("y", modifiers: [.command, .shift])`, disabled unless
  `tabCommands.isActiveTabConnected`.
- `TabCommands` bekommt `var toggleTransfers: (() -> Void)?`; `ContentView`
  setzt sie in `.task` auf `{ activeTab.transfersPanelVisible.toggle() }`.

### Lokalisierung (neue Keys, EN + DE)

- `"browser.transfersToggle"` = „Transfers" / „Übertragungen"
- `"browser.transfersToggleHelp"` = „Show/hide transfers (⌘⇧Y)" /
  „Übertragungen ein-/ausblenden (⌘⇧Y)"
- `"menu.transfers.toggle"` = „Show/Hide Transfers" / „Übertragungen
  ein-/ausblenden"
- `"transfers.empty"` = „No transfers" / „Keine Übertragungen"

## Randfälle

- **Nicht verbunden:** Toolbar-Gruppe fehlt → kein Icon; Menüpunkt deaktiviert
  (wie Terminal). Pro-Tab-Zustand belanglos.
- **Tab-Wechsel:** jeder Tab hat sein eigenes `transfersPanelVisible`;
  Umschalten zeigt den Zustand des jeweiligen Tabs.
- **„Aufräumen" bei sichtbarer Leiste:** Liste wird leer, Leiste bleibt im
  Leerzustand sichtbar, bis manuell weggeklappt.
- **Weggeklappt + neue Übertragung:** klappt wieder auf (Auto-Einblenden).
- **Teardown/Disconnect:** Tab wird abgebaut, Zustand verfällt mit ihm.

## Tests

- Reine App-Schicht-Verdrahtung ohne Core-Logik ⇒ wie alle App-only-Meilensteine
  **kein** App-Test-Target. Verifikation:
  - `swift build` sauber (keine neuen Warnungen).
  - EN/DE-Katalog-Parität + `plutil -lint` OK; `LocalizableStringsTests` grün.
  - Volle `swift test` unverändert grün (keine neue/geänderte Core-Logik).
  - Lesen/Trace der Verdrahtung (Toolbar-Button, Menüeintrag+Kürzel,
    `TabCommands`-Closure, `.onChange`-Auto-Einblenden, Sichtbarkeitsbedingung
    + Leerzustand).
- **Runtime-Rauchtest (feste Gewohnheit nach dem M11n-Vorfall):** Dev-Build
  starten und Idle-CPU prüfen (muss ~0% sein), bevor er ausgeliefert wird —
  fängt SwiftUI-Layout-Stürme ab, die Reviews/CI nicht sehen.

## Dateien

- Ändern: `Sources/MacSCPApp/SessionTab.swift` (`transfersPanelVisible`).
- Ändern: `Sources/MacSCPApp/TransferQueueBar.swift` (Leerzustand statt
  `EmptyView` bei leerer Liste — die Sichtbarkeit selbst steuert jetzt
  `ContentView`).
- Ändern: `Sources/MacSCPApp/ContentView.swift` (Sichtbarkeitsbedingung,
  `.onChange`-Auto-Einblenden, Toolbar-Button, `toggleTransfers`-Closure in
  `.task`).
- Ändern: `Sources/MacSCPApp/MacSCPApp.swift` (Menüeintrag + Kürzel).
- Ändern: `Sources/macSCPCore/…`? **Nein** — `TabCommands` lebt in der
  App-Schicht (`MacSCPApp.swift`); dort kommt `toggleTransfers` dazu.
- Ändern: `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`.

## Global Constraints

- Swift 6, `.swiftLanguageMode(.v5)`, min. macOS 15; Swift Testing, TDD wo
  Logik entsteht (hier: keine neue Core-Logik).
- Code/Kommentare/`reason:`-Strings EN; UI-Strings über die `.strings`-Kataloge
  EN-Default + DE, typografische Anführungszeichen; kein ASCII-`"` in DE-Werten.
- Sichtbarkeit ist **pro Tab** (kein app-weites Singleton), spiegelt das
  Terminal-`isVisible`-Muster; nicht persistiert.
- **AppKit-/SwiftUI-Menüleisten-Lektion (M11n):** keine neue `MenuBarExtra`;
  dieses Feature berührt sie nicht. Runtime-Idle-CPU vor Auslieferung prüfen.
- Kein Release/Tag ohne ausdrückliche Maintainer-Anordnung.
