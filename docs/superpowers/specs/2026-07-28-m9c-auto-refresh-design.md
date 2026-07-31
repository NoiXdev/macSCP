# M9c — Auto-Refresh der Remote-Panes (Design)

Datum: 2026-07-28 · Status: vom Maintainer freigegeben

## Ziel

Das Remote-Pane des AKTIVEN Tabs aktualisiert sich automatisch alle X
Sekunden — still (kein Spinner, keine Sperre, Selektion bleibt), einstellbar
in den Settings.

**Maintainer-Entscheidungen (2026-07-28):**

1. Scope: NUR das Remote-Pane des aktiven Tabs. Hintergrund-Tabs pollen
   nicht; beim Tab-Wechsel übernimmt der neue aktive Tab (Timer startet
   frisch). Das lokale Pane bleibt außen vor.
2. Settings: Tab „Allgemein" — Toggle „Remote-Ansicht automatisch
   aktualisieren" (Default AN) + Intervall in Sekunden (Default 5, geklemmt
   auf 2–300).
3. Architektur: Ansatz A — stiller Refresh im Core-VM
   (`refreshQuietly()`), Timer als `.task` im Detail-Baum des aktiven Tabs
   (lebt/stirbt mit der `.id(tab.id)`-Identität aus M8a).

## 1. Core: `RemoteBrowserViewModel.refreshQuietly()`

- Listet das aktuelle Verzeichnis im Hintergrund und ersetzt `items`
  (GLEICHER Anzeige-Filter für versteckte Dateien und GLEICHE Sortierung
  wie `load()` — eine gemeinsame private Aufbereitungs-Funktion, kein
  dupliziertes Filter/Sort).
- Der Zustand bleibt UNVERÄNDERT `.loaded`: kein `.loading`-Flackern, kein
  Spinner, keine Hit-Test-Sperre.
- Selektions-Beschnitt: `selectedItems` wird auf die Einträge reduziert,
  deren Pfad in der NEUEN, GEFILTERTEN Liste noch vorkommt (erledigt den
  offenen M7a-Backlog-Punkt „Selektion-über-Refresh-Erhalt muss den
  Hidden-Filter beachten"). Die AppKit-Reconciliation (M7a) übernimmt die
  Anzeige.
- Fehler werden STILL geschluckt: kein State-Wechsel, keine Meldung — ein
  toter Server erzeugt keinen Fehler-Screen im 5-Sekunden-Takt; echte
  Probleme macht jede manuelle Aktion sichtbar. Läuft der stille Refresh,
  während der Zustand nicht `.loaded` ist (z. B. paralleles `load()` oder
  `.failed`), kehrt er sofort still zurück (Guard am Anfang UND vor dem
  Items-Schreiben — ein während des Listings gestarteter Zustandswechsel
  gewinnt).
- Keine Wirkung auf offene Sheets/Menüs/Transfers: Dialoge halten
  Wert-Schnappschüsse (etablierter notFound-Fluss), das Kontextmenü
  captured die Auswahl by value (M7b), die Queue ist unabhängig.

## 2. Settings (Core + App)

- `SettingsStore` (vorwärtskompatibel wie gehabt):
  `autoRefreshEnabled: Bool` (Default `true`),
  `autoRefreshIntervalSeconds: Int` (Default `5`, beim Setzen geklemmt auf
  `2...300`; gespeicherte Werte außerhalb des Bereichs werden beim Lesen
  geklemmt).
- Settings-UI, Tab „Allgemein": Toggle „Auto-refresh remote view"/„
  Remote-Ansicht automatisch aktualisieren" + Zahlenfeld „Every n seconds"/
  „Alle n Sekunden" (nur aktiv, wenn der Toggle an ist). Keys EN/DE.

## 3. App: Timer im aktiven Tab

- Im Detail-Baum des aktiven Tabs (innerhalb der `.id(tab.id)`-Identität)
  hängt ein `.task`, das in einer Schleife `Task.sleep` über das aktuelle
  Intervall macht und dann `refreshQuietly()` aufruft, solange:
  Toggle an UND Tab verbunden UND Remote-Zustand `.loaded`. Übersprungene
  Ticks schlafen einfach weiter.
- Settings-Änderungen wirken live (die Schleife liest Toggle/Intervall bei
  jedem Durchlauf frisch); Tab-Wechsel/Trennen beendet den Task automatisch
  (SwiftUI-Task-Lifecycle + `.id`-Remount aus M8a).
- Kein Timer für Hintergrund-Tabs, das lokale Pane oder Formular-Tabs.

## 4. Tests

- VM (`refreshQuietly`): State bleibt `.loaded` (kein Flacker-Zwischenwert
  beobachtbar), Items aktualisiert mit Filter+Sortierung, Selektion auf
  existierende + sichtbare Pfade beschnitten (inkl. Fall „Datei wurde
  versteckt"), Fehler still (State und Items unverändert), Guard bei
  nicht-`.loaded` (sofortige stille Rückkehr).
- SettingsStore: Defaults, Klemmung 2–300 (Setzen UND Lesen), Roundtrip,
  Vorwärtskompatibilität alter settings.json.
- Timer + Settings-UI: visueller Smoke (T3).

## 5. Bewusst NICHT in M9c

- Kein Polling für Hintergrund-Tabs oder das lokale Pane (lokal wären
  FS-Events das richtige Werkzeug — eigenes Thema).
- Keine Pro-Host-Einstellung (global genügt).
- Kein sichtbarer „zuletzt aktualisiert"-Indikator.
