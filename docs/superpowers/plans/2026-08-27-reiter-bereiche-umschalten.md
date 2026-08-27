# Bereiche aus dem Reiter-Menü umschalten — Umsetzungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Das Reiter-Kontextmenü blendet Dateien und Terminal ein und aus, und bietet das externe Terminal als eigenen Weg an.

**Grundlage:** `docs/superpowers/specs/2026-08-27-reiter-bereiche-umschalten-design.md`

**Architektur:** Kein neues Modell. Die Zustände kommen aus `PaneToggleState`, das die Werkzeugleiste bereits liest; `TabContextMenu.entries` bekommt sie als fertige Antwort herein, so wie es `supportsShell` schon bekommt. Der einseitige Eintrag „Terminal öffnen" entfällt.

**Reihenfolge:** erst der Wert in Core, dann die Verdrahtung.

## Global Constraints

- Code, Kommentare, Bezeichner, Testnamen, Commit-Messages: **nur Englisch**;
  Katalogwerte sind Übersetzungen, das Deutsche duzt.
- Conventional Commits; Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Alle vier Kataloge** (`en`, `de`, `fr`, `pl` unter
  `Sources/MacSCPAppKit/Resources/`), gleiche Schlüsselmengen.
- **Nur zeigen, was möglich ist** — kein `.disabled`, kein Ausgrauen im
  Reiter-Menü. Ein nicht anwendbarer Eintrag **fehlt** (Maintainer, 2026-08-27).
- **`terminalTarget` bleibt außen vor.** Die Bereichsumschalter meinen immer
  den eingebauten Bereich, „Externes Terminal öffnen" meint immer extern —
  genau wie die zwei Einträge des „Terminal"-Menüs, die sich bewusst nie mit
  der Einstellung ändern, „sodass ein Umstellen nie eine Fähigkeit wegnimmt".
- **`TerminalPanelViewModel.toggle()` bleibt der einzige Schreibweg** für die
  Terminal-Sichtbarkeit; er besitzt den Lebenszyklus der Shell. Kein nackter
  Bool-Schreibvorgang.
- Alle sechs Targets stehen auf `.swiftLanguageMode(.v6)`; **CI wird rot, sobald
  die Zahl eindeutiger Warnorte über 1 liegt.**
- **Keine Zeilennummern, keine Ortsangaben in Kommentaren.** Jede Zahl und jede
  Aufzählung wird in dem Durchgang gezählt, der sie schreibt.
- Die App wird nicht gestartet, nichts gepusht.

---

### Task 1: Die Einträge in Core

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TabContextMenu.swift`
- Modify: `Sources/macSCPCore/Presentation/PaneVisibility.swift` (nur ein Kommentar)
- Test: `Tests/macSCPCoreTests/TabContextMenuTests.swift`

**Interfaces:**
- Consumes: `PaneToggle` (`.files`/`.terminal`) und `PaneToggleState`
  (`isOn`, `isEnabled`) aus `PaneVisibility.swift`.
- Produces: `TabMenuEntry.pane(PaneToggle, PaneAction)` und
  `TabMenuEntry.openExternalTerminal`; `TabMenuEntry.openTerminal` **entfällt**.
  Neue Signatur
  `entries(atIndex:ofTabCount:supportsShell:isAdHoc:isConnected:filesToggle:terminalToggle:)`.
  Task 2 rendert daraus.

**Der gemessene Ist-Zustand:** `entries` nimmt heute fünf Fakten und hängt
`.openTerminal` an `supportsShell && isConnected`. `PaneToggleState` liefert
`isOn` und `isEnabled`; `toggleState(for:hasShell:)` faltet `hasShell` bereits
ein und meldet für die **einzige noch sichtbare** Hälfte `isEnabled == false`.

- [ ] **Step 1: Den Test zuerst schreiben.** In die bestehende Suite ergänzen:

```swift
    private static let bothVisible = PaneToggleState(isOn: true, isEnabled: true)
    private static let visibleAndLocked = PaneToggleState(isOn: true, isEnabled: false)
    private static let hidden = PaneToggleState(isOn: false, isEnabled: true)

    @Test func aVisiblePaneOffersHidingItAndAHiddenOneOffersShowing() {
        let entries = TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: true, isAdHoc: false, isConnected: true,
            filesToggle: Self.bothVisible, terminalToggle: Self.hidden)
        #expect(entries.contains(.pane(.files, .hide)))
        #expect(entries.contains(.pane(.terminal, .show)))
    }

    @Test func theOnlyVisibleHalfOffersNoEntryAtAll() {
        let entries = TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: true, isAdHoc: false, isConnected: true,
            filesToggle: Self.visibleAndLocked, terminalToggle: Self.hidden)
        #expect(!entries.contains(.pane(.files, .hide)))
        #expect(!entries.contains(.pane(.files, .show)))
        #expect(entries.contains(.pane(.terminal, .show)))
    }

    @Test func aDisconnectedTabOffersNoPaneEntries() {
        let entries = TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: true, isAdHoc: false, isConnected: false,
            filesToggle: Self.bothVisible, terminalToggle: Self.bothVisible)
        #expect(!entries.contains(.pane(.files, .hide)))
        #expect(!entries.contains(.pane(.terminal, .hide)))
        #expect(!entries.contains(.openExternalTerminal))
    }

    @Test func theExternalTerminalNeedsAShellAndAConnection() {
        #expect(TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: true, isAdHoc: false, isConnected: true,
            filesToggle: Self.bothVisible, terminalToggle: Self.hidden)
            .contains(.openExternalTerminal))
        #expect(!TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: false, isAdHoc: false, isConnected: true,
            filesToggle: Self.bothVisible, terminalToggle: Self.hidden)
            .contains(.openExternalTerminal))
    }

    @Test func bothHalvesVisibleOffersBothHidingEntries() {
        let entries = TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: true, isAdHoc: false, isConnected: true,
            filesToggle: Self.bothVisible, terminalToggle: Self.bothVisible)
        #expect(entries.contains(.pane(.files, .hide)))
        #expect(entries.contains(.pane(.terminal, .hide)))
    }

    @Test func theOrderIsFixedRegardlessOfWhichEntriesApply() {
        #expect(TabContextMenu.entries(
            atIndex: 1, ofTabCount: 3,
            supportsShell: true, isAdHoc: true, isConnected: true,
            filesToggle: Self.bothVisible, terminalToggle: Self.hidden)
            == [.close, .closeOthers, .move(.left), .move(.right),
                .pane(.files, .hide), .pane(.terminal, .show),
                .openExternalTerminal, .saveAsSession])
    }
```

  **Der bestehende Test gleichen Namens (`theOrderIsFixed…`) wird ersetzt**, weil
  seine erwartete Liste `.openTerminal` enthält; ebenso die beiden bestehenden
  Tests, die `.openTerminal` prüfen. Zähle beim Ersetzen, wie viele Tests die
  Suite danach hat, falls du die Zahl irgendwo hinschreibst.

- [ ] **Step 2: Rot laufen lassen.**

Run: `swift test --filter TabContextMenu`
Erwartet: FAIL — `type 'TabMenuEntry' has no member 'pane'`.

- [ ] **Step 3: Umsetzen.** In `TabContextMenu.swift`:

```swift
/// Which way a pane entry points: the action the user can take right now.
/// One entry per pane with a changing label, never two entries of which one
/// is dead — this menu omits what does not apply instead of greying it.
public enum PaneAction: Equatable, Sendable {
    case show
    case hide
}
```

  In `TabMenuEntry`: `case openTerminal` **entfernen**, dafür

```swift
    /// Show or hide one of the window's two halves. Present only while the
    /// pane's own `PaneToggleState` reports `isEnabled` — which is false for
    /// the last visible half, so no entry here can empty the window.
    /// Always the built-in terminal; `SettingsStore.terminalTarget` has no
    /// say, for the same reason the Terminal menu's entries ignore it.
    case pane(PaneToggle, PaneAction)
    /// Open this session's shell in an external terminal. Always external,
    /// never the built-in pane. Needs a shell and a live connection.
    case openExternalTerminal
```

  Und in `entries`, an die Stelle der `.openTerminal`-Zeile:

```swift
        if isConnected && filesToggle.isEnabled {
            entries.append(.pane(.files, filesToggle.isOn ? .hide : .show))
        }
        if isConnected && terminalToggle.isEnabled {
            entries.append(.pane(.terminal, terminalToggle.isOn ? .hide : .show))
        }
        if supportsShell && isConnected { entries.append(.openExternalTerminal) }
```

  Die Signatur um die zwei Parameter erweitern (`filesToggle:`, `terminalToggle:`
  am Ende) und den Doku-Kommentar der Funktion nachziehen: er zählt heute
  „drei Fakten" auf — **zähle nach, was danach stimmt.**

- [ ] **Step 4: Den veralteten Kommentar richtigstellen.** In
  `PaneVisibility.swift` steht:

  > This type only decides WHICH halves are visible. It says nothing about
  > `TerminalPanelViewModel.isVisible`, the existing terminal-only toggle —
  > reconciling the two is a later task's decision.

  Das ist überholt: `SessionTab.effectivePaneVisibility(terminalIsVisible:hasShell:)`
  ist der eine Zusammenbau-Punkt und sein eigener Kommentar sagt, es dürfe nur
  einen geben. Schreib das dort hin, statt eine erledigte Aufgabe zu vertagen.

- [ ] **Step 5: Grün laufen lassen.** `swift test --filter TabContextMenu`
- [ ] **Step 6:** Volle Suite grün, keine neue Warnung.
- [ ] **Step 7: Commit** — `feat(tabs): let the menu offer both panes, not just the terminal`

---

### Task 2: Verdrahten

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView+Lifecycle.swift`,
  `Sources/MacSCPAppKit/TabStripView.swift`
- Modify: alle vier `Localizable.strings`
- Test: `Tests/macSCPAppKitTests/TabContextMenuWiringGuardTests.swift`

**Interfaces:**
- Consumes: alles aus Task 1.

**Der gemessene Ist-Zustand:** `tabMenuEntries(for:)` schlägt den Index nach,
liest `BackendDescriptor…capabilities` und ruft `TabContextMenu.entries`.
`handleTabMenuEntry` verzweigt über die Fälle; `openTerminalPane(in:)` blendet
**nur ein** und kehrt zurück, wenn das Terminal schon sichtbar ist.
`SessionTab.paneToggleState(for:terminalIsVisible:hasShell:)` liefert genau
das, was Task 1 braucht — dieselbe Funktion, aus der die Werkzeugleiste liest.

- [ ] **Step 1: Die Fakten beschaffen.** `tabMenuEntries(for:)` reicht die zwei
  Zustände nach, aus `paneToggleState(for:terminalIsVisible:hasShell:)`.
  **Nicht selbst zusammenbauen** — der Quelltext sagt an
  `effectivePaneVisibility`, dass es nur einen Zusammenbau-Punkt geben darf,
  und ein zweiter hier wäre genau der Fehler, den dieser Vorgang vermeiden soll.
- [ ] **Step 2: Die Titel.** Fünf Schlüssel in alle vier Kataloge:
  `tabs.menu.showFiles`, `tabs.menu.hideFiles`, `tabs.menu.showTerminal`,
  `tabs.menu.hideTerminal`, `tabs.menu.openExternalTerminal`. Der alte Schlüssel
  `tabs.menu.openTerminal` **entfällt in allen vier**. Deutsch duzt.
- [ ] **Step 3: Die Handler.**
  - `.pane(.files, _)` ruft den bestehenden Weg für einen Klick auf den
    Datei-Umschalter — such ihn über `applyingClick(on: .files, …)`, statt einen
    zweiten zu bauen.
  - `.pane(.terminal, _)` ruft `session.terminal.toggle()` und danach
    `persistActivePaneVisibility()`, wie `openTerminalPane` es heute schon tut
    — aber **ohne** dessen `guard !session.terminal.isVisible`, denn genau der
    machte den Eintrag einseitig.
  - `.openExternalTerminal` ruft `requestExternalTerminal(for: tab)`.
  - `openTerminalPane(in:)` entfällt, sofern kein anderer Aufrufer bleibt —
    **zähle die Aufrufer, bevor du löschst.**
- [ ] **Step 4: Den Wächter nachziehen.** `TabContextMenuWiringGuardTests`
  verankert die Menü-Einträge und den Weiterreich-Weg wörtlich. Der Wechsel von
  `.openTerminal` auf zwei neue Fälle wird ihn rot machen — **das ist beabsichtigt
  und der Beleg, dass er greift.** Zieh ihn nach und prüfe danach, ob sein
  Abschnitt „What this guard does NOT catch" noch stimmt.
- [ ] **Step 5:** Volle Suite grün, keine neue Warnung.
- [ ] **Step 6: Commit** — `feat(tabs): switch panes from the tab menu`

---

## Was ausdrücklich nicht dazugehört

- Keine Änderung an `terminalTarget`, an der Werkzeugleiste oder am
  „Terminal"-Menü der Menüleiste.
- Kein Ausgrauen im Reiter-Menü.
- Keine Änderung daran, wie `TerminalPanelViewModel.isVisible` geschrieben wird.
- Keine Antwort auf I5 (Speichern überschreibt namensgleich).
