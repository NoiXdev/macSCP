# Task 10 report — the Object Lock sheets

BASE `2d489afd`. One commit, `7afd772f` (squashed from `51ac79b9`, `ffa4fe9a`,
`f83e0db8`; the probe hashes in its message are the pre-squash ones). Not
pushed. Status: **DONE_WITH_CONCERNS** (concerns below; none blocks).

## What was built

- `Sources/MacSCPAppKit/ObjectLockSheet.swift` — the per-file sheet
  (`ObjectLockSheet`, `ObjectLockModel`), `ObjectLockTarget` (path to bucket and
  key), `ObjectLockFileAction` (the two ids to their sheet), `ObjectLockDates`
  (a date written for the locale), `ObjectLockLines` (the shared sentences).
- `Sources/MacSCPAppKit/BucketObjectLockSheet.swift` — the bucket default.
- `Sources/MacSCPAppKit/ObjectLockStateCache.swift` — per-bucket, session-long.
- Wiring: two `fileActions` on `s3Descriptor`; the id-keyed arm in
  `handleBrowserMenuEntry` beside `s3.presignedURL`; `ConnectionActionRoute.objectLock`
  with its own arm; two sheet items and `.sheet(item:)` presentations;
  `BrowserSession.objectLockStates` set in `startSession` through
  `BrowserSession.objectLockStates(for:)`.
- 39 `s3.objectLock.*` keys plus `browser.action.retention` / `.legalHold` in
  en, de (du-form), fr, pl.
- Tests: `ObjectLockSheetTests`, `BucketObjectLockSheetTests` (79 tests across
  the two suites), one in `ConnectionActionRouteTests`; `FakeBucketSettings`
  extended with an `ObjectLockFixture`; registry entries (11), floor 35 -> 37,
  `RigidControlScanTests` tables.

## The COMPLIANCE path, as it stands

A COMPLIANCE write reaches the store only if `canRun` is true, `run()` checks it
itself, and `canRun` is the emptiness of `RunBlocker.allCases.filter(isActive)`,
a `switch` with no `default`. The relevant blockers: `complianceNotAcknowledged`,
`dateNotInFuture`, `noLockOnBucket`, `lockUnread`, `lockReadFailed`,
`currentUnread`, `applying`.

The acknowledgement is a statement about one date and one mode. `acknowledged`
is cleared by any change of `mode` or `retainUntil` (writing back the same value
is not a change and keeps it), and by a successful write. The sentence names the
date and time in the reader's locale. The sheet starts on GOVERNANCE, a week
ahead, to the whole minute.

State space (the Task 9 hint): `ObjectLockSheetTests.scenarios` is the cross
product focus x lock fact x current read x mode x acknowledged x date x hold =
256 states, built from `CaseIterable`s, none written by hand.
`inNoStateDoesRunWriteWhatCanRunRefused` runs `run()` in every one and asserts
that it writes exactly when `canRun` said it could, that a legal-hold sheet
never writes a retention and the reverse, and that every COMPLIANCE write in
the 256 carries an acknowledgement, a lock-bearing bucket and the acknowledged,
future date. `everyBlockerCanBeTheOnlyReasonRunIsOff` asserts each blocker is
reachable alone (`applying` has its own test with a held write). The bucket
default has the same structure (`BucketObjectLockSheetTests.scenarios`, 288
states).

## Decisions that were mine (please look at these)

1. **One sheet type, two foci, rather than one sheet that carries both.** The
   brief says the per-file sheet "carries mode, date, legal-hold toggle". I
   opened it for ONE thing per action (`ObjectLockFileAction.focus`): "Retention…"
   shows mode, date and, for COMPLIANCE, the acknowledgement; "Legal Hold…" shows
   the toggle only. The reason is the one the dispatch gave: a click meant to
   lift a hold should not sit a field away from a COMPLIANCE write. A test pins
   that the legal-hold sheet never writes a retention. If you want the combined
   sheet it is a model change, not a rewrite.
2. **The bucket default carries the same COMPLIANCE ceremony.** The brief is
   silent about it. A COMPLIANCE default is every future file's lock, so I held
   it to the same standard. There is no single date; the acknowledgement says
   what is true of every file and names the day a file added now stays locked
   until.
3. **Days are bounded to 1...36500 in the bucket default**, a ceiling that is
   macSCP's own (not a claim about any store), so that the date in the
   acknowledgement is always one the calendar can count. The floor is Core's.
4. **`FakeBucketSettings` instead of the brief's `CountingBucketSettings`**, as
   the dispatch said (no second fake).
5. **The brief's four tests take a `now:`.** As written they use 2027-01-01
   against the wall clock and would go red on that date.
6. **The refused-retention sentence is hedged**: "A retention that is already in
   force may not be shortened, and your access key may not be allowed to change
   it." A refusal reaches the app as `permissionDenied` / `authenticationFailed`
   and the answer does not say which. I did not contact the rig, so I have not
   measured what a refused `setRetention` actually returns there. If Task 1's
   mapping turns it into a named finding, the finding's own sentence is shown
   instead (the model prefers a finding).
7. **The days in sentences never sit inside a plural.** "Retention period in
   days: N" and "a number of days from 1 to N" avoid four plural forms (pl has
   few/many). The cost is slightly stiff English.

## Red, observed

Three compile-failure runs; no behavioural test ran red before the models
existed, and none is claimed to have. Quoted from the stripped logs
(`scratchpad/sdd10/red1.txt`, `red2.txt`, `red3.txt`):

1. `swift test --filter ObjectLockSheetTests --filter BucketObjectLockSheetTests --filter ConnectionActionRouteTests`,
   production files moved aside, 71-line log. First error line:
   `ConnectionActionRouteTests.swift:110:39: error: type 'ConnectionActionRoute' has no member 'objectLock'`;
   6 error lines, all in that file (5x "has no member 'objectLock'", 1x
   "cannot find 'BucketObjectLockSheet' in scope" at :256:51). The build stopped
   there: the two new test files reported no error line in this run.
2. Route edits reverted (by an edit; `git checkout` was not used), same filter
   minus the route suite: 45 error lines, all in `BucketObjectLockSheetTests.swift`,
   first `:269:62: error: cannot find type 'BucketObjectLockModel' in scope`; one
   was "the compiler is unable to type-check this expression in reasonable time"
   (arithmetic literals in `#expect`, rewritten as typed constants).
   `ObjectLockSheetTests.swift` reported no error in that run.
3. `BucketObjectLockSheetTests.swift` moved aside, `--filter ObjectLockSheetTests`:
   99 error lines, all in `ObjectLockSheetTests.swift`, first
   `:448:20: error: cannot find type 'ObjectLockModel' in scope`.

Guard reds on the first implementation, from `swift test --filter macSCPAppKitTests`:
`noRigidComponentIsHeldToAWidthFrame(component:)` for RadioChoice and CheckboxRow
(`RigidControlScanTests.swift:608:9: Expectation failed: inspected == component.sites`),
`onlyTheListedSitesOptIntoWrapping` (`:785:9: wrapping == expected`),
`everyConformerIsInTheRegistry` (`BoundedViewCoverageTests.swift:89:9: declared == measured`).

## Green

`swift test`, no flags: Core 5074 passed; App 2742 run, exactly one failure,
`ViewTestabilitySpike` "Varying only isRegex leaves the pixels unchanged"
(`ViewTestabilitySpike.swift:202:9`), the failure Tasks 8 and 9 record on their
own bases; **not re-measured against this task's base**.

## Mutation probes

34 probes, each through `scripts/mutation-probe` on a committed tree, each
RED (caught) after a control run with 0 pre-existing failures. The exact
`--filter` and `--apply` of every one, with the tests that caught it, are in the
commit message of `7afd772f` (`git show 7afd772f`). Highlights:

- P6 (`guard canRun` removed from `run()`) first PARKED for ten minutes: the
  in-flight tests hold a write in the fake and, with the guard gone, never
  reached the line that releases it. I killed the probe with TERM (the script
  reverted; `git status --porcelain` was empty afterwards), gave both tests
  `.timeLimit(.minutes(1))` and a releasing `defer`, committed, and re-ran.
- P17 / P18 (the session's cache) were added because I found a hazard by
  asking what would be green if the cache were never created: nothing. A
  session without it makes the menu row and both file actions live and inert.
  It is now `BrowserSession.objectLockStates(for:)` with a test, and a scan that
  `startSession` calls it after building the session.
- P29-P32 hold the arm and the views to the file that was chosen (focus, path,
  key/bucket order), which no other test would have seen.

## Concerns

- **Nothing visual was verified.** No test here draws a view. How the radio
  group, the date picker, the wrapped acknowledgement and the days field look is
  for the maintainer's check. The layout guard measured the width of eleven new
  states in four languages (all green), including a 400-character file name.
- **A date's locale is `Locale.current`**, not the app's language override
  (which only tests set), like the other date displays in the tree. A user whose
  region and language differ sees the region's format.
- **`acknowledged` is a plain `var`.** Only the checkbox writes it today; a
  future caller that set it programmatically would be trusted. `run()` cannot
  tell. The tests pin what resets it, not who may set it.
- **The file actions are offered on every S3 file**, lock or not; the sheet
  explains a bucket with none. The row's availability does not read the cache.
- **No behaviour is restricted by the file's current retention.** A file already
  under COMPLIANCE can be offered GOVERNANCE or a shorter date; the sheet shows
  the current state and the store refuses. I did not add a rule about what S3
  allows because I have not measured it.
- Not done, by scope: the audit trail (Task 12), create-bucket (Task 11), user
  documentation (the plan's closeout; `noix-docs` untouched).

## Process notes

- To observe the reds I moved the three new production files to the session
  scratchpad (untracked, so safe) and, for run 2, reverted my own route-test
  edit by a scripted edit and restored it by copying the saved file back. No
  `git checkout -- <file>` and no bare stash anywhere.
- The rig was not contacted; nothing was written to any bucket, and no
  COMPLIANCE retention was placed on anything.
