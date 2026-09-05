# Quit Teardown Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ⌘Q tears every live tab down through the one teardown owner
before the process ends — transfers cancelled, edit watchers stopped,
terminals shut, connections closed, the audit log's `disconnected`
rows written — bounded, so a frozen peer cannot hold the quit.

**Architecture:** Measured 2026-09-05 (`docs/BACKLOG.md:66` and the
survey behind this plan): `AppDelegate.applicationWillTerminate`
(`Sources/MacSCPAppKit/MacSCPApp.swift:266-271`) sweeps parked seeds,
writes the restoration file, logs `app quit` and flushes; it runs no
teardown because it is synchronous and `ContentView.teardown(_:reason:)`
(`ContentView+Lifecycle.swift:477`) is main-actor `async`. Nothing
implements `applicationShouldTerminate(_:)`. `teardown` reads nothing
from `ContentView` but its `SessionTab` argument, and every window
already has `releaseUnclaimedSeedsOnClose()` + `releaseHeldTabsOnClose()`
as its close-time sequence. So: each `ContentView` registers a
per-window teardown closure with `TabRegistry` (the same shape as the
restoration describers — `registerWindowDescriber`); `AppDelegate`
implements `applicationShouldTerminate`, which returns `.terminateNow`
when no window holds a tab with a session, else `.terminateLater`,
writes the restoration seeds FIRST (teardown clears
`activeStoredSessionID`), runs every window's closure in registry order
in one main-actor task, races it against a watchdog bound, then logs
`app quit`, flushes, and replies `NSApp.reply(toApplicationShouldTerminate:
true)`. The registry only hands the closures out; it never tears down
(`TabRegistryNoTeardownGuardTests` keeps scanning it).

**Tech Stack:** Swift 6 strict, AppKit `NSApplicationDelegate`,
`TabRegistry`, `TeardownStage`, Swift Testing.

**Spec:** `docs/BACKLOG.md`, row "Quit tears down nothing" (hedged as
"nothing observed is not measured safe").

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; commit per task; zero warnings; do not push.
- **One teardown owner.** The quit path reaches a tab only through the window's existing close sequence (`releaseUnclaimedSeedsOnClose` then `releaseHeldTabsOnClose`, which call `ContentView.teardown`). No second copy of the four stages anywhere; the registry contains no teardown call (its guard stays green).
- **Bounded.** The whole quit sequence is capped by `QuitWatchdog.bound` (a production wall clock is allowed; it is not a test): when the bound passes first, the app replies `terminateNow` anyway and the log says which windows were still tearing down. The bound is a constant with its reason in the doc comment (the per-stage bounds in `TeardownStage` are 5 s; a tab's worst case is two stages plus a bounded disconnect; the cap is 15 s).
- **Order.** Restoration seeds are written BEFORE any teardown; the diagnostic log's `app quit` line and `flushSynchronously()` run LAST, after the teardown finished or the watchdog fired, and before the reply.
- **No new way to connect; nothing in Core knows about windows** (the closures live in the App target).
- Red first; no `#require` on a non-optional; no wall-clock ceiling in tests; tests never block the pool; a negative check has a positive beside it; comments in prose near anchors; numbers counted.
- Do NOT launch the GUI; the maintainer's dev build is the sight check (⌘Q with a connected tab and a transfer in flight: the audit log shows `disconnected`; ⌘Q with nothing connected: immediate).

---

### Task 1: The quit sequence

**Files:**
- Modify: `Sources/MacSCPAppKit/TabRegistry.swift` (`typealias WindowTeardown = @MainActor () async -> Void`; `registerWindowTeardown(_:for:)` / `unregisterWindowTeardown(for:)` beside the describer API; `allWindowTeardowns() -> [(WindowID, WindowTeardown)]` in registry order; NO call of any closure inside the registry)
- Modify: `Sources/MacSCPAppKit/ContentView+Lifecycle.swift` (in `performWindowSetup()` register `{ [self] in await releaseUnclaimedSeedsOnClose(); await releaseHeldTabsOnClose() }` — read whether those two are `async` today or spawn `Task`s internally; if they spawn, add awaitable variants they share, so the quit can await completion; unregister in `handleWindowWillClose`)
- Create: `Sources/MacSCPAppKit/QuitSequence.swift` (`enum QuitDecision { case now, later }`; `QuitSequence.decision(liveTabCount: Int) -> QuitDecision`; `QuitWatchdog.bound: Duration = .seconds(15)` with its reason; `QuitSequence.steps` as an ordered array of a small enum `[.writeRestoration, .teardownWindows, .logQuit, .flush, .reply]` so a guard can pin the delegate's order against it)
- Modify: `Sources/MacSCPAppKit/MacSCPApp.swift` (`AppDelegate.applicationShouldTerminate(_:)`: count live tabs through the registry (a tab counts when `session != nil`); `.now` → `writeRestorationSeeds()`, log `app quit`, flush, return `.terminateNow`; `.later` → `writeRestorationSeeds()` synchronously, then one `Task { @MainActor in }` that runs `sweepUnclaimedMoves()` (now tearing the parked tabs down through the App layer — a small helper that runs `teardown` on each parked `SessionTab`; find the one place that can own it: a `ContentView`-free `TabTeardown.run(tab:reason:)` extracted from `ContentView.teardown` — that extraction IS the "one owner" the invariant names; `ContentView.teardown` becomes a call into it) then every window's closure in order, racing a `Task.sleep(QuitWatchdog.bound)`; whichever finishes first: log `app quit windows=<n> tornDown=<m> forced=<bool>`, `flushSynchronously()`, `NSApp.reply(toApplicationShouldTerminate: true)`; `applicationWillTerminate` keeps only what must run synchronously at the very end (nothing that duplicates the above — read it and reduce it))
- Test: `Tests/macSCPAppKitTests/QuitSequenceTests.swift` — the decision (0 live → now; 1 → later); the steps array order; a registry instance: two teardown closures registered, `allWindowTeardowns()` yields them in registration order, each invoked once by a test-side loop (the registry itself invokes nothing — a source guard scans `TabRegistry.swift` for no `await` of a teardown closure, positive beside it: the closures are stored and returned); a source guard on `AppDelegate.applicationShouldTerminate`'s body: `writeRestorationSeeds(` precedes the teardown loop, which precedes `app quit`/`flushSynchronously(`/`reply(` (positional pin, each positive), `QuitWatchdog.bound` is referenced (positive), no second copy of the stage names outside `TabTeardown`/`ContentView.teardown` (negative beside the positive that `TabTeardown` names them); the `TabTeardown` extraction pinned by the existing teardown tests still green (`grep -rn "teardown(" Tests/MacSCPAppKitTests | head` to find them).

- [x] **Step 1: Red first** — `cannot find 'QuitSequence'`, the registry API, the guards.
- [x] **Step 2: Implement**; `swift test --filter "Quit|Teardown|TabRegistry|Window"` green; full `swift test`; zero warnings.
- [x] **Step 3: Commit** `feat(app): quitting tears every live tab down through the one owner, bounded`.

---

### Task 2: Closeout

**Files:**
- Modify: `docs/BACKLOG.md` (the row → Done: the sequence, the bound, what the audit log now shows, the sight check), `CLAUDE.md` ("The UI owns lifecycles explicitly" bullet gains the quit path in one clause), `README.md` (optional, one sentence if the sessions section mentions quitting — likely nothing).

- [x] **Step 1:** the row and the bullet; commit `docs(backlog): quit tears down through the one owner`.
