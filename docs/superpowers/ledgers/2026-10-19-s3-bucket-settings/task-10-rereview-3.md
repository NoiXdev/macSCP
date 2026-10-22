# Task 10, re-review 3 (BASE a4cdf0ea, HEAD 8bbcc6f5)

Verification only; nothing fixed. Two probes run through `scripts/mutation-probe` on the
committed tree, `--apply` copied from the message of `8bbcc6f5`.

## Probes

- **T2** (`_ = refusedRuns` folded into a short-circuiting `&&`): `RESULT: RED`, 101 tests ran,
  control 101 / 0 pre-existing failures. Caught by
  `ObjectLockSheetTests/aDateThatPassesWhileTheSheetIsOpenIsSaidSoOnTheClick()` alone.
  Not `BUILD FAILED`: the plant compiled and the tests ran.
- **T8** ("header" planted into a per-file line): `RESULT: RED`, 101 tests ran, control 101 / 0.
  Caught by `noLineOfTheSheetNamesStoreMechanics()` and `theEnglishCatalogueSaysTheDefault()`.
  Not `BUILD FAILED`.

## Claims

1. CONFIRMED. `ObjectLockSheet.swift` `dateHasPassed` is `_ = refusedRuns` on its own line,
   then `return focus == .retention && retainUntil <= now()`. The read is above the condition.
2. CONFIRMED. The key `s3.objectLock.blocked.datePast` moved in en, de, fr and pl. The withdrawn
   English quoted in the comment and the commit message,
   "Choose a date and time that is still ahead.", matches the text at `a4cdf0ea` exactly, in both
   `ObjectLockSheet.swift` (`datePastLine`) and `en.lproj`. German is du: "Wähle ein Datum und eine
   Uhrzeit in der Zukunft."
3. CONFIRMED. `noLineOfTheSheetNamesStoreMechanics` reads `Self.everyLine()` (fixed lines plus every
   scenario's lines, de-duplicated) with `#expect(english.count > 20)`. The only per-file
   sentence edited in the commit is `datePast`, for NEW-6. It contains none of the seven jargon
   terms. The other per-file lines are untouched, so the scan found nothing in the existing text.
4. CONFIRMED by reading the body. `aLoadOverAComplianceFileLeavesTheModeWhereItWas` seeds a COMPLIANCE
   retention (`newYear`), loads, asserts the read landed (`current?.retention?.mode == .compliance`),
   asserts `model.mode == .governance` and `activeBlockers == [.complianceInForce]`. Seeding the
   mode from the file would turn the `mode ==` assertion red. I did not run T5 myself.
5. CONFIRMED. `#expect(connective.count == Self.locales.count)` and
   `#expect(ruleHedges.count == Self.locales.count)` are in the test. Per locale it asserts the
   connective present and the hedges absent. The shipped refusal strings contain entweder, soit
   and albo, and "either" in en. The `locales` table is four entries.

Deferred findings untouched: CONFIRMED. The only `BucketObjectLockSheet.swift` change is the
`refusedSaves` comment (no code line). `acknowledged`'s `guard acknowledged != oldValue` is
unchanged, `s3.objectLock.notEnabledOnThisBucket` is unchanged in all four catalogues (still
"it can be chosen when a bucket is created"), the German acknowledgement string is not in the
diff, and `dayRange = 1...36_500` is unchanged.

## New finding

- **Minor, comment placement, test file.** The new test `theDateSentenceSaysTheDateHasPassed` was
  inserted between the doc comment `/// The legal-hold sheet has no mode, and says nothing about one.`
  and its function. That line now heads the new test's doc comment, and `theLegalHoldSheetShowsNoModeLine`
  has no doc comment. A comment now describes the wrong function (the file's own rule on comments
  that describe other code). One-line move. Evidence: `ObjectLockSheetTests.swift` around line 164.
  Not a behaviour issue.

## Gate

The gate can close once the misplaced comment is moved, or immediately if the controller accepts it
as a Minor. Nothing found affects behaviour or any guard.

## Environment note

While I ran, another session added `8d21b384` (docs only, a plan file) on top of `8bbcc6f5` and
left `docs/superpowers/plans/2026-10-19-s3-bucket-settings.md` staged in this worktree. Not mine; I left
it staged. `Sources` and `Tests` are identical to `8bbcc6f5` after my probes (`git diff --stat HEAD -- Sources Tests` empty).

## Not checked

I did not run the full suite, T1, T3-T7, or any probe beyond T2 and T8. Nothing was drawn or launched,
and the rig was not contacted. I did not verify the report's red-first claim (2 compile errors).
