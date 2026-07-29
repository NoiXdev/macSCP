# M11c — Rechte rekursiv setzen (Design)

Datum: 2026-07-29 · Status: vom Maintainer freigegeben („los")

## Ziel

Im Rechte-Dialog Rechte auf einen ganzen Unterbaum anwenden — wahlweise
dieselben Rechte für Dateien und Ordner oder getrennte (Ordner brauchen
fast immer das x-Bit, Dateien nicht).

**Maintainer-Entscheidungen (2026-07-29):**

1. Getrennter Modus wird vorbelegt mit: Dateien = Rechte des angeklickten
   Ordners, Ordner = dieselben Rechte PLUS x-Bit dort, wo Lesen erlaubt
   ist (644 ⇒ Ordner 755). Beides frei änderbar.
2. Der Dialog fragt beim Einschalten von „rekursiv", ob gleiche oder
   getrennte Rechte gelten sollen.

## 1. Der Walk (Core, RISK)

- `PermissionsTreeApplier` — reine Funktion gegen `any RemoteFileSystem`,
  KEINE Protokoll-Erweiterung: dadurch gilt sie ohne Duplizierung für das
  lokale UND das entfernte Backend (`deleteTree` musste pro Backend
  implementiert werden, weil es `topLevelKind` selbst herleitet; hier
  liefert der Aufrufer die Art des Wurzel-Eintrags mit, siehe unten).
- Signatur:
  `static func apply(root: String, kind: RemoteFileKind, filePermissions: UInt32, directoryPermissions: UInt32, on fs: any RemoteFileSystem) async -> PermissionsTreeResult`
  — wirft NICHT; das Ergebnis trägt die Zahlen.
- `PermissionsTreeResult: Equatable, Sendable`:
  `changed: Int`, `skippedSymlinks: Int`, `failed: Int`,
  `firstErrorMessage: String?`, `cancelled: Bool`.
- Ablauf: top-down über `list(path:)`, weil dessen Einträge den Typ
  UNAUFGELÖST melden (dieselbe Eigenschaft, auf der die Symlink-Sicherheit
  des Lösch-Walks beruht). Für jeden Eintrag:
  - `.symlink` ⇒ ÜBERSPRINGEN, `skippedSymlinks += 1`, NIE `setPermissions`
    darauf und NIE hineinlaufen.
  - `.directory` ⇒ `setPermissions(directoryPermissions)`, danach rekursiv.
  - sonst ⇒ `setPermissions(filePermissions)`.
  - Fehler pro Eintrag: `failed += 1`, erste Meldung merken, WEITERLAUFEN
    (Muster `applyImport`). Auch ein fehlgeschlagenes `list` eines
    Unterverzeichnisses zählt so und stoppt den Rest nicht.
- **Symlink-Begründung (bindend):** `setPermissions` FOLGT auf beiden
  Backends dem Symlink (bekannter M7a-Fund). Ein rekursiver Lauf, der
  Symlinks nicht überspringt, würde Rechte an Zielen AUSSERHALB des Baums
  ändern — genau der Ausbruch, den `deleteTree` verhindert. Überspringen
  ist deshalb Sicherheits-Invariante, keine Bequemlichkeit.
- Wurzel: Die Art (`kind`) kommt vom Aufrufer (die Auswahl stammt aus
  `list()`, also aus derselben unaufgelösten Quelle). Ist sie `.symlink`,
  passiert NICHTS (Ergebnis: nur `skippedSymlinks == 1`) — der Dialog
  bietet die Aktion für Symlinks ohnehin nicht an.
- Abbruch: `Task.checkCancellation()` vor jedem Eintrag; bei Abbruch
  bricht der Walk ab und liefert `cancelled: true` mit den bis dahin
  gezählten Zahlen (kein Fehler, kein Rollback — bereits gesetzte Rechte
  bleiben, das ist dokumentiert).

## 2. Ableitung der Ordner-Rechte (Core, pur)

`PosixPermissions.directoryDefault(from:)`: setzt in jeder Dreiergruppe
(owner/group/other) das x-Bit, wenn dort r gesetzt ist; Sonderbits
(setuid/setgid/sticky) bleiben unverändert. 644 ⇒ 755, 600 ⇒ 700,
640 ⇒ 750. Reine Funktion, direkt testbar.

## 3. VM-Aktion

`RemoteBrowserViewModel.applyPermissionsRecursively(file:directory:to:)`:
ruft den Walk, lädt danach die Liste neu, schreibt EINEN Audit-Eintrag
(`chmod -R <file>/<dir> <pfad>` plus die Zahlen; `isError` nur, wenn
`failed > 0`), liefert das Ergebnis an die UI. Fortschritt wird über
einen optionalen Callback gemeldet (`(changed, failed) -> Void`), damit
das Sheet mitzählen kann.

## 4. Dialog

- Schalter „Auf alle Unterobjekte anwenden" im bestehenden Rechte-Sheet;
  NUR sichtbar, wenn das Objekt ein Ordner ist (bei einer Datei wäre
  „rekursiv" wirkungslos).
- Eingeschaltet: Segmente `Gleiche Rechte | Getrennt`. „Gleiche Rechte"
  nutzt das vorhandene Raster für beides; „Getrennt" zeigt ZWEI Raster
  (Dateien / Ordner) mit der Vorbelegung aus §2.
- Der Anwenden-Knopf heißt dann „Rekursiv anwenden" und stellt vorher
  EINE Rückfrage mit Zielpfad und Modus (die Aktion ist nicht
  rückgängig zu machen).
- Während des Laufs: Fortschrittszeile im Sheet (laufende Zählung) plus
  „Abbrechen"; danach die Ergebniszeile (geändert / übersprungen /
  fehlgeschlagen, bei Fehlern die erste Meldung). Kein Eintrag in die
  Transfer-Warteschlange — das ist keine Übertragung.
- Gilt auf BEIDEN Panes (der Dialog steht schon auf beiden; der Walk ist
  protokollbasiert).

## 5. Tests

- Ableitung: 644⇒755, 600⇒700, 640⇒750, Sonderbits bleiben.
- Walk (Mock-FS mit Aufzeichnung aller `setPermissions`-Aufrufe):
  gemischter Baum (Dateien, Ordner, Symlinks, leerer Ordner);
  getrennte vs. gleiche Rechte; **kein `setPermissions` auf einem
  Symlink-Pfad** (Aufzeichnung beweist es); Fehler eines Eintrags zählt
  und stoppt nicht; fehlgeschlagenes `list` eines Unterordners zählt und
  stoppt nicht; Abbruch mitten im Baum liefert `cancelled: true` mit
  Teilzahlen; Wurzel ist Symlink ⇒ nichts passiert.
- VM: Audit-Eintrag mit Zahlen, `isError` nur bei `failed > 0`, Liste
  wird neu geladen, Fortschritts-Callback feuert.
- Gated am Rig: echter Baum inkl. Symlink; danach Kontrolle per
  `docker exec stat`, dass die Rechte im Baum stimmen UND das
  Symlink-Ziel außerhalb UNVERÄNDERT ist.

## 6. Aufteilung

T1 Core-Walk + Ableitung (RISK) → T2 VM-Aktion + Audit + Fortschritt →
T3 Dialog (Schalter, zwei Raster, Rückfrage, Fortschritt, EN/DE) →
T4 Abschluss (gated Rig-Test, Final-Review). KEIN Release.

## 7. Bewusst NICHT in M11c

Keine Mehrfachauswahl (der Dialog ist Einzelauswahl), kein „nur Dateien"
oder „nur Ordner"-Filter, kein Rückgängig, keine Vorschau der
betroffenen Einträge, kein rekursives Setzen von Eigentümer/Gruppe
(SFTP-`chown` ist nicht implementiert und nicht geplant).
