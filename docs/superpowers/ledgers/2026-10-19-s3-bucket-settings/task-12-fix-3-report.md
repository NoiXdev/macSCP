# Task 12, fix round 3 -- report

Base `6332cc69`. Commits: `0ac31adf` (Finding B), `83ffa661` (Findings A and D).
Every probe below ran against the COMMITTED tree `83ffa661` (clean, nothing
staged), one at a time, nothing written to the worktree while it ran.

**How to read the probe blocks.** Each block is one command, from the repository
root, that runs as written: file operand included, no prose, quoting that works
inside the double-quoted `--apply` (so `$1` is `\$1` and the literal `$0` is
`\\\$0`). The commands were not retyped for this report: this file is generated
from the same text file the probes were run from (`probes.txt`, one command per
probe id). `control:` is the harness's unplanted run; `RESULT:` is the planted
one. Counts are tests the harness counted (`testEnded` events), not lines.
A block whose Observed is `VERDICT PENDING` has not returned yet.

## Finding B -- the sort guard's filter anchor reads code, not comments

Change (`0ac31adf`): `theSortIsAppliedToTheFilterResult` reads
`SourceCorpus.code(of:)` through a new helper `sheetCode()`. Moving the whole
suite's `sheetSource()` to `code(of:)` was tried first and failed two siblings,
`theCellsDrawTheTextTheSortKeysOn` and `eachColumnCarriesItsOwnFieldsComparator`
(`swift test --filter AuditLogSortWiringGuardTests`: `Test run with 9 tests in 1
suite failed ... with 7 issues`, counted from the run's own summary line); they
read column titles and the search spelling, which are string literals. They are
untouched and keep the raw view. That is the hard boundary you set, reached and
respected: I did not fix the siblings and did not widen the change.

**S1** -- the call survives ONLY inside a comment (the plant that decides whether Finding B worked)

Expected: RED, caught by `theSortIsAppliedToTheFilterResult()`

```
scripts/mutation-probe --filter 'AuditLogFilterTests|AuditLogSortWiringGuardTests' --apply "perl -0pi -e 's/filter\.includes\(\\\$0\) && predicate/true \/* filter.includes( *\/ && predicate/' Sources/MacSCPAppKit/AuditLogSheet.swift"
```

Observed:

```
── control: 17 test(s) ran, 0 pre-existing failures
RESULT: RED — 17 test(s) ran, and the plant was caught by:
  macSCPAppKitTests.AuditLogSortWiringGuardTests/theSortIsAppliedToTheFilterResult()
```

**S0** -- the positive half: the real call present, a harmless comment added beside it

Expected: GREEN (the guard still accepts the real call, in the same run shape)

```
scripts/mutation-probe --filter 'AuditLogFilterTests|AuditLogSortWiringGuardTests' --apply "perl -0pi -e 's/filter\.includes\(\\\$0\) && predicate/filter.includes(\\\$0) \/* a comment *\/ && predicate/' Sources/MacSCPAppKit/AuditLogSheet.swift"
```

Observed:

```
── control: 17 test(s) ran, 0 pre-existing failures
RESULT: GREEN — 17 test(s) ran and NONE of them noticed the plant.
```

**S2** -- `(filter.includes($0) || true) && predicate`: the call present, the filter dead

Expected: GREEN. OUT OF REACH of a text guard: it is a semantic defeat, the text of the real call is all there. Named, not chased.

```
scripts/mutation-probe --filter 'AuditLogFilterTests|AuditLogSortWiringGuardTests' --apply "perl -0pi -e 's/filter\.includes\(\\\$0\) && predicate/(filter.includes(\\\$0) || true) && predicate/' Sources/MacSCPAppKit/AuditLogSheet.swift"
```

Observed:

```
── control: 17 test(s) ran, 0 pre-existing failures
RESULT: GREEN — 17 test(s) ran and NONE of them noticed the plant.
```

## Finding A (Ruling 26) -- the branching scan over `create` is withdrawn

Change (`83ffa661`): `createRecordsItsRefusalWithoutBranching` deleted;
`createMakesExactlyTwoRecordingCalls` stands alone (exactly two
`recordBucketCreated(` calls inside `create`). The limit is stated in the test's
comment in prose. The deletion is red-free by construction (removing a check
cannot turn a test red) and no red is claimed for it. What is owed is the
measurement that the hole is documented, not newly opened, and that the
surviving positive half still catches a deleted record.

**H1** -- the HELPER hole: the record goes through a helper that decides

Expected: GREEN (documented limit: the shape is not guarded)

```
scripts/mutation-probe --filter 'BucketSettingsAuditTests' --apply "perl -0pi -e 's/            recorder\?\.recordBucketCreated\(bucket: bucket, protection: choice, failure: refusal\.sentence\)/            whenRefused(recorder)?.recordBucketCreated(bucket: bucket, protection: choice, failure: refusal.sentence)/; s/(    \/\/\/ What a refused create comes to:)/    private func whenRefused(_ r: AuditRecorder?) -> AuditRecorder? {\n        if case .failed = outcome { return r } else { return nil }\n    }\n\n\$1/' Sources/MacSCPAppKit/CreateBucketSheet.swift"
```

Observed:

```
── control: 11 test(s) ran, 0 pre-existing failures
RESULT: GREEN — 11 test(s) ran and NONE of them noticed the plant.
```

**H2** -- the CLOSURE hole: the record inside a closure handed to an optional's map, no keyword anywhere

Expected: GREEN (documented limit)

```
scripts/mutation-probe --filter 'BucketSettingsAuditTests' --apply "perl -0pi -e 's/(            )(recorder\?\.recordBucketCreated\(bucket: bucket, protection: choice, failure: refusal\.sentence\))/\$1_ = Optional(refusal).map { _ in \$2 }/' Sources/MacSCPAppKit/CreateBucketSheet.swift"
```

Observed:

```
── control: 11 test(s) ran, 0 pre-existing failures
RESULT: GREEN — 11 test(s) ran and NONE of them noticed the plant.
```

**C6** -- the refusal's record deleted

Expected: RED, caught by `createMakesExactlyTwoRecordingCalls()` (and by the behavioural tests)

```
scripts/mutation-probe --filter 'BucketSettingsAuditTests' --apply "perl -0pi -e 's/            recorder\?\.recordBucketCreated\(bucket: bucket, protection: choice, failure: refusal\.sentence\)\n//' Sources/MacSCPAppKit/CreateBucketSheet.swift"
```

Observed:

```
── control: 11 test(s) ran, 0 pre-existing failures
RESULT: RED — 11 test(s) ran, and the plant was caught by:
  macSCPAppKitTests.BucketSettingsAuditTests/aRefusalsOwnWordsNeverReachTheTrail(operation:)
  macSCPAppKitTests.BucketSettingsAuditTests/aRefusedOperationRecordsTheFailureAndNotASuccess(operation:)
  macSCPAppKitTests.BucketSettingsAuditTests/createMakesExactlyTwoRecordingCalls()
```

### The five round-2 plants, re-run against the tree after the deletion

Round 2 reported C1 to C5 as RED in its table, with the prose under it reading,
verbatim: "All caught by `createRecordsItsRefusalWithoutBranching()`." (Corrected
2026-10-22: this sentence first spliced the two into one quoted string,
"`RED ... caught by createRecordsItsRefusalWithoutBranching()`", which is not
text that stands anywhere in that report.)
That guard no longer exists. Old wording, quoted: "All caught by
`createRecordsItsRefusalWithoutBranching()`." Each is re-run below; the verdict
observed wins.

**C1** -- `guard case ... else { return }` before the record

Expected: GREEN now (no guard looks for the shape; behaviour is identical, a refusal is always a refusal)

```
scripts/mutation-probe --filter 'BucketSettingsAuditTests' --apply "perl -0pi -e 's/(            )(recorder\?\.recordBucketCreated\(bucket: bucket, protection: choice, failure: refusal\.sentence\))/\$1guard case .failed = outcome else { return }\n\$1\$2/' Sources/MacSCPAppKit/CreateBucketSheet.swift"
```

Observed:

```
── control: 11 test(s) ran, 0 pre-existing failures
RESULT: GREEN — 11 test(s) ran and NONE of them noticed the plant.
```

**C2** -- `if failureSentence != nil { <record> }`

Expected: GREEN now (no guard looks for the shape; behaviour is identical, a refusal is always a refusal)

```
scripts/mutation-probe --filter 'BucketSettingsAuditTests' --apply "perl -0pi -e 's/(            )(recorder\?\.recordBucketCreated\(bucket: bucket, protection: choice, failure: refusal\.sentence\))/\$1if failureSentence != nil { \$2 }/' Sources/MacSCPAppKit/CreateBucketSheet.swift"
```

Observed:

```
── control: 11 test(s) ran, 0 pre-existing failures
RESULT: GREEN — 11 test(s) ran and NONE of them noticed the plant.
```

**C3** -- `switch outcome { case .failed: <record> default: break }`

Expected: GREEN now (no guard looks for the shape; behaviour is identical, a refusal is always a refusal)

```
scripts/mutation-probe --filter 'BucketSettingsAuditTests' --apply "perl -0pi -e 's/(            )(recorder\?\.recordBucketCreated\(bucket: bucket, protection: choice, failure: refusal\.sentence\))/\$1switch outcome { case .failed: \$2 default: break }/' Sources/MacSCPAppKit/CreateBucketSheet.swift"
```

Observed:

```
── control: 11 test(s) ran, 0 pre-existing failures
RESULT: GREEN — 11 test(s) ran and NONE of them noticed the plant.
```

**C4** -- the old gate, `if case .failed = outcome { <record> }`

Expected: GREEN now (no guard looks for the shape; behaviour is identical, a refusal is always a refusal)

```
scripts/mutation-probe --filter 'BucketSettingsAuditTests' --apply "perl -0pi -e 's/(            )(recorder\?\.recordBucketCreated\(bucket: bucket, protection: choice, failure: refusal\.sentence\))/\$1if case .failed = outcome { \$2 }/' Sources/MacSCPAppKit/CreateBucketSheet.swift"
```

Observed:

```
── control: 11 test(s) ran, 0 pre-existing failures
RESULT: GREEN — 11 test(s) ran and NONE of them noticed the plant.
```

**C5** -- `if refusal.sentence.isEmpty { return }` before the record

Expected: GREEN now (no guard looks for the shape; behaviour is identical, a refusal is always a refusal)

```
scripts/mutation-probe --filter 'BucketSettingsAuditTests' --apply "perl -0pi -e 's/(            )(recorder\?\.recordBucketCreated\(bucket: bucket, protection: choice, failure: refusal\.sentence\))/\$1if refusal.sentence.isEmpty { return }\n\$1\$2/' Sources/MacSCPAppKit/CreateBucketSheet.swift"
```

Observed:

```
── control: 11 test(s) ran, 0 pre-existing failures
RESULT: GREEN — 11 test(s) ran and NONE of them noticed the plant.
```

## Finding C -- every round-2 probe, in a form that runs as committed

The round-2 report's `--apply` cells for B, D, R22 and E omitted the file
operand (it sat only in the table header), B2 and B3 were prose, and R22's
quoting only worked inside a double-quoted argument. Old wording, quoted from
`task-12-fix-2-report.md`: "In the `--apply` strings below `$1` is written
`\$1` inside the double-quoted argument." and the column header
"`--apply` (file `Sources/MacSCPAppKit/AuditLogSheet.swift`)". (Corrected
2026-10-22: the header was first given as "`(file ...)` in the column header",
an elision inside quote marks, which is a description and not a quote.) Each probe is re-run here in its repaired form, from the committed tree,
and the verdict observed is recorded. Where a verdict differs from what round 2
claimed, it is flagged in the line under the block.

**N3** -- a refused retention is recorded as GOVERNANCE

Expected: RED (round 2: RED)

```
scripts/mutation-probe --filter 'ObjectLock|Audit' --apply "perl -0pi -e 's/\.retention\(written, key: key, bucket: bucket\), failure: applyFailure\)/.retention(ObjectRetention(mode: .governance, retainUntil: retainUntil), key: key, bucket: bucket), failure: applyFailure)/' Sources/MacSCPAppKit/ObjectLockSheet.swift"
```

Observed:

```
── control: 254 test(s) ran, 0 pre-existing failures
RESULT: RED — 254 test(s) ran, and the plant was caught by:
  macSCPAppKitTests.BucketSettingsAuditTests/aRefusedOperationRecordsTheFailureAndNotASuccess(operation:)
```

**N3M** -- mirror: a refused retention is recorded as COMPLIANCE

Expected: RED (round 2: RED)

```
scripts/mutation-probe --filter 'ObjectLock|Audit' --apply "perl -0pi -e 's/\.retention\(written, key: key, bucket: bucket\), failure: applyFailure\)/.retention(ObjectRetention(mode: .compliance, retainUntil: retainUntil), key: key, bucket: bucket), failure: applyFailure)/' Sources/MacSCPAppKit/ObjectLockSheet.swift"
```

Observed:

```
── control: 254 test(s) ran, 0 pre-existing failures
RESULT: RED — 254 test(s) ran, and the plant was caught by:
  macSCPAppKitTests.BucketSettingsAuditTests/aRefusedOperationRecordsTheFailureAndNotASuccess(operation:)
```

**B1** -- `case _:` after the last arm of `Filter.segment(of:)`

Expected: RED (round 2: RED)

```
scripts/mutation-probe --filter 'AuditLogFilterTests|AuditLogSortWiringGuardTests' --apply "perl -0pi -e 's/(            case \.plaintextConfirmed:\n\s*return nil\n)/\$1            case _:\n                return nil\n/' Sources/MacSCPAppKit/AuditLogSheet.swift"
```

Observed:

```
── control: 17 test(s) ran, 0 pre-existing failures
RESULT: RED — 17 test(s) ran, and the plant was caught by:
  macSCPAppKitTests.AuditLogFilterTests/everyArmOfTheClassificationNamesAKindAndTogetherTheyAreAllOfThem()
```

**B2** -- `default:` after the last arm (round 2 gave this as prose and never ran it as a command)

Expected: RED

```
scripts/mutation-probe --filter 'AuditLogFilterTests|AuditLogSortWiringGuardTests' --apply "perl -0pi -e 's/(            case \.plaintextConfirmed:\n\s*return nil\n)/\$1            default:\n                return nil\n/' Sources/MacSCPAppKit/AuditLogSheet.swift"
```

Observed:

```
── control: 17 test(s) ran, 0 pre-existing failures
RESULT: RED — 17 test(s) ran, and the plant was caught by:
  macSCPAppKitTests.AuditLogFilterTests/everyArmOfTheClassificationNamesAKindAndTogetherTheyAreAllOfThem()
```

**B3** -- `case let other:` after the last arm (round 2 gave this as prose and never ran it as a command)

Expected: RED

```
scripts/mutation-probe --filter 'AuditLogFilterTests|AuditLogSortWiringGuardTests' --apply "perl -0pi -e 's/(            case \.plaintextConfirmed:\n\s*return nil\n)/\$1            case let other:\n                _ = other\n                return nil\n/' Sources/MacSCPAppKit/AuditLogSheet.swift"
```

Observed:

```
── control: 17 test(s) ran, 0 pre-existing failures
RESULT: RED — 17 test(s) ran, and the plant was caught by:
  macSCPAppKitTests.AuditLogFilterTests/everyArmOfTheClassificationNamesAKindAndTogetherTheyAreAllOfThem()
```

**D1** -- `.errors` returns `true`

Expected: RED (round 2: RED)

```
scripts/mutation-probe --filter 'AuditLogFilterTests|AuditLogSortWiringGuardTests' --apply "perl -0pi -e 's/return event\.isError/return true/' Sources/MacSCPAppKit/AuditLogSheet.swift"
```

Observed:

```
── control: 17 test(s) ran, 0 pre-existing failures
RESULT: RED — 17 test(s) ran, and the plant was caught by:
  macSCPAppKitTests.AuditLogFilterTests/theErrorsSegmentListsAFailedEventAndNotASuccessfulOne(kind:)
```

**R22** -- the sheet ignores the filter: `true && predicate`

Expected: RED (round 2: RED)

```
scripts/mutation-probe --filter 'AuditLogFilterTests|AuditLogSortWiringGuardTests' --apply "perl -0pi -e 's/filter\.includes\(\\\$0\) && predicate/true && predicate/' Sources/MacSCPAppKit/AuditLogSheet.swift"
```

Observed:

```
── control: 17 test(s) ran, 0 pre-existing failures
RESULT: RED — 17 test(s) ran, and the plant was caught by:
  macSCPAppKitTests.AuditLogSortWiringGuardTests/theSortIsAppliedToTheFilterResult()
```

**E** -- a harmless string literal naming `default:` and `case _`

Expected: GREEN (round 2: GREEN)

```
scripts/mutation-probe --filter 'AuditLogFilterTests|AuditLogSortWiringGuardTests' --apply "perl -0pi -e 's/(        static func segment\(of kind: AuditEvent\.Kind\) -> Filter\? \{\n)/\$1            let note = \"default: case _:\"\n            _ = note\n/' Sources/MacSCPAppKit/AuditLogSheet.swift"
```

Observed:

```
── control: 17 test(s) ran, 0 pre-existing failures
RESULT: GREEN — 17 test(s) ran and NONE of them noticed the plant.
```

## Finding D -- the missing quote

In `theTableCoversEveryNewKind` the comment went from "seventh operation" to
"eighth operation" in `3b4b9b98` without quoting the withdrawn sentence. It is
quoted in `83ffa661`: "a duplicated row would pass the two checks above while
the parameterised tests ran a bogus case as a seventh operation". Comment-only,
no behavioural red.

## Summary of verdicts, and where they differ from what was claimed

All 19 probes ran from the committed tree `83ffa661`; every `control:` line said
`0 pre-existing failures` (11 tests for `BucketSettingsAuditTests`, 17 for the
two audit-filter suites, 254 for `ObjectLock|Audit`).

- Every verdict matched its expectation, including B2 and B3 (never before run as
  commands): RED, caught by `everyArmOfTheClassificationNamesAKindAndTogetherTheyAreAllOfThem()`.
- **Finding B's governing check:** S1 (the call present only in a comment) RED,
  S0 (the real call present beside a comment) GREEN, both against the same
  guard. S2 (`|| true`) GREEN, as named: out of reach of a text guard.
- **Finding A:** H1 (helper) and H2 (closure) GREEN, C6 RED, caught by
  `createMakesExactlyTwoRecordingCalls()` among others.
- **Round 2's claim for C1 to C5 is superseded.** Old wording, quoted from
  `task-12-fix-2-report.md`: "All caught by `createRecordsItsRefusalWithoutBranching()`."
  All five are GREEN now (the guard they were caught by is deleted, and each
  plant changes no behaviour). That is the documented limit, not a new hole.
- N3 / N3M: control 254 here; round 2 recorded 253 for the same filter at an
  earlier commit. I did not trace the one-test difference.

## Verification

Full `swift test` at `83ffa661`, no `--build-system` flag, counted from the run's
own summary lines: Core `✔ Test run with 5085 tests in 408 suites passed`; AppKit
`✘ Test run with 2848 tests in 240 suites failed ... with 1 issue`, the one issue
being `ViewTestabilitySpike.swift:202:9` (`off == on`), known and not mine.
`git status --porcelain -uall` empty afterwards.

## Concerns and limits

- Finding B changes ONE guard's corpus view. The two siblings that need string
  literals keep the raw view and therefore still read comments; they are not
  asserting calls, but they carry the same weakness in principle. Not widened.
- The shape of `create`'s record (unconditional, straight from the catch) is no
  longer guarded at all. A reader or reviewer holds it, not a test.
- Process note: the first run of this round was lost to a network error after
  the three Finding B probes (S0, S1, S2) had returned; their verdicts were
  recovered from the probe log that run had written, and the report was then
  rebuilt from the same `probes.txt` the probes were run from.
