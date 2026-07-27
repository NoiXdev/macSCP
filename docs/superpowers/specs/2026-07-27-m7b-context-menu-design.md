# macSCP M7b — Kontextmenü & Dialoge (Design-Spec)

**Datum:** 2026-07-27
**Status:** vom Maintainer freigegeben (Block 2)
**Kontext:** Zweiter Teil des Datei-Browser-Ausbaus, baut auf M7a
(rename/setPermissions/deleteTree, Multi-Select, Hidden-Filter) auf.
Tabs sind M8 — das „Übertragen"-Submenü ist die vorbereitete
Einhängestelle („Übertragen zu Session xy" kommt dort dazu).

## Kontextmenü

- Rechtsklick auf Zeilen BEIDER Panes; Implementierung als `NSMenu` im
  Tabellen-Coordinator (die Tabelle ist AppKit), Aktionen laufen über
  Callbacks in die SwiftUI-/ViewModel-Schicht.
- Rechtsklick auf eine NICHT selektierte Zeile selektiert sie zuerst
  (Finder-Verhalten); Rechtsklick in eine bestehende Mehrfachauswahl
  behält die Auswahl.
- Einträge (Einzelauswahl):
  1. **Übertragen** — Submenü, heute genau ein Eintrag „Zum anderen
     Pane" (Upload bzw. Download je nach Pane; Datei → `enqueue`,
     Ordner → `enqueueTree`).
  2. **Öffnen** — nur Remote-DATEIEN (der M5e-Editor-Pfad); im lokalen
     Pane und für Ordner/Symlinks ausgeblendet.
  3. **Umbenennen…**
  4. **Informationen & Rechte…**
  5. **Neuer Ordner…** (wirkt auf das aktuelle Verzeichnis des Panes;
     auch im Hintergrund-Kontext ohne Zeile verfügbar)
  6. **Pfad kopieren** (voller Pfad ins Pasteboard; bei Mehrfachauswahl
     eine Zeile pro Pfad)
  7. Separator, dann **Löschen…** (rot, `.destructive`)
- Mehrfachauswahl: Umbenennen, Informationen & Rechte und Öffnen
  entfallen; Übertragen/Pfad kopieren/Löschen wirken auf alle.
- Symlinks: Übertragen entfällt (Queue überträgt keine Symlinks),
  Umbenennen/Löschen/Pfad kopieren funktionieren.

## Dialoge (alle als Sheets, Buttons im PolishedButtonStyle)

- **Umbenennen…**: Namens-Sheet, vorausgefüllt mit dem aktuellen Namen.
  Validierung: nicht leer, kein `/`; Kollision und andere Fehler kommen
  als lokalisierter Fehlertext in den Sheet (Sheet bleibt offen).
  Bestätigen ruft `rename(from:to:)` mit dem Pfad im selben Verzeichnis,
  danach Pane-Refresh (Auswahl folgt dem neuen Namen, wenn möglich).
- **Neuer Ordner…**: gleicher Namens-Sheet-Typ (geteilte Komponente),
  Default „untitled folder"/„unbenannter Ordner"; ruft
  `createDirectory`, danach Refresh + Auswahl des neuen Ordners.
- **Informationen & Rechte…**: zeigt Name, vollständigen Pfad, Art,
  Größe (formatiert wie die Liste), Änderungsdatum sowie die Rechte:
  rwx-Grid (3×3 Checkboxen Besitzer/Gruppe/Andere) + Oktal-Feld
  (3–4 Stellen), beide bidirektional synchron; Basis ist
  `RemoteFileItem.permissions` (fehlt der Wert, ist der Rechte-Teil
  ausgegraut mit Hinweis). „Übernehmen" ruft `setPermissions` (nur
  untere 12 Bits), danach Refresh; Fehler als Text im Sheet.
- **Löschen…**: Bestätigungs-Alert, destruktiver roter Bestätigen-
  Button. Text nennt bei Einzelauswahl den Namen, bei Mehrfachauswahl
  die Anzahl; enthält bei Ordnern den Hinweis „einschließlich des
  gesamten Inhalts"; immer „Diese Aktion kann nicht widerrufen
  werden." Ausführung sequenziell über `deleteTree`/`delete` in einem
  Task mit Abbruch-Propagation; danach Refresh. Fehler → Fehler-Alert
  (lokalisiertes Mapping), bereits gelöschte Items bleiben gelöscht.

## Fehlerbehandlung & Lokalisierung

- Alle Aktionen melden Fehlschläge über einen Alert mit dem
  bestehenden lokalisierten Fehler-Mapping
  (`TransferQueueViewModel.message(for:)` bzw. Core-Keys); kein
  `String(describing:)`.
- Sämtliche neuen Menü-, Sheet- und Alert-Texte werden EN/DE
  katalogisiert.

## Invarianten

- Kein Verhalten bestehender Wege ändert sich (Doppelklick-Editor,
  Toolbar-Buttons, Drag&Drop, Queue-Invarianten).
- Aktionen laufen sequenziell und UI-blockierungsfrei; während einer
  laufenden Lösch-/Rename-Aktion ist das auslösende Pane-Refresh-Ziel
  klar definiert (Refresh erst nach Abschluss).
- Code + Kommentare Englisch.

## Tests

- Menü-Zustandslogik (welche Einträge bei welcher Auswahl) als
  unit-testbare Helper-Funktion (Items + Pane-Seite → Menü-Modell).
- Namens-Validierung unit-getestet; Oktal↔Grid-Konvertierung
  unit-getestet.
- Visueller Smoke: Menü in beiden Panes, Rename-Kollision, chmod auf
  dem Rig (`ls -l`-Beweis via docker exec), rekursives Löschen mit
  Bestätigung, Neuer Ordner, Pfad kopieren, Mehrfachauswahl-Varianten.

## Bewusst NICHT in M7b

- „Übertragen zu Session xy" (M8-Tabs; Submenü-Struktur steht bereit).
- Papierkorb/Undo fürs Löschen (SFTP kennt keinen Papierkorb; lokal
  bewusst symmetrisch hartes Löschen mit Bestätigung).
- Duplizieren, Komprimieren, „Öffnen mit"-Untermenü (Backlog v1.2).
