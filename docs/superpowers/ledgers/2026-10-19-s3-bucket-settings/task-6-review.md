# Task 6 review — let an account with no buckets connect (`612f1ece`, base `b4620035`)

Reviewed: brief, report, `review-b4620035..612f1ece.diff`, `CLAUDE.md`. Both
mutation probes re-run from the report's committed `--apply` strings through
`scripts/mutation-probe`; `git status --porcelain` empty before and after each.

## Spec Compliance

**✅ Spec compliant** on every step the brief spells, with two ⚠️ items below.

| brief step | verdict | evidence |
|---|---|---|
| Step 1: both tests | ✅ | `S3FileSystemTests.swift:1681`, `:1703`. Adapted from the brief's pseudo-API (`rootMode:`) to the real `connect(_:transport:)` seam — legitimate; see Minor 4 for the fixture leftover. |
| Step 2: red first | ✅ | Report's log excerpt names `Caught error: .bucketListEmpty` at `S3FileSystemTests.swift:1693:6`, run count 101. Corroborated independently: my probe control run reported `control: 100 test(s) ran, 0 pre-existing failures` for `--filter S3FileSystemTests` — 101 minus the deleted test. |
| Step 3: remove the throw, `.bucketList` only | ✅ | `S3FileSystem.swift:191` is now `_ = try await fs.listBuckets()`. The `.bucket` arm at `:169` is byte-identical to `b4620035` — the diff shows it only as a context line. |
| Step 3: keep `listBuckets()`, keep `bucketListForbidden` | ✅ | `listBuckets()` is unchanged and still maps `case 403: throw RemoteFSError.bucketListForbidden` (`S3FileSystem.swift:1158-1159`). `aForbiddenBucketListIsItsOwnOutcome` (`:1713`) untouched and still green. Empty and forbidden remain different answers. |
| Step 4: rewrite the comment, quote the withdrawal, name the action | ✅ quotation / ❌ the replacement's claim | Quotation verified character-for-character against `git show b4620035:Sources/macSCPCore/S3/S3FileSystem.swift` (see Strengths). The action is named by symbol, `createBucket(_:protection:)`, which exists at `S3FileSystem.swift:1729`. But see **Important 1**. |
| Step 5: suite run; say so if the case has no producer | ✅ | Verified below; the claim and its consumer list hold exactly. |
| Step 6: commit message | ✅ | `fix(s3): let an account with no buckets connect, so one can be made` — the brief's string verbatim. |

- ⚠️ **Cannot verify from the diff — the design record now describes an
  outcome that cannot occur.** `docs/superpowers/specs/2026-09-02-s3-bucket-browser-design.md:44`
  is row 2 of the §2 table, "200 with zero buckets → 'This key can list
  buckets, but the account has none.'", and the four
  `core.connect.s3BucketListEmpty` catalog entries (`en`/`de`/`fr`/`pl`
  `Localizable.strings`) are now unreachable strings. Task 13's file list
  (`docs/superpowers/plans/2026-10-19-s3-bucket-settings.md:959-967`) names
  `docs/BACKLOG.md` and a noix-docs page, not these. Controller: route the
  §2 row and the dead catalog key into Task 13 or a backlog row. Not a
  defect of this task — the brief scoped fixes to its own files.
- ⚠️ **Not re-run:** the full `swift test`. Per the rubric I did not reproduce
  the 5069/2556 figures; the `S3FileSystemTests` half is corroborated by both
  probe control runs (100 ran, 0 pre-existing failures).

## Task quality: **Needs fixes**

**Reasoning:** The removal itself is correct, minimal and genuinely pinned —
`.bucket` is untouched, the probe survives, 403 still differs from empty, and
the deleted test lost nothing. Two things need fixing before this is the
record it claims to be: the replacement comment asserts in the present tense
something that is not in the tree, and the guard the brief calls "what keeps
this relaxation from widening past its reason" is too loose to see the most
natural form of that widening.

## Strengths

- **The quotation is exact, and I checked it rather than eyeballed it.**
  Unwrapped, `S3FileSystem.swift:178-181` quotes `"An account with no buckets
  is its own outcome for the same reason: an empty browser explains nothing"`;
  `b4620035:…/S3FileSystem.swift:173-175` reads the same string plus its
  sentence period. Character-for-character identical. This is exactly what
  CLAUDE.md's "a correction quotes what it withdraws" asks for, including that
  it corrects in place rather than appending.
- **Nothing went with the deleted test.** `aBucketListWithNoBucketsIsItsOwnOutcome`
  was three statements — `bucketListConfig`, one canned 200 `emptyBucketListXML`,
  `#expect(throws: RemoteFSError.bucketListEmpty)` (diff lines 108-113). No
  request count, no path, no header. The replacement asserts strictly more.
  The report's claim that it is "superseded" is accurate.
- **The fake-transport test's expected values are written down, not derived.**
  `S3FileSystemTests.swift:1687-1692` asserts `requests.count == 2`,
  `httpMethod == "GET"`, `url?.path == "/"`, `url?.query == nil` — four
  literals, none produced by calling the code under test. The branch's earlier
  "computed its expected value from the function under test" failure is not
  repeated here. The `query == nil` check could pass vacuously on a nil `url`,
  but the `path == "/"` check one line above forecloses that, so the negative
  check has its positive beside it (CLAUDE.md, "Guards that name what they
  watch").
- **The probe is pinned as a probe, not just as a non-throw.** `requests.count == 2`
  is what makes "the relaxation removed a throw and not the probe" checkable;
  probe 2 confirms it, and `anAccountWithNoBucketsConnectsInBucketListMode` is
  among the 15 tests that catch the dropped call.
- **Probe 1 is better than the report says.** The report calls it "a proxy",
  but `try?` on the `.bucket` arm's `fetchPage` IS the minimal mutation that
  lets a non-existent named bucket connect — i.e. it directly falsifies the
  property the test asserts, and it is the nearest available plant. Its limit
  is the assertion's looseness (Important 2), not the plant's aim.
- **The dead-case claim and its consumer list verify exactly.** The committed
  producer command reproduces: `grep -rn -e 'throw RemoteFSError.bucketListEmpty'
  -e 'throw .bucketListEmpty' Sources --include='*.swift'` prints nothing,
  exit 1. The pre-change single hit really was line 177 (checked against the
  `b4620035` blob). I also searched the spellings the report's patterns would
  miss — `return RemoteFSError.bucketListEmpty`, `return .bucketListEmpty`,
  `= .bucketListEmpty` — and the only Sources hits are consumers
  (`TransferFailureKind.swift:101` is `RemoteFSError → Name`, verified at
  `:92-101`; `TransferQueueViewModel.swift:1680-1681` likewise). Every one of
  the 11 consumer sites, 4 catalogs and 8 pinning test sites the report
  enumerates is present at the stated line, and I found no consumer it missed.
- **Not deleting the case is the right call.** 11 consumer sites across three
  targets, 4 localized catalogs and 8 pinning tests is its own change with its
  own red; the brief said to report rather than delete, and the report does.

## Issues

### Critical (Must Fix)

None.

### Important (Should Fix)

**1. `Sources/macSCPCore/S3/S3FileSystem.swift:182-183` — the replacement
comment asserts something not in this tree.**

> "The browser now carries the action that resolves the empty state"

It does not. The implementer's own report says so two sections later: "I found
no empty-state view for the file browser … so an empty account now opens on a
blank browser. That is the gap Task 11's create-bucket action is meant to
fill." The parenthetical hedges ("surfaced as the browser's create-bucket
action in Task 11"), but the main clause is present tense and is the sentence
that justifies the removal. The withdrawn claim was quoted perfectly and then
replaced by an unmeasured one — the half of CLAUDE.md's correction rule that
says a correction must not improve a claim.

Fix: state the tree. Something like "`createBucket(_:protection:)` exists in
Core; Task 11 of the s3-bucket-settings plan surfaces it in the browser, and
until it lands an empty account opens on a blank browser." Also prefer the
surface to the plan task number — a plan reference in source goes stale the
day the plan closes, where `createBucket(_:protection:)` does not.

**2. `Tests/macSCPCoreTests/S3FileSystemTests.swift:1703-1709` — the guard that
is supposed to stop the relaxation widening cannot see the widening.**

The test asserts only `#expect(throws: RemoteFSError.self)` and no request
shape. Consider the over-reach the brief actually names — applying the
bucket-list treatment to both modes, e.g. collapsing the `switch` so `.bucket`
also just probes `listBuckets()`. With this fixture the planted code sends
`GET /`, gets the canned 404, and `listBuckets()`'s `default` arm returns
`mapErrorStatus(404, …, path: "/")` → `.notFound(path: "/")`, which is a
`RemoteFSError`. The test stays **green** through the exact mistake it exists
to catch. (`NoSuchBucket` has no arm in `S3ErrorCode.finding(forCode:status:path:)`
— `S3ErrorCode.swift:63-78` — so the body's code never enters the decision;
the status alone does.)

Fix: assert the case and the wire, as the sibling test
`withTheToggleOffConnectStillProbesTheConfiguredBucket`
(`S3FileSystemTests.swift:1664-1675`) already does for the same arm —
`#expect(throws: RemoteFSError.notFound(path: <the reported bucket path>))`
plus `requests.first?.url?.path == "/macscp-seed"` and `list-type=2` in the
query. Then the collapse-the-switch mutation becomes a direct, non-proxy plant
for this test and probe 1's stated limit disappears.

**3. Report accuracy — probe 1's "(only that one)" does not reproduce.**

Re-ran the committed `--apply` string, extracted from the report text rather
than retyped, through `scripts/mutation-probe --filter 'S3FileSystemTests'`.
RED reproduces, the 100-test count reproduces, and
`aNamedBucketThatDoesNotExistStillRefusesTheConnect()` is named — but **three**
tests catch it, not one:

```
RESULT: RED — 100 test(s) ran, and the plant was caught by:
  macSCPCoreTests.S3FileSystemTests/aNamedBucketThatDoesNotExistStillRefusesTheConnect()
  macSCPCoreTests.S3FileSystemTests/connectItselfMapsForbiddenToAuthenticationFailed()
  macSCPCoreTests.S3FileSystemTests/networkFailureMapsToConnectionFailed()
```

A cardinality written beside a command that does not produce it is the failure
CLAUDE.md's "a number travels with the command that produced it" exists for.
It understates the guard's redundancy rather than overstating it, so it does
not change the task's safety — which is why this is Important and not
Critical. Drop the parenthetical or correct it to the three.

Probe 2 reproduces in full: `RESULT: RED — 100 test(s) ran`, 15 catching
tests, including all four the report names
(`anAccountWithNoBucketsConnectsInBucketListMode`,
`aForbiddenBucketListIsItsOwnOutcome`,
`connectAsksForTheBucketListInsteadOfProbingOneBucket`,
`anyOtherBucketListFailureStaysWhatItWas`). Neither probe printed
`PLANT CHANGED NOTHING`, as claimed.

**4. Four comments in untouched files now assert a thrower that does not
exist — named in the report, recorded nowhere in the tree.** *(Labeled
brief-scoped: the brief restricted edits to two files, and the rubric says a
brief-mandated defect is still a finding.)*

All four are genuinely stale; I read each:

- `Sources/macSCPCore/Presentation/ConnectionViewModel.swift:2310` — "`.bucketListEmpty`
  is connect-time only — `connect` is its single thrower." False: there is no
  thrower.
- `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift:1278-1280` —
  "`.bucketListEmpty` needs no arm — `connect` is its only thrower". First
  half false; second half ("a later empty account is an empty browser, not an
  error") now true of every account, which is a different statement.
- `Sources/macSCPCore/RemoteFS/RemoteFSError.swift:24-28` — the case's doc
  comment still carries the withdrawn reason, "a connect that opens on an
  empty browser explains nothing at the form". This is the one that matters
  most: it is where a contributor goes to learn what the case means.
- `ConnectionViewModel.swift:2319-2321` — I'd call this one a mild
  over-claim by the report. "`.bucketListEmpty` blames no row, because nothing
  in the form is wrong: the account has no buckets" is still a true
  description of the arm's `field: nil`; what is stale is that the arm is
  dead, not the sentence.

**One site the report missed, in the same comment block as the one it names:**
`ConnectionViewModel.swift:2306-2308` — "The two S3 bucket-list outcomes
(2026-09-02), both reachable ONLY with `startsAtBucketList` on." It asserts
reachability for a case now reachable from nothing. Two lines above `:2310`.

Route: either a follow-up commit on this branch fixing the five sites
alongside the keep-or-delete decision, or a `docs/BACKLOG.md` row. An SDD
report is not the tree, and CLAUDE.md's rule is explicit that the damage is a
comment going wrong without appearing in a diff.

### Minor (Nice to Have)

**1. Report clears a comment that is in fact stale (pre-existing, not this
task's doing).** The report lists `RemoteFSError.swift:16` — "only at connect
time", about `bucketListForbidden` — as "still true". It is not:
`RemoteBrowserViewModel.swift:1274-1277` records the opposite with a
measurement ("Task 3 review, M-3: `listBuckets` runs again on every listing of
`/` and on a `stat` of a bucket"), and `S3FileSystem.list(path:)` confirms it
(`if isBucketListRoot(path) { return try await listBuckets() }`). Two comments
in the tree contradict each other on this; neither was touched by this commit.
Worth folding into the same follow-up.

**2. `S3FileSystemTests.swift:1548-1549` — an unmeasured universal, two lines
from a fixture whose comment exists because such a universal was false.** The
new fixture's doc reads "What every S3 implementation answers `ListObjectsV2`
on a bucket that is not there." Its neighbour `accessDeniedXML` says "What AWS
answers … MinIO does NOT answer this — measured 2026-09-02". And the claim is
load-bearing for nothing: `NoSuchBucket` has no arm in
`S3ErrorCode.finding(forCode:status:path:)`, so the test behaves identically
with an empty body. Say what it is — a plausible 404 body; the outcome comes
from the status.

**3. `S3FileSystemTests.swift:1641`, `:1711`, `:1722` — the Outcome
enumeration now reads 1, 3, 4.** Outcome 2's test went with the refusal and
the replacement carries no label tying it back to the design's §2 table, so
the file's mapping to that table has a silent hole. One clause on
`anAccountWithNoBucketsConnectsInBucketListMode`'s doc comment closes it
("Outcome 2 of the design's §2 table, as that row now stands: 200 with zero
buckets no longer refuses"). This is in the task's own file, so the
brief's scoping does not excuse it. CLAUDE.md: an enumeration in a comment is
counted in the moment it changes.

**4. `S3FileSystemTests.swift:1552` — the fixture names a bucket the request
never asks for.** `<BucketName>nope</BucketName>`, left over from the brief's
`.bucket("nope")` sketch, while the test uses `self.config` whose bucket is
`macscp-seed` and whose request path is `/macscp-seed`. Harmless today
(the field is unread) and misleading to the next reader. Either align it or
add a `configNamingAMissingBucket` as the brief sketched.

**5. "occurrences" beside a line count.** The report writes "All remaining
occurrences (19 lines in `Sources`, from `grep -rn -e 'bucketListEmpty'
Sources --include='*.swift' | wc -l` …)". The command reproduces exactly — I
get 19 — but it counts lines, and occurrences are **20**
(`grep -ro -e 'bucketListEmpty' Sources --include='*.swift' | wc -l`), because
`ConnectionViewModelTests`-style double hits share a line. The figure is
correctly labeled "lines" inside the parenthesis and mislabeled "occurrences"
outside it — the precise `grep -c` / `grep -o` slip CLAUDE.md names. One word.

## Commands I ran

All extracted from the report text programmatically, never retyped.

| command | report's figure | mine |
|---|---|---|
| `grep -rn -e 'throw RemoteFSError.bucketListEmpty' -e 'throw .bucketListEmpty' Sources --include='*.swift'` | nothing, exit 1 | nothing, exit 1 ✅ |
| `grep -rn -e 'bucketListEmpty' Sources --include='*.swift' \| wc -l` | 19 | 19 ✅ (occurrences 20 — Minor 5) |
| same pattern against `b4620035`'s blob | "single hit … line 177" | `177:` ✅ |
| `scripts/mutation-probe --filter 'S3FileSystemTests' --apply "<probe 1>"` | RED, 100 ran, caught by 1 | RED, 100 ran, caught by **3** ❌ (Important 3) |
| `scripts/mutation-probe --filter 'S3FileSystemTests' --apply "<probe 2>"` | RED, 100 ran, caught by 15 incl. 4 named | RED, 100 ran, 15, all 4 named present ✅ |
| comment quotation vs `git show b4620035:…` | "verbatim" | identical ✅ |

The report's `grep -n "✘\|Test run with\|error:"` is a grep of a local test log
that is not in the tree; it cannot be re-run and I did not count it against the
report. `git status --porcelain` was empty before and after both probes; the
harness reverted both plants.
