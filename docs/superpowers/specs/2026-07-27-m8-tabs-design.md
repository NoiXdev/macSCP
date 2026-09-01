# M8 — Tabs for multiple active sessions (Design)

Date: 2026-07-27 · Status: approved by the maintainer (blocks 1+2 confirmed individually) ·
Mockup: `docs/design/assets/m8-tabs-mockup.html`

## Goal

One window holds several simultaneously active SSH sessions as tabs (the WinSCP model).
Background tabs keep running fully (transfers, shell, edit watcher). The
context menu carries selections into other sessions — including a direct
server-to-server stream through the app.

**Maintainer decisions (2026-07-27):**

1. New tabs arise via BOTH: the ⊕ tab (an empty tab = connection form) AND
   a sidebar click, which opens a new tab when the active tab is connected.
2. "Transfer to session xy" from both panes, including remote→remote directly
   (stream through the app, no intermediate file).
3. Background tabs keep running; tabs carry activity/attention indicators;
   closing with active transfers asks for confirmation.
4. Bandwidth limits apply app-globally across all tabs (one token bucket per
   direction, app-wide).
5. Approach A: a dedicated tab strip in the window (ONE sidebar; native window
   tabs were dropped). Release v1.1.0 only comes AFTER M8 (it bundles M7+M8).

**Architecture invariant, sharpened:** "one SSH connection per **tab**; the
tab collection belongs to the window." Multi-window stays open for v2; nothing
becomes an app singleton besides the objects that already are app-wide
(SettingsStore, and newly: the two bandwidth buckets).

## Split

- **M8a — Tab infrastructure:** TabsViewModel (Core), tab strip (UI), per-tab
  sessions/queues/bridges, app-global buckets, window/sidebar/shortcut
  behavior, indicators, close semantics.
- **M8b — Cross-session transfers:** the transfer submenu with target
  sessions, remote→remote, a second rig container, close warning for target
  tabs.

Each part stands on its own; separate plans, one shared spec (this one).

---

## 1. State model (M8a)

### 1.1 SessionTab

`ContentView` replaces `session: BrowserSession?` with:

- `tabs: [SessionTab]` (at least 1 element, order = strip order)
- `activeTabID: UUID?` (always points at an existing element)

`SessionTab` (App layer, reference type `@MainActor @Observable final class`)
bundles the state that used to be window-wide, PER TAB:

- `id: UUID` (tab identity; independent of `BrowserSession.id`)
- `connectionViewModel: ConnectionViewModel` (form state of empty tabs;
  every tab has its own)
- `session: BrowserSession?` (nil = form tab)
- `transferQueue: TransferQueueViewModel` (per tab; survives disconnecting
  the tab — resume-banner behavior as today, just tab-local)
- `conflictBridge: ConflictPromptBridge` (per tab)
- `titleName: String?` (the former `sessionTitleName`, per tab)
- `editErrorMessage: String?` (per tab)
- `activeStoredSessionID: UUID?` (the former `activeSessionID`, per tab —
  the sidebar highlights the value of the ACTIVE tab)
- `isReconnecting: Bool` (per tab; locks only its own connection paths)

`BrowserSession` itself stays unchanged (id/localFS/remoteFS/local/remote/
terminal/editManager).

### 1.2 TabsViewModel (Core, testable)

The tab MANAGEMENT RULES live as a generic state machine in
`Sources/macSCPCore/Presentation/TabsViewModel.swift` — without UI and
without SSH dependencies (lesson M7a: the App target is untestable). Generic
over the payload (`TabsViewModel<Payload>` or protocol-based), the app
instantiates it with `SessionTab`.

Rules (all unit-tested):

- `addTab()` → a new tab at the end, becomes active (⊕ / ⌘N).
- `closeTab(id:)` → removes it; if it was active, the RIGHT neighbor becomes
  active, otherwise the left one (browser convention); the last tab is NOT
  removable (the app interprets "⌘W on the last unconnected tab" as closing
  the window).
- `activate(id:)`; `activeTab` accessor.
- "Target tab for sidebar connect": active tab unconnected → this tab; active
  tab connected → `addTab()`. (The "unconnected" predicate is supplied by the
  app via a closure/protocol requirement, so the rule stays testable.)

### 1.3 Rendering & lifecycle

- Only the ACTIVE tab is mounted in the view tree. Background tabs keep
  living as state — their queues, shells and watchers run without further
  intervention.
- Terminal remount on tab switch goes through the existing 256 KiB replay
  buffer (M5a); the panes remount via the existing VMs.
- Conflict sheets hang off the tab content: a conflict in a background tab
  parks the transfer (FIFOGate, already present) and sets the attention
  indicator; the sheet only appears when switching into that tab. No sheet
  ever interrupts the active tab because of a foreign tab.
- Teardown on tab close = today's `teardownSession` order, tab-local:
  `conflictBridge.dismiss()` → `queue.cancelAll()` → `editManager.stopAll()` →
  `terminal.shutdown()` → `remote.disconnect()`.

## 2. Tab strip (M8a, UI)

Dimensions/look per the mockup (`m8-tabs-mockup.html`), design tokens
present:

- Strip 30 pt tall, between toolbar and pane heads, hairline at the bottom,
  surface `paper`.
- Active tab: surface `card`, title 12 pt semibold `ink`, 2-pt underline
  `remoteBlue` at the bottom edge. Inactive: `inkSecondary`, separator
  hairline on the right. Max width ~200 pt, title with ellipsis.
- ✕ (15 pt hit area) only visible on tab hover; ⊕ on the right (30 pt).
- Form-tab title: "New connection" (localized), italic, `inkTertiary`.
- Indicator (7-pt dot, left of the title): amber = upload active, blue =
  download active (with both: direction of the most recently STARTED item),
  subtle pulsing; static red = attention (a conflict waiting OR failed
  transfers since the last visit); no dot = idle. Priority: red > active.
  a11y: indicator state as accessibilityValue on the tab.
- **Pristine state** (exactly one unconnected form tab): the strip is
  invisible — startup look identical to today.

## 3. Window, sidebar, shortcuts (M8a)

- **Window size:** the active grow/shrink logic (700×460 ↔ ≥930×620) applies
  only in the single-tab state. From the second tab onward, OR as soon as the
  only tab is connected, the window stays at browser size; a form tab shows
  the form top-aligned in the large window. It only shrinks back once exactly
  one unconnected tab remains again. `lastBrowserSize` stays window-wide.
- **Window title:** "macSCP — ‹titleName of the active tab›", otherwise
  "macSCP".
- **Toolbar** acts on the active tab (upload/download/⌘T/disconnect).
  "Disconnect" turns the tab into a form tab (queue and interrupted transfers
  remain).
- **Sidebar (ONE, unchanged, on the left):**
  - Session click: active tab unconnected → connect IN the tab (today's
    behavior); connected → new tab + connect there.
  - The blanket `sidebarDisabled` lock goes away; clicks are locked only
    while the tab that would perform the connect is itself `isReconnecting`/
    connecting. Running transfers no longer lock the sidebar (a click no
    longer destroys a session).
  - "Edit…": active tab unconnected → form in the tab; otherwise a new form
    tab with edit context.
  - Highlight = `activeStoredSessionID` of the active tab.
  - Deleting a stored session leaves connected tabs untouched (only a
    highlight reset, as today).
- **Shortcuts:** ⌘T terminal (stays). ⌘N new tab (multi-window is v2).
  ⌘W closes the active tab; if it's the last one AND unconnected, it closes
  the window (document this behavior change). ⌃Tab/⌃⇧Tab cycle, ⌘1–⌘9 direct
  selection.
- **Settings wiring:** `showHiddenFiles` affects ALL tabs (filter + refresh
  per session). `maxConcurrentTransfers` affects the per-tab queue
  (deliberate: per-connection limit, channel multiplexing). Bandwidth: see
  4.

## 4. App-global bandwidth buckets (M8a)

- The two directional buckets (`BandwidthBucket` up/down) are created ONCE in
  `MacSCPApp` (alongside the `SettingsStore`) and injected into every tab
  queue. `TransferQueueViewModel` gets an init/injection path for
  externally-managed buckets for this purpose; today's internal creation via
  `uploadLimitBytesPerSec`'s didSet goes away in favor of the injected
  instances.
- Limit changes re-rate the LIVE instances (the generation counter from M6b
  stays); semantics: 300 KB/s = 300 across all tabs combined (shared, like
  the M6a live proof, just app-wide).
- **Remote→remote counts against BOTH buckets** (it is really a download AND
  an upload on the line): the engine call gets both buckets for such
  transfers, throttled to the minimum of both allowances. (Extend
  `copyFile(throttle:)` with a second optional bucket; token-taking order is
  deadlock-free — wait on the tighter one first, then draw the other, details
  in the plan.)
- 0 = off (as today); mixed operation (one limit set, one off) unchanged.

## 5. Cross-session transfers (M8b)

### 5.1 Semantics

- The context menu's "Transfer" becomes a SUBMENU: first entry as before
  ("To the other pane" — today's wording), then a separator, then ONE entry
  per OTHER connected tab: "To '‹titleName›'" with the target tab's current
  remote path as subtitle/hint. Form tabs and the tab's own entry NEVER
  appear. No other connected tab → the submenu contains only the previous
  entry (look as today).
- The target is ALWAYS the target tab's remote, target directory =
  its `remote.currentPath` at the time of the click.
  - Local selection → upload to the target remote.
  - Remote selection → a direct remote→remote stream through the app
    (chunk-wise, no intermediate file; throughput = min of download A and
    upload B).
- Symlinks: excluded from transfers as before (menu rules from M7b
  unchanged; multi-select skips symlinks in the tree as before).
- Folders go through `enqueueTree` (existing recursion including conflict-
  and group-abort machinery).

### 5.2 Queue ownership & conflicts

- The job lands in the SOURCE tab's queue: that's where the action was
  triggered, that's where progress, errors, conflict sheets appear (the
  source tab's bridge).
- Conflict checking runs against the destination FS — M5b machinery
  unchanged (rename/skip/overwrite/applyToAll).
- After completion, the TARGET tab's REMOTE pane refreshes (weak capture as
  usual); additionally the source pane, only where that's already the
  practice today.
- Bandwidth: local→remote cross-transfers count against the upload bucket;
  remote→remote against both (section 4).

### 5.3 Edges & error cases

- **Target tab closes during the stream:** its teardown severs the target
  connection; the running job in the source tab ends via the existing M5d
  mapping (connectionFailed → interrupted or failed). No special path, no
  hang.
- **Close confirmation extended:** it also appears if the tab is the TARGET
  of active transfers from other tabs (the text names this explicitly).
  Detection: starting with M8b, queue items carry an optional target-tab
  reference (App-side only, e.g. `destinationTabID`), checked app-side on
  close.
- **Target disconnects between menu build and click:** the enqueue runs
  against the dead FS and ends as a normal error message in the source
  queue (no guard needed; fail-safe already present).
- The target path is frozen at CLICK time (if the target tab navigates
  further afterward, that no longer changes the target) — a deliberate
  decision, visible in the submenu hint.

## 6. Menu model (M8b, Core)

`BrowserContextMenu` is extended:

- New parameter: list of possible target sessions
  (`[CrossSessionTarget]`: `id`, `title`, `remotePath`) — the app passes the
  other CONNECTED tabs.
- `BrowserMenuEntry.transferToOtherPane` stays; new:
  `transferToSession(CrossSessionTarget)`. The exhaustive switch in
  `ContentView` (M7b final-review fix) enforces handling it at compile time.
- Rules (unit-tested): target entries only when the selection is
  transferable (same gate as `transferToOtherPane`); never the tab's own
  entry; never form tabs; order = strip order.

## 7. Tests

- **TabsViewModel (Core, TDD):** add/close/activate, neighbor choice when
  closing the active tab (right, otherwise left), last-tab protection,
  sidebar-connect target choice (unconnected = in place, connected = new
  tab).
- **Shared buckets:** two queues, one bucket pair, aggregate rate holds the
  limit (pattern of the M6a proof as a unit test with an injected clock);
  double-bucket throttle (remote→remote) including deadlock freedom (tighter
  bucket first).
- **Menu model:** submenu rules from section 6; multi-select/symlink
  unchanged (regressions).
- **Remote→remote, gated:** SECOND container in the test compose (port 2223,
  its own seed, same image/PIN); test connects both, copies server→server,
  checks checksum; cleanup on both sides. Rig convention (start/stop, main
  checkout) applies unchanged.
- **App side** (strip rendering, sheet wiring, indicators): visual smoke
  (checklist in the plan; the maintainer tests it themselves).

## 8. Deliberately NOT in M8

- Tab tear-off/docking (drag out), tab reordering via drag — backlog.
- Multi-window (v2) and persisting open tabs across app restart.
- One app-global transfer window across all tabs (every queue bar stays
  tab-local).
- Handing off queues on close (jobs do not migrate to other tabs).
