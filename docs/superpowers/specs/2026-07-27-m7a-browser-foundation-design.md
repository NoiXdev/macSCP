# macSCP M7a — Browser-Fundament (Design-Spec)

**Datum:** 2026-07-27
**Status:** vom Maintainer freigegeben (Block 1)
**Kontext:** Erster Teil des Datei-Browser-Ausbaus (Schnitt M7a Fundament →
M7b Kontextmenü & Dialoge). Erste Arbeit im neuen **develop-Workflow**:
Branch `develop`, Releases nur noch gezielt via Merge auf `main` + Tag.
Tabs für mehrere Sessions sind M8 — das Menü-Design in M7b hält dafür die
„Übertragen"-Substruktur offen.

## Entscheidungen (Maintainer, 2026-07-27)

- **Multi-Select**: ja, Finder-artig (⌘/⇧-Klick), Aktionen wirken auf die
  Auswahl.
- **Löschen**: auch Ordner, rekursiv (mit Bestätigung — UI in M7b).
- **Rechte-Editor**: beide Panes (lokal + remote) — UI in M7b, API hier.
- **Versteckte Dateien**: Standard AUS (Verhaltensänderung — heute wird
  alles angezeigt), Settings-Toggle + ⌘⇧.

## Neue FS-APIs (`RemoteFileSystem`-Protocol, Local + Citadel + Tests)

1. `func rename(from: String, to: String) async throws`
   - `to` ist der VOLLE Zielpfad (gleicher Ordner ⇒ Umbenennen; die UI
     baut den Pfad, das Protokoll bleibt generisch).
   - Existierendes Ziel: Fehler (`RemoteFSError`-Mapping), KEIN stilles
     Überschreiben. Lokal: `FileManager.moveItem` (wirft bei Kollision);
     remote: SFTP-rename (Server lehnt Kollision ab bzw. Fehler wird auf
     einen klaren Text gemappt).
2. `func setPermissions(path: String, permissions: UInt32) async throws`
   - Wirkt nur auf die unteren 12 Bits (rwx für Owner/Group/Other +
     setuid/setgid/sticky); Datei-Typ-Bits werden nie geschrieben.
   - Lokal: `FileManager.setAttributes([.posixPermissions:])`;
     remote: SFTP setstat.
3. `func deleteTree(at path: String) async throws` (RISK)
   - Rekursives Löschen. Lokal: `FileManager.removeItem` (nativ
     rekursiv). Remote: Bottom-up-Walk — `list`, Dateien/Symlinks per
     `delete`, danach die (leeren) Verzeichnisse; Symlinks werden
     GELÖSCHT, NIE gefolgt (kein Ausbruch aus dem Baum).
   - Kooperativ cancelbar (`Task.checkCancellation` pro Eintrag); ein
     Abbruch hinterlässt einen teilgelöschten Baum (dokumentiert).
   - Einzeldatei-Aufruf verhält sich wie `delete`.

## Multi-Select

- `RemoteFileTableView`: `allowsMultipleSelection = true`; Coordinator
  meldet die Auswahl als geordnetes Array (Tabellenreihenfolge).
- `RemoteBrowserViewModel`: neu `selectedItems: [RemoteFileItem]`
  (Quelle der Wahrheit); `selectedItem` bleibt als abgeleitete
  Convenience (`selectedItems.count == 1 ? first : nil`) — Doppelklick/
  Editor-Pfad nutzt sie weiter.
- Upload-/Download-Toolbar-Buttons: aktiv, sobald die Auswahl mindestens
  ein übertragbares Item enthält; sie enqueuen ALLE ausgewählten Items
  (Datei → `enqueue`, Ordner → `enqueueTree`, Symlinks werden still
  übersprungen — nicht mehr die Buttons sperren wie bisher bei
  Symlink-Einzelauswahl).
- Drag aus der Tabelle: alle ausgewählten Zeilen liefern Writer
  (lokal NSURL, remote FilePromise) — Mechanik pro Zeile wie heute.

## Versteckte Dateien

- `SettingsStore.showHiddenFiles: Bool`, Default `false`
  (vorwärtskompatibles JSON wie gehabt).
- Filter im `RemoteBrowserViewModel` (Anzeige-Schicht, NICHT im
  FS-Protokoll): ausgeblendet wird, was mit `.` beginnt; die Sortierung
  bleibt unverändert. `..`-Navigation ist nicht betroffen (kein
  Listeneintrag).
- Settings-UI: neuer Tab **„Allgemein"** im bestehenden
  Settings-Fenster mit dem Toggle „Versteckte Dateien anzeigen"
  (EN „Show hidden files"), Keys EN/DE.
- Shortcut **⌘⇧.** im Browser toggelt die Einstellung live (schreibt in
  den SettingsStore; beide Panes reagieren über das bestehende
  onChange-Muster).

## Invarianten

- Sicherheits-/Architektur-Invarianten unangetastet (TOFU, Keychain,
  UI-owned Lifecycles, Queue-Invarianten).
- Code + Kommentare Englisch; neue UI-Texte katalogisiert EN/DE.
- Bestehende Suite (317) bleibt grün; neue Logik TDD (rename/
  setPermissions/deleteTree gated Docker-Tests wie die übrigen
  FS-APIs; Multi-Select- und Filter-Logik unit-getestet).

## Bewusst NICHT in M7a

- Kontextmenü, Dialoge, Lösch-Bestätigung → M7b.
- Tabs/Multi-Session → M8.
- macOS-Hidden-Flag lokal (UF_HIDDEN) als zusätzliches Kriterium —
  Punkt-Präfix genügt für v1.1 (Backlog-Notiz).
