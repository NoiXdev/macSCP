# Task 6 report: let an account with no buckets connect

Status: DONE_WITH_CONCERNS (concerns: stale comments elsewhere, a dead error case, a blank browser; all listed below, none fixed here as instructed).

Commit: `612f1ece` fix(s3): let an account with no buckets connect, so one can be made
Files: `Sources/macSCPCore/S3/S3FileSystem.swift` (+19/-6), `Tests/macSCPCoreTests/S3FileSystemTests.swift` (+39/-8); `git show --numstat HEAD`: 2 files, 58 insertions, 14 deletions. No push.

## What changed (from the diff)

- `S3FileSystem.connect`, `.bucketList` arm: `if try await fs.listBuckets().isEmpty { throw RemoteFSError.bucketListEmpty }` became `_ = try await fs.listBuckets()`. The call is kept: it is the readiness and authorisation probe, and its 403 still maps to `bucketListForbidden` (`listBuckets()` is unchanged).
- The `.bucket` arm is not touched.
- The comment above is rewritten, not deleted. It quotes the withdrawn sentence verbatim ("An account with no buckets is its own outcome for the same reason: an empty browser explains nothing"), says the premise held while an empty browser offered nothing, and names the action that now resolves it: creating a bucket via `createBucket(_:protection:)`, surfaced as the browser's create-bucket action in Task 11. It also states that the relaxation covers `.bucketList` only.
- Tests added: `anAccountWithNoBucketsConnectsInBucketListMode`, `aNamedBucketThatDoesNotExistStillRefusesTheConnect`, plus a `noSuchBucketXML` fixture.
- Test removed: `aBucketListWithNoBucketsIsItsOwnOutcome`, which pinned the old refusal (`#expect(throws: RemoteFSError.bucketListEmpty)`). It asserted exactly the behaviour this task removes and is superseded by the new first test. I deleted it rather than keep a vacuous rewrite of it. `aForbiddenBucketListIsItsOwnOutcome` and `anyOtherBucketListFailureStaysWhatItWas` are untouched and still pass.

## Fake transport, not the rig

The empty-account test uses `FakeS3Transport` with a canned empty `ListAllMyBucketsResult`. The rig has three buckets that must not be touched, and a second identity would have to be an account with zero buckets, which the single-tenant RustFS rig does not offer (its scoped identity gets a filtered list, per `S3AccessProbe` docs, not an empty account). The fake also lets the test assert the wire shape: two requests, the first a signed `GET /` with no query.
I did not run the gated `MACSCP_ITEST` suites; no rig case was added or touched.

## Red, taken before the change

Tests written first, run with `swift test --filter S3FileSystemTests` (no build-system flag). Verbatim excerpt of the log (`grep -n "✘\|Test run with\|error:"`, lines 297, 354, 405, 406 of the log; labelled as an excerpt, not the full output):

```
297:✘ Test anAccountWithNoBucketsConnectsInBucketListMode() recorded an issue at S3FileSystemTests.swift:1693:6: Caught error: .bucketListEmpty
354:✘ Test anAccountWithNoBucketsConnectsInBucketListMode() failed after 0.036 seconds with 1 issue.
405:✘ Suite "S3FileSystem" failed after 0.039 seconds with 1 issue.
406:✘ Test run with 101 tests in 1 suite failed after 0.040 seconds with 1 issue.
```

The second test was green on that run (`✔ Test aNamedBucketThatDoesNotExistStillRefusesTheConnect() passed`). That is expected: it is a guard on behaviour that must not change, not a red-first test. Its sensitivity is measured by probe 1 below.

Green after the change: `✔ Test run with 100 tests in 1 suite passed` (101 minus the removed test).

## Mutation probes (run on the committed tree; harness reverted both, `git status --short` empty afterwards)

Probe 1, widening past its reason:
- `--filter 'S3FileSystemTests'`
- `--apply "perl -0pi -e 's/_ = try await fs\.fetchPage\(bucket: bucket, prefix: \"\", continuationToken: nil\)/_ = try? await fs.fetchPage(bucket: bucket, prefix: \"\", continuationToken: nil)/' Sources/macSCPCore/S3/S3FileSystem.swift"`
- Result: `RED — 100 test(s) ran, and the plant was caught by: macSCPCoreTests.S3FileSystemTests/aNamedBucketThatDoesNotExistStillRefusesTheConnect()` (only that one) -- **WITHDRAWN in fix round 1: the probe is caught by three tests, see task-6-fix-1-report.md.**

Probe 2, dropping the probe call:
- `--filter 'S3FileSystemTests'`
- `--apply "perl -0pi -e 's/_ = try await fs\.listBuckets\(\)\n/_ = ()\n/' Sources/macSCPCore/S3/S3FileSystem.swift"`
- Result: `RED — 100 test(s) ran`, caught by 15 tests, including `anAccountWithNoBucketsConnectsInBucketListMode()`, `aForbiddenBucketListIsItsOwnOutcome()`, `connectAsksForTheBucketListInsteadOfProbingOneBucket()` and `anyOtherBucketListFailureStaysWhatItWas()`. Neither probe printed `PLANT CHANGED NOTHING`.

**WITHDRAWN in fix round 1:** "Probe 1 has one limit: it plants the `.bucket` arm swallowing an error, not the specific mistake..." -- the review showed `try?` on that arm is the minimal falsifying plant; the real limit was the test assertion (`RemoteFSError.self`), tightened in `09080f6e`.

## Full suite

`swift test` (no flag, ungated). Core: `✔ Test run with 5069 tests in 406 suites passed`. AppKit: `✘ Test run with 2556 tests in 230 suites failed ... with 1 issue`, the one issue being `ViewTestabilitySpike.swift:202:9` "Varying only isRegex leaves the pixels unchanged" (the known red on an untouched base, not mine). Every other test passed.

## Does `bucketListEmpty` still have a producer?

No. Command, run from the worktree root:

```
grep -rn -e 'throw RemoteFSError.bucketListEmpty' -e 'throw .bucketListEmpty' Sources --include='*.swift'
```

It prints nothing (exit 1). Before the change the single hit was `S3FileSystem.swift` line 177. The case is now unreachable from production code. All remaining occurrences [WITHDRAWN: that is 19 LINES and 20 occurrences, see task-6-fix-1-report.md] (19 lines in `Sources`, from `grep -rn -e 'bucketListEmpty' Sources --include='*.swift' | wc -l`, which includes comments and the case declaration) are consumers or comments. I did not delete the case. Its consumers, for the later removal decision: `RemoteFSError.swift:28` (declaration), `CLIErrorMapping.swift:138` and `:317`, `DialProbes.swift:448`, `ConnectionViewModel.swift:2326`, `TransferQueueViewModel.swift:1680`, `TransferFailureKind.swift:52/87/101/146`, `ComparisonOverview.swift:502`, `TransferFailureLabel.swift:184/199`, plus the `core.connect.s3BucketListEmpty` string in four `Localizable.strings` catalogs. Tests pinning it: `CLIErrorMappingTests.swift:149/153`, `ConnectionViewModelTests.swift:1806`, `TunnelFailureKindTests.swift:186`, `TransferFailureKindTests.swift:63/225/256`, `TransferFailureLabelGuardTests.swift:65`.

## What else reads an empty listing as an error

I searched for "no buckets", "bucketList" and empty-state handling in `Sources/macSCPCore/Presentation`, `MacSCPAppKit`, `MacSCPCLI` and `macSCPCore/CLI`.
- No path found treats an empty root listing as an error. The only handling of the empty account was the connect throw I removed. `S3AccessProbe` records answers without interpreting them, and `listBuckets()` has no emptiness check.
- The CLI would print an empty listing for `ls /`; I did not execute it.
- I found no empty-state view for the file browser (no "empty folder" string in the AppKit catalog), so an empty account now opens on a blank browser. That is the gap Task 11's create-bucket action is meant to fill; until then the state is blank rather than explained. Not verified by running the app.

## Stale comments left as instructed (rule: comments that describe other code)

The brief limited fixes to this task's files, so these are named, not edited. They now assert something false:
- `Sources/macSCPCore/Presentation/ConnectionViewModel.swift:2310`: "`.bucketListEmpty` is connect-time only — `connect` is its single thrower" (nothing throws it now); and `:2319-2321`, "`.bucketListEmpty` blames no row, because nothing in the form is wrong: the account has no buckets".
- `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift:1278-1280`: "`.bucketListEmpty` needs no arm — `connect` is its only thrower, and a later empty account is an empty browser, not an error". The second half is now true in a stronger sense; the first half is not.
- `Sources/macSCPCore/RemoteFS/RemoteFSError.swift:24-28` (doc comment on the case): "a connect that opens on an empty browser explains nothing at the form".
- `Sources/macSCPCore/RemoteFS/RemoteFSError.swift:16`: "only at connect time" (about `bucketListForbidden`; still true) -- **WITHDRAWN: it is stale, see task-6-fix-1-report.md.**
- Tests whose names or docs say the case is reachable: `ConnectionViewModelTests.swift:1806`, `CLIErrorMappingTests.swift:149`. They test mapping functions directly and still pass.

A follow-up that either deletes the case with its consumers or marks it reserved should fix these in one pass.

## Concerns

1. `bucketListEmpty` is dead and its comments are stale (above). Whoever decides to keep or delete it should do both together.
2. An empty account opens on a blank browser until Task 11 lands, so this commit is not user-friendly on its own.
3. **WITHDRAWN in fix round 1:** "Probe 1 is a proxy plant (see above)."
