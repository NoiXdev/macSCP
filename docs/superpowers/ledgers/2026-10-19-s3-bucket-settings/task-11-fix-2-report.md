# Task 11, fix round 2

BASE `1d1dcec2`. Four commits on top, none amended, no rebase:

- `5ba1f50b` N1, M4, N2 (first form), N4
- `4cad4c20` the prefix test must not spell the prefix it forbids
- `891bb0c2` a string literal names nothing to the sweep
- `0ef4e3f5` the probes of this round with their commands (empty commit; its message is the record)

Full `swift test` at `0ef4e3f5` (code identical to `891bb0c2`): Core 5075 passed;
App 2815 tests, one red, the pre-existing `ViewTestabilitySpike` isRegex test.

## N1 / M8: a guard on what a person reads

- `BoundedViewRegistry.ownedBucketModel(nameInList:)` and one new registry state,
  "a bucket the store says is already ours, whose name is also in the list": a
  partial outcome AND a taken name, which no other entry had. It differs from
  its neighbours (a finding's sentence, no lock), so
  `entriesOfOneTypeMeasureDifferentStates` does not read it as a twin (that
  guard would otherwise have gone red on correct code).
- Registry entries alone could not catch the regression: the extra line is a
  short caption that fits the bound. So
  `aTakenNameAddsNoLineBesideAnOutcomeThatAlreadySaysTheBucketExists` measures
  the sheet's height with the name in the list and without it, for the same
  outcome, in all four locales, and requires them equal; its positive control
  is the same comparison where the line SHOULD show (taller). Plain `Text`
  cannot be found in a hosted view, so presence is read from height.
- RP3, the exact pre-fix view condition restored: **RED** (63 tests, and 84 with
  every layout/on-screen/coverage/rigid-control guard added), caught by that
  test alone. It was GREEN over 60 and 81 against `1d1dcec2`.
- The registry comment "Seven states" is corrected in place to eight, with the
  command (`grep -c 'CreateBucketSheet[(]' Tests/macSCPAppKitTests/BoundedViewRegistry.swift`
  prints 8 under both greps; the brackets keep the comment from matching its own
  pattern).

## M4

`theObjectLockSentenceNamesWhatTheCheckboxIsCalled` now also pins, for `en`
only, that the clause says the lock can be **chosen** and when it is **created**
(source language; no cross-locale derivation exists). RM4 (en clause rewritten
to "a bucket cannot be changed afterwards.") is **RED**; P17 (clause deleted from
all four) still **RED**. Limit unchanged for fr/de/pl: shape plus the bucket
noun.

## N2: whole tokens, and what it took

`identifierTokens(in:)` splits on non-identifier characters. It took three tries,
all recorded in `0ef4e3f5`'s message:

1. `5ba1f50b`: RP2 (a member named `nameIsTaken`) was GREEN. My own tokeniser
   test spelled `"nameIsTaken"` in a string literal, and the sweep reads this
   file's string literals.
2. `4cad4c20` computed the prefix; RP2 was **still GREEN**, because the catalogue
   key literal `"s3.createBucket.nameIsTaken"` splits into that same token.
3. `891bb0c2`: the sweep removes string literals (`withoutStringLiterals`,
   with its own unit test and positive control) before tokenising. RP2 is now
   **RED**, and so is RP1 (`zzzNothingNamesThis`).

Cost, stated: interpolations inside string literals are dropped with them, which
only makes the sweep stricter; and the sweep is still nominal (a mention, not an
assertion), as the coordinator's note on it says.

## N3

`task-11-fix-1-report.md`'s M6 line is corrected in place, quoting "35 sites in
tests and the registry" and giving
`git grep -o 'CreateBucketModel(' 1d1dcec2 -- Tests | awk -F: '{print $2}' | sort | uniq -c`
(41 in `CreateBucketSheetTests.swift` + 7 in `BoundedViewRegistry.swift` = 48).
I ran that command here and it printed those two lines.

## N4

Three withdrawals now carry their quote, in the comment beside the replacement:
the old template's doc line ("The create went through and the versioning request
after it did not."), `theRoutesGateAsksTheModelsRule`'s "And the arm is the
inverse of its neighbours' bucket test: a row that is live only AT the list." with
`#expect(arm.contains("context.bucket == nil"))`, and `aFindingSaysItsOwnSentence`'s
`#expect(model.bucketMayExist == false)`. Checked, not assumed: the third was
not quoted verbatim next door (that comment paraphrased it); it is now.

## Probes

Six, in `0ef4e3f5`'s message, all through `scripts/mutation-probe` against
`891bb0c2`: RP3, RP3b, RP2, RP1, RM4, P17: all RED, controls 63 and 84 tests with
0 pre-existing failures, tree clean after each.

## Not done

M1, M3 untouched (as instructed). M7 stands. The `\b` nondeterminism is not
revisited. Nothing I could not do.
