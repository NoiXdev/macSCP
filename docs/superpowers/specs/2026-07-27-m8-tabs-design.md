# M8 — Tabs für mehrere aktive Sessions (Design)

Datum: 2026-07-27 · Status: vom Maintainer freigegeben (Blöcke 1+2 einzeln bestätigt) ·
Mockup: `docs/design/assets/m8-tabs-mockup.html`

## Ziel

Ein Fenster hält mehrere gleichzeitig aktive SSH-Sessions als Tabs (WinSCP-Modell).
Hintergrund-Tabs laufen vollständig weiter (Transfers, Shell, Edit-Watcher). Das
Kontextmenü überträgt Auswahlen in andere Sessions — inklusive direktem
Server-zu-Server-Stream durch die App.

**Maintainer-Entscheidungen (2026-07-27):**

1. Neue Tabs entstehen über BEIDES: ⊕-Tab (leerer Tab = Verbindungsformular) UND
   Sidebar-Klick, der bei verbundenem aktivem Tab einen neuen Tab öffnet.
2. „Übertragen zu Session xy" aus beiden Panes, inkl. Remote→Remote direkt
   (Stream durch die App, keine Zwischendatei).
3. Hintergrund-Tabs laufen weiter; Tabs tragen Aktivitäts-/Achtung-Indikatoren;
   Schließen mit aktiven Transfers fragt nach.
4. Bandbreiten-Limits gelten app-global über alle Tabs (ein Token-Bucket pro
   Richtung app-weit).
5. Ansatz A: eigener Tab-Strip im Fenster (EINE Sidebar; native Fenster-Tabs
   verworfen). Release v1.1.0 erst NACH M8 (bündelt M7+M8).

**Architektur-Invariante präzisiert:** „eine SSH-Verbindung pro **Tab**; die
Tab-Kollektion gehört dem Fenster." Multi-Fenster bleibt v2-offen; nichts wird
App-Singleton außer den bereits app-weiten Objekten (SettingsStore, neu: die
beiden Bandbreiten-Buckets).

## Aufteilung

- **M8a — Tab-Infrastruktur:** TabsViewModel (Core), Tab-Strip (UI), Pro-Tab-
  Sessions/Queues/Bridges, app-globale Buckets, Fenster-/Sidebar-/Shortcut-
  Verhalten, Indikatoren, Schließen-Semantik.
- **M8b — Cross-Session-Transfers:** Übertragen-Submenü mit Ziel-Sessions,
  Remote→Remote, zweiter Rig-Container, Schließen-Warnung für Ziel-Tabs.

Jeder Teil ist für sich lauffähig; eigene Pläne, gemeinsames Spec (dieses).

---

## 1. State-Modell (M8a)

### 1.1 SessionTab

`ContentView` ersetzt `session: BrowserSession?` durch:

- `tabs: [SessionTab]` (mindestens 1 Element, Reihenfolge = Strip-Reihenfolge)
- `activeTabID: UUID?` (immer auf ein existierendes Element gerichtet)

`SessionTab` (App-Layer, Referenztyp `@MainActor @Observable final class`) bündelt
den bisher fensterweiten Zustand PRO TAB:

- `id: UUID` (Tab-Identität; unabhängig von `BrowserSession.id`)
- `connectionViewModel: ConnectionViewModel` (Formular-Zustand leerer Tabs;
  jeder Tab hat sein eigenes)
- `session: BrowserSession?` (nil = Formular-Tab)
- `transferQueue: TransferQueueViewModel` (pro Tab; überlebt Disconnect im Tab —
  Resume-Banner-Verhalten wie heute, nur tab-lokal)
- `conflictBridge: ConflictPromptBridge` (pro Tab)
- `titleName: String?` (bisheriges `sessionTitleName`, pro Tab)
- `editErrorMessage: String?` (pro Tab)
- `activeStoredSessionID: UUID?` (bisheriges `activeSessionID`, pro Tab —
  die Sidebar highlightet den Wert des AKTIVEN Tabs)
- `isReconnecting: Bool` (pro Tab; sperrt nur die eigenen Verbindungswege)

`BrowserSession` selbst bleibt unverändert (id/localFS/remoteFS/local/remote/
terminal/editManager).

### 1.2 TabsViewModel (Core, testbar)

Die Tab-VERWALTUNGSREGELN liegen als generische Zustandsmaschine in
`Sources/macSCPCore/Presentation/TabsViewModel.swift` — ohne UI- und ohne
SSH-Abhängigkeit (Lektion M7a: das App-Target ist untestbar). Generisch über das
Payload (`TabsViewModel<Payload>` oder Protokoll-basiert), die App instanziiert
es mit `SessionTab`.

Regeln (alle unit-getestet):

- `addTab()` → neuer Tab ans Ende, wird aktiv (⊕ / ⌘N).
- `closeTab(id:)` → entfernt; war er aktiv, wird der RECHTE Nachbar aktiv, sonst
  der linke (Browser-Konvention); der letzte Tab ist NICHT entfernbar (die App
  interpretiert „⌘W auf letztem unverbundenen Tab" als Fenster-Schließen).
- `activate(id:)`; `activeTab`-Accessor.
- „Ziel-Tab für Sidebar-Connect": aktiver Tab unverbunden → dieser Tab; aktiver
  Tab verbunden → `addTab()`. (Das Prädikat „unverbunden" liefert die App über
  eine Closure/Protokoll-Anforderung, damit die Regel testbar bleibt.)

### 1.3 Rendering & Lebenszyklus

- Nur der AKTIVE Tab ist im View-Baum gemountet. Hintergrund-Tabs leben als
  State weiter — ihre Queues, Shells und Watcher laufen ohne Zutun.
- Terminal-Remount beim Tab-Wechsel läuft über den vorhandenen
  256-KiB-Replay-Puffer (M5a); die Panes remounten über die bestehenden VMs.
- Konflikt-Sheets hängen am Tab-Inhalt: Ein Konflikt in einem Hintergrund-Tab
  parkt den Transfer (FIFOGate, vorhanden) und setzt den Achtung-Indikator; das
  Sheet erscheint erst beim Wechsel in den Tab. Kein Sheet unterbricht je den
  aktiven Tab wegen eines fremden Tabs.
- Teardown beim Tab-Schließen = heutige `teardownSession`-Reihenfolge, tab-lokal:
  `conflictBridge.dismiss()` → `queue.cancelAll()` → `editManager.stopAll()` →
  `terminal.shutdown()` → `remote.disconnect()`.

## 2. Tab-Strip (M8a, UI)

Maße/Optik laut Mockup (`m8-tabs-mockup.html`), Design-Tokens vorhanden:

- Strip 30 pt hoch, zwischen Toolbar und Paneheads, Hairline unten, Fläche
  `paper`.
- Aktiver Tab: Fläche `card`, Titel 12 pt semibold `ink`, 2-pt-Unterstreichung
  `remoteBlue` an der Unterkante. Inaktive: `inkSecondary`, Trenner-Hairline
  rechts. Max-Breite ~200 pt, Titel mit Ellipsis.
- ✕ (15 pt Hit-Area) nur bei Hover des Tabs sichtbar; ⊕ rechts (30 pt).
- Formular-Tab-Titel: „Neue Verbindung" (lokalisiert), kursiv, `inkTertiary`.
- Indikator (7-pt-Punkt, links vom Titel): Bernstein = Upload aktiv, Blau =
  Download aktiv (bei beidem: Richtung des zuletzt GESTARTETEN Items), dezentes
  Pulsieren; Rot statisch = Achtung (Konflikt wartet ODER fehlgeschlagene
  Transfers seit letztem Besuch); kein Punkt = idle. Priorität: Rot > aktiv.
  a11y: Indikator-Zustand als accessibilityValue am Tab.
- **Jungfräulicher Zustand** (genau ein unverbundener Formular-Tab): Strip
  unsichtbar — Startbild identisch zu heute.

## 3. Fenster, Sidebar, Shortcuts (M8a)

- **Fenstergröße:** Die aktive Grow/Shrink-Logik (700×460 ↔ ≥930×620) gilt nur
  im Ein-Tab-Zustand. Ab dem zweiten Tab ODER sobald der einzige Tab verbunden
  ist, bleibt das Fenster auf Browser-Größe; ein Formular-Tab zeigt das Formular
  im großen Fenster oben ausgerichtet. Schrumpfen erst, wenn wieder genau ein
  unverbundener Tab übrig ist. `lastBrowserSize` bleibt fensterweit.
- **Fenstertitel:** „macSCP — ‹titleName des aktiven Tabs›", sonst „macSCP".
- **Toolbar** wirkt auf den aktiven Tab (Upload/Download/⌘T/Trennen).
  „Trennen" macht den Tab zum Formular-Tab (Queue + Unterbrochene bleiben).
- **Sidebar (EINE, unverändert links):**
  - Session-Klick: aktiver Tab unverbunden → Connect IM Tab (heutiges
    Verhalten); verbunden → neuer Tab + Connect dort.
  - Die pauschale Sperre `sidebarDisabled` entfällt; gesperrt sind Klicks nur,
    solange der Tab, der den Connect ausführen würde, selbst `isReconnecting`/
    connecting ist. Laufende Transfers sperren die Sidebar NICHT mehr (ein
    Klick zerstört keine Session mehr).
  - „Bearbeiten…": aktiver Tab unverbunden → Formular im Tab; sonst neuer
    Formular-Tab mit Edit-Kontext.
  - Highlight = `activeStoredSessionID` des aktiven Tabs.
  - Löschen einer gespeicherten Session lässt verbundene Tabs unberührt (nur
    Highlight-Reset wie heute).
- **Shortcuts:** ⌘T Terminal (bleibt). ⌘N neuer Tab (Multi-Fenster ist v2).
  ⌘W schließt den aktiven Tab; ist er der letzte UND unverbunden, schließt es
  das Fenster (Verhaltensänderung dokumentieren). ⌃Tab/⌃⇧Tab Zyklus, ⌘1–⌘9
  Direktwahl.
- **Settings-Verkabelung:** `showHiddenFiles` wirkt auf ALLE Tabs (Filter +
  Refresh je Session). `maxConcurrentTransfers` wirkt pro Tab-Queue (bewusst:
  Pro-Verbindung-Limit, Channel-Multiplex). Bandbreite: siehe 4.

## 4. App-globale Bandbreiten-Buckets (M8a)

- Die beiden Richtungs-Buckets (`BandwidthBucket` Up/Down) werden EINMAL in
  `MacSCPApp` erzeugt (neben dem `SettingsStore`) und in jede Tab-Queue
  injiziert. `TransferQueueViewModel` erhält dafür einen Init-/Injektionsweg
  für extern verwaltete Buckets; die heutige interne Erzeugung über
  `uploadLimitBytesPerSec`-didSet entfällt zugunsten der injizierten Instanzen.
- Limit-Änderungen re-raten die LEBENDEN Instanzen (Generation-Counter aus
  M6b bleibt); Semantik: 300 KB/s = 300 über alle Tabs zusammen (geteilt, wie
  der M6a-Live-Beweis, nur app-weit).
- **Remote→Remote zählt in BEIDEN Buckets** (real Down- + Upload der Leitung):
  Der Engine-Aufruf bekommt für solche Transfers beide Buckets; gedrosselt wird
  auf das Minimum beider Freigaben. (Erweiterung `copyFile(throttle:)` um einen
  zweiten optionalen Bucket; Reihenfolge der Token-Entnahme deadlockfrei —
  erst warten auf den knapperen, dann nachziehen, Details im Plan.)
- 0 = aus (wie heute); Mischbetrieb (ein Limit gesetzt, eins aus) unverändert.

## 5. Cross-Session-Transfers (M8b)

### 5.1 Semantik

- Das Kontextmenü-„Übertragen" wird zum SUBMENÜ: erster Eintrag wie bisher
  („Zum anderen Pane" — Wortlaut heute), dann Separator, dann JE ein Eintrag
  pro ANDEREM verbundenen Tab: „Zu ‚‹titleName›'" mit dem aktuellen Remote-Pfad
  des Ziel-Tabs als Untertitel/Hinweis. Formular-Tabs und der eigene Tab
  erscheinen NIE. Kein anderer verbundener Tab → Submenü enthält nur den
  bisherigen Eintrag (Optik wie heute).
- Ziel ist IMMER das Remote des Ziel-Tabs, Zielverzeichnis = dessen
  `remote.currentPath` zum Zeitpunkt des Klicks.
  - Lokale Auswahl → Upload zum Ziel-Remote.
  - Remote-Auswahl → direkter Remote→Remote-Stream durch die App (Chunk-weise,
    keine Zwischendatei; Durchsatz = min aus Download A und Upload B).
- Symlinks: wie bisher von Übertragungen ausgeschlossen (Menü-Regeln M7b
  unverändert; Multi-Select überspringt Symlinks im Baum wie gehabt).
- Ordner laufen über `enqueueTree` (vorhandene Rekursion inkl. Konflikt- und
  Gruppenabbruch-Maschinerie).

### 5.2 Queue-Besitz & Konflikte

- Der Job landet in der Queue des QUELL-Tabs: Dort wurde die Aktion ausgelöst,
  dort erscheinen Fortschritt, Fehler, Konflikt-Sheets (Bridge des Quell-Tabs).
- Konfliktprüfung läuft gegen das Ziel-FS (destination) — M5b-Maschinerie
  unverändert (Umbenennen/Überspringen/Überschreiben/applyToAll).
- Nach Abschluss refresht das REMOTE-Pane des ZIEL-Tabs (weak-Capture wie
  bisher üblich); zusätzlich das Quell-Pane nur, wo heute schon üblich.
- Bandbreite: lokale→Remote-Cross-Transfers zählen im Upload-Bucket;
  Remote→Remote in beiden (Abschnitt 4).

### 5.3 Kanten & Fehlerfälle

- **Ziel-Tab schließt während des Streams:** dessen Teardown reißt die
  Ziel-Verbindung; der laufende Job im Quell-Tab endet über das vorhandene
  M5d-Mapping (connectionFailed → unterbrochen bzw. fehlgeschlagen). Kein
  Sonderpfad, kein Hänger.
- **Schließen-Nachfrage erweitert:** Sie erscheint auch, wenn der Tab ZIEL
  aktiver Transfers anderer Tabs ist (Text nennt das ausdrücklich).
  Erkennung: die Queue-Items tragen ab M8b eine optionale Ziel-Tab-Referenz
  (nur App-seitig, z. B. `destinationTabID`), über die beim Schließen
  app-seitig geprüft wird.
- **Ziel trennt zwischen Menü-Aufbau und Klick:** Der Enqueue läuft gegen das
  tote FS und endet als normale Fehlermeldung in der Quell-Queue (kein Guard
  nötig; fail-safe vorhanden).
- Der Ziel-Pfad wird beim KLICK eingefroren (navigiert der Ziel-Tab danach
  weiter, ändert das das Ziel nicht mehr) — bewusste Entscheidung, im
  Submenü-Hinweis sichtbar.

## 6. Menü-Modell (M8b, Core)

`BrowserContextMenu` wird erweitert:

- Neuer Parameter: Liste der möglichen Ziel-Sessions
  (`[CrossSessionTarget]`: `id`, `title`, `remotePath`) — die App übergibt die
  anderen VERBUNDENEN Tabs.
- `BrowserMenuEntry.transferToOtherPane` bleibt; neu:
  `transferToSession(CrossSessionTarget)`. Der exhaustive Switch in
  `ContentView` (M7b-Final-Review-Fix) erzwingt die Behandlung zur Compile-Zeit.
- Regeln (unit-getestet): Ziel-Einträge nur, wenn die Auswahl übertragbar ist
  (gleiche Gate wie `transferToOtherPane`); nie der eigene Tab; nie
  Formular-Tabs; Reihenfolge = Strip-Reihenfolge.

## 7. Tests

- **TabsViewModel (Core, TDD):** add/close/activate, Nachbar-Wahl beim
  Schließen des aktiven Tabs (rechts, sonst links), Letzter-Tab-Schutz,
  Sidebar-Connect-Zielwahl (unverbunden=in place, verbunden=neuer Tab).
- **Geteilte Buckets:** zwei Queues, ein Bucket-Paar, Aggregatrate hält das
  Limit (Muster des M6a-Beweises als Unit-Test mit injizierter Uhr);
  Doppel-Bucket-Drossel (Remote→Remote) inkl. Deadlock-Freiheit
  (knapper Bucket zuerst).
- **Menü-Modell:** Submenü-Regeln aus Abschnitt 6; Multi-Select/Symlink
  unverändert (Regressionen).
- **Remote→Remote gated:** ZWEITER Container im Test-Compose (Port 2223,
  eigener Seed, gleiches Image/PIN); Test verbindet beide, kopiert
  Server→Server, prüft Checksum; Cleanup beidseitig. Rig-Konvention
  (start/stop, Haupt-Checkout) gilt unverändert.
- **App-Seite** (Strip-Rendering, Sheet-Anbindung, Indikatoren): visueller
  Smoke (Checkliste im Plan; Maintainer testet selbst).

## 8. Bewusst NICHT in M8

- Tab-Reißen/-Andocken (Drag out), Tab-Umsortieren per Drag — Backlog.
- Multi-Fenster (v2) und Persistenz offener Tabs über App-Neustart.
- Ein app-globales Transfer-Fenster über alle Tabs (jede Queue-Bar bleibt
  tab-lokal).
- Warteschlangen-Übergabe beim Schließen (Jobs wandern nicht in andere Tabs).
