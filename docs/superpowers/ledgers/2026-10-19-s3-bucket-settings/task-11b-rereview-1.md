# Task 11b re-review 1

HEAD daff1df5, BASE 31c39ec1.

## Designed probe X1: exact pre-fix I1 behaviour

Plant (from the d0bafd4f diff, the removed lines restored in the catch of the lock read in `read`): the five lines `if state == .enabled { load = .failed(lockReadFailedLine.text); return }; lock = nil` replaced by the two pre-fix lines `load = .failed(Self.lockReadFailedLine.text); return`. Filter `BucketVersioning|BoundedView|SheetBound`, run through scripts/mutation-probe on the committed tree (HEAD daff1df5).

Result: control 62 tests, 0 pre-existing failures; planted 62 tests; **RED**, caught by `aLockThatCannotBeReadDoesNotCostABucketThatIsNotEnabled` and `enablingAfterAFailedLockReadAsksAgainAndNeverGoesSilent`. Not BUILD FAILED. Tree clean afterwards.

## Re-runs (extracted with awk from the commit message of daff1df5, run with bash from the repo root, unedited)

- P8 (`awk '/^    scripts\/mutation-probe/ && /--label .P8 /'`): control 62 tests, 0 pre-existing failures; planted 62; **RED**, caught by `theKnownStateDrawsTheReasonNothingIsOffered` alone.
- P5 (same awk, `.P5 `): ran unedited, no repair needed (M3 closed for this probe). Control 35 tests, 0 pre-existing failures; planted 35; **RED**, caught by `theCacheTravelsFromTheSessionToTheRead` alone. Note: the message says control 32 tests "on c98649ca"; 35 at HEAD is 32 plus the three tests this round added, consistent.

## Extra probe X2 (collapse of "failed" and "unread")

`if bucketHasObjectLock == nil, lockReadFailed {` changed to `if bucketHasObjectLock == nil {`. Control 62, planted 62, RED, caught by `anUnreadLockStateOffersNothingAndSaysNothingAboutLocks` and `enablingAfterAFailedLockReadAsksAgainAndNeverGoesSilent`. The collapse in that direction is held by two tests.

## Claims

1. CONFIRMED. Read `read`/`apply`/`blockedReason`/`lockReadFailed` at HEAD. `read`: the lock catch is fatal only under `state == .enabled`, otherwise `lock = nil`, `lockReadFailed = lock == nil`, `load = .known(state)`. `apply(_:bucket:via:locks:)` has a required `locks:` (no default; the sheet button passes `locks: locks`), re-asks when `bucketHasObjectLock == nil`, sets `lockReadFailed` true on a second failure. `blockedReason` gives lockRead only for `bucketHasObjectLock == nil, lockReadFailed`; unread (`!lockReadFailed`) returns nil. Tests assert the unread distinction (`!unread.lockReadFailed`, `blockedReasonKey == nil`) and X2 shows it held by two tests.
2. CONFIRMED with a limit. `theKnownStateDrawsTheReasonNothingIsOffered` is positive (`#require`s for `content`, `case .known:`, the warning draw and the blocked draw, then `warning.lowerBound < blocked.lowerBound`); the warning draw is the positive control. It reads the model member (`model.blockedReason`) off the view source through comment/string-blanked code; no catalogue key is spelled. It spells the member and the local name `blocked`, so a rename fails loudly, not silently. P8 RED on HEAD by this test alone.
3. CONFIRMED. The `lines` quote matches 31c39ec1 line 213 verbatim; "three listed, four in the body" is right (stateLine, warning, blockedReason, offered buttons). `warning` has an in-line comment on the new nil branch (nothing to withdraw). Registry: the quoted "the suspended one its own state sentence and no warning" and "Five states (four until Task 11b added the lock-bearing one, below the refused read)" both match 31c39ec1 (the second joins a line break); the new list has five entries (never, enabled, suspended, refused, enabled-under-lock); `grep -c 'BucketVersioningSheet($'` prints 5 and `grep -o 'BucketVersioningSheet($' ... | wc -l` prints 5. The `blockedReason` and `read` quotes also match 31c39ec1 verbatim.
4. P10 and P11 each have a single catcher, as disclosed, but neither is held by something weaker than it looks: P10 is held by three sub-scenarios (healed, locked, stuck; each asserts `hasLockReads == ["b","b"]` or its outcome), P11 by the stuck scenario's `blockedReasonKey` and `lines.contains`. Expectations do not abort, so all three scenarios run in one failure. The cost is diagnosis and fragility (one test, three properties, a dependency on `setHasLockError` in the fake), not sensitivity. The opposite direction (X2) has two catchers. Not a finding.

## New finding

**N1 (Minor, stale comment beside changed code; no quote).** `Sources/MacSCPAppKit/BucketVersioningSheet.swift` lines 48-49, doc comment of `bucketHasObjectLock`: "Set together with `load` going to `.known` (`read`), never after it, so a settled sheet is never waiting on a second answer." False since d0bafd4f: `apply` sets `bucketHasObjectLock` when `load` is already `.known`, and a settled sheet with an unreadable lock now does wait on a second ask by design. Found with `grep -rn -e 'second answer' -e 'never after it' Sources Tests`. The project's "comments that describe other code" failure, in a file the diff touched.

## Gate

The gate can close. X1 (exact pre-fix I1) is RED with two catchers, so the I1 fix is guarded; P8 RED; P5 ran as committed, unedited (M3 closed); M2/M4 corrected with matching quotes and a correct count. N1 is a Minor to fix or accept.

## Not checked

I3 (user docs in noix-docs) was out of scope. Did not re-run P1-P4, P6, P7, P9-P11. Did not verify the four catalogues this round (the diff touches none). X1 restores c98649ca's behaviour on HEAD; it is not a run on the c98649ca tree itself.
