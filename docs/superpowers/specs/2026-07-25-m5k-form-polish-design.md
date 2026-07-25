# macSCP M5k — Design-Polish Formular & Buttons (Design-Spec)

**Datum:** 2026-07-25
**Status:** vom Maintainer freigegeben (Runde 4 — letzte der gestaffelten Polish-Runden)
**Referenz:** `docs/design/assets/macscp-ci-mockup.html` (bindende Blaupause);
Vorgänger M5g/M5h/M5j.

## Ziel

Das Verbindungsformular (Neu/Bearbeiten/Fingerprint-Prompt) übernimmt das
Feld-Grid und den Button-Stil aus dem CI-Mockup. Reiner View-Layer, null
Verhaltensänderung. Danach ist die Design-Polish-Serie komplett → M6.

## Mockup-Werte (bindend)

| Element | Wert |
|---|---|
| Feld-Grid | Label-Spalte fest 110 pt, rechtsbündig, 12,5 pt, `inkSecondary`; Gap Label→Feld 10 pt; Zeilenabstand 10 pt |
| Button | Radius 7, Padding 5 pt vertikal / 14 pt horizontal, 12,5 pt |
| Button sekundär | Grund `card`, 1-pt-Rand `hairline`, Text `inkSecondary` |
| Button primär | Füllung `remoteBlue`, Text Weiß semibold; gedrückt leicht abgedunkelt (Opacity ~0.85) |

## Umsetzung

### 1. `PolishedButtonStyle` (neue Datei `Sources/MacSCPApp/PolishedButtonStyle.swift`)

- `struct PolishedButtonStyle: ButtonStyle` mit `let prominent: Bool`:
  Radius-7-RoundedRectangle, Padding 5×14, `font(.system(size: 12.5,
  weight: prominent ? .semibold : .regular))`; prominent: Füllung
  `DesignTokens.remoteBlue`, Text `.white`, `opacity(configuration.isPressed
  ? 0.85 : 1)`; sekundär: Füllung `DesignTokens.card`, `strokeBorder`
  `DesignTokens.hairline` 1 pt, Text `DesignTokens.inkSecondary`, gedrückt
  Opacity 0.85. Disabled-Darstellung über `.opacity` via Environment
  `\.isEnabled` (0.5). Convenience: `static` Zugriffe
  `.polished` / `.polishedProminent` über eine `ButtonStyle`-Extension.

### 2. Formular-Grid (`Sources/MacSCPApp/ConnectionFormView.swift`)

- Private Helper-View `FormRow<Content: View>`:
  `FormRow(label: String) { content }` → `HStack(alignment: .firstTextBaseline,
  spacing: 10)` mit `Text(label).font(.system(size: 12.5))
  .foregroundStyle(DesignTokens.inkSecondary).frame(width: 110,
  alignment: .trailing)` + Content.
- Die `Form { … }` wird zu `VStack(alignment: .leading, spacing: 10)` mit
  `FormRow`-Zeilen (Host, Port, Benutzername, Authentifizierung [Segmented-
  Picker als Content], Passwort/Key-Pfad/Passphrase, Session-Name, Gruppe
  [Picker], Speichern-Toggle [`FormRow(label: "")` — der Toggle fluchtet
  auf der Feldspalte]). Labels kommen aus den bestehenden
  Katalog-Strings (heutige TextField-Label-Parameter werden zu
  `FormRow`-Labels; die TextFields behalten ihre Prompts/Placeholder).
- `errorHighlight` wird auf die jeweilige `FormRow` angewendet (Rahmen um
  Label+Feld, bestehende Außen-Padding-Optik aus dem Design-Review 6e03c7a
  bleibt unverändert).
- Tab-Reihenfolge/Fokus: TextFields bleiben System-Controls in
  Hierarchie-Reihenfolge — KEINE Verhaltensänderung (Tab-Kette
  Host→Port→Benutzer→Passwort[…] muss identisch funktionieren).
- Der Fingerprint-Prompt behält sein Layout; nur seine Buttons wechseln
  auf den neuen Stil.
- `.disabled(isConnecting)`-Gruppierung, fileImporter, Alert, Edit-Modus-
  Zweige, Callbacks: unverändert.

### 3. Button-Anwendung (nur ConnectionFormView)

- Primär (`.polishedProminent`): „Verbinden" (New), „Speichern & verbinden"
  (Edit), „Vertrauen & verbinden" (Prompt). Der bisherige
  `.buttonStyle(.borderedProminent)` entfällt zugunsten des neuen Stils.
- Sekundär (`.polished`): „Zurück", „Speichern", „…"-Browse.
- `keyboardShortcut(.defaultAction)`-Zuordnungen und `disabled`-Logik
  bleiben exakt.
- NICHT umgestellt: Toolbar (native macOS-Toolbar), Alerts, Sheets,
  Settings-Fenster, Sidebar — System-Chrome bleibt System (M5f-Linie).

## Invarianten

- KEINE Verhaltensänderung: Validierung/Alert, Edit-Modus-Semantik
  (Passwort „unverändert"), TOFU-Fluss, fileImporter, Shortcuts,
  Disabled-Zustände.
- Beide Appearances über vorhandene Tokens; keine neuen statischen Farben
  (Weiß auf remoteBlue ist bewusst statisch — Mockup `#fff` auf Markenblau,
  in beiden Appearances korrekt).
- CI-Regeln: Blau = Primäraktion; Bernstein taucht im Formular nicht auf.
- Lokalisierung unangetastet (Label-Keys identisch).

## Tests

- Keine neuen Unit-Tests (View-Layer); bestehende 295 bleiben grün.
- Visueller Smoke hell UND dunkel: Grid-Fluchtung (110-pt-Labels bündig),
  Validierungsfehler (leer verbinden → Alert + Rahmen um Zeile),
  Edit-Modus (Buttons Zurück/Speichern/Speichern & verbinden im neuen
  Stil), TOFU-Prompt (Pin löschen → Prompt mit neuen Buttons, Trust-Fluss
  funktioniert), **Tab-Ketten-Regression** Host→Port→Benutzer→Passwort,
  „…"-Browse öffnet Panel.

## Bewusst NICHT in M5k

- Settings-Fenster-Restyling (System-Form bleibt).
- Toolbar-/Sheet-/Alert-Buttons (System-Chrome).
- Eigene TextField-Optik (System-Felder bleiben — Fokus-Ring/Tab nativ).
