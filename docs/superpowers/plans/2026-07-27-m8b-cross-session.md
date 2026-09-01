# M8b — Cross-Session-Transfers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** "Transfer to session xy" from both panes — including a direct remote→remote stream through the app, a double-bucket throttle, a second rig container for the server-to-server proof, and a close warning for target tabs.

**Architecture:** The job lands in the SOURCE tab's queue; the engine is already source-/target-agnostic, it receives a SECOND bucket for remote→remote (counts in both directions — spec §4 carry-over from M8a). The menu model in Core is extended with target sessions (`transferToSession`), the exhaustive switch in `ContentView` enforces handling the new case at compile time. Queue items carry an opaque `destinationTabID` for the close warning.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, AppKit `NSMenu` (macOS 15 → `NSMenuItem.subtitle` available), Docker Compose rig.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-27-m8-tabs-design.md` §4 (double bucket), §5, §6 — binding. Branch: **develop**.
- Queue invariants unchanged (FIFO, exactly-once waiter, cancelAll, group onCompleted exactly-once); conflict machinery runs unchanged against the target FS.
- Throttle semantics: remote→remote consumes EVERY chunk from BOTH bucket pairs (down + up — it really is both on the line); sequential `consume` on two independent actors is deadlock-free (no lock is held across an await); total wait time = max of both allowances ⇒ rate = min of both limits. Local→target-remote counts only against the upload bucket.
- Menu rules (spec §6, unit-tested): target entries only when the selection is transferable (same gate as `transferToOtherPane`); NEVER the tab's own entry; NEVER form tabs (the app only passes other connected tabs); order = strip order; without other connected tabs the look is as today (no forced submenu). Target path is frozen at CLICK time.
- Edges (spec §5.3): target tab closes during the stream → existing M5d mapping (no special path); close confirmation also appears if the tab is the TARGET of active transfers from other tabs (own text); enqueue against a dead FS ends as a normal error message.
- Symlinks stay excluded from transfers (M7b rules unchanged); folders via `enqueueTree`.
- Rig: NEVER `up`/`down` from worktrees, only `start`/`stop` from the main checkout; second container, same image PIN, port 2223; `PerSourcePenalties` disabled (shared sshd_config.d).
- All new UI text EN/DE (`Sources/MacSCPApp/Resources/*/Localizable.strings`); code + comments ONLY English.
- Conventional Commits (English), footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + full `swift test` green after every task (starting point 376 tests / 32 suites); gated suites in T3 (implementer, rig running) and T5.
- TDD for Core; App target untestable → T4 delivers build + behavior description; tests run SYNCHRONOUSLY in the foreground.
- M8a backlog NOT in M8b (tab a11y, menu cleanup) — none of it gets "carried along".

## Schedule

T1 (double bucket + destinationTabID, Core) → T2 (menu model, Core) → T3 (second rig container + gated remote→remote test) → T4 (App: submenu, handler, close warning) → T5 wrap-up (coordinator).

---

### Task 1: Engine double bucket + queue extensions (Core)

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/TransferEngine.swift` (`copyFile` ~line 89–143)
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (job/item, `enqueue`/`enqueueAndWait`/`enqueueTree`, throttle resolution ~line 697)
- Test: `Tests/macSCPCoreTests/TransferEngineTests.swift`, `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift`

**Interfaces:**
- Consumes: `BandwidthBucket` (injectable clock via the existing test init), `BandwidthLimiter` (M8a).
- Produces (T3/T4 rely on this exactly):
  - `TransferEngine.copyFile(..., throttle: BandwidthBucket? = nil, secondaryThrottle: BandwidthBucket? = nil, ...)` — every chunk consumes `throttle` first, then `secondaryThrottle`.
  - `TransferQueueViewModel.enqueue(fileName:direction:source:sourcePath:destination:destinationDirectory:onCompleted:destinationTabID:crossRemote:)` — both new parameters have a default (`destinationTabID: UUID? = nil`, `crossRemote: Bool = false`); the same extension on `enqueueTree` (inherited by all expanded items) and NOT needed on `enqueueAndWait` (no consumer).
  - `crossRemote: true` ⇒ throttle resolution: primary = `limiter?.uploadBucket`, secondary = `limiter?.downloadBucket` (the job's direction is `.upload` — writing to the target; the indicator shows amber).
  - `TransferQueueViewModel.hasActiveItems(destinationTabID: UUID) -> Bool` — true when a non-terminal item (queued/running/in conflict) carries this target tab ID.

- [x] **Step 1: Failing tests.** In `TransferEngineTests.swift` (follow the file's existing patterns for FS mocks/bucket clock — adapt helper names, keep assertions unchanged):

```swift
    @Test func copyFileConsumesBothThrottles() async throws {
        // 8 KiB file, primary 8 KiB/s, secondary 2 KiB/s: the pace must
        // follow the TIGHTER bucket — total virtual wait ≈ 4s, not 1s.
        // Build both buckets on the same injected virtual clock (existing
        // BandwidthBucket test init), copy, assert the recorded sleep total
        // is within the file's tolerance pattern for 4s (mirror the M6a
        // steady-state test's tolerance).
    }

    @Test func copyFileSecondaryThrottleNilBehavesAsBefore() async throws {
        // Same setup with secondaryThrottle: nil — wait ≈ 1s (regression).
    }
```

(Align the concrete values/tolerances with the file's existing M6a throttle tests; the test MUST fail because `secondaryThrottle` does not exist yet.)

In `TransferQueueViewModelTests.swift`:

```swift
    @Test func crossRemoteJobResolvesBothBuckets() async throws {
        // Queue with a BandwidthLimiter (both limits set), enqueue with
        // crossRemote: true, let the job run against the mock FS pair and
        // assert completion; the bucket WIRING is proven at the engine level —
        // here assert the job completes and the item's direction is .upload.
    }

    @Test func hasActiveItemsTracksDestinationTab() async throws {
        let tabID = UUID()
        // enqueue a job with destinationTabID: tabID against a gated mock
        // (use the existing signal-gate helpers so the job stays .running),
        // assert hasActiveItems(destinationTabID: tabID) == true and a random
        // UUID == false; release the gate, await completion, assert false.
    }

    @Test func enqueueTreeForwardsDestinationTabID() async throws {
        // enqueueTree(..., destinationTabID: tabID) over a small mock tree;
        // while items are gated .running, hasActiveItems(destinationTabID:)
        // is true; after completion false.
    }
```

- [x] **Step 2: Prove red.** `swift test --filter TransferEngineTests` and `--filter TransferQueueViewModelTests` → FAIL (parameters do not exist).

- [x] **Step 3: Engine.** In `copyFile`, add the parameter `secondaryThrottle: BandwidthBucket? = nil` (after `throttle`), doc line: "Second bucket for cross-remote transfers (M8b): a remote→remote stream is real download AND upload on this machine's link, so every chunk pays both buckets; the pace follows the tighter one." In the chunk loop, after the existing `try await throttle.consume(chunk.count)`:

```swift
            if let secondaryThrottle {
                try await secondaryThrottle.consume(chunk.count)
            }
```

- [x] **Step 4: Queue.** Extend `Job` with `let destinationTabID: UUID?` and `let crossRemote: Bool`; extend `Item` with `public let destinationTabID: UUID?` (for `hasActiveItems`; display unchanged). Extend `enqueue`/`enqueueTree` with the parameters, with defaults (`enqueueTree` forwards both to every expanded file item). Throttle resolution at job start:

```swift
        let throttle: BandwidthBucket?
        let secondary: BandwidthBucket?
        if job.crossRemote {
            // Cross-remote (M8b): the stream is upload to the target AND
            // download from the source — both app-global buckets pay.
            throttle = limiter?.uploadBucket
            secondary = limiter?.downloadBucket
        } else {
            throttle = job.direction == .upload
                ? limiter?.uploadBucket : limiter?.downloadBucket
            secondary = nil
        }
```

Extend the `copyFile` call with `secondaryThrottle: secondary`. New:

```swift
    /// True while any non-terminal item targets the given tab (M8b) — the
    /// app asks every OTHER tab's queue before closing a tab, so a close
    /// can warn when it would sever incoming cross-session streams.
    public func hasActiveItems(destinationTabID: UUID) -> Bool {
        items.contains { $0.destinationTabID == destinationTabID && !$0.status.isTerminal }
    }
```

(Match the exact `isTerminal` access form to the file's `Item.Status`.)

- [x] **Step 5: Green + full suite.** `swift test` → 376 + new ones (record the number in the report); build clean.

- [x] **Step 6: Commit.** `feat: pay both bandwidth buckets on cross-remote transfers`

---

### Task 2: Menu model with target sessions (Core)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/BrowserContextMenu.swift`
- Test: `Tests/macSCPCoreTests/BrowserContextMenuTests.swift`

**Interfaces:**
- Produces (T4 relies on this exactly):
  - `public struct CrossSessionTarget: Equatable, Sendable, Identifiable { public let id: UUID; public let title: String; public let remotePath: String; public init(id:title:remotePath:) }` (id = tab ID; `remotePath` = the target tab's current remote path, frozen at menu-build time).
  - `BrowserMenuEntry` + `case transferToSession(CrossSessionTarget)`.
  - `entries(for:side:crossSessionTargets:)` — new parameter `crossSessionTargets: [CrossSessionTarget] = []`; the existing two-parameter form stays functional as an overload/default (existing callers + tests unchanged).
  - Rule: `transferToSession` entries appear exactly when `transferToOtherPane` also appears (same transferability gate), directly AFTER it, in list order (= strip order, as supplied by the app). Empty list ⇒ return exactly as today.

- [x] **Step 1: Failing tests** (match the style of the existing `BrowserContextMenuTests`):

```swift
    @Test func crossSessionTargetsFollowTransferEntry() {
        let t1 = CrossSessionTarget(id: UUID(), title: "db-prod", remotePath: "/srv")
        let t2 = CrossSessionTarget(id: UUID(), title: "backup", remotePath: "/volume1")
        let entries = BrowserContextMenu.entries(
            for: [fileItem("/a.txt")], side: .local, crossSessionTargets: [t1, t2])
        #expect(entries.starts(with: [
            .transferToOtherPane, .transferToSession(t1), .transferToSession(t2)]))
    }

    @Test func crossSessionTargetsAbsentWhenSelectionNotTransferable() {
        let t = CrossSessionTarget(id: UUID(), title: "x", remotePath: "/")
        // Symlink-only selection: no transfer entry -> no session targets.
        let entries = BrowserContextMenu.entries(
            for: [symlinkItem("/l")], side: .remote, crossSessionTargets: [t])
        #expect(!entries.contains { if case .transferToSession = $0 { return true }; return false })
        #expect(!entries.contains(.transferToOtherPane))
    }

    @Test func emptyTargetsKeepTodayShape() {
        let with = BrowserContextMenu.entries(for: [fileItem("/a")], side: .local, crossSessionTargets: [])
        let without = BrowserContextMenu.entries(for: [fileItem("/a")], side: .local)
        #expect(with == without)
    }

    @Test func backgroundClickIgnoresTargets() {
        let t = CrossSessionTarget(id: UUID(), title: "x", remotePath: "/")
        #expect(BrowserContextMenu.entries(for: [], side: .local, crossSessionTargets: [t]) == [.newFolder])
    }
```

- [x] **Step 2: Prove red**, then implement: after the `transferToOtherPane` append, `entries.append(contentsOf: crossSessionTargets.map { .transferToSession($0) })`. Update the doc comments (the `transferToOtherPane` comment already says "M8 adds per-session targets").

- [x] **Step 3: Green + full suite + commit.** `feat: add cross-session targets to the context-menu model`

---

### Task 3: Second rig container + gated remote→remote test

**Files:**
- Modify: `docker/test-server/compose.yml`
- Test: `Tests/macSCPCoreTests/CitadelIntegrationTests.swift` (or whichever file holds the `MACSCP_ITEST` suite — check beforehand; insert the new tests there)

**Interfaces:**
- Consumes: `TransferEngine.copyFile(..., secondaryThrottle:)` (T1), existing Docker suite helpers (connect config testuser/testpass, port constant, cleanup pattern).
- Produces: second sshd service on **127.0.0.1:2223** (same image PIN `lscr.io/linuxserver/openssh-server:10.3_p1-r0-ls230`, container `macscp-test-sshd-2`, same env, same `sshd_config.d` mounts, its OWN empty seed directory `./seed2:/data/seed:ro` — create the directory with `.gitkeep`).

- [x] **Step 1: Extend compose** (service `sshd2` as a copy of `sshd` with `container_name: macscp-test-sshd-2`, `ports: ["2223:2222"]`, `./seed2` mount). Re-create the rig from the MAIN checkout — a one-time `docker compose -f docker/test-server/compose.yml up -d` is needed here (new service; avoid rotating the first container's host key: `up -d` only re-creates the NEW service as long as the old one keeps running unchanged — secure that with `docker compose ... up -d --no-recreate`). Keep both containers running.

- [x] **Step 2: Failing gated test** (in the existing Docker suite, same gate convention):

```swift
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"))
    func remoteToRemoteStreamCopiesByteIdentical() async throws {
        // Connect to BOTH rig servers (ports 2222 and 2223, same creds,
        // follow the suite's existing connect/TOFU test helpers).
        // 1. Write a ~256 KiB random payload to server 1 (existing write
        //    helpers), remember its bytes.
        // 2. TransferEngine.copyFile(source: fs1, sourcePath: ...,
        //    destination: fs2, destinationPath: ...) — remote to remote,
        //    no local temp file involved by construction.
        // 3. Read the file back from server 2, #expect(bytes identical).
        // 4. Cleanup on both servers (defer, existing delete helpers).
    }
```

Proving red here means: the test fails BEFORE Step 1 (only one server) — task order: write the test first, `MACSCP_ITEST=1 swift test --filter <name>` against the old rig → FAIL (connection refused 2223), then the compose step, then green.

- [x] **Step 3: Prove green.** `MACSCP_ITEST=1 swift test` in FULL (all gated suites, both containers) + ungated `swift test`.

- [x] **Step 4: Commit.** `feat: add a second test server and prove remote-to-remote streaming`

---

### Task 4: App — submenu, handler, close warning

**Files:**
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift` (NSMenu bridge), `Sources/MacSCPApp/BrowserPane.swift` (pass-through), `Sources/MacSCPApp/ContentView.swift` (build targets, handler, close warning), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: none (App target; smoke in T5)

**Interfaces:**
- Consumes: `CrossSessionTarget`/`transferToSession` (T2), `enqueue(..., destinationTabID:crossRemote:)`/`enqueueTree(...)`/`hasActiveItems(destinationTabID:)` (T1), `tabsModel`/`SessionTab` (M8a).
- Produces: context-menu "Transfer" as a submenu as soon as target sessions exist; close confirmation also for target tabs.

**Behavior requirements:**
1. **Build targets (ContentView):** closure `crossSessionTargets(for tab: SessionTab) -> [CrossSessionTarget]` — all OTHER tabs in strip order with `session != nil`, mapped to `CrossSessionTarget(id: other.id, title: other.displayTitle, remotePath: other.session!.remote.currentPath)`. Pass as a closure through `BrowserPane` into the table coordinator (re-evaluated freshly on EVERY `menuNeedsUpdate` — menu build freezes the path, spec §5.3).
2. **NSMenu bridge:** if the model contains at least one `transferToSession` entry, ALL transfer* entries become a submenu "Transfer"/"Übertragen" (new key `menu.transfer.submenu`): first item = the previous `transferToOtherPane` title, separator, then per target `String(format: L10n.string("menu.transfer.toSession", "To “%@”"), target.title)` with `menuItem.subtitle = target.remotePath` (macOS 15 ≥ 14.4, available). WITHOUT target entries, today's flat structure stays byte-identical. Keep the `MenuActionBox` pattern (selection by value; carry the target in the representedObject).
3. **Handler (ContentView, exhaustive switch):** `case .transferToSession(let target)`: target tab via `tabsModel.tabs.first { $0.id == target.id }`; guard `let targetSession = targetTab?.session` else return (target disconnected in the meantime — enqueue is skipped, no crash; the queue error message only arises for jobs already running, spec §5.3). Per selection item (skip symlinks like `transferSelection`):
   - Local source: `enqueue(fileName:direction:.upload, source: tab.session!.localFS, sourcePath:, destination: targetSession.remoteFS, destinationDirectory: target.remotePath, onCompleted: [weak remote = targetSession.remote] refresh, destinationTabID: target.id)`; folders analogous via `enqueueTree`.
   - Remote source: identical, but `source: tab.session!.remoteFS` and `crossRemote: true` (direction stays `.upload`).
   All on the SOURCE tab's queue (`tab.transferQueue`).
4. **Close warning:** `requestClose` additionally asks whether ANY other tab reports `hasActiveItems(destinationTabID: tab.id)`; then confirm with its own text `tabs.close.incomingTransfers` ("Other tabs are streaming to this session; closing cancels those transfers." / "Andere Tabs übertragen gerade zu dieser Session; Schließen bricht diese Übertragungen ab.") — both reasons can apply together (combine the texts: own hint plus incoming hint, one under the other).
5. Keys EN/DE: `menu.transfer.submenu` "Transfer"/"Übertragen", `menu.transfer.toSession` "To “%@”"/"Zu „%@"", `tabs.close.incomingTransfers` (see above).

- [x] **Step 1:** bridge + pass-through; **Step 2:** handler; **Step 3:** close warning; **Step 4:** catalog keys + cross-check (every key in BOTH files); **Step 5:** `swift build` (0 errors, no new warnings) + full `swift test` (state at T3); **Step 6:** commit `feat: transfer selections to other session tabs from the context menu`.

---

### Task 5: Wrap-up verification (coordinator)

- [x] Gated suites with BOTH containers: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` ⇒ fully green, zero skips (386 before / 389 after the final-review fixes).
- [ ] Visual smoke — **delegated to the maintainer** (wrapper is running; checklist in the milestone summary): submenu shows only other connected tabs (never a form tab, never the tab's own) with a path subtitle; local selection → target tab's remote (queue in the source tab, target pane refreshes); remote selection → server-to-server (docker exec proof on container 2, no local temp file); throttle: remote→remote at limit X depresses BOTH directions (rate ≈ min); folder transfer cross-session including the conflict sheet in the SOURCE tab; closing the target tab during a stream → warning text, after confirmation a failed transfer in the source tab (no hang); without a second tab the menu looks as today; regressions: transferToOtherPane, M7b dialogs.
- [x] Plan checkboxes, ledger, Opus whole-branch final review (base = commit before T1; "No" with one Critical → fix commit d147ed5 → re-review "Ready to merge: Yes"), fixes, push develop, CI, rig `stop`, memory update, milestone summary (+ question: tag release v1.1.0 now — M7+M8 complete).
