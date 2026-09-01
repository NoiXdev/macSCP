# macSCP M5d — Resume + reconnect survival implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aborted/interrupted transfers continue from the SFTP offset instead of starting over; a connection loss marks open items as "interrupted" (instead of failed-red), and after reconnecting, ONE click continues all interrupted transfers — byte-identical result.

**Architecture:** Three new FS capabilities (`readStream(path:fromOffset:)`, append-capable `write`, `delete(path:)`). The engine gets a resume mode (stat destination size → read from offset → append → progress from offset). The queue distinguishes connection loss (`connectionFailed` → new status `.interrupted`, items keep their metadata) from real errors; it survives session changes (the queue is NO LONGER recreated per session) and `retryInterrupted(...)` re-enqueues interrupted items with the NEW FS references and `resume: true`. UI: status "interrupted" + banner button "Resume interrupted" after reconnect.

**Scope boundary (deliberate):** NO automatic reconnect with backoff in M5d (the spec point stays in the backlog — the manual reconnect flow exists and the queue survives it; auto-backoff is a separate SSH-layer building block). Resume is size-based (the default for SFTP clients); no checksum comparison of the existing part.

## Global Constraints

- swift-tools 6.0; ALL targets `.swiftLanguageMode(.v5)`; macOS 15; Swift Testing, TDD red→green.
- LANGUAGE POLICY (CLAUDE.md): comments/identifiers ENGLISH; new UI strings via `L10n`/`CoreL10n` with EN source + DE translation in BOTH `.strings` files; `reason:` strings in English.
- All queue invariants remain: exactly-once waiter, cancelAll window (queued/resolving/running), group bookkeeping, FIFO start, conflict-rule reset, slot model.
- Resume semantics (binding): `.cancelled` and `.interrupted` partial files STAY at the destination (resume fodder). `resume: true` in the engine does deliberately NOT skip the conflict check — that happens in the QUEUE, and `retryInterrupted` overrides it (documented): resuming IS the conflict decision.
- Gated tests: `MACSCP_ITEST=1` (rig from the main checkout), `MACSCP_KEYCHAIN=1`.
- Conventional Commits, footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Implementers do not push.

**Dependency graph:** `T1 (FS APIs) → T2 (engine resume) → T3 (queue interrupted/retry) → T4 (UI) → T5 (closeout)` — sequential (each layer consumes the previous one).

---

### Task 1: FS capabilities — offset read, append write, delete

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`, `LocalFileSystem.swift`, `Sources/macSCPCore/SSH/CitadelFileSystem.swift`, `Tests/macSCPCoreTests/MockRemoteFileSystem.swift` (+ QueueTestFS minimal)
- Test: `LocalFileSystemTests.swift`, gated `CitadelFileSystemIntegrationTests.swift`

**Interfaces (binding for T2):**

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

Existing `readStream(path:)`/`write(path:stream:)` stays as a convenience (default offset 0 / .overwrite) — protocol extension, so all conformances stay lean.

**Binding:**
- Citadel: offset read via an `SFTPFile.read(from:)` loop from the offset (extending the existing unfolding pattern); append via OpenFlags without `.truncate` + writing from the file's end (stat the size upfront; if Citadel has an `.append` flag: use it, otherwise offset-write from the end); delete via `sftp.remove`/equivalent (look up the API in the checkout: `.build/checkouts/Citadel/Sources/Citadel/SFTP/`).
- Local: FileHandle `seek(toOffset:)` for reading; append via FileHandle `seekToEnd` (no O_TRUNC); delete via FileManager (file collision: directory at path → `protocolError`).
- Mock/QueueTestFS: offset-capable (slice of contents), append (onto existing data), delete (remove from tree) — recording for T2/T3 tests.
- Unit tests (Local + Mock): offset mid-file/0/past EOF; append onto existing file + onto a non-existent one (=create); delete exists/missing/directory.
- Gated (Docker, /config): write file → read from offset → bytes match; overwrite then append → total content correct (md5 against a locally constructed reference); delete removes (list confirms) + second delete → notFound; offset past EOF → empty.

- [x] Red → implement → green (unit + gated) → Commit `feat: add offset reads, append writes and delete to file systems` (with footer).

---

### Task 2: Engine resume

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/TransferEngine.swift`
- Test: `Tests/macSCPCoreTests/TransferEngineTests.swift`, gated `CitadelFileSystemIntegrationTests.swift` (extend)

**Interfaces (binding for T3):**

```swift
/// resume: if true and the destination already exists SMALLER than the
/// source, continue from its current size (offset read + append write).
/// Destination >= source size: returns immediately reporting full progress
/// (already complete — size-based heuristic, documented). Destination absent:
/// behaves like a fresh transfer. Progress: bytesTransferred starts at the
/// resume offset; totalBytes = full source size.
static func copyFile(..., resume: Bool = false, bytesPerSecondLimit: Int = 0, ...) async throws
```

**Binding:**
- resume=false: behavior UNCHANGED (all 219 tests stay green without adjustment).
- resume=true path: dest stat (notFound → fresh transfer); destSize >= sourceSize → immediate success progress event (bytes=total) and return; otherwise readStream(fromOffset: destSize) + write(mode: .append), progress from destSize, throttle/cancellation act unchanged (post-write gate stays!).
- Unit (Mock): resume mid-file (5 chunks, 2 present → only 3 read from offset, append recorded, progress starts at 2*chunk); dest missing → fresh; dest complete → immediate success without read; dest larger than source → immediate success (documented heuristic); cancellation mid-resume → CancellationError, partial stays.
- Gated (the core test): start a 32 MiB random upload, cancel after the first progress event (partial file stays, size < source — pattern from M5c-T2), then copyFile resume:true → md5 remote == md5 local (BYTE-IDENTICAL after resume!). Second gated: resume on an already complete file → no write (mtime/size unchanged via docker stat).

- [x] Red → implement → green → Commit `feat: resume interrupted transfers from the destination offset` (with footer).

---

### Task 3: Queue — interrupted status, session-surviving queue, retryInterrupted

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`, `Sources/macSCPCore/Resources/{en,de}.lproj/Localizable.strings` (+1 key), `Sources/MacSCPApp/TransferQueueBar.swift` (status branch), `Sources/MacSCPApp/ContentView.swift` (ONLY: no longer recreate transferQueue per session)
- Test: `TransferQueueViewModelTests.swift`

**Interfaces (binding for T4):**

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

**Binding:**
1. Error classification in the worker: `RemoteFSError.connectionFailed` (and only that) → `.interrupted` instead of `.failed`; the waiter still throws (promise contract), onCompleted does not fire. All other errors stay `.failed` unchanged.
2. **The queue survives sessions:** ContentView creates `transferQueue` ONCE (the existing `@State` init suffices — the recreation in `startSession` IS REMOVED). `teardownSession` keeps calling `cancelAll` — BUT: running/queued items cancelled by the teardown stay `.cancelled` (user action); ONLY real connection losses produce `.interrupted`. History (finished/failed/cancelled/interrupted) stays visible in the bar across the session change.
3. `retryInterrupted`: takes the new FS refs (direction decides which is source/destination — the item knows its direction; upload: source=localFS destination=remoteFS, download reversed — the method gets BOTH and chooses per item), resets status back to `.queued`, appends the jobs with resume:true at the end of the order (FIFO in original order), kicks the worker. Exactly-once waiter: interrupted enqueueAndWait waiters were already thrown at interrupt time — retry items have NO waiters (documented; a repeated promise drop produces a fresh item).
4. New Core key `core.transfer.interrupted` = EN "Connection lost — transfer interrupted." / DE "Verbindung verloren — Übertragung unterbrochen." (if a message is needed) + App key `transfers.status.interrupted` = "interrupted"/"unterbrochen" for the bar (orange secondary text).
5. Tests (binding): connectionFailed→`.interrupted` (a different error→`.failed` as contrast); retryInterrupted re-enqueues FIFO with resume:true (mock records the resume flag → engine call assertions via recorded append/offset-read) and flips status; interrupted does NOT retroactively survive cancelAll (cancelAll only cancels queued/running — interrupted stays interrupted); queue persistence across simulated teardown+new-FS (items list stays, retry uses new refs — check mock identity); hasInterrupted flag; renamed items retried under effectiveFileName.

- [x] Red → implement → green (filter + overall) → Commit `feat: keep interrupted transfers resumable across reconnects` (with footer).

---

### Task 4: UI — "Resume interrupted" banner

**Files:**
- Modify: `Sources/MacSCPApp/ContentView.swift`, `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings` (+2 keys)

**Binding:**
1. In the connected view, when `transferQueue.hasInterrupted`: subtle banner above the queue bar (secondary background): text `transfers.interrupted.banner` = EN "Interrupted transfers can be resumed." / DE "Unterbrochene Übertragungen können fortgesetzt werden." + button `transfers.interrupted.resume` = "Resume"/"Fortsetzen" → `transferQueue.retryInterrupted(source:/destination: per direction — method takes localFS+remoteFS of the CURRENT session; serve the T3 signature exactly)`.
2. Banner only with an existing session (the form view does not show it; but the items stay visible in the bar, which is also present in the form state... — the bar lives in the session branch: so the form state shows nothing; ACCEPTED, document it).
3. Headless launch + suite green; visual in T5.

- [x] Implement → green → Commit `feat: offer resuming interrupted transfers after reconnect` (with footer).

---

### Task 5: Closeout verification

- [x] `swift test` full suite; rig up, `MACSCP_ITEST=1` full (incl. new gated), `MACSCP_KEYCHAIN=1` 2/2.
- [x] **Visual kill test (the money shot; keep the screen free):** start a large upload (≥ 64 MiB, limit e.g. 500 KB/s for visibility) → mid-transfer `docker stop macscp-test-sshd` → item goes "interrupted" (orange, not red), app stays stable → `docker start` → reconnect in the app (same session) → banner appears → "Resume" → transfer continues from the offset (progress does not start at 0!) → done → `md5` remote == local BYTE-IDENTICAL. Also: kill during MULTIPLE parallel transfers → all three "interrupted", one Resume click re-enqueues all of them.
- [x] Quick check of partial-file semantics: after cancel the partial file stays; a repeated normal upload of the same file shows the conflict dialog (no silent resume outside retryInterrupted).
- [x] Checkboxes, Commit `docs: mark M5d plan tasks as completed` (with footer).

## Outlook

M5e: editor integration (temp download, watcher, auto-upload). M6: release — among other things, DMG with lproj markers + SPM bundles, auto-reconnect backoff (backlog), global throttle bucket, applyToAll recheck.
