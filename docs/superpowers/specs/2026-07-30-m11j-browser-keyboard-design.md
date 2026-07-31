# M11j — Tastatursteuerung im Dateibrowser (Design)

Datum: 2026-07-30 · Status: vom Maintainer freigegeben (Finder-Stil,
Übertragen richtungs-nach-Pane)

## Ziel

Die Dateiliste per Tastatur bedienen: navigieren, öffnen, umbenennen,
löschen, Informationen, übertragen — ohne zur Maus greifen zu müssen.

## Ausgangslage

- Die Liste ist ein schlichtes `NSTableView` (nicht abgeleitet) im
  `RemoteFileTableView`-Coordinator; **kein** Tastatur-Handler. Nur die
  native Pfeiltasten-Auswahl wirkt; Tippen tut nichts.
- Alle Aktionen laufen heute schon durch EIN Modell: `onOpen`,
  `onOpenFile`, und `onMenuAction(BrowserMenuEntry, [RemoteFileItem])` für
  Rename/Info/NewFolder/Delete/Transfer, dazu `viewModel.goUp()`. Die
  Gültigkeit (welche Aktion für welche Auswahl erlaubt ist) liegt in der
  reinen Core-Funktion `BrowserContextMenu.entries(for:side:)`.

## Tastenbelegung (Finder-Stil, Maintainer-Entscheid)

| Taste | Aktion |
|---|---|
| **Return** | Umbenennen (nur bei genau einer Auswahl) |
| **⌘↓** / **⌘O** | Öffnen: Ordner → hinein (`onOpen`), Datei → Editor (`onOpenFile`, nur Remote) |
| **⌘↑** | Eine Ebene hoch (`goUp`) |
| **⌘⌫** | Löschen mit Rückfrage (`delete`) |
| **⌘I** | Informationen & Rechte (nur einzeln, NIE Symlink) |
| **Leertaste** | Übertragen — lokales Pane lädt hoch, Remote lädt herunter |
| **⌘A** | Alles auswählen (nativ) |
| **Esc** | Auswahl aufheben |

- **Plain ⌫ bleibt unbelegt** — kein versehentliches Löschen; Finder löscht
  damit auch nichts.
- Pfeiltasten (Auswahl bewegen) bleiben die native Tabellen-Funktion.
- Beide Panes identisch; die Übertragen-Richtung ergibt sich aus `side`.

## Gültigkeit = Kontextmenü, kein zweiter Weg

Eine Taste löst eine Aktion nur aus, wenn dieselbe Aktion auch im
Kontextmenü für die aktuelle Auswahl erscheinen würde. Konkret: die
Tastatur befragt `BrowserContextMenu.entries(for:side:)` (oder eine dünne
Ableitung daraus) und leitet nur zulässige Aktionen an genau die Closures
weiter, die das Kontextmenü schon nutzt. So können Menü und Tastatur nie
auseinanderlaufen:

- Umbenennen/Info nur bei Einzelauswahl; Info nie bei Symlink.
- Löschen nur bei nicht-leerer Auswahl.
- Editor nur remote und nur für Dateien.
- Übertragen nur bei übertragbarer Auswahl.

Ist eine Taste für die aktuelle Auswahl nicht zulässig, passiert **nichts**
(kein Fehler, kein Piepsen unterdrückt — der Tastendruck fällt an `super`,
damit native Funktionen wie Type-Select erhalten bleiben).

## AppKit-Verdrahtung

- `RemoteFileTableView` bekommt eine **`NSTableView`-Unterklasse** mit:
  - `override func keyDown(_:)` für die **modifierlosen** Tasten: **Return**
    (Umbenennen), **Leertaste** (Übertragen), **Esc** (Auswahl leeren).
  - `override func performKeyEquivalent(_:) -> Bool` für die
    **⌘-kombinierten** Tasten (⌘↓/⌘O/⌘↑/⌘⌫/⌘I): Command-Events laufen in
    AppKit durch `performKeyEquivalent`, NICHT durch `keyDown` — die
    klassische Falle. Rückgabe `true` nur, wenn wir die Taste wirklich
    verarbeiten; sonst `false`, damit App-Menü-Kürzel und Fokuswechsel
    unberührt bleiben.
  - Beide prüfen zuerst, dass eine passende Auswahl da ist und die Aktion
    laut Menü-Modell zulässig ist; sonst `super`/`false`.
- Der Coordinator (schon `NSTableViewDelegate`/`NSMenuDelegate`) bekommt die
  Dispatch-Methoden; die Unterklasse hält eine schwache Referenz auf ihn
  und ruft sie. Die Selektion wird BY VALUE zum Zeitpunkt des Tastendrucks
  gelesen (dasselbe Muster wie `MenuActionBox` beim Menü-Bau, gegen
  Stale-Index).
- **Kollisions-Prüfung:** vor der Umsetzung sicherstellen, dass ⌘↓/⌘↑/⌘O/
  ⌘I/⌘⌫ mit keinem bestehenden App-Menü-Kürzel kollidieren (belegt sind
  ⌘N/W/1–9, ⌘⇧., ⌘⇧K/L/I, ⌘T, ⌘,). Kollidiert eines, im Report melden,
  nicht still umbelegen.

## Bewusst NICHT in M11j

- Keine Type-to-Select-Änderung (bleibt nativ).
- Kein Quick-Look / Leertaste-Vorschau (Leertaste ist Übertragen).
- Keine Pfeiltasten-Navigation der Kandidatenliste in der Pfadzeile (das ist
  M11i/PathBar, unberührt).
- Kein neuer Audit-Eintrag (die ausgelösten Aktionen auditieren sich schon
  selbst, wo relevant — Delete etc.).

## Tests

- **Reine Gültigkeits-Ableitung** (Core, testbar): eine Funktion, die aus
  `(Taste, Auswahl, Pane-Seite)` die auszulösende `BrowserMenuEntry` bzw.
  Öffnen/Hoch/Übertragen-Absicht ODER „nichts" liefert — abgekoppelt vom
  `NSEvent`. Fälle: Return bei Einzel- vs. Mehrfachauswahl; ⌘I bei Symlink
  (nichts) vs. Datei; ⌘⌫ bei leerer vs. nicht-leerer Auswahl; Leertaste
  Richtung nach `side`; ⌘O Ordner vs. Datei vs. Datei-im-lokalen-Pane
  (kein Editor). Diese Funktion ist der automatisierte Kern; sie stellt
  sicher, dass Tastatur und Menü dieselbe Gültigkeit teilen.
- Die AppKit-Anbindung (`keyDown`/`performKeyEquivalent`) hat kein
  Test-Target → Smoke-Checkliste.

## Aufteilung

T1 Core (reine `BrowserKeyCommand`-Ableitung + Test) → T2 App
(`NSTableView`-Unterklasse, Dispatch, Kollisions-Check, beide Panes) →
T3 Abschluss. KEIN Release.
