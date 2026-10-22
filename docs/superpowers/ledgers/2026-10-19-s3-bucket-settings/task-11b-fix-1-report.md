# Task 11b, fix round 1

Base `31c39ec1`. Commits on top, no amend, no rebase:
- `d0bafd4f` fix(app): a lock that cannot be read costs only the bucket that needs it; the sheet draws why (I1, I2, M2, M4)
- `daff1df5` test(app): the probe record of Task 11b, in a form that runs (review M3), plus P8-P11 (empty commit)

Not touched, as instructed: I3 (`noix-docs`, Task 13's) and M1 (the unreachable fallback).

## I1 (both halves)

`BucketVersioningModel` (read back from the diff):
- `read(bucket:from:locks:)`: a failed lock ask is a failed load (`lockReadFailedLine`) only when the versioning state is `.enabled`. For `.never`/`.suspended` the load settles `.known(state)` with `bucketHasObjectLock == nil` and the new `lockReadFailed == true`. `lockReadFailed` is reset on entry with the lock.
- `apply(_:bucket:via:locks:)` gained a required `locks` parameter (no default). After a successful write, if `bucketHasObjectLock == nil` it asks the cache again (failures are not cached, so it is a real second ask) and sets `lockReadFailed` from the outcome, then sets `load`. The ask is outside the write's `catch`, so its failure cannot be reported as a failed write.
- "Failed" is its own state: `lockReadFailed` is distinct from `nil` with `lockReadFailed == false` ("not asked yet"). `blockedReason` now returns `objectLockKeepsItOnLine` for a lock read as `true`, `lockReadFailedLine` for an enabled bucket with `bucketHasObjectLock == nil && lockReadFailed`, and `nil` otherwise, so an unread lock still says nothing about locks (the brief's third test is untouched and green). `lockReadFailedLine` therefore only ever shows for `.enabled`, where "cannot be changed here" is true.
- The sheet's `Task { await model.apply(...) }` passes `locks: locks`.
- The `blockedReason` and `read` doc comments are corrected in place, each quoting the withdrawn text verbatim.

Tests (`BucketVersioningSheetTests`; `FakeBucketSettings.setHasLockError(_:)` added so one store can fail then answer):
- `aLockThatCannotBeReadDoesNotCostABucketThatIsNotEnabled`: `.never` and `.suspended` still settle and offer `[.enabled]`, `lockReadFailed` set, no lock sentence; the enabled bucket beside them is the positive control (`load == .failed(lockReadFailedLine)`).
- `enablingAfterAFailedLockReadAsksAgainAndNeverGoesSilent`: three arms after a failed read then `apply(.enabled)`: second ask answers `false` (suspend offered, `hasLockReads == ["b","b"]`), answers `true` (nothing offered, lock sentence), fails again (nothing offered, `blockedReasonKey == "s3.versioning.error.lockRead"`, the line is in `lines`); plus a control that "not asked yet" still says nothing.
- Existing `apply` callers (9) pass a cache.

Honest note on order: I wrote the implementation and then the tests, so there is no recorded red-first run for I1. The tests' sensitivity is instead measured by P9, P10, P11 below, each RED.

## I2

P8 measured on the committed tree `31c39ec1` BEFORE any fix: `--filter 'BucketVersioning|BoundedView|SheetBound' --apply "perl -0pi -e 's/ *if let blocked = model\.blockedReason \{.*?\n            \}\n//s' Sources/MacSCPAppKit/BucketVersioningSheet.swift"` -> `control: 59 test(s) ran, 0 pre-existing failures`, `RESULT: GREEN — 59 test(s) ran and NONE of them noticed the plant` (6 lines deleted). The review's finding is confirmed by measurement.

Fix: `theKnownStateDrawsTheReasonNothingIsOffered` (source scan of `content`'s `.known` branch, whitespace-flattened): it must contain `if let warning = model.warning { Text(warning.text)` (positive control that the slice is the branch that draws the model's lines) and, after it, `if let blocked = model.blockedReason { Text(blocked.text)`. Same plant on `d0bafd4f`: control 62, RED, caught by that test alone.

## M2, M4

- `lines` doc comment: now lists four sources, with the old three-item wording quoted as withdrawn. `warning`: a comment on the `.enabled where !offeredStates.contains(.suspended)` arm says it warns about nothing and that `blockedReason` stands in its place.
- Registry comment: the "no warning" clause quoted and corrected, the "Five states (four until...)" lead withdrawn and quoted, the list now has five clauses. The count is `grep -c 'BucketVersioningSheet($' Tests/macSCPAppKitTests/BoundedViewRegistry.swift`, which prints 5 under the session grep and `/usr/bin/grep` alike (checked after writing the sentence).

## M3

`daff1df5` carries every probe as one unwrapped line starting with four spaces and `scripts/mutation-probe`, repository-root-relative paths, and quotes the withdrawn P5 wording verbatim. P4's pattern is adjusted for the tree after `d0bafd4f` (`let lock: Bool?`), said in the message. Proof it runs as committed: P5 and P4 were extracted with `git log -1 --format=%B | awk '/^    scripts\/mutation-probe/ && /--label .P5 /'` (and `.P4 `), written to files and run with bash, not retyped:
- P5: control 35 tests, 0 pre-existing failures; RED, caught by `theCacheTravelsFromTheSessionToTheRead`.
- P4: control 35 tests, 0 pre-existing failures; RED, caught by `theVersioningAnswerDoesNotSettleBeforeTheLockAnswer`.
Those two ran on `daff1df5`'s tree; the results recorded for P1-P7 in the message are still the `c98649ca` ones. P1-P3, P6, P7 were not re-run in this round.

## New probes, committed tree `d0bafd4f`, filter `BucketVersioning|BoundedView|SheetBound`, control 62 / 0 pre-existing each time, none BUILD FAILED

- P8 draw deleted: RED, `theKnownStateDrawsTheReasonNothingIsOffered`.
- P9 failed lock read always a failed load: RED, `aLockThatCannotBeReadDoesNotCostABucketThatIsNotEnabled` and `enablingAfterAFailedLockReadAsksAgainAndNeverGoesSilent`.
- P10 `apply` does not re-ask: RED, `enablingAfterAFailedLockReadAsksAgainAndNeverGoesSilent`.
- P11 failed not told apart from unread: RED, `enablingAfterAFailedLockReadAsksAgainAndNeverGoesSilent`.

P10 and P11 share one test (three arms, each plant breaks a different clause); I did not split it.

## Full suite

`swift test`: `Test run with 5075 tests in 407 suites passed`; `Test run with 2829 tests in 238 suites failed ... with 1 issue`, the one issue being `ViewTestabilitySpike` "Varying only isRegex leaves the pixels unchanged", which fails identically at `eff615ef` (measured in the first round).

## Could not do / open

- No red-first run for I1 (see above).
- P1-P3, P6, P7 not re-run this round; only P4 and P5 were extracted and run from the new record.
- M1 left as ruled; I3 left for Task 13.
