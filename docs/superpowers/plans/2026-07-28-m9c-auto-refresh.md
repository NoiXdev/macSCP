# M9c — Auto-Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Das Remote-Pane des aktiven Tabs aktualisiert sich alle X Sekunden still (kein Spinner, Selektion bleibt), Default 5 s, einstellbar (Toggle + 2–300 s) im Allgemein-Tab.

**Architecture:** `refreshQuietly()` im Core-VM (bleibt `.loaded`, gemeinsame Filter/Sort-Aufbereitung mit `load()`, Selektions-Beschnitt, Fehler still, Doppel-Guard gegen Races); zwei neue SettingsStore-Properties; der Timer ist ein `.task` im Detail-Baum des aktiven Tabs (stirbt/startet mit der `.id(tab.id)`-Identität aus M8a).

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, SwiftUI `.task` + `Task.sleep`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-28-m9c-auto-refresh-design.md` — bindend. Branch: **develop**.
- Stiller Refresh: Zustand bleibt UNVERÄNDERT `.loaded` (kein Flackern, keine Sperre); Fehler still geschluckt (kein State-Wechsel, keine Meldung); Guard bei nicht-`.loaded` am Anfang UND vor dem Items-Schreiben; Selektion auf Pfade der neuen GEFILTERTEN Liste beschnitten; Filter+Sortierung identisch zu `load()` (EINE gemeinsame private Funktion, kein Duplikat).
- Settings: `autoRefreshEnabled` Default `true`; `autoRefreshIntervalSeconds` Default `5`, geklemmt `2...300` beim Setzen UND Lesen; vorwärtskompatibles Store-Muster wie gehabt.
- Timer NUR im aktiven Tab-Detail (Remote-Pane), nie für Hintergrund-/Formular-Tabs oder das lokale Pane; liest Toggle/Intervall bei jedem Durchlauf frisch.
- Alle neuen UI-Texte EN/DE; Code + Kommentare NUR Englisch; keine neuen Dependencies.
- Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + volle `swift test` nach jedem Task grün (Ausgangslage 445 Tests / 36 Suiten); gated Suiten nur in T3; Tests SYNCHRON im Vordergrund.
- TDD für Core; App-Target untestbar → T2 liefert Build + Verhaltensbeschreibung.

## Schedule

T1 (Core: refreshQuietly + Settings) → T2 (App: Timer + Settings-UI) → T3 Abschluss (Koordinator).

---

### Task 1: refreshQuietly + Settings-Properties (Core)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` (`load()` ~Zeile 50–64 refaktorieren + neue Methode), `Sources/macSCPCore/Settings/SettingsStore.swift` (zwei Properties nach dem `showHiddenFiles`-Muster ~Zeile 177)
- Test: `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift`, `Tests/macSCPCoreTests/SettingsStoreTests.swift` (bestehende Dateien erweitern; Muster dort übernehmen)

**Interfaces:**
- Produces (T2 verlässt sich exakt hierauf):
  - `RemoteBrowserViewModel.refreshQuietly() async` (public)
  - `SettingsStore.autoRefreshEnabled: Bool` (get/set, Default `true`)
  - `SettingsStore.autoRefreshIntervalSeconds: Int` (get/set, Default `5`, geklemmt `2...300` in Setter UND Getter)

- [ ] **Step 1: Failing VM-Tests** (Mock-FS-Muster der Datei übernehmen — Helfer für Tree-Mutation/werfende Mocks existieren; Assertions unverändert lassen):

```swift
    // refreshQuietlyUpdatesItemsWithoutStateFlicker:
    //   load() auf Verzeichnis mit [a.txt]; Mock-Tree um b.txt ergänzen;
    //   refreshQuietly(); #expect(items enthalten a+b sortiert, state == .loaded).
    // refreshQuietlyPrunesVanishedAndHiddenFromSelection:
    //   Verzeichnis [a.txt, b.txt, .hidden]; showHiddenFiles = true; load();
    //   selectedItems = [a, b, .hidden]; Mock: b.txt entfernen; showHiddenFiles = false;
    //   refreshQuietly(); #expect(selectedItems.map(\.name) == ["a.txt"])
    //   (b verschwunden, .hidden nun gefiltert).
    // refreshQuietlySwallowsErrors:
    //   load() ok; Mock ab jetzt werfend (connectionFailed-Form des Mocks);
    //   refreshQuietly(); #expect(state == .loaded, items unverändert).
    // refreshQuietlyBailsWhenNotLoaded:
    //   state == .failed (load gegen werfenden Mock); Mock heilen;
    //   refreshQuietly(); #expect(state bleibt .failed, items leer)
    //   — der stille Refresh repariert NICHT (nur „Erneut versuchen" tut das).
```

- [ ] **Step 2: Rot beweisen.** `swift test --filter RemoteBrowserViewModelTests` → FAIL (Methode fehlt).

- [ ] **Step 3: Implementierung.** In `RemoteBrowserViewModel`:

```swift
    /// Shared display pipeline for `load()` and `refreshQuietly()` — the
    /// hidden-files filter and sort MUST stay identical between the two.
    private func displayItems(from listed: [RemoteFileItem]) -> [RemoteFileItem] {
        let visible = showHiddenFiles
            ? listed
            : listed.filter { !$0.name.hasPrefix(".") }
        return Self.sortedForDisplay(visible)
    }

    /// Silent background refresh (M9c): re-lists the current directory and
    /// swaps the rows WITHOUT touching `state` — no spinner, no hit-test
    /// block, selection preserved (pruned to paths still visible, which
    /// also closes the M7a backlog note about the hidden filter). Errors
    /// are swallowed silently: a dead server must not paint a failure
    /// screen every few seconds — any manual action still surfaces real
    /// problems. Both guards are needed: the state can change while the
    /// listing is in flight (e.g. a manual `load()` or `open()`), and the
    /// late writer must lose.
    public func refreshQuietly() async {
        guard state == .loaded else { return }
        let path = currentPath
        guard let listed = try? await fs.list(path: path) else { return }
        guard state == .loaded, currentPath == path else { return }
        items = displayItems(from: listed)
        let visiblePaths = Set(items.map(\.path))
        selectedItems = selectedItems.filter { visiblePaths.contains($0.path) }
    }
```

`load()` auf `items = displayItems(from: listed)` umstellen (Filter/Sort-Zeilen dort raus). In `SettingsStore` (Keys/Defaults-Einträge nach Datei-Muster ergänzen; `intValue`/`setInt`-Helfer der Datei nachschlagen — analoge Helfer existieren für die Transfer-Settings):

```swift
    /// Auto-refresh of the active tab's remote pane (M9c). Default ON.
    public var autoRefreshEnabled: Bool {
        get { boolValue(for: Keys.autoRefreshEnabled, default: Defaults.autoRefreshEnabled) }
        set { setBool(newValue, for: Keys.autoRefreshEnabled) }
    }

    /// Interval in seconds, clamped to 2...300 on BOTH ends so a hand-edited
    /// settings.json cannot produce SFTP spam or a dead timer.
    public var autoRefreshIntervalSeconds: Int {
        get { min(300, max(2, intValue(for: Keys.autoRefreshIntervalSeconds, default: Defaults.autoRefreshIntervalSeconds))) }
        set { setInt(min(300, max(2, newValue)), for: Keys.autoRefreshIntervalSeconds) }
    }
```

- [ ] **Step 4: Failing Settings-Tests** (Muster der Datei): Defaults (true/5), Setter-Klemmung (1→2, 9999→300), Getter-Klemmung (rohen Wert 0 bzw. 100000 direkt in die JSON-Datei schreiben wie die Vorwärtskompatibilitäts-Tests es tun → Lesen liefert 2 bzw. 300), Roundtrip, alte settings.json ohne die Keys lädt mit Defaults. Rot → implementieren → grün.

- [ ] **Step 5: Volle Suite + Commit.** `swift test` → 445 + ~8 (echte Zahl festhalten).

```bash
git add -A
git commit -m "feat: add a silent remote refresh and its settings"
```

---

### Task 2: Timer im aktiven Tab + Settings-UI (App)

**Files:**
- Modify: `Sources/MacSCPApp/ContentView.swift` (Timer-`.task` im Detail-Baum), `Sources/MacSCPApp/SettingsView.swift` (Allgemein-Tab ~Zeile 41), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: keiner (App-Target; Smoke in T3)

**Interfaces:**
- Consumes: `refreshQuietly()`, `autoRefreshEnabled`, `autoRefreshIntervalSeconds` (T1); die `.id(tab.id)`-Detail-Identität (M8a) in `ContentView.detail`.

**Verhaltens-Anforderungen:**
1. Im Detail-Baum des aktiven Tabs, INNERHALB der `.id(tab.id)`-Gruppe und nur im verbundenen Zweig (`if let session = tab.session`), hängt:

```swift
        .task {
            // Auto-refresh loop (M9c): lives inside the tab's `.id` identity,
            // so switching tabs (or disconnecting) cancels it and the next
            // active tab starts its own. Reads the settings fresh every lap
            // so changes apply without restart; skipped laps just sleep on.
            while !Task.isCancelled {
                let seconds = settingsStore.autoRefreshIntervalSeconds
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, settingsStore.autoRefreshEnabled else { continue }
                await session.remote.refreshQuietly()
            }
        }
```

   (Platzierung: am selben View wie der bestehende `.task { await viewModel.load() }`-Stil — konkret an den Browser-Layout-Container im verbundenen Zweig; NICHT am Formular-Zweig. `refreshQuietly` guarded selbst auf `.loaded` — kein zusätzlicher Zustand nötig.)
2. Settings-UI im Allgemein-Tab unter dem Versteckte-Dateien-Toggle: Toggle (Key `settings.general.autoRefresh` — EN „Auto-refresh remote view", DE „Remote-Ansicht automatisch aktualisieren") + Stepper/TextField-Zeile (Key `settings.general.autoRefreshInterval %lld` — EN „Every %lld seconds", DE „Alle %lld Sekunden"; Formular-Stil der bestehenden Transfer-Settings-Zeilen nachschlagen und übernehmen — dort existiert das Muster Zahlenfeld+Klemmung), Feld disabled wenn Toggle aus.
3. Keys in BEIDEN Katalogen; Grep-Gegenprobe.

- [ ] **Step 1:** Timer. **Step 2:** Settings-UI + Keys. **Step 3:** `swift build` (0 Fehler, keine neuen Warnungen) + volle `swift test` (Stand T1). **Step 4:** Commit `feat: auto-refresh the active remote pane on an interval`.

---

### Task 3: Abschluss-Verifikation (Koordinator)

- [ ] Gated Suiten (Rig aus dem Haupt-Checkout): `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` ⇒ komplett grün, zero skips.
- [ ] Visueller Smoke (Dev-Wrapper; Maintainer testet ggf. selbst): verbinden → per `docker exec` Datei auf dem Server anlegen → erscheint binnen ~5 s OHNE Spinner/Selektionsverlust; Auswahl halten während Refresh; Datei serverseitig löschen → verschwindet aus Liste UND Auswahl; Intervall in den Settings ändern (wirkt ohne Neustart), Toggle aus → Ruhe; Tab-Wechsel: nur aktiver Tab pollt (docker-Logs bzw. zweiter Tab bleibt stale bis Wechsel); Formular-Tab/getrennt: kein Polling; Sheets/Menü offen während Refresh → ungestört; Fehlerfall: Rig stoppen → KEIN Fehler-Screen-Flackern, manuelle Aktion zeigt den Fehler.
- [ ] Plan-Checkboxen, Ledger, Opus-Whole-Branch-Final-Review (Base = Commit vor T1), Fixes, Push develop, CI, Rig `stop`, Memory-Update, Milestone-Zusammenfassung (+ M9d Terminal-Darstellung als Nächstes; Release-Bündelung weiter offen).
