# Detachable, Optionally Sticky Tabs — Design

**Status:** brainstormed with the maintainer on 2026-09-02/03 (four
questions, answered below); **awaiting the maintainer's read of this
document** before the plan. From item 17 of
`2026-09-02-backlog-maintainer-notes.md`.

**Implemented 2026-09-05**
(`docs/superpowers/plans/2026-09-03-detachable-tabs.md`, six tasks; see
`docs/BACKLOG.md`'s "Detachable, optionally sticky tabs" row for the full
commit list and sight checks). All four decisions below shipped as
written, with four deviations measured along the way: **detaching by
dragging a tab out and dropping it on the desktop was not built** —
SwiftUI's only drag-ended callback is a macOS 26 API and this package
targets macOS 15, so detach stays a menu action only (its own open
`docs/BACKLOG.md` row, "drop outside is detach"); **a restoration seed is
consumed the moment its window appears**, never re-read, so a seed is a
one-shot description rather than a value SwiftUI keeps synchronised with
the window; and **a tab moved into a window of its own can be
permanently parked** if that window never appears — SwiftUI reports no
`openWindow(value:)` failure, so there is no signal to reclaim it early,
and it is torn down only when its source window closes or the app quits;
and **the restoration file is written once, at quit, from the windows
still open** rather than by each window as it closes (Task 5 fix round
1) — the "Restoration" section below still says "written on close",
which is what was designed and is not what shipped: ⌘Q closes no
windows, so a close-path write described every window the user had
deliberately shut and none of the ones on screen at the end.
`AppDelegate.applicationWillTerminate` asks
`TabRegistry.describeAllWindows()` and replaces the file. The same round
also replaced the restored tab's `beginEditing` prefill with a per-tab
pointer at the session, so the tab comes back showing that session's
`SessionOverviewView` (Connect / Edit / Diagnose) instead of an edit form
offering "Save & connect" for a session that is already saved.

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
- **Measured 2026-09-05 (Task 3): the drop-outside half was NOT built
  then, because macOS 15 offers no SwiftUI hook that reports it. It was
  built on 2026-09-05, the same day, on a maintainer report — the AppKit
  route this note names below is the one that shipped.** What was read,
  in the macOS 26.5 SDK, against this package's `platforms:
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
    racing the same mouse-down. (Corrected 2026-09-05: this paragraph
    also claimed the existing wiring guard would fail such an overlay "by
    count". It would not — the guard counted `.draggable(`, and an AppKit
    overlay adds none. The reason above is the whole reason. The guard
    now counts the AppKit source positively and `.draggable(` negatively
    beside it, which is the shape that WOULD have noticed.)

  **What was built, 2026-09-05, when the maintainer reported that
  dragging a tab out wrote a file on the Desktop and opened no window.**
  Both halves of that report were one cause — the drag carried a
  `String`:

  - `TabDragPayload` is `Transferable` over
    `UTType(exportedAs: "dev.noix.macscp.tab")`, declared in
    `scripts/package-app` as conforming to `public.data` with no text
    conformance and no filename extension. A `String` payload exports
    `public.utf8-plain-text`, which the Finder accepts by writing a text
    clipping; this exports one private type, which nothing outside the
    app imports and which names no file to write.
  - The tab's drag source is `TabDragSourceView`, an
    `NSViewRepresentable` over the tab's label (not over its ✕: an
    `NSView` that answers `hitTest` takes the event outright, and a
    button underneath one stops working). Its `NSView` answers `hitTest`
    only for an UNMODIFIED left-button event of the three types it
    handles, so both ways of opening the tab's SwiftUI `.contextMenu`
    pass through to the SwiftUI content — the right-click and the
    control-click, which macOS delivers as a `.leftMouseDown` carrying
    `.control` (fix round 1) — and so do the moves that drive
    `.onHover`; a left press that never crosses a 3 pt threshold is
    forwarded to the same `onActivate` the tab's tap gesture calls. It
    accepts the first mouse, so a drag from a background window's tab
    costs one gesture rather than two.
  - It offers `[.move, .copy]` within the application and `[]` outside
    it. Outside: no other app can accept the drop whatever it makes of
    the pasteboard type — the source's own half of the Finder fix,
    beside the type's. Within: the mask is the set a destination may
    CHOOSE from, and SwiftUI's `dropDestination` negotiates its own
    operation and has historically asked for `.copy`, so `.move` alone
    could be refused by one of our own strips (fix round 1). The tab is
    always moved whichever is picked — `TabDetachSequence` is what runs.
  - `draggingSession(_:endedAt:operation:)` asks `TabDropOutsidePlan`:
    an empty operation AND a point inside NONE of the app's own windows
    is "this landed nowhere", and calls `ContentView.moveToNewWindow(_:)`
    — the same path the tab context menu and the Window menu take. The
    second condition started as "outside the source window's frame",
    which detached a tab dropped on another of our windows' file list or
    terminal into a third window (fix round 2). Which windows count is
    `TabDropWindowFrames.ours(_:)`: visible, on the active Space, not a
    panel — the Space check because `isVisible` is `true` for a window
    on another Space, and a second window left full-screen there would
    otherwise cover every point on the desktop (fix round 3). The
    condition still keeps a drop into the strip's own blank area the
    no-op it has always been.
  - The drop destination reads `TabDragPayload.self` instead of
    `String.self`. The in-strip reorder and the cross-window move are
    unchanged in behaviour; what changed is that text, files and the
    sidebar's own row payload now reach no closure at all.
  - Accepted limits: an Escape-cancelled drag also ends with an empty
    operation and AppKit reports no reason, so cancelling over the
    desktop or over another application's window detaches, while
    cancelling over any window of ours does not; and the new window
    opens where SwiftUI puts it, since `openWindow(value:)` takes no
    frame and a position hint through `WindowSeed` was scoped out.

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
  Since the drag-detach fix: the payload declares exactly one content
  type (its own) and the pasteboard writer offers exactly that one; the
  bundle declares the same identifier with no text conformance and no
  filename extension; `TabDropOutsidePlan` answers the detach question
  over both its facts, and `TabDropWindowFrames.ours(_:)` over its four,
  each exclusion with a positive beside it; `TabDragHitTestDecision`
  and `TabDragOperationMask` answer what the overlay claims and what it
  offers; and a source guard holds the strip to the AppKit drag source
  with `.draggable(` counted at zero beside it.
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
