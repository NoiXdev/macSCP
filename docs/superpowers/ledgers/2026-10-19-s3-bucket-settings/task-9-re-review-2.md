# Task 9, fix round 2: re-review

Reviewed commit `9ba2d1d2` (base `b2631aa4`) in the worktree `/Users/noidee/macSCP/.claude/worktrees/diff-view`. Nothing committed, amended or edited. `git status --porcelain` was empty before the first probe and is empty now (checked after the last command). Every `scripts/mutation-probe` run below used the `--apply` string from `git log -1 --format=%B 9ba2d1d2`, unrepaired.

One disclosure about my own method: for the mixed-cause item I needed documents of my own, so I copied one untracked Swift Testing file (`ZZScratchReview2Tests.swift`) into `Tests/macSCPAppKitTests/`, ran `swift test --filter ZZScratchReview2Tests`, and `rm`'d it. It printed `canSave`, `formBlock`, `problem` and `blockingSentence` (in en, de, fr, pl) for 14 documents. Porcelain was empty before and after.

## Per-item verdicts

| Item | Verdict |
|---|---|
| N1, the method name is clipped on the path the sentence takes | ADDRESSED |
| N2, six form-off states registered and measured | ADDRESSED |
| The two pins (`prefix(55)`, the overflow marker) | ADDRESSED |
| The mixed-cause document | PARTIAL, one more cause pair still ends in a disabled Save with no sentence about the cause |
| The `%lld`-unformatted bug the round found | ADDRESSED |
| The 10 probes | ADDRESSED, all 10 RED at HEAD |

## The thing that fooled the guard once: G1b, G5b, and the fixture

**G1b** (method clip removed, judged by `BoundedViewLayoutGuardTests`): `RESULT: RED — 9 test(s) ran, and the plant was caught by: BoundedViewLayoutGuardTests/noViewNeedsMoreThanItsBoundGrantsInAnyLanguage()`. Control: 9 ran, 0 pre-existing failures. The plant touched 1 file.

**G5b** (name clip removed, same suite): `RESULT: RED`, same catching test, same control.

**Is 800 characters adequate, or adequate-today?** Adequate today; not derived from anything. I bracketed the threshold with the same G1b plant and the multiplier in `BoundedViewRegistry.corsOverlong` varied (one `perl -pi` over both files; the probe's own stat line shows `2 files changed`):

| fixture (multiple of `nameLimit` 40) | characters | G1b-style result |
|---|---|---|
| x3 (the round's first version; reported by the round, not re-run) | 120 | GREEN (as reported) |
| x5 | 200 | **GREEN** (measured here) |
| x10 | 400 | **RED** |
| x13 | 520 | **RED** |
| x20 (committed) | 800 | **RED** |

So the method-clip plant is first noticed somewhere between 200 and 400 characters on today's layout. 800 carries a margin of between 2x and 4x. That is a reasonable margin, and the round's reasoning ("a sentence three times as long wraps and still fits") is confirmed by my x5 GREEN. It is not a relationship anyone will re-derive, for three reasons:

1. The only anchor stated in the registry comment is "longer than the 600 that took the sheet to 653 pt against 620", which is one reviewer measurement in one catalogue. The 20 is a chosen multiple.
2. The fixture is `nameLimit * 20`, so it **shrinks if the limit is lowered**, while the threshold it must beat depends on the sheet's headroom (620 minus 536 pt, about 84 pt) and not on `nameLimit`. A limit of 10 would make the fixture 200 characters, which my x5 run shows is blind.
3. Nothing asserts the property the fixture exists for ("the unclipped entry would exceed its bound"). The evidence is the G1b/G5b probes plus one GREEN-to-RED transition.

None of this blocks the task (Minor, see New Findings). A fixed character count, or a one-line record of the 200/400 bracket beside the 20, would make the number re-derivable.

**All six form-off states are measured, not only present.** The six entries sit in `valueInSheets`, which `BoundedViewRegistry.all` concatenates, and `noViewNeedsMoreThanItsBoundGrantsInAnyLanguage` loops over `all` in every shipped locale at the bound's granted width and height. `MACSCP_BOUND_FIGURES=1 swift test --filter BoundedView` printed one `boundfigures:` line per entry (22 tests in 6 suites passed). The `tall` figures, copied from that output:

| entry | de | en | fr | pl | of |
|---|---|---|---|---|---|
| three overlong element names left out | 575 | 575 | 575 | 575 | 620 |
| an overlong method name | 536 | 536 | 536 | 536 | 620 |
| a method outside the five (`FETCH`) | 536 | 523 | 536 | 536 | 620 |
| a value over several lines | 523 | 523 | 523 | 523 | 620 |
| a carriage return in a value | 540 | 540 | 540 | 540 | 620 |
| text that is not a readable configuration yet | 557 | 557 | 557 | 557 | 620 |

All six are under 620 and distinct (the measurement differs between states, so they are not the same sentence measured six times).

## N1: the clip is on the path that reaches the sentence

`formUnavailableSentence` (`BucketCORSSheet.swift:361`) now reads `String(format: line.text, Self.clipped(method))`; `clipped(_:)` is the same function the element names go through in `listed(_:)` (`names.prefix(namesShown).map(clipped)`). The view reads it at `BucketCORSSheet.swift:856` (`model.formUnavailableSentence`), so the clip is on the path that reaches the screen. G1a (the unit test) and G1b (the layout guard) both go RED when the clip is removed there. `nameLimit = 40` and `namesShown = 3` are constants (`BucketCORSModel`, `nonisolated static let`).

**Figures reproduced** with the committed command, `MACSCP_BOUND_FIGURES=1 swift test --filter BoundedView`: three names of 40 of the widest letter = **575 pt** of 620; the overlong-method entry = **536 pt** of 620; both identical in en, de, fr, pl. The round's wording "a method of 40 is 536" is shorthand: the entry feeds 800 characters and the clip lets 40 through, which is what 536 measures. That is the intended meaning.

## The two pins

**G2 (40 -> 55): RED, caught by `theClipFiguresAreTheOnesTheBoundWasMeasuredAt` and by nothing else.** The tests that derive from `nameLimit` (`aListOfNamesIsShortAndEachNameIsClipped`, `aMethodNameFromTheDocumentIsClippedInItsSentence`) cannot see it move, exactly as the round says.

**Judgement on pinning the 40 by value: I agree, and I can now put a measurement under the reasoning the round left unmeasured.** The round wrote that it "did not measure how tight" the layout guard is. I measured it: `nameLimit = 55` run against `BoundedViewLayoutGuardTests` alone is **GREEN**. At 55 the widest registered state still fits in 620 pt, so the layout guard bounds how large the figure can grow and does not pin 40; the by-value test is the only thing that fails when the figure moves. This case is also not the failure this project's "a literal is a second copy of a name" rule warns about. That rule is about a literal standing in for a symbol you could read, so that a rename leaves it stale in silence. Here the value is the decision itself. A rename of `nameLimit` fails to compile (loud), a change of value fails the test (loud), and the test is a positive check, not an absent-thing check. The exception is correct and the test's comment says why. One precision: the doc comment on `nameLimit` ("40 is what the bound was measured at") is true but should not be read as "40 is what the bound requires"; 55 fits as well. 40 is a chosen figure with about 45 pt of height left (575 of 620). That is not a defect.

**Overflow marker: G3 RED**, caught by `aListThatIsCutDiffersFromTheListOfTheNamesShown`. The test does not spell the marker: `listed(names(shown + 1)) != listed(names(shown))`, `.hasPrefix(listed(names(shown)))`, and exactly `namesShown` names equal the plain join. It works as described. (It would not notice the marker changing from `, …` to some other non-empty text; that is intended and said.)

**`clipped.count < 60` -> `== nameLimit`:** confirmed in the diff (`#expect(clipped.count == BucketCORSModel.nameLimit)` plus `#expect(clipped == String(long.prefix(BucketCORSModel.nameLimit)))`, with `long` now `nameLimit * 5`). G4 (`namesShown` 3 -> 4) is RED, caught by that test and by the by-value test. G5a (name clip removed) is RED, caught by `aListOfNamesIsShortAndEachNameIsClipped`.

## The mixed-cause document: PARTIAL

**What is addressed.** The reviewer's document (rule 1 `FETCH`, rule 2 a carriage return) now shows the value sentence: `blockerLine` returns `valueChangesLine` for a lossy document when `formBlock` is `.value` or `.method`. G6 (restore the `.value?`-only case) is RED, caught by `aMethodAndACarriageReturnAreBothSaid`. G7 (drop `.method?` from `blockingSentence`) is RED, caught by `aDocumentThatCannotBeSavedAlwaysSaysWhy(document:)`. The battery has 12 documents (7 with two causes, 5 with one; I counted them in `documentsThatCannotBeSaved`), with a saveable control (`aDocumentThatCanBeSavedHasNoBlockingSentence`).

**What is not.** The battery's claim, "`blockingSentence` ... is the one that is always there", and the doc comment's "nil only when nothing blocks a save (or the block is not the text's ...)" are false for one pair the battery does not contain: **a value over several lines (which reads back losslessly) together with a method outside the five.** Measured with my scratch test (en, and the same in de, fr, pl):

| document | canSave | formBlock | problem | `blockingSentence` |
|---|---|---|---|---|
| A: rule 1 origin `a\nb`, rule 2 method `FETCH` | false | `.value(rule: 1)` | `.methodNotAllowed("FETCH")` | **empty in all four locales** |
| B: one rule, origin `a\nb`, method `FETCH` | false | `.value(rule: 1)` | `.methodNotAllowed("FETCH")` | **empty** |
| K: `ID` of `x\ny`, method `FETCH` | false | `.value(rule: 1)` | `.methodNotAllowed("FETCH")` | **empty** |
| L: `AllowedHeader` of `x\ny`, method `FETCH` | false | `.value(rule: 1)` | `.methodNotAllowed("FETCH")` | **empty** |
| C (control): origin `a\nb` alone | **true** | `.value(rule: 1)` | nil | empty (correct) |

Why: a multi-line value survives the write-and-read-back, so `isLossless` is true and `blockerLine`'s value branch does not fire. `firstUnshowable` reports the value before the method, so `formBlock` is `.value`, not `.method`. `blockerLine`'s `problem` switch returns `nil` for `.methodNotAllowed` on the assumption that the `.method` form-off sentence covers it, and here the form-off sentence is the value one. `canSave` is false (the validation problem), `blockerSentence` is nil, and `blockingSentence`'s `formBlock` switch has no `.value` case. The view (`BucketCORSSheet.swift:856` and `:865`) shows only the form-off sentence, which says "A value in rule 1 runs over more than one line, which a field cannot hold. Edit the rules as text." That sentence is **not the reason Save is disabled** (C shows the multi-line value alone is saveable), and nothing says the method is. A user who leaves the multi-line value as it is will never be told about `FETCH`. This is the same defect class the round set out to close (disabled Save, no sentence about the cause), reached through a pair of causes the 12-document battery did not include. Severity: Important by this task's own standard (the original finding was the same shape); the documents are unusual, so not Critical.

Documents of my own that I constructed and that **do** yield a sentence in all four locales, with no `%` left in any: D (rule 1 `FETCH` + rule 2 multi-line), E (lowercase `get` + a rule with no origin), F (empty method + carriage return), G (an origin that is only `&#13;`), H (carriage return in rule 1 + `FETCH` in rule 2), I (element left out + multi-line), J and M (multi-line + a rule with no origin / an empty origin). The saveable control N has none.

## The bug the round found itself: ADDRESSED

- **Fix:** `blockerSentence` (`BucketCORSSheet.swift:581`) now formats whenever `line == Self.noOriginLine || line == Self.noMethodLine`, with the rule number from `problemRuleIndex`, instead of returning early for a non-readable or lossy text. Documents #2 and #5 of the battery exercise it (an element left out beside a rule with no origin; a multi-line value beside a rule with no method), and my J/M show "Rule 2 needs at least one allowed origin." with the number filled in.
- **Old line quoted verbatim:** the doc comment quotes `if !isReadable || !isLossless { return line.text }`. `git show b2631aa4:Sources/MacSCPAppKit/BucketCORSSheet.swift` has exactly that statement at line 543 of that file. The comment also states what was withdrawn and why.
- **G8** (restores the old line via the multi-line `perl -0pi`): RED, caught by `aDocumentThatCannotBeSavedAlwaysSaysWhy(document:)`. The plant stat showed 1 file changed, so it took effect.
- **Siblings.** I listed every `CatalogueLine` in the file whose English (and, in `Resources/{en,de,fr,pl}.lproj/Localizable.strings`, translated) text carries a specifier: `s3.cors.title %@`, `formCannotShowThis %@`, `formCannotShowMethod %@`, `formCannotShowValue %lld`, `problem.noOrigin %lld`, `problem.noMethod %lld`, `rule.title %lld`. Each is formatted before it reaches a `Text`: the title at `:777`; the three form-off lines in `formUnavailableSentence` (the `default` branch returns `line.text` only for `.unreadable` and `.unstable`, whose lines have none); the two rule lines in `blockerSentence`; the rule title in `ruleTitle`. All other lines the sheet shows raw (`unreadableLine`, `valueChangesLine`, `formNeedsReadableText`, `none`, `clearsAll`, the three error lines) carry no specifier in any of the four catalogues. `lines` (`:608`) returns raw `CatalogueLine`s, but it is read only by tests. I found no other path that can show a format specifier.

## Probes (all at HEAD `9ba2d1d2`, tree clean before and after each)

| probe | result | caught by |
|---|---|---|
| G1a method clip removed | RED | `aMethodNameFromTheDocumentIsClippedInItsSentence` |
| G1b same plant, layout guard | RED | `noViewNeedsMoreThanItsBoundGrantsInAnyLanguage` |
| G2 40 -> 55 | RED | `theClipFiguresAreTheOnesTheBoundWasMeasuredAt` only |
| G3 marker removed | RED | `aListThatIsCutDiffersFromTheListOfTheNamesShown` |
| G4 `namesShown` 3 -> 4 | RED | `aListOfNamesIsShortAndEachNameIsClipped`, `theClipFiguresAreTheOnesTheBoundWasMeasuredAt` |
| G5a name clip removed | RED | `aListOfNamesIsShortAndEachNameIsClipped` |
| G5b same plant, layout guard | RED | `noViewNeedsMoreThanItsBoundGrantsInAnyLanguage` |
| G6 value sentence not shown beside a method | RED | `aMethodAndACarriageReturnAreBothSaid` |
| G7 `blockingSentence` loses the method case | RED | `aDocumentThatCannotBeSavedAlwaysSaysWhy(document:)` |
| G8 unformatted blocker restored | RED | `aDocumentThatCannotBeSavedAlwaysSaysWhy(document:)` |

Controls were 57 tests for `BucketCORSSheetTests` and 9 for `BoundedViewLayoutGuardTests`, as the commit states, with no pre-existing failure. Extra probes of mine, outside the assigned ten: the multiplier bracket above (x5 GREEN, x10/x13 RED) and `nameLimit = 55` under the layout guard alone (GREEN). I did not run the full `swift test`; the report's one pre-existing red in `macSCPAppKitTests` (`ViewTestabilitySpike.swift:202`) is out of scope as instructed.

## Provenance of the G1b GREEN line

The commit message's GREEN line ("RESULT: GREEN — 9 test(s) ran and NONE of them noticed the plant.") was copied from a log the re-run overwrote. For a claim about a state the tree no longer has, I judge that **acceptable**, for three reasons. It is disclosed in both the commit message and the report, in the same sentence as the fact it qualifies, so no reader is misled about what was reproduced. The wording is exactly the string `scripts/mutation-probe` prints for a GREEN, so it was not invented. And my independent x5 run (200 characters, the same plant) printed that same line, which is the same shape the round claims for its x3 fixture. The claim does not carry weight for the final tree (the final tree's guard is shown RED, five times over). The disclosure is the right remedy and no re-demonstration is needed.

## No red before the production change

The round discloses that no red was observed before the change. In one line: G6 and G8 restore the pre-fix source almost literally, and both go RED under the new tests, so those two tests are effectively red-first by construction; the others rest on G1 to G5 and G7 alone. I do not count it against the round.

## New breakage in the fix diff

- **Important: the mixed-cause claim is not true for a multi-line (lossless) value with a method outside the five.** Detail and measurements under "The mixed-cause document". `BucketCORSSheet.swift:559` (`blockerLine`: `.methodNotAllowed` returns nil), `:594` (`blockingSentence`: no `.value` case). The battery at `BucketCORSSheetTests.swift` (`documentsThatCannotBeSaved`) does not contain the pair. The comment "`blockingSentence` is the one that is always there" (`:558`) and its own doc comment (`:589`) are false for it. A fix has two parts: say the method when `problem` is `.methodNotAllowed` and `formBlock` is not `.method`, and add this pair (and K/L variants) to the battery with `blockingSentence` asserting non-empty.
- **Minor: the fixture length has no stated relationship to the bound** (`BoundedViewRegistry.corsOverlong`, `nameLimit * 20`). Measured bracket: GREEN at x5, RED at x10. It scales with `nameLimit` and the threshold does not. See above.
- **Minor: `blockingSentence` has no production reader.** Only the tests read it (`grep -n blockingSentence` finds its definition at `BucketCORSSheet.swift:594` and uses in `BucketCORSSheetTests.swift` only). That is sound as long as the view keeps showing both `formUnavailableSentence` and `blockerSentence` (it does, `:856`, `:865`), but a change to the view that stopped showing either would leave the battery green. Not a defect today.
- **Minor: the `blockerLine` comment contradicts the catalogue it sits on.** The first paragraph (unchanged from round 1) says a method outside the five has "a sentence of their own that says the text cannot be saved as it is". The English `s3.cors.formCannotShowMethod` text is "“%@” is not a method that can be allowed, so the fields are off. Use GET, PUT, POST, DELETE or HEAD in the text." It does not say that. The paragraph the round added lists only `.leftOut` and `.unstable` as carrying that wording, which is accurate, so the two paragraphs now disagree. The sentence is clear enough for a user; the comment is wrong.

## Out-of-scope observations

None beyond those already deferred.

## Verdict

**Fix round: findings remain open.** N1, N2, the two pins and the `%lld` bug are addressed and verified RED/GREEN by me, including all ten probes. The mixed-cause item is PARTIAL: the reviewer's own document is fixed, but a multi-line (lossless) value together with a method outside the five still ends with a disabled Save and no sentence about the method, and the round's comment says that cannot happen.

Verdict on the fixture: adequate today (2x to 4x margin measured), not derived, and shrinks with the limit. Verdict on pinning the 40 by value: agree; the layout guard alone is GREEN at 55, so the by-value test is the only guard.

Paths: `.superpowers/sdd/2026-10-19-s3-bucket-settings/task-9-re-review-2.md` (this file); source `Sources/MacSCPAppKit/BucketCORSSheet.swift`; tests `Tests/macSCPAppKitTests/BucketCORSSheetTests.swift`, `Tests/macSCPAppKitTests/BoundedViewRegistry.swift`.
