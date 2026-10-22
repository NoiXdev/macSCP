# Task 6, fix round 1 — scoped re-review (`612f1ece`..`8aa5f5eb`)

Scope: the nine findings of `task-6-review.md` (0 Critical, 4 Important, 5
Minor), and whether the fix round broke anything. Not a fresh review of Task 6.
`1a2587c8` is the controller's plan edit and is judged only for contradiction.

`git status --porcelain` empty before the first probe and after every one of
the three. Full `swift test` run with no `--build-system` flag.

## Finding verdicts

**Important 1 — `S3FileSystem.swift:182-183`, the replacement comment asserts
something not in this tree.** ADDRESSED. The present-tense clause is gone
(`S3FileSystem.swift:184-196`). Every claim the new comment makes was checked
against the tree:

- "`createBucket(_:protection:)` exists in Core" — `S3FileSystem.swift:1738`,
  and the protocol requirement at `S3BucketSettings.swift:84`.
- "NO browser surface calls it yet" — `grep -rn "createBucket" Sources
  --include='*.swift'` returns 8 lines, none of them a call from
  `Sources/MacSCPAppKit`: two declarations, one body builder
  (`S3SettingsXML.swift:95`), its call site inside `createBucket` itself
  (`S3FileSystem.swift:1746`), and three comments (one of them this one).
- "the create-bucket action in the bucket browser is planned (the
  s3-bucket-settings plan) and is not in this tree" — plan Task 11 ("The
  create-bucket sheet",
  `docs/superpowers/plans/2026-10-19-s3-bucket-settings.md:851`) creates
  `Sources/MacSCPAppKit/CreateBucketSheet.swift`, reached through the
  `ConnectionActionsMenu` toolbar capsule (plan lines 56, 67); neither file
  exists.
- "until it lands an account with no buckets opens on a blank browser" — the
  only empty-state views in the app are `SheetListEmptyState`
  (`SheetFacetPicker.swift:79`) and `SessionSidebar.emptyStateRow`
  (`:1000`); neither is the file browser.

The withdrawal is verbatim, checked by `grep -F` and not by eye: the exact
string `The browser now carries the action that resolves the empty state`
occurs in the unwrapped comment of `git show
612f1ece:Sources/macSCPCore/S3/S3FileSystem.swift` (lines 155-200), and the
same string **in quotation marks** occurs in the unwrapped HEAD comment. The
round also kept `612f1ece`'s own withdrawal of the `b4620035` wording intact
(`read "An account with no buckets is its own outcome for the same reason: an
empty browser explains nothing"` still present at HEAD). The "Task 11"
reference was dropped as the review asked; the plan is named once, by name.

**Important 2 — `S3FileSystemTests.swift:1703-1709`, the guard cannot see the
widening.** ADDRESSED, and the round's departure from the review's suggested
assertion is correct — **the review's suggestion was wrong.**

The test (`S3FileSystemTests.swift:1737-1751`) now asserts
`RemoteFSError.notFound(path: "/")`, `requests.count == 1`,
`url.path == "/macscp-seed"` and `list-type=2` in the query.

The round's correction settles true, read off the code rather than argued:

- `.bucket` route: the arm is `_ = try await fs.fetchPage(bucket: bucket,
  prefix: "", continuationToken: nil)` (`S3FileSystem.swift:169`), whose
  `default:` throws `Self.mapErrorStatus(response.statusCode, body: data,
  path: reportedPath(bucket: bucket, key: prefix))` (`:1123-1124`) with
  `prefix == ""`. `reportedPath(bucket:key:)` (`:283-290`) in `.bucket` mode
  is `return "/" + key` — the `bucket` argument is discarded — so an empty
  key gives `"/"`.
- `listBuckets` route: `default: throw Self.mapErrorStatus(response.statusCode,
  body: data, path: "/")` (`:1170`).
- Both land in `mapErrorStatus` (`:1373-1387`), where `NoSuchBucket` has no
  arm in `S3ErrorCode.finding(forCode:status:path:)`
  (`S3ErrorCode.swift:63-78`, read directly) so `finding` returns nil and
  `case 404: return .notFound(path: path)` decides.

So both routes throw `.notFound(path: "/")`. `.notFound(path: "/macscp-seed")`
— what the review's text implied — is not what either route produces, and a
test asserting it would be red. The error pins the case; the wire pins the
route, exactly as the round says and as the test's own doc comment now states.

The sensitivity is measured, not asserted (probes below): the tightened guard
IS a catcher of the collapse-the-switch over-reach (probe 3), where the
`612f1ece` version of it was NOT (probe 3b). That is the evidence the review
asked for, and it reproduces.

**Important 3 — probe 1's "(only that one)" does not reproduce.** ADDRESSED.
All three probe figures in the fix report reproduce exactly, run through
`scripts/mutation-probe --filter 'S3FileSystemTests'`. Each `--apply` string
was extracted from the committed report line (26, 34, 41) rather than
retyped; the sandbox in this session refuses `eval`/`sh`/command substitution
into a runner, so each was re-run as a literal and the literal then proved
identical to the committed text with `grep -c -F` against the report (1 match
each for probes 1 and 3).

| probe | report | this run |
|---|---|---|
| control (all three runs) | 100 ran, 0 pre-existing failures | 100 ran, 0 pre-existing failures ✅ |
| 1 (`try?` on the `.bucket` arm) | RED, 100 ran, 3 catchers | RED, 100 ran, same 3 names ✅ |
| 3 (`.bucket` routed through `ListBuckets`) | RED, 100 ran, 3 catchers | RED, 100 ran, same 3 names ✅ |
| 3b (same plant, `612f1ece` test file restored) | RED, 100 ran, **2** catchers, guard ABSENT | RED, 100 ran, same 2 names, guard absent ✅ |

Probe 3's catchers: `aNamedBucketThatDoesNotExistStillRefusesTheConnect()`,
`connectItselfMapsForbiddenToAuthenticationFailed()`,
`withTheToggleOffConnectStillProbesTheConfiguredBucket()`. Probe 3b's: the
latter two only. No run printed `PLANT CHANGED NOTHING` or `BUILD FAILED`.
`git status --porcelain` empty after each; the harness reverted all three
plants, including the one that overwrote a tracked test file.

**One deviation, stated so it is not mistaken for the committed form.** Probe
3b's committed `--apply` opens `git show
612f1ece:Tests/macSCPCoreTests/S3FileSystemTests.swift > …`, and this
session's worktree isolation refuses any command carrying `git` inside an
argument it cannot verify. I ran the semantically identical plant with `cat
<scratchpad copy> > Tests/macSCPCoreTests/S3FileSystemTests.swift && perl …`,
having first proved the copy is that blob: `git rev-parse
'612f1ece:Tests/macSCPCoreTests/S3FileSystemTests.swift'` and `git
hash-object` of the copy both print
`5b724c4fdba9d7951d9aace9a70a54ee19d09783`. The perl half is the committed
string unchanged.

**Important 4 — five stale comment sites recorded nowhere in the tree.**
ADDRESSED. `8aa5f5eb` adds one row to `docs/BACKLOG.md:360`, in the "Tooling
and maintenance" section (heading at `:282`), titled
"`RemoteFSError.bucketListEmpty` has no producer since `612f1ece`, and six
comments still describe it or its sibling as they were". Row conventions:

- **No pipe in either cell.** The row splits into 4 fields on `|`
  (`awk -F'|' '/has no producer since/ {print NF}' docs/BACKLOG.md` → `4`,
  i.e. 3 pipes, i.e. two cells and nothing inside them).
- **Every figure travels with its command, and the command runs as
  committed.** I extracted the four `grep` commands from line 360 with
  `sed -n '360p' docs/BACKLOG.md | grep -o -E '`grep[^`]*`'`, then ran each
  and proved the text I ran is the committed text with `grep -c -F`:

  | extracted command | row's figure | this run at HEAD |
  |---|---|---|
  | `grep -rn -e 'throw RemoteFSError.bucketListEmpty' -e 'throw .bucketListEmpty' Sources --include='*.swift'` | nothing, exit 1 | nothing, exit 1 ✅ |
  | `grep -rn -e 'bucketListEmpty' Sources --include='*.swift'` | 19 lines | 19 ✅ (19 under `/usr/bin/grep` too) |
  | `grep -rno -e 'bucketListEmpty' Sources --include='*.swift'` | 20 | 20 ✅ (20 under `/usr/bin/grep` too) |
  | `grep -rn 'core.connect.s3BucketListEmpty' Sources --include='*.strings'` | 4, one per catalogue | 4: `de:69`, `en:73`, `fr:71`, `pl:71` ✅ |

  The row explains the 19/20 gap and the explanation holds: `grep -rno` prints
  `TransferFailureKind.swift:101` twice, and that line is
  `case .bucketListEmpty: return .bucketListEmpty` — two occurrences on one
  physical line, the `grep -c`/`grep -o` distinction CLAUDE.md names. The
  row's "one of the 20 is a comment in `S3FileSystem.swift` that names the
  case on purpose" also holds: `grep -no` on that file prints exactly one
  hit, `181:bucketListEmpty`, inside the rewritten comment. The row's
  pre-change claim verifies too — `throw RemoteFSError.bucketListEmpty` is at
  line **177** of `git show b4620035:…/S3FileSystem.swift`.

- **Sites named by opening words, not line numbers**, and each quoted opening
  appears where the row says (`grep -n -F`, exact strings):
  (1) "The two S3 bucket-list outcomes (2026-09-02), both reachable ONLY" →
  `ConnectionViewModel.swift:2307` (row says "near 2306"; see Minor note
  below). (2) "`.bucketListEmpty` is connect-time only — `connect` is its
  single" → `:2310`, exact. (3) "the toggle — which is the row this
  highlights. `.bucketListEmpty`" → `:2319`, exact. (4) "`.bucketListEmpty`
  needs no arm — `connect`" → `RemoteBrowserViewModel.swift:1278`, exact.
  (5) "own case rather than an empty listing, because a connect that opens" →
  `RemoteFSError.swift:25`, the doc comment on the case, row says "near 24"
  (the comment opens at `:24`). (6) "`startsAtBucketList` is on, and only at
  connect time." → `RemoteFSError.swift:16`, exact.

  The comments themselves are untouched, as the brief required.

**The sixth site is genuinely stale**, and the withdrawal rests on claims that
check out. `RemoteFSError.swift:15-16` says `bucketListForbidden` is "Only
reachable from an S3 connection whose `startsAtBucketList` is on, and only at
connect time." Both legs of the contradiction are real:
`RemoteBrowserViewModel.swift:1274-1276` carries the measured note
("`.bucketListForbidden` is NOT connect-time only (Task 3 review, M-3):
`listBuckets` runs again on every listing of `/` and on a `stat` of a bucket")
exactly where the row says; and the code agrees on both counts —
`S3FileSystem.list(path:)` opens `if isBucketListRoot(path) { return try await
listBuckets() }` (`:213`), and the `stat` path reaches the same call through
`listedEntry(at:)`, `guard let row = try await listBuckets().first(where: …)`
(`:360`), for a bucket's own entry. `listBuckets()` throws
`bucketListForbidden` on 403 (`:1168-1169`), so a revoked policy raises it
mid-session. The first report's "still true" was wrong and the withdrawal is
right. The row correctly marks it older than this task.

**Minor 1 — `RemoteFSError.swift:16` cleared as "still true".** ADDRESSED —
withdrawn in the fix report and recorded as the row's sixth site; the
staleness is verified above.

**Minor 2 — the unmeasured universal on `noSuchBucketXML`.** ADDRESSED.
`S3FileSystemTests.swift:1547-1551` now reads "A plausible 404 body … not
measured against any provider and the code under test never reads it:
`NoSuchBucket` has no arm in `S3ErrorCode.finding(forCode:status:path:)`, so
the 404 STATUS alone decides the outcome and an empty body would behave the
same." Every clause is true: I read `S3ErrorCode.swift:63-78` myself (the
implementer says it did not) — the five arms are
`ObjectLockConfigurationNotFoundError`, `BucketNotEmpty`,
`BucketAlreadyExists`, `BucketAlreadyOwnedByYou`, `NotImplemented`, and
`default: return nil` — and `mapErrorStatus` then decides on status alone, so
an empty body (nil `parse`) does behave identically. The withdrawn wording is
quoted verbatim: `git show 612f1ece:Tests/…/S3FileSystemTests.swift:1548-1549`
unwraps to exactly "What every S3 implementation answers `ListObjectsV2` on a
bucket that is not there."

**Minor 3 — the Outcome enumeration reads 1, 3, 4.** ADDRESSED. `grep -n
'Outcome [0-9]' Tests/macSCPCoreTests/S3FileSystemTests.swift` now prints four
lines, `1` at `:1644`, `2` at `:1678`, `3` at `:1734`, `4` at `:1745`. The new
label names the design table and says how the row stands ("Outcome 2 of the
design's §2 table, as that row now stands: 200 with zero buckets no longer
refuses"), and its parenthetical about the neighbouring labels still counting
it is true of the tree.

**Minor 4 — the fixture names a bucket the request never asks for.**
ADDRESSED. `S3FileSystemTests.swift:1553` now reads
`<BucketName>macscp-seed</BucketName>`, the bucket `config` points at and the
one in the asserted request path.

**Minor 5 — "occurrences" beside a line count.** ADDRESSED. Withdrawn in the
fix report quoting the original phrasing, and the BACKLOG row now carries both
commands and both figures with the reason they differ, all four reproduced
above.

## New breakage in the fix diff

**None Critical or Important.** The diff is 4 files, 76 insertions, 17
deletions; the two source files are the ones the brief scoped, and the
`.bucket` arm (`S3FileSystem.swift:169`) is still byte-identical to
`b4620035`. `swift test --filter S3FileSystemTests` → `✔ Test run with 100
tests in 1 suite passed`, confirming the round's claim; the three probe
control runs independently printed `control: 100 test(s) ran, 0 pre-existing
failures`. Full `swift test` (no `--build-system` flag): **2556 tests in 230
suites, 1 issue** — `✘ Test "Varying only isRegex leaves the pixels unchanged"
recorded an issue at ViewTestabilitySpike.swift:202:9: Expectation failed: off
== on`, the known red on an untouched base, excluded by the brief. Four `✘`
lines in the whole log, all four from that one case/suite/run. `Suite
"S3FileSystem" passed`. No `warning:` line names either touched file.

The tightened test keeps its positive checks beside its negative ones: `try
#require(requests.first?.url)` forecloses a vacuous pass on a nil URL, and
`requests.count == 1` is asserted before the path is read.

Three Minor notes, none blocking:

1. **A quoted withdrawal that starts mid-token.** The fix report withdraws
   "`RemoteFSError.swift:16`: "only at connect time" (about
   `bucketListForbidden`; still true)." The first report wrote
   `Sources/macSCPCore/RemoteFS/RemoteFSError.swift:16` — the quote
   abbreviates the path inside the backticks and adds a trailing period.
   Everything from `RemoteFSError.swift:16` onward is exact (`grep -c -F` → 1
   against `task-6-report.md`), so nothing was lost, but under CLAUDE.md's
   verbatim rule a quoted span should not begin inside a token it shortens.
2. **A commit sha standing where the harness prints a tree hash.** The fix
   report gives the probes' baseline as "staged tree at `09080f6e`".
   `scripts/mutation-probe` prints `── (baseline: staged tree at <git
   write-tree hash>)`; all three of my runs printed `02cc473c`. A commit sha
   in that slot is a figure the command that produced it cannot reproduce.
3. **One line number off by one in the BACKLOG row.** Site 1 is at
   `ConnectionViewModel.swift:2307`, the row says "near line 2306". The row
   states its own tolerance ("Line numbers are approximate on purpose … find
   each by its quoted words") and the quoted words are exact, so this is
   inside its declared contract — recorded for completeness, not as a defect.

   The fix report also points at `probes.sh` "in the scratchpad" for the
   `--apply` strings; a scratchpad file is outside the tree and unverifiable.
   The strings themselves are committed in the report, which is what the rule
   needs, so this is a dead pointer and nothing more.

## The controller's plan edit (`1a2587c8`) — contradiction check only

No contradiction with the fix round or the tree. Its citation is right:
`docs/superpowers/specs/2026-09-02-s3-bucket-browser-design.md:44` is indeed
§2 row 2, "200 with zero buckets". Its consumer list ("the CLI mapping,
`DialProbes`, two view models, `TransferFailureKind`, two AppKit files")
matches `grep -rln 'bucketListEmpty' Sources --include='*.swift'`:
`CLIErrorMapping.swift`, `DialProbes.swift`, `ConnectionViewModel.swift` +
`TransferQueueViewModel.swift`, `TransferFailureKind.swift`,
`ComparisonOverview.swift` + `TransferFailureLabel.swift` (plus the
declaration and two comment-only files). Its "the row Task 6's fix round
opened" anticipated a row that `8aa5f5eb` then created, and the step that
"checks that row still names them" is satisfiable.

One inexact gloss, non-blocking: the step calls them "the five comment sites
naming `connect` as the case's single thrower". Only sites 2 and 4 name
`connect` as the thrower; sites 1, 3 and 5 are stale for other reasons
(reachability, a dead arm, a withdrawn reason). The count of five agrees with
the row; the descriptor does not describe all five.

## Out-of-scope observations

- **`reportedPath(bucket:key:)` discards the bucket in `.bucket` mode**
  (`S3FileSystem.swift:283-290`: `case .bucket: return "/" + key`), so a
  connect-time 404 on a named bucket that does not exist surfaces as
  `.notFound(path: "/")` rather than naming the bucket the user typed. This is
  pre-existing — the `.bucket` arm is unchanged since `b4620035` — and it is
  precisely what makes the round's correction to the review true, so it is
  worth a ledger line: the message the user sees for the one thing they typed
  cannot name it.
- The design spec's §2 row 2 and the four `core.connect.s3BucketListEmpty`
  catalogue strings remain live artifacts describing an outcome that cannot
  occur. Routed to Task 13 by `1a2587c8` and recorded in the new BACKLOG row;
  nothing further owed by Task 6.

## Verdict

**Fix round: all nine findings addressed, no new Critical or Important
breakage.** Three Minor notes above (a withdrawal quote that starts
mid-token, a commit sha where the harness prints a tree hash, a one-off line
number inside the row's own declared tolerance) and one inexact gloss in the
controller's plan edit. The round's departure from the review's suggested
assertion in Important 2 is correct and the review's suggestion was wrong:
both routes throw `.notFound(path: "/")`, so the error pins the case and the
wire pins the route. Probe 3/3b reproduce and are the measurement that
answers the review's central claim — the `612f1ece` guard was not a catcher
of the over-reach it existed to stop; the tightened one is.
