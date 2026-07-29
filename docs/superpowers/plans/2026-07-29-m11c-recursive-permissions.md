# M11c — Rechte rekursiv setzen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rechte auf einen ganzen Unterbaum anwenden — gleiche Rechte für alles oder getrennte für Dateien und Ordner — mit Fortschritt, Abbruch, ehrlicher Ergebnisbilanz und Symlink-Sicherheit.

**Architecture:** Ein reiner `PermissionsTreeApplier` gegen `any RemoteFileSystem` (gilt dadurch für beide Panes ohne Backend-Duplizierung; die Wurzel-Art liefert der Aufrufer), plus `PosixPermissions.directoryDefault(from:)` als reine Ableitung; die VM kapselt Aufruf, Reload, Audit und Fortschritts-Callback; das bestehende Rechte-Sheet bekommt Schalter, zweites Raster, Rückfrage, Fortschritt.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, SwiftUI.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-29-m11c-recursive-permissions-design.md` — bindend. Branch: **develop**.
- **SYMLINK-SICHERHEIT (Sicherheits-Invariante):** Symlinks werden NIE `setPermissions` unterworfen und NIE betreten — `setPermissions` folgt auf beiden Backends dem Symlink (M7a-Fund), ein Verstoß ändert Rechte AUSSERHALB des Baums. Der Walk erkennt Typen ausschließlich über `list()` (meldet unaufgelöst), nie über `stat`.
- Fehler zählen statt abzubrechen (Muster `applyImport`); der Walk wirft NICHT, er liefert Zahlen.
- Kooperativ abbrechbar zwischen Einträgen; bei Abbruch bleiben bereits gesetzte Rechte stehen (dokumentiert, kein Rollback).
- Keine Protokoll-Erweiterung von `RemoteFileSystem` (der Walk ist eine reine Funktion darüber).
- Kein Eintrag in die Transfer-Warteschlange; keine Mehrfachauswahl; kein Rückgängig.
- Alle neuen UI-Texte EN/DE in BEIDEN App-Katalogen, Core-Meldungen in beiden Core-Katalogen; Code + Kommentare NUR Englisch; keine neuen Dependencies.
- Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + volle `swift test` nach jedem Task grün (Ausgangslage 652 Tests / 49 Suiten); gated Suiten in T4; Tests SYNCHRON im Vordergrund; TDD rot→grün für Core.
- Docker-Rig nur `start`/`stop` aus dem Haupt-Checkout.
- KEIN Release, kein Merge nach main.

## Schedule

T1 (Core: Ableitung + Walk) → T2 (VM: Aktion, Audit, Fortschritt) → T3 (App: Dialog) → T4 Abschluss (Koordinator).

---

### Task 1: directoryDefault + PermissionsTreeApplier (Core, RISK)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/PosixPermissions.swift` (Ableitung)
- Create: `Sources/macSCPCore/RemoteFS/PermissionsTreeApplier.swift`
- Test: `Tests/macSCPCoreTests/PosixPermissionsTests.swift` (bestehende Datei — per grep finden), `Tests/macSCPCoreTests/PermissionsTreeApplierTests.swift` (neu)

**Interfaces:**
- Consumes: `RemoteFileSystem` (`list(path:)`, `setPermissions(path:permissions:)`), `RemoteFileItem`/`RemoteFileKind`, der Mock aus den bestehenden Tests (grep `MockFileSystem` bzw. das in den Browser-Tests genutzte Double — das passende wiederverwenden oder ein aufzeichnendes Double lokal ergänzen).
- Produces (T2/T3 verlassen sich exakt hierauf):
  - `PosixPermissions.directoryDefault(from raw: UInt32) -> UInt32` (statisch ODER Instanz-Property — der Implementer wählt und dokumentiert; im Plan als statisch angenommen)
  - `PermissionsTreeResult: Equatable, Sendable` (`changed: Int`, `skippedSymlinks: Int`, `failed: Int`, `firstErrorMessage: String?`, `cancelled: Bool`)
  - `PermissionsTreeApplier.apply(root:kind:filePermissions:directoryPermissions:on:progress:) async -> PermissionsTreeResult` — `progress: (@Sendable (PermissionsTreeResult) -> Void)? = nil` wird nach JEDEM Eintrag mit dem Zwischenstand gerufen (die UI zählt damit mit)

**Verhaltens-Anforderungen (Spec §1/§2, bindend):**
1. `directoryDefault`: in jeder Dreiergruppe das x-Bit setzen, WENN dort r gesetzt ist; Sonderbits (setuid/setgid/sticky, die oberen vier Bits) unverändert übernehmen. 0o644⇒0o755, 0o600⇒0o700, 0o640⇒0o750, 0o2644⇒0o2755.
2. Wurzel `.symlink` ⇒ NICHTS tun, Ergebnis `skippedSymlinks == 1`, sonst alles 0.
3. Wurzel `.directory` ⇒ zuerst `setPermissions(directoryPermissions)` auf die Wurzel, dann rekursiv über `list()`. Wurzel `.file` (oder sonstiges) ⇒ nur `setPermissions(filePermissions)` auf die Wurzel.
4. Pro Eintrag aus `list()`: `.symlink` ⇒ überspringen + zählen, NIE `setPermissions`, NIE betreten. `.directory` ⇒ `setPermissions(directoryPermissions)`, danach rekursiv absteigen. Sonst ⇒ `setPermissions(filePermissions)`.
5. Fehler eines `setPermissions` ⇒ `failed += 1`, erste Meldung in `firstErrorMessage` (`String(describing:)` bzw. die lokalisierte `RemoteFSError`-Meldung, falls vorhanden — kleinere Lösung wählen und dokumentieren), Walk läuft weiter. Fehler eines `list` ⇒ ebenfalls `failed += 1` und weiter mit dem Rest (das Unterverzeichnis wird nicht betreten).
6. `Task.checkCancellation()` vor jedem Eintrag; bei Abbruch sofort zurück mit `cancelled: true` und den Teilzahlen (kein Throw).
7. `progress` wird nach jeder Zählungsänderung mit dem aktuellen Zwischenstand gerufen (auch bei übersprungenen und fehlgeschlagenen Einträgen).

- [ ] **Step 1: Failing Tests**

```swift
    // PosixPermissionsTests (Ergänzung):
    // directoryDefaultAddsExecuteWhereReadable: 0o644->0o755, 0o600->0o700,
    //   0o640->0o750, 0o2644->0o2755 (Sonderbits bleiben), 0o000->0o000.
    //
    // PermissionsTreeApplierTests (Recording-Mock: merkt sich alle
    // setPermissions-Aufrufe als (path, permissions) und liefert gestellte
    // Listings; kann pro Pfad einen Fehler werfen):
    // appliesSeparatePermissionsAcrossTree: Baum /r (dir) mit /r/a.txt,
    //   /r/sub (dir), /r/sub/b.txt -> Aufrufe: /r und /r/sub mit dirPerms,
    //   /r/a.txt und /r/sub/b.txt mit filePerms; changed == 4.
    // samePermissionsModeUsesOneValue: filePerms == dirPerms -> alle vier
    //   Aufrufe mit demselben Wert.
    // neverTouchesSymlinks: Baum mit /r/link (symlink) und /r/dirlink
    //   (symlink auf ein Verzeichnis) -> KEIN setPermissions-Aufruf mit
    //   diesen Pfaden (Aufzeichnung prüfen), kein list() auf /r/dirlink,
    //   skippedSymlinks == 2.
    // rootSymlinkDoesNothing: kind .symlink -> keine Aufrufe,
    //   skippedSymlinks == 1, changed == 0.
    // rootFileAppliesFilePermissionsOnly: kind .file -> genau ein Aufruf.
    // failedEntryCountsAndContinues: setPermissions wirft für /r/a.txt ->
    //   failed == 1, firstErrorMessage != nil, /r/sub/b.txt trotzdem
    //   gesetzt (changed enthält die übrigen).
    // failedListingCountsAndContinues: list wirft für /r/sub -> failed == 1,
    //   /r/a.txt trotzdem gesetzt; kein Absturz.
    // cancellationStopsAndReportsPartial: Abbruch nach dem ersten Eintrag
    //   (Mock löst im setPermissions-Callback Task-Cancellation aus bzw.
    //   der Test cancelt den umgebenden Task) -> cancelled == true,
    //   changed < Gesamtzahl.
    // emptyDirectoryOnlySetsItself: /r ohne Inhalt -> changed == 1.
    // progressReportsAfterEachEntry: Callback-Aufrufe == Anzahl der
    //   verarbeiteten Einträge (inkl. übersprungener/fehlgeschlagener).
```

- [ ] **Step 2: Rot beweisen.** `swift test --filter PermissionsTree` und `--filter PosixPermissions` → FAIL.
- [ ] **Step 3: Implementierung** (Ableitung zuerst, dann der Walk).
- [ ] **Step 4: Grün + volle Suite.** `swift test` → 652 + neue, 0 Failures.
- [ ] **Step 5: Commit.** `feat: apply permissions across a directory tree`

---

### Task 2: VM-Aktion + Audit + Fortschritt (Core)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift`
- Test: `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift` (bzw. die Datei mit `applyPermissionsFailureFiresIsErrorPermissionsEvent` — per grep)

**Interfaces:**
- Consumes (T1): `PermissionsTreeApplier.apply(...)`, `PermissionsTreeResult`, `PosixPermissions.directoryDefault(from:)`.
- Produces (T3):
  - `RemoteBrowserViewModel.applyPermissionsRecursively(filePermissions:directoryPermissions:to item:progress:) async -> PermissionsTreeResult`

**Verhaltens-Anforderungen (Spec §3, bindend):**
1. Ruft den Walk mit `item.path` und `item.kind`, reicht den Fortschritts-Callback durch, lädt danach EINMAL die Liste neu (`load()`), auch bei Fehlern und nach Abbruch.
2. Schreibt GENAU EINEN Audit-Eintrag: Detail `chmod -R <fileOctal>/<dirOctal> <pfad>` plus die Zahlen (geändert/übersprungen/fehlgeschlagen, bei Abbruch zusätzlich als abgebrochen markiert); `isError` NUR wenn `failed > 0`; bei Fehlern trägt `errorMessage` die erste Meldung.
3. Gibt das Ergebnis unverändert zurück (die UI formuliert die Anzeige).
4. Bestehendes `applyPermissions` (Einzelobjekt) bleibt unverändert.

- [ ] **Step 1: Failing Tests**

```swift
    // recursiveApplyWritesOneAuditEventWithCounts: Mock-FS mit kleinem Baum
    //   -> genau EIN Audit-Event, Detail enthält "chmod -R", die Oktalwerte
    //   und die Zahlen; isError == false.
    // recursiveApplyMarksErrorWhenAnyEntryFailed: ein Eintrag scheitert ->
    //   isError == true, errorMessage == erste Meldung, Ergebnis failed == 1.
    // recursiveApplyReloadsListing: nach dem Lauf wurde list() erneut
    //   gerufen (Mock zählt).
    // recursiveApplyForwardsProgress: Callback-Aufrufe kommen an.
```

- [ ] **Step 2: Rot.** **Step 3: Implementierung.** **Step 4: Grün + volle Suite.** **Step 5: Commit** `feat: expose a recursive permissions action with audit and progress`.

---

### Task 3: Dialog (App)

**Files:**
- Modify: `Sources/MacSCPApp/InfoPermissionsSheet.swift` (bzw. die Datei mit dem Rechte-Sheet — per grep `InfoPermissions`), ggf. `Sources/MacSCPApp/BrowserPane.swift` (Aufruf-Verdrahtung), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: keiner (App-Target; Smoke in T4)

**Interfaces:**
- Consumes (T2): `applyPermissionsRecursively(filePermissions:directoryPermissions:to:progress:)`, `PermissionsTreeResult`; bestehend: das Rechte-Raster und die Oktal-Eingabe aus M7b (EINWEG-Verhalten der Oktal-Eingabe NICHT verändern — M7b-Review-Fund), der Bestätigungs-Dialog-Stil aus dem Lösch-Fluss.

**Verhaltens-Anforderungen (Spec §4, bindend):**
1. Schalter „Auf alle Unterobjekte anwenden"/„Apply to all enclosed items" — NUR sichtbar, wenn `item.kind == .directory`.
2. Eingeschaltet: Segmente `Gleiche Rechte | Getrennt` („Same permissions" / „Separate"). „Gleiche Rechte": das vorhandene Raster gilt für Dateien UND Ordner. „Getrennt": zwei Raster mit Beschriftung Dateien/Ordner; Vorbelegung = aktuelle Rechte für Dateien und `PosixPermissions.directoryDefault(from:)` für Ordner; beide frei änderbar (inkl. der bestehenden Oktal-Eingabe je Raster).
3. Der Anwenden-Knopf heißt im Rekursiv-Modus „Rekursiv anwenden"/„Apply Recursively" und zeigt VORHER eine Rückfrage mit Zielpfad und Modus (EN „Apply permissions to every item inside %@? This cannot be undone." / DE „Rechte auf alle Objekte in %@ anwenden? Das lässt sich nicht rückgängig machen.").
4. Während des Laufs: das Sheet zeigt eine Fortschrittszeile (laufende Zahlen aus dem Callback) und einen „Abbrechen"-Knopf, der den Task cancelt; die übrigen Bedienelemente sind gesperrt. Danach die Ergebniszeile: „%lld geändert, %lld übersprungen, %lld fehlgeschlagen" (Symlinks-Hinweis im Text: übersprungen = Symlinks), bei Abbruch zusätzlich der Hinweis, dass abgebrochen wurde; bei Fehlern die erste Meldung in Rot.
5. Der Einzelobjekt-Pfad (Schalter aus) bleibt exakt wie heute.
6. Alle neuen Keys EN/DE in beiden App-Katalogen; Grep-Gegenprobe.

- [ ] **Step 1:** Schalter + Segmente + zweites Raster. **Step 2:** Rückfrage + Aufruf + Fortschritt/Abbruch. **Step 3:** Ergebniszeile. **Step 4:** L10n + Gegenprobe. **Step 5:** `swift build` (0 Fehler, keine neuen Warnungen) + volle `swift test`. **Step 6:** Commit `feat: apply permissions recursively from the info sheet`.

---

### Task 4: Abschluss-Verifikation (Koordinator)

- [ ] Gated Rig-Test ergänzen: Baum auf dem Server anlegen (Verzeichnis, Datei, Unterverzeichnis mit Datei, Symlink auf eine Datei AUSSERHALB des Baums), rekursiv 644/755 anwenden, danach per `docker exec stat` prüfen: Rechte im Baum korrekt, **Symlink-Ziel außerhalb UNVERÄNDERT**, `skippedSymlinks == 1`.
- [ ] Rig `start`, `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → alle grün, zero skips, keine Leichen; Rig `stop`.
- [ ] Visueller Smoke — an den Maintainer delegiert (Checkliste: Schalter nur bei Ordnern, beide Modi, Vorbelegung 644⇒755, Rückfrage, Fortschritt + Abbrechen, Ergebniszeile, lokale Seite).
- [ ] Plan-Checkboxen, Ledger, Opus-Final-Review (Package über `git merge-base origin/develop HEAD`), Fix-Runden bis „Yes", Push develop, `gh run watch`, Memory, Zusammenfassung. KEIN Release.
