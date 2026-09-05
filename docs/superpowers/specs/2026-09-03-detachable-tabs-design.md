# Detachable, Optionally Sticky Tabs — Design

**Status:** brainstormed with the maintainer on 2026-09-02/03 (four
questions, answered below); **awaiting the maintainer's read of this
document** before the plan. From item 17 of
`2026-09-02-backlog-maintainer-notes.md`. Nothing here is implemented.

## The decisions

1. **A detached tab is a full window** — a second main window with the
   sidebar and the tab strip, started with that one tab, able to take
   more. This IS the multi-window the architecture invariant reserves
   for "v2"; detaching is "move this tab into a new window".
2. **Sticky = above all windows:** a per-window toggle in the Window
   menu puts the window on the floating level, above other apps, and
   leaves everything else normal (title bar, resizing, Spaces behaviour).
   Not across all Spaces, not beside full-screen apps.
3. **Tabs move in both directions** between any two macSCP windows by
   drag; a window whose last tab leaves or closes closes itself — unless
   it is the app's last window, which stays open, empty, like a fresh
   main window.
4. **Restoration is a setting, default off:** with the setting on, the
   windows come back at the next launch with their tabs and their sticky
   state but DISCONNECTED — a click connects; no automatic logins, no
   keychain read, no host-key question at launch. Off: only the main
   window, as today.

## The measured starting point

- One `ContentView` per window owns `TabsViewModel<SessionTab>`
  (`ContentView.swift:189`); each `SessionTab` owns its `BrowserSession`
  — the connection, the two panes' state, the terminal. The connection
  therefore already lives with the TAB, not with the window; moving a tab
  is moving that object, and the invariant "connection state belongs to
  the window scope, never to an app-wide singleton" keeps holding — the
  scope is the window the tab is in.
- The session STORE (sidebar list, groups) is app-wide already; the
  sidebar in each window shows the same list. Nothing in it is
  per-window.
- SwiftUI gives the app a `WindowGroup`; a second instance is opened
  with `openWindow(value:)` carrying an identifier, and the scene builds
  its `ContentView` from that value. The `NSWindow` handle is resolved
  through `WindowAccessor` (`ContentView.swift:111-125`) — the hook for
  the floating level. State restoration in SwiftUI restores scenes with
  their values; the setting decides whether the app honours that.
- The tab strip already supports drag reordering within one strip
  (`TabStripView.swift:477`, a `dropDestination` for a String payload).
  Cross-window drag needs a payload that identifies the tab across
  process-wide state, and a place the tab lives while it is "in flight".

## The design

### Tab ownership across windows

A process-wide `TabRegistry` (App layer, `@MainActor`, one instance)
holds every live `SessionTab` by id and knows which window has it. A
window's `TabsViewModel` holds ids and asks the registry for the
objects. Moving a tab = registry reassigns the id; the source window's
model drops it, the target's inserts it. The tab object is never
destroyed by a move, so its connection, queue and terminal survive
untouched — that is the whole point, and it is the property the tests
pin: a tab moved between two `TabsViewModel`s keeps the same
`BrowserSession.id`, and no `disconnect` is called.

Not a singleton for STATE the invariant forbids: the registry holds
references so a window can find its tabs; the connection state stays
inside the tab, whose lifetime the owning window controls exactly as
today (teardown on close → `cancelAll` → `shutdown` → `disconnect`).

### Detach and drag

- "Move Tab to New Window" (tab context menu, Window menu):
  `openWindow(value: WindowSeed(tabID:))`; the new scene's `ContentView`
  claims the tab from the registry on appear.
- Drag between windows: the strip's drag payload becomes the tab id; a
  drop on another window's strip claims it; a drop outside any strip
  (on the desktop) is "detach" — the same path as the menu.
- **Measured 2026-09-05 (Task 3): the drop-outside half is NOT built,
  because macOS 15 offers no hook that reports it.** What was read, in
  the macOS 26.5 SDK, against this package's `platforms:
  [.macOS(.v15)]`:
  - `SwiftUI.swiftinterface`: the only "this drag has ended" callback is
    `View.onDragSessionUpdated(_:)`, whose `DragSession.Phase` carries
    `.ended(DropOperation)`. It is `@available(macOS 26.0, *)`, together
    with `DragSession` and `DragConfiguration` themselves — eleven major
    versions above this app's minimum. There is no `onDragEnd` at any
    availability (grep: zero occurrences), and neither `draggable(_:)`,
    `draggable(_:preview:)` nor `onDrag(_:)` returns or accepts anything
    that reports an outcome.
  - `AppKit`, `NSDragging.h` line 157:
    `draggingSession:endedAtPoint:operation:` is a method of
    **`NSDraggingSource`** — the object that STARTED the session. With
    `.draggable`, that object is SwiftUI's, and it is not vended. There
    is no observer-side equivalent: nothing lets a view learn that a
    session some other object began has ended with `NSDragOperationNone`.
  - So the only route is an `NSViewRepresentable` that calls
    `beginDraggingSession(with:event:source:)` itself and is its own
    `NSDraggingSource`. That REPLACES `.draggable` on the tab rather than
    sitting beside it — two drag sources on one view is two gestures
    racing the same mouse-down — which means the in-strip reorder has to
    be rebuilt on a hand-rolled AppKit drag, and that was out of scope
    for a task whose constraint was that the reorder keep working
    unchanged. (Corrected 2026-09-05: this paragraph also claimed the
    existing wiring guard would fail such an overlay "by count". It
    would not — the guard counts `.draggable(`, and an AppKit overlay
    adds none. The reason above is the whole reason.)

  Detach therefore stays on the menu ("Move Tab to New Window", tab
  context menu and Window menu), which the plan permits. The work this
  leaves open is one of: raise the minimum to macOS 26 and use
  `onDragSessionUpdated`, or move the whole tab drag to AppKit and own
  both halves. Neither is a small edit, and both should be decided
  rather than drifted into.
- Last tab gone → the window closes, unless it is the last window
  (registry knows the window count).

### Sticky

Window menu → "Keep on Top" (checkmark). `NSWindow.level = .floating`
on, `.normal` off, on the window resolved by `WindowAccessor`. Stored
per window in the restoration state (below); no effect on other
windows.

### Restoration

`SettingsStore.restoresWindows` (default false). Off: the app opens one
main window, as today (SwiftUI restoration is declined for the
group's extra instances). On: each window's seed (its tab ids, in order;
each tab's session id and pane visibility; the sticky flag) is written
on close and read at launch; tabs come back disconnected with their
session pre-selected. No secret is touched at launch; the first connect
is the user's click.

### What the tests pin

- Registry: a move keeps the `BrowserSession` instance; teardown of a
  window tears down only its tabs; the last-window rule.
- Strip: the drag payload carries the id; a drop claims across models.
- Sticky: the level toggles and is read back.
- Restoration: seeds round-trip; with the setting off nothing is
  written or read; with it on, tabs come back disconnected (no connect
  call at launch — a guard on the launch path).

## Order, if approved

1. `TabRegistry` + `TabsViewModel` on ids; move between models (Core/App
   tests, no windows yet).
2. Second window scene + "Move to New Window" + last-window rule.
3. Cross-window drag.
4. Sticky toggle.
5. Restoration setting.

## Decided already, so not open

Window type (full), sticky meaning (above all), two-way drag with
closing empties, restoration as a setting defaulting to off and
restoring windows without connections.
