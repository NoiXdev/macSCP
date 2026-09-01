# macSCP M5c — Settings + Transfer Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Central settings window (⌘,) with switches that actually work — maximum concurrent transfers (1–8, default 3) and bandwidth limits up/down — plus cooperative transfer cancellation ("Cancel all" becomes real), rate/ETA in the bar, and the compact connection window.

**Architecture:** `SettingsStore` (Core, JSON in the Application Support directory following the `SessionStore` pattern, forward-compatible: unknown keys survive load/save). SwiftUI `Settings` scene with a "Transfers" tab. Cooperative cancellation via `Task.checkCancellation()` in the `TransferEngine`'s chunk loop (covers both FS directions — the loop is the shared bottleneck). Queue gets N parallel worker slots (setting-driven; gated beforehand, empirically validated that multiple transfers run cleanly over ONE SFTP channel). Throttling as a token-time calculation in the same chunk loop. `TransferProgress` grows a rate/ETA (sliding window in the queue consumer, not in the engine).

**Tech Stack:** Existing engine/queue; SwiftUI `Settings` scene; no new dependencies.

## Global Constraints

- swift-tools 6.0; ALL targets `.swiftLanguageMode(.v5)`; macOS 15; Swift Testing, TDD red→green.
- Gated tests: `MACSCP_ITEST=1` (rig ONLY from the main checkout), `MACSCP_KEYCHAIN=1`.
- Queue invariants (M5a/M5b) stay: exactly-once waiter, cancelAll semantics including the resolvingJobID window, group accounting exactly-once, conflict-rule reset on drain. FIFO *start* order stays preserved with N workers (slots pull in turn from `order`); completion order may differ.
- Settings defaults: `maxConcurrentTransfers = 3` (1–8), `uploadLimitKBs = 0`, `downloadLimitKBs = 0` (0 = unlimited). Without a settings file the defaults apply; the app behaves with defaults (except parallelism 3 instead of 1) like M5b.
- NO secrets in the SettingsStore. German UI text; duo color semantics; Conventional Commits with footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Implementers do not push.

**Dependency graph:** `[ T0 (window+tests) ∥ T1 (SettingsStore) ∥ T2 (cancellation, RISK) ] → [ T3 (settings UI) ∥ T4 (N workers, RISK) ] → T5 (throttle + rate/ETA) → T6 (wrap-up)` — T0/T1/T2 file-disjoint (worktrees); T3 (App settings files) ∥ T4 (Core queue) likewise disjoint.

---

### Task 0: Opening — compact connection window + missing tree tests

**Files:**
- Modify: `Sources/MacSCPApp/MacSCPApp.swift`, `Sources/MacSCPApp/ContentView.swift`
- Test: `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift` (extend)

**Part A — window (user feedback 2026-07-10):** The form window is too large, the content sits too low. Binding:
1. Form state (`session == nil`): compact window — content minimum size approx. 700×440, form aligned TOP (VStack with a spacer at the bottom, or `.frame(maxHeight: .infinity, alignment: .top)` on the detail branch), not vertically centered.
2. Browser state: minimum size 930×460 as before.
3. On a state change the window ACTIVELY adapts (animated): connecting → grows to at least 930×620 (or the last browser size, if remembered — a simple `@State` remembered size suffices); disconnecting → shrinks to ~700×460.
4. Implementation: REMOVE the global `.frame(minWidth: 930, ...)` in `MacSCPApp.swift`; conditional `.frame(minWidth: session == nil ? 700 : 930, minHeight: 460)` in ContentView; NSWindow access via a small `WindowAccessor` (`NSViewRepresentable`, a `weak var window` passed up via callback suffices) + `window.setFrame(_:display:animate:)` calls in `startSession`/`teardownSession` (set window width/height, keep position: pin top-left).
5. Verification, Part A: headless launch + visual check in T6 (no unit test for an AppKit window).

**Part B — tree tests (M5b final review, backlog e):** two tests in the existing style (signal mocks):
- `twoConcurrentTreesKeepIndependentGroups` — two `enqueueTree` calls in sequence (different folders), both onCompleted fire exactly 1× each, item assignment clean.
- `emptyTreeFiresOnCompleted` — a folder with no files (only empty subfolders): onCompleted fires exactly 1×, `createdDirectories` contains both levels.

- [x] Step 1: Part B tests red (if they turn out green against expectation: document it — they then merely pin; no implementation need per the review trace).
- [x] Step 2: implement Part A; `swift build && swift test` green (185 + 2 = 187), headless launch ok.
- [x] Step 3: Commit `fix: compact connection window and pin tree accounting tests` (with footer).

---

### Task 1: SettingsStore (Core)

**Files:**
- Create: `Sources/macSCPCore/Settings/SettingsStore.swift`
- Test: `Tests/macSCPCoreTests/SettingsStoreTests.swift`

**Interfaces (binding for T3/T4/T5):**

```swift
/// Zentrale App-Einstellungen. JSON in <directory>/settings.json —
/// VORWÄRTSKOMPATIBEL: unbekannte Schlüssel bleiben beim Speichern erhalten
/// (Roundtrip über ein rohes [String: JSONValue]-Backing, typisierte Accessoren
/// obendrauf). Kein Geheimnis-Speicher.
@Observable @MainActor
public final class SettingsStore {
    public static let defaultDirectory: URL   // == SessionStore.defaultDirectory
    public init(directory: URL)               // lädt sofort; fehlende Datei => Defaults

    /// Maximale gleichzeitige Übertragungen (geklemmt auf 1...8, Default 3).
    public var maxConcurrentTransfers: Int { get set }   // Setter speichert
    /// Bandbreiten-Limits in KB/s; 0 = unbegrenzt (Default 0). Geklemmt >= 0.
    public var uploadLimitKBs: Int { get set }
    public var downloadLimitKBs: Int { get set }
}
```

**Binding tests:** defaults without a file; persistence roundtrip; clamping (0→1, 99→8, negative limit→0); UNKNOWN keys in the JSON survive load+change+save (write a fixture with a foreign key to disk, then verify); corrupt JSON → defaults + no crash (the file gets replaced on the next save); the directory is created when needed.

- [x] Red → implement → green (filter + total) → Commit `feat: add forward-compatible settings store` (with footer).

---

### Task 2: Cooperative cancellation (engine/FS) — RISK

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/TransferEngine.swift`
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift` (only if the stream unfolds need their own checks)
- Test: `Tests/macSCPCoreTests/TransferEngineTests.swift`, gated `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift` (extend)

**Background (M5c PRECONDITION from the M5a final review):** `cancelAll` cancels the running transfer task, but `copyFile` never checks cancellation → the transfer runs to its natural end (`.finished` instead of `.cancelled`). Grep-verified: no `Task.isCancelled`/`checkCancellation` anywhere in the engine path.

**Binding:**
1. `TransferEngine.copyFile`: `try Task.checkCancellation()` BEFORE every chunk write (in the source stream's consume loop). Effect: cancellation takes effect chunk-precise (64 KiB), throws `CancellationError`, the queue maps it to `.cancelled` as before.
2. Document cleanup semantics (existing review note M2c): partial writes are NOT rolled back — add a doc comment on `copyFile` ("cancellation may leave a partial file at the destination; cleanup is the caller's/M5d resume's responsibility").
3. Unit test (mock): transfer with a signal-throttled source stream; cancel the task; assert `CancellationError` is thrown, the destination mock has < all chunks, NO further chunk after the cancel point.
4. Unit test (queue level, `TransferQueueViewModelTests`): running transfer with a throttled stream; `cancelAll()`; item ends `.cancelled` (not `.finished`), cancelAll returns PROMPTLY (timeout race < 2 s instead of natural end).
5. Gated test: large upload (≥ 64 MiB random) against the rig; cancel the task after the first progress event; assert the error is CancellationError and the remote partial file is TRULY smaller than the source (docker exec stat); the connection/SFTP stays usable afterward (list ok).
6. M5a/M5b invariants left untouched; `.serialized` where needed against rig flakiness.

- [x] Red (tests 3+4 against the current state: 3 hangs/delivers all chunks, 4 ends .finished) → implement → green → Commit `feat: make transfers cooperatively cancellable` (with footer).

---

### Task 3: Settings window (App)

**Files:**
- Create: `Sources/MacSCPApp/SettingsView.swift`
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (Settings scene), `Sources/MacSCPApp/ContentView.swift` (pass through the SettingsStore instance)

**Interfaces:** Consumes `SettingsStore` (T1).

**Binding:**
1. `MacSCPApp`: ONE `SettingsStore` as `@State` on the App struct; `Settings { SettingsView(store: settingsStore) }` scene (macOS opens it via ⌘, / the "Settings…" menu); the same instance passed to `ContentView` (parameter, no singleton — the v2 window rule).
2. `SettingsView`: `TabView` with ONE tab "Transfers" (symbol `arrow.up.arrow.down`), `Form` layout, window fixed at ~460×260:
   - "Maximum concurrent transfers": `Stepper`(1–8) with a value display + footnote "Applies to new transfers; running ones are unaffected."
   - "Bandwidth limit upload/download": one number field each (KB/s) with a "0 = unlimited" placeholder/footnote; inputs < 0 are clamped (the store does that).
3. The tab structure is deliberately extensible (comment: future tabs Terminal/General).
4. Verification: build + suite stays green unchanged; headless launch; visual in T6.

- [x] Implement → green → Commit `feat: add settings window with transfer tab` (with footer).

---

### Task 4: Queue parallelism N (Core) — RISK

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`
- Test: `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift`, gated `Tests/macSCPCoreTests/CitadelShellIntegrationTests.swift` OR a new gated file (validation)

**Binding:**
1. **Validation FIRST (gated, own commit step):** a test that drives THREE uploads (~8 MiB) over ONE `CitadelFileSystem` TRULY CONCURRENTLY (`async let`/TaskGroup directly on `TransferEngine.copyFile`) and checks byte-identical arrival (docker exec md5sum). If this fails structurally (the Citadel SFTP channel cannot handle parallelism) → STOP, report BLOCKED — parallelism then stays at 1 and T3/T5 run without this switch (coordinator decides).
2. `TransferQueueViewModel`: `public var maxConcurrent: Int = 3` (clamped 1–8; ContentView sets it from the SettingsStore on `startSession` AND on change via `.onChange` — a change affects FUTURE slot assignments, running ones stay). Worker loop → slot model: up to `maxConcurrent` concurrent `process` tasks; start order strictly FIFO from `order`; `runningTransferTask` becomes `runningTransferTasks: [UUID: Task]`; `resolvingJobID` becomes `resolvingJobIDs: Set<UUID>` — cancelAll semantics (queued sweep, in-flight resolver sweep, cancel running ones [now cooperative thanks to T2], expansion first) stay exactly-once. Conflict prompts continue to self-serialize (MainActor + ONE bridge prompt: a second conflict waits until the first is resolved — the bridge needs a fair queue for this OR the slot awaits the bridge exclusively; simplest binding solution: an `AsyncSemaphore`/gate in the VM around the decider call, FIFO).
3. Unit tests: `startsAtMostMaxConcurrent` (3 throttled transfers + maxConcurrent 2 → never >2 active at once in the mock, counter in the mock); `fifoStartOrderPreserved` (start order == enqueue order despite parallelism); `cancelAllWithParallelRunners` (2 running + 1 queued: all end .cancelled, exactly-once, prompt return); `conflictPromptsSerializeAcrossSlots` (2 parallel conflicts → decider calls in sequence, never interleaved); the existing 27 suite tests stay green (set the parallelism default explicitly to 1 in tests where determinism is needed — do NOT loosen the assertions).
4. Gated: 5 files multi-drop-equivalent via enqueue, maxConcurrent 3, all md5-identical.

- [x] Validation → red → implement → green (all levels) → Commit `feat: run transfers on configurable parallel slots` (with footer).

---

### Task 5: Bandwidth throttle + rate/ETA

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/TransferEngine.swift` (throttle), `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift` (TransferProgress extension — check the file where TransferProgress lives), `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (rate window), `Sources/MacSCPApp/TransferQueueBar.swift` (display), `Sources/MacSCPApp/ContentView.swift` (limits from Settings into the enqueue paths)
- Tests: engine + queue + formatter tests where applicable

**Binding:**
1. `TransferEngine.copyFile` gets `bytesPerSecondLimit: Int = 0` (0 = off): token-time throttle in the chunk loop (after every chunk: target time = bytes transferred / limit; if actual < target → `Task.sleep` for the difference; a simple sliding approach, no burst bucket needed). The cancellation check (T2) stays effective BEFORE the sleep (sleep throws on cancel — document this).
2. The queue passes the limit through direction-dependent: `.upload` → uploadLimitKBs, `.download` → downloadLimitKBs (values arrive either as new enqueue parameters with default 0 OR as VM properties that ContentView sets from the SettingsStore — decision: VM properties `uploadLimitBytesPerSec`/`downloadLimitBytesPerSec`, set by ContentView via onChange; applies from the NEXT item that starts).
3. Rate/ETA: `TransferProgress` gains `bytesPerSecond: Double?` and `etaSeconds: Double?` (nil while unknown). Calculation NOT in the engine but in the queue's progress consumer: a sliding 3-second window over (timestamp, bytes) pairs; ETA only when totalBytes is known. The bar shows, compactly after the progress bar, `"1,2 MB/s · 0:42"` (formatter helper, tabular digits, German formats via `MeasurementFormatter`/a custom helper — tests for the formatter).
4. Engine test: limit 256 KB/s, 1 MiB mock transfer → duration ≥ ~3.5 s (tolerance window, no flaky exact timing; alternatively virtual time via an injectable sleep — preferred: an injectable `sleep` closure, the test counts the target sleep time instead of actually sleeping). Queue test: rate field populated and monotonically sensible under a constant mock cadence; ETA nil without totalBytes.

- [x] Red → implement → green → Commit `feat: add bandwidth limits and transfer rate display` (with footer).

---

### Task 6: Final verification

- [x] `swift test` overall green (count in the report); rig up, `MACSCP_ITEST=1` (19 + new gated), `MACSCP_KEYCHAIN=1` 2/2.
- [x] Visual smoke test (only with a free screen): compact form window on launch + grows/shrinks on connect/disconnect; ⌘, opens Settings, stepper/fields work; parallelism 3: multi-drop → up to 3 bars SIMULTANEOUSLY, start order FIFO; set limit 200 KB/s upload → visibly throttled rate in the bar (`~0.2 MB/s`), back to 0 → full rate; "Cancel all" behavior via the disconnect-disabled gate stays (no new button in M5c — deliberate); RETEST promise-drag through the queue (drag the window small beforehand, drop on a free desktop area); byte-identical.
- [x] Checkboxes, Commit `docs: mark M5c plan tasks as completed` (with footer).

## Outlook

M5d: resume (SFTP offset) + reconnect survival (queue pauses) + partial-file cleanup. M5e: editor integration. M6: release (icon, polish incl. sheet default-action review, notarized DMG). Backlog remainder: .other suffix, tree-cancel semantics (M6 design note).
