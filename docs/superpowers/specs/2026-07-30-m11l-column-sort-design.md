# M11l — Sorting by column click (Design)

Date: 2026-07-30 · Status: approved by the maintainer ("works as is")

## Goal

Sort the file list by name, size or modification date — clicking the
column header selects the key, clicking again reverses the direction.

## Starting point

- `RemoteBrowserViewModel.sortedForDisplay(_:)` is today the ONLY
  sorting authority: folders first, then name case-insensitive. No backend
  sorts. Called in `displayItems(from:)` (after the hidden-file filter,
  before the M11k search).
- The table (`RemoteFileTableView`) has three columns `name`/`size`/
  `modified` with `PolishedHeaderCell`; today the headers don't
  react to clicks (no `sortDescriptors`).

## 1. Parameterize the sorting authority (Core)

- New type `FileSortKey: Sendable` (`.name` / `.size` / `.modified`).
- `sortedForDisplay(_:key:ascending:)`:
  - **Folders always stay first** (grouping, independent of the key):
    folders don't carry a size and this grouping is today's behavior;
    mixing them into the file sort would be a silent
    behavior change and meaningless for size. Within each group (folders,
    non-folders), sorting follows the key.
  - `.name`: `localizedCaseInsensitiveCompare` (as today).
  - `.size`: numeric by byte size; a missing size (e.g. within the
    folder group internally) deterministically goes to the end of the
    secondary ordering, then name as the tiebreaker.
  - `.modified`: by timestamp; a missing timestamp deterministic,
    name as the tiebreaker.
  - `ascending == false` reverses the order WITHIN the groups — the
    folders-first grouping stays (folders stay on top even descending).
  - The name tiebreaker makes the sort **stable/deterministic**
    (same size/same date ⇒ always the same order).
- The existing call with no parameters stays with the default `.name`
  ascending (default arguments), so nothing else breaks.

## 2. Sort state in the view model

- `sortKey: FileSortKey = .name`, `sortAscending: Bool = true`
  (`@Observable`, `didSet` → re-derive `displayItems` as with search).
- `displayItems(from:)` passes `sortKey`/`sortAscending` through to
  `sortedForDisplay`. That way `load`, `refreshQuietly` AND the
  M11k search (which builds `displayedAll` from it) sort consistently
  by the same state.
- The sort state survives `refreshQuietly` and directory changes
  (it is a display preference of the pane, not a directory attribute) —
  unlike search, which resets on a change.

## 3. Operation (App)

- The three columns get `sortDescriptorPrototype`s
  (`name`/`size`/`modified`); the table reports clicks via
  `tableView(_:sortDescriptorsDidChange:)` to the coordinator.
- Clicking a header: if it's a DIFFERENT column, it becomes the
  sort key (default direction: name/date ascending, size
  descending — largest first is what's expected); if it's the ACTIVE
  column, only the direction flips.
- The active column shows the native sort triangle (▲/▼) — AppKit does
  this via the set `sortDescriptor`; `PolishedHeaderCell` must draw the
  indicator through (check that the M5g header look is preserved
  and the triangle is visible).
- The actual sorting is NOT done by AppKit on the NSTableView rows,
  but by the view model (the order comes from `items`) — the
  `sortDescriptorsDidChange` only sets `viewModel.sortKey`/`sortAscending`,
  and the new `items` order flows back through the existing
  reload/reconcile mechanism. This way the sorting authority stays in
  ONE place (Core), and search/filter/sort compose without conflicts.
- Both panes independent (state on their respective view model).

## 4. Deliberately NOT in M11l

- No "mix folders in" option (folders stay on top; possibly later
  as a setting).
- No sorting by permissions/owner (those columns don't exist yet —
  that's the next request; when they come, they get their
  `FileSortKey` case).
- No persisting the sort state across App restarts (a display
  preference per session; a later settings topic).
- No audit entry.

## 5. Tests

- `sortedForDisplay(key:ascending:)` (pure, Core): folders-first for every
  key and in both directions; `.name` up/down; `.size` numeric
  (not lexicographic — "9" before "10" only with a numeric comparison);
  `.modified` up/down; name tiebreaker with equal size/equal date
  (stability); missing size/missing date deterministic.
- VM: setting `sortKey`/`sortAscending` re-orders `items`; survives
  `refreshQuietly` and `load` on a new directory; works together with
  an active M11k filter (the filtered list is sorted).
- The AppKit header binding has no test target → smoke.

## 6. Breakdown

T1 Core (parameterized `sortedForDisplay` + VM sort state, with tests)
→ T2 App (column `sortDescriptor`s, click handler, triangle indicator,
both panes) → T3 wrap-up. NO release.
