# M8a — Tab Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One window holds several simultaneously active SSH sessions as tabs — tab strip, per-tab state, app-global bandwidth buckets; background tabs keep running fully.

**Architecture:** The tab management rules live as a generic, UI-free `TabsViewModel` in Core (testable). The app bundles the previously window-wide state into `SessionTab` objects (per tab: ConnectionViewModel, BrowserSession?, TransferQueueViewModel, ConflictPromptBridge) and renders only the active tab. The direction buckets move out of the queue into an app-wide injected `BandwidthLimiter`.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing (`@Test`/`#expect`), SwiftUI + AppKit, `@Observable`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-27-m8-tabs-design.md` — binding. Branch: **develop**. Mockup: `docs/design/assets/m8-tabs-mockup.html`.
- Architecture invariant (refined): one SSH connection per **tab**; the tab collection belongs to the window. NO new app singleton other than `SettingsStore` (exists) and the new `BandwidthLimiter` (both created in `MacSCPApp`, passed through by parameter).
- Teardown order per tab unchanged: `conflictBridge.dismiss()` → `queue.cancelAll()` → `editManager.stopAll()` → `terminal.shutdown()` → `remote.disconnect()`; no `deinit` cleanup.
- Queue invariants unchanged: FIFO start order, exactly-once waiter, `cancelAll` leaves no orphans.
- Bandwidth: the limit applies app-globally across all tabs (ONE bucket per direction app-wide); live re-rate with generation counter (M6b) stays; 0 = off; 0↔n swaps the reference (applies only to transfers starting afterward) — semantics exactly as today, just one level higher.
- `maxConcurrentTransfers` deliberately stays PER tab queue (per-connection limit); `showHiddenFiles` applies to ALL tabs.
- Only the active tab is mounted; terminal remount goes through the existing 256-KiB replay buffer; conflict sheets appear only in their own (active) tab.
- Pristine state (exactly one unconnected form tab): strip invisible, window compact 700×460 — launch image identical to today. From the second tab ON, OR a connected single tab: browser size (≥930×620), no shrink on tab switch.
- Shortcuts: ⌘T terminal (stays), ⌘N new tab, ⌘W closes the active tab (last unconnected tab → window), ⌘1–⌘9 direct selection. (⌃Tab cycling: only if feasible as a menu shortcut — otherwise leave it out, documented, no event monitor.)
- All new UI texts cataloged EN/DE (`Sources/MacSCPApp/Resources/*/Localizable.strings`); code + comments English ONLY.
- Conventional Commits (English), footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + full `swift test` green after every task (starting point 361 tests / 30 suites); gated suites only in T5.
- TDD for Core (TabsViewModel, BandwidthLimiter, queue accessors); the app target is untestable — app tasks deliver build + behavior description, the visual smoke test is T5.
- Run tests SYNCHRONOUSLY in the foreground (no run_in_background).

## Schedule

T1 (TabsViewModel, Core) → T2 (BandwidthLimiter + queue accessors, Core) → T3 (SessionTab + ContentView rework, App, RISK) → T4 (tab strip UI + shortcuts + window, App) → T5 completion (coordinator).

---

### Task 1: TabsViewModel (Core)

**Files:**
- Create: `Sources/macSCPCore/Presentation/TabsViewModel.swift`
- Test: `Tests/macSCPCoreTests/TabsViewModelTests.swift` (new)

**Interfaces:**
- Produces (T3/T4 rely on this exactly):
  - `@MainActor @Observable public final class TabsViewModel<Tab: Identifiable> where Tab.ID == UUID`
  - `public private(set) var tabs: [Tab]`, `public private(set) var activeTabID: UUID`
  - `public init(initial: Tab)`
  - `public var activeTab: Tab { get }`
  - `public var isLastTab: Bool { get }` (tabs.count == 1)
  - `public func addTab(_ tab: Tab)` (to the end, becomes active)
  - `public func activate(_ id: UUID)` (no-op for unknown id)
  - `@discardableResult public func closeTab(_ id: UUID) -> Bool` (false for the last tab or an unknown id; if the closed tab was active, the RIGHT neighbor becomes active, otherwise the left one)
  - `public func sidebarConnectTarget(activeTabIsConnected: Bool, makeTab: () -> Tab) -> Tab` (unconnected → current active tab; connected → `makeTab()` is appended via `addTab` and returned)

- [x] **Step 1: Failing Tests** — `Tests/macSCPCoreTests/TabsViewModelTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

/// Plain payload stand-in — the rules under test are payload-agnostic.
private struct StubTab: Identifiable, Equatable {
    let id: UUID
    var connected: Bool = false
}

@Suite("TabsViewModel")
@MainActor
struct TabsViewModelTests {
    @Test func initialTabIsActiveAndLast() {
        let first = StubTab(id: UUID())
        let vm = TabsViewModel(initial: first)
        #expect(vm.tabs.map(\.id) == [first.id])
        #expect(vm.activeTabID == first.id)
        #expect(vm.activeTab.id == first.id)
        #expect(vm.isLastTab)
    }

    @Test func addTabAppendsAndActivates() {
        let first = StubTab(id: UUID())
        let vm = TabsViewModel(initial: first)
        let second = StubTab(id: UUID())
        vm.addTab(second)
        #expect(vm.tabs.map(\.id) == [first.id, second.id])
        #expect(vm.activeTabID == second.id)
        #expect(!vm.isLastTab)
    }

    @Test func activateSwitchesAndIgnoresUnknown() {
        let first = StubTab(id: UUID())
        let vm = TabsViewModel(initial: first)
        let second = StubTab(id: UUID())
        vm.addTab(second)
        vm.activate(first.id)
        #expect(vm.activeTabID == first.id)
        vm.activate(UUID()) // unknown — no-op
        #expect(vm.activeTabID == first.id)
    }

    @Test func closeActiveTabActivatesRightNeighbor() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID()), c = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b)
        vm.addTab(c)
        vm.activate(b.id)
        #expect(vm.closeTab(b.id))
        #expect(vm.tabs.map(\.id) == [a.id, c.id])
        #expect(vm.activeTabID == c.id) // right neighbor
    }

    @Test func closeActiveLastPositionActivatesLeftNeighbor() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b) // b active, rightmost
        #expect(vm.closeTab(b.id))
        #expect(vm.activeTabID == a.id) // no right neighbor -> left
    }

    @Test func closeInactiveTabKeepsActive() {
        let a = StubTab(id: UUID()), b = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        vm.addTab(b) // b active
        #expect(vm.closeTab(a.id))
        #expect(vm.activeTabID == b.id)
        #expect(vm.tabs.map(\.id) == [b.id])
    }

    @Test func lastTabCannotBeClosed() {
        let a = StubTab(id: UUID())
        let vm = TabsViewModel(initial: a)
        #expect(!vm.closeTab(a.id))
        #expect(vm.tabs.count == 1)
        #expect(!vm.closeTab(UUID())) // unknown id -> false, no change
    }

    @Test func sidebarConnectTargetReusesUnconnectedActiveTab() {
        let a = StubTab(id: UUID(), connected: false)
        let vm = TabsViewModel(initial: a)
        let target = vm.sidebarConnectTarget(activeTabIsConnected: false) {
            StubTab(id: UUID())
        }
        #expect(target.id == a.id)
        #expect(vm.tabs.count == 1)
    }

    @Test func sidebarConnectTargetOpensNewTabWhenActiveConnected() {
        let a = StubTab(id: UUID(), connected: true)
        let vm = TabsViewModel(initial: a)
        let fresh = StubTab(id: UUID())
        let target = vm.sidebarConnectTarget(activeTabIsConnected: true) { fresh }
        #expect(target.id == fresh.id)
        #expect(vm.tabs.map(\.id) == [a.id, fresh.id])
        #expect(vm.activeTabID == fresh.id)
    }
}
```

- [x] **Step 2: Prove red**

Run: `swift test --filter TabsViewModelTests`
Expected: FAIL (type does not exist).

- [x] **Step 3: Implementation** — `Sources/macSCPCore/Presentation/TabsViewModel.swift`:

```swift
import Foundation
import Observation

/// Window-scoped tab collection rules (M8a). Pure state machine — no UI,
/// no SSH: the app layer instantiates it with its session payload and
/// renders `tabs`/`activeTabID`. Payload-generic so the rules stay unit
/// testable (the app target has no test target).
@MainActor
@Observable
public final class TabsViewModel<Tab: Identifiable> where Tab.ID == UUID {
    public private(set) var tabs: [Tab]
    public private(set) var activeTabID: UUID

    public init(initial: Tab) {
        self.tabs = [initial]
        self.activeTabID = initial.id
    }

    /// The active tab. `activeTabID` is maintained to always reference an
    /// existing element, so lookup failure is a programmer error.
    public var activeTab: Tab {
        guard let tab = tabs.first(where: { $0.id == activeTabID }) else {
            fatalError("activeTabID does not reference an existing tab")
        }
        return tab
    }

    public var isLastTab: Bool { tabs.count == 1 }

    /// Appends and activates (⊕ / Cmd-N / sidebar-into-new-tab).
    public func addTab(_ tab: Tab) {
        tabs.append(tab)
        activeTabID = tab.id
    }

    /// No-op for unknown ids (defensive: a stale click on a closing tab).
    public func activate(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    /// Removes the tab. The LAST tab is not removable (the app interprets
    /// closing the last unconnected tab as closing the window). Closing the
    /// active tab activates the right neighbor, or the left one at the
    /// rightmost position (browser convention).
    @discardableResult
    public func closeTab(_ id: UUID) -> Bool {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else {
            return false
        }
        tabs.remove(at: index)
        if activeTabID == id {
            let successor = min(index, tabs.count - 1)
            activeTabID = tabs[successor].id
        }
        return true
    }

    /// Sidebar-connect rule (spec 1.2): an unconnected active tab is reused
    /// in place; a connected one spawns a fresh tab so the running session
    /// is never torn down by a sidebar click.
    public func sidebarConnectTarget(
        activeTabIsConnected: Bool, makeTab: () -> Tab
    ) -> Tab {
        guard activeTabIsConnected else { return activeTab }
        let fresh = makeTab()
        addTab(fresh)
        return fresh
    }
}
```

- [x] **Step 4: Prove green**

Run: `swift test --filter TabsViewModelTests` → PASS, then the full suite `swift test` → 370/370 (361 + 9 new).

- [x] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Presentation/TabsViewModel.swift Tests/macSCPCoreTests/TabsViewModelTests.swift
git commit -m "feat: add the window-scoped tabs state machine"
```

---

### Task 2: BandwidthLimiter (app-global) + Queue Activity Accessors

**Files:**
- Create: `Sources/macSCPCore/RemoteFS/BandwidthLimiter.swift`
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (limit properties/buckets out, `limiter` injection + activity accessors in; lines ~130–175 and the throttle resolution ~697)
- Modify: `Sources/MacSCPApp/ContentView.swift` (only the spots that set `uploadLimitBytesPerSec`/`downloadLimitBytesPerSec` on the queue — for compilability; the real app wiring is done by T3)
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (create the limiter + pass it to ContentView)
- Test: `Tests/macSCPCoreTests/BandwidthLimiterTests.swift` (new), `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift` (migrate the throttle block ~1940)

**Interfaces:**
- Consumes: `BandwidthBucket` (M6a, `Sources/macSCPCore/RemoteFS/BandwidthBucket.swift`) with `setRate(bytesPerSecond:generation:)`.
- Produces:
  - `@MainActor @Observable public final class BandwidthLimiter` with `public init()`, `public var uploadLimitBytesPerSec: Int` / `downloadLimitBytesPerSec: Int` (didSet re-rates/swaps as in the queue today), `public private(set) var uploadBucket: BandwidthBucket?` / `downloadBucket: BandwidthBucket?`.
  - `TransferQueueViewModel.limiter: BandwidthLimiter?` (public var, default nil = unthrottled; job start reads `limiter?.uploadBucket` or `downloadBucket`).
  - `TransferQueueViewModel.lastStartedDirection: TransferDirection?` (public private(set); set on every job start) and `TransferQueueViewModel.failedCount: Int` (public computed: number of items with status .failed) — the basis for the tab indicators (T4).

- [x] **Step 1: Failing Tests** — `Tests/macSCPCoreTests/BandwidthLimiterTests.swift`:

```swift
import Testing
@testable import macSCPCore

@Suite("BandwidthLimiter")
@MainActor
struct BandwidthLimiterTests {
    @Test func zeroMeansNoBucket() {
        let limiter = BandwidthLimiter()
        #expect(limiter.uploadBucket == nil)
        #expect(limiter.downloadBucket == nil)
    }

    @Test func settingLimitCreatesBucketAndKeepsInstanceOnRerate() {
        let limiter = BandwidthLimiter()
        limiter.uploadLimitBytesPerSec = 1024
        let first = limiter.uploadBucket
        #expect(first != nil)
        limiter.uploadLimitBytesPerSec = 4096 // re-rate: same instance
        #expect(limiter.uploadBucket === first)
        limiter.uploadLimitBytesPerSec = 0 // disable: reference dropped
        #expect(limiter.uploadBucket == nil)
        #expect(limiter.downloadBucket == nil) // directions independent
    }

    @Test func twoQueuesShareTheLimiterBuckets() {
        let limiter = BandwidthLimiter()
        limiter.downloadLimitBytesPerSec = 2048
        let queueA = TransferQueueViewModel()
        let queueB = TransferQueueViewModel()
        queueA.limiter = limiter
        queueB.limiter = limiter
        // Both queues resolve the SAME bucket instance — the aggregate-rate
        // math on a shared bucket is proven in BandwidthBucketTests (M6a);
        // identity is the queue-level contract.
        #expect(queueA.limiter?.downloadBucket === queueB.limiter?.downloadBucket)
        #expect(queueA.limiter?.downloadBucket != nil)
    }
}
```

Additionally, in the existing `TransferQueueViewModelTests.swift`: migrate the block starting at ~line 1940 (sets `queue.uploadLimitBytesPerSec` etc.) onto the limiter — same assertions (bucket identity on re-rate, reference swap on 0↔n), just via `queue.limiter = BandwidthLimiter()` + limits on the limiter. Do NOT weaken any assertion.

- [x] **Step 2: Prove red**

Run: `swift test --filter BandwidthLimiterTests` → FAIL (type missing).

- [x] **Step 3: Implement `BandwidthLimiter`** — the code is the LITERALLY moved machinery from the queue (lines ~137–175):

```swift
import Foundation
import Observation

/// App-global bandwidth ceilings (M8a): ONE shared token bucket per
/// direction for the whole app — every tab's queue resolves its throttle
/// from here, so a 300 KB/s limit is 300 in aggregate across all tabs.
/// Semantics are identical to the per-queue wiring it replaces (M6a/M6b):
/// re-rating a non-zero limit keeps the live instance (running transfers
/// follow), toggling 0 <-> n swaps the reference (applies to transfers
/// starting afterwards).
@MainActor
@Observable
public final class BandwidthLimiter {
    public init() {}

    public var uploadLimitBytesPerSec: Int = 0 {
        didSet {
            uploadRateGeneration += 1
            uploadBucket = Self.updatedBucket(
                uploadBucket, bytesPerSecond: uploadLimitBytesPerSec,
                generation: uploadRateGeneration)
        }
    }
    public var downloadLimitBytesPerSec: Int = 0 {
        didSet {
            downloadRateGeneration += 1
            downloadBucket = Self.updatedBucket(
                downloadBucket, bytesPerSecond: downloadLimitBytesPerSec,
                generation: downloadRateGeneration)
        }
    }
    private var uploadRateGeneration = 0
    private var downloadRateGeneration = 0

    public private(set) var uploadBucket: BandwidthBucket?
    public private(set) var downloadBucket: BandwidthBucket?

    private static func updatedBucket(
        _ bucket: BandwidthBucket?, bytesPerSecond: Int, generation: Int
    ) -> BandwidthBucket? {
        guard bytesPerSecond > 0 else { return nil }
        guard let bucket else { return BandwidthBucket(bytesPerSecond: bytesPerSecond) }
        // Keep the instance (running transfers hold it) and re-rate it. The
        // hop is fire-and-forget by design: pacing catches up on the next
        // consume; the generation makes unordered hops last-write-wins.
        Task { await bucket.setRate(bytesPerSecond: bytesPerSecond, generation: generation) }
        return bucket
    }
}
```

- [x] **Step 4: Convert the queue** — in `TransferQueueViewModel`:
  1. Remove the properties `uploadLimitBytesPerSec`, `downloadLimitBytesPerSec`, `uploadRateGeneration`, `downloadRateGeneration`, `uploadBucket`, `downloadBucket` and `static updatedBucket` WITHOUT REPLACEMENT; instead:

```swift
    /// App-global limiter injected by the app layer (M8a). nil = unthrottled
    /// (tests, CLI). All queues of a window share one instance, so limits
    /// apply in aggregate across tabs.
    public var limiter: BandwidthLimiter?
```

  2. Change the throttle resolution at job start (today ~line 697) to:

```swift
        let throttle = job.direction == .upload
            ? limiter?.uploadBucket : limiter?.downloadBucket
```

  3. Right next to it (at the spot where the job is set to `.running`) set the indicator anchor and add the accessors:

```swift
        lastStartedDirection = job.direction
```

```swift
    /// Direction of the most recently STARTED job — drives the tab activity
    /// indicator's color (M8a; spec 2: on simultaneous both-direction
    /// activity the last started one wins).
    public private(set) var lastStartedDirection: TransferDirection?

    /// Number of items currently in the failed state — the tab attention
    /// indicator compares this against a per-tab seen-counter (M8a).
    public var failedCount: Int {
        items.filter { if case .failed = $0.status { return true } else { return false } }.count
    }
```

  (Adjust the exact status enum case syntax to `TransferItem.Status` in the file; assertions of the new tests unchanged.)

- [x] **Step 5: Keep the app compilable** — `MacSCPApp.swift`: `@State private var bandwidthLimiter = BandwidthLimiter()` next to the SettingsStore, pass it through as `ContentView(settingsStore: settingsStore, bandwidthLimiter: bandwidthLimiter)`. `ContentView`: add the parameter `let bandwidthLimiter: BandwidthLimiter`; switch the three settings `.onChange` observers and the `startSession` wiring of `transferQueue.uploadLimitBytesPerSec…` over to `bandwidthLimiter.uploadLimitBytesPerSec…`; additionally, once, `transferQueue.limiter = bandwidthLimiter` in `startSession` (T3 moves this into tab creation). `maxConcurrent` stays on the queue.

- [x] **Step 6: Prove green**

Run: `swift build` (0 errors) and `swift test` → all suites green (370 + 3 new = 373; check the number against the migrated block and record it in the report).

- [x] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: hoist bandwidth buckets into an app-global limiter"
```

---

### Task 3: SessionTab + ContentView Rework onto Tabs (RISK)

**Files:**
- Create: `Sources/MacSCPApp/SessionTab.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift` (core rework; move the `BrowserSession` struct there)
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (only if signatures change)

**Interfaces:**
- Consumes: `TabsViewModel` (T1), `BandwidthLimiter` (T2), the existing `BrowserSession`, `ConnectionViewModel`, `TransferQueueViewModel`, `ConflictPromptBridge`, `SessionSidebar`, `teardownSession` logic.
- Produces (T4 relies on this):
  - `@MainActor @Observable final class SessionTab: Identifiable` with: `let id: UUID`; `let connectionViewModel: ConnectionViewModel`; `var session: BrowserSession?`; `let transferQueue: TransferQueueViewModel`; `let conflictBridge: ConflictPromptBridge`; `var titleName: String?`; `var editErrorMessage: String?`; `var activeStoredSessionID: UUID?`; `var isReconnecting: Bool`; `var seenFailureCount: Int` (attention indicator anchor); computed `var isConnected: Bool { session != nil }` and `var displayTitle: String` (titleName ?? localized "New Connection").
  - `ContentView` functions: `makeTab() -> SessionTab` (fresh form tab including `transferQueue.limiter = bandwidthLimiter` and decider wiring onto the tab's own bridge), `connect(in tab: SessionTab, stored: StoredSession)` (without tearing down other tabs!), `closeTab(_ tab: SessionTab) async` (teardown + `tabsModel.closeTab`), `teardown(_ tab: SessionTab) async` (tab-local, today's order).
  - `tabsModel: TabsViewModel<SessionTab>` as `@State` in `ContentView`.

**Behavior requirements (from spec §1, §3):**
1. `session/transferQueue/conflictBridge/sessionTitleName/editErrorMessage/activeSessionID/isReconnecting/connectionViewModel` move COMPLETELY into `SessionTab`; `ContentView` keeps window-wide only: `tabsModel`, `window`, `lastBrowserSize`, `importedHosts`, `sessionListViewModel`, `settingsStore`, `bandwidthLimiter`.
2. `detail`/toolbar/sheets/banner render the ACTIVE tab (`tabsModel.activeTab`); only this one is mounted. All previous `session.` accesses become `activeTab.session.` accesses; the conflict sheet binds to `activeTab.conflictBridge`, the queue bar to `activeTab.transferQueue`, the resume banner to `activeTab.transferQueue` + `activeTab.session`.
3. `startSession(with:storedName:)` becomes `startSession(in tab: SessionTab, with fs:, storedName:)` — writes into the tab instead of window state; decider/limiter wiring happens in `makeTab()` exactly once per tab (NO LONGER per connect).
4. Sidebar handlers:
   - `onSelect`: `let target = tabsModel.sidebarConnectTarget(activeTabIsConnected: tabsModel.activeTab.isConnected, makeTab: makeTab)`, then `connect(in: target, stored:)`. `connect(in:)` = today's `connectStored` WITHOUT the `teardownSession()` prelude, when the target tab is unconnected (per the rule it always is; defensively: if it is connected after all, `teardown(target)` first), guarded on `target.isReconnecting`.
   - `onEdit`: active tab unconnected → `beginEditing` on its ConnectionViewModel; otherwise a new tab via `makeTab()` + `addTab` + `beginEditing` there.
   - `onNew`: active tab unconnected → blank the form (today's `newConnection` without teardown); otherwise a new empty tab.
   - `onDelete`: as today, just null out `activeStoredSessionID` in ALL tabs whose value matches.
   - remove `sidebarDisabled` without replacement; instead `interactionsDisabled: tabsModel.activeTab.isReconnecting || tabsModel.activeTab.connectionViewModel.state == .connecting`.
   - Highlight: `activeSessionID: tabsModel.activeTab.activeStoredSessionID`.
5. Toolbar "Disconnect" → `disconnectToForm(tabsModel.activeTab)`: teardown of the tab, `tab.session = nil`, queue/interrupted STAY (only `cancelAll` of the running ones as today — note: keep today's semantics: `teardownSession` cancels active ones; interrupted ones already survive `cancelAll` today, do nothing extra).
6. Window size: helper `private var isPristine: Bool { tabsModel.isLastTab && !tabsModel.activeTab.isConnected }`. `resizeWindow` calls: grow on first connect as today; shrink ONLY if `isPristine` holds after the action. Switch `.frame(minWidth:)` conditions from `session == nil` to `isPristine`.
7. The `showHiddenFiles` observer iterates over ALL tabs with a session (set filter + refresh). The limit observers from T2 stay on the `bandwidthLimiter`; the `maxConcurrentTransfers` observer iterates over all tab queues.
8. Window title: `.navigationTitle` from `tabsModel.activeTab.titleName`.
9. The menu handler (`onMenuAction`) and `transferSelection`/`copyPaths`/`uploadDropped`/`openInEditor`/`remotePromiseProvider` take the tab (or its session/queue) as a parameter instead of the global `session` — mechanical adjustment, behavior identical.

- [x] **Step 1: Create `SessionTab.swift`** (including the `BrowserSession` struct moved here, unchanged):

```swift
import Foundation
import Observation
import macSCPCore

/// One window tab (M8a): bundles what used to be window-wide state, per
/// tab. Reference type — background tabs stay alive in `TabsViewModel`
/// while only the active tab is mounted.
@MainActor
@Observable
final class SessionTab: Identifiable {
    let id = UUID()
    let connectionViewModel: ConnectionViewModel
    var session: BrowserSession?
    let transferQueue = TransferQueueViewModel()
    let conflictBridge = ConflictPromptBridge()
    var titleName: String?
    var editErrorMessage: String?
    var activeStoredSessionID: UUID?
    var isReconnecting = false
    /// Failure count last seen while this tab was active — the attention
    /// indicator (T4) lights up when `transferQueue.failedCount` exceeds it.
    var seenFailureCount = 0

    var isConnected: Bool { session != nil }

    var displayTitle: String {
        titleName ?? L10n.string("tabs.newConnection", "New Connection")
    }

    /// Wires the tab-owned queue on construction: shared limiter, initial
    /// concurrency, and the conflict decider onto the tab's OWN bridge —
    /// exactly once per tab (no re-wiring per connect).
    init(
        connectionViewModel: ConnectionViewModel,
        limiter: BandwidthLimiter,
        maxConcurrent: Int
    ) {
        self.connectionViewModel = connectionViewModel
        transferQueue.limiter = limiter
        transferQueue.maxConcurrent = maxConcurrent
        let bridge = conflictBridge
        transferQueue.conflictDecider = { conflict in await bridge.ask(conflict) }
    }
}
```

(The `ConflictPromptBridge` and `ConnectionViewModel` types exist; move `ConflictPromptBridge` from `ContentView.swift` here if visibility requires it. Add catalog keys `tabs.newConnection` EN "New Connection" / DE „Neue Verbindung".)

- [x] **Step 2: Rework `ContentView`** per behavior requirements 1–9. `makeTab()` as a static factory, so it is also available to `ContentView`'s init:

```swift
    private static func makeTab(
        settingsStore: SettingsStore, limiter: BandwidthLimiter
    ) -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { config, onUnknownHostKey in
                try await CitadelFileSystem.connect(
                    config: config,
                    knownHosts: KnownHostsStore(directory: SessionStore.defaultDirectory),
                    onUnknownHostKey: onUnknownHostKey
                )
            }),
            limiter: limiter,
            maxConcurrent: settingsStore.maxConcurrentTransfers
        )
    }
```

`@State private var tabsModel: TabsViewModel<SessionTab>` — initialization in `ContentView`'s `init`:

```swift
    init(settingsStore: SettingsStore, bandwidthLimiter: BandwidthLimiter) {
        self.settingsStore = settingsStore
        self.bandwidthLimiter = bandwidthLimiter
        _tabsModel = State(initialValue: TabsViewModel(
            initial: Self.makeTab(settingsStore: settingsStore, limiter: bandwidthLimiter)))
    }
```

- [x] **Step 3: Build + full suite**

Run: `swift build` (0 errors, no new warnings) and `swift test` → the state from T2 stays green unchanged.

- [x] **Step 4: Behavior self-check** (report): one sentence with code evidence per requirement 1–9; explicitly confirm that (a) no code path calls `teardownSession` globally anymore, (b) a sidebar click on a connected active tab triggers NO teardown, (c) the conflict sheet is bound to the tab's own bridge.

- [x] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: move the window session state into per-tab objects"
```

---

### Task 4: Tab Strip UI, Indicators, Closing, Shortcuts, Window

**Files:**
- Create: `Sources/MacSCPApp/TabStripView.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift` (hook in the strip, close-confirm, final window-size rule), `Sources/MacSCPApp/MacSCPApp.swift` (commands), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj` (new keys)
- Test: none (app target; visual smoke test in T5)

**Interfaces:**
- Consumes: `tabsModel`, `SessionTab` (T3), `TransferQueueViewModel.lastStartedDirection`/`failedCount`/`isActive` (T2), design tokens (`DesignTokens.paper/card/hairline/ink/inkSecondary/inkTertiary/remoteBlue/localAmber` — look up the exact token names in `DesignTokens.swift`).
- Produces: `TabStripView(tabs:activeTabID:onActivate:onClose:onAdd:)`.

**Dimensions (spec §2 / mockup, binding):** strip 30 pt, `paper` surface, hairline at the bottom; active tab `card` surface + 2-pt `remoteBlue` underline + title 12 pt semibold `ink`; inactive `inkSecondary` + hairline divider on the right; tab min 120 / max 200 pt, ellipsis; ✕ 15-pt hit area only on tab hover; ⊕ 30 pt on the right; form tab italic `inkTertiary`; indicator 7-pt dot on the left: attention red static (priority) > amber (upload) / blue (download) with a subtle pulse (`opacity` animation, respect `reduceMotion`) > no dot. a11y: `accessibilityValue` per state. Strip invisible in the pristine state (`isPristine`).

- [x] **Step 1: `TabStripView.swift`**:

```swift
import SwiftUI
import macSCPCore

/// The window tab strip (M8a) — between toolbar and pane heads. Pure
/// rendering: all rules live in `TabsViewModel`/`SessionTab`.
struct TabStripView: View {
    let tabs: [SessionTab]
    let activeTabID: UUID
    let onActivate: (UUID) -> Void
    let onClose: (SessionTab) -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        TabItemView(
                            tab: tab,
                            isActive: tab.id == activeTabID,
                            onActivate: { onActivate(tab.id) },
                            onClose: { onClose(tab) })
                    }
                }
            }
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.inkTertiary)
            .help(L10n.string("tabs.newTabHelp", "New tab (⌘N)"))
            Spacer(minLength: 0)
        }
        .frame(height: 30)
        .background(DesignTokens.paperColor)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DesignTokens.hairline).frame(height: 1)
        }
    }
}

private struct TabItemView: View {
    let tab: SessionTab
    let isActive: Bool
    let onActivate: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private enum Indicator { case none, upload, download, attention }

    /// Attention (static red) wins over activity; activity color follows
    /// the LAST STARTED item's direction (spec 2).
    private var indicator: Indicator {
        if tab.conflictBridge.currentPrompt != nil
            || tab.transferQueue.failedCount > tab.seenFailureCount {
            return .attention
        }
        guard tab.transferQueue.isActive else { return .none }
        return tab.transferQueue.lastStartedDirection == .upload ? .upload : .download
    }

    var body: some View {
        HStack(spacing: 7) {
            switch indicator {
            case .none: EmptyView()
            case .upload: dot(DesignTokens.localAmber, pulse: true)
            case .download: dot(DesignTokens.remoteBlue, pulse: true)
            case .attention: dot(.red, pulse: false)
            }
            Text(tab.displayTitle)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .italic(!tab.isConnected)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(
                    isActive ? DesignTokens.ink
                    : tab.isConnected ? DesignTokens.inkSecondary : DesignTokens.inkTertiary)
            if isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 15, height: 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.inkTertiary)
            } else {
                Color.clear.frame(width: 15, height: 15)
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 120, maxWidth: 200, maxHeight: .infinity)
        .background(isActive ? DesignTokens.cardColor : .clear)
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle().fill(DesignTokens.remoteBlue).frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) {
            if !isActive { Rectangle().fill(DesignTokens.hairline).frame(width: 1) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityState)
    }

    private var accessibilityState: String {
        switch indicator {
        case .none: return ""
        case .upload: return L10n.string("tabs.a11y.uploading", "uploading")
        case .download: return L10n.string("tabs.a11y.downloading", "downloading")
        case .attention: return L10n.string("tabs.a11y.attention", "needs attention")
        }
    }

    @ViewBuilder
    private func dot(_ color: Color, pulse: Bool) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(pulse && pulsing && !reduceMotion ? 0.35 : 1.0)
            .animation(
                pulse && !reduceMotion
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : nil,
                value: pulsing)
            .onAppear { pulsing = pulse }
    }
}
```

(Adjust the token names `paperColor/cardColor/localAmber` to the real identifiers in `DesignTokens.swift` — `paper` was removed in M6a, the strip surface may need to be the window background instead; record in the report which token was used. Do NOT adjust the dimensions.)

- [x] **Step 2: Hook in + close confirm** in `ContentView`: strip above the detail content, `if !isPristine`. `onClose` flow:

```swift
    @State private var closeRequest: SessionTab?

    private func requestClose(_ tab: SessionTab) {
        if tab.transferQueue.isActive {
            closeRequest = tab // destructive confirm alert
        } else {
            Task { await performClose(tab) }
        }
    }

    private func performClose(_ tab: SessionTab) async {
        if tabsModel.isLastTab {
            await teardown(tab)
            tab.session = nil
            tab.titleName = nil
            // Last tab: never removed — it reverts to a pristine form tab
            // (Cmd-W on it closes the window via the system path instead).
            resizeWindow(toWidth: 700, height: 460)
        } else {
            await teardown(tab)
            tabsModel.closeTab(tab.id)
        }
    }
```

Alert (destructive, bound to `closeRequest`): title key `tabs.close.title` "Close tab?"/„Tab schließen?", text `tabs.close.activeTransfers` "Active transfers in this tab will be canceled."/„Laufende Übertragungen in diesem Tab werden abgebrochen.", buttons `common.cancel` + `tabs.close.confirm` "Close"/„Schließen" (role .destructive). On tab ACTIVATION (`onActivate` and after `closeTab`): `tab.seenFailureCount = tab.transferQueue.failedCount` for the newly active tab (attention reset on visit).

- [x] **Step 3: Commands** in `MacSCPApp.swift` — `CommandGroup(replacing: .newItem)`: "New Tab" ⌘N (calls via `FocusedValue` or — simpler, since this is a single-window app — via an `@Observable` command bridge `TabCommands` passed to and set in `ContentView`, with closures `newTab/closeTab/selectTab(Int)`; document the implementation path in the report) and "Close Tab" ⌘W (last unconnected tab → `window.performClose(nil)`). ⌘1–⌘9 as "Tab n" items (Window menu, `CommandGroup(after: .windowList)`), target = index n-1, no-op if out of range. ⌃Tab only if it works as a menu shortcut (`KeyEquivalent("\t")`, `.control`) — otherwise leave it out and note it in the report. Keys `menu.newTab` "New Tab"/„Neuer Tab", `menu.closeTab` "Close Tab"/„Tab schließen", `menu.selectTab` "Tab %lld"/„Tab %lld".

- [x] **Step 4: Build + full suite + catalog check**

Run: `swift build` && `swift test` (state from T3 green). Catalog cross-check: every new `L10n.string` key exists in BOTH `.strings` files.

- [x] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add the tab strip with activity indicators and tab commands"
```

---

### Task 5: Completion Verification (Coordinator)

- [x] Gated suites (rig from the main checkout, `docker compose -f docker/test-server/compose.yml start`): `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` ⇒ completely green, zero skips (373 before / 376 after the final-review fixes).
- [ ] Visual smoke test — **delegated to the maintainer** (wrapper is running; checklist in the milestone summary, including ⌘W with settings focus and bandwidth sum across two tabs):
  - Start = today's image (no strip, compact form window).
  - Connect → window grows; ⊕ → form tab in the large window, strip visible; connect a second session (rig user) → two tabs.
  - Sidebar click on a connected active tab → NEW tab, the first session keeps running (terminal ping in the background tab stays alive after switching back, replay shows the output).
  - Throttled transfer in tab A, switch to tab B: amber/blue dot on tab A pulses; the transfer keeps running in the background (queue bar on switching back).
  - App-global bandwidth: limit 300, one download each in TWO tabs simultaneously → sum ≈ limit (shown in both queue bars).
  - Provoke a conflict in a background tab → red dot, NO sheet in the active tab; switch → sheet appears; attention reset after visiting.
  - Close a tab without transfers → gone, right neighbor active; with transfers → destructive confirmation; last tab → becomes a form tab, window shrinks.
  - ⌘N/⌘W/⌘1–⌘9; ⌘T still terminal; window title follows the active tab; "Disconnect" makes it a form tab, interrupted items + resume banner survive in the tab.
  - Regressions: double-click editor, drag & drop in both directions, context menu (M7b), rename/permissions/delete, hidden files ⌘⇧. affects both tabs.
- [x] Plan checkboxes, ledger, Opus whole-branch final review (base = commit before T1; "No" → fix commit 17b3829 → re-review "Ready to merge: Yes"), fixes, push develop, CI, rig `stop`, memory update, milestone summary (+ transition to M8b).
