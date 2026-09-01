# macSCP M5b — Conflict rules + recursive directory transfers implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** If the destination file exists, macSCP asks (overwrite/skip/rename — once or as a rule for the queue); folders can be transferred recursively (drop and buttons), including creating the destination structure.

**Architecture:** `RemoteFileSystem` gets an idempotent `createDirectory`. The conflict check lives in the worker of the `TransferQueueViewModel` (before `copyFile`: destination stat; decision via an injected async `ConflictDecider` — UI bridge following the continuation pattern of the host-key prompt). Recursion as an expansion task: walk the tree, create destination directories, enqueue files as normal queue items; group accounting fires `onCompleted` only once ALL items of the tree are terminal.

**Tech Stack:** Existing queue/engine unchanged at its core; Citadel `SFTPClient.createDirectory`; FileManager.

## Global Constraints

- swift-tools 6.0; ALL targets `.swiftLanguageMode(.v5)`; macOS 15; Swift Testing, TDD red→green.
- Gated tests: `MACSCP_ITEST=1` (start the rig ONLY from the main checkout; PerSourcePenalties has been disabled since 5688f49), `MACSCP_KEYCHAIN=1`.
- Queue invariants from M5a stay untouched: FIFO, exactly-once waiter, cancelAll semantics, worker restart. NO cancel-while-active UI (M5c precondition: cooperative cancellation).
- Without a decider set, the queue behaves like M5a: silent overwrite (backward compatibility, covers CLI/tests).
- Duo color semantics, German UI texts, system red for errors.
- Conventional Commits, footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Implementers do not push.

**Dependency graph:** `[ Task 1 (createDirectory, Core FS) ∥ Task 2 (conflict machinery, queue) ] → Task 3 (recursion, queue) → Task 4 (conflict sheet + folder paths, UI) → Task 5 (wrap-up)` — T1/T2 are file-disjoint (worktree-parallel).

---

### Task 1: `createDirectory` in the protocol + both implementations

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`
- Modify: `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift`
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift`
- Modify: `Tests/macSCPCoreTests/MockRemoteFileSystem.swift` (conformance)
- Test: `Tests/macSCPCoreTests/LocalFileSystemTests.swift` (extend), `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift` (gated, extend)

**Interfaces:**
- Produces (binding for T3):

```swift
/// Creates the directory. IDEMPOTENT: if it already exists as a directory,
/// the call returns silently. If a FILE exists at the path, it throws
/// RemoteFSError.protocolError. Missing intermediate directories: Local
/// creates them (withIntermediateDirectories); Citadel creates ONLY the
/// last level — the recursion (T3) runs top-down, so parents always exist.
func createDirectory(at path: String) async throws
```

- [x] **Step 1: Failing tests**
  - Local: creates directory; idempotent on second call; throws `protocolError` when a file sits at the path; creates intermediate levels.
  - Mock: `createdDirectories` logging (for T3 tests); directory appears in the mock tree.
  - Gated (Docker): `createDirectory(at: "/config/macscp-mkdir-test/sub")`? — NO: Citadel only creates the last level → test: first `/config/macscp-mkdir-test`, then `/config/macscp-mkdir-test/sub`; idempotency second call; file collision (`write` a file, then createDirectory at the same path → error); cleanup via `docker exec` or SFTP delete if available — otherwise a unique name per run + a cleanup note in the test comment.
- [x] **Step 2: Red** (compile errors in conformances).
- [x] **Step 3: Implement**
  - Local: `FileManager.createDirectory(atPath:withIntermediateDirectories:true)`; a `fileExists(isDirectory:)` check beforehand for the file collision (→ `protocolError(reason: "Path exists as a file: \(path)")`).
  - Citadel: `try await sftp.createDirectory(atPath: path)`; catch the error → if `stat(path)` afterward returns a directory: silently ok (race/exists); if stat returns a file: `protocolError`; otherwise pass the original error through `mapSFTPError`.
- [x] **Step 4: Green** — filter + full suite; gated 15/15 + new.
- [x] **Step 5: Commit** — `feat: add idempotent createDirectory to remote file systems` (with footer).

---

### Task 2: Conflict machinery in TransferQueueViewModel

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`
- Test: `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift` (extend)

**Interfaces:**
- Produces (binding for T4):

```swift
public enum ConflictResolution: Sendable, Equatable { case overwrite, skip, rename }

public struct TransferConflict: Sendable, Equatable {
    public let fileName: String
    public let destinationDirectory: String
    public let direction: TransferDirection
}

/// UI decider. Return nil == "Cancel" (item becomes .cancelled).
/// applyToAll == true sets the decision as a rule for the rest of the queue.
public typealias ConflictDecider =
    @Sendable (TransferConflict) async -> (resolution: ConflictResolution, applyToAll: Bool)?

// On the VM:
public var conflictDecider: ConflictDecider?   // nil (default) => silent overwrite as in M5a
// Item.Status additionally gets:
case skipped                                    // German: "übersprungen" (UI in T4/T2 bar adjustment)
// Item.fileName becomes `internal(set) var` (rename updates the displayed name).
```

**Semantics (binding):**
1. Before `copyFile`, the worker checks via `destination.stat` (path join EXACTLY as in `TransferEngine` — look it up there and use/extract the same helper) whether the destination exists. `notFound` → no conflict. Other stat errors → item `.failed` (message via `message(for:)`).
2. Conflict + active queue rule → apply the rule without asking.
3. Conflict without a rule: `conflictDecider` nil → `.overwrite`. Otherwise await the decider (the worker blocks — serially, so exactly ONE open prompt). nil → item `.cancelled`, the waiter (enqueueAndWait) throws `CancellationError`. `applyToAll` → set the rule.
4. `.skip` → item `.skipped`, `onCompleted` is NOT called, the waiter throws `CancellationError` (promise contract: the file did not arrive).
5. `.rename` → find a free name: "name (2).ext", "name (3).ext", … (base name/extension via the last dot; without an extension "name (2)"); probe via `stat` until `notFound`, upper bound 999 → otherwise `.failed("No free name…")`. The transfer runs under the new name; `items[idx].fileName` is updated to the new name.
6. **Rule lifetime:** the queue rule holds until the worker drains empty — it is reset at worker end (the `workerTask = nil` path). New batches ask again.
7. `TransferQueueBar` (small adjustment here in T2, file `Sources/MacSCPApp/TransferQueueBar.swift`): `case .skipped: Text("übersprungen")` gray — otherwise the exhaustive switch breaks.

- [x] **Step 1: Failing tests** (prepare the mock tree so the destination exists):
  1. `conflictWithoutDeciderOverwrites` (M5a behavior)
  2. `deciderSkipMarksSkippedAndSkipsWrite` (no write in the mock, no onCompleted)
  3. `deciderOverwriteWrites`
  4. `deciderRenameWritesUnderFreeName` — "(2)" taken → lands on "(3)"; item fileName updated
  5. `deciderCancelCancelsItem` (nil → .cancelled; enqueueAndWait throws)
  6. `applyToAllAsksOnlyOnce` (2 conflicts, decider call count == 1)
  7. `ruleResetsAfterDrain` (batch 1 with applyToAll, wait for drain, batch 2 → decider asked again)
  8. `noConflictDoesNotAskDecider` (destination does not exist → call count 0)
- [x] **Step 2: Red.**
- [x] **Step 3: Implement** (conflict logic as a private function `resolveConflictIfNeeded(job:) async -> Outcome` before the engine call in `process`).
- [x] **Step 4: Green** — filter (17 = 9 + 8), full suite.
- [x] **Step 5: Commit** — `feat: add conflict rules to the transfer queue` (with footer).

---

### Task 3: Recursive directory transfers (expansion + groups)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`
- Test: `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift` (extend)

**Interfaces:**
- Consumes: `createDirectory` (T1), `list`/`stat` of the protocol.
- Produces (binding for T4):

```swift
/// Enqueues a complete folder: creates destination directories (top-down)
/// and enqueues each file as its own queue item. `onCompleted` fires exactly
/// once, once ALL items of the tree are terminal (finished/failed/skipped/
/// cancelled) — even on partial failures. Symlinks are skipped (item with
/// status .skipped and a name suffix " →"). Expansion errors (list/mkdir)
/// appear as a .failed item under the folder name with a "/" suffix.
public func enqueueTree(
    directoryName: String, direction: TransferDirection,
    source: any RemoteFileSystem, sourceDirectory: String,
    destination: any RemoteFileSystem, destinationDirectory: String,
    onCompleted: (@MainActor () async -> Void)?
)
```

**Semantics (binding):**
- Expansion runs as its own MainActor task BEFORE the transfers: BFS/DFS top-down; first `createDirectory(dest)/dirName`, then `list(source)`: files → `enqueue` (with group assignment), subdirectories → recursive (mkdir + descend), symlinks → immediately terminal `.skipped` item.
- Group accounting: `enqueueTree` registers a group; every terminal status change of a group item decrements it; at 0 (and expansion complete) → `onCompleted` exactly once. An expansion error ends expansion of the affected branch, already-enqueued items keep running; the error item counts toward the group.
- `cancelAll` during expansion: the expansion task is canceled (store the task + cancel it in `cancelAll` + await it), the rest as before.
- File items of the group go through the T2 conflict logic unchanged.

- [x] **Step 1: Failing tests** (mock tree with structure `dir/{a.txt, sub/{b.txt}, link→x, leer/}`):
  1. `treeCreatesDirectoriesTopDown` (mock `createdDirectories` order: dir before dir/sub before file writes)
  2. `treeTransfersAllFilesAndFiresOnCompletedOnce`
  3. `treeSkipsSymlinks` (item .skipped, no write)
  4. `treeCreatesEmptyDirectories`
  5. `treeOnCompletedWaitsForLastItem` (signal mock: onCompleted only after the last finish)
  6. `treeExpansionErrorProducesFailedItemButOthersRun` (list throws in a subfolder)
  7. `treePartialFailureStillFiresOnCompleted` (one file fails → onCompleted still fires, exactly 1×)
  8. `cancelAllDuringExpansionStopsCleanly` (expansion tied to a signal; cancelAll → no new items, group cleaned up, isActive false)
- [x] **Step 2: Red.** — [ ] **Step 3: Implement.** — [ ] **Step 4: Green** (filter 25 = 17 + 8; full suite).
- [x] **Step 5: Commit** — `feat: add recursive directory transfers to the queue` (with footer).

---

### Task 4: UI — conflict sheet + folders via drop and buttons

**Files:**
- Modify: `Sources/MacSCPApp/ContentView.swift`

**Interfaces:**
- Consumes: `ConflictDecider`/`TransferConflict`/`ConflictResolution` (T2), `enqueueTree` (T3).

- [x] **Step 1: Conflict bridge** (pattern: the host-key prompt from `ConnectionViewModel`/`ConnectionFormView`, including the cancellation handler):
  - `@State private var conflictPrompt: TransferConflict?` + a private continuation field in a small `@Observable` helper class OR directly in the view state (ContentView is a struct → hold the continuation in a box/helper class; cleanest variant: a small `@MainActor final class ConflictPromptBridge` in the same file with `ask(_:) async` + `resolve(_:)`, continuation exactly-once + cancellation handler as in `presentHostKeyPrompt`).
  - In `startSession`: `transferQueue.conflictDecider = { conflict in await bridge.ask(conflict) }`.
  - Sheet (`.sheet(item:)` on the detail area, `TransferConflict` made `Identifiable` via fileName+dir — or an `@State` wrapper with UUID):
    Title "Datei existiert bereits", text "\(fileName)" existiert in „\(destinationDirectory)"." — buttons: **Überschreiben** (destructive role), **Überspringen**, **Umbenennen**, **Abbrechen** (cancel role); toggle "Für alle weiteren übernehmen". German texts, system colors.
- [x] **Step 2: Folder paths**
  - `uploadDropped`: REMOVE the directory filter; `isDirectory` → `transferQueue.enqueueTree(directoryName: url.lastPathComponent, …, sourceDirectory: url.path…, destinationDirectory: session.remote.currentPath, onCompleted: { await session.remote.refresh() })`, files as before.
  - Upload/download button: `.disabled(selected == nil)` (kind restriction removed); in the handler: `selected.kind == .directory` → `enqueueTree`, otherwise `enqueue`. Symlink selection stays disabled (`selected?.kind == .symlink` → keep disabled).
  - The Finder promise stays FILE-only (pasteboard writer unchanged: `item.kind == .file`).
- [x] **Step 3: Green + headless launch** — `swift build && swift test`; bundle wrapper launch check.
- [x] **Step 4: Commit** — `feat: add conflict dialog and folder transfers` (with footer).

---

### Task 5: Wrap-up verification

- [x] **Step 1:** `swift test` — full suite green (expected ≈ 155 + T1 unit + 16 queue tests; exact in the report).
- [x] **Step 2:** Rig up (MAIN checkout), `MACSCP_ITEST=1` (15 + new mkdir tests), `MACSCP_KEYCHAIN=1` 2/2.
- [x] **Step 3: Visual smoke test** (coordinator; rig running; ONLY if the screen is free — respect user activity):
  a) Conflict: upload a file twice → sheet appears; play through all four paths (overwrite / skip → "übersprungen" / rename → "x (2).ext" appears remotely / cancel → "abgebrochen"); "apply to all further" with 2+ conflicts → only ONE sheet.
  b) Recursion: drop a local folder with a subfolder + an empty folder → structure correct remotely (`docker exec find`), items per file in the bar, refresh at the end; download a remote folder via the button → `diff -r` clean.
  c) M5a catch-up: drag a remote file → Finder WHILE the queue is working (item appears, file byte-identical); ⌘T off/on while the shell is running → screen stays (replay); after the queue ends, "Disconnect" is active again and disconnects cleanly.
- [x] **Step 4:** Checkboxes, commit `docs: mark M5b plan tasks as completed` (with footer).

## Outlook

M5c: cooperative cancellation in engine/FS (PRECONDITION for the cancel button), resume (SFTP offset), rate/ETA, reconnect survival, concurrency → 3, enqueueAndWait timeout, promise drag window. M5d: editor integration. Then M6 release.
