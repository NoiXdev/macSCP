# macSCP M5g — Design-Polish Browser-Hauptansicht (Design-Spec)

**Datum:** 2026-07-11
**Status:** vom Maintainer freigegeben (Brainstorming nach Design-Review 2026-07-11)
**Referenz:** `docs/design/assets/macscp-ci-mockup.html` (interaktiver CI-Entwurf,
Abschnitt „Das Hauptfenster") — bindende Blaupause; `docs/design/ci.md`.

## Ziel & Kontext

User-Feedback: Der Entwurf ist schön in Abständen, Formen und Design — die App
wirkt dagegen „sehr leblos". Analyse: Dem Mockup geben Flächen-Hierarchie,
Haarlinien, dichte Typo-Details und eine feine Radien-Sprache ihr Leben; die
App nutzt flache System-Standards. Entscheidung des Maintainers:

- **Richtung:** „Mockup als Blaupause" — Flächen, Haarlinien, Typo-Rhythmus und
  Radien exakt übernehmen; System-Controls bleiben nur, wo sie unsichtbar sind.
- **Scope-Staffelung:** Alle Bereiche folgen, aber einzeln. **M5g = nur die
  Browser-Hauptansicht** (Dateiliste, Paneheads, Pane-Trenner). Folgerunden:
  Sidebar-Fläche & Rhythmus · Transfer-Leiste & Terminal-Strip · Formular &
  Buttons.

## Mockup-Werte (bindend, aus dem CSS des Entwurfs)

| Element | Wert |
|---|---|
| Linienfarbe `line` | hell `#DAE3EB`, dunkel `#24374A` |
| Text `ink` | hell `#14212E`, dunkel `#E8EFF5` |
| Text `ink-2` | hell `#4A5B6B`, dunkel `#A7B7C5` |
| Text `ink-3` | hell `#7E8FA0`, dunkel `#6E8093` |
| `remote-soft` | hell `#E3EEF9`, dunkel `#142C42` |
| `local-soft` | hell `#FBF1DF`, dunkel `#2C2415` |
| Spaltenköpfe | 10,5pt, semibold, versal, Laufweite ~0.08em, `ink-3`, Padding 5×12pt, Hairline unten |
| Tabellenzellen | Padding 4,5×12pt, Hairline unten in `line` @45 % Opazität, `white-space: nowrap` |
| Zellen-Typo | erste Spalte `ink`, übrige `ink-2`; Zahlen-Spalten rechtsbündig mit Tabellenziffern |
| Zeilen-Auswahl | Hintergrund `remote-soft` (in BEIDEN Panes — Blau ist die Auswahl-/Primärfarbe, CI-Regel) |
| Panehead | Padding 7×12pt, Hairline unten, Gap 8pt, Schriftgewicht ~650 |
| Pane-Badge | versal 10,5pt, Laufweite .09em, Padding 2×8pt, Radius 5pt, Farbe/Soft je Seite |
| Panehead-Pfad | `ink-3`, 11,5pt, Ellipsis |
| Pane-Trenner | 1pt Hairline zwischen den Panes |

## Umsetzung

### 1. DesignTokens erweitern (`Sources/MacSCPApp/DesignTokens.swift`)

Neue appearance-aware Tokens (Muster der bestehenden `localAmber`/`remoteBlue`
mit `NSColor(name:dynamicProvider:)`): `hairline`, `ink`, `inkSecondary`,
`inkTertiary`, `remoteSoft`, `localSoft` mit den Tabellenwerten oben. Bestehende
Views, die Soft-Töne bisher über `opacity` improvisieren (Pane-Badge 0.18,
aktive Sidebar-Zeile 0.12), stellen NUR dort um, wo M5g sie ohnehin anfasst
(Pane-Badge); die Sidebar folgt in ihrer eigenen Runde.

### 2. Dateiliste (`Sources/MacSCPApp/RemoteFileTableView.swift`, AppKit — RISK)

- Eigene `NSTableHeaderCell`: versale Titel (Katalog-Strings bleiben, Anzeige
  versal), 10,5pt semibold, Laufweite, `inkTertiary`, Hairline unten; Header-
  Höhe ~22pt (10,5pt-Schrift + 2×5pt Padding, wie im Mockup).
- Zeilen: Höhe ~24pt; Zellen-Padding 12pt seitlich; Trennung als Hairline
  (`hairline` @45 %) UNTER jeder Zeile (NSTableView `gridStyleMask` reicht
  nicht für die Transparenz — eigene Zeichnung in einer `NSTableRowView`-
  Subclass oder Grid-Farbe `hairline.withAlphaComponent(0.45)` via
  `gridColor`, wenn das visuell identisch ist; der Plan legt den Weg fest).
- Auswahl: `selectionHighlightStyle = .none` + eigene `NSTableRowView`, die
  bei Selektion `remoteSoft` als abgerundetes Rechteck (Radius 0 — Mockup
  `tr.sel` ist rechteckig) zeichnet; Text bleibt lesbar in beiden Appearances.
  Auswahlfarbe in BEIDEN Panes `remoteSoft`.
- Typo: Namensspalte `ink` (bzw. `labelColor`-äquivalent des Tokens), Größe/
  Datum `inkSecondary`, Zahlen-/Datumsspalten rechtsbündig mit
  `monospacedDigit`-Font (Systemgröße bleibt 12–12,5pt-Bereich).
- Verhalten UNVERÄNDERT: Sortierung, Auswahl-Logik, Doppelklick (Ordner +
  onOpenFile), Kontextmenüs, Drag-Quellen/Promise, Symlink-„ →"-Suffix.

### 3. Paneheads + Trenner (`Sources/MacSCPApp/BrowserPane.swift`, `ContentView.swift`)

- Panehead: Padding 7×12pt, Gap 8pt; Badge auf `localSoft`/`remoteSoft` (statt
  `tint.opacity(0.18)`), Padding 2×8pt, Radius 5pt, versal mit Laufweite .09em
  wie gehabt; Pfad `inkTertiary` 11,5pt, `lineLimit(1)` + `truncationMode(.middle)`;
  darunter Hairline (1pt `hairline`) statt `Divider()`.
- Pane-Trenner: Die HSplitView-Optik zwischen Lokal/Remote auf 1pt-Hairline
  bringen — funktional ziehbar bleiben. Weg (Plan legt fest): eigener
  schmaler Divider-Look, oder Panes ohne Split-Steg mit Hairline-Overlay,
  solange das Ziehen erhalten bleibt. Fällt die Ziehbarkeit dem Look zum
  Opfer, gewinnt die Ziehbarkeit (Funktion > Optik) und der Steg wird nur
  so dünn wie möglich.

## Fehlerbehandlung / Invarianten

- KEINE Verhaltensänderung an Auswahl, Transfers, Drag & Drop, Kontextmenüs,
  Queue, Terminal — reiner View-Layer.
- Beide Appearances (hell/dunkel) müssen die Tabellenwerte treffen; Tokens
  sind dynamisch, keine statischen Farben in Views.
- CI-Regeln bleiben: Bernstein nur lokal (Badge), Blau Auswahl/Remote,
  Phosphor nur Status, Fehler System-Rot.
- Lokalisierung unangetastet (Spaltentitel bleiben Katalog-Keys; Versal-
  Darstellung ist Anzeige-Transformation).

## Tests

- Keine neuen Unit-Tests (reiner AppKit/SwiftUI-View-Layer; `FileListFormatter`
  und alle ViewModels unverändert); bestehende 295 müssen grün bleiben.
- Visueller Smoke (Abschluss-Task): Seite-an-Seite mit dem Mockup in hell UND
  dunkel — Spaltenköpfe, Hairlines, Auswahlfarbe, Zellen-Typo/Tabellenziffern,
  Panehead-Maße, Badge-Soft-Töne, 1pt-Trenner; Verhaltens-Regression:
  Sortieren, Doppelklick (Ordner + Editor), Auswahl + Upload/Download,
  Drag & Drop, Kontextmenü.

## Bewusst NICHT in M5g

- Sidebar-Fläche & Zeilen-Rhythmus (eigene Runde).
- Transfer-Leiste (Pillen-Progress) & Terminal-Strip (eigene Runde).
- Formular-Grid & Button-Radien (eigene Runde).
- Flächen-Hierarchie `paper`/`card` app-weit (kommt mit der Sidebar-Runde,
  wo der Zwischenton gebraucht wird).
