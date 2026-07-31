# M11i — Durch die Vervollständigungs-Kandidaten blättern (Design)

Datum: 2026-07-30 · Status: vom Maintainer angefordert (mehrfach betont)

## Ziel

In der Pfadeingabe (M11g) soll wiederholtes **Tab** bei mehreren Kandidaten
durch die Liste **iterieren**, statt sie nur erneut anzuzeigen; **Esc**
bricht das Blättern ab, ohne die Eingabe zu verlieren.

## Ausgangslage (M11g, `PathBar.swift`)

Der heutige Ablauf:

- **1. Tab**: `handleTab()` listet das Elternverzeichnis, ruft
  `PathCompletion.complete`, setzt `draft = result.completedInput` (das
  gemeinsame Präfix, bei genau einem Treffer mit `/`), merkt sich
  `lastCandidates`, `lastCandidatesDirectory`, `lastCandidatesDraft`.
- **2. Tab** (`justCompletedWithTab == true`): zeigt `lastCandidates` als
  Overlay, sofern `lastCandidatesDraft == draft`.
- **jedes weitere Tab**: zeigt dieselbe Liste erneut — es passiert nichts
  Neues.
- Ein Klick auf einen Kandidaten (`selectCandidate`) setzt
  `RemotePath.join(lastCandidatesDirectory, name) + "/"` ins Feld.
- **Esc** (`cancelOperation` → `cancel()`): schließt das Feld ganz und
  verwirft.
- **Shift+Tab** (`insertBacktab`): fällt bewusst durch zur AppKit-
  Fokus-Traversierung und verwirft dabei (M11g-Finding M7).

## Verhalten neu

Sobald die Kandidatenliste sichtbar ist (also ab dem 2. Tab), tritt die
Eingabe in einen **Blätter-Modus**:

- **Jedes weitere Tab** wählt den **nächsten** Kandidaten, setzt ihn ins
  Feld (`RemotePath.join(lastCandidatesDirectory, name) + "/"`, exakt wie
  `selectCandidate`) und hebt ihn in der Liste hervor. Der erste Tab im
  Blätter-Modus wählt den **ersten** Kandidaten (Index 0).
- **Shift+Tab** wählt den **vorherigen**; am Anfang/Ende wird umgebrochen
  (modulo Anzahl). Dazu muss `insertBacktab` im `PathTextField` behandelt
  werden, **solange die Liste offen ist** — nur sonst fällt es weiter durch
  (die M7-Regel bleibt außerhalb des Blätterns unangetastet).
- **Enter** springt auf den gerade gewählten Kandidaten — das ist der
  aktuelle `draft`, `navigate(to:)` braucht keinen Sonderfall.
- **Ein anderer Tastendruck** (ein Zeichen, Löschen) verlässt den
  Blätter-Modus: der Text bleibt, wie das Feld ihn nach dem Tastendruck
  zeigt, die Liste schließt, und die nächste Tab-Runde beginnt frisch
  (`justCompletedWithTab` zurückgesetzt — passiert heute schon in
  `resetTabTracking`).

## Esc — „ein Schritt zurück"

Esc verwirft heute das ganze Feld. Das darf beim Blättern nicht die ganze
Eingabe kosten, also bekommt Esc zwei Stufen:

- **1. Esc, während geblättert wird**: stellt den Text wieder her, der
  **vor** dem Blättern im Feld stand (der gemeinsame-Präfix-Stand aus dem
  1. Tab, d. h. `lastCandidatesDraft`), verlässt den Blätter-Modus und
  schließt die Liste. **Das Feld bleibt offen.**
- **2. Esc** (oder Esc, wenn NICHT geblättert wird): schließt das Feld und
  verwirft, genau wie heute.

So bedeutet Esc immer „einen Schritt zurück", und niemand verliert
versehentlich die getippte Eingabe.

## Zustand (rein additiv)

Zwei neue `@State`-Felder in `PathBar`, kein bestehendes Feld ändert seine
Bedeutung:

- `cycleIndex: Int?` — `nil` heißt „nicht im Blätter-Modus"; sonst der
  Index des hervorgehobenen Kandidaten in `lastCandidates`.
- `cycleBaseDraft: String` — der Feldtext vor dem ersten Blätter-Schritt,
  auf den das 1. Esc zurücksetzt.

Der Blätter-Modus ist an `lastCandidates` gebunden: eine neue Tab-Runde
(neues Listing) setzt `cycleIndex = nil` zurück, damit ein spätes Listing
nicht in eine alte Auswahl hineinschreibt (dieselbe Sorgfalt wie bei den
M11g-Findings I2/I6).

## Anzeige

`CandidatesList` bekommt einen optionalen `selectedIndex`. Der hervorgehobene
Eintrag erhält die dezente Auswahl-Fläche der App (`remoteSoft`, wie die
Tabellen-Auswahl in M5g) und wird in den sichtbaren Bereich gescrollt
(`ScrollViewReader`), damit man beim Blättern durch eine lange, gedeckelte
Liste den aktuellen Kandidaten immer sieht. Ohne `selectedIndex` (reiner
2.-Tab-Zustand vor dem ersten Blätter-Schritt) sieht die Liste aus wie
heute.

## Bewusst NICHT

- Keine Tastatur-Navigation der Liste mit Pfeiltasten (das kommt, wenn
  überhaupt, mit der allgemeinen Browser-Tastatursteuerung — eigener
  Meilenstein).
- Keine Änderung an `PathCompletion` (Core) — reine App-Schicht.
- Kein Blättern über Datei-Kandidaten: die Liste enthält weiterhin nur
  Verzeichnisse (M11g).

## Tests

- **Kein App-Test-Target** (bekannt aus M11g): die Zustandslogik lebt als
  `@State` in der View und ist nicht automatisiert erreichbar. Die reine
  Rechen-Kernaussage — „nächster/voriger Index modulo Anzahl" — wird als
  **freie, testbare Funktion** ausgelagert (z. B.
  `CandidateCycle.next(from:count:)` / `.previous(...)`) und in
  `Tests/macSCPCoreTests` bzw. einem App-nahen reinen Test abgedeckt:
  Umbruch vorwärts/rückwärts, Start aus `nil`, Anzahl 1, Anzahl 0.
- Der Rest (Tab/Shift+Tab/Esc-Verdrahtung, Hervorhebung, Scroll) geht in
  die Smoke-Checkliste an den Maintainer, wie schon bei M11g.

## Aufteilung

Ein einziger Task (App + kleine reine Zyklus-Funktion mit Test) → Abschluss.
KEIN Release.
