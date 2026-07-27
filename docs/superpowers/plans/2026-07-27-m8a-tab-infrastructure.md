# M8a — Tab-Infrastruktur Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein Fenster hält mehrere gleichzeitig aktive SSH-Sessions als Tabs — Tab-Strip, Pro-Tab-State, app-globale Bandbreiten-Buckets; Hintergrund-Tabs laufen vollständig weiter.

**Architecture:** Die Tab-Verwaltungsregeln liegen als generisches, UI-freies `TabsViewModel` in Core (testbar). Die App bündelt den bisher fensterweiten Zustand in `SessionTab`-Objekte (je Tab: ConnectionViewModel, BrowserSession?, TransferQueueViewModel, ConflictPromptBridge) und rendert nur den aktiven Tab. Die Richtungs-Buckets wandern aus der Queue in einen app-weit injizierten `BandwidthLimiter`.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing (`@Test`/`#expect`), SwiftUI + AppKit, `@Observable`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-27-m8-tabs-design.md` — bindend. Branch: **develop**. Mockup: `docs/design/assets/m8-tabs-mockup.html`.
- Architektur-Invariante (präzisiert): eine SSH-Verbindung pro **Tab**; die Tab-Kollektion gehört dem Fenster. KEIN neues App-Singleton außer `SettingsStore` (existiert) und dem neuen `BandwidthLimiter` (beide in `MacSCPApp` erzeugt, per Parameter durchgereicht).
- Teardown-Reihenfolge pro Tab unverändert: `conflictBridge.dismiss()` → `queue.cancelAll()` → `editManager.stopAll()` → `terminal.shutdown()` → `remote.disconnect()`; kein `deinit`-Cleanup.
- Queue-Invarianten unverändert: FIFO-Startreihenfolge, exactly-once Waiter, `cancelAll` hinterlässt keine Waisen.
- Bandbreite: Limit gilt app-global über alle Tabs (EIN Bucket pro Richtung app-weit); Live-Re-Rate mit Generation-Counter (M6b) bleibt; 0 = aus; 0↔n swappt die Referenz (wirkt nur auf danach startende Transfers) — Semantik exakt wie heute, nur eine Ebene höher.
- `maxConcurrentTransfers` bleibt bewusst PRO Tab-Queue (Pro-Verbindung-Limit); `showHiddenFiles` wirkt auf ALLE Tabs.
- Nur der aktive Tab ist gemountet; Terminal-Remount über den vorhandenen 256-KiB-Replay-Puffer; Konflikt-Sheets erscheinen nur im eigenen (aktiven) Tab.
- Jungfräulicher Zustand (genau ein unverbundener Formular-Tab): Strip unsichtbar, Fenster kompakt 700×460 — Startbild identisch zu heute. Ab zweitem Tab ODER verbundenem Einzel-Tab: Browser-Größe (≥930×620), kein Shrink bei Tab-Wechsel.
- Shortcuts: ⌘T Terminal (bleibt), ⌘N neuer Tab, ⌘W schließt aktiven Tab (letzter unverbundener Tab → Fenster), ⌘1–⌘9 Direktwahl. (⌃Tab-Zyklus: nur wenn als Menü-Shortcut machbar — sonst dokumentiert weglassen, kein Event-Monitor.)
- Alle neuen UI-Texte katalogisiert EN/DE (`Sources/MacSCPApp/Resources/*/Localizable.strings`); Code + Kommentare NUR Englisch.
- Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + volle `swift test` nach jedem Task grün (Ausgangslage 361 Tests / 30 Suiten); gated Suiten nur in T5.
- TDD für Core (TabsViewModel, BandwidthLimiter, Queue-Accessoren); App-Target ist untestbar — App-Tasks liefern Build + Verhaltensbeschreibung, der visuelle Smoke ist T5.
- Tests SYNCHRON im Vordergrund laufen lassen (kein run_in_background).

## Schedule

T1 (TabsViewModel, Core) → T2 (BandwidthLimiter + Queue-Accessoren, Core) → T3 (SessionTab + ContentView-Umbau, App, RISK) → T4 (Tab-Strip-UI + Shortcuts + Fenster, App) → T5 Abschluss (Koordinator).

---

### Task 1: TabsViewModel (Core)

**Files:**
- Create: `Sources/macSCPCore/Presentation/TabsViewModel.swift`
- Test: `Tests/macSCPCoreTests/TabsViewModelTests.swift` (neu)

**Interfaces:**
- Produces (T3/T4 verlassen sich exakt hierauf):
  - `@MainActor @Observable public final class TabsViewModel<Tab: Identifiable> where Tab.ID == UUID`
  - `public private(set) var tabs: [Tab]`, `public private(set) var activeTabID: UUID`
  - `public init(initial: Tab)`
  - `public var activeTab: Tab { get }`
  - `public var isLastTab: Bool { get }` (tabs.count == 1)
  - `public func addTab(_ tab: Tab)` (ans Ende, wird aktiv)
  - `public func activate(_ id: UUID)` (No-op bei unbekannter ID)
  - `@discardableResult public func closeTab(_ id: UUID) -> Bool` (false bei letztem Tab oder unbekannter ID; war der geschlossene aktiv, wird der RECHTE Nachbar aktiv, sonst der linke)
  - `public func sidebarConnectTarget(activeTabIsConnected: Bool, makeTab: () -> Tab) -> Tab` (unverbunden → aktueller aktiver Tab; verbunden → `makeTab()` wird per `addTab` angehängt und zurückgegeben)

- [ ] **Step 1: Failing Tests** — `Tests/macSCPCoreTests/TabsViewModelTests.swift`:

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

- [ ] **Step 2: Rot beweisen**

Run: `swift test --filter TabsViewModelTests`
Expected: FAIL (Typ existiert nicht).

- [ ] **Step 3: Implementierung** — `Sources/macSCPCore/Presentation/TabsViewModel.swift`:

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

- [ ] **Step 4: Grün beweisen**

Run: `swift test --filter TabsViewModelTests` → PASS, dann volle Suite `swift test` → 370/370 (361 + 9 neue).

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Presentation/TabsViewModel.swift Tests/macSCPCoreTests/TabsViewModelTests.swift
git commit -m "feat: add the window-scoped tabs state machine"
```

---

### Task 2: BandwidthLimiter (app-global) + Queue-Aktivitäts-Accessoren

**Files:**
- Create: `Sources/macSCPCore/RemoteFS/BandwidthLimiter.swift`
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (Limit-Properties/Buckets raus, `limiter`-Injektion + Aktivitäts-Accessoren rein; Zeilen ~130–175 und die Throttle-Auflösung ~697)
- Modify: `Sources/MacSCPApp/ContentView.swift` (nur die Stellen, die `uploadLimitBytesPerSec`/`downloadLimitBytesPerSec` auf der Queue setzen — Kompilierfähigkeit; die echte App-Verkabelung macht T3)
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (Limiter erzeugen + an ContentView reichen)
- Test: `Tests/macSCPCoreTests/BandwidthLimiterTests.swift` (neu), `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift` (Throttle-Block ~1940 migrieren)

**Interfaces:**
- Consumes: `BandwidthBucket` (M6a, `Sources/macSCPCore/RemoteFS/BandwidthBucket.swift`) mit `setRate(bytesPerSecond:generation:)`.
- Produces:
  - `@MainActor @Observable public final class BandwidthLimiter` mit `public init()`, `public var uploadLimitBytesPerSec: Int` / `downloadLimitBytesPerSec: Int` (didSet re-rated/swappt wie heute in der Queue), `public private(set) var uploadBucket: BandwidthBucket?` / `downloadBucket: BandwidthBucket?`.
  - `TransferQueueViewModel.limiter: BandwidthLimiter?` (public var, default nil = ungedrosselt; Job-Start liest `limiter?.uploadBucket` bzw. `downloadBucket`).
  - `TransferQueueViewModel.lastStartedDirection: TransferDirection?` (public private(set); gesetzt bei jedem Job-Start) und `TransferQueueViewModel.failedCount: Int` (public computed: Anzahl Items mit Status .failed) — Grundlage der Tab-Indikatoren (T4).

- [ ] **Step 1: Failing Tests** — `Tests/macSCPCoreTests/BandwidthLimiterTests.swift`:

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

Zusätzlich im bestehenden `TransferQueueViewModelTests.swift`: den Block ab ~Zeile 1940 (setzt `queue.uploadLimitBytesPerSec` etc.) auf den Limiter migrieren — gleiche Assertions (Bucket-Identität bei Re-Rate, Referenz-Swap bei 0↔n), nur über `queue.limiter = BandwidthLimiter()` + Limits auf dem Limiter. KEINE Assertion abschwächen.

- [ ] **Step 2: Rot beweisen**

Run: `swift test --filter BandwidthLimiterTests` → FAIL (Typ fehlt).

- [ ] **Step 3: `BandwidthLimiter` implementieren** — Code ist die WÖRTLICH verschobene Maschinerie aus der Queue (Zeilen ~137–175):

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

- [ ] **Step 4: Queue umstellen** — in `TransferQueueViewModel`:
  1. Die Properties `uploadLimitBytesPerSec`, `downloadLimitBytesPerSec`, `uploadRateGeneration`, `downloadRateGeneration`, `uploadBucket`, `downloadBucket` und `static updatedBucket` ERSATZLOS entfernen; stattdessen:

```swift
    /// App-global limiter injected by the app layer (M8a). nil = unthrottled
    /// (tests, CLI). All queues of a window share one instance, so limits
    /// apply in aggregate across tabs.
    public var limiter: BandwidthLimiter?
```

  2. Throttle-Auflösung beim Job-Start (heute ~Zeile 697) ändern zu:

```swift
        let throttle = job.direction == .upload
            ? limiter?.uploadBucket : limiter?.downloadBucket
```

  3. Direkt daneben (an der Stelle, an der der Job auf `.running` gesetzt wird) den Indikator-Anker setzen und die Accessoren ergänzen:

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

  (Die exakte Status-Enum-Case-Syntax an `TransferItem.Status` in der Datei anpassen; Assertions der neuen Tests unverändert.)

- [ ] **Step 5: App kompilierfähig halten** — `MacSCPApp.swift`: `@State private var bandwidthLimiter = BandwidthLimiter()` neben dem SettingsStore, Weitergabe `ContentView(settingsStore: settingsStore, bandwidthLimiter: bandwidthLimiter)`. `ContentView`: Parameter `let bandwidthLimiter: BandwidthLimiter` ergänzen; die drei Settings-`.onChange`-Observer und die `startSession`-Verkabelung von `transferQueue.uploadLimitBytesPerSec…` umstellen auf `bandwidthLimiter.uploadLimitBytesPerSec…`; zusätzlich einmalig `transferQueue.limiter = bandwidthLimiter` in `startSession` (T3 zieht das in die Tab-Erzeugung um). `maxConcurrent` bleibt auf der Queue.

- [ ] **Step 6: Grün beweisen**

Run: `swift build` (0 Fehler) und `swift test` → alle Suiten grün (370 + 3 neue = 373; Zahl je nach migriertem Block prüfen und im Report festhalten).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: hoist bandwidth buckets into an app-global limiter"
```

---

### Task 3: SessionTab + ContentView-Umbau auf Tabs (RISK)

**Files:**
- Create: `Sources/MacSCPApp/SessionTab.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift` (Kern-Umbau; `BrowserSession`-Struct dorthin verschieben)
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (nur falls Signaturen sich ändern)

**Interfaces:**
- Consumes: `TabsViewModel` (T1), `BandwidthLimiter` (T2), bestehende `BrowserSession`, `ConnectionViewModel`, `TransferQueueViewModel`, `ConflictPromptBridge`, `SessionSidebar`, `teardownSession`-Logik.
- Produces (T4 verlässt sich hierauf):
  - `@MainActor @Observable final class SessionTab: Identifiable` mit: `let id: UUID`; `let connectionViewModel: ConnectionViewModel`; `var session: BrowserSession?`; `let transferQueue: TransferQueueViewModel`; `let conflictBridge: ConflictPromptBridge`; `var titleName: String?`; `var editErrorMessage: String?`; `var activeStoredSessionID: UUID?`; `var isReconnecting: Bool`; `var seenFailureCount: Int` (Achtung-Indikator-Anker); computed `var isConnected: Bool { session != nil }` und `var displayTitle: String` (titleName ?? lokalisiertes "Neue Verbindung").
  - `ContentView`-Funktionen: `makeTab() -> SessionTab` (frischer Formular-Tab inkl. `transferQueue.limiter = bandwidthLimiter` und Decider-Verkabelung auf die tab-eigene Bridge), `connect(in tab: SessionTab, stored: StoredSession)` (ohne Teardown fremder Tabs!), `closeTab(_ tab: SessionTab) async` (Teardown + `tabsModel.closeTab`), `teardown(_ tab: SessionTab) async` (tab-lokal, heutige Reihenfolge).
  - `tabsModel: TabsViewModel<SessionTab>` als `@State` in `ContentView`.

**Verhaltens-Anforderungen (aus Spec §1, §3):**
1. `session/transferQueue/conflictBridge/sessionTitleName/editErrorMessage/activeSessionID/isReconnecting/connectionViewModel` wandern KOMPLETT in `SessionTab`; `ContentView` behält fensterweit nur: `tabsModel`, `window`, `lastBrowserSize`, `importedHosts`, `sessionListViewModel`, `settingsStore`, `bandwidthLimiter`.
2. `detail`/Toolbar/Sheets/Banner rendern den AKTIVEN Tab (`tabsModel.activeTab`); nur dieser ist gemountet. Alle bisherigen `session.`-Zugriffe werden `activeTab.session.`-Zugriffe; das Konflikt-Sheet bindet an `activeTab.conflictBridge`, die Queue-Bar an `activeTab.transferQueue`, der Resume-Banner an `activeTab.transferQueue` + `activeTab.session`.
3. `startSession(with:storedName:)` wird `startSession(in tab: SessionTab, with fs:, storedName:)` — schreibt in den Tab statt in Fenster-State; Decider-/Limiter-Verkabelung passiert in `makeTab()` genau einmal pro Tab (NICHT mehr pro Connect).
4. Sidebar-Handler:
   - `onSelect`: `let target = tabsModel.sidebarConnectTarget(activeTabIsConnected: tabsModel.activeTab.isConnected, makeTab: makeTab)`, dann `connect(in: target, stored:)`. `connect(in:)` = heutiges `connectStored` OHNE `teardownSession()`-Vorspann, wenn der Ziel-Tab unverbunden ist (er ist es per Regel immer; defensiv: falls doch verbunden, erst `teardown(target)`), Guard auf `target.isReconnecting`.
   - `onEdit`: aktiver Tab unverbunden → `beginEditing` in dessen ConnectionViewModel; sonst neuer Tab via `makeTab()` + `addTab` + `beginEditing` dort.
   - `onNew`: aktiver Tab unverbunden → Formular leeren (heutiges `newConnection` ohne Teardown); sonst neuer leerer Tab.
   - `onDelete`: wie heute, nur `activeStoredSessionID` in ALLEN Tabs nullen, deren Wert passt.
   - `sidebarDisabled` ersatzlos streichen; stattdessen `interactionsDisabled: tabsModel.activeTab.isReconnecting || tabsModel.activeTab.connectionViewModel.state == .connecting`.
   - Highlight: `activeSessionID: tabsModel.activeTab.activeStoredSessionID`.
5. Toolbar-„Trennen" → `disconnectToForm(tabsModel.activeTab)`: Teardown des Tabs, `tab.session = nil`, Queue/Unterbrochene BLEIBEN (nur `cancelAll` der laufenden wie heute — Achtung: heutige Semantik beibehalten: `teardownSession` cancelt aktive; Unterbrochene überleben `cancelAll` bereits heute, nichts extra tun).
6. Fenstergröße: Helper `private var isPristine: Bool { tabsModel.isLastTab && !tabsModel.activeTab.isConnected }`. `resizeWindow`-Aufrufe: Grow beim ersten Connect wie heute; Shrink NUR wenn nach der Aktion `isPristine` gilt. `.frame(minWidth:)`-Bedingungen von `session == nil` auf `isPristine` umstellen.
7. `showHiddenFiles`-Observer iteriert über ALLE Tabs mit Session (Filter setzen + refresh). Die Limit-Observer aus T2 bleiben auf dem `bandwidthLimiter`; `maxConcurrentTransfers`-Observer iteriert über alle Tab-Queues.
8. Fenstertitel: `.navigationTitle` aus `tabsModel.activeTab.titleName`.
9. Der Menü-Handler (`onMenuAction`) und `transferSelection`/`copyPaths`/`uploadDropped`/`openInEditor`/`remotePromiseProvider` nehmen den Tab (bzw. dessen Session/Queue) als Parameter statt des globalen `session` — mechanische Anpassung, Verhalten identisch.

- [ ] **Step 1: `SessionTab.swift` anlegen** (inkl. hierher verschobenem `BrowserSession`-Struct, unverändert):

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

(Der `ConflictPromptBridge`- und `ConnectionViewModel`-Typ existieren; `ConflictPromptBridge` von `ContentView.swift` hierher verschieben, falls Sichtbarkeit es erfordert. Katalog-Keys `tabs.newConnection` EN "New Connection" / DE „Neue Verbindung" ergänzen.)

- [ ] **Step 2: `ContentView` umbauen** gemäß Verhaltens-Anforderungen 1–9. `makeTab()` als statische Factory, damit sie auch dem `ContentView`-Init zur Verfügung steht:

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

`@State private var tabsModel: TabsViewModel<SessionTab>` — Initialisierung im `init` von `ContentView`:

```swift
    init(settingsStore: SettingsStore, bandwidthLimiter: BandwidthLimiter) {
        self.settingsStore = settingsStore
        self.bandwidthLimiter = bandwidthLimiter
        _tabsModel = State(initialValue: TabsViewModel(
            initial: Self.makeTab(settingsStore: settingsStore, limiter: bandwidthLimiter)))
    }
```

- [ ] **Step 3: Build + volle Suite**

Run: `swift build` (0 Fehler, keine neuen Warnungen) und `swift test` → Stand aus T2 unverändert grün.

- [ ] **Step 4: Verhaltens-Selbstcheck** (Report): je ein Satz mit Code-Beleg zu den Anforderungen 1–9; explizit bestätigen, dass (a) kein Codepfad mehr `teardownSession` global aufruft, (b) Sidebar-Klick bei verbundenem aktivem Tab KEINEN Teardown auslöst, (c) das Konflikt-Sheet an der tab-eigenen Bridge hängt.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: move the window session state into per-tab objects"
```

---

### Task 4: Tab-Strip-UI, Indikatoren, Schließen, Shortcuts, Fenster

**Files:**
- Create: `Sources/MacSCPApp/TabStripView.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift` (Strip einhängen, Schließen-Confirm, Fenstergrößen-Regel final), `Sources/MacSCPApp/MacSCPApp.swift` (Commands), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj` (neue Keys)
- Test: keiner (App-Target; visueller Smoke in T5)

**Interfaces:**
- Consumes: `tabsModel`, `SessionTab` (T3), `TransferQueueViewModel.lastStartedDirection`/`failedCount`/`isActive` (T2), Design-Tokens (`DesignTokens.paper/card/hairline/ink/inkSecondary/inkTertiary/remoteBlue/localAmber` — exakte Token-Namen in `DesignTokens.swift` nachschlagen).
- Produces: `TabStripView(tabs:activeTabID:onActivate:onClose:onAdd:)`.

**Maße (Spec §2 / Mockup, bindend):** Strip 30 pt, Fläche `paper`, Hairline unten; aktiver Tab `card`-Fläche + 2-pt-`remoteBlue`-Unterstreichung + Titel 12 pt semibold `ink`; inaktive `inkSecondary` + Hairline-Trenner rechts; Tab min 120 / max 200 pt, Ellipsis; ✕ 15-pt-Hit-Area nur bei Tab-Hover; ⊕ 30 pt rechts; Formular-Tab kursiv `inkTertiary`; Indikator 7-pt-Punkt links: Achtung-Rot statisch (Priorität) > Bernstein (Upload) / Blau (Download) mit dezentem Pulsieren (`opacity`-Animation, `reduceMotion` respektieren) > kein Punkt. a11y: `accessibilityValue` je Zustand. Strip unsichtbar im jungfräulichen Zustand (`isPristine`).

- [ ] **Step 1: `TabStripView.swift`**:

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

(Token-Namen `paperColor/cardColor/localAmber` an die realen Bezeichner in `DesignTokens.swift` anpassen — `paper` wurde in M6a entfernt, ggf. ist die Strip-Fläche der Fenster-Hintergrund; im Report festhalten, welcher Token verwendet wurde. Maße NICHT anpassen.)

- [ ] **Step 2: Einhängen + Schließen-Confirm** in `ContentView`: Strip oberhalb des Detail-Inhalts, `if !isPristine`. `onClose`-Fluss:

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

Alert (destruktiv, an `closeRequest` gebunden): Titel-Key `tabs.close.title` „Close tab?"/„Tab schließen?", Text `tabs.close.activeTransfers` „Active transfers in this tab will be canceled."/„Laufende Übertragungen in diesem Tab werden abgebrochen.", Buttons `common.cancel` + `tabs.close.confirm` „Close"/„Schließen" (role .destructive). Beim Tab-AKTIVIEREN (`onActivate` und nach `closeTab`): `tab.seenFailureCount = tab.transferQueue.failedCount` für den neuen aktiven Tab (Achtung-Reset beim Besuch).

- [ ] **Step 3: Commands** in `MacSCPApp.swift` — `CommandGroup(replacing: .newItem)`: „New Tab" ⌘N (ruft via `FocusedValue` oder — einfacher, da Ein-Fenster-App — über eine an `ContentView` gereichte, dort gesetzte `@Observable`-Command-Brücke `TabCommands` mit Closures `newTab/closeTab/selectTab(Int)`; Implementierungsweg im Report dokumentieren) und „Close Tab" ⌘W (letzter unverbundener Tab → `window.performClose(nil)`). ⌘1–⌘9 als „Tab n"-Items (Window-Menü, `CommandGroup(after: .windowList)`), Ziel = Index n-1, No-op wenn außerhalb. ⌃Tab nur, falls als Menü-Shortcut (`KeyEquivalent("\t")`, `.control`) funktionsfähig — sonst weglassen und im Report vermerken. Keys `menu.newTab` „New Tab"/„Neuer Tab", `menu.closeTab` „Close Tab"/„Tab schließen", `menu.selectTab` „Tab %lld"/„Tab %lld".

- [ ] **Step 4: Build + volle Suite + Katalog-Check**

Run: `swift build` && `swift test` (Stand T3 grün). Katalog-Gegenprobe: jeder neue `L10n.string`-Key existiert in BEIDEN `.strings`-Dateien.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add the tab strip with activity indicators and tab commands"
```

---

### Task 5: Abschluss-Verifikation (Koordinator)

- [ ] Gated Suiten (Rig aus dem Haupt-Checkout, `docker compose -f docker/test-server/compose.yml start`): `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` ⇒ komplett grün, zero skips.
- [ ] Visueller Smoke (Dev-Wrapper; Maintainer testet ggf. selbst — Checkliste übergeben):
  - Start = heutiges Bild (kein Strip, kompaktes Formular-Fenster).
  - Verbinden → Fenster wächst; ⊕ → Formular-Tab im großen Fenster, Strip sichtbar; zweite Session verbinden (Rig-User) → zwei Tabs.
  - Sidebar-Klick bei verbundenem aktivem Tab → NEUER Tab, erste Session läuft weiter (Terminal-Ping im Hintergrund-Tab lebt nach Rückwechsel, Replay zeigt Ausgabe).
  - Gedrosselter Transfer in Tab A, Wechsel zu Tab B: Bernstein/Blau-Punkt an Tab A pulsiert; Transfer läuft im Hintergrund weiter (Queue-Bar bei Rückwechsel).
  - Bandbreite app-global: Limit 300, je ein Download in ZWEI Tabs gleichzeitig → Summe ≈ Limit (Anzeige in beiden Queue-Bars).
  - Konflikt in Hintergrund-Tab provozieren → roter Punkt, KEIN Sheet im aktiven Tab; Wechsel → Sheet erscheint; Achtung-Reset nach Besuch.
  - Tab schließen ohne Transfers → weg, rechter Nachbar aktiv; mit Transfers → destruktive Nachfrage; letzter Tab → wird Formular-Tab, Fenster schrumpft.
  - ⌘N/⌘W/⌘1–⌘9; ⌘T weiterhin Terminal; Fenstertitel folgt aktivem Tab; „Trennen" macht Formular-Tab, Unterbrochene + Resume-Banner überleben im Tab.
  - Regressionen: Doppelklick-Editor, Drag&Drop in beide Richtungen, Kontextmenü (M7b), Umbenennen/Rechte/Löschen, versteckte Dateien ⌘⇧. wirkt auf beide Tabs.
- [ ] Plan-Checkboxen, Ledger, Opus-Whole-Branch-Final-Review (Base = Commit vor T1), Fixes, Push develop, CI, Rig `stop`, Memory-Update, Milestone-Zusammenfassung (+ Übergang M8b).
