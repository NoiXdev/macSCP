# M11m — Zusätzliche Spalten: Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Zuschaltbare Spalten Rechte/Besitzer/Gruppe/Typ in der Dateiliste, in den Einstellungen ein-/ausschaltbar, jede sortierbar.

**Architecture:** `RemoteFileItem` bekommt `owner`/`group` (aus `longname` geparst, numerischer/`nil`-Rückfall); ein `FileColumn`-Modell + persistierte Sichtbarkeit im `SettingsStore`; `FileSortKey` (M11l) um die neuen Schlüssel erweitert; die Tabelle baut ihre Spalten dynamisch aus der Einstellung.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftUI + AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-31-m11m-extra-columns-design.md`

## Global Constraints

- Code und Kommentare **nur Englisch**; Anzeigetexte über die Kataloge
  (EN Default + DE, typografische Anführungszeichen im Deutschen).
- Besitzer/Gruppe: `longname`-Namen ZUERST, dann numerische `uidgid`, dann
  `nil` — **nie eine geratene Falschanzeige**. Der Parser ist rein/testbar
  und defensiv.
- Kein zusätzlicher Server-Roundtrip zur Namensauflösung.
- `name` ist immer sichtbar; `size`/`modified` standardmäßig an;
  `permissions`/`owner`/`group`/`type` standardmäßig aus.
- Vorwärtskompatibilität: altes `settings.json` ⇒ Standard-Spalten.
- Recycling-Hygiene in den Zellen (Inhalt je Wiederverwendung setzen).
- M5g-Optik der drei bestehenden Spalten unverändert.
- `swift build` immer aus SAUBEREM Build-Verzeichnis prüfen.
- Tests: Swift Testing, TDD. Baseline: **847 Tests / 59 Suiten**.
- Kein Release, kein Merge auf `main`, kein Tag.

---

### Task 1: Modell, longname-Parser, Mapper, Spalten-/Sortier-/Settings-Kern (Core)

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFileItem.swift` (owner/group), `Sources/macSCPCore/SSH/SFTPAttributeMapper.swift`, `Sources/macSCPCore/SSH/CitadelFileSystem.swift` (longname durchreichen), `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift` (owner/group aus stat), `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` (FileSortKey-Fälle), `Sources/macSCPCore/Settings/SettingsStore.swift` (sichtbare Spalten)
- Create: `Sources/macSCPCore/Presentation/FileColumn.swift` (FileColumn + Formatierer + longname-Parser, oder aufgeteilt)
- Test: `Tests/macSCPCoreTests/` — neue Dateien für Parser/Formatierer/Spalten, Erweiterungen an Mapper-/VM-/Settings-/Citadel-ITests

**Interfaces:**
- Consumes: `RemoteFileItem`, Citadels `SFTPPathComponent.longname`/`.attributes.uidgid`, `PosixPermissions` (M7b), `FileSortKey` (M11l).
- Produces (T2 verlässt sich wörtlich darauf):
  - `RemoteFileItem.owner: String?`, `.group: String?` (memberwise init erweitern, Defaults `nil`)
  - `public enum FileColumn: String, Sendable, CaseIterable { case name, size, modified, permissions, owner, group, type }` mit `isToggleable`/`defaultVisible`
  - `public enum LongnameParser { public static func ownerGroup(from longname: String) -> (owner: String, group: String)? }`
  - Formatierer (rein): `FileColumn.text(for: RemoteFileItem) -> String?` bzw. je Spalte (Rechte rwx, Typ je kind — die lokalisierten Typ-/Platzhalter-Strings kommen aus der App-Schicht; Core liefert die rohen Bausteine)
  - `FileSortKey` erweitert um `.permissions/.owner/.group/.type`
  - `SettingsStore.visibleColumns: [FileColumn]` (oder Set), persistiert, vorwärtskompatibel

- [x] **Step 1: Failing tests für `LongnameParser`.** Standard-`ls -l`-Zeile
  `-rw-r--r-- 1 www-data staff 2454 Jul 30 14:22 config.php` ⇒
  `(owner: "www-data", group: "staff")`; Mehrfach-Whitespace; Besitzer mit
  Sonderzeichen; zu kurze/kaputte Zeile ⇒ `nil`; Ordner-Zeile `drwxr-xr-x`.
- [x] **Step 2: Rot, dann Parser implementieren** (defensiv: nach den ersten
  beiden Feldern — Perms, Linkzahl — kommen Besitzer und Gruppe; tolerant
  gegen Whitespace; unsicher ⇒ `nil`).
- [x] **Step 3: Modell + Mapper.** `owner`/`group` auf `RemoteFileItem`;
  `SFTPAttributeMapper.item` bekommt `longname`/`uidgid` und setzt
  owner/group nach der Rangfolge (longname-Name → numerisch → nil). Tests:
  longname gewinnt; ohne longname numerisch; ohne beides nil.
- [x] **Step 4: Citadel + Local durchreichen.** readdir-Pfad reicht
  `component.longname` und `component.attributes.uidgid` an den Mapper; der
  Einzel-`stat`-Pfad nur `uidgid` (kein longname). `LocalFileSystem` füllt
  owner/group aus `stat` (getpwuid/getgrgid), numerischer Rückfall.
- [x] **Step 5: `FileColumn` + Formatierer + `FileSortKey`-Fälle** mit Tests
  (Rechte rwx, Typ je kind, Besitzer/Gruppe/nil; Sortier-Fälle inkl.
  Name-Tiebreaker und nil-Position; die M11l-Regel „Tiebreaker bleibt
  aufsteigend" gilt weiter).
- [x] **Step 6: `SettingsStore.visibleColumns`** persistiert +
  vorwärtskompatibel (altes JSON ⇒ name/size/modified). Roundtrip-Test.
- [x] **Step 7: Gated Rig-Test.** Ein Listing gegen den Docker-Server
  liefert owner/group (bekannte Rig-Werte). `MACSCP_ITEST=1`.
- [x] **Step 8: Grün + volle Suite.** `swift test` → 847 + neue.
- [x] **Step 9: Commit.** `feat: carry owner/group and model selectable columns`

---

### Task 2: Dynamische Spalten + Einstellungs-Kontrollkästchen (App)

**Files:**
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift` (Spalten dynamisch aus der Einstellung, Zellen für die neuen Spalten, sortDescriptor/Indikator je Spalte), `Sources/MacSCPApp/SettingsView.swift` (Kontrollkästchen), `Sources/MacSCPApp/BrowserPane.swift`/`ContentView.swift` (Einstellung durchreichen), `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `FileColumn`, die Formatierer, `SettingsStore.visibleColumns`, `FileSortKey` (T1); das M11l-Sortier-/Indikator-Muster.

- [x] **Step 1: Dynamische Spalten.** `makeNSView` baut die Spalten aus
  `visibleColumns` in fester Reihenfolge (Name, Größe, Geändert, Rechte,
  Besitzer, Gruppe, Typ — nur die sichtbaren); jede mit `PolishedHeaderCell`,
  lokalisiertem Titel und `sortDescriptorPrototype`. Ändert sich die
  Einstellung, werden die Spalten neu aufgebaut (in `updateNSView`,
  idempotent — nur bei echter Änderung, kein Flackern).
- [x] **Step 2: Zellen.** `tableView(_:viewFor:row:)` bekommt die neuen
  Spalten-IDs: Rechte (rwx, monospaced), Besitzer/Gruppe (Text), Typ
  (lokalisiert). Recycling-Hygiene: Inhalt UNBEDINGT je Wiederverwendung
  setzen; Werte über die Core-Formatierer + App-L10n.
- [x] **Step 3: Sortier-Indikator** je Spalte weiter wie M11l (selbst
  gezeichnetes ▲/▼).
- [x] **Step 4: Einstellungen.** Kontrollkästchen je zuschaltbarer Spalte
  (Name fix, nicht abschaltbar). Bindet an `SettingsStore.visibleColumns`.
- [x] **Step 5: EN/DE.** Spaltentitel + Typ-Strings + Platzhalter „—" in
  BEIDE Kataloge. `plutil -lint` OK, `LocalizableStringsTests` grün.
- [x] **Step 6: Verifikation.** `swift build` sauber (keine neuen
  Warnungen), volle `swift test`.
- [x] **Step 7: Commit.** `feat: show selectable file-list columns`

---

### Task 3: Abschluss-Verifikation (Koordinator)

- [x] Gated Suiten: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → grün, zero skips.
- [ ] Visueller Smoke — Maintainer (Checkliste: Kontrollkästchen schalten
  Spalten zu/ab; Besitzer/Gruppe zeigen echte Namen gegen den Rig, „—" wo
  unbekannt; Rechte als rwx; Typ lokalisiert; neue Spalten sortierbar mit
  Dreieck; Recycling ohne Schmieren beim Scrollen; M5g-Optik der Alt-Spalten
  unverschoben; hell/dunkel; beide Panes).
- [x] Plan-Checkboxen, Ledger, Opus-Final-Review, Fix-Runden bis „Yes",
  Push develop, `gh run watch`, Memory. KEIN Release.
