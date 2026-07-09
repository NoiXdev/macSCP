# macSCP — Corporate Identity

Stand: 2026-07-09 · vom Maintainer freigegebene Richtung („Zwei Welten, ein Fenster")
Interaktiver Entwurf: Artifact „macSCP — Design & CI" (Session 2026-07-09)

## Markenidee

**Zwei Welten, ein Fenster.** Bernstein steht für alles Lokale (warm, nah),
Ozeanblau für alles Entfernte (kühl, fern). Damit trägt jede Transferrichtung
automatisch ihre Farbe: Upload = bernstein, Download = blau. Die App selbst
bleibt macOS-nativ (Systemfarben, Standard-Controls, Vibrancy) — die
Markenfarben arbeiten nur dort, wo sie Bedeutung tragen.

## Farbwelt

| Name | Hell | Dunkel | Verwendung |
|---|---|---|---|
| Bernstein | `#DE9426` | `#E8A63C` | Lokal-Pane, Uploads |
| Ozeanblau | `#2D71B8` | `#4E92D6` | Remote-Pane, Downloads, Primäraktion |
| Tiefsee | `#16344C → #0F1E2B` (Verlauf) | ebenso | Icon-Grund, Terminal-Hintergrund |
| Phosphor | `#7BD88F` | `#7BD88F` | Terminal-Text, Verbunden-Status |
| Nebel | `#F4F7FA` | — | Heller Grund (Web/Docs) |
| Tinte | `#14212E` | `#E8EFF5` (invertiert) | Text auf Grundflächen |

Regeln:

- Bernstein und Ozeanblau nie dekorativ mischen — sie sind semantisch
  (lokal/remote), nicht ornamental.
- Status-Grün (Phosphor) ist von den Markenfarben getrennt; Fehler nutzen
  System-Rot.
- In der App haben Systemfarben Vorrang; die Duo-Farben kommen als
  Asset-Farben (`LocalAmber`, `RemoteBlue`) mit Hell/Dunkel-Varianten.

## App-Icon

Gewählt: **Variante A „Zwei Panes"** — zwei umrandete Panes (bernstein/blau)
auf Tiefsee-Squircle, Austauschpfeile in beiden Richtungen und beiden Farben.
Master: [`assets/icon.svg`](assets/icon.svg). Für M6 (Release) daraus die
`.icns`-Größen rendern (16–1024 px); bis dahin läuft die App ohne Bundle-Icon.

Verworfene Varianten: B „Auf & Ab" (nur Pfeile — Reserve fürs Menüleisten-Icon),
C „Prompt" (zu terminal-lastig für einen Dateimanager).

## Wortmarke & Typografie

- Wortmarke: `mac` in SF Pro Display Light (300), `SCP` in Bold (750),
  Laufweite −2 %. Keine eigene Logo-Schrift.
- Die Systemschrift **ist** die Markenschrift: SF Pro Text für UI und
  Fließtext, SF Mono (`ui-monospace`) für Pfade, Terminal und Zahlenspalten
  (tabellarische Ziffern).
- Im Web/Docs: `-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica
  Neue", sans-serif` bzw. `ui-monospace, "SF Mono", Menlo, monospace`.

## Sprache & öffentliche Texte

- Tagline: **„Dateien sicher zwischen Mac und Server bewegen — in einer App,
  die sich nach Mac anfühlt."**
- Öffentliche Texte (Tagline, README-Einstieg, Landingpage) bleiben
  nutzenorientiert und frei von Technik-/Stack-Begriffen; Protokoll- und
  Werkzeugnamen erst ab dem Contributing-Teil (Konvention des Maintainers).
- UI-Texte auf Deutsch, aktiv formuliert; Fehler nennen Ursache und nächsten
  Schritt („Anmeldung fehlgeschlagen — Benutzername oder Passwort prüfen.").

## Roadmap-Bezug

Das Zielbild (Sidebar, zwei Panes, Terminal, Transfer-Leiste) entsteht über
die Meilensteine: Remote-Browser M2a · Lokal-Pane/Transfers M2b · Sessions M3 ·
Terminal M4 · Warteschlange M5 · Icon/Release M6. Design-Tokens (Asset-Farben)
werden mit M2b eingeführt.
