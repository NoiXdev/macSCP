# macSCP M5j — Design-Polish Transfer-Leiste & Terminal-Strip (Design-Spec)

**Datum:** 2026-07-11
**Status:** vom Maintainer freigegeben (Runde 3 der gestaffelten Polish-Runden)
**Referenz:** `docs/design/assets/macscp-ci-mockup.html` (bindende Blaupause);
Vorgänger `…-m5g-browser-polish-design.md`, `…-m5h-sidebar-polish-design.md`.

## Ziel

Transfer-Leiste und Terminal-Panel übernehmen Maße, Typo und die
Pillen-Progress-Form aus dem CI-Mockup. Reiner View-Layer, null
Verhaltensänderung. Dritte von vier Runden (danach: Formular & Buttons).

## Mockup-Werte (bindend)

| Element | Wert |
|---|---|
| Transferbar | `border-top` 1 pt Hairline, Padding 8 pt vertikal / 14 pt seitlich, Schrift 12 pt, Text `ink-2`, Gap 12 pt |
| Progress-Pille | Höhe 5 pt, Radius 99 (Capsule), Track in `line` (Hairline-Farbe), Füllung Capsule |
| Terminal-Strip | `border-top` 1 pt Hairline, Padding 8 pt vertikal / 14 pt seitlich, Schrift 12 pt |

**Farbentscheidung (Maintainer/CI-Regel):** Die Pillen-Füllung bleibt
SEMANTISCH in der Richtungsfarbe (Bernstein `localAmber` = Upload, Ozeanblau
`remoteBlue` = Download) — das Mockup-Beispiel zeigt Blau, aber die CI-Regel
(`docs/design/ci.md`) ist bindend; nur die FORM (5-pt-Capsule r99) kommt vom
Mockup.

## Umsetzung

### 1. Transfer-Leiste (`Sources/MacSCPApp/TransferQueueBar.swift`)

- `Divider()` → `Rectangle().fill(DesignTokens.hairline).frame(height: 1)`.
- Kopfzeile: Padding 14 pt horizontal / 8 pt vertikal (statt 12/4); Titel
  12 pt semibold in `inkSecondary` (statt `.caption`/`.secondary`).
- Zeilen-Container: Padding 14 pt horizontal, 8 pt unten (statt 12/6);
  Zeilen-HStack-Gap 12 pt (statt 8).
- Zeilen-Typo: Basis `font(.system(size: 12))` (statt `.callout`); Dateiname
  `DesignTokens.ink`; Status-/Rate-Texte `inkSecondary` statt `.secondary`
  (Fehler bleiben System-Rot, „interrupted" bleibt `.orange` — M5d-Semantik).
- **PillProgress** (neue private View in derselben Datei):
  `PillProgress(fraction: Double, fill: Color)` — 5 pt hohe Capsule als Track
  in `DesignTokens.hairline`, Füllung als Capsule in `fill` mit Breite
  `fraction × Gesamtbreite` (GeometryReader), `animation(.linear(duration:
  0.2))` auf Fraction-Änderungen; Gesamtbreite 120 pt wie der heutige
  `ProgressView`. Ersetzt den determinate `ProgressView(value:)`-Zweig;
  der indeterminate Zweig (`ProgressView().controlSize(.small)`) bleibt.
- Icon-/Checkmark-Farben (amber/blau je Richtung) und alle Status-Zweige
  inhaltlich unverändert.

### 2. Terminal-Panel (`Sources/MacSCPApp/ContentView.swift`, `terminalPanel`)

- 1-pt-Hairline als obere Kante des Panels:
  `.overlay(alignment: .top) { Rectangle().fill(DesignTokens.hairline)
  .frame(height: 1).allowsHitTesting(false) }` auf dem Panel-ZStack.
- „Shell beendet"-Zustand: Schrift 12 pt (`font(.system(size: 12))`),
  Padding 8 pt vertikal / 14 pt seitlich um den Inhalt; Farben unverändert
  (Phosphor auf Tiefsee).
- SwiftTerm-View, Terminal-Lifecycle, ⌘T, Replay: unangetastet.

## Invarianten

- KEINE Verhaltensänderung: Queue-Status-Semantik, Aufräumen-Button,
  Resume-Banner, Konflikt-Sheet, Terminal-Lifecycle — exakt wie heute.
- Beide Appearances über dynamische Tokens; keine statischen Farben neu.
- CI-Regeln: Bernstein nur Upload, Blau nur Download/Remote, Phosphor nur
  Status/Terminal, Fehler System-Rot, Orange nur „interrupted".

## Tests

- Keine neuen Unit-Tests (View-Layer); bestehende 295 bleiben grün.
- Visueller Smoke: hell UND dunkel; laufender Transfer mit niedrigem
  Bandbreiten-Limit, damit die Pille sichtbar füllt (Track/Füllung/5 pt/
  Capsule-Form, Upload amber + Download blau); Hairline über Leiste und
  Terminal-Panel; „Shell beendet"-Maße; Verhaltens-Regression: Transfer
  läuft durch, Aufräumen, ⌘T auf/zu.

## Bewusst NICHT in M5j

- Formular-Grid & Button-Radien (Runde 4).
- Kein Umbau der Queue-Zeilen-Struktur (Reihenfolge der Elemente bleibt).
- Terminal-Innen-Padding des SwiftTerm-Inhalts (Renderer-intern, nicht anfassen).
