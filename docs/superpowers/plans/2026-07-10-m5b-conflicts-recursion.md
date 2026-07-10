# macSCP M5b — Konfliktregeln + rekursive Verzeichnis-Transfers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Existiert die Zieldatei, fragt macSCP (überschreiben/überspringen/umbenennen — einmalig oder als Regel für die Queue); Ordner lassen sich rekursiv übertragen (Drop und Buttons), inklusive Anlegen der Zielstruktur.

**Architektur:** `RemoteFileSystem` bekommt idempotentes `createDirectory`. Die Konfliktprüfung lebt im Worker des `TransferQueueViewModel` (vor `copyFile`: Ziel-stat; Entscheidung via injiziertem async-`ConflictDecider` — UI-Brücke nach dem Continuation-Muster des Host-Key-Prompts). Rekursion als Expansions-Task: Baum laufen, Zielverzeichnisse anlegen, Dateien als normale Queue-Items einreihen; Gruppen-Buchhaltung feuert `onCompleted` erst, wenn ALLE Items des Baums terminal sind.

**Tech Stack:** Bestehende Queue/Engine unverändert im Kern; Citadel `SFTPClient.createDirectory`; FileManager.

## Global Constraints

- swift-tools 6.0; ALLE Targets `.swiftLanguageMode(.v5)`; macOS 15; Swift Testing, TDD rot→grün.
- Gated Tests: `MACSCP_ITEST=1` (Rig NUR aus dem Haupt-Checkout starten; PerSourcePenalties ist seit 5688f49 deaktiviert), `MACSCP_KEYCHAIN=1`.
- Queue-Invarianten aus M5a bleiben unangetastet: FIFO, exactly-once-Waiter, cancelAll-Semantik, Worker-Neustart. KEIN Cancel-while-active-UI (M5c-Vorbedingung: kooperative Cancellation).
- Ohne gesetzten Decider verhält sich die Queue wie M5a: stilles Überschreiben (Rückwärtskompatibilität, deckt CLI/Tests).
- Duo-Farben-Semantik, deutsche UI-Texte, System-Rot für Fehler.
- Conventional Commits, Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Implementierer pushen nicht.

**Abhängigkeitsgraph:** `[ Task 1 (createDirectory, Core-FS) ∥ Task 2 (Konflikt-Maschinerie, Queue) ] → Task 3 (Rekursion, Queue) → Task 4 (Konflikt-Sheet + Ordner-Wege, UI) → Task 5 (Abschluss)` — T1/T2 dateidisjunkt (Worktree-parallel).

---

### Task 1: `createDirectory` im Protocol + beiden Implementierungen

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`
- Modify: `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift`
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift`
- Modify: `Tests/macSCPCoreTests/MockRemoteFileSystem.swift` (Konformität)
- Test: `Tests/macSCPCoreTests/LocalFileSystemTests.swift` (ergänzen), `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift` (gated ergänzen)

**Interfaces:**
- Produces (bindend für T3):

```swift
/// Legt das Verzeichnis an. IDEMPOTENT: existiert es bereits als Verzeichnis,
/// kehrt der Aufruf still zurück. Existiert am Pfad eine DATEI, wirft
/// RemoteFSError.protocolError. Fehlende Zwischenverzeichnisse: Local legt sie
/// an (withIntermediateDirectories); Citadel legt NUR die letzte Ebene an —
/// die Rekursion (T3) läuft top-down, Eltern existieren daher immer.
func createDirectory(at path: String) async throws
```

- [x] **Step 1: Fehlschlagende Tests**
  - Local: legt Verzeichnis an; idempotent bei zweitem Aufruf; wirft `protocolError` wenn am Pfad eine Datei liegt; legt Zwischenebenen an.
  - Mock: `createdDirectories`-Protokollierung (für T3-Tests); Verzeichnis erscheint im Mock-Tree.
  - Gated (Docker): `createDirectory(at: "/config/macscp-mkdir-test/sub")`? — NEIN: Citadel legt nur letzte Ebene an → Test: erst `/config/macscp-mkdir-test`, dann `/config/macscp-mkdir-test/sub`; Idempotenz-Zweitaufruf; Datei-Kollision (`write` einer Datei, dann createDirectory am selben Pfad → Fehler); Cleanup via `docker exec` oder SFTP-delete falls vorhanden — sonst eindeutiger Name pro Lauf + Cleanup-Hinweis im Test-Kommentar.
- [x] **Step 2: Rot** (Compile-Fehler in Konformitäten).
- [x] **Step 3: Implementieren**
  - Local: `FileManager.createDirectory(atPath:withIntermediateDirectories:true)`; vorher `fileExists(isDirectory:)`-Check für die Datei-Kollision (→ `protocolError(reason: "Pfad existiert als Datei: \(path)")`).
  - Citadel: `try await sftp.createDirectory(atPath: path)`; Fehler abfangen → wenn `stat(path)` danach ein Verzeichnis liefert: still ok (Race/exists); wenn stat eine Datei liefert: `protocolError`; sonst Original-Fehler durch `mapSFTPError`.
- [x] **Step 4: Grün** — Filter + Gesamtsuite; gated 15/15 + neue.
- [x] **Step 5: Commit** — `feat: add idempotent createDirectory to remote file systems` (mit Footer).

---

### Task 2: Konflikt-Maschinerie im TransferQueueViewModel

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`
- Test: `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift` (ergänzen)

**Interfaces:**
- Produces (bindend für T4):

```swift
public enum ConflictResolution: Sendable, Equatable { case overwrite, skip, rename }

public struct TransferConflict: Sendable, Equatable {
    public let fileName: String
    public let destinationDirectory: String
    public let direction: TransferDirection
}

/// UI-Entscheider. Rückgabe nil == "Abbrechen" (Item wird .cancelled).
/// applyToAll == true setzt die Entscheidung als Regel für den Rest der Queue.
public typealias ConflictDecider =
    @Sendable (TransferConflict) async -> (resolution: ConflictResolution, applyToAll: Bool)?

// Am VM:
public var conflictDecider: ConflictDecider?   // nil (Default) => stilles Überschreiben wie M5a
// Item.Status bekommt zusätzlich:
case skipped                                    // deutsch: "übersprungen" (UI in T4/T2-Bar-Anpassung)
// Item.fileName wird `internal(set) var` (rename aktualisiert den angezeigten Namen).
```

**Semantik (bindend):**
1. Vor `copyFile` prüft der Worker per `destination.stat` (Pfad-Join EXAKT wie `TransferEngine` — dort nachschlagen und denselben Helfer nutzen/extrahieren), ob das Ziel existiert. `notFound` → kein Konflikt. Andere stat-Fehler → Item `.failed` (Meldung via `message(for:)`).
2. Konflikt + aktive Queue-Regel → Regel anwenden ohne Rückfrage.
3. Konflikt ohne Regel: `conflictDecider` nil → `.overwrite`. Sonst await Decider (der Worker blockiert — seriell, also genau EIN offener Prompt). nil → Item `.cancelled`, Waiter (enqueueAndWait) wirft `CancellationError`. `applyToAll` → Regel setzen.
4. `.skip` → Item `.skipped`, `onCompleted` wird NICHT gerufen, Waiter wirft `CancellationError` (Promise-Kontrakt: Datei kam nicht an).
5. `.rename` → freien Namen suchen: "name (2).ext", "name (3).ext", … (Basisname/Extension via letztem Punkt; ohne Extension "name (2)"); Probe per `stat` bis `notFound`, Obergrenze 999 → sonst `.failed("Kein freier Name…")`. Transfer läuft unter neuem Namen; `items[idx].fileName` wird auf den neuen Namen aktualisiert.
6. **Regel-Lebensdauer:** Die Queue-Regel gilt, bis der Worker leerläuft (Drain) — beim Worker-Ende (`workerTask = nil`-Pfad) wird sie zurückgesetzt. Neue Batches fragen wieder.
7. `TransferQueueBar` (kleine Anpassung hier in T2, Datei `Sources/MacSCPApp/TransferQueueBar.swift`): `case .skipped: Text("übersprungen")` grau — sonst bricht der exhaustive Switch.

- [x] **Step 1: Fehlschlagende Tests** (Mock-Tree so präparieren, dass Ziel existiert):
  1. `conflictWithoutDeciderOverwrites` (M5a-Verhalten)
  2. `deciderSkipMarksSkippedAndSkipsWrite` (kein Write im Mock, kein onCompleted)
  3. `deciderOverwriteWrites`
  4. `deciderRenameWritesUnderFreeName` — "(2)" belegt → landet bei "(3)"; Item-fileName aktualisiert
  5. `deciderCancelCancelsItem` (nil → .cancelled; enqueueAndWait wirft)
  6. `applyToAllAsksOnlyOnce` (2 Konflikte, Decider-Callcount == 1)
  7. `ruleResetsAfterDrain` (Batch 1 mit applyToAll, Drain abwarten, Batch 2 → Decider wieder gefragt)
  8. `noConflictDoesNotAskDecider` (Ziel existiert nicht → Callcount 0)
- [x] **Step 2: Rot.**
- [x] **Step 3: Implementieren** (Konfliktlogik als private Funktion `resolveConflictIfNeeded(job:) async -> Outcome` vor dem Engine-Aufruf in `process`).
- [x] **Step 4: Grün** — Filter (17 = 9 + 8), Gesamtsuite.
- [x] **Step 5: Commit** — `feat: add conflict rules to the transfer queue` (mit Footer).

---

### Task 3: Rekursive Verzeichnis-Transfers (Expansion + Gruppen)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`
- Test: `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift` (ergänzen)

**Interfaces:**
- Consumes: `createDirectory` (T1), `list`/`stat` des Protocols.
- Produces (bindend für T4):

```swift
/// Reiht einen kompletten Ordner ein: legt Zielverzeichnisse an (top-down)
/// und enqueued jede Datei als eigenes Queue-Item. `onCompleted` feuert genau
/// einmal, wenn ALLE Items des Baums terminal sind (finished/failed/skipped/
/// cancelled) — auch bei Teilfehlern. Symlinks werden übersprungen (Item mit
/// Status .skipped und Namensuffix " →"). Expansions-Fehler (list/mkdir)
/// erscheinen als .failed-Item unter dem Ordnernamen mit "/" -Suffix.
public func enqueueTree(
    directoryName: String, direction: TransferDirection,
    source: any RemoteFileSystem, sourceDirectory: String,
    destination: any RemoteFileSystem, destinationDirectory: String,
    onCompleted: (@MainActor () async -> Void)?
)
```

**Semantik (bindend):**
- Expansion läuft als eigene MainActor-Task VOR den Transfers: BFS/DFS top-down; erst `createDirectory(dest)/dirName`, dann `list(source)`: Dateien → `enqueue` (mit Gruppen-Zuordnung), Unterverzeichnisse → rekursiv (mkdir + Abstieg), Symlinks → sofort terminales `.skipped`-Item.
- Gruppen-Buchhaltung: `enqueueTree` registriert eine Gruppe; jede terminale Statusänderung eines Gruppen-Items dekrementiert; bei 0 (und Expansion abgeschlossen) → `onCompleted` genau einmal. Expansion-Fehler beendet die Expansion des betroffenen Zweigs, bereits enqueued Items laufen weiter; das Fehler-Item zählt zur Gruppe.
- `cancelAll` während Expansion: Expansion-Task wird gecancelt (Task speichern + in `cancelAll` canceln + awaiten), Rest wie gehabt.
- Datei-Items der Gruppe durchlaufen die T2-Konfliktlogik unverändert.

- [x] **Step 1: Fehlschlagende Tests** (Mock-Tree mit Struktur `dir/{a.txt, sub/{b.txt}, link→x, leer/}`):
  1. `treeCreatesDirectoriesTopDown` (Mock-`createdDirectories`-Reihenfolge: dir vor dir/sub vor Datei-Writes)
  2. `treeTransfersAllFilesAndFiresOnCompletedOnce`
  3. `treeSkipsSymlinks` (Item .skipped, kein Write)
  4. `treeCreatesEmptyDirectories`
  5. `treeOnCompletedWaitsForLastItem` (Signal-Mock: onCompleted erst nach letztem finish)
  6. `treeExpansionErrorProducesFailedItemButOthersRun` (list wirft in einem Unterordner)
  7. `treePartialFailureStillFiresOnCompleted` (eine Datei failt → onCompleted trotzdem, genau 1×)
  8. `cancelAllDuringExpansionStopsCleanly` (Expansion an Signal gebunden; cancelAll → keine neuen Items, Gruppe aufgeräumt, isActive false)
- [x] **Step 2: Rot.** — [ ] **Step 3: Implementieren.** — [ ] **Step 4: Grün** (Filter 25 = 17 + 8; Gesamtsuite).
- [x] **Step 5: Commit** — `feat: add recursive directory transfers to the queue` (mit Footer).

---

### Task 4: UI — Konflikt-Sheet + Ordner über Drop und Buttons

**Files:**
- Modify: `Sources/MacSCPApp/ContentView.swift`

**Interfaces:**
- Consumes: `ConflictDecider`/`TransferConflict`/`ConflictResolution` (T2), `enqueueTree` (T3).

- [x] **Step 1: Konflikt-Brücke** (Muster: Host-Key-Prompt aus `ConnectionViewModel`/`ConnectionFormView`, inkl. Cancellation-Handler):
  - `@State private var conflictPrompt: TransferConflict?` + private Continuation-Feld in einer kleinen `@Observable`-Hilfsklasse ODER direkt im View-State (ContentView ist Struct → Continuation in einer Box/Hilfsklasse halten; sauberste Variante: kleine `@MainActor final class ConflictPromptBridge` im selben File mit `ask(_:) async` + `resolve(_:)`, Continuation exactly-once + Cancellation-Handler wie in `presentHostKeyPrompt`).
  - In `startSession`: `transferQueue.conflictDecider = { conflict in await bridge.ask(conflict) }`.
  - Sheet (`.sheet(item:)` auf dem Detail-Bereich, `TransferConflict` dafür `Identifiable` via fileName+dir — oder ein `@State`-Wrapper mit UUID):
    Titel „Datei existiert bereits", Text „\(fileName)" existiert in „\(destinationDirectory)"." — Buttons: **Überschreiben** (destruktive Rolle), **Überspringen**, **Umbenennen**, **Abbrechen** (Cancel-Rolle); Toggle „Für alle weiteren übernehmen". Deutsche Texte, System-Farben.
- [x] **Step 2: Ordner-Wege**
  - `uploadDropped`: Directory-Filter ENTFERNEN; `isDirectory` → `transferQueue.enqueueTree(directoryName: url.lastPathComponent, …, sourceDirectory: url.path…, destinationDirectory: session.remote.currentPath, onCompleted: { await session.remote.refresh() })`, Dateien wie gehabt.
  - Upload-/Download-Button: `.disabled(selected == nil)` (kind-Einschränkung weg); im Handler: `selected.kind == .directory` → `enqueueTree`, sonst `enqueue`. Symlink-Auswahl bleibt disabled (`selected?.kind == .symlink` → disabled beibehalten).
  - Finder-Promise bleibt DATEI-only (Pasteboard-Writer unverändert: `item.kind == .file`).
- [x] **Step 3: Grün + Headless-Launch** — `swift build && swift test`; Bundle-Wrapper-Launch-Check.
- [x] **Step 4: Commit** — `feat: add conflict dialog and folder transfers` (mit Footer).

---

### Task 5: Abschluss-Verifikation

- [x] **Step 1:** `swift test` — Gesamtsuite grün (erwartet ≈ 155 + T1-Unit + 16 Queue-Tests; exakt im Report).
- [x] **Step 2:** Rig hoch (HAUPT-Checkout), `MACSCP_ITEST=1` (15 + neue mkdir-Tests), `MACSCP_KEYCHAIN=1` 2/2.
- [x] **Step 3: Visueller Smoke-Test** (Koordinator; Rig läuft; NUR wenn der Bildschirm frei ist — User-Aktivität respektieren):
  a) Konflikt: Datei doppelt hochladen → Sheet erscheint; alle vier Wege durchspielen (Überschreiben / Überspringen → „übersprungen" / Umbenennen → „x (2).ext" erscheint remote / Abbrechen → „abgebrochen"); „Für alle weiteren" mit 2+ Konflikten → nur EIN Sheet.
  b) Rekursion: lokalen Ordner mit Unterordner + leerem Ordner droppen → Struktur remote korrekt (`docker exec find`), Items pro Datei in der Leiste, Refresh am Ende; einen Remote-Ordner per Button herunterladen → `diff -r` sauber.
  c) M5a-Nachholer: Remote-Datei → Finder ziehen WÄHREND Queue arbeitet (Item erscheint, Datei byte-identisch); ⌘T aus/ein bei laufender Shell → Screen bleibt (Replay); nach Queue-Ende ist „Trennen" wieder aktiv und trennt sauber.
- [x] **Step 4:** Checkboxen, Commit `docs: mark M5b plan tasks as completed` (mit Footer).

## Ausblick

M5c: kooperative Cancellation in Engine/FS (VORBEDINGUNG für Cancel-Button), Resume (SFTP-Offset), Rate/ETA, Reconnect-Überleben, Parallelität → 3, enqueueAndWait-Timeout, Promise-Drag-Fenster. M5d: Editor-Integration. Danach M6 Release.
