# macSCP M5d — Resume + Reconnect-Überleben Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Abgebrochene/unterbrochene Transfers setzen per SFTP-Offset fort statt neu zu beginnen; ein Verbindungsverlust markiert offene Items als „unterbrochen" (statt rot-fehlgeschlagen), und nach dem Wiederverbinden setzt EIN Klick alle unterbrochenen Transfers fort — byte-identisches Ergebnis.

**Architektur:** Drei neue FS-Fähigkeiten (`readStream(path:fromOffset:)`, append-fähiges `write`, `delete(path:)`). Die Engine bekommt einen Resume-Modus (Ziel-Größe statten → ab Offset lesen → anhängen → Progress ab Offset). Die Queue unterscheidet Verbindungsverlust (`connectionFailed` → neuer Status `.interrupted`, Items behalten ihre Metadaten) von echten Fehlern; sie überlebt Session-Wechsel (Queue wird NICHT mehr pro Session neu erzeugt) und `retryInterrupted(...)` reiht unterbrochene Items mit den NEUEN FS-Referenzen und `resume: true` wieder ein. UI: Status „unterbrochen" + Banner-Button „Unterbrochene fortsetzen" nach Reconnect.

**Scope-Abgrenzung (bewusst):** KEIN automatischer Reconnect mit Backoff in M5d (Spec-Punkt bleibt im Backlog — der manuelle Reconnect-Flow existiert und die Queue überlebt ihn; Auto-Backoff ist ein eigener SSH-Schicht-Baustein). Resume ist größenbasiert (Standard bei SFTP-Clients); kein Checksummen-Vergleich des vorhandenen Teils.

## Global Constraints

- swift-tools 6.0; ALLE Targets `.swiftLanguageMode(.v5)`; macOS 15; Swift Testing, TDD rot→grün.
- SPRACH-POLICY (CLAUDE.md): Kommentare/Identifier ENGLISCH; neue UI-Strings über `L10n`/`CoreL10n` mit EN-Quelle + DE-Übersetzung in BEIDEN `.strings`-Dateien; `reason:`-Strings englisch.
- Alle Queue-Invarianten bleiben: exactly-once-Waiter, cancelAll-Fenster (queued/resolving/running), Gruppen-Buchhaltung, FIFO-Start, Konfliktregel-Reset, Slot-Modell.
- Resume-Semantik (bindend): `.cancelled`- und `.interrupted`-Teil-Dateien BLEIBEN am Ziel liegen (Resume-Futter). `resume: true` in der Engine überspringt die Konfliktprüfung bewusst NICHT — sie findet in der QUEUE statt und `retryInterrupted` setzt sie außer Kraft (dokumentiert): Fortsetzen IST die Konfliktentscheidung.
- Gated Tests: `MACSCP_ITEST=1` (Rig aus Haupt-Checkout), `MACSCP_KEYCHAIN=1`.
- Conventional Commits, Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Implementierer pushen nicht.

**Abhängigkeitsgraph:** `T1 (FS-APIs) → T2 (Engine-Resume) → T3 (Queue interrupted/retry) → T4 (UI) → T5 (Abschluss)` — sequentiell (jede Schicht konsumiert die vorige).

---

### Task 1: FS-Fähigkeiten — Offset-Read, Append-Write, Delete

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`, `LocalFileSystem.swift`, `Sources/macSCPCore/SSH/CitadelFileSystem.swift`, `Tests/macSCPCoreTests/MockRemoteFileSystem.swift` (+ QueueTestFS minimal)
- Test: `LocalFileSystemTests.swift`, gated `CitadelFileSystemIntegrationTests.swift`

**Interfaces (bindend für T2):**

```swift
/// Streams the file starting at `offset` (bytes). Offset 0 behaves exactly
/// like the plain readStream. Offset beyond EOF yields an empty stream.
func readStream(path: String, fromOffset offset: UInt64) -> AsyncThrowingStream<[UInt8], Error>

/// Write mode for `write`: .overwrite truncates/creates (today's behavior),
/// .append opens existing (or creates) and appends at the end.
enum WriteMode { case overwrite, append }   // Sendable, Equatable
func write(path: String, mode: WriteMode, stream: AsyncThrowingStream<[UInt8], Error>) async throws

/// Deletes a FILE (not a directory). notFound if absent.
func delete(path: String) async throws
```

Bestehendes `readStream(path:)`/`write(path:stream:)` bleibt als Konvenienz (default offset 0 / .overwrite) — Protokoll-Extension, damit alle Konformitäten schlank bleiben.

**Bindend:**
- Citadel: Offset-Read via `SFTPFile.read(from:)`-Schleife ab Offset (bestehendes unfolding-Muster erweitern); Append via OpenFlags ohne `.truncate` + Schreiben ab Datei-Ende (Größe vorab statten; falls Citadel `.append`-Flag hat: nutzen, sonst Offset-Write ab Ende); Delete via `sftp.remove`/äquivalent (API im Checkout nachschlagen: `.build/checkouts/Citadel/Sources/Citadel/SFTP/`).
- Local: FileHandle `seek(toOffset:)` fürs Lesen; Append via FileHandle `seekToEnd` (kein O_TRUNC); Delete via FileManager (Datei-Kollision: Verzeichnis am Pfad → `protocolError`).
- Mock/QueueTestFS: offset-fähig (Slice des Contents), append (an vorhandene Daten anhängen), delete (aus Tree entfernen) — Aufzeichnung für T2/T3-Tests.
- Unit-Tests (Local + Mock): offset mitten/0/hinter EOF; append an bestehende Datei + auf nicht-existente (=create); delete existiert/fehlt/Verzeichnis.
- Gated (Docker, /config): Datei schreiben → ab Offset lesen → Bytes stimmen; overwrite dann append → Gesamtinhalt korrekt (md5 gegen lokal konstruierte Referenz); delete entfernt (list bestätigt) + zweites delete → notFound; Offset hinter EOF → leer.

- [ ] Rot → implementieren → grün (Unit + gated) → Commit `feat: add offset reads, append writes and delete to file systems` (mit Footer).

---

### Task 2: Engine-Resume

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/TransferEngine.swift`
- Test: `Tests/macSCPCoreTests/TransferEngineTests.swift`, gated `CitadelFileSystemIntegrationTests.swift` (ergänzen)

**Interfaces (bindend für T3):**

```swift
/// resume: if true and the destination already exists SMALLER than the
/// source, continue from its current size (offset read + append write).
/// Destination >= source size: returns immediately reporting full progress
/// (already complete — size-based heuristic, documented). Destination absent:
/// behaves like a fresh transfer. Progress: bytesTransferred starts at the
/// resume offset; totalBytes = full source size.
static func copyFile(..., resume: Bool = false, bytesPerSecondLimit: Int = 0, ...) async throws
```

**Bindend:**
- resume=false: Verhalten UNVERÄNDERT (alle 219 Tests bleiben ohne Anpassung grün).
- resume=true-Pfad: dest-stat (notFound → frischer Transfer); destSize >= sourceSize → sofortiges Erfolgs-Progress-Event (bytes=total) und Return; sonst readStream(fromOffset: destSize) + write(mode: .append), Progress ab destSize, Drossel/Cancellation wirken unverändert (Post-Write-Gate bleibt!).
- Unit (Mock): resume mitten (5 Chunks, 2 vorhanden → nur 3 gelesen ab Offset, append aufgezeichnet, Progress startet bei 2*chunk); dest fehlt → frisch; dest komplett → Sofort-Erfolg ohne Read; dest größer als Quelle → Sofort-Erfolg (dokumentierte Heuristik); Cancellation mitten im Resume → CancellationError, Teil bleibt.
- Gated (der Kerntest): 32-MiB-Random-Upload starten, nach erstem Progress canceln (Teil-Datei bleibt, Größe < Quelle — Muster aus M5c-T2), dann copyFile resume:true → md5 remote == md5 lokal (BYTE-IDENTISCH nach Resume!). Zweiter gated: Resume auf bereits kompletter Datei → kein Write (mtime/Größe unverändert via docker stat).

- [ ] Rot → implementieren → grün → Commit `feat: resume interrupted transfers from the destination offset` (mit Footer).

---

### Task 3: Queue — interrupted-Status, Session-überdauernde Queue, retryInterrupted

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`, `Sources/macSCPCore/Resources/{en,de}.lproj/Localizable.strings` (+1 Key), `Sources/MacSCPApp/TransferQueueBar.swift` (Status-Zweig), `Sources/MacSCPApp/ContentView.swift` (NUR: transferQueue nicht mehr pro Session neu erzeugen)
- Test: `TransferQueueViewModelTests.swift`

**Interfaces (bindend für T4):**

```swift
// Item.Status gains:
case interrupted            // connection lost mid-transfer; resumable
// Item gains (internal storage, public read where needed):
//   retained metadata: sourcePath, destinationDirectory, effectiveFileName (post-rename!)
public var hasInterrupted: Bool { get }
/// Re-enqueues all .interrupted items FIFO (original order) against the NEW
/// session's file systems, with resume semantics (engine resume:true, conflict
/// check bypassed by design — resuming IS the decision). Items flip back to
/// .queued; group membership is NOT revived (interrupted tree items retry as
/// individuals; the group already fired or died with the disconnect).
public func retryInterrupted(
    source: any RemoteFileSystem, destination: any RemoteFileSystem)
```

**Bindend:**
1. Fehler-Klassifikation im Worker: `RemoteFSError.connectionFailed` (und nur diese) → `.interrupted` statt `.failed`; Waiter wirft weiterhin (Promise-Kontrakt), onCompleted feuert nicht. Alle anderen Fehler unverändert `.failed`.
2. **Queue überlebt Sessions:** ContentView erzeugt `transferQueue` EINMAL (bestehendes `@State`-Init reicht — die Neu-Erzeugung in `startSession` ENTFÄLLT). `teardownSession` ruft weiter `cancelAll` — ABER: laufende/queued Items, die durch den Teardown gecancelt werden, bleiben `.cancelled` (User-Aktion); NUR echte Verbindungsverluste erzeugen `.interrupted`. Historie (finished/failed/cancelled/interrupted) bleibt über den Session-Wechsel in der Leiste sichtbar.
3. `retryInterrupted`: nimmt die neuen FS-Refs (Richtung entscheidet, welches source/destination ist — Item kennt seine direction; Upload: source=localFS destination=remoteFS, Download umgekehrt — die Methode bekommt BEIDE und wählt pro Item), setzt Status zurück auf `.queued`, hängt die Jobs mit resume:true ans Ende der order (FIFO in Original-Reihenfolge), kickt den Worker. Exactly-once-Waiter: unterbrochene enqueueAndWait-Waiter wurden beim Interrupt bereits geworfen — Retry-Items haben KEINE Waiter (dokumentiert; ein erneuter Promise-Drop erzeugt ein frisches Item).
4. Neuer Core-Key `core.transfer.interrupted` = EN "Connection lost — transfer interrupted." / DE „Verbindung verloren — Übertragung unterbrochen." (falls eine Message gebraucht wird) + App-Key `transfers.status.interrupted` = "interrupted"/„unterbrochen" für die Leiste (oranger Sekundärtext).
5. Tests (bindend): connectionFailed→`.interrupted` (anderer Fehler→`.failed` als Kontrast); retryInterrupted re-enqueued FIFO mit resume:true (Mock zeichnet resume-Flag auf → Engine-Aufruf-Assertions via aufgezeichnetem append/offset-Read) und flippt Status; interrupted überlebt cancelAll NICHT rückwirkend (cancelAll cancelt nur queued/running — interrupted bleibt interrupted); Queue-Persistenz über simuliertes teardown+neue-FS (Items-Liste bleibt, retry nutzt neue Refs — Mock-Identität prüfen); hasInterrupted-Flag; Rename-Items retried unter effectiveFileName.

- [ ] Rot → implementieren → grün (Filter + Gesamt) → Commit `feat: keep interrupted transfers resumable across reconnects` (mit Footer).

---

### Task 4: UI — Banner „Unterbrochene fortsetzen"

**Files:**
- Modify: `Sources/MacSCPApp/ContentView.swift`, `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings` (+2 Keys)

**Bindend:**
1. In der verbundenen Ansicht, wenn `transferQueue.hasInterrupted`: dezenter Banner über der Queue-Leiste (Sekundär-Hintergrund): Text `transfers.interrupted.banner` = EN "Interrupted transfers can be resumed." / DE „Unterbrochene Übertragungen können fortgesetzt werden." + Button `transfers.interrupted.resume` = "Resume"/„Fortsetzen" → `transferQueue.retryInterrupted(source:/destination: je Richtung — Methode nimmt localFS+remoteFS der AKTUELLEN Session; Signatur aus T3 exakt bedienen)`.
2. Banner nur bei bestehender Session (Formular-Ansicht zeigt ihn nicht; die Items bleiben aber in der Leiste sichtbar, die auch im Formular-Zustand... — die Leiste lebt im Session-Zweig: dann zeigt der Formular-Zustand nichts; AKZEPTIERT, dokumentieren).
3. Headless-Launch + Suite grün; visuell in T5.

- [ ] Implementieren → grün → Commit `feat: offer resuming interrupted transfers after reconnect` (mit Footer).

---

### Task 5: Abschluss-Verifikation

- [ ] `swift test` gesamt; Rig hoch, `MACSCP_ITEST=1` voll (inkl. neuer gated), `MACSCP_KEYCHAIN=1` 2/2.
- [ ] **Visueller Kill-Test (der Money-Shot; Bildschirm frei):** großen Upload starten (≥ 64 MiB, Limit z. B. 500 KB/s für Sichtbarkeit) → mitten drin `docker stop macscp-test-sshd` → Item wird „unterbrochen" (orange, nicht rot), App bleibt stabil → `docker start` → in der App neu verbinden (gleiche Session) → Banner erscheint → „Fortsetzen" → Transfer läuft ab Offset weiter (Progress startet nicht bei 0!) → fertig → `md5` remote == lokal BYTE-IDENTISCH. Zusätzlich: Kill während MEHRERER paralleler Transfers → alle drei „unterbrochen", ein Fortsetzen-Klick reiht alle wieder ein.
- [ ] Kurz-Check Teil-Datei-Semantik: nach Cancel bleibt Teil-Datei liegen; erneuter normaler Upload derselben Datei zeigt Konflikt-Dialog (kein stilles Resume außerhalb retryInterrupted).
- [ ] Checkboxen, Commit `docs: mark M5d plan tasks as completed` (mit Footer).

## Ausblick

M5e: Editor-Integration (Temp-Download, Watcher, Auto-Upload). M6: Release — dort u. a. DMG mit lproj-Markern + SPM-Bundles, Auto-Reconnect-Backoff (Backlog), globaler Drossel-Bucket, applyToAll-Recheck.
