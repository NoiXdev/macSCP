# P3f — Wrap-up

**Goal:** Export everywhere through the row context menu.
**Status:** done. Suite 2128 tests in 186 suites, green.

## What the measurement found

The task was to measure, before planning, which lists show exportable
things and what their context menu can already do. Result: **four of
five were already done.**

| List | Export in the row |
|---|---|
| Session (sidebar) | present, `export.menu.single` |
| Group (sidebar) | present, `export.menu.group` |
| Login sets | present, `logins.export.action` |
| SSH keys | present, public and private |
| Snippets (sheet) | **missing** — now added |

So the phase was one entry, not a rework.

## The spec's open question was already answered — in the code

The spec asked whether "Export" on the row means the same as in the
sheet. `LoginSetsSheet` has answered that since M19 with a comment: *"the
footer button covers 'all' (or whatever is selected); this one always
means THIS row."* The row entry sets the selection beforehand, so the
visible selection and the effective scope never diverge. The new snippet
entry carries over exactly this pattern — no second rule.

## What the full check found

**The measurement was incomplete.** There is a **sixth** row context
menu on a list with exportable things: the terminal snippet picker from
P3d (`ContentView+Detail.swift`, `SnippetRowContextMenu`) with
Run / Insert / Preview. It was neither counted nor deliberately
excluded. Two smaller neighbors likewise: the audit log (export only in
the footer, no row menu at all) and the imported hosts (row menu with
only "Hide").

No code was changed — but "everywhere" is thereby proved-for-five and
open-for-the-picker. **That is a maintainer decision**, not a silent
exclusion: a save dialog in the middle of a running terminal session is
plausibly unwanted, but that's not the phase's call to make.

Also: two comments that were no longer true (the new guard's suite
comment promised an ordering guarantee that an earlier correction had
removed; `performExport`'s comment knew of only one caller, and since
this phase there are two), and a guard test that searched the whole file
and hit the right occurrences only by ordering luck. It now isolates the
row menu block, fails on a missing anchor instead of silently passing
through, and counts `"snippets.export"` at exactly two occurrences — that
catches the drift a bare `contains` couldn't see.

## Open, deliberately not decided

**The confirmation step is missing for snippets — at both triggers.**
`LoginSetsSheet` opens its export sheet with options and a count from
both the footer and the row; snippet export goes straight into the save
dialog. Substantively justified: `SnippetExportCodec` has neither options
nor a password, an options sheet would have nothing to show.

**The footers mean different things.** Login sets export the selection
if one is visible, otherwise all visible ones — and name the count
before writing. Snippets always export the visible set and ignore the
selection. Both pre-existing, untouched by this phase. Unifying them
would be a behavior change to shipped code and belongs in front of the
maintainer, not handled on the side — especially since, without a
confirmation step, a selection narrowing for snippets would be
**invisible**, which is exactly what the spec warns against.
