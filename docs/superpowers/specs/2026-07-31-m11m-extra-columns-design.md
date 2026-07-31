# M11m — Zusätzliche Dateilisten-Spalten (Design)

Datum: 2026-07-31 · Status: vom Maintainer freigegeben („dann los")

## Ziel

Die Dateiliste um zuschaltbare Spalten erweitern: **Rechte**, **Besitzer**,
**Gruppe**, **Typ** — in den Einstellungen ein-/ausschaltbar, jede
sortierbar (baut auf dem M11l-Sortierfundament auf).

## Ausgangslage

- `RemoteFileItem` trägt heute `name`, `path`, `kind`, `size: UInt64?`,
  `modifiedAt: Date?`, `permissions: UInt32?`. **Keine Besitzer/Gruppen-
  Felder.**
- Citadels SFTP-Listing liefert je Eintrag `attributes: SFTPFileAttributes`
  (mit `uidgid: UserGroupId?` = NUMERISCHE `userId`/`groupId`, KEINE Namen)
  UND `longname: String` (die server-formatierte `ls -l`-Zeile, in der die
  Besitzer/Gruppen-NAMEN als Textfelder stehen).
- `SFTPAttributeMapper.item(...)` zieht heute nur size/permissions/modTime;
  `longname` und `uidgid` werden verworfen.
- Die Tabelle (`RemoteFileTableView`) baut drei feste Spalten `name`/`size`/
  `modified`. `FileSortKey` (M11l) hat `.name/.size/.modified`.
- Rechte werden im Info-Sheet schon als rwx über `PosixPermissions` (M7b)
  formatiert.

## 1. Modell + Datenherkunft (Core)

`RemoteFileItem` bekommt zwei neue optionale Felder:

- `owner: String?`, `group: String?`.

Herkunft:

- **Remote-Listing (readdir):** primär die NAMEN aus `longname` parsen
  (das `ls -l`-Format: nach den Rechten stehen Linkzahl, **Besitzer**,
  **Gruppe**). Schlägt das Parsen fehl oder fehlt `longname`, Rückfall auf
  die numerische `uidgid` als String (`"1000"`). Ist beides nicht da, `nil`.
- **Remote-Einzel-`stat`:** hat KEIN `longname` (nur `getAttributes`), also
  nur die numerische `uidgid` bzw. `nil`. Das ist in Ordnung — die Spalten
  zeigt die LISTE, nicht der Einzelabruf.
- **Local:** über `stat`/`getpwuid`/`getgrgid` Namen, Rückfall numerisch.

**Fragilität ehrlich benennen:** `longname` ist server-generiert und
formatabhängig; der Parser ist defensiv (feste Feldpositionen der `ls -l`-
Ausgabe, aber tolerant gegen Mehrfach-Whitespace), und jeder Zweifelsfall
fällt auf die numerische uid/gid oder `nil` zurück — nie eine geratene
Falschanzeige. Der Parser ist eine reine, testbare Funktion.

## 2. Spalten-Modell + Einstellung

- `enum FileColumn: String, Sendable, CaseIterable` mit
  `name`, `size`, `modified`, `permissions`, `owner`, `group`, `type`.
  `name` ist immer sichtbar (nicht abschaltbar). `size`/`modified` bleiben
  standardmäßig sichtbar (heutiges Verhalten); `permissions`/`owner`/`group`/
  `type` standardmäßig AUS.
- `SettingsStore` bekommt eine persistierte, vorwärtskompatible Menge
  sichtbarer Spalten (altes JSON ⇒ die drei heutigen). App-global (wie die
  anderen Anzeige-Einstellungen), nicht pro Pane.
- Formatierung je Spalte (reine Core-Funktionen, testbar, lokalisierbar an
  der App-Schicht):
  - Rechte: rwx-String über `PosixPermissions` ODER Oktal — rwx wie im
    Info-Sheet, konsistent.
  - Typ: „Ordner" / „Datei" / „Verknüpfung" / „—" je `kind` (lokalisiert).
  - Besitzer/Gruppe: der String bzw. „—".

## 3. Sortierung (Core, baut auf M11l)

`FileSortKey` bekommt `.permissions`, `.owner`, `.group`, `.type`:
- `.permissions`: numerisch nach den Bits, Name-Tiebreaker.
- `.owner`/`.group`: `localizedCaseInsensitiveCompare` auf dem String, `nil`
  ans Ende, Name-Tiebreaker.
- `.type`: nach `kind` (stabile Reihenfolge Ordner/Datei/Link/other), Name-
  Tiebreaker. (Ordner-zuerst-Gruppierung aus M11l bleibt ohnehin.)
- Der Name-Tiebreaker bleibt aufsteigend auch absteigend (M11l-Regel).

## 4. Bedienung (App)

- Die Tabelle baut ihre Spalten DYNAMISCH aus der Einstellung (Reihenfolge
  fest: Name, Größe, Geändert, Rechte, Besitzer, Gruppe, Typ — nur die
  sichtbaren). Jede Spalte hat ihre `PolishedHeaderCell` und ihren
  `sortDescriptorPrototype` (M11l), inklusive des selbst gezeichneten
  ▲/▼-Indikators.
- Einstellungen ▸ Allgemein (oder ein eigener kleiner Abschnitt):
  Kontrollkästchen je zuschaltbarer Spalte. Name bleibt fix.
- Zeilenaufbau: die neuen Spalten zeichnen wie die bestehenden Zellen
  (12,5 pt; Rechte/Typ monospaced/regulär passend), Recycling-Hygiene wie
  beim Symlink-Symbol (M11h) — Zellinhalt UNBEDINGT je Wiederverwendung
  setzen.
- M5g-Optik: die drei bestehenden Spalten behalten Maße/Typo; die neuen
  fügen sich im selben Rhythmus ein.

## 5. Bewusst NICHT in M11m

- Kein Auflösen numerischer uid/gid in Namen über eine Extra-Server-Abfrage
  (kein `id`/`getent`-Aufruf) — nur `longname`-Namen bzw. die Zahl.
- Keine frei umsortierbaren/breitenverstellbar-persistierten Spalten (feste
  Reihenfolge; Breiten sind AppKit-Standard, nicht persistiert).
- Kein Besitzer/Gruppe-ÄNDERN (nur Anzeige; chown ist kein Thema hier).
- Kein Audit-Eintrag.

## 6. Tests

- `longname`-Parser (rein): Standard-`ls -l`-Zeile ⇒ Besitzer/Gruppe
  korrekt; Mehrfach-Whitespace; Namen mit Sonderzeichen; zu kurze/kaputte
  Zeile ⇒ `nil` (kein Raten); eine Zeile ohne Gruppenspalte ⇒ defensiv.
- Mapper: `longname` gewinnt über `uidgid`; ohne `longname` numerischer
  Rückfall; ohne beides `nil`.
- Spalten-Formatierer (Rechte rwx, Typ je `kind`, Besitzer/Gruppe/„—").
- `FileSortKey` neue Fälle inkl. Name-Tiebreaker und `nil`-Position.
- `SettingsStore`: Vorwärtskompatibilität (altes JSON ⇒ Standard-Spalten),
  Roundtrip.
- Gated Rig-Test: ein Listing gegen den Docker-Server liefert Besitzer/
  Gruppe (der Rig hat bekannte Werte).
- EN/DE-Kataloge: Key-Mengen identisch.

## 7. Aufteilung

T1 Core (Modell-Felder + `longname`-Parser + Mapper + LocalFileSystem +
`FileColumn`/`FileSortKey`-Fälle + Formatierer + `SettingsStore`, mit Tests
inkl. gated Rig) → T2 App (dynamische Spalten aus der Einstellung, Zellen,
Einstellungs-Kontrollkästchen, EN/DE) → T3 Abschluss. KEIN Release.
