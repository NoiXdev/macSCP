# P3d — Closing: the snippet picker in the terminal goes flat

Completed 2026-08-18. Three substantive commits:

```
dd7941c feat(app): project the snippet model into a flat list
43acfbc feat(app): offer insert, run and cancel in one window
daf5c38 feat(app): flatten the terminal snippet picker
```

## Usability, not a security fix

This phase does not fix a hole. The popover picker **never** had a
"one click executes": every row was already a submenu with "Insert" and
"Execute" before this rework — built that way in round 2 for exactly that
reason. The actual maintainer finding was the submenus themselves —
opening, sliding sideways, aiming, uncomfortable in the narrow popover.
What changes is the path to the action, not whether an action can be
triggered incidentally.

## How the model and the presentation split

`SnippetMenuModel` remains the single source for all four trigger surfaces
(popover, right-click in the terminal, host context menu, menu bar). Three
of those are real menus and continue to render `SnippetMenuItems` —
**byte-unchanged** through this phase, verified by an empty diff on all
three files. Only the popover gets a second projection:
`SnippetListPlan.build(model:)` (`Sources/macSCPCore/Terminal/SnippetListPlan.swift`,
Task 1), a pure computation with no SwiftUI dependency, hence in Core
instead of next to `SnippetMenuPlan` in `MacSCPAppKit`.

## Each snippet once instead of twice

`SnippetMenuPlan` deliberately duplicates a snippet with two tags — the two
occurrences there sit in two different submenus, of which both are never
visible at the same time. A flat, continuously visible list has no such
submenu boundary: the same name twice in the same area would look like a
bug, not like grouping, and would undermine arrow-key navigation — exactly
the reason a plain click only selects. `SnippetListPlan.build` therefore
shows each snippet **at most once**, under the first section that would
otherwise have produced it; a subsequent section left completely empty by
this is dropped entirely.

## The action sheet and its keyboard shortcuts

Double-clicking a row opens `SnippetActionSheet`
(`Sources/MacSCPAppKit/SnippetActionSheet.swift`, Task 2): name, command in
plain text (`.textSelection(.enabled)`, monospaced), three actions.

- **Esc** cancels (`role: .cancel`).
- **Return** sits on **"Insert"** (`.keyboardShortcut(.defaultAction)`).
- **⌘Return** executes (`.keyboardShortcut(.return, modifiers: .command)`).

Rationale: Return triggers the default button in a macOS dialog. If it sat
on "Execute", a double-click plus Return would start a command on a remote
machine with two keystrokes — more incidental than the old path through the
submenu, even though this rework is meant to achieve the opposite. A new,
deliberately narrow source-text scan guard
(`SnippetActionSheetKeyboardShortcutGuardTests`) pins the mapping; verified
live by test-moving `.defaultAction` onto Execute, which made both central
tests fail.

## ⌃⌘n: nothing lost

The Task 4 brief claimed the popover would lose ⌃⌘n through the rework.
That is refuted: `SnippetMenuItems.shortcutOrder` defaults to `[]`, and
**only** `MacSCPApp.swift` (the menu bar) passes the real store order.
`SessionSidebar.swift` and the old `ContentView+Detail.swift` never did —
the shortcut lives exclusively on the menu bar, as a globally registered
`NSMenuItem`, regardless of whether a popover is open. The flat list has no
buttons left anyway for a `.keyboardShortcut` to attach to (rows are `Text`
+ gestures). Nothing was lost, because nothing was there before.

## The three paths in the popover (Task 3)

- **Right-click on the row** → Execute, Insert, Preview — the fast path,
  one gesture, no window. "Preview" pins the row into the same fixed
  command line that also appears on hover, instead of opening a second
  window — costs no new file, no new window state.
- **Double-click** → `SnippetActionSheet` with the clicked snippet.
- **Hover** → the command appears in a fixed line at the bottom of the
  popover (always present, with hint text absent hover/pin, otherwise the
  popover height would jump on every change), truncated rather than
  wrapped.
- **A plain click only selects**, triggers nothing — a prerequisite for
  arrow-key operation. The gesture behind it
  (`TapGesture(...).exclusively(before:)`) is not testable without a
  rendering harness; a ninth source-scan guard was deliberately not built,
  because the risky property sits inside a multi-line, nested gesture
  composition that a line-based scanner cannot reliably capture against a
  stable pattern — it would deliver false confidence instead of real
  protection.

## GUI: not launched

The app was **not** launched during this phase. For the maintainer, for
manual verification — the complete list:

- The popover shows a flat list with no submenus; tag headers remain as
  grouping.
- Right-clicking a row opens a context menu with Execute, Insert, Preview.
- Double-clicking opens the action sheet with the command in plain text and
  the three buttons Insert/Execute/Cancel.
- In the action sheet: Esc cancels, Return inserts, ⌘Return executes.
- Hovering a row shows the command in the fixed line at the bottom of the
  popover, not as a tooltip.
- A locked row (not connected / backend without a shell) is visibly
  disabled.
- The menu bar and right-click in the terminal still show the old submenus
  with Insert/Execute — unchanged.

## Measurement

```
swift test    → 2097 tests in 181 suites, all green
```

Starting point before this phase (Task 1 start): 2076/178. Growth across
the three tasks: 11 tests (Task 1, `SnippetListPlan`) + 6 tests (Task 2,
`SnippetActionSheetKeyboardShortcutGuardTests`) + 4 tests (Task 3,
`SnippetPreviewLine`) = 21 new tests, matching 2076 → 2097.

```
plutil -lint  → all *.strings catalogues OK (all four languages)
```

## Build verification (`scripts/package-app`, started in the background)

```
lipo -archs dist/macSCP.app/Contents/MacOS/macSCP      → x86_64 arm64
lipo -archs dist/macSCP.app/Contents/MacOS/macscp-cli  → x86_64 arm64
Resources/*.bundle                                      → macSCP_MacSCPAppKit.bundle, macSCP_macSCPCore.bundle
Resources/*.lproj                                        → de, en, fr, pl (all four)
plutil -lint Info.plist                                  → OK
UTExportedTypeDeclarations                                → 3 (dev.noix.macscp.sessions, .logins, .snippets)
```

The app was **not** launched; `scripts/release` was not run.

## Brief errors

Two of the coordinator's own brief errors, both refuted by the respective
tasks against the code itself:

- **Task 3:** the brief claimed the popover would lose ⌃⌘n through the
  rework. It never had the shortcut — see above.
- **Task 3:** the brief quoted "seven source-text scan guards, an eighth
  only with justification" from the parent plan. Task 2 had already built
  an eighth one; the starting point for Task 3 was eight, not seven. The
  plan text was written before Task 2 and had not been updated since.

All other cited facts in the three task briefs (starting counts,
`SnippetMenuModel`/`SnippetMenuPlan` structure, the menu projection's
duplication rule) matched the code.

## Fix round after closing

Two follow-up corrections to the already-closed phase state, before the
whole-branch review.

**Fix 1 (context menu untested).** The per-row `.contextMenu` in
`snippetRow(_:)` (`Sources/MacSCPAppKit/ContentView+Detail.swift`) had no
test, even though the technique for it already exists in the project:
`Tests/macSCPAppKitTests/TerminalContextMenuTests.swift` renders a SwiftUI
menu body via `NSHostingMenu` into a real `NSMenu` and checks its
structure — used so far only for `SnippetMenuItems`. The menu content was
pulled out of the closure into its own type, `SnippetRowContextMenu`
(`View`, three buttons: Execute/Insert gated on `!row.isDisabled`, Preview
ungated), so `NSHostingMenu` can render it directly, without the row
gestures or the popover around it. Three new tests in
`TerminalContextMenuTests`: an enabled row offers Execute/Insert/Preview; a
disabled row offers only Preview; each menu item reaches its own closure.
Mutation verified: test-removing the `!row.isDisabled` gate (only
Execute/Insert/Preview with no condition) made the disabled-row test fail
(expected `["Preview"]`, got `["Execute", "Insert", "Preview"]`); gate
restored, green again. Side finding: `snippetPopover`'s own doc comment
claimed "the context menu entries" were unobservable — that stopped being
true as of this fix round and was corrected.

**Fix 2 (stale hover row, MINOR).** `hoveredRow` was not cleared when a
search filters a currently hovered row out of the list — `onHover`'s
`else` branch only fires while the row view still exists, and a filtered-
out row never gets that chance. The local `let sections = ...` block in
`snippetPopover` was pulled into a private method
`filteredSections(text:isRegex:)` (same pipeline: search predicate →
`TerminalSnippetSearch.matching` → `SnippetMenuModel.build` →
`SnippetListPlan.build`), so a second call site —
`clearHoveredRowIfFilteredOut()` — can invoke it again without
duplication. Two `.onChange` modifiers (`searchText`, `searchIsRegex`)
call this method; it clears `hoveredRow` if its row no longer occurs in the
newly computed `sections`. Deliberately NO second state field (e.g. an
"isStale" flag) — the direction was to fix it at the point where the
filter is computed, not with a second piece of state alongside it.

**Two checks before the commit:**
- Would a new test stay green against a constant? No, for Fix 1: a stub
  that always shows all three entries fails the disabled test; a stub that
  always shows only Preview fails the enabled test; no-op closures fail the
  wiring test.
- Which claim in the doc comment is unobserved by any test? All of Fix 2:
  clearing `hoveredRow` on filtering is SwiftUI view state with no
  rendering harness — the same boundary already documented multiple times
  in this project, as with `TerminalPanelHeader.body`, the gesture split,
  and the row selection highlight. `clearHoveredRowIfFilteredOut()`'s doc
  comment claims the behavior correctly, but unverified.

**Measurement:** starting point 2097 tests / 181 suites (self-measured,
matches the ledger). After Fix 1 (+3 tests): 2100/181. Fix 2 adds no tests
(rationale above). Final: **2100 tests in 181 suites, all green.**

Commits: see the ledger entry and the git log for this fix round.
