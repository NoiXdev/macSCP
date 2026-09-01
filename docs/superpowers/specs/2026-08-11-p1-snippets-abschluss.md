# P1 — close-out report (snippets reachable)

**Status:** completed 2026-08-11. HEAD before this report: `df081be`.

Nine tasks: four on the Core model (flag out, tags in, bytes, suggestion
list, `SnippetMenuModel`), five on the App (management sheet, menu bar,
host context menu, terminal header, right-click), plus this close-out.
Spec: `2026-08-10-snippets-runde-2-design.md`, section "P1". Plan:
`../plans/2026-08-11-p1-snippets-erreichbar.md`. Ledger:
`.superpowers/sdd/2026-08-11-p1-snippets-erreichbar/progress.md`.

## Commits

Plan base: `7247685` (planning doc, last commit before Task 1).

| Commit | Content |
|---|---|
| `7247685` | Plan (= base) |
| `e9b52ac` | Task 1 — model: `runsImmediately` out, `tags` in |
| `2cede3e` | Task 2 — `SnippetKeystrokes.bytes(for:execute:)` |
| `a7cc2b4` / `a346516` | Task 3 — suggestion list, fix round (case-insensitive exclude/count unpinned) |
| `942ce69` / `82876b3` | Task 4 — `SnippetMenuModel`, fix round (sort order unpinned) |
| `18b0741` / `f63d124` | Task 5 — management sheet: checkbox out, tag field + filter, fix round (dead L10n key, highlight clamp unpinned) |
| `f60ffc5` / `371c2bb` | Task 6 — menu bar onto the model, fix round (shortcut guard for Execute) |
| `62c9cf6` | Task 7 — context menu on the host |
| `2d59a30` | Task 8 — terminal header with popover |
| `df081be` | Task 9 — right-click in the terminal |

**Unpushed:** `git rev-list --count origin/develop..develop` → **47**
before this report commit. **Release backlog:**
`git rev-list --count origin/main..develop` → **457**.

## 1. Measured numbers

Not copied from the plan or the brief. The before number was re-measured
in this session in a dedicated `git worktree` on the plan's base commit
(`7247685`), and the worktree removed afterward; the after number in the
main tree on `df081be`.

| | before (`7247685`, isolated worktree) | after (`df081be`, this tree) |
|---|---|---|
| `swift test` | **1786 tests / 150 suites, green** | **1880 tests / 159 suites, green** |

Growth: **+94 tests, +9 suites**, spread across the nine tasks
(traceable before and after each task's own fix round from the task
reports): 1786→1792 (T1, +6) →1795 (T2, +3) →1801 (T3, +6, new suite
`SnippetTagSuggestionsTests`) →1803 (T3 fix, +2) →1811 (T4, +8, new suite
`SnippetMenuModelTests`) →1814 (T4 fix, +3) →1837 (T5, +23, new suite
`SnippetTagFieldTests`) →1843 (T5 fix, +6) →1853 (T6, +10, new suite
`SnippetMenuItemsTests`) →1859 (T6 fix, +6, new suite
`SnippetMenuItemsKeyboardShortcutGuardTests`) →1865 (T7, +6, new suite
`SessionRowSnippetMenuPlanTests`) →1871 (T8, +6, new suite
`TerminalSnippetSearchTests`) →1880 (T9, +9, new suite
`TerminalContextMenuTests`). No existing test changed status during this
phase.

**Catalog guard, eight catalogs.** The project has no `.xcstrings` files
(`git ls-files '*.xcstrings'` → empty) — localization runs through
classic `Localizable.strings`, four languages each (en/de/fr/pl) in two
resource directories (`Sources/MacSCPAppKit/Resources`,
`Sources/macSCPCore/Resources`), making eight files. `plutil -lint` on
all eight: **`OK`**, without exception. `LocalizableStringsTests` (the
existing guard for key-set parity across the four languages per layer)
stayed green on every task — no L10n key was forgotten in any language.

## 2. The dev build

```
MACSCP_VERSION="1.2.0-dev" MACSCP_BUILD="$(git rev-list --count HEAD)" ./scripts/package-app
```

| Run | Result |
|---|---|
| `swift build -c release --triple arm64-apple-macosx` + `--triple x86_64-apple-macosx` | `Build complete!` (twice, once per architecture) |
| `lipo -archs` on `dist/macSCP.app/Contents/MacOS/macSCP` | `x86_64 arm64` |
| `lipo -archs` on `dist/macSCP.app/Contents/MacOS/macscp-cli` | `x86_64 arm64` |
| Resource bundles | `macSCP_MacSCPAppKit.bundle`, `macSCP_macSCPCore.bundle` — both present |
| `en/de/fr/pl.lproj` markers under `Contents/Resources` | all four present |
| `plutil -lint dist/macSCP.app/Contents/Info.plist` | `OK` |
| `CFBundleShortVersionString` / `CFBundleVersion` | `1.2.0-dev` / `925` — `925` matches `git rev-list --count HEAD` on `df081be` |
| `scripts/release` | **not run** (published) |
| GUI | **not started** |

The build ran once, in the background, while the test measurements were
running; no commit was added afterward that could make it stale.

## 3. The spec's success criteria, one by one

| # | Criterion | Evidence | Result |
|---|---|---|---|
| 1 | A `snippets.json` from round 1 loads; `runsImmediately` disappears, `tags` empty | **Test** | `aRoundOneStoreFileLoadsWithoutTags` (Task 1) |
| 2 | Inserting never appends a line ending, executing exactly one (`0x0D`) | **Test** | `insertingNeverAppendsATerminator`, `executingAppendsExactlyOneCarriageReturn`, `theTwoCallsDifferByTheTerminatorAlone` (Task 2) |
| 3 | Tag trimmed, empty rejected, exact duplicates dropped, case preserved | **Test** | `SnippetTests` (Task 1), including the case of a hand-edited file |
| 4 | Suggestion list finds `Docker` on typing `doc` | **Test** | `aLowercasePrefixFindsADifferentlyCasedTag` (Task 3) |
| 5 | `SnippetMenuModel` groups by tags, untagged last, provides a disabled reason | **Test** | `SnippetMenuModelTests`, 11 tests after the fix round (Task 4) |
| 6 | An unreadable store does not look like an empty one | **Test** | `SnippetsLoad` unchanged, existing test stays green |
| 7 | All four trigger surfaces show the same entries | **Review — evidence in code** | all four render `SnippetMenuItems` via the same `SnippetMenuModel`; see section 4 |
| 8 | Without a connected session or without a shell, entries are disabled | **Review** | app-side wiring (`!isActiveTabConnected \|\| !activeTabSupportsShell` resp. `BackendDescriptor…supportsShell`), the drawing itself unchecked |
| 9 | P0 changes no behavior | **Test + build per step** | concerns P0, not this phase — already covered in the P0 close-out report |
| 10 | All four catalogs carry the new keys | **Test + `plutil -lint`** | `LocalizableStringsTests` green, eight catalogs `OK` (section 1) |
| 11 | The shortcuts catalog names the shortcuts correctly | **Review** | `KeyboardShortcutsCatalog.swift`: entry "Insert snippet 1–3" / `⌃⌘1–3`, no Execute shortcut claimed — see section 4 |
| 12 | PV ends with a runnable example test or a proven no | **Test** | concerns PV, not this phase — already covered in the PV/P0 close-out report |

Criteria 7, 8 and 11 are **review points, not tests** — as the spec
itself prescribes. The distinction is not blurred here: "provable in
code" (7) means all four surfaces instantiate the same type, not that a
test checks the rendering; "review" (8, 11) means read, not run.

## 4. The evidence for criterion 7 — one model, four surfaces

`SnippetMenuModel.build(snippets:isConnected:supportsShell:)` (Core) is
the single place that decides: grouping by tag, untagged last, the
disabled reason. Precedence when both `!isConnected` and
`!supportsShell` hold: `backendHasNoShell` wins, documented and pinned in
`SnippetMenuModel.swift` — being shell-less is a permanent backend
property, "not connected" would falsely promise that connecting fixes
the problem.

All four surfaces instantiate `SnippetMenuItems` (App, `SnippetMenuItems.swift`)
via this one `SnippetMenuModel` — none has its own copy of the menu
logic:

| Surface | File | Calls |
|---|---|---|
| "Terminal" menu bar | `MacSCPApp.swift` | `SnippetMenuItems` directly |
| Context menu on the host | `SessionSidebar.swift` | `SnippetMenuItems` via `SessionRowSnippetMenuPlan` |
| Terminal header/popover | `ContentView+Detail.swift` | `SnippetMenuItems` with a `TerminalSnippetSearch`-filtered list |
| Right-click in the terminal | `SSHTerminalView.swift` | `SnippetMenuItems` via `NSHostingMenu` |

That is the evidence in code, not a runtime measurement: a change to
`SnippetMenuItems` necessarily affects all four surfaces at once, because
no surface builds its own entries.

**Shortcuts catalog (criterion 11), review.**
`KeyboardShortcutsCatalog.swift` carries the "Snippets" group with one
line: title "Insert snippet 1–3", shortcut `⌃⌘1–3`. The file's header
comment names itself a hand-maintained mirror with no central registry
and explicitly requires that it be kept in step with every shortcut
change. No entry claims an Execute shortcut — on the contrary, the
comment in `MacSCPApp.swift` explicitly explains why Execute never gets
one: a keystroke that runs immediately on a remote host has no good
error case. The actual catalog entry matches the real behavior — checked
by reading, not by a test (there is a different, narrower test for that:
see section 6, `SnippetMenuItemsKeyboardShortcutGuardTests` only protects
that Execute gets no `.keyboardShortcut` *in code*, not that the catalog
text matches it).

## 5. The spec's two "measure, don't assume" points

**Right-click in the terminal (Task 9).** The spec required establishing
whether SwiftTerm's `TerminalView` already claims the right-click, rather
than inferring it from the absence of `rightMouseDown` overrides.
Measured, not inferred, with two independent tests that stayed in the
tree permanently (`TerminalContextMenuTests.swift`):

- **Objective-C runtime, without an instance:** `class_getMethodImplementation`
  for `rightMouseDown(with:)`, `menu(for:)` and the `menu` getter shows:
  the IMP `TerminalView` inherits is `NSView`'s, not overridden, and
  `NSView`'s IMP is in turn genuinely different from `NSResponder`'s
  default.
- **Real instance:** a fresh `TerminalView` has `menu == nil`; after
  `terminal.menu = someMenu`, `terminal.menu(for: event)` returns exactly
  that object (identity); none of the three subviews (`NSScroller`,
  `TerminalProgressBarView`, `CaretView`) intercepts the click.

**Result: the right-click holds.** It displaces nothing — SwiftTerm does
not see the right mouse button at all today (only `mouseDown`/`mouseUp`/
`mouseDragged` are overridden), selection is left-click-only, no built-in
menu exists, no ancestor carries a `.contextMenu`. Wired via
`NSHostingMenu` onto `SnippetMenuItems` — not rebuilt. **What remains
open is a visual check:** that AppKit actually shows the built `NSMenu`
on screen when the user right-clicks needs a real window and a running
modal tracking loop — not checkable in-process without risk of hanging,
and the GUI was not started.

**Terminal panel edge (Task 8).** In `ContentView+Detail.swift`, current
state, re-measured for this report:

- Height of the terminal strip: `.frame(minHeight: 120, idealHeight: 220)`
  at the `terminalPanel(session)` call in `detail`.
- The only inner padding inside `terminalPanel` itself:
  `.padding(.vertical, 8).padding(.horizontal, 14)` on the text block of
  the `.ended` state.

Both values are **deliberately unchanged** — the edge is P2, not P1. The
new header carries its own, new inner padding
(`.padding(.horizontal, 12).padding(.vertical, 6)`), which changes
nothing on the existing area, only adds to it.

## 6. A real shift in what is checkable

Up to Task 9, the honest position of this project was: views in
`MacSCPAppKit` are untested, `SnippetMenuItems`'s body included — Task 6
and 7 had to record that in their own reports ("no view-testing tool in
this project sees AppKit-backed menu content").

`NSHostingMenu` changes that for **this one case**. An `NSHostingMenu`
over `SnippetMenuItems` produces a real `NSMenu` in the test process,
without a window, without a running `NSApplication` — and this `NSMenu`
can be queried: `TerminalContextMenuTests` fires the resulting
`NSMenuItem`s and, in doing so, checks the rendered structure of the
shared component itself, for the first time in this project — submenu
per tag, insert/execute titles per snippet with the localized texts, and
the `execute` flag of every entry, verified by actually firing both
actions and checking the passed-in values (`false`/`true`). The mutation
probe from Task 9 confirms that the suite actually reacts: with the
divider logic and the empty guard removed, 6 of 9 tests went red across
5 cases.

**What this does not change:** `NSHostingMenu` holds only because a menu
is ultimately a flat list of `NSMenuItem`s that AppKit itself builds from
the SwiftUI description — the technique does not carry over to arbitrary
SwiftUI. Layout questions, `TextField`/`Toggle`/table content, popover
positioning, actual drawing: none of that becomes checkable through this
finding. The last step remains unchecked, as named in section 5: that
AppKit truly brings the menu onto the screen when the right mouse button
is actually pressed is a question of the modal tracking loop, not of the
menu structure — that would need a running window.

## 7. The GUI was not started

Explicitly: no `open`, no call that shows a window, in this entire phase.
Everything above rests on `swift test`, `swift build`, the dev build, and
reading source. The following spots are pure visual checks, which sit
with the maintainer:

1. **The tag token field** (`SnippetTagField.swift`) — chips with a
   remove button, the suggestion list while typing with the "create *x*
   as a new tag" entry last, Return/comma/backspace behavior, the
   chip wrapping (`TagFlowLayout`).
2. **The filter row** in the management sheet — "All", one chip per tag
   with count, "no tag", single-value selection.
3. **The terminal header and its popover** — host on the left, snippet
   button on the right, the popover with search field and groups,
   whether it stands out visually from the new header.
4. **The context menu on the host** — the "Snippet" submenu in the
   sidebar, the visible reason "Only available for the active tab" when
   the row is not the active tab.
5. **The right-click in the terminal, which sits one level below
   everything else:** that AppKit actually shows the built `NSMenu` on
   screen. Everything up to this point is measured (section 5); this one
   step is the only one that needs a running window with modal tracking,
   and nobody could establish it without starting the GUI.

## 8. What is carried forward from the ledger — open minor findings

Five entries, none fixed in this phase because each fell outside the
scope of its respective task:

1. **Task 5's orphan-key guard only sees literal keys in
   `Sources/MacSCPAppKit`.** Variable-key call sites
   (`ConnectionFormView`, `SchemaFormView`, ~13 more spots) and Core's
   own catalog sit outside its view. Useful, but not exhaustive — this
   limitation must not be sold as proof of completeness.
2. **`TagFlowLayout`'s line-wrap placement is untested.** Pure SwiftUI,
   pinnable in principle with the pixel harness (`ViewTestabilitySpike`)
   per the PV result — no test was added. A real gap, not a claimed
   impossibility.
3. **Task 6's shortcut guard has two disclosed blind spots.**
   `SnippetMenuItemsKeyboardShortcutGuardTests` is a source-text scan of
   `SnippetMenuItems.swift`: a rename of `insertButton` that includes the
   Execute button would silently keep passing, likewise a modifier
   injected from a different file. The threat model is a local hand-edit
   to exactly this file — documented in its own doc comment.
4. **`SnippetMenuItems` renders a leading `Divider()` by default as soon
   as it has groups.** Sensible in the menu bar (separates it from the
   existing terminal entries above). But TWO surfaces are affected, not
   just one: in the host context-menu submenu (Task 7) it is the first
   line of the submenu, and in the terminal-header popover
   (`TerminalPanelHeader.snippetPopover`, Task 8) `SnippetMenuItems`
   likewise pulls the default `leadingDivider: true` there, so the row
   directly under the search field draws a separator — switchable off in
   principle since Task 9 via the `leadingDivider` parameter (used by
   the right-click), but originally not switched off in EITHER Task 7 OR
   Task 8.
   **Addendum (review fix round, see `final-fix-report.md`):** fixed in
   Task 7's sidebar submenu (`leadingDivider: false`) — there, the
   separator is a pure head artifact, nothing sits above it in this
   submenu. Deliberately NOT touched in Task 8's popover: there, the
   line genuinely separates the search field from the results list, so
   it is not an artifact without a reference point but a plausible
   visual separation — a matter of taste, not one of this phase's three
   established sample answers, therefore left unchanged rather than
   guessed at.
5. **The open visual check from Task 9** (sections 5/7): that AppKit
   really shows the right-click menu.

## 9. What remains open

- The five minor findings from section 8.
- **The maintainer's visual checks** (section 7) — not yet done, GUI not
  started in this phase.
- **The release backlog:** 47 commits ahead of `origin/develop`, 457
  ahead of `origin/main` (section "Commits") — kept growing.
- **P2 from the spec** — terminal version: the now-measured edge
  (section 5) only changes here, plus its own terminal-tab type without
  SFTP panes and a switcher that hides the file panes in the normal tab.
  Not part of this phase.
- **P3 from the spec** — host tags on `StoredSession` with sidebar
  filter, import/export of snippets via the envelope machinery from M19.
  Not part of this phase; P1 was deliberately built first, so it becomes
  clear how tags feel before they migrate a second time to a different
  model.
- **Explicitly not part of the original maintainer feedback that this
  phase covers:**
  - the **bulk runner** across filtered hosts with an output view — its
    own brainstorming, its own milestone, needs its own selection
    mechanism (which only P3's host filter delivers).
  - **multi-line commands and syntax highlighting** — per the spec these
    only get an honest place once the bulk runner exists, as long as
    "insert" stays the normal case.
  - **host tags and snippet import/export** — P3, see above.
  - **the terminal edge and a pure terminal window** — P2, see above.
- **Placeholders** (`{{path}}`, current directory), **binding snippets to
  hosts/groups/protocols**, **agent forwarding**, **multiple windows** —
  explicitly excluded by the spec, unchanged.

## For the release notes

**One sentence**, as the spec intends: snippets can be organized with
tags and inserted or executed directly at the host or in the terminal.

## Addendum: a parked finding from the fix-wave re-review

The final re-review found a point that does **not** originate from this
phase but belongs recorded here, so it does not disappear along with the
working directory:

**The context menu on the host cannot distinguish "no snippets" from
"store unreadable".** The sidebar receives `snippetsLoad.snippets`, i.e.
the already-flattened list, and never `SnippetsLoad` itself — it lacks
the `isUnreadable` signal. It therefore shows "No snippets yet" in both
cases. The menu bar distinguishes correctly and shows its own notice, as
does the terminal popover.

**Classification:** the same bug class as the whole-branch finding from
round 1 — an unreadable store must never look like an empty one. Here it
hits **one of four surfaces**, and the cause is the parameter shape,
which predates this phase. **Parked, not fixed:** fixing it changes an
interface that three other callers sit on, and therefore belongs in its
own task with its own tests — not in a fix wave after the ship verdict.
