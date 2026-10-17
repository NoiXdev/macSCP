# Sheet width and control rigidity — design

**Date:** 2026-10-17
**Status:** design, awaiting maintainer approval
**Record:** `docs/BACKLOG.md` rows added `cea077eb` and corrected `e84ef2e4`;
exemplar fix `5855b592`; exemplar guard
`Tests/macSCPAppKitTests/FileActionEditorLayoutGuardTests.swift`.

## Intent, and why now

On 2026-10-17 the maintainer reported the new-file-action sheet with its
title, a section header and two warning paragraphs cut off. The cause found
was a sheet fixed at 520 points whose Polish content needed 620.5, and a
German segmented picker that was squeezed from 432 points to 360 and lost
its last letter. Both were fixed for that one sheet, and a guard now
measures that one sheet in all four catalogues.

The defect was never specific to that sheet. Fourteen further views fix
their width in points and not one of them is measured in any language, and
27 sites use a localized control that cannot wrap. The maintainer's ruling
of 2026-10-17, asked which failure matters more:

> beide, die stille variante ist mir wichtiger

(Quoted verbatim as the ruling was given, in the maintainer's language:
both, and the silent variant matters more to them.)

The silent variant is the one no width measurement can see: a compressible
control reports a small minimum, is squeezed inside its row, and truncates
its labels while nothing overflows and nothing goes red. The exemplar fix
avoided it only because its author marked each non-wrapping control
`.fixedSize()` by hand. Fourteen more views must not rest on that.

## Goals

1. **No shipped language clips a fixed-width view.** Every view that grants
   a fixed width is measured, per catalogue, against what it grants.
2. **No localized control that cannot wrap is compressible.** Rigidity is a
   measured property of the control, not a convention its author remembered.
3. **A new view or a fifth language is covered the day it lands**, by a
   check that fails loudly rather than one that quietly matches nothing.
4. **The granted width is declared once**, so a reader can find every one of
   them, which today's `grep` cannot do (see Constraints).

## Non-goals

- No catalogue text changes. Nothing is shortened to make a layout fit.
- No visual redesign, and no new or removed controls beyond replacing a
  control with its rigid equivalent.
- **No flexible or negotiated sheet width.** Measured 2026-10-16 on this
  content: `.frame(minWidth:idealWidth:)`, `.frame(idealWidth:)` and a
  `ZStack` floor each either reported the frame's own width while the
  content overflowed it, or opened the sheet at its widest unwrapped text,
  843 points in German. The width stays fixed and is measured instead.
- **No attempt to explain the 2026-10-17 German screenshot.** German
  measured 499 points against 520 both before and after the fix, so the
  sheet-wide clipping in that screenshot is unexplained. It has its own
  backlog row and its own next step, a sight check.

## Anti-goals

Any of these means the work failed even if every test is green:

- **A source scan as the only guard.** This project has measured, five
  rounds running on one guard, that a scan buys one spelling and reveals
  another. A scan may stand beside a behavioural check; it may not stand
  alone.
- **A negative check with no positive beside it.** Only a check requiring
  something ABSENT can go stale in silence.
- **Figures measured once, on one machine, and never again.** The exemplar
  guard's numbers come from Darwin 27 and have never run on CI's macos-15.
- **Widening a view until German fits.** Polish needed roughly half again
  as much as English in the exemplar.

## The two properties, and the instrument for each

### Clipping: minimum content width ≤ granted width

`NSHostingController.sizeThatFits(in:)` at a proposed width of **zero**
returns the smallest width the content can take without clipping. Compare
it with the granted width. This is the exemplar guard, and it already
works; the work is to run it over every fixed-width view rather than one.

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

So **rigid means minimum equals ideal**, and it is a behavioural check
rather than a search for `.fixedSize()` in the source. The Polish segmented
picker can be squeezed by 45.5 points without anything overflowing, which
is the failure the maintainer ranked first.

**This instrument does not work at sheet level.** Measured the same day,
the exemplar sheet's ideal width is 699 points in all four catalogues
against a minimum of 364 to 411, because the ideal is dominated by
paragraphs that are meant to wrap, whose own ideal widths run 659 to 819
points. As a bound at sheet level it would be red for every sheet always.
It is a per-control instrument.

## The structural boundary

Rigidity is enforced by **components that contain it**, not by a rule
authors follow. One component per non-wrapping control kind in use, each
applying the rigid treatment internally:

- a segmented choice (21 sites today)
- a checkbox row (4 sites)
- a radio choice (2 sites)

A call site that wants the compressible form cannot express it through the
component, which is the property a scan cannot buy. Beside the components,
and only beside them, a scan asserts that the raw styles appear nowhere
outside the component definitions — a negative check, so it carries the
positive check this project requires: each component is measured rigid, in
every catalogue, minimum equal to ideal.

## The declared width, and keeping the list honest

Every fixed-width view declares its width through one named modifier rather
than writing a number. The granted widths in the tree today are 280, 380,
420, 460 and 520 points, across fifteen views.

The measurement needs to construct each view, which needs test doubles, so
**the registry of views to measure lives in the test target** and the
production side contributes only the declaration. A registry can go stale
when a sixteenth view lands, so the guard compares the **number of
declaration sites in `Sources/` with the number of registry entries** and
fails when they differ. That is a count equality, which breaks loudly on an
addition, not a `!contains` that would quietly match nothing.

## Constraints the builder must respect

1. **Build the view inside the locale override, not outside it.** Measured
   2026-10-17: a probe that built the view outside
   `L10n.$localeOverride.withValue` and measured inside it reported 373
   points for the German draft where the correct figure is 411, because
   labels on the view's top level resolve eagerly at construction while
   labels inside nested closures resolve at render. The error is silent and
   makes the guard pass. The exemplar guard already does this correctly and
   carries two positive checks against it: the measured widths must differ
   between catalogues, and each label the measurement depends on must come
   back as that catalogue's own value.
2. **Seven of the fifteen views are `private`** and cannot be reached from a
   test even with `@testable import`: `LoginSetEditorView`,
   `GenerateKeySheet`, `RenameKeySheet`, `CorrectKeyPassphraseSheet`,
   `ChangeKeyPassphraseSheet`, `SnippetEditorView`, `TerminalPanelHeader`.
   Measured 2026-10-17. **This is an open question for the maintainer**, not
   a decision taken here: making them module-internal widens the surface
   inside `MacSCPAppKit` by seven types.
3. **Rigidity raises the minimum content width of a resizable container.**
   In a container that sizes to its content the change is unobservable; in a
   resizable window it raises how narrow the window can be made. Five
   containers are affected: the main window through `ConnectionFormView`
   (five sites), the Settings window through `TerminalSettingsTab` and
   `CLISettingsSection` (one each), and three search or filter bars
   (`FileSearchBar`, `TagFilterJoinPicker`, `SheetSearchField`). For each,
   the new minimum is measured and recorded before it changes.
   `MainWindowSizePlan.formSize` is `CGSize(width: 700, height: 460)` and
   `browserFloor` is `CGSize(width: 930, height: 620)`; if a measured
   minimum no longer fits one of them, that constant changes with its
   measurement beside it, under the existing `MainWindowSizePlan` suite.
4. **The project's standing rules apply unchanged**, in particular: no
   hardcoded display string; every wait in a test is an `await`; no
   wall-clock ceiling in a test, a floor is fine; a figure travels with the
   command that produced it and the command runs in the form it is
   committed; a tracked-file plant goes through `scripts/mutation-probe`.
5. **CI has never run a measurement of this kind.** The exemplar guard's
   figures are from Darwin 27 and CI runs macos-15. The first task that can
   do so reads the figures off a CI run and writes them beside the local
   ones, before thirteen more views inherit the same unverified assumption.

## What is left to the builder

- The names of the components, the width declaration and its cases.
- The draft state each of the fifteen views is measured in. The exemplar
  measures two, a pristine draft and one with a declared variable of each
  kind and placement, chosen so the variable row's own pickers are on
  screen. Each view needs the equivalent judgement: the state that puts its
  widest content up.
- Whether the registry carries the granted width or reads it from the view.
- The order of the work, except that the CI reading comes before the bulk
  migration.

## Open question for the maintainer

Seven views must become module-internal to be measurable (Constraint 2).
The alternative is to leave them private and measure the remaining eight,
which leaves unguarded four of the five widths in `SSHKeysSheet`, the only
one in `SnippetsSheet`, the one in `LoginSetsSheet` and the popover in
`ContentView+Detail.swift` — seven of fifteen, and the majority of what
this finding is about. The
recommendation here is to make them internal, because `internal` does not
leave the module and the alternative abandons the majority of the finding,
but the call is the maintainer's.
