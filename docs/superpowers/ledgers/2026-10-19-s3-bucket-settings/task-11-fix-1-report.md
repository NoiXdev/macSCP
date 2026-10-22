# Task 11, fix round 1

BASE `d7c6631c`; four commits on top, none amended, each green on its own
(the first two ran the focused suites, `c50759d0` the full suite).

- `0fde99b6` refactor(app): the create row's rule lives in `isOffered`, and the list is never assumed known (I3, M6)
- `91ad6078` fix(app): a bucket the store says we own is taken, and say only what was read (I1, M2, M8)
- `c50759d0` test(app): read every sentence a person reads, and guard the creation clause (I2, M4, M5)
- `1d1dcec2` test(app): the thirteen probes, re-run with their commands, and ten more (I4; its message IS the probe record)

## Full suite at `c50759d0`

Core 5075 passed. App 2812 tests, one red: `ViewTestabilitySpike` "Varying only
isRegex leaves the pixels unchanged" (`:202:9`), the pre-existing one. After
`1d1dcec2` (a one-word test rename) `CreateBucketSheetTests` was re-run: 47 passed.

## I4: the probes

All 13 re-run on the committed tree, plus 10 new (23 in all). **All 23 reproduced
RED**; none GREEN, none BUILD FAILED. The full record (id, `--filter`, `--apply`
as the shell hands it over, control count, result, catching tests by name) is in
the message of `1d1dcec2` (`git log -1 --format=%B 1d1dcec2`). Control counts
were 60 tests (58 for the layout-guard filter), 0 pre-existing failures each;
tree clean after each.

Stated plainly: P1, P2 and P3 had to be **re-anchored**, because I3 removed the
text their first `--apply` strings matched (`&& context.bucket == nil`). P4-P13
are the first report's strings, unchanged, and reproduced. The first report's
catcher omission is repaired: every RED now names its catchers (e.g. P9 is
caught by `theLockRefusesToLetVersioningBeUntickedAndShowsItTicked` alone).

## I1

`.bucketAlreadyOwnedByYou` now inserts the name into the taken set and returns
`bucketMayExist: true` (so the pane refreshes and `canCreate` is false); the
finding's own sentence is shown. `.bucketNameTaken` is left as it was: another
account's bucket is not in "your list", and nothing here is stale. Tests assert
`canCreate`, `nameIsTakenKey`, `bucketMayExist` and `showsNameIsTaken` per
finding (`aBucketTheStoreSaysYouOwnIsTakenAndTheListIsStale`,
`aNameAnotherAccountOwnsIsNotInYourListAndNothingIsStale`). Probes P14a (list
left unrefreshed) and P14b (name left free) are RED, caught by the first.

Honesty note: I wrote these tests and the fix in the same step and did not run a
separate red before the fix; the red is demonstrated by P14a/P14b.

## I2: the sweep

Found by running `grep` for every member the view reads (now a test:
`everyMemberTheViewReadsIsNamedByATest`, which reads the view's `model.x` /
`CreateBucketModel.x` and requires each to appear in the suite; its positive is
`read.count >= 15`). It found, beyond the four the reviewer named, six static
lines no test named (`actionLine`, `creatingLine`, `listingUnknownLine`,
`nameHintLine`, `nameIsTakenLine`, `versioningLabel`) and two decisions that
lived inline in the view (the versioning note's choice and the checkbox's
enabled state), now `versioningNoteLine` and `versioningCanBeChanged` on the
model. Pinned: `aSubstitutedSentenceNeverShowsItsPlaceholder` (all four
locales, three `%@` sentences), `everyProblemSentenceIsPlainTextOnceFilledIn`,
`theFieldsAreEditableExceptWhileCreatingAndOnceCreated`,
`theStateFlagsTheViewShowsAreTheOutcomeAndNothingElse`,
`theVersioningCheckboxAndItsNoteFollowTheLock`,
`theLinesTheViewShowsAsTheyStandCarryNoPlaceholder`.

The reviewer's plant (P16, same `--filter`, both substitutions dropped) is RED,
caught by `aSubstitutedSentenceNeverShowsItsPlaceholder` and
`everyProblemSentenceIsPlainTextOnceFilledIn`; each substitution alone (P16a,
P16b) is RED too. Plants for `isEditable` (P18) and the versioning note (P19) RED.

A limit of the sweep test: a mention is not an assertion. The first draft
matched names with a `\b` regex and returned inconsistent results between runs
(`canCreate` was "unnamed" in one run and not in the next); I did not find out
why and replaced it with a plain substring check.

## I3

`isOffered(rootIsContainerList:paneBucket:)` now states the whole rule
(`rootIsContainerList && paneBucket == nil`); the route's arm passes
`paneBucket: context.bucket`. The brief's seventh body
`theRowIsLiveOnlyWhileThePaneIsSHOWINGTheBucketList` is in verbatim.
`theActionIsOfferedOnlyInBucketListMode` gained the second argument (old
wording quoted in a comment); `theRoutesGateAsksTheModelsRule` now requires
both arguments in the arm and that it never reads `context.bucket != nil`.
Probes: P1/P2/P3 (the arm), P3b (`isOffered` ignoring the pane) RED, P3b caught
by the new seventh test.

## Minor

- **M2** The follow-up read answers existence, so the sentence now says "A
  bucket named X exists now, but the request to create it with the settings you
  chose did not complete" (key `createdIncompletely` -> `existsIncompletely`, all
  four catalogues). A plain create's "could not be created" asserted a non-event
  nothing checked; it now says "The request to create the bucket failed".
  `create(via:)`'s "found means the create had gone through" is corrected in
  place with the old words quoted. Test `aFailureOfTheSecondRequestSaysTheBucketWasCreated`
  renamed `...SaysTheBucketExists`.
- **M8** One model decision, `showsNameIsTaken` (`nameIsTakenKey != nil &&
  !bucketMayExist`); the view reads it. P15 RED.
- **M4** `theObjectLockSentenceNamesWhatTheCheckboxIsCalled` now also requires
  the clause after the semicolon and that it names a noun derived from the
  sheet's own title and name label (not spelled). Deleting the clause from all
  four catalogues (P17) is RED. **Limit, stated:** it pins that the clause exists
  and talks about buckets, not that it says "creation"; the nouns derived are
  the bucket word, which every locale shares. I could not derive a creation word
  per locale (the French sentence says "création", the action says "Créer").
- **M5** Follows the sibling shape: named `planted` constant, the `Bool` computed
  before the expectation, both the credential and the host checked.
- **M6** `existingNames` and `listingIsKnown` have no default; spelled at every
  construction site (**Corrected in fix round 2 (N3).** This read, verbatim: "35 sites in tests and the registry". Withdrawn: the figure had no command behind it and was wrong. Occurrences of the constructor in the tests at `1d1dcec2`, counted by `git grep -o 'CreateBucketModel(' 1d1dcec2 -- Tests | awk -F: '{print $2}' | sort | uniq -c`, are 41 in `CreateBucketSheetTests.swift` and 7 in `BoundedViewRegistry.swift`, 48 in all. None in Sources besides
  the `Listing` convenience init). This changed the call spelling of the brief's
  six test bodies (`CreateBucketModel()` -> `CreateBucketModel(existingNames: [],
  listingIsKnown: true)`), not their values or expectations. Compile-time, so no
  probe.

## Deferred, as told

M1, M3 untouched. M7 recorded, no rebase.

## Could not do / concerns

- The sweep's guard is nominal (names, not assertions); see above.
- No rig, no GUI.
- The catalogue strings for `existsIncompletely` and the new `create` line are
  new German/French/Polish text written by me; German in du-form
  (`GermanAddressFormTests` green in the full run).
