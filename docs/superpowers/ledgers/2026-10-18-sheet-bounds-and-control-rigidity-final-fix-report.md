# Final fix wave — report

**Status: DONE_WITH_CONCERNS.** All six fixes carried out, in seven commits on
`sheet-bounds-and-control-rigidity`. Nothing pushed, nothing merged, no other
branch or worktree touched.

## Commits

| Hash | Subject | Fix |
|---|---|---|
| `399385a5` | test(views): catch a width frame written around a rigid component | 1 |
| `7dd2fe2e` | docs(views): say what the 411 pt figure is, and what to do when it reds | 2 |
| `c7380deb` | docs(views): correct the guard header that says no locale code is spelled | 3 |
| `cec221a6` | test(views): measure the styleless Toggle the backlog row left unclassified | 4 |
| `fb0c76ff` | docs: correct three understatements in this branch's own record | 5 |
| `187aba63` | test(views): close the windows the on-screen walk opens | 6 (the one-liner) |
| `e1f656bc` | docs: open one row for the rigidity work's coverage debt | 6 (the row) |

## Tests

`swift test` at `e1f656bc`: **2555 tests in 230 suites, one issue — the standing
`ViewTestabilitySpike` failure "Varying only isRegex leaves the pixels
unchanged" (`ViewTestabilitySpike.swift:202`), which is not this wave's.**
`swift test --filter RigidControlScan` 16 of 16, `--filter RigidControlTests`
8 of 8, `--filter BoundedViewStateOnScreen` 2 of 2. After `touch` on all six
changed test files, `swift build --build-tests` emits zero lines matching the
CI gate's pattern `^[^[:space:]]+:[0-9]+:[0-9]+: warning:`.

## What each fix did

**1 — the `.frame(width:)` hole.** `RigidControlScanTests` gained
`noRigidComponentIsHeldToAWidthFrame`, which walks the modifier chain written
on each component call (parenthesis-balanced, so a multi-line call is followed
to the line that closes it) and is red on `.frame(width:` / `.frame(maxWidth:`.
Positive half: per-file call counts held to the committed list exactly (19 in
the blanked view; the 20th grep line is `RigidControls.swift:57`, that file's
own prose). Proved red through `scripts/mutation-probe` by putting the deleted
frame back on the snippet kind picker:
`RESULT: RED — 1 test(s) ran, and the plant was caught by:
macSCPAppKitTests.RigidControlScanTests/noRigidComponentIsHeldToAWidthFrame(component:)`,
over a control run of `1 test(s) ran, 0 pre-existing failures`. The withdrawn
Task 8 conclusion is quoted in the test's doc comment and in the ledger.

**2 — the 411 pt figure.** Doc comment added with the platform (Darwin 27.0.0,
macOS 27.0.1 build 26A434, arm64, Swift 6.4), the date, both commands that
reproduce it, and the ruling: a red is answered by re-measuring and recording,
never by reverting the component.

**3 — the false header sentence.** "No locale code and no display string is
spelled here" corrected in place with the wording quoted. `grep -o -e
'"[a-z][a-z]"' …` prints 13 occurrences on 10 lines, re-run after the sentence
was written, and the pattern does not match the command as the comment spells
it.

**4 — the `Toggle(` row.** New measurement
`RigidControlTests.theJumpToggleIsCompressibleWhereTheComponentIsNot`, which
asserts the relationship and, under `MACSCP_BOUND_FIGURES=1`, prints the
figures: bare / through `CheckboxRow` — de 21.0/319.0 and 319.0/319.0, en
21.0/332.0 and 332.0/332.0, fr 21.0/335.0 and 335.0/335.0, pl 21.0/302.0 and
302.0/302.0. The three `ConnectionFormView` line numbers were verified
(`469`, `953`, `1253`) and so was the bound (`.capped(minWidth: 420,
maxWidth: 460)`).

**5 — three corrections.** The closeout sentence at the `Thirteen sheets…` row
corrected in place with its wording quoted, naming both widenings
(`GenerateKeySheet` 380 → 420 `beff2664`, now `SSHKeysSheet.swift:634`;
`TagFilterSheet` 300 → 320 `c0f1bf5b`, now `SidebarTagFilterBar.swift:120`) and
the count of four user-visible changes. The registry's "IS the longest localized
text the sheet ever shows" hedged to the Task 6 classification, with
`KnownHostsSheet`'s four never-rendered localized strings named and the
2.4×–8.3× slack measured rather than recalled.

**6 — one row, plus the one-liner.** Seven findings folded into a single row;
`BoundedViewStateOnScreenTests` now closes its sixteen windows a run
(`isReleasedWhenClosed = false` first, because ARC owns the window).

## Concerns

1. **The brief's "27–43 pt below its ideal" is wrong for `pl`.** Measured:
   `ConnectionFormView`'s ideal stands 27 (de), 40 (en), 43 (fr) and **10** (pl)
   points above the 460 it is granted. The row carries the four figures, not the
   range.
2. **The ledger's "3-8x slack" was also off** — measured 2.4× to 8.3×. Corrected
   in `progress.md` with the old wording quoted.
3. **`.superpowers/` is gitignored.** The ledger corrections (the Task 8
   width-frame withdrawal, the four-user-visible-changes count, the slack range)
   are on disk but appear in no commit. If the ledger is meant to be part of the
   record, it is not under version control here.
4. **`BoundedViewRegistry.swift` is in `Tests/`, not `Sources/`** as the brief
   said; the hedge went into the test registry, which is where the sentence was.
5. **Item 5 of the new row is predicted, not measured.** No German-preferred
   machine was available, and driving `AppleLanguages` through `swift test` was
   not attempted beyond establishing that the bundle can be run directly. The row
   says so outright.
6. **A second unclosed `NSWindow` survives**, in
   `RigidControlTests.renderedSegmentedWidth` (one per locale per shape, so
   twelve a run). Out of this wave's scope as briefed; it is the same defect as
   the one fixed in `BoundedViewStateOnScreenTests`.
7. **The width-frame check reads one level only.** A frame on an enclosing
   container collapses the minimum exactly as well, nothing in the tree measures
   that, and both the suite header and the test say so rather than leaving it
   implied.

## Appendix — the coordinator's `minWidth` correction (2026-10-18, after the first return)

Two commits: `d9084704` (test(views): catch a minWidth floor around a rigid
component too) and `0f858325` (docs: add the two deferred findings to the
coverage-debt row).

**The hole is real and is now measured here.** New test
`RigidControlTests.aWidthOrMinWidthFrameCollapsesTheMinimum` reproduces the
coordinator's figures through this repository's own `LayoutMeasure`, in all four
catalogues, printed by `MACSCP_BOUND_FIGURES=1 swift test --filter
aWidthOrMinWidthFrameCollapsesTheMinimum`:

```
frame: de alone 149.0 width100 100.0 maxWidth100 100.0 minWidth100 100.0 maxWidthInfinity 149.0 minWidth100AndInfinity 100.0
frame: en alone 155.0 width100 100.0 maxWidth100 100.0 minWidth100 100.0 maxWidthInfinity 155.0 minWidth100AndInfinity 100.0
frame: fr alone 174.0 width100 100.0 maxWidth100 100.0 minWidth100 100.0 maxWidthInfinity 174.0 minWidth100AndInfinity 100.0
frame: pl alone 219.0 width100 100.0 maxWidth100 100.0 minWidth100 100.0 maxWidthInfinity 219.0 minWidth100AndInfinity 100.0
```

1. `widthFramePattern` now reads
   `(?:width|maxWidth|minWidth)\s*:(?!\s*\.infinity)`. The exclusion of
   `maxWidth: .infinity` is measured rather than reasoned, and
   `minWidth: 100, maxWidth: .infinity` is caught on its `minWidth`.
2. `.frame(minWidth: 100)` moved from the must-not-match list to the must-match
   list, and the withdrawn sentence — "A width frame, in the two spellings that
   CAP a width. `minWidth:` and `idealWidth:` raise a floor rather than cap, so
   they are not matched" — is quoted in place.
   `grep -rn -F -e '.frame(minWidth:' Sources/MacSCPAppKit` prints 25 under both
   greps; none sits on a component call, so nothing went red.
3. The reviewer's 477.0/100.0 figures are labelled **not reproducible as
   committed**, with the runnable measurement named beside them. The
   `VStack`-inside-a-frame case is the one the runnable test cannot show,
   because nothing here measures a frame on an enclosing container.
4. The false coverage claim is corrected in both places (test doc comment and
   suite header), with the wording quoted: only `SnippetsSheet`'s instance sits
   on a component call. `grep -n 'SegmentedChoice(\|RadioChoice(\|CheckboxRow('
   Sources/MacSCPAppKit/FileSearchBar.swift` prints nothing, so a width frame
   returning to that line is caught by nothing; both sentences now point at item
   (1) of the coverage-debt row.
5. Deferred as instructed into that row as items (8) and (9): the
   `Self.components[0]`/`[2]` indices (four occurrences across two tests) and
   the second unclosed `NSWindow` in `RigidControlTests.renderedSegmentedWidth`
   (twelve a run), with the three-line fix shape named. The row's own count is
   corrected in place from seven findings to nine, quoting the old wording.

**Proved red twice** through `scripts/mutation-probe`, planting first
`.frame(width: 150)` and then `.frame(minWidth: 100)` on the snippet kind
picker. Both runs, over a control of `1 test(s) ran, 0 pre-existing failures`:

```
RESULT: RED — 1 test(s) ran, and the plant was caught by:
  macSCPAppKitTests.RigidControlScanTests/noRigidComponentIsHeldToAWidthFrame(component:)
```

**Verification.** `swift test --filter RigidControlScan` 16 of 16,
`--filter RigidControlTests` 9 of 9. Full `swift test` at `0f858325`: Core 4936
tests in 395 suites green; AppKit 2556 tests in 230 suites with the single
standing `ViewTestabilitySpike` issue. After `touch` on both changed files,
`swift build --build-tests` emits zero lines matching the CI gate's warning
pattern. Worktree clean, nothing pushed.
