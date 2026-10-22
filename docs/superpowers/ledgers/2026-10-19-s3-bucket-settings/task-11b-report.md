# Task 11b report

Status: DONE_WITH_CONCERNS (concerns at the end). Base `eff615ef`.

Commits:
- `c98649ca` fix(app): a bucket under Object Lock is not offered a suspension it cannot have
- `31c39ec1` test(app): the probes of Task 11b, run through scripts/mutation-probe (empty commit, carries the probe record)

## Red, quoted verbatim

After adding the brief's four tests and running `swift test --filter BucketVersioningSheetTests`:

`BucketVersioningSheetTests.swift:41:83: error: extra argument 'bucketHasObjectLock' in call`

(and the same at `:49:83`; the whole target failed to compile, which is the red.)

## What changed (read back from `git diff --stat eff615ef c98649ca`, 11 files, +396 -44)

Model (`BucketVersioningSheet.swift`):
- `bucketHasObjectLock: Bool?` stored property, `private(set)`; doc says `nil` is not `false`.
- `offeredStates`: `.enabled` offers `[.suspended]` only when the lock reads `false`; `true` and `nil` offer `[]`. `.never`/`.suspended` still offer `[.enabled]` whatever the lock. The doc comment is corrected in place with the old text quoted verbatim.
- `blockedReason` / `blockedReasonKey`: non-nil only for `.enabled` with a lock READ as `true`. An unread lock says nothing about locks.
- `warning` for `.enabled` is now `nil` when suspension is not on offer (a warning about a click that is not there). This is beyond the brief; see concerns.
- `read(bucket:from:locks:)` replaces `read(bucket:from:)`: versioning read, then `locks.hasObjectLock(bucket)`, and only then `bucketHasObjectLock = lock; load = .known(state)`. `load` stays `.reading` until both answers are in. A failed lock read is `.failed(lockReadFailedLine.text)` (fixed sentence, error never quoted).
- Two new catalogue lines in `fixedLines`/`lines`: `s3.versioning.objectLockKeepsItOn`, `s3.versioning.error.lockRead`; four catalogues (en, de in du-form/no addressing needed, fr, pl); `plutil -lint` OK on all four.
- Sheet: `locks: ObjectLockStateCache` required stored property and init parameter, no default; `.task` calls `model.read(bucket: bucket, from: settings, locks: locks)`; the blocked reason is drawn in the `.known` branch.

Call chain: `ContentView+MenuActions.swift` versioning arm passes `states: session.objectLockStates ?? ObjectLockStateCache(settings: settings)` into `BucketVersioningSheetItem.states` (new `let` in `ContentView.swift`, no default); `ContentView+Sheets.swift` passes `locks: item.states`.

Tests: the brief's four verbatim; `FakeBucketSettings.ObjectLockFixture` gained `hasLockEntered`/`hasLockRelease` (same pattern as the write gate); registry gained a fifth versioning entry (lock-bearing) and every entry passes `locks:`.

## Decisions asked of me

1. **Construction-site count.** Command: `grep -rno 'BucketVersioningModel(' Sources Tests | wc -l`. Before: **28** (1 + 4 + 23). After: **44** (1 in the sheet source, 5 in `BoundedViewRegistry.swift`, 38 in `BucketVersioningSheetTests.swift`), because the new tests construct more models. The figure that matters: `grep -rno 'BucketVersioningModel(current: [^)]*)' Sources Tests | wc -l` prints 31, and `... | grep -vc 'bucketHasObjectLock'` prints 1 -- that one is a comment that quotes the old call (`BucketVersioningSheetTests.swift:29`), so all 30 code sites with `current:` name the lock explicitly. No site relies on a default.
2. **The parameter is on `init(current:bucketHasObjectLock:)` only, not on `init()` and `init(loadFailure:)`.** Deviation from "lands on all three", and deliberate: `read` overwrites the lock state, so on `init()` a parameter would be dead, and on `init(loadFailure:)` there is no state to be locked in. Those two have nothing to keep silently from the old behaviour (they offer `[]`). If you want it on all three, it is a mechanical change; say so.
3. **The sheet's default model stays** (`model: BucketVersioningModel = BucketVersioningModel()`). The default can only be a reading model, which offers nothing until `read` answers, and `read` takes the lock from `locks`, which is required with no default. So the default cannot keep the old behaviour. `locks:` is the parameter that has no default.
4. **nil cache.** Checked: `session.objectLockStates` is set in `ContentView.startSession` from `BrowserSession.objectLockStates(for: fs)`, i.e. non-nil exactly when the file system is an `S3BucketSettings`, and the versioning row needs `context.settings != nil` (same file system), so in a live session it is non-nil whenever the row is live. Two existing tests pin that wiring (`aConnectionWithTheCapabilityGetsACacheAndOneWithoutDoesNot`, `startSessionPutsTheCacheOnTheSessionItBuilds`). I still did not let a nil leave a live-and-inert row, which is what the sibling Object Lock arm does (`guard let states`): the versioning arm falls back to a fresh cache over the same capability. Cost of the fallback: one extra lock read, and it would mask a missing wiring for THIS sheet (not for the other two; their tests are unchanged).
5. **Fold shape:** sequential (versioning, then lock) inside the one `read`, not `async let`. Simpler failure attribution; the cost is two round trips on first open, one when the cache already has the answer (`twoReadsOfOneBucketAskTheStoreOnceAboutTheLock`).

## Tests

New in `BucketVersioningSheetTests`: the brief's four; `aReadOfALockBearingBucketOffersNothingAndSaysWhy` (with positive control); `aSuspensionOnALockBearingBucketIsNeverSent`; `theVersioningAnswerDoesNotSettleBeforeTheLockAnswer` (lock read held at the store, asserts `.reading` in the window, `.timeLimit(.minutes(1))`, every wait an `await`); `aLockThatCouldNotBeReadLeavesASentenceAndNoOffer`; `twoReadsOfOneBucketAskTheStoreOnceAboutTheLock`; `theLockSentenceClaimsNoRefusalAndIsSaidInEveryLanguage` (positive: names Object Lock and says "cannot"; negatives: refus/reject/denied/error/fail/store); `theCacheTravelsFromTheSessionToTheRead` (source scan of the three hand-offs, ending on a count of exactly one `model.read(`). `everyLine()` now includes the lock-bearing state's lines, so the new sentence is held to four languages by the existing tests.

Moved tests: `anEnabledBucketCanBeSuspendedAndNotUnset` now names its bucket as lock-free; the comment quotes the old construction verbatim. `aRefusedReadSaysSoAndOffersNothing` and `aReadFillsTheState...` now pass a lock fixture and cache.

Full suite: `swift test` -> two Swift Testing runs print, one `Test run with 5075 tests in 407 suites passed` and one `Test run with 2826 tests in 238 suites failed ... with 1 issue` (the summary names `macSCPAppKitTests` as the failing target). The one issue is `ViewTestabilitySpike` "Varying only isRegex leaves the pixels unchanged" (`off == on`, `ViewTestabilitySpike.swift:202:9`), which fails identically on a detached worktree at `eff615ef` (removed afterwards), so it is not from this task.

## Probes (all via `scripts/mutation-probe`, committed tree `c98649ca`, `--filter 'BucketVersioningSheetTests'`, control 32 tests / 0 pre-existing failures, every one RED (caught), no BUILD FAILED)

The exact `--apply` strings are in `31c39ec1`. Summary:
- P1 lock check removed (brief's plant 1): caught by 4 tests.
- P2 `nil` treated as `false` (`!= true`), the brief's plant 2: caught by `aSuspensionOnALockBearingBucketIsNeverSent` and `anUnreadLockStateOffersNothingAndSaysNothingAboutLocks`, and NOT by `aLockBearingBucketIsNotOfferedSuspension` (as predicted: `true` is still refused).
- P3 read stores `false` instead of the cache answer: `aReadOfALockBearingBucketOffersNothingAndSaysWhy`.
- P4 `load = .known` before the lock read: `theVersioningAnswerDoesNotSettleBeforeTheLockAnswer`.
- P5 opener ignores the session cache, P6 sheet reads via a fresh cache, P7 sheet never reads: all caught by `theCacheTravelsFromTheSessionToTheRead` only.

## "What would be green if this were never wired?"

Answered with P5/P6/P7: before the scan existed, none of the model tests would notice (the model is right, the call site is wrong). The compiler enforces that `locks`, `states` and `read(..., locks:)` exist and are passed something; it cannot enforce that the something is the session's cache or that the sheet calls `read` at all. One caveat on the scan itself: it is a string scan of three files; its negative-style guards (the `locks: item.states` and `session.objectLockStates` substrings) each sit beside a positive (the same `#require` finds the call it slices), and P5-P7 are the proof it is sensitive to those three spellings, not to every spelling.

## Concerns

1. A failed lock read fails the whole load, so a key that may read versioning but not Object Lock configuration cannot enable versioning on a never-versioned bucket either. I judged an honest red sentence better than an enabled-but-silent sheet; the alternative (read the lock only when versioning is `.enabled`) leaves the model after `apply(.enabled)` with an unread lock and no suspend button. Your call if you prefer the other trade.
2. `warning` for an enabled bucket is now `nil` when suspension is not on offer (not in the brief). Reverting is one line if you want the cost warning to stay on a locked bucket.
3. `init()`/`init(loadFailure:)` do not take the parameter (decision 2).
4. The versioning row could still be live while the fallback masks a missing wiring of the session cache for this sheet only.
5. No user-doc change made: the brief's file list does not include `noix-docs`, but this is a user-visible behaviour change on a branch that, per project rules, closes with its docs; flagging for the closeout task.
