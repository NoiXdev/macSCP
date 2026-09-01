# M11k — Search in the file list (Design)

Date: 2026-07-30 · Status: approved by the maintainer (both toggleable,
regex, ⌘F)

## Goal

Search within the currently loaded directory listing: either **filter**
(show only matches) or **jump to the match** (list stays full, selection
moves), toggleable; optionally as a regular expression. Field on ⌘F, Esc
closes.

## Boundary (important)

The search acts **only on the currently loaded list** of a pane — no
recursive walk through the tree, no additional server requests. The match
count ("12 of 431") refers to the entries of the current directory (after
the hidden-file filter). Recursive search would be its own, much larger
milestone.

## Starting point

- `RemoteBrowserViewModel.load()`/`refreshQuietly()` build `items` via
  `displayItems(from:)` = hidden filter + sorting. `items` IS the displayed
  list; there is no separate "full" list today.
- The file list is the `NSTableView` from M11j; selection runs through
  `onSelect`/`viewModel.selectedItems`.
- ⌘F is currently unassigned. M11j has a **focus-scoped**
  `performKeyEquivalent` in `KeyboardDrivenTableView` — the ideal place to
  route ⌘F to the FOCUSED pane.

## 1. Pure matcher (Core)

`FileSearchMatcher` (pure, testable):

- `compile(query:isRegex:) -> Result<Predicate, FileSearchError>`:
  - empty/blank query ⇒ "everything matches" (no filter).
  - `isRegex == false`: case-insensitive **substring** match on the file
    name.
  - `isRegex == true`: `NSRegularExpression` (case-insensitive), a partial
    match in the name counts. An **invalid** expression ⇒
    `.failure(.invalidRegex)` — its own case, NOT "no matches".
- `matches(name:) -> Bool` against the compiled predicate.

Why compile-then-apply: the regular expression is checked/built ONCE, not
per row; and the invalid case is cleanly separated from the empty-match
case (the maintainer explicitly asked for its own, honest error display).

## 2. Search state in the ViewModel

Additive, without breaking the existing meaning of `items`:

- New stored base `displayedAll: [RemoteFileItem]` = the result of
  `displayItems(from:)` BEFORE the search (hidden-filtered, sorted).
  `load()`/`refreshQuietly()` set it; the search derives from it.
- `searchQuery: String`, `searchIsRegex: Bool`,
  `searchMode: SearchMode` (`.filter` / `.jump`).
- Derived:
  - **Filter mode:** `items` = `displayedAll` ∩ matcher; additionally
    `searchMatchCount` and `searchTotalCount` for "N of M".
  - **Jump mode:** `items` = `displayedAll` (full); a
    `searchMatchPaths`/`currentMatchIndex` that sets the selection to the
    next match (Enter/"next" iterates, wraps at the end).
  - **Invalid regex:** `items` stays unchanged (do not clear it!) and a
    `searchError` is set — the UI shows it instead of pretending "0
    matches".
- Re-derive on every change of query/mode/regex toggle. `load()` on a new
  directory **resets the search** (empty query) — a filter from the old
  folder must not silently hide the new one.
- `refreshQuietly()` keeps the active search state (it's the same folder),
  applies it to the fresh list.

The derivation (query+mode+list ⇒ visible items / match indices / error)
is a **pure, testable** function; the VM only calls it.

## 3. Interaction (App)

- **⌘F** opens a search field over the file list of the FOCUSED pane —
  routed through the focus-scoped `performKeyEquivalent` from M11j (only
  the focused table reacts). Focus moves into the field.
- The field contains: the text field, a **mode toggle** (Filter / Jump), a
  **regex toggle** (`.*`), and the match count on the right ("12 of 431").
  On an invalid regex, a concrete red message replaces the count.
- **Jump mode:** Enter sets the selection to the next match, ⇧Enter to the
  previous one, with wraparound. The match count shows "Match k/N".
- **Esc** closes the field, clears the search and shows everything again;
  focus returns to the table.
- The field is **per pane** (each pane searches its own list); the state
  hangs off the respective ViewModel/tab, so it does not survive a tab
  switch as global state.
- The table's type-select (M11j) stays untouched — the search field is its
  own focus target.

## 4. Honest errors

- Invalid regular expression: its own red message in the search field, the
  list stays as it was (no pretend "no matches").
- No match on a VALID search: "0 of M" resp. "no matches" — that is a
  legitimate result, not an error message.

## 5. Deliberately NOT in M11k

- No recursive/server-side search beyond the current directory.
- No search history, no saved searches.
- No replace/bulk-rename over matches.
- No search over size/date/permissions — name only.
- No audit entry (search is pure display).

## 6. Tests

- **Matcher (Core):** empty query ⇒ everything; case-insensitive substring;
  valid regex (partial match, anchors `^`/`$`, `\.log$`); INVALID regex ⇒
  `.invalidRegex` (not "no matches"); Unicode/umlaut in the name.
- **Derivation (Core/VM-adjacent):** filter mode reduces `items` and
  returns N/M; jump mode leaves `items` full and returns match indices +
  wraparound forward/backward; invalid regex leaves `items` as is and sets
  the error; `load()` on a new directory resets the search;
  `refreshQuietly()` keeps it and applies it to the fresh list; selection
  in jump mode points at the expected path.
- EN/DE catalogs: identical key sets.
- The AppKit/SwiftUI field wiring has no test target → smoke test.

## 7. Breakdown

T1 Core (`FileSearchMatcher` + pure derivation + VM search state, with
tests) → T2 App (search field, mode/regex toggle, match count/error, ⌘F via
the M11j focus path, Esc, EN/DE) → T3 wrap-up. NO release.
