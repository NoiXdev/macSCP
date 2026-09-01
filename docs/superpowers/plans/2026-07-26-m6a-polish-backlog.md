# M6a — Polish Backlog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close all open ledger backlog items: a global bandwidth bucket (replaces the virtual throttle clock), group cancel in the conflict dialog, edit-integration fixes, form/session refactorings, a11y and code hygiene — after which the code is release-ready for M6b.

**Architecture:** A new Core actor `BandwidthBucket` (token bucket, real injectable clock) is owned per direction by `TransferQueueViewModel` and threaded through to `TransferEngine.copyFile` (signature change: `throttle: BandwidthBucket?` instead of `bytesPerSecondLimit`+`sleep`). Group cancel as a new sweep `cancelGroup` in the queue, built after the exactly-once pattern of `cancelAll`. All remaining items are local fixes in the App and Core layers without new abstractions.

**Tech Stack:** Swift 6 toolchain / `.swiftLanguageMode(.v5)`, Swift Testing (`@Test`/`#expect`), SwiftUI, macOS 15+.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-26-m6a-polish-backlog-design.md` — binding.
- Security/architecture invariants untouched: TOFU hardness, secrets only in the Keychain, UI-owned lifecycles, FIFO start order, exactly-once waiter/onCompleted.
- Queue invariants during group cancel: `onCompleted` exactly-once, no item terminalized twice, no waiter resumed twice, already-copied files stay in place.
- Code + comments English ONLY; new UI/error texts catalogued in `en.lproj`/`de.lproj` (App: `Sources/MacSCPApp/Resources/`, Core: `Sources/macSCPCore/Resources/`).
- Conventional Commits (English), footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` and the full `swift test` green after every task (starting point 295 tests; gated suites run ONLY at completion, with the Docker rig).
- TDD: prove new logic red first, then green.
- Environment note: Bash errors "claude-opus-4-8 is temporarily unavailable … cannot determine the safety" are NOT permission denials — wait and repeat identically.

## Schedule

T1 → T2 → T3 → T4 → T5 sequentially (T2–T4 share `TransferQueueViewModel.swift`). T6 = wrap-up (coordinator).

---

### Task 1: BandwidthBucket (Core)

**Files:**
- Create: `Sources/macSCPCore/RemoteFS/BandwidthBucket.swift`
- Test: `Tests/macSCPCoreTests/BandwidthBucketTests.swift`

**Interfaces:**
- Consumes: nothing new (only `ContinuousClock`, `Duration.secondsAsDouble`/`seconds(fromDouble:)` from `TransferEngine.swift` — both `internal` in the same module).
- Produces: `public actor BandwidthBucket` with `init(bytesPerSecond: Int, now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })`, `func consume(_ bytes: Int) async throws`, `func setRate(bytesPerSecond: Int)`. T2 relies on exactly these names.

**Semantics (binding):**
- Capacity (burst) = 1 second of rate. Tokens start full.
- `consume` waits as long as `tokens <= 0`; as soon as `tokens > 0`, it deducts the FULL `bytes` (may go negative). This makes chunks larger than the capacity (64 KiB chunks at a limit < 64 KB/s) work too, without starving; the average rate stays exactly the limit, the burst is bounded by capacity + one chunk.
- Continuous refill: on every `consume`/wait iteration, `tokens = min(capacity, tokens + elapsedSeconds * rate)` based on the injected clock.
- Wait duration per loop iteration: `(-tokens + 1) / rate` seconds (until the tokens would turn positive again). After every `sleep`, refill happens again and the condition is rechecked (multiple consumers: actor reentrancy is fine, the loop rechecks).
- `consume` is cooperatively cancellable: the injected `sleep` throws on task cancellation (the `Task.sleep` default); additionally the loop checks `try Task.checkCancellation()` before every iteration.
- `setRate` sets rate and capacity anew and clamps `tokens` to the new capacity (upward); negative tokens remain (debt is not forgiven).
- `bytesPerSecond <= 0` in init/`setRate` is a caller programming error — the queue creates no bucket at all for "0 = off". Clamp defensively to at least 1.

- [x] **Step 1: Write failing tests** — `Tests/macSCPCoreTests/BandwidthBucketTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

/// Deterministic clock driver for BandwidthBucket tests: `sleep` advances the
/// virtual instant instead of actually sleeping, so tests never wait.
private final class VirtualTime: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private(set) var totalSlept = Duration.zero

    var now: @Sendable () -> ContinuousClock.Instant {
        { [self] in lock.withLock { instant } }
    }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in
            try Task.checkCancellation()
            lock.withLock {
                instant = instant.advanced(by: duration)
                totalSlept += duration
            }
        }
    }
}

@Suite("BandwidthBucket")
struct BandwidthBucketTests {
    @Test("first consume within the burst capacity passes without sleeping")
    func burstPassesImmediately() async throws {
        let time = VirtualTime()
        let bucket = BandwidthBucket(bytesPerSecond: 1000, now: time.now, sleep: time.sleep)
        try await bucket.consume(800)
        #expect(time.totalSlept == .zero)
    }

    @Test("sustained consumption is paced to the configured rate")
    func sustainedRateIsPaced() async throws {
        let time = VirtualTime()
        let bucket = BandwidthBucket(bytesPerSecond: 1000, now: time.now, sleep: time.sleep)
        // 10 chunks of 1000 bytes = 10_000 bytes at 1000 B/s. The first
        // 1000 ride the initial burst, the remaining 9000 must be paced:
        // total sleep ≈ 9 seconds (tolerance for the +1-byte rounding).
        for _ in 0..<10 { try await bucket.consume(1000) }
        let slept = time.totalSlept.secondsAsDouble
        #expect(slept > 8.9 && slept < 9.2)
    }

    @Test("a chunk larger than the capacity does not starve")
    func oversizedChunkPasses() async throws {
        let time = VirtualTime()
        let bucket = BandwidthBucket(bytesPerSecond: 100, now: time.now, sleep: time.sleep)
        // Capacity is 100 tokens; a 500-byte chunk must still pass (debt
        // model) and the NEXT consume pays it off by waiting ≈ 5 seconds.
        try await bucket.consume(500)
        try await bucket.consume(100)
        let slept = time.totalSlept.secondsAsDouble
        #expect(slept > 3.9 && slept < 5.2)
    }

    @Test("two consumers share one bucket at the aggregate rate")
    func sharedBucketPacesAggregate() async throws {
        let time = VirtualTime()
        let bucket = BandwidthBucket(bytesPerSecond: 1000, now: time.now, sleep: time.sleep)
        // 2 × 5 × 1000 bytes = 10_000 bytes through ONE bucket: same math
        // as `sustainedRateIsPaced` — total virtual sleep ≈ 9 s, NOT ≈ 4.5 s
        // per consumer in parallel wall-clock (they serialize on the actor).
        async let first: Void = {
            for _ in 0..<5 { try await bucket.consume(1000) }
        }()
        async let second: Void = {
            for _ in 0..<5 { try await bucket.consume(1000) }
        }()
        _ = try await (first, second)
        let slept = time.totalSlept.secondsAsDouble
        #expect(slept > 8.9 && slept < 9.3)
    }

    @Test("setRate applies to subsequent pacing")
    func setRateApplies() async throws {
        let time = VirtualTime()
        let bucket = BandwidthBucket(bytesPerSecond: 1000, now: time.now, sleep: time.sleep)
        try await bucket.consume(1000)              // eat the initial burst
        await bucket.setRate(bytesPerSecond: 2000)  // double the rate
        try await bucket.consume(2000)              // debt from chunk 1 + this
        try await bucket.consume(2000)
        // After the burst everything is paced at 2000 B/s: 4000 bytes ≈ 2 s
        // (plus paying off the 0-token state left by the burst chunk).
        let slept = time.totalSlept.secondsAsDouble
        #expect(slept > 1.9 && slept < 2.3)
    }

    @Test("consume throws on task cancellation instead of sleeping forever")
    func consumeIsCancellable() async {
        let time = VirtualTime()
        let bucket = BandwidthBucket(
            bytesPerSecond: 1, now: time.now,
            // Never advances time: without cancellation this would loop.
            sleep: { _ in try Task.checkCancellation() })
        let task = Task {
            try await bucket.consume(1_000_000)   // burst passes (tokens 1 > 0)
            try await bucket.consume(1)           // now deep in debt → waits
        }
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }
}
```

- [x] **Step 2: Prove red** — `swift test --filter BandwidthBucketTests` ⇒ FAIL (type does not exist / compile error counts as red).

- [x] **Step 3: Implement** — `Sources/macSCPCore/RemoteFS/BandwidthBucket.swift`:

```swift
import Foundation

/// Shared token bucket pacing all transfers of one direction to a single
/// aggregate bandwidth limit (M6a). Owned per direction by
/// `TransferQueueViewModel`; every concurrent `copyFile` calls
/// `consume(_:)` before each chunk, so N parallel transfers share exactly
/// one limit instead of getting N × limit (the M5c per-transfer virtual
/// clock this replaces).
///
/// Debt model: `consume` waits only until the token balance is POSITIVE,
/// then deducts the full chunk size — the balance may go negative. That
/// keeps chunks larger than the burst capacity (64 KiB chunks under a
/// sub-64-KB/s limit) from starving while still pacing the average rate
/// exactly to the limit; the burst is bounded by capacity + one chunk.
///
/// Clock and sleep are injectable so tests drive a virtual timeline and
/// never actually sleep. The defaults use the real `ContinuousClock` and
/// `Task.sleep` — unlike the replaced virtual clock, real elapsed transfer
/// time refills tokens, so an already-slow link is no longer throttled
/// additionally (the M5c over-throttling).
public actor BandwidthBucket {
    private var rate: Double            // tokens (bytes) per second
    private var capacity: Double        // burst bound: 1 second of rate
    private var tokens: Double
    private var lastRefill: ContinuousClock.Instant
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        bytesPerSecond: Int,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        // A non-positive rate is a caller bug (the queue creates no bucket
        // for "0 = unlimited") — clamp defensively rather than trap.
        self.rate = Double(max(1, bytesPerSecond))
        self.capacity = self.rate
        self.tokens = self.rate         // start with a full burst
        self.now = now
        self.sleep = sleep
        self.lastRefill = now()
    }

    /// Updates the rate (Settings change at runtime). Tokens are clamped to
    /// the new capacity; a negative balance (debt) is deliberately kept.
    public func setRate(bytesPerSecond: Int) {
        refill()
        rate = Double(max(1, bytesPerSecond))
        capacity = rate
        tokens = min(tokens, capacity)
    }

    /// Waits until the token balance is positive, then deducts `bytes`.
    /// Cooperatively cancellable: throws `CancellationError` from the
    /// injected `sleep` (Task.sleep default) or the explicit check.
    public func consume(_ bytes: Int) async throws {
        while true {
            try Task.checkCancellation()
            refill()
            if tokens > 0 {
                tokens -= Double(bytes)
                return
            }
            // Sleep until the balance would turn positive again (+1 token
            // against rounding), then re-check — several consumers may have
            // been admitted meanwhile (actor reentrancy), so this loops.
            let waitSeconds = (-tokens + 1) / rate
            try await sleep(Duration.seconds(fromDouble: waitSeconds))
        }
    }

    private func refill() {
        let instant = now()
        let elapsed = (instant - lastRefill).secondsAsDouble
        lastRefill = instant
        guard elapsed > 0 else { return }
        tokens = min(capacity, tokens + elapsed * rate)
    }
}
```

- [x] **Step 4: Prove green** — `swift test --filter BandwidthBucketTests` ⇒ all PASS; then full suite `swift test` ⇒ 295 + new ones green.
- [x] **Step 5: Commit** — `feat: add the shared bandwidth token bucket`.

---

### Task 2: Move the engine + queue onto the bucket

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/TransferEngine.swift` (signature + throttle block, lines 83–164)
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (limit properties lines 122–130, `process` engine call lines 605–622)
- Test: `Tests/macSCPCoreTests/TransferEngineTests.swift` (migrate throttle tests), `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift` (direction mapping)

**Interfaces:**
- Consumes: `BandwidthBucket` from T1 (`consume(_:)`, `init(bytesPerSecond:now:sleep:)`).
- Produces: `TransferEngine.copyFile(from:sourcePath:to:destinationDirectory:fileName:resume:throttle:onProgress:)` — the parameters `bytesPerSecondLimit: Int` and `sleep:` are REMOVED without replacement, newly added `throttle: BandwidthBucket? = nil`. `TransferQueueViewModel` keeps the public properties `uploadLimitBytesPerSec`/`downloadLimitBytesPerSec: Int` (API-compatible for ContentView), but internally holds `uploadBucket`/`downloadBucket: BandwidthBucket?` (internal, visible to tests via `@testable`).

**Engine changes in detail:**
1. Replace the doc comment for the parameters `bytesPerSecondLimit`/`sleep` (lines 83–87) with a `throttle` paragraph: shared bucket, nil = unlimited, reference to the `BandwidthBucket` doc.
2. Signature: `resume: Bool = false, throttle: BandwidthBucket? = nil,` (no more `sleep` hook).
3. Remove the entire virtual-clock block: the `throttledElapsed` variable (line 143 incl. comment block 129–142) and the `if bytesPerSecondLimit > 0 { … }` block (lines 151–164). Instead, in the `unfolding` closure after the `onProgress` call:

```swift
            // Shared throttle (M6a): every chunk asks the direction's bucket
            // before being handed to the destination. `consume` also throws
            // on task cancellation — in addition to the check above, not in
            // place of it.
            if let throttle {
                try await throttle.consume(chunk.count)
            }
```

4. The `Duration` extension (lines 34–50) stays — `BandwidthBucket` and `RateWindow` keep using it.

**Queue changes in detail:**
1. Replace the property block (lines 122–130):

```swift
    /// Bandwidth ceilings in bytes/second, direction-dependent; `0` (default)
    /// = unlimited. Backed by ONE shared `BandwidthBucket` per direction
    /// (M6a): all concurrent transfers of a direction share the limit in
    /// aggregate. CHANGING a non-zero limit re-rates the existing bucket, so
    /// it applies live even to running transfers; ENABLING/DISABLING (0 ↔ n)
    /// swaps the bucket reference and therefore only applies to transfers
    /// starting afterwards (running ones keep the reference they resolved).
    public var uploadLimitBytesPerSec: Int = 0 {
        didSet { uploadBucket = Self.updatedBucket(uploadBucket, bytesPerSecond: uploadLimitBytesPerSec) }
    }
    public var downloadLimitBytesPerSec: Int = 0 {
        didSet { downloadBucket = Self.updatedBucket(downloadBucket, bytesPerSecond: downloadLimitBytesPerSec) }
    }

    /// The per-direction shared buckets handed to `TransferEngine.copyFile`.
    /// Internal for test visibility.
    private(set) var uploadBucket: BandwidthBucket?
    private(set) var downloadBucket: BandwidthBucket?

    private static func updatedBucket(
        _ bucket: BandwidthBucket?, bytesPerSecond: Int
    ) -> BandwidthBucket? {
        guard bytesPerSecond > 0 else { return nil }
        guard let bucket else { return BandwidthBucket(bytesPerSecond: bytesPerSecond) }
        // Keep the instance (running transfers hold it) and re-rate it. The
        // hop is fire-and-forget by design: pacing catches up on the next
        // consume, there is nothing to await for correctness.
        Task { await bucket.setRate(bytesPerSecond: bytesPerSecond) }
        return bucket
    }
```

2. In `process` (lines 605–622): replace the `bytesPerSecondLimit` let (lines 605–610 incl. comment) with

```swift
        // Direction-dependent shared bucket (M6a): resolved HERE, at the
        // moment the transfer actually starts — a Settings change rebuilds
        // the bucket and therefore only applies to items starting next.
        let throttle = job.direction == .upload ? uploadBucket : downloadBucket
```

   and in the `TransferEngine.copyFile` call replace `bytesPerSecondLimit: bytesPerSecondLimit,` with `throttle: throttle,`.

**Test migration (existing throttle tests in `TransferEngineTests.swift`):** Today's M5c/T5 tests inject a counting `sleep` into `copyFile`. They are switched to T1's pattern: a `BandwidthBucket` with a `VirtualTime` driver (move the helper from T1's test file into a shared file: **Create** `Tests/macSCPCoreTests/VirtualTime.swift`, move it there from `BandwidthBucketTests.swift`, `final class VirtualTime` without `private`) is passed to `copyFile(throttle:)` and the accumulated virtual sleep time is asserted (same order of magnitude as before: transferred bytes ÷ limit, minus 1 s burst). Tests that only checked "no limit ⇒ no sleep" now assert `throttle: nil` ⇒ `totalSlept == .zero` — the bucket stub falls away; there is nothing to assert without a bucket, so reduce or drop such tests to sensible variants (justify in the report).

**New queue test (`TransferQueueViewModelTests.swift`):**

```swift
    @Test("direction limits build one shared bucket per direction")
    @MainActor
    func directionLimitsBuildBuckets() {
        let queue = TransferQueueViewModel()
        #expect(queue.uploadBucket == nil && queue.downloadBucket == nil)
        queue.uploadLimitBytesPerSec = 1024
        #expect(queue.uploadBucket != nil && queue.downloadBucket == nil)
        queue.downloadLimitBytesPerSec = 2048
        #expect(queue.downloadBucket != nil)
        // Changing a non-zero limit keeps the SAME bucket instance (running
        // transfers hold it — the change must reach them live).
        let bucketBefore = queue.uploadBucket
        queue.uploadLimitBytesPerSec = 4096
        #expect(queue.uploadBucket === bucketBefore)
        queue.uploadLimitBytesPerSec = 0
        #expect(queue.uploadBucket == nil)
    }
```

- [x] **Step 1: Queue test + one migrated engine test red** — the new signature does not exist yet ⇒ compile error counts as red (`swift test --filter directionLimitsBuildBuckets`).
- [x] **Step 2: Rebuild the engine** (signature, throttle block, doc as above).
- [x] **Step 3: Rebuild the queue** (properties, `process`, doc as above).
- [x] **Step 4: Migrate throttle tests** (`VirtualTime` to `Tests/macSCPCoreTests/VirtualTime.swift`, engine tests onto the bucket, remove dead sleep-hook stubs).
- [x] **Step 5: Full suite green** — `swift test` ⇒ everything PASS (the count may shift slightly from the migration; document it in the report).
- [x] **Step 6: Commit** — `feat: pace transfers through a shared per-direction bandwidth bucket`.

---

### Task 3: Group cancel + conflict hygiene (Queue, RISK)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (`process` lines 544–568, `resolveConflictIfNeeded` lines 684–710, new method `cancelGroup`)
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift:313`, `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift:133`
- Test: `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift`

**Interfaces:**
- Consumes: existing private queue machinery (`itemGroup`, `order`, `resolvingJobIDs`, `runningTransferTasks`, `expansionTasks`, `setStatus`, `resumeWaiter`) — names exactly as in the file.
- Produces: no new public API. Behavior: decider `nil` (cancel) on a group item aborts the whole group.

**Part A — `cancelGroup`:** New private method directly under `cancelAll` (after line 468):

```swift
    /// Conflict-dialog "Cancel" on a tree item aborts the WHOLE folder
    /// transfer (M6a): sweeps this group's queued items, cancels its
    /// in-flight transfers cooperatively, and stops its expansion so no new
    /// items appear. Already-copied files stay in place (nothing is
    /// deleted). Built on the same exactly-once pattern as `cancelAll`:
    /// every swept id has its job cleared synchronously, so a later
    /// `process` guard (`jobs[id] != nil`) cannot double-terminalize it.
    /// Items of OTHER groups and ungrouped items are untouched.
    private func cancelGroup(_ groupID: UUID) {
        // Stop the expansion first — its task observes the cancellation at
        // its next checkpoint and runs `finishExpansion(succeeded: false)`.
        expansionTasks[groupID]?.cancel()
        // Sweep this group's queued (not yet started) items.
        let queuedGroupIDs = order.filter { itemGroup[$0] == groupID }
        order.removeAll { itemGroup[$0] == groupID }
        for id in queuedGroupIDs {
            setStatus(id, .cancelled)
            jobs[id] = nil
            resumeWaiter(id, with: .failure(CancellationError()))
        }
        // Sweep this group's items currently resolving a conflict in another
        // slot (their `process` bails on the missing job, exactly-once).
        let resolving = resolvingJobIDs.filter { itemGroup[$0] == groupID }
        resolvingJobIDs.subtract(resolving)
        for id in resolving {
            setStatus(id, .cancelled)
            jobs[id] = nil
            resumeWaiter(id, with: .failure(CancellationError()))
        }
        // Cancel this group's in-flight transfers cooperatively — each
        // `copyFile` throws `CancellationError` and its `process` marks the
        // item `.cancelled` (partial files stay, as in `cancelAll`).
        for (id, task) in runningTransferTasks where itemGroup[id] == groupID {
            task.cancel()
        }
    }
```

**Part B — call site in the `.cancel` branch of `process`:** The existing branch (lines 558–561) becomes:

```swift
        case .cancel:
            // Capture the group BEFORE setStatus — the terminal transition
            // removes the item's `itemGroup` entry.
            let groupID = itemGroup[jobID]
            setStatus(jobID, .cancelled)
            jobs[jobID] = nil
            resumeWaiter(jobID, with: .failure(CancellationError()))
            // Tree item: cancelling ONE conflict aborts the whole folder
            // transfer (M6a). Single-file items (no group) keep the old
            // behavior — only this item is cancelled.
            if let groupID { cancelGroup(groupID) }
            return
```

**IMPORTANT (justification for the reviewer):** `resolveConflictIfNeeded` also returns `.cancel` on the `cancelAll` bail path (line 699) — but there `jobs[job.id]` is already `nil`, so `process` turns back at the guard (line 539) beforehand and never reaches the `.cancel` branch. So `cancelGroup` runs only for real decider cancels.

**Part C — applyToAll recheck after the gate acquire:** In `resolveConflictIfNeeded`, the recheck after `conflictGate.acquire()` (lines 695–700) only covers `cancelAll`. A rule that was set WHILE this item was waiting at the gate is currently ignored ⇒ an unnecessary second prompt. Replace the block (lines 694–707):

```swift
            // Serialize prompts across parallel slots: at most one decider is
            // open at a time, FIFO. Only the prompt itself is gated.
            await conflictGate.acquire()
            // Re-check: `cancelAll` may have fired while we waited for the gate.
            // Bail without prompting (and always release, so the gate never leaks).
            guard jobs[job.id] != nil else {
                conflictGate.release()
                return .cancel
            }
            // Re-check the rule too (M6a): an "apply to all" decision made
            // while this item waited at the gate answers its conflict as
            // well — prompting again would contradict the just-made rule.
            if let rule = queueRule {
                conflictGate.release()
                resolution = rule
            } else {
                let decision = await decider(conflict)
                conflictGate.release()
                guard let decision else {
                    return .cancel                        // nil == cancel
                }
                resolution = decision.resolution
                if decision.applyToAll { queueRule = decision.resolution }
            }
```

(The preceding `let conflict = TransferConflict(...)` remains unchanged.)

**Part D — message fix:** In both files, replace the reason string `"path exists as a file: \(path)"` with `"path exists and is not a directory: \(path)"` (correctly covers a file AND a symlink/other; reason strings are English internals, not catalogued).

**New tests (in `TransferQueueViewModelTests.swift`; reuse the file's existing mocks/patterns — a test FS with controllable `stat`/streams and decider helpers already exist there; follow their conventions exactly):**

1. `treeConflictCancelAbortsWholeGroup` — a tree with 3 files, file 2 conflicts, decider answers `nil`: file 2 `.cancelled`, file 3 (queued) `.cancelled`, file 1 (already `.finished`) stays `.finished`; the group's `onCompleted` fires exactly once afterward (anyFinished).
2. `treeConflictCancelLeavesOtherItemsAlone` — same setup plus one UNGROUPED queued item and a SECOND group: both untouched (`.queued` resp. keep running).
3. `treeConflictCancelCancelsRunningGroupTransfers` — a group with one running (blocked) transfer + a conflict cancel on a second item: the running one ends `.cancelled` (cooperatively), `onCompleted` exactly-once.
4. `singleFileConflictCancelKeepsOldBehavior` — single-file conflict, decider `nil`: only this item `.cancelled`, other queued items keep running.
5. `queueRuleSetWhileWaitingAtGateIsApplied` — two parallel slots, both conflict; slot 1 answers `overwrite` + applyToAll, slot 2 waits at the gate: the decider is called only ONCE in total (counter in the decider), slot 2 follows the rule.

- [x] **Step 1: Write tests 1–5, prove red** (`swift test --filter TransferQueueViewModelTests` — the new ones fail, existing ones stay green).
- [x] **Step 2: Implement Parts A+B**, tests 1–4 green.
- [x] **Step 3: Implement Part C**, test 5 green.
- [x] **Step 4: Part D** (two strings), adjust affected existing tests (grep for `exists as a file` in Tests).
- [x] **Step 5: Full suite green** — `swift test`.
- [x] **Step 6: Commit** — `feat: cancel the whole folder transfer from a tree conflict dialog` (Parts A+B), resp. a second commit `fix: honor an apply-to-all rule set while waiting at the conflict gate` for Parts C+D, if committed separately (both forms ok, state which in the report).

---

### Task 4: Edit-integration fixes

**Files:**
- Modify: `Sources/macSCPCore/Presentation/EditSessionManager.swift` (new static sweep function)
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (`process` catch `connectionFailure` lines 641–657; make `message(for:)` line 895 `public`)
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (sweep call in `init`)
- Modify: `Sources/MacSCPApp/ContentView.swift` (`openInEditor` catch lines 767–771)
- Modify: `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj` (one new key)
- Test: `Tests/macSCPCoreTests/EditSessionManagerTests.swift`, `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift`

**Interfaces:**
- Consumes: `Job.bypassConflictCheck` (exists; `true` ONLY for edit uploads — resume retries use `resume`, not this flag), `CoreL10n.string("core.transfer.interrupted")` (key exists in both Core catalogs).
- Produces: `EditSessionManager.sweepOrphanedTempDirectories()` (`public static func`), `TransferQueueViewModel.message(for:)` becomes `public static`.

**Part A — startup sweep:** In `EditSessionManager` (below `init`):

```swift
    /// Removes the entire `macscp-edit` temp tree at app launch (M6a). Only
    /// `stopAll` cleans a session's subtree, so hard-killed app runs leave
    /// orphaned directories behind forever. At launch no edit can be active
    /// (single-instance app, sessions start later), so sweeping the whole
    /// tree is safe. Idempotent; a missing tree is a no-op.
    public static func sweepOrphanedTempDirectories() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-edit", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
    }
```

As the first line in `MacSCPApp.init()`: `EditSessionManager.sweepOrphanedTempDirectories()`.

Test (in `EditSessionManagerTests.swift`): create a directory `macscp-edit/<uuid>/probe.txt` under `FileManager.default.temporaryDirectory`, call `sweepOrphanedTempDirectories()`, `#expect` that `macscp-edit` no longer exists; a second call does not throw (idempotence).

**Part B — resume exclusion for edit uploads:** In the `connectionFailure` catch of `process`, condition the branch — BEFORE the existing code:

```swift
        } catch let error as RemoteFSError where error.isConnectionFailure {
            progressContinuation.finish()
            await consumer.value
            if job.bypassConflictCheck {
                // Editor write-back (M6a): NOT resumable — its temp source is
                // deleted by `stopAll` on disconnect, so a later resume would
                // visibly fail. Surface it as a plain failure instead; the
                // next editor save enqueues a fresh upload anyway.
                setStatus(jobID, .failed(CoreL10n.string("core.transfer.interrupted")))
                jobs[jobID] = nil
                runningTransferTasks[jobID] = nil
                resumeWaiter(jobID, with: .failure(error))
            } else {
                // Connection lost mid-transfer (M5d/T3): mark `.interrupted` …
                [existing code of lines 648–657 unchanged, indented]
            }
        }
```

Test (in `TransferQueueViewModelTests.swift`): `editUploadConnectionFailureIsFailedNotInterrupted` — edit upload via `enqueueEditUpload`, FS throws `RemoteFSError.connectionFailed`; `#expect`: status `.failed` (not `.interrupted`), `hasInterrupted == false`. Counter-check in the same test: a NORMAL transfer with the same error still becomes `.interrupted`.

**Part C — localized edit error text:** Change `TransferQueueViewModel.message(for:)` from `static func` to `public static func` (add a doc sentence: "Public: the App layer reuses this mapping for editor-open failures (M6a)."). In `ContentView.openInEditor`, replace the catch:

```swift
            } catch is CancellationError {
                // Teardown cancelled the download (disconnect while opening) —
                // the session is going away; a stale banner on the NEXT
                // session would be misattributed. Show nothing.
            } catch {
                editErrorMessage = String(format: L10n.string(
                    "edit.openFailed", "Could not open file for editing: %@"),
                    TransferQueueViewModel.message(for: error))
            }
```

Note: `enqueueAndWait` also throws `CancellationError` for skip/cancel conflicts — but edit downloads go through `beginEditing` without a conflict prompt (temp destination), so the only `CancellationError` path is teardown. No new catalog key is needed if the cancel case stays silent — the `edit.cancelled` key initially considered therefore DROPS OUT (YAGNI); the strings files stay untouched, since no new text is needed.

Test: the mapper itself is covered by existing `message(for:)` tests (if none exists: add a lookup test that compares the catalog text for `RemoteFSError.notFound(path:)` via `CoreL10n.string` — locale-pinned, same pattern as existing L10n tests).

- [x] **Step 1: Tests (sweep, resume exclusion, mapper if needed) red.**
- [x] **Step 2: Implement Parts A–C.**
- [x] **Step 3: Full suite green** — `swift test`.
- [x] **Step 4: Commit** — `fix: edit-upload interruptions, orphaned temp dirs, localized edit errors`.

---

### Task 5: Form, session, a11y, hygiene (App + Core)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` (`endEditing` lines 200–212)
- Modify: `Sources/macSCPCore/Sessions/SessionStore.swift` (`load()` lines 41–44)
- Modify: `Sources/MacSCPApp/ContentView.swift` (`onNew:` line 200, new method next to `disconnectToForm`)
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift` (FormRow, L10n binding, errorHighlight comment)
- Modify: `Sources/MacSCPApp/PolishedButtonStyle.swift` (focus ring)
- Modify: `Sources/MacSCPApp/DesignTokens.swift` (delete paper, comments)
- Test: `Tests/macSCPCoreTests/ConnectionViewModelTests.swift` (endEditing consolidation), existing tests for SessionStore

**Interfaces:**
- Consumes: T4 complete (same files, App-side).
- Produces: no new public names; `ConnectionViewModel.endEditing()` internally calls `exitEditMode()`.

**Part A — endEditing/exitEditMode consolidation** (`ConnectionViewModel`):

```swift
    /// Leaves edit mode and resets the form to the same blank state
    /// `teardownSession` leaves it in for a new connection. Built on
    /// `exitEditMode()` (mode + group reset) plus the full field reset —
    /// the two used to duplicate the mode handling (M6a).
    public func endEditing() {
        exitEditMode()
        host = ""
        port = "22"
        username = ""
        password = ""
        authChoice = .password
        keyPath = ""
        shouldSaveSession = false
        saveName = ""
        state = .idle
    }
```

(`selectedGroupID = nil` now lives in `exitEditMode()` — the explicit line drops out.) Test: `endEditingResetsEverything` — fill the form via `beginEditing`, `endEditing()`, `#expect` all fields blank, `mode == .new`, `selectedGroupID == nil`.

**Part B — "New connection" clears the fields** (`ContentView`): line 200 `onNew: { disconnectToForm() }` becomes `onNew: { newConnection() }`; new method directly above `disconnectToForm`:

```swift
    /// Sidebar "New connection": tear down any current session AND blank the
    /// form (M6a) — without this, host/username/name from a previous edit or
    /// connection stay prefilled. The toolbar "Disconnect" deliberately keeps
    /// the fields (reconnect convenience) — only this path blanks them.
    private func newConnection() {
        guard !isReconnecting else { return }
        isReconnecting = true // synchronous — prevents double teardown
        Task {
            defer { isReconnecting = false }
            await teardownSession()
            connectionViewModel.endEditing()
        }
    }
```

**Part C — SessionStore readability** (replace lines 41–44):

```swift
        // Defensive: a groupID whose group no longer exists behaves like nil.
        let knownIDs = Set(file.groups.map(\.id))
        for index in file.sessions.indices {
            guard let groupID = file.sessions[index].groupID,
                  !knownIDs.contains(groupID) else { continue }
            file.sessions[index].groupID = nil
        }
```

(Behavior identical — the existing `SessionStoreTests` stay unchanged and green and PROVE it.)

**Part D — FormRow a11y + dimming** (`ConnectionFormView`, replace lines 275–288):

```swift
/// Mockup form row (M5k): fixed 110pt right-aligned label column in
/// inkSecondary, 10pt gap to the field. The visible label lives here;
/// the wrapped controls keep their own label parameters for accessibility —
/// which is why the visible label is hidden from VoiceOver (M6a): without
/// that, every row is announced twice. The label also dims with the row's
/// enabled state, matching the system Form behavior the grid replaced.
private struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(DesignTokens.inkSecondary)
                .opacity(isEnabled ? 1 : 0.5)
                .frame(width: 110, alignment: .trailing)
                .accessibilityHidden(true)
            content
        }
    }
}
```

**Part E — L10n binding** (`ConnectionFormView.formContent`): for the eight duplicated calls (Host, Port, Username, Authentication, Password, Key path, Passphrase, Session name), a `let` in the ViewBuilder body BEFORE the respective line, e.g.:

```swift
            let hostLabel = L10n.string("connection.field.host", "Host")
            // …
                FormRow(label: hostLabel) {
                    TextField(
                        hostLabel, text: $viewModel.host,
                        prompt: Text(L10n.string("connection.field.host.placeholder", "server.example.com"))
                    )
                }
```

Same pattern for all eight; keep the keys and default strings UNCHANGED (only bind the duplication). The group picker (only one call) stays as it is.

**Part F — errorHighlight comment** (replace lines 291–293):

```swift
    /// Red outline for the form row whose validation failed. The stroke
    /// wraps label AND field, sitting 10pt horizontally / 5pt vertically
    /// outside the row's bounds so the content keeps breathing room.
```

**Part G — focus ring** (`PolishedButtonStyle`): `makeBody` delegates to a private view so `@Environment` can be used:

```swift
struct PolishedButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        PolishedButtonBody(prominent: prominent, configuration: configuration)
    }
}

/// Split out so the style can read environment values (M6a focus ring).
private struct PolishedButtonBody: View {
    let prominent: Bool
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: prominent ? .semibold : .regular))
            .padding(.vertical, 5)
            .padding(.horizontal, 14)
            .foregroundStyle(prominent ? Color.white : DesignTokens.inkSecondary)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(prominent ? DesignTokens.remoteBlue : DesignTokens.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(DesignTokens.hairline, lineWidth: prominent ? 0 : 1)
            )
            // Full Keyboard Access: custom button styles suppress the system
            // focus ring, so draw one — 2pt remote blue, slightly outset so
            // it never collides with the secondary variant's hairline (M6a).
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(DesignTokens.remoteBlue, lineWidth: isFocused ? 2 : 0)
                    .padding(-3)
            )
            .opacity(configuration.isPressed ? 0.85 : (isEnabled ? 1 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}
```

The `extension ButtonStyle where Self == PolishedButtonStyle` stays unchanged. VERIFICATION REQUIRED (in the report): `@Environment(\.isFocused)` must actually fire in the button-label context — if it does not show up during the T6 smoke test, the documented fallback is to solve the ring via `.focusable(interactions: .activate)` + `@FocusState` at the button call site; do NOT silently drop it.

**Part H — delete the paper token + comments** (`DesignTokens.swift`): lines 67–71 become:

```swift
    // Surface hierarchy (mockup: card content surface on the window ground).
    // `paper` (the mockup's page ground) had no consumer after the polish
    // rounds and was dropped (M6a, YAGNI).
    static let card = Color(nsColor: dynamicNS(light: 0xFFFFFF, dark: 0x14212E))
```

And the stale lines 56–57 ("staged for the sidebar polish round") become:

```swift
    /// SwiftUI wrappers alongside the NS variants — the file table consumes
    /// the NS colors directly, SwiftUI views the wrappers.
```

- [x] **Step 1: `endEditingResetsEverything` red** (the assertion on `selectedGroupID == nil` after `beginEditing` with a group fails, as long as the old double implementation… — if the test is immediately green: flag it in the report as a characterization test; the refactor afterward proves behavior preservation).
- [x] **Step 2: Implement Parts A–H.**
- [x] **Step 3: Full suite green** — `swift test`; `swift build` warning-free with respect to the changed files.
- [x] **Step 4: Commit** — `fix: form a11y, blank new-connection form, focus ring, code hygiene`.

---

### Task 6: Wrap-up verification (coordinator, no subagent)

- [x] Start the Docker rig (`docker compose -f docker/test-server/compose.yml start` — ONLY from the main checkout), then `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` ⇒ fully green.
- [x] Visual smoke test (rebuild the App wrapper): (1) global throttle — 300 KB/s limit, TWO parallel downloads: sum of the rates ≈ 300 (not 600); (2) folder conflict → "Cancel" stops the whole group, single-file cancel only that item; (3) "New connection" after edit mode: form empty; (4) tab to the form buttons (Full Keyboard Access on): blue focus ring visible — otherwise pursue the fallback from T5/Part G; (5) VoiceOver spot check: form row is announced ONCE; (6) disabled dimming of the labels during Connect (the 10.255.255.1 trick); (7) a quick edit round trip (double-click → TextEdit → Save → Upload) as a regression check.
- [x] Check off plan checkboxes, ledger entries, Opus whole-branch final review (base = commit before T1), fixes, push, `gh run watch`, stop the rig, memory update.
