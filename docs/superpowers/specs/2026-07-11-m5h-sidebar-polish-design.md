# macSCP M5h — Design-Polish Sidebar (Design-Spec)

**Datum:** 2026-07-11
**Status:** vom Maintainer freigegeben (Runde 2 der gestaffelten Polish-Runden)
**Referenz:** `docs/design/assets/macscp-ci-mockup.html` (bindende Blaupause);
Vorgänger-Runde `docs/superpowers/specs/2026-07-11-m5g-browser-polish-design.md`.

## Ziel

Die Sessions-Sidebar übernimmt Fläche, Zeilen-Rhythmus und Label-Typo aus dem
CI-Mockup. Reiner View-Layer, null Verhaltensänderung. Zweite von vier Runden
(nach M5g Browser; danach Transfer-Leiste/Terminal-Strip, dann Formular).

## Mockup-Werte (bindend, aus dem CSS des Entwurfs)

| Element | Wert |
|---|---|
| `paper` | hell `#F4F7FA`, dunkel `#0D1720` |
| `card` | hell `#FFFFFF`, dunkel `#14212E` |
| Sidebar-Fläche | `color-mix(card 70 %, paper)` → vorberechnet hell `#FCFDFE`, dunkel `#121E2A` |
| Sidebar-Kante | 1 pt Hairline rechts (`hairline`-Token aus M5g) |
| Container-Padding | 12 pt vertikal, 8 pt horizontal |
| Abschnitts-Labels | 10,5 pt semibold, versal, Laufweite ~1 pt (`.1em`), `inkTertiary`, Padding oben 2 / seitlich 10 / unten 6 |
| Session-Zeilen | Padding 5×10 pt, Radius 6, Zeilenabstand 2 pt |
| Aktive Zeile | Hintergrund `remoteSoft` (Token statt bisher `remoteBlue.opacity(0.12)`), Schrift semibold `remoteBlue`, Phosphor-Punkt |
| Inaktive Zeilen | Text Standard; Hover `Color.secondary.opacity(0.08)` (wie M5f, unverändert) |

## Umsetzung

### 1. Tokens (`Sources/MacSCPApp/DesignTokens.swift`)

Neu über den bestehenden `dynamicNS`-Helper:

- `paper: Color` — hell `#F4F7FA`, dunkel `#0D1720`
- `card: Color` — hell `#FFFFFF`, dunkel `#14212E`
- `sidebarSurface: Color` — hell `#FCFDFE`, dunkel `#121E2A` (vorberechneter
  70/30-Mischton; statisch statt Laufzeit-Mischung — deterministisch)

`paper`/`card` werden in M5h NICHT konsumiert (Staging für Transferbar- und
Formular-Runde, wie bereits `ink`/`inkSecondary` — Kommentar entsprechend).

### 2. Sidebar (`Sources/MacSCPApp/SessionSidebar.swift`)

- Container (äußerer VStack): `.background(DesignTokens.sidebarSurface)` +
  `.overlay(alignment: .trailing)` mit 1-pt-`hairline`-Rectangle.
- „SESSIONS"-Label und Gruppen-/IMPORTIERT-Header: `font(.system(size: 10.5,
  weight: .semibold))`, `.tracking(1.0)`, `.foregroundStyle(DesignTokens.inkTertiary)`,
  Padding oben 2 / seitlich 10 / unten 6 (Gruppen-Header behalten ihre
  Kontextmenü-/Drop-/Rename-Funktion unverändert; nur Typo/Farbe/Padding).
- Session-Zeilen (`SessionRow`): Innen-Padding 5 pt vertikal / 10 pt horizontal,
  Radius 6 für Hover- und Aktiv-Hintergrund; aktive Zeile nutzt
  `DesignTokens.remoteSoft` statt `remoteBlue.opacity(0.12)`; Listen-Insets so
  anpassen, dass die Zeilen mit den Labels fluchten; Zeilenabstand ~2 pt
  (List-Row-Spacing bzw. Padding — der Plan legt den Mechanismus fest, das
  visuelle Ergebnis ist bindend).
- `List(.sidebar)` + `scrollContentBackground(.hidden)` bleiben; die getönte
  Fläche kommt vom Container darunter.
- Fehlertext-Bereich unten unverändert.

## Invarianten

- KEINE Verhaltensänderung: Kontextmenüs, Inline-Rename (Enter/Escape/Blur),
  Drag & Drop, Lösch-Dialog, Neue-Gruppe-Alert, Collapse-State,
  `interactionsDisabled` — alles exakt wie M5f.
- Beide Appearances über dynamische Tokens; keine statischen Farben in Views.
- CI-Regeln unverändert (Blau = aktiv/Auswahl, Phosphor nur Status).
- Lokalisierung unangetastet (Label-Keys bleiben; Versal-Darstellung war schon
  Anzeige-Transformation).

## Tests

- Keine neuen Unit-Tests (View-Layer); bestehende 295 bleiben grün.
- Visueller Smoke: hell UND dunkel Seite an Seite mit dem Mockup — getönte
  Fläche sichtbar gegen die Pane-Fläche, rechte Hairline, Label-Typo, aktive
  Zeile in remoteSoft, Zeilen-Maße; Verhaltens-Regression: Kontextmenü,
  Inline-Rename, Gruppe ein-/ausklappen, Verbinden-Klick.

## Bewusst NICHT in M5h

- Transfer-Leiste & Terminal-Strip (Runde 3), Formular & Buttons (Runde 4).
- Kein app-weiter `paper`-Grund (die Panes bleiben auf `controlBackgroundColor`,
  bis die Folgerunden die Karten-Hierarchie komplettieren).
