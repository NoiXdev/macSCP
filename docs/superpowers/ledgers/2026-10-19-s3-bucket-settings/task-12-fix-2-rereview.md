# Task 12, fix round 2 -- re-review

Scope `31e24403..6332cc69` (four commits). HEAD `6332cc69`, tree clean, nothing staged at start.
All probes through `scripts/mutation-probe` on the committed tree (clean index = HEAD, so the
harness's "staged tree" baseline is the commit). To read per-case attribution I ran the harness
with a `swift` shim first on PATH (scratchpad `shim/swift`): it execs `/usr/bin/swift` unchanged
and only tees stdout and copies the `--event-stream-output-path` file. It touches no tracked file.

## Check 1 and 2 -- the governing plants, both directions, committed tree, per-case attribution

Both run as `probe.sh <tag> 'ObjectLock|Audit' <label> "<apply>"` (a thin scratchpad wrapper that
sets the shim and calls `scripts/mutation-probe --filter ... --apply ...`). The `--apply` is round
2's N3 string, with the file argument.

| plant | control | RESULT | issue line (verbatim, from the swift test stdout) |
|---|---|---|---|
| recorded mode forced to `.governance` | 254 ran, 0 pre-existing | RED, caught by `BucketSettingsAuditTests/aRefusedOperationRecordsTheFailureAndNotASuccess(operation:)` | `recorded an issue with 1 argument operation → set a file's COMPLIANCE retention at BucketSettingsAuditTests.swift:256:9: Expectation failed: describesTheAttempt`; `with 7 test cases failed ... with 1 issue` |
| recorded mode forced to `.compliance` | 254 ran, 0 pre-existing | RED, same test | `recorded an issue with 1 argument operation → set a file's retention at BucketSettingsAuditTests.swift:256:9: Expectation failed: describesTheAttempt`; `with 7 test cases failed ... with 1 issue` |

Attribution is READ, not constructed: the issue line carries the `operation` argument (its
`testDescription` = the row's `name`). Forced-GOVERNANCE is caught by exactly the COMPLIANCE row,
forced-COMPLIANCE by exactly the GOVERNANCE row, one case of seven each. That is what the
construction argument predicts. Control 254 = round 2's 253 + the one new test function of
`73878dff` (D); round 2's 253 was taken at `3b4b9b98`, before that commit.
Logs: scratchpad `out/n3gov/run2.log`, `out/n3comp/run2.log`.

## Check 3 -- the declared deviation, tested: probes re-run from the committed tree

Seven of the report's probes re-run from `6332cc69` (clean index = HEAD), each through
`scripts/mutation-probe` with the `--apply` string as the report carries it, with ONE addition
that I had to make (below). Controls and results:

| probe (report's name) | commit it belongs to | filter | control | RESULT |
|---|---|---|---|---|
| B1 | `73878dff` | `AuditLogFilterTests\|AuditLogSortWiringGuardTests` | 17 ran, 0 pre-existing | RED, `everyArmOfTheClassificationNamesAKindAndTogetherTheyAreAllOfThem()` only |
| D1 | `73878dff` | same | 17, 0 | RED, `theErrorsSegmentListsAFailedEventAndNotASuccessfulOne(kind:)` only |
| R22 | `ed0e0a78` | same | 17, 0 | RED, `AuditLogSortWiringGuardTests/theSortIsAppliedToTheFilterResult()` only |
| E (string naming `default:` and `case _`) | `73878dff` | same | 17, 0 | GREEN, 17 ran, none noticed (intended) |
| C1 | `6332cc69` | `BucketSettingsAuditTests` | 11, 0 | RED, `createRecordsItsRefusalWithoutBranching()` only |
| C3 | `6332cc69` | same | 11, 0 | RED, same, only |
| C6 (refusal's record deleted) | `6332cc69` | same | 11, 0 | RED, `createRecordsItsRefusalWithoutBranching()` + `aRefusedOperationRecordsTheFailureAndNotASuccess(operation:)` + `aRefusalsOwnWordsNeverReachTheTrail(operation:)`; NOT `RUN INCOMPLETE` |

Every result matches the report. C6 specifically confirms the report's fix of its own first
draft (the range no longer traps).

**What did not run in the form committed.** The report's probe table for B/D/R22/E gives
`--apply` strings WITHOUT the file argument ("file `Sources/MacSCPAppKit/AuditLogSheet.swift`" is
in the table's header). `perl -0pi -e '...'` with no file operand reads stdin; run unedited it
would hang or no-op, so I appended `Sources/MacSCPAppKit/AuditLogSheet.swift` to each. B2 and B3
are descriptions ("same with `default:...`"), not strings, so I did not run them (B1 stands for
the family; the sibling spelling `default:` is separately tested by the `!hasDefault` expect).
The R22 cell carries `\\\$0` "as typed in the shell"; it is correct only inside a double-quoted
`--apply` (which I used), and wrong in the single-quoted form a reader would also reasonably
type. All of these are the CLAUDE.md "must run in the form it is committed" failure in small:
Minor finding, report-only (nothing in the tree is affected).

The deviation therefore does not matter for the results: all seven committed-tree probes
reproduce round 2's staged-tree verdicts and controls (17 / 11, 0 pre-existing).

## Check 4 -- the E probe's green beside a red on the same guard

E (string naming `default:` and `case _`) is GREEN with filter `AuditLogFilterTests|AuditLogSortWiringGuardTests`,
control 17. B1 (a real `case _:` arm) with the SAME filter, SAME file and SAME run shape is RED, caught by
`everyArmOfTheClassificationNamesAKindAndTogetherTheyAreAllOfThem()` only. So the green means "the
guard ignores strings", not "the guard is dead". Not run: E under the old `commentFree` view (would
it have gone falsely red) -- round 2 did not run it either.

## Check 5 -- Finding A's fixture (read from `git show 6332cc69:Tests/macSCPAppKitTests/BucketSettingsAuditTests.swift`)

The new row sets `model.mode = .compliance`, `model.retainUntil = until` (1_800_000_000),
`model.acknowledged = true` LAST (the model's `didSet`s on `mode` and `retainUntil` clear it,
`ObjectLockSheet.swift`), injects `now: { clock }` (1_700_000_000, so `until` is in the future) and
its prefix reads `... set to COMPLIANCE until 2027-01-15T08:00:00Z`.
`date -u -r 1800000000 +%Y-%m-%dT%H:%M:%SZ` prints `2027-01-15T08:00:00Z`. The GOVERNANCE row is
unchanged: no mode set, default `.governance` (`var mode: RetentionMode = .governance`), prefix
`... set to GOVERNANCE until `. Prefix and attempt agree in both rows, and the two plants of
checks 1-2 prove it behaviourally (each plant is caught by exactly the other row). A third
confirmation: plant P9c (SUCCESS-path mode forced to `.governance`) is RED, caught by
`eachOperationRecordsExactlyOneEventOfItsOwnKind(operation:)` on the COMPLIANCE row
(`startsAsExpected`) and `anObjectLockLineNamesWhichOfTheThreeOperationsItWas()`.

## Check 6 -- the recounted numbers

Rows of `operations` at `6332cc69`, counted by reading the table: create a bucket, change
versioning, save CORS rules, set a file's retention (GOVERNANCE), set a file's COMPLIANCE
retention, place a legal hold, set a bucket's Object Lock default = **7**. Of these, kind
`.objectLockChanged`: retention x2, legal hold, bucket default = **4**. Distinct operations in that
kind (retention, hold, default) = 3, so "the one kind that covers three operations, and the
retention is in it twice" is true. The five apply methods are the five named in the suite doc
(`create`, `apply`, `save` (CORS), `run`, `save` (default)): "Seven rows for the five apply methods"
is true. The new positive control (`modes == ["GOVERNANCE", "COMPLIANCE"]`, filtered on
`"set to \(mode) until"`) does not match the default-retention row ("set to GOVERNANCE for 30
days"). `lockRows.count == 4` and `operations.count == 7` match my count; the planted runs' own
logs say "with 7 test cases" for the refused-write test, independently.

## Check 7 -- withdrawals quote verbatim

Old text from the pre-round file (`31e24403`) flattened to one line (comment markers stripped), then
`/usr/bin/grep -c -F` of each quote (LINES; the flattened file is one line):
"Three of the rows share a kind on purpose: it is the one kind that covers three operations."
prints 1; "Six rows for the five apply methods (`ObjectLockModel.run` serves the retention and the legal
hold)" prints 1. The two removed checks (`lockRows.count == 3`, `Self.operations.count == 6`) are
named correctly. The "Corrected (Task 12, fix round 2)" note under
`aRefusedOperationRecordsTheFailureAndNotASuccess` leaves the withdrawn sentence in place and says
what was false of it: nothing erased.

One change is NOT quoted: the same comment's tail went from "...ran a bogus case as a seventh
operation" (old file line 167) to "...as an eighth operation"
(`/usr/bin/grep -n 'seventh\|eighth'` on both files). It follows from the new count and the meaning
is intact, so Minor. The segment guard and the create guard replaced test doc comments; those are
test comments, not the measurement record the rule binds, and the replacement narrates what the
first version missed ("A first version looked for the text `if case`...", which round 1b measured as
H3-H5). Searching the tree at `6332cc69` for the removed names: exactly one line still names
`matchesFilter` (the 2026-08-19 plan, as round 2 said); no source or test names
`theClassificationHasNoDefaultArm` or `createRecordsItsRefusalWithoutAnOutcomeGate`.

## Check 8 -- Guard C's helper hole, sized

Plants (committed tree, filter `BucketSettingsAuditTests`, control 11, 0 pre-existing; plant scripts
in scratchpad `plants/`):

| plant | what it does | RESULT |
|---|---|---|
| P8a | the refusal's call becomes `whenRefused(recorder)?.recordBucketCreated(...)`; `whenRefused` (file-level, `@MainActor`, appended to `CreateBucketSheet.swift`) is `if r != nil { return r } else { return nil }` -- a branch in a helper the `catch` calls, always-true so no behaviour test can see it | **GREEN, 11 ran, none noticed** |
| P8c | the whole record, with its branch, moved into a helper (`recordRefusal(recorder, bucket, choice, refusal.sentence)`), so `create` holds one `recordBucketCreated(` | RED, but only by the positive half: `recordingCalls == 2` (BucketSettingsAuditTests.swift:444) and "the refusal's record is not inside the catch" (:454). Right result, accidental reason |

So the hole is fully open for any branch whose helper wraps the RECEIVER or an ARGUMENT of the call
while the literal call stays in `create`. The guard sees only the text of `create`; what it pins is
"no control-flow keyword textually between `catch {` and the call", not "the record is
unconditional".

## Check 9 -- plants outside the author's enumeration

| plant | filter | control | RESULT |
|---|---|---|---|
| P9a: `_ = Optional(refusal).map { _ in recorder?.recordBucketCreated(...) }` (gate by closure, no keyword, no ` ? `, always runs) | `BucketSettingsAuditTests` | 11 | **GREEN** |
| P9b: `(filter.includes($0) \|\| true) && predicate` in `filteredEvents` (the sheet ignores the segment) | `Audit` | 102 | **GREEN** |
| P9f: `true /* filter.includes( */ && predicate` (the anchor survives only in a comment) | `Audit` | 102 | **GREEN** |
| P9c: success-path retention record forced to `.governance` | `ObjectLock\|Audit` | 254 | RED (see check 5) |
| P9d: `.corsChanged` moved from the File Ops arm to the Terminal arm | `Audit` | 102 | RED, `aBucketSettingsWriteIsListedUnderFileOps(kind:)` and `...UnderNoOtherKindSegment(kind:)`, both naming `.corsChanged` |

- **P9a** is a second, larger hole in guard C than the declared helper hole: closure combinators
  (`.map`, `.forEach`, `.compactMap`, `&&`/`||` short-circuit) branch with no keyword in the scanned
  region. Round 2's report names only the helper case. Same class: the keyword list is a spelling
  list of a closed set, and the language has branching that is not in the set.
- **P9b/P9f**: Ruling 22 removed the forwarder, but the round-1b H2 plant (the sheet's own use of the
  classification untested) reproduces one line up, GREEN. The sort-wiring guard reads raw text
  (`SourceCorpus.text(of:)`, AuditLogSortWiringGuardTests.swift line 61 at `6332cc69`), so a comment
  satisfies its new anchor `filter.includes(`. Nothing in this round made that worse (the old
  `matchesFilter(` anchor had the same weakness), but "Ruling 22 closed H2" would be false; round 2
  does not claim it.

## Check 10 -- leaks

New assertions: `#expect(describesTheAttempt, "\(operation.name)")` (a Bool computed first; the
message is the row name, as the issue lines above show); `modes == ["GOVERNANCE", "COMPLIANCE"]`
(constants); guard B prints pattern text and case names; guard C prints keywords found; the D test
computes `listsTheFailure`/`listsTheSuccess` first. The COMPLIANCE row's bucket/key/mode/date are
fixtures. `aRefusalsOwnWordsNeverReachTheTrail` is unchanged and still computes `leaked` before
`#expect`. The issue lines I read from the planted runs contain no canary text. Nothing found.

## Verdicts

- **Important 1 (reopened): CLOSED.** Both directions RED on the committed tree, each caught by exactly the other mode's row (attribution read from the issue line, not inferred).
- **Finding A fixture / recounts: closed.** 7 rows, 4 lock rows, counted.
- **Finding B: CLOSED.** B1 RED on the committed tree; B2/B3 not run.
- **Finding C: closed for the keyword spellings (C1, C3, C6 re-run RED), NOT closed in its property.** P8a and P9a are GREEN. The tree pins "no control-flow keyword between catch and call", not "the record is unconditional".
- **Finding D: CLOSED** (D1 RED). **Finding E: CLOSED** (E GREEN beside B1 RED in the same run shape).
- **Ruling 22: closed in letter** (R22 RED); H2's substance reproduces (P9b, P9f GREEN), pre-existing.

## New defects introduced by the four commits

None in behaviour or tests. Report-level only:
1. The report's B/D/R22/E probe `--apply` cells omit the file operand (header only), B2/B3 are prose, R22's quoting is double-quote-only: not runnable as committed (Minor).
2. "seventh" -> "eighth" in the count comment, unquoted (Minor).

## Not verified

- B2 (`default:` arm) and B3 (`case let other:`) were not run; B1 only.
- Round 2's A-probes at `31e24403` (N3 GREEN before the fix) not re-run; the 1b re-review observed it.
- C2, C4, C5 not re-run (C1, C3, C6 stand for the family).
- The E probe under the old `commentFree` view not run.
- Full `swift test` not run (AppKit 2848 / Core 5085 and the one `ViewTestabilitySpike.swift:202` issue are round 2's figures).
- Probes ran once each; no repetition rate.
- The per-case attribution shim (a `swift` wrapper first on PATH) execs the real binary unchanged; it only tees stdout and copies the event stream after the run.
