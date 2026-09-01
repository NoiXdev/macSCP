# M9c — Auto-refresh of the remote panes (design)

Date: 2026-07-28 · Status: approved by the maintainer

## Goal

The remote pane of the ACTIVE tab refreshes automatically every X
seconds — quietly (no spinner, no lock, selection stays), configurable in
Settings.

**Maintainer decisions (2026-07-28):**

1. Scope: ONLY the remote pane of the active tab. Background tabs do not
   poll; on tab switch, the newly active tab takes over (timer starts
   fresh). The local pane is left out.
2. Settings: tab "Allgemein" — toggle "Remote-Ansicht automatisch
   aktualisieren" (default ON) + interval in seconds (default 5, clamped
   to 2–300).
3. Architecture: approach A — quiet refresh in the Core VM
   (`refreshQuietly()`), timer as `.task` in the detail tree of the
   active tab (lives/dies with the `.id(tab.id)` identity from M8a).

## 1. Core: `RemoteBrowserViewModel.refreshQuietly()`

- Lists the current directory in the background and replaces `items`
  (SAME display filter for hidden files and SAME sorting as `load()` —
  a shared private preparation function, no duplicated filter/sort).
- State stays UNCHANGED `.loaded`: no `.loading` flicker, no spinner, no
  hit-test lock.
- Selection pruning: `selectedItems` is reduced to the entries whose path
  still occurs in the NEW, FILTERED list (this closes the open M7a
  backlog item "selection-across-refresh preservation must respect the
  hidden filter"). AppKit reconciliation (M7a) handles the display.
- Errors are swallowed SILENTLY: no state change, no message — a dead
  server does not produce an error screen every five seconds; any manual
  action makes real problems visible. If the quiet refresh runs while
  state is not `.loaded` (e.g. a parallel `load()` or `.failed`), it
  returns immediately and silently (guard at the start AND before
  writing items — a state change started during the listing wins).
- No effect on open sheets/menus/transfers: dialogs hold value snapshots
  (the established notFound flow), the context menu captures the
  selection by value (M7b), the queue is independent.

## 2. Settings (Core + App)

- `SettingsStore` (forward-compatible as before):
  `autoRefreshEnabled: Bool` (default `true`),
  `autoRefreshIntervalSeconds: Int` (default `5`, clamped to `2...300` on
  set; stored values outside the range are clamped on read).
- Settings UI, tab "Allgemein": toggle "Auto-refresh remote view"/„
  Remote-Ansicht automatisch aktualisieren" + number field "Every n
  seconds"/„Alle n Sekunden" (active only while the toggle is on). Keys
  EN/DE.

## 3. App: timer in the active tab

- In the active tab's detail tree (within the `.id(tab.id)` identity)
  hangs a `.task` that loops `Task.sleep` over the current interval and
  then calls `refreshQuietly()`, as long as: toggle on AND tab connected
  AND remote state `.loaded`. Skipped ticks simply keep sleeping.
- Settings changes take effect live (the loop reads toggle/interval fresh
  on every pass); switching or disconnecting a tab ends the task
  automatically (SwiftUI task lifecycle + `.id` remount from M8a).
- No timer for background tabs, the local pane, or form tabs.

## 4. Tests

- VM (`refreshQuietly`): state stays `.loaded` (no observable flicker
  intermediate value), items updated with filter+sorting, selection
  pruned to existing + visible paths (including the "file was hidden"
  case), errors silent (state and items unchanged), guard on
  non-`.loaded` (immediate silent return).
- SettingsStore: defaults, clamping 2–300 (set AND read), round trip,
  forward compatibility with an old settings.json.
- Timer + Settings UI: visual smoke (T3).

## 5. Deliberately NOT in M9c

- No polling for background tabs or the local pane (locally, FS events
  would be the right tool — a separate topic).
- No per-host setting (global suffices).
- No visible "last refreshed" indicator.
