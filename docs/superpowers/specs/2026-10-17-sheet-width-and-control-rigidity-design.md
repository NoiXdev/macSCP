# Sheet width and control rigidity — design

**Date:** 2026-10-17
**Status:** design, maintainer rulings of 2026-10-17 incorporated
**Record:** `docs/BACKLOG.md` rows added `cea077eb`, corrected `e84ef2e4` and
`ce245b5c`; exemplar fix `5855b592`; exemplar guard
`Tests/macSCPAppKitTests/FileActionEditorLayoutGuardTests.swift`.

## Intent, and why now

On 2026-10-17 the maintainer reported the new-file-action sheet with its
title, a section header and two warning paragraphs cut off. The cause found
was a sheet fixed at 520 points whose Polish content needed 620.5, and a
German segmented picker squeezed from 432 points to 360 that lost its last
letter. Both were fixed for that one sheet, and a guard now measures that
one sheet in all four catalogues.

The defect was never specific to that sheet. **Thirty-three views bound
their width to something other than their content, and one of them is
measured.** Twenty-seven sites use a localized control that cannot wrap.

Asked which failure matters more, the maintainer ruled:

> beide, die stille variante ist mir wichtiger

(Quoted verbatim as it was given, in the maintainer's language: both, and
the silent variant matters more to them.)

The silent variant is the one no width measurement can see: a compressible
control reports a small minimum, is squeezed inside its row, and truncates
its labels while nothing overflows and nothing goes red. The exemplar fix
avoided it only because its author marked each non-wrapping control
`.fixedSize()` by hand. Thirty-two more views must not rest on that.

## Scope

**All thirty-three**, by the maintainer's ruling of 2026-10-17 (`33`). The
figure is three commands, each run from the repository root, each
reproducing under the session's ugrep and under `/usr/bin/grep`, measured
2026-10-17:

| spelling | command | lines |
|---|---|---|
| width only | `grep -rn '^        \.frame(width: [0-9]*)$' Sources/MacSCPAppKit/` | 14 |
| width and height | `grep -rn '^        \.frame(width: [0-9]*, height: [0-9]*)$' Sources/MacSCPAppKit/` | 11 |
| width capped | `grep -rn '^        \.frame(minWidth: [0-9]*, maxWidth: [0-9]*)$' Sources/MacSCPAppKit/` | 6 |

Plus two none of them returns: `FileActionEditor`'s own
`.frame(width: Self.sheetWidth)`, a named constant at a deeper indentation,
and the nested cap at `ContentView+Detail.swift:724`. 14 + 11 + 6 + 2 = 33.

The narrower readings were rejected because a capped width clips exactly as
a fixed width does, and because two of the controls this work makes rigid
live in containers the narrower readings do not measure:
`TagFilterJoinPicker` renders inside the 300-by-360 popover at
`SidebarTagFilterBar.swift:146`, and five of the twenty-one segmented sites
sit behind the 460-point cap at `ConnectionFormView.swift:652`. Under a
fifteen-view scope, making those controls rigid would introduce a clipping
defect in a container nothing measures.

**Height is measured too**, where a view fixes it. Eleven views fix both
axes, and a sheet 460 points tall whose German content needs more clips
vertically — the same defect through the other axis. The instrument is the
same call with the roles swapped: the minimum height at the granted width.
This is the author's call, taken because the ruling that chose 33 chose it
on the argument that an uncounted bound is still a bound.

## Goals

1. **No shipped language clips a bounded view**, on either axis a view
   binds. Every one of the thirty-three is measured, per catalogue, against
   what it grants.
2. **No localized control that cannot wrap is compressible.** Rigidity is a
   measured property of the control, not a convention its author remembered.
3. **A new view or a fifth language is covered the day it lands**, by a
   check that fails loudly rather than one that quietly matches nothing.
4. **The bound is declared once**, so a reader can find every one of them —
   which no single `grep` can do today, as the three spellings above show.

## Non-goals

- No catalogue text changes. Nothing is shortened to make a layout fit.
- No new or removed controls beyond what Goal 2 and a red measurement
  require.
- **No flexible or negotiated sheet width.** Measured 2026-10-16 on the
  exemplar's content: `.frame(minWidth:idealWidth:)`, `.frame(idealWidth:)`
  and a `ZStack` floor each either reported the frame's own width while the
  content overflowed it, or opened the sheet at its widest unwrapped text,
  843 points in German. The bound stays and is measured instead.
- **No attempt to explain the 2026-10-17 German screenshot.** German
  measured 499 points against 520 both before and after the fix, so the
  sheet-wide clipping in that screenshot is unexplained. It has its own
  backlog row and its own next step, a sight check.

## Anti-goals

Any of these means the work failed even if every test is green:

- **A source scan as the only guard.** Measured here across five rounds on
  one guard: a scan buys one spelling and reveals another. This design's
  own census made that mistake twice in one day, which is why the scope
  above is three commands and not one.
- **A negative check with no positive beside it.**
- **Figures measured once, on one machine, and never again.**
- **Widening a view until German fits.** Polish needed roughly half again
  as much as English in the exemplar. Widening to the maximum measured
  across all four catalogues is a different thing and is sanctioned; see
  Remedies.

## The two properties, and the instrument for each

### Clipping: minimum content size ≤ granted size

`NSHostingController.sizeThatFits(in:)` at a proposed width of **zero**
returns the smallest width the content can take without clipping. Compare
with the granted width; where a height is granted, measure the minimum
height at the granted width and compare that too.

### Silent squeezing: a control's minimum equals its ideal

Measured 2026-10-17, bare controls hosted alone, per catalogue. The
**minimum** is `sizeThatFits` at proposed width zero; the **ideal** is the
same measurement under `.fixedSize(horizontal: true, vertical: false)`. A
control that can be compressed reports two different numbers:

| control | locale | minimum | ideal | verdict |
|---|---|---|---|---|
| segmented kind picker | en | 144.0 | 155.0 | compressible |
| segmented kind picker | de | 144.5 | 149.0 | compressible |
| segmented kind picker | fr | 145.5 | 174.0 | compressible |
| segmented kind picker | pl | 173.5 | 219.0 | compressible |
| the same, `.fixedSize()` | en | 155.0 | 155.0 | rigid |
| the same, `.fixedSize()` | pl | 219.0 | 219.0 | rigid |
| radio group | de | 21.0 | 213.0 | compressible |
| checkbox pair | de | 58.0 | 251.0 | compressible |

**Rigid means minimum equals ideal** — a behavioural check, not a search
for `.fixedSize()` in the source. The Polish segmented picker can be
squeezed by 45.5 points without anything overflowing, which is the failure
the maintainer ranked first.

**This instrument does not work at sheet level.** Measured the same day,
the exemplar sheet's ideal width is 699 points in all four catalogues
against a minimum of 364 to 411, because the ideal is dominated by
paragraphs meant to wrap, whose own ideal widths run 659 to 819 points. As
a sheet-level bound it would be red for every sheet always. It is a
per-control instrument.

**Rigid means a floor at the ideal, not a shrink to it.** Author's call:
several of the twenty-one segmented sites currently stretch to fill their
row, and shrinking them would change how up to twenty-seven controls look,
which the non-goals exclude. A floor satisfies the definition above —
minimum equals ideal — while preserving the stretch.

## The structural boundary

Rigidity is enforced by **components that contain it**, not by a rule
authors follow. One component per non-wrapping control kind in use, each
applying the floor internally:

- a segmented choice (21 sites today)
- a checkbox row (4 sites)
- a radio choice (2 sites)

A call site cannot express the compressible form through the component,
which is the property a scan cannot buy. Beside the components, and only
beside them, a scan asserts the raw styles appear nowhere outside the
component definitions — a negative check, so it carries the positive this
project requires: each component is measured rigid, in every catalogue,
minimum equal to ideal.

## The declared bound, and keeping the list honest

Every bounded view declares its bound through one named modifier rather
than writing numbers, so that one search finds all of them — which is
precisely what the three spellings above make impossible today.

The measurement must construct each view, which needs test doubles, so
**the registry of views to measure lives in the test target** and the
production side contributes only the declaration. A registry goes stale
when a thirty-fourth view lands, so the guard compares the **number of
declaration sites in `Sources/` with the number of registry entries** and
fails when they differ. That is a count equality, which breaks loudly on an
addition, not a `!contains` that would quietly match nothing.

**The count equality is only sound if every declaring type is reachable
from a test**, which is why the visibility ruling below is load-bearing
rather than cosmetic: an exclusion list would be exactly the quietly
staleable construct the anti-goals forbid.

## Remedies when a measurement comes back red

By the maintainer's ruling of 2026-10-17, all three are available:

1. **Make the control rigid**, if the red is a squeeze.
2. **Widen the granted bound** to the maximum measured across all four
   catalogues. This is not the anti-goal above: the anti-goal is widening
   to German's figure and leaving Polish broken.
3. **Replace the control with a different kind** — as the exemplar did,
   turning a segmented picker into a radio group so the widest thing is one
   label rather than two side by side. Ruled allowed on 2026-10-17
   (`ja anderer typ erlaubt`), which is why this is a non-goal exception
   and not a violation of "no visual redesign".

## Constraints the builder must respect

1. **Build the view inside the locale override, not outside it.** Measured
   2026-10-17: a probe that built the view outside
   `L10n.$localeOverride.withValue` and measured inside it reported 373
   points for the German draft where the correct figure is 411, because
   labels on the view's top level resolve eagerly at construction while
   labels inside nested closures resolve at render. The error is silent and
   makes the guard pass. The exemplar guard does this correctly and carries
   two positive checks against it: the measured widths must differ between
   catalogues, and each label the measurement depends on must come back as
   that catalogue's own value.
2. **Fourteen types become module-internal.** Ruled 2026-10-17
   (`private aufmachen`). **This number was written as ten when the ruling
   was given, and as seven when the question was first put.** Both were
   short for the same reason the scope was: they were read off the
   width-only census. Counted 2026-10-18 by a script that walks all three
   spellings and reads each owner's declaration, eleven of the thirty-three
   bounded views are owned by a `private` type — `ChangeKeyPassphraseSheet`,
   `ConnectFailureView`, `ConnectingAttemptView`, `CorrectKeyPassphraseSheet`,
   `GenerateKeySheet`, `LoginSetEditorView`, `LostConnectionView`,
   `RenameKeySheet`, `SnippetEditorView`, `TagFilterSheet`,
   `TerminalPanelHeader` — and three more are the private resizable
   containers of Constraint 3: `TerminalSettingsTab`, `CLISettingsSection`,
   `TagFilterJoinPicker`. Fourteen distinct types. `internal` does not leave
   `MacSCPAppKit`.
3. **Rigidity raises the minimum content width of a resizable container.**
   In a container that sizes to its content the change is unobservable; in
   a resizable window it raises how narrow the window can be made. Six
   containers are affected: the main window through `ConnectionFormView`
   (five sites), the Settings window through `TerminalSettingsTab` and
   `CLISettingsSection` (one each), and three search or filter bars
   (`FileSearchBar`, `TagFilterJoinPicker`, `SheetSearchField`). Each new
   minimum is measured, and the measurement becomes a standing check rather
   than a one-off note (author's call). `MainWindowSizePlan.formSize` is
   `CGSize(width: 700, height: 460)` and `browserFloor` is
   `CGSize(width: 930, height: 620)`. **If a measured minimum no longer
   fits one of those, stop and ask the maintainer.** A window the user can
   no longer make as narrow is user-visible behaviour, which under the
   house rule owes a user-documentation page in `noix-docs` and the
   maintainer's agreement; that question was put on 2026-10-17 and has not
   been answered, so it is not settled here.
4. **The project's standing rules apply unchanged**, in particular: no
   hardcoded display string; every wait in a test is an `await`; no
   wall-clock ceiling in a test, a floor is fine; a figure travels with the
   command that produced it and the command runs in the form it is
   committed; a tracked-file plant goes through `scripts/mutation-probe`.
5. **CI has never run a measurement of this kind.** The exemplar guard's
   figures are from Darwin 27; CI runs macos-15. **Pushing for this
   measurement is authorized** (ruled 2026-10-17, `push ist ok`), and
   reading the CI figures is the first task, before thirty-two more views
   inherit an unverified assumption. If the figures disagree with the local
   ones, the remedy is Remedy 2 — widen to the maximum across catalogues
   AND platforms — because a bound that holds on one machine and not
   another is the wall-clock-ceiling mistake in another coordinate. If the
   instrument does not work headless at all, that is a finding to report
   with its evidence, not a reason to drop the guard: say so and stop.

## What is left to the builder

- The names of the components, of the bound declaration, and its cases.
- The draft state each of the thirty-three views is measured in. The
  exemplar measures two, a pristine draft and one with a declared variable
  of each kind and placement, chosen so the variable row's own pickers are
  on screen. Each view needs the equivalent judgement: the state that puts
  its widest and tallest content up.
- Whether the registry carries the granted bound or reads it from the view.
- The order of the work, except that the CI reading comes first.
- How the count equality is implemented. `SourceCorpus` already provides a
  vetted source-reading seam.
