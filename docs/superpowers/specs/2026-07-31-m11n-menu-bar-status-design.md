# M11n — Menüleisten-Status (NSStatusItem/MenuBarExtra) Design

**Status:** freigegeben (Brainstorming 2026-07-31)
**Meilenstein:** M11n
**Sprache:** Design-Doc DE; Code/Kommentare/Strings EN (App-UI lokalisiert EN+DE)

## Ziel

Ein app-weites Menüleisten-Symbol, das außerhalb des Hauptfensters den Status
der aktiven SSH-Verbindungen und laufenden Übertragungen zeigt. Ein Klick
öffnet ein Panel; ein Klick auf eine Verbindung holt das Hauptfenster nach
vorn und aktiviert deren Tab.

Maintainer-Entscheidungen aus dem Brainstorming:
- **Interaktivität:** Anzeige **+ Fenster-holen** (kein Abbrechen/Löschen aus
  dem Panel in v1).
- **Sichtbarkeit:** immer sichtbar, mit **Ausblend-Schalter** in den
  Einstellungen (Default an). Icon signalisiert dezent laufende Übertragung.
- **Transfer-Darstellung:** **pro Verbindung gruppiert**, eine kompakte
  zusammengefasste Zeile je Tab (nicht jede Datei einzeln).
- **Technik:** SwiftUI `MenuBarExtra` im Panel-Stil (`.window`), kein
  AppKit-App-Delegate.

## Kontext / Ist-Zustand

- Einzel-`WindowGroup`, mehrere Tabs (Multi-Window ist v2). Aller
  Verbindungs-/Queue-Zustand lebt **pro Tab**, aggregiert nur in
  `ContentView`s `@State tabsModel: TabsViewModel<SessionTab>`
  (`ContentView.swift`). Es gibt **keinen** app-weiten Registry — Projektregel
  (CLAUDE.md): Session-State gehört in den Fenster-Scope, kein app-weites
  Singleton.
- Kein `NSStatusItem`/`MenuBarExtra` vorhanden — Greenfield.
- Präzedenz für „app-weites Observable, das aus Tab-Zustand gefüttert wird":
  `TabCommands` (`MacSCPApp.swift`) — `MacSCPApp` baut Menüs, hält aber keine
  `ContentView`-Referenz; `ContentView` setzt Closures in `.task` und spiegelt
  Zustand per `.onChange`. `UpdateCheckModel` ist der Präzedenz für ein
  bewusst app-globales `@Observable`.
- Per-Tab-Daten (alle `@Observable`): `SessionTab.displayTitle`/`isConnected`,
  `SessionTab.connectionViewModel.state` (`ConnectionViewModel.State`:
  `.idle`/`.connecting`/`.failed`; „verbunden" = `isConnected`),
  `SessionTab.transferQueue: TransferQueueViewModel`.
- `TransferQueueViewModel` (Core, `@Observable`): `items: [Item]`, `isActive`,
  `pendingCount`, `displayDirection: TransferDirection?`. Per-Item-Fortschritt
  in `Item.Status.running(TransferProgress)`; `TransferProgress` hat
  `bytesTransferred: UInt64`, `totalBytes: UInt64?`, `bytesPerSecond: Double?`,
  `etaSeconds: Double?`, `fraction: Double?`. **Keine** app-weite oder
  queue-weite Gesamtsumme vorhanden — die muss neu abgeleitet werden.
- L10n: `.strings`-Dateien (nicht `.xcstrings`) unter
  `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`; Lookup über
  `L10n.string(key, "English default")` / `L10n.text(...)`. Typografische
  Anführungszeichen `„ "` / `…` in Strings; ein ASCII-`"` in einer deutschen
  Zeile macht den ganzen DE-Katalog ungültig.
- Settings: `SettingsStore` (Core, `@Observable`, JSON, vorwärtskompatibel).
  Bool-Muster: Key in `Keys`, Default in `Defaults`, computed `var` über
  `boolValue(for:default:)`/`setBool(_:for:)` (z.B. `updateCheckEnabled`).

## Architektur

Trennung nach Testbarkeit: die **Aggregations-Logik** (Items eines Tabs zu
einer kompakten Summe verdichten) liegt in **Core** und wird dort per
Unit-Test abgedeckt; die App-Schicht rendert nur und hält die Brücke aktuell.

### Core (neu, getestet)

**`TransferActivitySummary`** — `Sendable` value type:
- `runningCount: Int` — Anzahl laufender Items.
- `pendingCount: Int` — Anzahl wartender (queued, noch nicht laufender) Items.
- `fraction: Double?` — byte-gewichteter Gesamtfortschritt nur über **laufende**
  Items mit bekanntem `totalBytes` (Σ `bytesTransferred` / Σ `totalBytes`);
  `nil`, wenn kein laufendes Item eine Gesamtgröße kennt.
- `bytesPerSecond: Double?` — Summe der `bytesPerSecond` über laufende Items,
  die eine Rate melden; `nil`, wenn keines meldet.
- `direction: TransferDirection?` — aus `displayDirection` der Queue.

**`TransferQueueViewModel.activitySummary: TransferActivitySummary?`** —
computed:
- `nil`, wenn `!isActive` (weder laufend noch wartend).
- sonst gefaltet aus `items` nach obigen Regeln.

### App (Brücke + Rendering)

**`MenuBarStatusModel`** (`@MainActor @Observable`, app-weit, `@State` in
`MacSCPApp`):
- `var tabsSnapshot: [SessionTab]` — von `ContentView` synchron gehalten.
- `var focusTab: (UUID) -> Void` — von `ContentView` in `.task` gesetzt.
- `var showMainWindow: () -> Void` — Fenster nach vorn ohne Tab-Zwang (Fuß-Button).
- abgeleitet: `var anyTransferActive: Bool` = `tabsSnapshot.contains {
  $0.transferQueue.activitySummary?.runningCount ?? 0 > 0 }` (fürs Icon).

**Live-Aktualisierung ohne Extra-Timer:** Panel und Icon sind SwiftUI-Views,
die `tab.displayTitle`, `tab.connectionViewModel.state`, `tab.isConnected`,
`tab.transferQueue.activitySummary` **direkt** lesen. Da alle `@Observable`
sind, aktualisiert SwiftUI-Beobachtung Panel und Icon live während der
Übertragung. Die Brücke muss nur bei Tab-hinzu/-zu/-umsortieren nachziehen
(`.onChange` von `tabsModel.tabs`), nicht pro Fortschritts-Tick.

**`MacSCPApp`** erhält eine zweite Szene neben `WindowGroup`:
```
MenuBarExtra(isInserted: $settingsStore.menuBarEnabled) {
    MenuBarStatusPanel(model: menuBarModel)  // .menuBarExtraStyle(.window)
} label: {
    MenuBarStatusLabel(model: menuBarModel)
}
```
`isInserted` an `settingsStore.menuBarEnabled` gebunden → Ein-/Ausblenden
ohne Neustart.

**`ContentView`** (bestehend, erweitert):
- in `.task`: `menuBarModel.focusTab = { id in … }`,
  `menuBarModel.showMainWindow = { … }`.
- per `.onChange(of: tabsModel.tabs)`: `menuBarModel.tabsSnapshot = tabsModel.tabs`
  (initial auch in `.task` einmal setzen).

**`focusTab(id)`:** `NSApplication.shared.activate(ignoringOtherApps: true)`;
Hauptfenster `makeKeyAndOrderFront(nil)`; `tabsModel.activate(id)`.
**`showMainWindow()`:** identisch ohne den `activate(id)`-Schritt.

## UI

### Menüleisten-Icon (`MenuBarStatusLabel`)

Ein SF-Symbol mit zwei Zuständen, getrieben von `model.anyTransferActive`:
- **Ruhe:** `arrow.up.arrow.down` (normaler Tint).
- **Aktiv:** `arrow.up.arrow.down.circle.fill` (App-Tint). Kein Zappeln/keine
  Animation — nur ruhiger Zustandswechsel.

### Panel (`MenuBarStatusPanel`, `.window`-Stil, Design-Tokens)

- **Kopf:** Titel „macSCP", rechts dezent die Anzahl offener Verbindungen
  (`tabsSnapshot.filter(\.isConnected).count`).
- **Verbindungsliste**, eine Zeile/Karte je Tab in `tabsSnapshot`-Reihenfolge:
  - Zeile 1: `displayTitle` + Status-Indikator:
    - **verbunden** (`isConnected`) — grüner Punkt.
    - **verbindet…** (`state == .connecting`) — gelb/Spinner.
    - **fehlgeschlagen** (`state == .failed`) — roter Punkt.
    - sonst (`.idle`, nicht verbunden) — neutraler Punkt („bereit"/leer).
  - Zeile 2 (nur wenn `activitySummary != nil`): Richtungs-Pfeil (↑/↓ aus
    `direction`) + kompakt: `runningCount>0` → „n überträgt · [x % ·] Rate"
    (Prozent weggelassen, wenn `fraction == nil`), Rate/ETA über
    `TransferRateFormatting.compactLabel(...)`; nur wartend → „n in
    Warteschlange".
  - ganze Zeile klickbar → `model.focusTab(tab.id)`; Hover-Highlight.
- **Leerzustand:** keine Tabs/Verbindungen → ruhige Zeile „Keine aktiven
  Verbindungen".
- **Fuß:** Button „macSCP anzeigen" → `model.showMainWindow()`. Bewusst
  **keine** Beenden-Aktion (App-Menü bleibt der Ort dafür).

### Lokalisierung

Neue Strings EN + DE, typografische Anführungszeichen/`…`:
- Statuslabels: verbunden / verbindet… / fehlgeschlagen / bereit.
- Transfer: „%d überträgt", „%d in Warteschlange", Header-Zähler
  („%d Verbindungen").
- Leerzustand „Keine aktiven Verbindungen".
- Fuß-Button „macSCP anzeigen".
- Settings-Toggle „Menüleisten-Symbol anzeigen".

### Einstellung

`SettingsStore.menuBarEnabled: Bool` (Default **true**), nach dem bestehenden
Bool-Muster (`Keys`/`Defaults`/computed `var` über `boolValue`/`setBool`). In
`SettingsView` ▸ Allgemein ein Toggle „Menüleisten-Symbol anzeigen". Der
`SettingsStore` ist bereits sowohl an `ContentView` als auch an die
`Settings`-Szene durchgereicht; `MacSCPApp` liest ihn für das
`isInserted`-Binding.

## Randfälle

- **Kein Tab / keine Verbindung:** Panel-Leerzustand; Icon bleibt im
  Ruhezustand (Default-an).
- **Tab schließt bei offenem Panel:** `tabsSnapshot` zieht per `.onChange`
  nach; Zeile verschwindet, kein Absturz.
- **`.connecting`/`.failed`:** Statuslabel spiegelt `state`; kein Transfer-Zeile
  für nicht verbundene Tabs.
- **Fenster minimiert/versteckt beim Klick:** `activate` + `makeKeyAndOrderFront`
  holt es nach vorn, dann Tab-Wechsel.
- **Unterbrochene Transfers:** in v1 **nicht** gesondert im Panel markiert — die
  bestehende Resume-Leiste im Fenster bleibt der Ort dafür (YAGNI).

## Tests

- **Core (neu, red→green):** `TransferQueueViewModel.activitySummary` mit
  gesäten Items:
  - leer / `!isActive` ⇒ `nil`.
  - ein laufendes mit bekanntem `totalBytes` ⇒ `runningCount==1`, `fraction`
    == dessen `fraction`, `bytesPerSecond` == dessen Rate.
  - mehrere laufende, alle mit Total ⇒ byte-gewichtete `fraction` (Σ/Σ),
    summierte `bytesPerSecond`.
  - laufendes ohne `totalBytes` ⇒ `fraction == nil`, `runningCount` zählt
    trotzdem.
  - laufendes ohne Rate ⇒ Rate zählt nur die meldenden; keins meldet ⇒ `nil`.
  - nur wartende Items ⇒ `runningCount==0`, `pendingCount>0`, `fraction==nil`.
  - `direction` == `displayDirection`.
- **App:** wie bei allen App-only-Meilensteinen **kein** App-Test-Target — die
  Brücken-Synchronisation (`ContentView` → `menuBarModel`), das
  `isInserted`-Binding und die `focusTab`/`showMainWindow`-Verdrahtung werden
  per Build + Lesen + Trace belegt. Die riskante Logik liegt in Core und ist
  dort getestet.

## Dateien

- Neu Core: `Sources/macSCPCore/Presentation/TransferActivitySummary.swift`
  (oder in `TransferQueueViewModel.swift` einfügen — der computed `var` gehört
  ohnehin dorthin; das Struct bekommt eine eigene kleine Datei).
- Ändern Core: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`
  (`activitySummary`), `Sources/macSCPCore/Settings/SettingsStore.swift`
  (`menuBarEnabled`).
- Neu App: `Sources/MacSCPApp/MenuBarStatusModel.swift`,
  `Sources/MacSCPApp/MenuBarStatusPanel.swift` (Panel + Label + Zeilen-Views).
- Ändern App: `Sources/MacSCPApp/MacSCPApp.swift` (`MenuBarExtra`-Szene +
  `@State menuBarModel`), `Sources/MacSCPApp/ContentView.swift` (Brücke füttern),
  `Sources/MacSCPApp/SettingsView.swift` (Toggle),
  `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`.
- Neu Tests: `Tests/macSCPCoreTests/TransferActivitySummaryTests.swift`.

## Global Constraints

- Swift 6, `.swiftLanguageMode(.v5)`, min. macOS 15; Swift Testing, TDD
  red→green.
- Code/Kommentare/`reason:`-Strings EN; UI-Strings über die `.strings`-Kataloge
  EN-Default + DE, typografische Anführungszeichen; kein ASCII-`"` in DE-Werten.
- Keine app-weiten Singletons für Session-State: der Menüleisten-Eintrag hält
  **keinen** eigenen Verbindungszustand, sondern spiegelt nur `tabsModel.tabs`
  über die `TabCommands`-artige Brücke.
- Kein Release/Tag ohne ausdrückliche Maintainer-Anordnung.
