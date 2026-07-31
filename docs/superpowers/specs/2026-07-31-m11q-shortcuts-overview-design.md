# M11q — Tastenkürzel-Übersicht Design

**Status:** freigegeben (Brainstorming 2026-07-31)
**Meilenstein:** M11q
**Sprache:** Design-Doc DE; Code/Kommentare EN; UI lokalisiert EN/DE/FR/PL

## Ziel

Eine **read-only** Übersicht aller Tastenkürzel in einem eigenen
Einstellungen-Tab „Tastenkürzel". Der Nutzer sieht gruppiert, welche Taste
welche Aktion auslöst.

Maintainer-Entscheidung aus dem Brainstorming:
- **Scope:** **nur Übersicht** (read-only). Das Umbelegen bleibt ein eigener,
  späterer Meilenstein — es bräuchte ein neues zentrales Keybinding-Modell und
  einen Umbau aller sechs Definitions-Stellen (SwiftUI-`.keyboardShortcut`,
  AppKit-keyCodes, Sheet-Default-Actions), Konflikterkennung und Persistenz.

## Kontext / Ist-Zustand

Die Kürzel liegen über **sechs Stellen** verstreut; es gibt **keine** zentrale
Registry (Inventur 2026-07-31):
1. **SwiftUI-Menü-Kürzel** in `MacSCPApp.swift` `.commands`: ⌘N (Neuer Tab),
   ⌘W (Tab schließen), ⌘1–9 (Tab wählen), ⌘⇧. (versteckte Dateien),
   ⌘⇧Y (Übertragungen), ⌘⇧K (Known Hosts), ⌘⇧L (Logins), ⌘⇧I (versteckte
   Importe). ⌘, (Einstellungen) ist SwiftUI-Framework-Default (kein expliziter
   Aufruf).
2. **Toolbar** in `ContentView.swift`: ⌘T (Terminal-Toggle-Knopf).
3. **AppKit `KeyboardDrivenTableView`** in `RemoteFileTableView.swift`
   (hartkodierte keyCodes, M11j): ⌘↑ (nach oben), ⌘↓/⌘O (öffnen), ⌘I (Infos &
   Rechte), ⌘⌫ (löschen), ␣ (übertragen), ⏎ (umbenennen), ⎋ (Auswahl aufheben),
   ⌘F (suchen). Auflösung über `BrowserKeyCommand.resolve` (Core), Eignung je
   Auswahl über `BrowserContextMenu.entries`.
4. **`BrowserKeyCommand`** (Core) — nur ein Resolver für die Tabellen-Tasten,
   keine auflistbare Tabelle; deckt Menü/Toolbar/Sheets NICHT ab.
5. **Such-/Pfadzeile** (M11k/M11i): ⌘F-Verdrahtung, Such-Esc/Return,
   Pfad-Vervollständigung (⇥/⇧⇥/⎋/⏎).
6. **Sheet-Default-Actions**: `.keyboardShortcut(.defaultAction)` (⏎ =
   Bestätigen) an vielen Sheets; Esc/⎋ über `role: .cancel`.

**Folge:** Eine Übersicht lässt sich **nicht** aus einer bestehenden Quelle
ableiten — sie ist eine **hand-gepflegte Tabelle**, die diese Stellen spiegelt.

**Settings-Struktur:** `SettingsView.swift` — `TabView` (General/Transfers/
Open with/Terminal), fixe Größe `460×460`. Neue Tabs slotten identisch ein
(`.tabItem { Label(L10n.string(...), systemImage: ...) }`). L10n über
`L10n.string(key, "English default")`.

## Architektur

Rein App-Schicht (Labels laufen über `L10n`, das im App-Layer lebt).

### Katalog-Modell (statisch, hand-gepflegt)

- Neu `Sources/MacSCPApp/KeyboardShortcutsCatalog.swift`:
  ```swift
  /// Read-only overview of the app's keyboard shortcuts (M11q). This is a
  /// HAND-MAINTAINED mirror — there is no central shortcut registry; the
  /// real bindings live across six sites: SwiftUI `.keyboardShortcut` in
  /// `MacSCPApp.swift` menus, the ⌘T toolbar button in `ContentView.swift`,
  /// the hardcoded keyCodes in `KeyboardDrivenTableView`
  /// (`RemoteFileTableView.swift`) resolved via `BrowserKeyCommand`, the
  /// ⌘F / search-Esc wiring, the path-bar completion keys (`PathBar.swift`),
  /// and sheet `.defaultAction`/`.cancel` roles. WHEN A SHORTCUT CHANGES AT
  /// ANY OF THOSE SITES, UPDATE THIS CATALOG TOO.
  enum KeyboardShortcutsCatalog {
      struct Row: Identifiable {
          let id = UUID()           // stable per build; only for ForEach
          let labelKey: String      // L10n key
          let labelDefault: String  // English fallback
          let shortcut: String      // display glyphs, e.g. "⌘⇧Y", "⌘↑", "␣"
      }
      struct Group: Identifiable {
          let id = UUID()
          let titleKey: String
          let titleDefault: String
          let rows: [Row]
      }
      static let groups: [Group] = [ … ]  // see content below
  }
  ```

### Inhalt (Gruppen → Zeilen)

- **Tabs & Fenster** (`settings.shortcuts.group.tabs`): ⌘N Neuer Tab,
  ⌘W Tab schließen, ⌘1–9 Tab wählen, ⌘, Einstellungen.
- **Ansicht** (`settings.shortcuts.group.view`): ⌘⇧. Versteckte Dateien,
  ⌘⇧Y Übertragungen, ⌘T Terminal.
- **Sitzungen** (`settings.shortcuts.group.sessions`): ⌘⇧K Known Hosts,
  ⌘⇧L Logins, ⌘⇧I Versteckte Importe.
- **Dateibrowser** (`settings.shortcuts.group.browser`): ⌘↑ Nach oben,
  ⌘↓ / ⌘O Öffnen, ⌘I Infos & Rechte, ⌘⌫ Löschen, ␣ Übertragen,
  ⏎ Umbenennen, ⎋ Auswahl aufheben, ⌘F Suchen.
- **Pfadzeile** (`settings.shortcuts.group.pathbar`): ⇥ Vervollständigen,
  ⇧⇥ Rückwärts blättern, ⎋ Abbrechen, ⏎ Navigieren.
- **Dialoge** (`settings.shortcuts.group.sheets`): ⏎ Bestätigen, ⎋ Abbrechen.

**Kürzel-Anzeigestrings** (`shortcut`) sind fest und **nicht lokalisiert**
(⌘⇧Y ist universell). Für zusammengesetzte Fälle „⌘↓ / ⌘O" ein einzelner
String. Symbole: ⌘ ⇧ ⌥ ⌃, Pfeile ↑ ↓, ⌫ (Delete), ␣ (Space), ⏎ (Return),
⎋ (Esc), ⇥/⇧⇥ (Tab/Shift-Tab).

**Labels:** über `L10n`, **durchgehend eigene `settings.shortcuts.label.*`-
Keys** (nicht die Menü-Keys wiederverwenden — das entkoppelt die Übersicht
vom Menü-Wording und hält sie selbstbeschreibend). Der Plan enumeriert die
konkrete Key-Liste; alle neuen Keys kommen in alle vier Kataloge.

### UI

- Neu `Sources/MacSCPApp/SettingsView.swift` → `ShortcutsSettingsTab` (privat,
  Muster wie die anderen Tabs): ein `Form { … }` mit einer `Section` je
  `KeyboardShortcutsCatalog.Group` (Header = lokalisierter Gruppentitel), je
  Zeile ein `HStack { Text(label); Spacer(); Text(shortcut) }` — der
  Kürzel-String in `.monospaced()`/`.foregroundStyle(.secondary)`,
  rechtsbündig. Read-only, keine Interaktion.
- In `SettingsView.body`s `TabView` als fünfter Tab „Tastenkürzel"
  (`.tabItem { Label(L10n.string("settings.tab.shortcuts", "Shortcuts"),
  systemImage: "keyboard") }`). Das `Form` scrollt im fixen `460×460`-Fenster;
  falls die Liste unangenehm knapp wird, die Fensterhöhe moderat anheben (der
  Plan prüft das visuell).

## Randfälle / bewusste Nicht-Ziele

- **Kontextabhängige Doppelbelegung ist korrekt** und wird nicht „entdoppelt":
  ⏎ = Umbenennen (Tabelle) vs. Bestätigen (Dialog); ⎋ = Auswahl aufheben vs.
  Abbrechen. Die Übersicht listet sie je Gruppe getrennt.
- **Kein Umbelegen**, keine Konflikterkennung, keine Persistenz — späterer
  Meilenstein.
- **Enabled/Disabled je Auswahl** (z.B. Tabellen-Aktionen nur bei passender
  Auswahl) wird **nicht** dargestellt — die Übersicht zeigt die *mögliche*
  Aktion, nicht den momentanen Zustand.
- **Pflegehinweis:** der Katalog ist ein Spiegel; der Doc-Kommentar nennt die
  sechs Fundstellen, damit Kürzel-Änderungen hier nachgezogen werden.

## Tests

- Reine statische Anzeige-Daten, keine Logik ⇒ **kein App-Test-Target**.
  Verifikation:
  - `swift build` sauber (keine neuen Warnungen).
  - EN/DE/FR/PL-Katalog-Parität + `plutil -lint` OK; `LocalizableStringsTests`
    grün (fängt fehlende Keys / ein falsches Anführungszeichen).
  - Volle `swift test` unverändert grün (keine neue Core-Logik).
  - Lesen/Trace: jede Katalog-Zeile hat einen Label-Key, der in allen vier
    Katalogen existiert; jeder `shortcut`-String ist nicht leer.
- **Runtime-Idle-CPU-Rauchtest** (feste Gewohnheit nach M11n): Dev-Build
  starten, Einstellungen ▸ Tastenkürzel öffnen, Idle-CPU ~0%.
- **Kein Eindeutigkeits-Test** (kontextabhängige Doppelbelegung ist gewollt).

## Dateien

- Neu: `Sources/MacSCPApp/KeyboardShortcutsCatalog.swift`.
- Ändern: `Sources/MacSCPApp/SettingsView.swift` (`ShortcutsSettingsTab` +
  Tab im `TabView`, ggf. Fensterhöhe).
- Ändern: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
  (Tab-Titel, Gruppentitel, Label-Keys — in allen vier Sprachen).

## Global Constraints

- Swift 6, `.swiftLanguageMode(.v5)`, min. macOS 15; kein Core, keine neue
  Logik ⇒ keine neuen Unit-Tests außer dem L10n-Wächter.
- Code/Kommentare EN; UI-Strings über die `.strings`-Kataloge EN/DE/FR/PL,
  typografische Anführungszeichen; **kein ASCII-`"`** in Nicht-EN-Werten.
- Kürzel-Anzeigestrings sind fest und nicht lokalisiert.
- FR/PL neue Strings sind KI-generiert, vor Release muttersprachlich zu prüfen
  (konsistent mit M11p).
- **M11n-Lektion:** neue GUI-Wege vor Auslieferung per Runtime-Idle-CPU-
  Rauchtest prüfen.
- Read-only — kein Umbelegen (eigener späterer Meilenstein).
- Kein Release/Tag ohne ausdrückliche Maintainer-Anordnung.
