# Task 11 report: the create-bucket sheet

Status: DONE_WITH_CONCERNS (concerns at the end). Written from
`git diff --stat 8e21f073..HEAD` (17 files, 1407 insertions, 10 deletions) and the
test/probe output of this session, not from the plan.

## Commits (BASE 8e21f073)

- `52e30257` feat(core): `listedItems`, the directory's contents whatever the search hides
- `75fe0553` feat(app): create a bucket, with the two switches that are final
- `b7371a8f` test(app): pin what the mutation probe found unguarded in the create sheet
- `d7c6631c` fix(app): a create sheet built in a failed state came up without the failure

## Two things the dispatch did not know

1. **The brief file has no "Where `existingNames` comes from" section.** The dispatch
   cites it as the ruling for the gate; `task-11-brief.md` is 297 lines and the only
   `existingNames` in it is the one test body (`grep -n existingNames` prints line 134
   only). I worked from the dispatch's description of it (row live only at the bucket
   list; listing is `session.remote`'s).
2. **`RemoteBrowserViewModel.items` is the wrong member for `existingNames`.** It is
   the listing AFTER the pane's search filter (`applySearch()` writes it from the
   private `displayedAll`). With a filter typed at the bucket list, `items` omits
   buckets that exist, and the taken-name check then passes a name that is taken: the
   silent one-way door the sheet exists to stop. I added a Core accessor,
   `RemoteBrowserViewModel.listedItems` (= `displayedAll`, public read-only) with a
   test (`listedItemsIgnoreTheSearchFilter`, red first: "value of type
   'RemoteBrowserViewModel' has no member 'listedItems'"). This is the only Core
   change. `CreateBucketModel.listing(of:)` reads it, and reports the list as known
   only when `browser.state == .loaded` (an empty array before load is "no answer",
   not "no buckets").

## What was built

- `Sources/MacSCPAppKit/CreateBucketSheet.swift`: `CreateBucketModel` + `CreateBucketSheet`
  (`BoundedView`, `.width(480)`).
  - Brief names used verbatim: `canCreate`, `problem`, `objectLockNoteKey`
    (`s3.createBucket.objectLockIsFinal`), `versioning`/`objectLock`/`versioningIsLocked`,
    `protection`, `isOffered(rootIsContainerList:)`, `existingNames:`, `nameIsTakenKey`
    (`s3.createBucket.nameIsTaken`).
  - `protection` folds the two checkboxes into the one `BucketProtection` (lock first).
    No case added to `BucketProtection`, no pair of Bools passed to Core.
  - The Object Lock note says "you cannot undo it", not "decide now" (the ruling).
  - Two requests: on a failure with a protection asked for, the model does ONE read
    (`versioning(ofBucket:)`). Found -> sentence "created, but switching on versioning
    failed ... do not create it again". `RemoteFSError.notFound` -> plain "not created".
    Any other answer -> "may exist now; refresh the list". `bucketNameTaken` /
    `bucketAlreadyOwnedByYou` skip the read (only the create can say them). A create
    with no protection is one request and needs no read. A name that may exist is added
    to the taken names, so the sheet cannot send the re-create. No error is quoted.
  - After a create (or a partial failure) the sheet calls `onCreated`, which the
    dispatcher arm points at `session.remote.refresh()` so the bucket appears.
- Route: `ConnectionActionRoute.createBucket = "s3.createBucket"`. Its arm is the
  inverse of its neighbours: `settings != nil && CreateBucketModel.isOffered(rootIsContainerList:)
  && bucket == nil`. Both conditions are needed: `bucket == nil` alone is true for a
  one-bucket connection with a blank configured bucket (test covers it).
- Dispatcher arm in `ContentView+MenuActions.swift`, `CreateBucketSheetItem` in
  `ContentView.swift`, `.sheet(item: $createBucketSheetItem)` in `ContentView+Sheets.swift`.
  `ContentView+Lifecycle.swift` needed no change: Task 8's hook already asks the route.
- Catalogues: 23 keys `s3.createBucket.*` in all four, German in du-form (the full
  suite includes `GermanAddressFormTests`: green).
- Tests: `CreateBucketSheetTests` (36 tests: the brief's six plus 30), route tests,
  `FakeBucketSettings` extended (`createBucket` records calls; `CreateFailure.refused` /
  `.afterTheBucketExists`; after a refused create, `versioning(ofBucket:)` answers
  `.notFound`), 7 `BoundedViewRegistry` entries, floor raised.

## Task 10's sentence (`s3.objectLock.notEnabledOnThisBucket`)

Checked against what the sheet offers, in all four catalogues. Its last clause ("it can
be chosen when a bucket is created") is now true: the sheet has a checkbox labelled
"Object Lock" / "Objektsperre" / "Verrouillage d'objet" / "Blokada obiektów". The
sentence is unchanged. `theObjectLockSentenceNamesWhatTheCheckboxIsCalled` reads the
sentence from the catalogue and the label from the model, per locale, case-insensitively,
so renaming one without the other is red. (Not mutation-probed.)

## Red, quoted verbatim

- Core: `error: value of type 'RemoteBrowserViewModel' has no member 'listedItems'`
- App (before implementation): `error: cannot find 'CreateBucketSheet' in scope`;
  `error: type 'ConnectionActionRoute' has no member 'createBucket'`
  (`CreateBucketModel` not found likewise).
- Later red: `Expectation failed: model.failureSentence == "it did not work"` and
  `Expectation failed: model.bucketMayExist` (`aSheetBuiltInAFailedStateShowsTheFailureForItsName`).

## Tests that had to change, and why

- `ConnectionActionRouteTests.aWiredIdIsAvailableAndAnUnwiredOneIsNot` expected every
  wired row live in ONE context (inside a bucket); the new row is correctly dead there.
  Now: live in at least one of {inside a bucket, at the list}; unwired in neither. The
  change is marked in the doc comment with the old wording quoted.
- `BoundedViewCoverageTests`: floor 37 -> 38, counted by the comment's command
  (`grep -rhn -e '^ *struct [A-Za-z]* *: BoundedView {' Sources/MacSCPAppKit | wc -l`
  prints 38 under the session grep and `/usr/bin/grep`); old wording quoted.
- `RigidControlScanTests`: `CheckboxRow` sites +2 in `CreateBucketSheet.swift`; counts
  by the three greps now 13 / 4 / 12 (29 lines, 28 in the table); old wording quoted.

## Mutation probes (all through `scripts/mutation-probe`, committed tree, filter
`CreateBucketSheetTests|ConnectionActionRouteTests`, clean tree after each)

| Plant | Result |
|---|---|
| P1 drop `bucket == nil` from the arm | RED (caught) |
| P2 `isOffered(...)` replaced by `true` | RED |
| P3 arm copies the neighbours' `settings != nil && bucket != nil` | RED |
| P4 `protection` ignores the lock | RED |
| P5 taken names no longer block `canCreate` | RED |
| P6 unread list vouches for names | RED |
| P7 `listing(of:)` reads `items` not `listedItems` | RED |
| P8 maybe-made bucket not added to taken names | RED |
| P9 observer refusing to untick versioning removed | **GREEN** at first |
| P10 dispatcher passes an empty listing | RED |
| P11 `.sheet(item: $createBucketSheetItem)` block removed | RED |
| P9 again, after `theLockRefusesToLetVersioningBeUntickedAndShowsItTicked` | RED |
| P12 sheet never calls `onCreated` | RED |
| P13 arm does not call `remote.refresh()` | RED |

P9 was a real hole: `protection` reads the lock first, so nothing looked at the
checkbox's own state. The probe script prints "caught by:" without the test names in
my filtered output; I did not capture which test caught each plant.

## The layout guard found a bug I wrote

`entriesOfOneTypeMeasureDifferentStates` went red (three registry entries measured the
same in every catalogue). Cause: the observer on `name` that clears a stale failure also
ran for the name assigned in `init` (observers run in `init` on an `@Observable` class),
so the "failed" entries came up with no failure on them. Fixed by assigning the name
before the outcome; the test above pins it. The guard then passes all 7 entries in four
languages at 480.

## What would be green if this were never wired

Asked of each link: the route case (compile error without an arm: no `default`), the
arm's availability (`createBucketIsLiveOnlyAtTheBucketList`, P1-P3), `isOffered` having
a caller (`theRoutesGateAsksTheModelsRule`, P2), the arm building the sheet from the
pane's listing (`theDispatcherHandsTheSheetTheRemotePanesListing`, P10), the sheet being
presented (existing `theStateTheDispatcherSets...`, extended with
`CreateBucketSheet`, P11), and the refresh after a made bucket
(`aMadeBucketRefreshesThePaneThatListsIt`, P12/P13). The scans are source scans, as the
neighbours' are: none draws the view.

## Full suite

`swift test`, no build-system flag, run twice: Core 5075 tests passed; App 2801 tests,
one red, `ViewTestabilitySpike` "Varying only isRegex leaves the pixels unchanged"
(`:202:9`), the pre-existing red Tasks 1, 8, 9 and 10 already record.

## Concerns

1. **Nothing was run against the rig and the GUI was never launched.** That the store
   answers a missing bucket's `GET ?versioning` with a 404 that `mapErrorStatus` turns
   into `RemoteFSError.notFound` is read from `S3FileSystem.mapErrorStatus` (404 ->
   `.notFound`), not measured. If a store answers differently, the model says "may
   exist", which is the safe side.
2. `bucketNameTaken`'s sentence is Core's ("already taken by another account"). I show a
   finding's own sentence, as the other sheets do; it is the store's named code, but if
   you want the sheet to promise no cause even there, that is a one-line change.
3. Retrying a partially made bucket is blocked in the same sheet (the name goes into
   the taken set). The user is told to open Versioning / Object Lock for it instead.
4. User docs (`noix-docs`, CLAUDE.md "ships with the feature") not touched: this task's
   file list has none and I did not find a docs step in Task 11's brief; the closeout
   task should cover "Create Bucket".
5. Task 11b (versioning under Object Lock) not started, as scheduled.
