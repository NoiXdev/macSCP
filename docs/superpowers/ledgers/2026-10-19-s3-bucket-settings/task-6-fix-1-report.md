# Task 6, fix round 1

Commits (on top of `612f1ece`, which is not amended; `1a2587c8` is the controller's docs commit between them):
- `09080f6e` fix(s3): hold the bucket-mode refusal to its wire, and say what the tree does (`S3FileSystem.swift`, `S3FileSystemTests.swift`)
- `8aa5f5eb` docs: record the dead bucketListEmpty case and the six comments that describe it (`docs/BACKLOG.md`, one row)

`git status --porcelain` was empty before and after every probe (recorded by `probes-summary.txt`: `before: []`, `after p1: []`, `after p3: []`, `after p3b: []`). Not pushed.

## Important 1: the comment's tense

Withdrawn, quoted verbatim from `612f1ece`: "The browser now carries the action that resolves the empty state". The tree: `grep -rn "createBucket" Sources --include='*.swift'` shows `createBucket` is declared in Core (`S3FileSystem.swift`, `S3BucketSettings.swift`) and no browser or view-model surface calls it.
The comment in `S3FileSystem.connect` now says that `createBucket(_:protection:)` exists, that no browser surface calls it, that the action is planned (the s3-bucket-settings plan) and not in the tree, that until it lands an empty account opens on a blank browser, and that the refusal is lifted ahead of the action because keeping it would make the action unreachable for the account it is for. It quotes the withdrawn sentence with its commit. I dropped the "Task 11" reference, as the review suggested; the plan is named once, by name.

## Important 2: the guard

`aNamedBucketThatDoesNotExistStillRefusesTheConnect` was `#expect(throws: RemoteFSError.self)`. It now asserts `RemoteFSError.notFound(path: "/")`, exactly one request, request path `/macscp-seed`, and `list-type=2` in the query.
One correction to the review's suggestion, found while writing it: the error does NOT distinguish the routes. In `.bucket` mode `fetchPage` reports `reportedPath(bucket:key:)` for an empty key, and `listBuckets` reports `"/"`; both are `.notFound(path: "/")`. The error assertion pins the case; the ROUTE is pinned by the wire (request count, path, `list-type=2`). The test's doc comment says so. I did not assert `.notFound(path: "/macscp-seed")`, which the review's text implied; the test passes with `"/"` and I did not try the other value.

Whether the old guard was a formality is now measured, not argued (probe 3b below): with the `612f1ece` test file restored and the `.bucket` arm routed through `ListBuckets`, `aNamedBucketThatDoesNotExistStillRefusesTheConnect` is NOT among the catchers.

## Important 3: probe figures, from the run that printed them

All three through `scripts/mutation-probe --filter 'S3FileSystemTests'`, baseline "staged tree at `09080f6e`", control "100 test(s) ran, 0 pre-existing failures". The `--apply` strings are in `probes.sh` in the scratchpad; the plant, in each case, is on this one line of `S3FileSystem.swift`.

Probe 1 (the `.bucket` arm swallows the probe's error):
`--apply "perl -0pi -e 's/_ = try await fs\.fetchPage\(bucket: bucket, prefix: \"\", continuationToken: nil\)/_ = try? await fs.fetchPage(bucket: bucket, prefix: \"\", continuationToken: nil)/' Sources/macSCPCore/S3/S3FileSystem.swift"`
`RESULT: RED — 100 test(s) ran`, **3** catchers:
- `aNamedBucketThatDoesNotExistStillRefusesTheConnect()`
- `connectItselfMapsForbiddenToAuthenticationFailed()`
- `networkFailureMapsToConnectionFailed()`
This replaces my earlier "(only that one)", which the review showed did not reproduce. I no longer call this probe a proxy: the reviewer showed `try?` on that arm is the minimal mutation falsifying the property.

Probe 3 (the over-reach: `.bucket` routed through `ListBuckets`):
`--apply "perl -0pi -e 's/_ = try await fs\.fetchPage\(bucket: bucket, prefix: \"\", continuationToken: nil\)/_ = try await fs.listBuckets()/' Sources/macSCPCore/S3/S3FileSystem.swift"`
`RESULT: RED — 100 test(s) ran`, **3** catchers:
- `aNamedBucketThatDoesNotExistStillRefusesTheConnect()`
- `connectItselfMapsForbiddenToAuthenticationFailed()`
- `withTheToggleOffConnectStillProbesTheConfiguredBucket()`

Probe 3b (the same plant, with the OLD test file from `612f1ece` restored in the same `--apply`):
`--apply "git show 612f1ece:Tests/macSCPCoreTests/S3FileSystemTests.swift > Tests/macSCPCoreTests/S3FileSystemTests.swift && perl -0pi -e 's/_ = try await fs\.fetchPage\(bucket: bucket, prefix: \"\", continuationToken: nil\)/_ = try await fs.listBuckets()/' Sources/macSCPCore/S3/S3FileSystem.swift"`
`RESULT: RED — 100 test(s) ran`, **2** catchers: `connectItselfMapsForbiddenToAuthenticationFailed()` and `withTheToggleOffConnectStillProbesTheConfiguredBucket()`. The old guard is absent. The over-reach was caught by two older tests that happen to touch the same arm, not by the guard the brief called load-bearing; the tightened guard makes the guard itself a catcher (probe 3).
Limits: probe 3 and 3b are one plant each, and one run each. Neither was repeated, so this says nothing about flakiness.

The review's probe 2 reproduces, and I did not re-run it this round (the tightened test does not touch the `listBuckets` probe path).

## Important 4: stale comment sites

Recorded in `docs/BACKLOG.md` (`8aa5f5eb`, one row in "Tooling and maintenance"), no pipe in either cell (checked: the added line splits into 4 fields on `|`, i.e. two cells; `git diff docs/BACKLOG.md` shows one added line). It names:
1. `ConnectionViewModel.swift` near line 2306, the one my first report missed: "The two S3 bucket-list outcomes (2026-09-02), both reachable ONLY".
2. `ConnectionViewModel.swift` near 2310.
3. `ConnectionViewModel.swift` near 2319, flagged in the row as a true description of a now-dead arm.
4. `RemoteBrowserViewModel.swift` near 1278.
5. `RemoteFSError.swift` near 24.
Plus the dead case, the four catalogue strings, the design spec's §2 row 2 (already routed to Task 13 by `1a2587c8`), and the two corrected claims below. Each site is identified by its opening words, because line numbers have moved before. The comments themselves are not touched, as instructed.

Corrections to my first report, each quoting what it withdraws:
- Withdrawn: "`RemoteFSError.swift:16`: "only at connect time" (about `bucketListForbidden`; still true)." It is stale. `RemoteBrowserViewModel.swift` near 1274 records, with a measurement, that `listBuckets` runs again on every listing of `/` and on a `stat` of a bucket, and `S3FileSystem.list(path:)` does `if isBucketListRoot(path) { return try await listBuckets() }`. The row lists it as a sixth comment, older than this task.
- Withdrawn: "four", as in "Four comments ... now assert a thrower"; the first report listed the stale sites without `ConnectionViewModel.swift` near 2306. Five sites.

## Minor findings

1. `RemoteFSError.swift:16`: see above (in the row).
2. The `noSuchBucketXML` doc claimed "What every S3 implementation answers `ListObjectsV2` on a bucket that is not there." Withdrawn. It now says it is a plausible 404 body, not measured against any provider, that the code under test never reads it, and that the 404 status alone decides (`NoSuchBucket` has no arm in `S3ErrorCode.finding(forCode:status:path:)`, per the review at `S3ErrorCode.swift:63-78`; I did not re-read that file myself).
3. The Outcome numbering read 1, 3, 4. `anAccountWithNoBucketsConnectsInBucketListMode` now opens with "Outcome 2 of the design's §2 table, as that row now stands". The enumeration is in the test file's doc comments, and I did not change the 1, 3, 4 labels on the other tests.
4. The fixture's `<BucketName>nope</BucketName>` now reads `macscp-seed`, the bucket `config` points at.
5. Withdrawn: "All remaining occurrences (19 lines in `Sources`, from `grep -rn -e 'bucketListEmpty' Sources --include='*.swift' | wc -l`". `grep -rn ... | wc -l` prints 19 and counts LINES; `grep -rno -e 'bucketListEmpty' Sources --include='*.swift' | wc -l` prints 20 and counts occurrences, because `TransferFailureKind.swift` line 101 has two. Both measured again at `09080f6e`: 19 and 20. The BACKLOG row carries both commands without a pipe, as `grep -rn` (19 lines) and `grep -rno` (20 lines).

Also dropped, per the coordinator: the hedge that probe 1 is "a proxy plant".

## Tests

Full `swift test` result is in the hand-back summary. Before it: `swift test --filter S3FileSystemTests` after the test and comment edits: `✔ Test run with 100 tests in 1 suite passed`.

## Could not fix

Nothing in the nine findings was left. The five comments are deliberately not edited (brief scope, recorded in the row instead).
