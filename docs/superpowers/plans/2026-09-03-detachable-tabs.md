# Detachable, Optionally Sticky Tabs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tab can be moved into a new full window and between windows
by drag, its connection surviving the move; a window can be kept above
all others; an emptied window closes unless it is the last; a setting
(default off) restores windows without their connections at launch.
From `docs/superpowers/specs/2026-09-03-detachable-tabs-design.md`
(brainstormed with the maintainer 2026-09-02/03).

**Architecture:** A process-wide `@MainActor` `TabRegistry` (App layer)
owns every live `SessionTab` by id and records which window holds it;
`TabsViewModel<SessionTab>` keeps its API but a window's model is built
from ids the registry resolves. A move reassigns ownership — the
`SessionTab` object, its `BrowserSession`, queue and terminal are never
recreated, which the tests pin (same `BrowserSession.id`, no
`disconnect`). The app's `WindowGroup` (read `Sources/MacSCPMain/Main.swift`)
gains a value-typed instance keyed by a `WindowSeed` (the tab ids it
starts with); `openWindow(value:)` opens a second window; the window's
`ContentView` claims its seed's tabs from the registry on appear and
releases them on close through the existing teardown path
(`cancelAll` → `shutdown` → `disconnect`) — teardown of a window tears
down only the tabs it still holds. Sticky is `NSWindow.level` on the
handle `WindowAccessor` resolves. Restoration is a `SettingsStore`
flag; on, each window's seed (tab ids → session ids, pane visibility,
sticky) is written on close and read at launch, tabs come back
disconnected.

**Tech Stack:** SwiftUI `WindowGroup`/`openWindow`, AppKit `NSWindow.level`,
`TabsViewModel` (`Sources/macSCPCore/Presentation/TabsViewModel.swift`),
`SessionTab`/`BrowserSession` (`Sources/MacSCPAppKit/SessionTab.swift`),
`TabStripView` drag (`Sources/MacSCPAppKit/TabStripView.swift:477`),
`ContentView+Lifecycle` teardown, `SettingsStore`, four App catalogs.

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **A move never touches the connection:** the moved `SessionTab` keeps
  its `BrowserSession` instance; no `disconnect`, no queue cancel, no
  terminal shutdown on a move. Pinned in Task 1 and re-pinned at the
  window level in Task 2.
- **Lifecycles stay explicit** (CLAUDE.md): a window closing tears down
  exactly the tabs it holds at that moment, through the existing
  teardown sequence; the registry never tears anything down on its own;
  no `deinit` cleanup.
- **Connection state belongs to the window scope** — the registry holds
  references and ownership, not state; nothing in Core knows about
  windows.
- **No automatic login at launch** under restoration: a guard pins that
  the launch path calls no `connect`.
- Four App catalogs (`window.moveTabToNewWindow`, `window.keepOnTop`,
  `settings.restoreWindows` + footer), du-form German, parity guards.
- Swift 6; warning budget 1; TDD red first; commit per task; do not push.

---

### Task 1: The registry, and moving a tab between two models

**Files:**
- Create: `Sources/MacSCPAppKit/TabRegistry.swift` (`@MainActor final class TabRegistry { static let shared; func register(_ tab: SessionTab, in window: WindowID); func tab(for id: UUID) -> SessionTab?; func windowHolding(_ id: UUID) -> WindowID?; func move(_ id: UUID, to window: WindowID); func release(_ ids: [UUID], from window: WindowID); var windowCount: Int; func tabs(in window: WindowID) -> [SessionTab] }`, `WindowID` a UUID wrapper)
- Modify: `Sources/macSCPCore/Presentation/TabsViewModel.swift` only if a
  "remove without closing" primitive is missing (`closeTab` refuses the
  last tab and the caller expects a close; a move needs `detach(tabID:) -> Tab?`
  that removes without the last-tab rule — add it, pinned)
- Test: `Tests/macSCPAppKitTests/TabRegistryTests.swift` — register two
  windows' tabs; move one between two `TabsViewModel`s through the
  registry: same object identity (`===`), same `BrowserSession.id`, the
  source model no longer lists it, the target does; a fake `BrowserSession`
  double records that `disconnect`/`cancelAll`/`shutdown` were not called;
  releasing a window's tabs releases only its own; `windowCount`.

- [ ] Red → green → commit `feat(tabs): a registry that lets a tab change windows without changing hands`

### Task 2: A second window, "Move Tab to New Window", the last-window rule

**Files:**
- Modify: `Sources/MacSCPMain/Main.swift` (the `WindowGroup` takes a
  `WindowSeed` value; the primary window is the seedless one — read how
  SwiftUI treats `WindowGroup(for:)` with an optional value), `Sources/MacSCPAppKit/ContentView.swift`
  (+Lifecycle: on appear claim the seed's tabs; on close release what it
  holds through teardown; if it would be left with zero tabs and it is
  not the last window, close itself), `TabStripView`/the tab context
  menu and the Window menu (`window.moveTabToNewWindow`), catalogs.
- Test: `TabsWindowLifecycleTests` — the seed round trip; a claimed tab is
  the registry's object; "last tab leaves → window closes" as a decision
  value (`WindowCloseDecision.after(removing:in:)` — a pure function,
  tested; the view calls it); the last-window exception; a source guard
  that the window's close path releases through the existing teardown
  (positive anchor on the teardown call order).

- [ ] Red → green → commit `feat(windows): a tab moves into its own window`

### Task 3: Drag between windows

**Files:**
- Modify: `Sources/MacSCPAppKit/TabStripView.swift` (the drag payload
  becomes the tab id + source window id; a drop on another window's
  strip claims through the registry — the existing in-strip reorder
  keeps working; a drop that lands nowhere is detach: needs an
  `NSDraggingSession` end hook — read what SwiftUI's `onDrag` offers on
  macOS and, if it cannot report "dropped outside", keep detach on the
  menu only and say so).
- Test: payload encoding round trip; a cross-model drop moves through
  the registry (Task 1's property); reorder within one strip unchanged
  (existing tests green).

- [ ] Red → green → commit `feat(tabs): drag a tab into another window`

### Task 4: Keep on Top

**Files:**
- Modify: the Window menu (a checkmark item `window.keepOnTop`),
  `ContentView` (state + `window.level = .floating / .normal` on the
  resolved `NSWindow`), catalogs.
- Test: the decision value (`WindowLevelPlan`) and a source guard that
  the level is set only from that plan.

- [ ] Red → green → commit `feat(windows): keep a window on top`

### Task 5: Restoration as a setting

**Files:**
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift`
  (`restoresWindows: Bool`, default false), `SettingsView` (toggle +
  footer), the app's launch path (with the flag on: read the seeds,
  open the windows, select the sessions, connect NOTHING; off: only the
  main window; seeds written on window close only when on), catalogs.
- Test: seed round trip; flag off → no seed file written/read; flag on
  → windows described, and a guard that the launch path contains no
  `connect(` (negative check with a positive anchor on the seed read).

- [ ] Red → green → commit `feat(windows): restore windows, disconnected, when asked`

### Task 6: Closeout

- [ ] `docs/superpowers/specs/2026-09-02-backlog-maintainer-notes.md`
  (item 17 → Done), `docs/BACKLOG.md`, the design's status line, and
  CLAUDE.md's "multi-window is planned for v2" sentence updated to what
  is true; commit `docs(backlog): detachable tabs done; multi-window is here`.

## What is explicitly not in this plan

- Sticky across Spaces or beside full-screen apps.
- Automatic reconnect at launch.
- Per-window sidebars with different session lists (the store is app-wide).
