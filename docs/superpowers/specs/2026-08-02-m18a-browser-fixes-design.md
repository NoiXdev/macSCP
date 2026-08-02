# M18a — Browser-Fixes & „Neue Datei" (Design/Spec)

**Datum:** 2026-08-02
**Status:** freigegeben (Maintainer), bereit für writing-plans
**Branch:** `develop`
**Anlass:** Maintainer-Bugreport im Dev-Build v1.8.0-dev + eine kleine Funktionslücke.

## Ziel

Vier kleine, unabhängige Punkte aus dem Alltagsgebrauch: der hängende
Neuer-Ordner-Dialog, seine Ursache im Auflisten, eine fehlende
„Neue Datei"-Aktion, und eine beobachtete Fenster-Wiederherstellung außerhalb
des Bildschirms.

## Befund (reproduziert, belegt)

**Symptom:** „Wenn man Ordner erstellt, geht der Dialog nicht mehr weg."

**Reproduziert** im laufenden Dev-Build (lokaler Bereich, UI-Scripting):
Der Ordner wird angelegt, **kein** Fehlertext erscheint, der Dialog bleibt mit
Spinner (`isWorking == true`) stehen — und schließt sofort korrekt, sobald drei
nacheinander erscheinende macOS-**TCC-Berechtigungsdialoge** („Zugriff auf
Schreibtisch/Dokumente/Downloads") bestätigt sind.

**Ursachenkette:**
1. `RemoteBrowserViewModel.createFolder(named:)` (`Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift:464`) ruft nach erfolgreichem `createDirectory` **`await load()`**, bevor es `nil` zurückgibt.
2. `load()` → `LocalFileSystem.list(path:)` (`Sources/macSCPCore/RemoteFS/LocalFileSystem.swift:59`) schickt **jeden** Eintrag durch `item(for:)` → `ownerGroup(for:)` (`:302`) → ein `FileManager.attributesOfItem` **pro Eintrag** — unabhängig davon, ob die Owner/Gruppe-Spalten überhaupt sichtbar sind (M11m).
3. Trifft das auf TCC-geschützte Ordner (Schreibtisch/Dokumente/Downloads), blockiert macOS mit Systemdialogen.
4. `NameEntrySheet.confirm()` (`Sources/MacSCPApp/BrowserSheets.swift:47`) wartet auf `await onConfirm(...)` und ruft `dismiss()` erst danach → der Dialog wirkt eingefroren.

**Ausgeschlossen:** kein SwiftUI-`dismiss()`-Fehler (der Dialog schließt korrekt,
sobald `load()` zurückkehrt); kein Fehler in `createFolder`s Rückgabewert
(Tests grün); kein Problem mit gestapelten `.sheet`-Modifiern (ContentView
stapelt acht davon funktionierend).

**Warum jetzt:** Ein frisch gebauter Dev-Build ist für TCC eine neue App —
die Abfragen erscheinen erneut. Vermutlich blieben sie unbemerkt, weil das
Fenster außerhalb des sichtbaren Bereichs wiederhergestellt wurde (siehe D).

## Umfang

### A — Dialog wartet nicht mehr auf das Neuladen (der eigentliche Fehler)

Der Ordner ist fertig, sobald `createDirectory` zurückkehrt; das Neuladen der
Liste ist reine Anzeige-Aktualisierung. Dass das Schließen daran hängt, trifft
genauso einen langsamen SFTP-Server oder ein sehr großes Verzeichnis.

**Änderung (Core):** `createFolder(named:)` und `rename(_:to:)` führen künftig
**nur die Operation** aus (inkl. Kollisionsprüfung und Audit-Ereignis) und
kehren sofort zurück. Das Neuladen samt Auswahl des neuen Eintrags zieht in
eine eigene, ebenfalls awaitbare Methode um:

```swift
/// Refreshes the listing and selects `path` if present. Called after a
/// successful create/rename so dismissing the sheet never waits on a listing.
public func refreshAndSelect(path: String) async
```

**Änderung (App):** Der `onConfirm`-Aufruf in `BrowserPane` wartet nur noch auf
die Operation; bei Erfolg wird `refreshAndSelect` in einem eigenen `Task`
gestartet, **ohne** darauf zu warten. Der Dialog schließt damit sofort.

Beide Wege bleiben in Core einzeln awaitbar und damit testbar — die
bestehenden Tests werden entsprechend angepasst (Operation und Aktualisierung
getrennt geprüft), nicht gelöscht.

### B — Owner/Gruppe nur holen, wenn die Spalten sichtbar sind

`LocalFileSystem` bekommt `init(fetchesOwnerGroup: Bool = false)`. Ist es
`false` (Standard), entfällt der `attributesOfItem`-Aufruf pro Eintrag
vollständig: keine unnötigen Syscalls, keine TCC-Abfragen. Die App setzt es
beim Erzeugen der lokalen Ansicht auf „an", **wenn** die Owner- oder
Gruppe-Spalte in den Einstellungen sichtbar ist.

Das Protokoll bleibt unverändert (kein `list`-Parameter): SFTP liefert
Owner/Gruppe ohnehin kostenlos aus dem `longname`, S3 hat das Konzept nicht —
nur der lokale Dateizugriff zahlt hier drauf.

### C — „Neue Datei…" im Kontextmenü

Neuer Menüeintrag `newFile` (analog zu `newFolder`, ebenfalls auch bei Klick
auf den leeren Bereich), neue Core-Aktion:

```swift
/// Creates an empty file in the current directory. Same collision probe and
/// error contract as `createFolder(named:)`.
public func createFile(named name: String) async -> String?
```

Sie legt die Datei über den bestehenden `write`-Weg des `RemoteFileSystem`
mit leerem Inhalt an — funktioniert damit für lokal, SFTP und S3 gleichermaßen.
UI: derselbe `NameEntrySheet` wie „Neuer Ordner" (Titel/Bestätigungstext und
Standardname eigen), dieselbe Nicht-Warten-Regel aus A.

### D — Fenster-Wiederherstellung außerhalb des Bildschirms (erst untersuchen)

Beobachtet: Das App-Fenster wurde nach einem Neustart bei `{-101, -1386}`
wiederhergestellt, also außerhalb aller Bildschirme. **Nicht ursächlich
geklärt** — es kann macOS' eigene Fensterwiederherstellung sein oder unser
`window.setFrame` (`Sources/MacSCPApp/ContentView.swift:1565`, das Wachsen auf
die gemerkte Browser-Größe aus M5c).

Vorgehen: erst belegen, wer den Rahmen setzt. Ist es unser Code, wird der
resultierende Rahmen auf die sichtbare Fläche geklemmt (`NSScreen.visibleFrame`
des nächstgelegenen Bildschirms). Ist es macOS' Restaurierung, wird das
dokumentiert und **nicht** blind umgangen.

## Tests

- **A:** `createFolder`/`rename` geben nach der Operation zurück, **ohne** die Liste geladen zu haben (Fake-FS zählt `list`-Aufrufe); `refreshAndSelect` aktualisiert und selektiert. Die bestehenden Erwartungen (Kollision → Fehlertext, Audit-Ereignis, Auswahl nach Aktualisierung) bleiben erhalten, nur auf die zwei Schritte verteilt.
- **B:** `LocalFileSystem(fetchesOwnerGroup: false).list(...)` liefert Einträge **ohne** Owner/Gruppe und ruft `attributesOfItem` nicht auf (prüfbar über ein Verzeichnis, dessen Einträge sonst Owner/Gruppe hätten); mit `true` sind sie gefüllt.
- **C:** `createFile` legt eine leere Datei an, meldet Kollisionen mit demselben Fehlerkontrakt wie `createFolder`, und feuert ein Audit-Ereignis.
- **D:** je nach Befund — bei eigenem Code ein Test der Klemm-Funktion (Rahmen außerhalb → auf sichtbare Fläche korrigiert).
- App: build-verifiziert, Katalog-Parität, Idle-CPU-Smoke.

## Invarianten

- Kein verändertes Fehlerverhalten: Kollisionen und Fehler erscheinen weiterhin **im** Dialog (er bleibt dann offen).
- Audit-Ereignisse (`newFolder`, `rename`, neu `newFile`) bleiben erhalten bzw. folgen demselben Muster.
- Keine neue externe Dependency; keine Protokolländerung an `RemoteFileSystem`.
- UI-Strings EN/DE/FR/PL, typografisch.

## Nicht in M18a

- Weitere Owner/Gruppe-Optimierungen für SFTP/S3 (dort entsteht der Aufwand nicht).
- Ein allgemeiner „Aktion ohne Warten"-Umbau für andere Sheets (Info/Rechte laufen bewusst weiter synchron, sie zeigen ihr Ergebnis im Dialog).

## Betroffene Dateien

- `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` — **modify** (A: Operation/Aktualisierung trennen; C: `createFile`).
- `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift` — **modify** (B: `fetchesOwnerGroup`).
- `Sources/macSCPCore/Presentation/BrowserContextMenu.swift` — **modify** (C: `newFile`-Eintrag).
- `Sources/MacSCPApp/BrowserPane.swift` — **modify** (A: nicht warten; C: Sheet + Auslöser).
- `Sources/MacSCPApp/RemoteFileTableView.swift` — **modify** (C: Menüeintrag rendern).
- `Sources/MacSCPApp/ContentView.swift` — **modify** (B: Flag setzen; D: ggf. Klemmung).
- `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings` — **modify**.
- `Tests/macSCPCoreTests/…` — Tests zu A, B, C (und D, falls eigener Code).
