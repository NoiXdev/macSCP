# macSCP M5a — Transfer Queue Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ALL three transfer paths (buttons, drop, Finder promise) run through ONE queue with a visible queue bar — drops and clicks while transfers are running get enqueued instead of discarded.

**Architecture:** A new `TransferQueueViewModel` (@Observable @MainActor) with an item list and a serial worker loop (concurrency 1 in M5a — the abstraction carries N workers, but concurrent transfers over ONE SFTP channel are only empirically validated and turned up in M5c; the spec default of 3 comes then). `enqueue` enqueues and wakes the worker; `enqueueAndWait` (for the promise path) waits via continuation for the completion of EXACTLY that item. `TransferBar` is replaced by `TransferQueueBar` (item list); the old single-transfer `TransferViewModel` is deleted at the end.

**Tech Stack:** Existing `TransferEngine.copyFile` (unchanged), `TransferProgress`/`TransferDirection`, MockRemoteFileSystem for tests.

## Global Constraints

- swift-tools 6.0; ALL targets `.swiftLanguageMode(.v5)`; macOS 15; Swift Testing, TDD red→green.
- Duo colors semantic: ↑ amber (`DesignTokens.localAmber`) = upload, ↓ ocean blue (`DesignTokens.remoteBlue`) = download; errors system red. German UI texts.
- Gated tests: `MACSCP_ITEST=1` (rig ONLY from the main checkout), `MACSCP_KEYCHAIN=1`.
- The UI owns lifecycles explicitly: `teardownSession` cleans up the queue BEFORE the disconnect (pattern: terminal shutdown M4).
- Do not touch terminal/TOFU behavior (except Task 0a, which specifically fixes the terminal screen retention).
- Conventional Commits, footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Implementers do not push.

**Dependency graph:** `[ Task 0 (M5 openings) ∥ Task 1 (queue VM, core) ] → Task 2 (queue bar, UI) → Task 3 (ContentView rebuild) → Task 4 (wrap-up)` — T0/T1 file-disjoint (worktree-parallel).

---

### Task 0: M5 Openings — Terminal Screen Retention + Cancellation Fast-Path Test

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TerminalPanelViewModel.swift`
- Modify: `Sources/MacSCPApp/SSHTerminalView.swift`
- Test: `Tests/macSCPCoreTests/TerminalPanelViewModelTests.swift` (extend)
- Test: `Tests/macSCPCoreTests/ConnectionViewModelTests.swift` (extend)

**Interfaces:**
- Produces: `TerminalPanelViewModel.replayBuffer: [[UInt8]]` (public read) — played back by the view on mount.

**Background (Final Review M4, Minor 1):** ⌘T hiding while a shell is running unmounts the `TerminalView`; `onOutput`'s weak ref goes nil, the read loop discards all chunks; on re-showing, an empty console starts. Fix: the VM buffers the last output chunks and the view plays them back in `makeNSView`.

- [x] **Step 1: Failing test — replay buffer**

```swift
@Test func outputIsBufferedForReplayWhileHidden() async throws {
    let shell = MockShell()
    let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
    vm.toggle()
    try await waitUntil { vm.state == .running }
    // Kein onOutput gesetzt (Panel ausgeblendet) — Chunks dürfen nicht verloren gehen
    shell.continuation.yield(Array("verborgen".utf8))
    try await waitUntil { !vm.replayBuffer.isEmpty }
    #expect(vm.replayBuffer.flatMap { $0 } == Array("verborgen".utf8))
    // Neuer Konsument (Re-Mount) sieht Puffer + Live-Daten
    var received: [[UInt8]] = []
    vm.onOutput = { received.append($0) }
    shell.continuation.yield(Array("live".utf8))
    try await waitUntil { !received.isEmpty }
}
```

Second test: the buffer is capped (oldest gets dropped) — constant `maxReplayBytes = 256 * 1024`:

```swift
@Test func replayBufferIsBounded() async throws {
    let shell = MockShell()
    let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
    vm.toggle()
    try await waitUntil { vm.state == .running }
    shell.continuation.yield([UInt8](repeating: 1, count: 200_000))
    shell.continuation.yield([UInt8](repeating: 2, count: 200_000))
    try await waitUntil { vm.replayBuffer.count == 1 || vm.replayBuffer.reduce(0) { $0 + $1.count } <= 256 * 1024 }
    #expect(vm.replayBuffer.reduce(0) { $0 + $1.count } <= 256 * 1024)
    #expect(vm.replayBuffer.last?.last == 2)  // Neuestes bleibt
}
```

- [x] **Step 2: Red** — `replayBuffer` unknown.

- [x] **Step 3: Implement**

In the VM: private buffer, filled in the read loop BEFORE the `onOutput` call; cleared on `shutdown()` and on reopening (`openIfNeeded` after `.ended`):

```swift
/// Zuletzt empfangene Output-Chunks (max. 256 KiB) — Replay beim Wieder-
/// einblenden des Panels, damit ⌘T den sichtbaren Screen nicht verwirft.
public private(set) var replayBuffer: [[UInt8]] = []
private static let maxReplayBytes = 256 * 1024
private var replayBytes = 0

private func bufferForReplay(_ chunk: [UInt8]) {
    replayBuffer.append(chunk)
    replayBytes += chunk.count
    while replayBytes > Self.maxReplayBytes, !replayBuffer.isEmpty {
        replayBytes -= replayBuffer.removeFirst().count
    }
}
```

In the read loop (`readTask`): `self?.bufferForReplay(chunk)` before `self?.onOutput?(chunk)`. In `openIfNeeded` (before opening) and `shutdown()`: `replayBuffer = []; replayBytes = 0`.

In `SSHTerminalView.makeNSView`, directly after setting `viewModel.onOutput`:

```swift
for chunk in viewModel.replayBuffer {
    terminal.feed(byteArray: chunk[...])
}
```

- [x] **Step 4: Cancellation fast-path test** (Final Review Minor 2) — in `ConnectionViewModelTests.swift`: a connector whose `onUnknownHostKey` call only comes AFTER the cancel (connector waits for a signal; test cancels the connect task, then releases the signal) → `presentHostKeyPrompt` runs with cancellation already set inside `withCheckedContinuation` and must return `false` immediately via the `Task.isCancelled` fast path; assertion: connect returns (reuse the file's timeout-race pattern), no hang. If the fast path is not deterministically reachable after an honest attempt (the onCancel handler always fires first), formulate the test as a deterministic proof of the OVERALL BEHAVIOR (cancel-before-prompt → no hang) and document in the report which path actually applies.

- [x] **Step 5: Green** — filter suites + full suite (145 + 3 new = 148 expected).
- [x] **Step 6: Commit** — `fix: preserve terminal screen across panel toggle` (with footer).

---

### Task 1: TransferQueueViewModel (Core)

**Files:**
- Create: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`
- Test: `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift`

**Interfaces:**
- Consumes: `TransferEngine.copyFile(from:sourcePath:to:destinationDirectory:fileName:onProgress:)` (unchanged), `TransferProgress`, `TransferDirection`.
- Produces (binding for T2/T3):

```swift
@Observable @MainActor
public final class TransferQueueViewModel {
    public struct Item: Identifiable, Equatable {
        public enum Status: Equatable {
            case queued
            case running(TransferProgress)
            case finished
            case failed(String)      // deutsche Meldung
            case cancelled
        }
        public let id: UUID
        public let fileName: String
        public let direction: TransferDirection
        public internal(set) var status: Status
    }

    public private(set) var items: [Item]
    /// true solange irgendein Item queued/running ist (Sidebar-Gate).
    public var isActive: Bool { get }
    /// Anzahl offener (queued+running) Items — fürs "n ausstehend"-Label.
    public var pendingCount: Int { get }

    public init()

    /// Reiht ein und startet den Worker, falls er schläft. Läuft IMMER an —
    /// kein isRunning-Verwerfen mehr.
    @discardableResult
    public func enqueue(
        fileName: String, direction: TransferDirection,
        source: any RemoteFileSystem, sourcePath: String,
        destination: any RemoteFileSystem, destinationDirectory: String,
        onCompleted: (@MainActor () async -> Void)?
    ) -> UUID

    /// Wie enqueue, kehrt aber erst zurück, wenn GENAU dieses Item fertig ist.
    /// Wirft bei failed/cancelled (Promise-Pfad: Finder braucht die Datei).
    public func enqueueAndWait(
        fileName: String, direction: TransferDirection,
        source: any RemoteFileSystem, sourcePath: String,
        destination: any RemoteFileSystem, destinationDirectory: String
    ) async throws

    /// Bricht alles ab: laufenden Transfer canceln, queued → .cancelled,
    /// wartende Continuations werfen. Kehrt erst nach Worker-Stopp zurück.
    public func cancelAll() async

    /// Entfernt finished/failed/cancelled aus der Liste.
    public func clearCompleted()
}
```

**Key implementation points:**

```swift
// Privater Zustand:
private struct Job {
    let id: UUID
    let source: any RemoteFileSystem
    let sourcePath: String
    let destination: any RemoteFileSystem
    let destinationDirectory: String
    let fileName: String
    let onCompleted: (@MainActor () async -> Void)?
}
private var jobs: [UUID: Job] = [:]
private var order: [UUID] = []                 // FIFO der queued-Items
private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
private var workerTask: Task<Void, Never>?
private var runningTransferTask: Task<Void, Error>?   // fürs Cancel des aktiven copyFile

// Worker-Loop (seriell, MainActor-Klasse, copyFile awaited off-main):
private func kickWorker() {
    guard workerTask == nil else { return }
    workerTask = Task { [weak self] in
        while let self, let jobID = self.nextQueuedID() {
            await self.process(jobID)
        }
        self?.workerTask = nil
    }
}
```

`process(_:)` sets status `.running(TransferProgress(bytesTransferred: 0, totalBytes: nil))`, uses the ORDERED AsyncStream consumer pattern from the old `TransferViewModel` (one consumer updates `items[...] .status = .running(progress)`), runs `TransferEngine.copyFile` inside its own `runningTransferTask` (so `cancelAll` can cancel it), sets `.finished`/`.failed(message)` at the end, calls `onCompleted` (only on success), and resumes the waiter (`waiters.removeValue(forKey:)`: success → `resume()`, error → `resume(throwing:)`).

Error texts: `Self.message(for:)` — take over the switch cases 1:1 from `TransferViewModel.message(for:)` (the file still exists as a reference until T3).

`cancelAll()`: all queued IDs from `order` → status `.cancelled`, resume their waiters with `CancellationError()`; `runningTransferTask?.cancel()`; `await workerTask?.value` (worker terminates because `nextQueuedID()` no longer returns anything and the running copyFile ends with CancellationError → the active item's status becomes `.cancelled`, not `.failed`); only then return. Handle `CancellationError` separately in `process` (`catch is CancellationError` → `.cancelled`).

**Watch out for reentrancy:** an `enqueue` while the worker is running only appends to `order`/`jobs`/`items` — the running `while` loop picks it up on the next pass. NO second worker (guard `workerTask == nil`).

- [x] **Step 1: Failing tests** — `TransferQueueViewModelTests.swift`, take over the mock pattern from `TransferViewModelTests.swift` (MockRemoteFileSystem with read/write streams exists there; copy shared helpers rather than sharing them if needed). Binding behavioral assertions:

  1. `enqueueRunsTransferAndFinishes` — one item, status progression queued→running→finished, `onCompleted` exactly once, file arrived at the destination mock.
  2. `secondEnqueueDuringRunningIsQueuedNotDropped` — two enqueues in direct succession (mock read with delay/signal), item 2 has status `.queued` WHILE item 1 is running, afterward BOTH complete (this pins the old isRunning drop as dead).
  3. `itemsRunInFIFOOrder` — three items, completion order == enqueue order (mock logs write order).
  4. `failedItemDoesNotBlockQueue` — item 1 throws (mock error `RemoteFSError.notFound`), status `.failed` with a German message, item 2 still runs and finishes.
  5. `enqueueAndWaitReturnsAfterCompletion` — returns only after `.finished` (task + signal mock prove the ordering).
  6. `enqueueAndWaitThrowsOnFailure` — mock throws → `enqueueAndWait` throws.
  7. `cancelAllCancelsQueuedAndRunning` — item 1 running (mock blocks on signal), item 2 queued; `cancelAll()`; item 2 `.cancelled` immediately, item 1 `.cancelled` (not `.failed`), a waiting `enqueueAndWait` on item 2 throws; afterward `isActive == false`; a new `enqueue` starts up again (worker restart after cancelAll).
  8. `clearCompletedRemovesOnlyDone` — finished+failed+cancelled get removed, queued/running stay.
  9. `isActiveReflectsPendingWork` — false initially, true after enqueue, false after completion.

- [x] **Step 2: Red** — compile errors.
- [x] **Step 3: Implement** (as sketched above; base code layout on `TransferViewModel`).
- [x] **Step 4: Green** — filter suite (9), full suite (base + 9).
- [x] **Step 5: Commit** — `feat: add transfer queue view model with fifo worker` (with footer).

---

### Task 2: TransferQueueBar (UI)

**Files:**
- Create: `Sources/MacSCPApp/TransferQueueBar.swift`

**Interfaces:**
- Consumes: `TransferQueueViewModel` (API from Task 1 — present on the base commit after the merge).
- Produces: `struct TransferQueueBar: View { let viewModel: TransferQueueViewModel }` — T3 embeds it instead of `TransferBar`.

No unit test (SwiftUI rendering); verification via build + visual check in T4.

- [x] **Step 1: Implement**

```swift
import SwiftUI
import macSCPCore

/// Warteschlangen-Leiste unter den Panes: kompakte Item-Liste,
/// ↑ Bernstein (Upload), ↓ Ozeanblau (Download), Fehler in System-Rot.
struct TransferQueueBar: View {
    let viewModel: TransferQueueViewModel

    private func tint(for direction: TransferDirection) -> Color {
        direction == .upload ? DesignTokens.localAmber : DesignTokens.remoteBlue
    }

    var body: some View {
        if viewModel.items.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Text(viewModel.isActive
                         ? "Übertragungen — \(viewModel.pendingCount) ausstehend"
                         : "Übertragungen")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Aufräumen") { viewModel.clearCompleted() }
                        .controlSize(.small)
                        .disabled(viewModel.items.allSatisfy {
                            $0.status == .queued || $0.status.isRunning
                        })
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(viewModel.items) { item in
                            row(item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 110)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: TransferQueueViewModel.Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.direction == .upload ? "arrow.up" : "arrow.down")
                .foregroundStyle(tint(for: item.direction))
                .fontWeight(.bold)
                .frame(width: 14)
            Text(item.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            switch item.status {
            case .queued:
                Text("wartet").font(.caption).foregroundStyle(.secondary)
            case .running(let progress):
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .tint(tint(for: item.direction))
                        .frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
            case .finished:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(tint(for: item.direction))
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(message)
            case .cancelled:
                Text("abgebrochen").font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}
```

Also needed for the VM consumption (Task 1 provides it): `Item.Status` needs a helper property `isRunning: Bool` (in Core, `public var isRunning: Bool { if case .running = self { return true }; return false }`) — if Task 1 does not already add it, add it here as an extension in the file.

- [x] **Step 2: Green** — `swift build && swift test` (base unchanged).
- [x] **Step 3: Commit** — `feat: add transfer queue bar listing queued items` (with footer).

---

### Task 3: ContentView rebuild — everything through the queue

**Files:**
- Modify: `Sources/MacSCPApp/ContentView.swift`
- Modify: `Sources/MacSCPApp/RemoteFilePromise.swift` (only if a signature adjustment is needed)
- Delete: `Sources/MacSCPApp/TransferBar.swift`
- Delete: `Sources/macSCPCore/Presentation/TransferViewModel.swift`
- Delete: `Tests/macSCPCoreTests/TransferViewModelTests.swift`

**Interfaces:**
- Consumes: `TransferQueueViewModel` (T1), `TransferQueueBar` (T2).

- [x] **Step 1: Switch state** — `@State private var transferViewModel = TransferViewModel()` → `@State private var transferQueue = TransferQueueViewModel()`; reinstantiate in `startSession` (`transferQueue = TransferQueueViewModel()`) as before.

- [x] **Step 2: Redraw gates**
  - `sidebarDisabled`: `transferViewModel.isRunning` → `transferQueue.isActive` (switching sessions while the queue is running stays locked — a deliberate M5a decision, an abort dialog comes with M5c/reconnect).
  - Upload/download button: `.disabled(... || transferViewModel.isRunning)` → REMOVE the isRunning criterion (only `selected == nil || kind != .file` remains) — clicks get enqueued.
  - "Disconnect" button: `.disabled(transferViewModel.isRunning)` → `.disabled(transferQueue.isActive)`.
  - `uploadDropped`: REMOVE the `guard !transferViewModel.isRunning` drop guard (its comment too); the awaited-for loop becomes direct `enqueue` calls (no task needed):

```swift
private func uploadDropped(_ urls: [URL], session: BrowserSession) {
    let files = urls.filter { /* wie bisher */ }
    for url in files {
        transferQueue.enqueue(
            fileName: url.lastPathComponent, direction: .upload,
            source: session.localFS, sourcePath: url.path(percentEncoded: false),
            destination: session.remoteFS,
            destinationDirectory: session.remote.currentPath,
            onCompleted: { await session.remote.refresh() }
        )
    }
}
```

  - Buttons analogously: `Task { await transferViewModel.run(...) }` → `transferQueue.enqueue(...)` (synchronous, no task).

- [x] **Step 3: Promise path through the queue** — in `remotePromiseProvider`:

```swift
RemoteFilePromiseProvider(item: item) { item, url in
    try await transferQueue.enqueueAndWait(
        fileName: url.lastPathComponent, direction: .download,
        source: session.remoteFS, sourcePath: item.path,
        destination: session.localFS,
        destinationDirectory: url.deletingLastPathComponent()
            .path(percentEncoded: false)
    )
}
```

(The provider callback is already `async throws` — check the signature in `RemoteFilePromise.swift`; if the callback was previously `@Sendable` without MainActor, lift the `enqueueAndWait` call into `await MainActor.run { ... }` or adjust the closure signature minimally. Promise downloads thus appear in the bar and serialize with all other transfers — the old gate bypass is dead.)

- [x] **Step 4: Teardown** — in `teardownSession()` BEFORE `session.terminal.shutdown()`: `await transferQueue.cancelAll()`.

- [x] **Step 5: Replace TransferBar** — `TransferBar(viewModel: transferViewModel)` → `TransferQueueBar(viewModel: transferQueue)`; delete the `TransferBar.swift` file; delete `TransferViewModel.swift` and its test file. `grep -rn "TransferViewModel\|TransferBar" Sources/ Tests/` must be empty (except for TransferQueue*).

- [x] **Step 6: Green + headless launch** — `swift build && swift test` (full suite = base − old TransferVM tests); headless-launch check (bundle wrapper pattern).
- [x] **Step 7: Commit** — `feat: route all transfers through the queue` (with footer).

---

### Task 4: Wrap-up verification

- [x] **Step 1:** `swift test` — full suite green (expected ≈ 148 + 9 − 4 old TransferVM tests; exact number in the report).
- [x] **Step 2:** rig up (MAIN checkout), `MACSCP_ITEST=1` 15/15, `MACSCP_KEYCHAIN=1` 2/2, rig down (or leave running for step 3).
- [x] **Step 3: Visual smoke test** (coordinator, rig running): connect; multi-drop 3+ files into the remote pane → ALL appear in the queue bar (waiting/running), work off FIFO, ↑ amber; WHILE a transfer is running, enqueue a download click → gets queued, not discarded; drag a remote file into the Finder (promise) WHILE the queue is working → appears as an item and lands byte-identical (diff); an error case (unreadable file or similar) does not block the queue; "Clean up" clears finished items; briefly toggle the ⌘T terminal on/off while the queue is running (screen stays intact — Task 0 fix); disconnect only possible after the queue ends (button disabled while active).
- [x] **Step 4:** checkboxes, commit `docs: mark M5a plan tasks as completed` (with footer).

## Outlook

M5b: conflict rules (overwrite/skip/rename) + recursive directory transfers. M5c: resume (SFTP offset), rate/ETA, reconnect survival (queue pauses), concurrency → spec default 3 after empirical single-channel validation. M5d: editor integration (temp download, DispatchSource watcher, auto-upload, session cleanup). Then M6 release.
