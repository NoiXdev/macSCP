# Task 12, fix round 3 -- re-review

Tree: `83ffa6615dee1327b96eb0eeee0e594390de4c6d`. `git status --porcelain -uall | wc -l` printed 0 before the
first probe and 0 after the last. No `--build-system` flag. Nothing was written to the worktree while a probe ran.
Probe scripts and outputs live in my scratchpad, outside the worktree.

## Check 1 -- do the report's probe commands run, extracted and unrepaired?

Method: a script (not retyping) pulled every fenced block that follows a `**ID** --` heading in
`task-12-fix-3-report.md` and starts with `scripts/mutation-probe`: 19 blocks, one file each. Proof that the
extraction is the report's own text: for the nine commands run, `/usr/bin/grep -F -x -c -f <extracted file>
task-12-fix-3-report.md` printed 1 for each of B2 B3 S1 S0 C6 D1 R22 E N3 (whole-line, fixed-string match).
Each was run unedited as `zsh -c "$(cat <file>)"` from the repository root (zsh = the maintainer's shell), one at
a time, against the clean committed tree. Counts are `testEnded` events as the harness reports them.

| id | ran as copied | exit | control | verdict observed | catcher | matches report |
|---|---|---|---|---|---|---|
| B2 (`default:`) | yes | 0 | 17, 0 pre-existing | RED | `AuditLogFilterTests/everyArmOfTheClassificationNamesAKindAndTogetherTheyAreAllOfThem()` | yes |
| B3 (`case let other:`) | yes | 0 | 17, 0 | RED | same | yes |
| S1 (call only in a comment) | yes | 0 | 17, 0 | RED | `AuditLogSortWiringGuardTests/theSortIsAppliedToTheFilterResult()` | yes |
| S0 (real call + comment) | yes | 0 | 17, 0 | GREEN | - | yes |
| C6 (refusal record deleted) | yes | 0 | 11, 0 | RED | `aRefusalsOwnWordsNeverReachTheTrail(operation:)`, `aRefusedOperationRecordsTheFailureAndNotASuccess(operation:)`, `createMakesExactlyTwoRecordingCalls()` | yes |
| D1 (`.errors` returns true) | yes | 0 | 17, 0 | RED | `AuditLogFilterTests/theErrorsSegmentListsAFailedEventAndNotASuccessfulOne(kind:)` | yes |
| R22 (`true && predicate`) | yes | 0 | 17, 0 | RED | `theSortIsAppliedToTheFilterResult()` | yes |
| E (harmless string literal) | yes | 0 | 17, 0 | GREEN | - | yes |
| N3 (retention forced to GOVERNANCE) | yes | 0 | 254, 0 | RED | `aRefusedOperationRecordsTheFailureAndNotASuccess(operation:)` | yes |

Nine of nineteen run; none needed a repair of any kind (no missing operand, no quoting fix). None came back
`PLANT CHANGED NOTHING`, `PLANT FAILED`, `BUILD FAILED` or `RUN INCOMPLETE`. The other ten (B1, N3M, C1 to C5, H1, H2,
S2) were extracted the same way and not run: they have the identical shape, and the brief's bar was six.

The corrected cells in `task-12-fix-2-report.md`: there are none. Its probe tables are still the non-runnable cells
(no file operand, B2/B3 prose, `$1` unescaped); round 3 left them and appended a "Corrected in fix round 3"
section saying they do not run and pointing to round 3's blocks. I did not try to run the round-2 cells: the
section says in so many words that they are not commands, and a reader following the pointer lands on blocks that
do run. Noted, not a defect.

VERDICT: PASS (9 of 9 run unrepaired, 9 of 9 verdicts match).

## Check 2 -- Finding B's governing red, independently

Commands: S1 and S0 as in the table above (the report's own blocks, unedited).
S1: `control: 17 test(s) ran, 0 pre-existing failures`; `RESULT: RED -- 17 test(s) ran`, caught by
`AuditLogSortWiringGuardTests/theSortIsAppliedToTheFilterResult()` and by nothing else.
S0: same control; `RESULT: GREEN -- 17 test(s) ran and NONE of them noticed the plant.`
R22 (the pre-existing governing plant `true && predicate`) is RED through the same test.
Also read: `0ac31adf` changes only the new `sheetCode()` helper and the one call in
`theSortIsAppliedToTheFilterResult` (`git diff 6332cc69 83ffa661 --numstat` -> 11 added / 1 removed lines in
`AuditLogSortWiringGuardTests.swift`).

VERDICT: PASS

## Check 3 -- the deletion left the surviving half standing

C6, as in the table: RED, with `createMakesExactlyTwoRecordingCalls()` among the three catchers (control 11, 0
pre-existing). The surviving positive half still catches a deleted record. I read the diff of `83ffa661`: the test
keeps `func create(via` to the first `    }` and counts `recordBucketCreated(` lines == 2; the rest of the removed body
was the branching scan only. I did not re-run C1 to C5 (not asked); their GREEN is Ruling 26's cost.

VERDICT: PASS

## Check 4 -- the bounded scope held

`swift test --filter AuditLogSortWiringGuardTests`, exit 0: `Test run with 9 tests in 1 suite passed`, including
`theCellsDrawTheTextTheSortKeysOn()` and `eachColumnCarriesItsOwnFieldsComparator()`.
Raw view check: `/usr/bin/grep -n -e 'sheetSource()' -e 'sheetCode()' Tests/macSCPAppKitTests/AuditLogSortWiringGuardTests.swift`
shows the helper declarations plus 8 call lines to `sheetSource()` (lines 165, 188, 198, 215, 238, 305, 332, 378) and
1 to `sheetCode()` (line 277, inside `theSortIsAppliedToTheFilterResult`). Lines counted, not occurrences; no line
holds two. Round 3's diff to this file is the helper plus that one call; the siblings are untouched.

VERDICT: PASS

## Check 5 -- the two corrections

5a. `theTableCoversEveryNewKind`. Old wording recovered with
`git show 3b4b9b98^:Tests/macSCPAppKitTests/BucketSettingsAuditTests.swift` and
`git show 83ffa661:Tests/macSCPAppKitTests/BucketSettingsAuditTests.swift`; both comment blocks flattened (leading
`//` and wrap whitespace removed, joined with single spaces) and compared by script. The old sentence,
"Six rows for the five apply methods (`ObjectLockModel.run` serves the retention and the legal hold). Pinned
because a duplicated row would pass the two checks above while the parameterised tests ran a bogus case as a seventh
operation", is a substring of the new comment's quote: `True`. It is word for word, modulo the original's line
wrapping and its final period (outside the quote). The report's and the commit message's shorter quotes are also
substrings of it. PASS.

5b. The fix-2 note. It exists ("## Corrected in fix round 3" at the end of `task-12-fix-2-report.md`) and does not
erase anything: the original sentence "All caught by `createRecordsItsRefusalWithoutBranching()`" is still at line
88 (`grep -F -o -n` found it there). Two quotation defects, both minor:
 (i) The note quotes the withdrawn claim as "RED, caught by `createRecordsItsRefusalWithoutBranching()`". That
 string is not in the round-2 report anywhere else: `' '.join(text.split()).count('RED, caught by')` is 1 and that one
 occurrence is the note itself. The original said "RED" in the table cell and, in a separate sentence, "All caught by
 `createRecordsItsRefusalWithoutBranching()`." The note's quote is a splice of the two, in quotation marks. The
 verbatim quote IS in round 3's report ("All caught by `createRecordsItsRefusalWithoutBranching()`."), so the record
 is complete, but the note in the file it annotates does not meet "verbatim".
 (ii) In round 3's Finding C intro, the second quote of round 2, "`(file ...)` in the column header", carries an
 ellipsis: the round-2 header reads "`--apply` (file `Sources/MacSCPAppKit/AuditLogSheet.swift`)". A description,
 not a quote. The first quote there ("In the `--apply` strings below `$1` is written `\$1` inside the double-quoted
 argument.") is verbatim.

VERDICT: 5a PASS; 5b PASS on substance (exists, nothing erased, verbatim quote present in the round-3 report), with
the two quotation defects above.

## New defects / concerns

1. Minor (CLAUDE.md "Comments that describe other code", rule 2, a number in a comment): the rewritten doc comment
 on `createMakesExactlyTwoRecordingCalls` (line 420 of `BucketSettingsAuditTests.swift`, a `+` line in `83ffa661`) says
 "like the other four recording sites". The same phrase sits in `Sources/MacSCPAppKit/CreateBucketSheet.swift:282`
 (`/usr/bin/grep -rn 'recording sites' Tests Sources`, 2 lines). `/usr/bin/grep -rn -e 'recorder?\.record[A-Za-z]*('
 Sources/MacSCPAppKit` lists, outside `create`, refusal records in `BucketVersioningSheet`, `BucketCORSSheet`,
 `BucketObjectLockSheet` and two in `ObjectLockSheet` (retention, legal hold): five refusal sites in four sheets.
 "Four" is right by sheet and wrong by site; the fix-2 report itself counts "five apply methods". I did not trace
 where the number originated (it is in a pre-existing Sources comment), only that the test's comment was re-written
 in this round carrying it. The sentence is ambiguous either way.
2. Minor: the deleted test's doc comment held a "Withdrawn wording, verbatim:" quote of the old `if case .failed(let
 sentence, _) = outcome { ... }` gate. It goes with the deletion; the commit message and the fix-3 report do not
 repeat it. It stays recoverable in `git show 6332cc69` and `git log -S`, so nothing is lost, but the project's
 measurement-record rule would put it in the report. I'd call it optional.
3. Observation, not a defect: round 3's "Verification" paragraph and the claim "every control said 0 pre-existing
 failures" match what I saw (11, 17, 254).

## Not verified

- The ten extracted commands I did not run (B1, N3M, C1 to C5, H1, H2, S2) and therefore their verdicts; C1 to C5
 in particular, so the "GREEN now" claim of the report for them is not independently re-measured here.
- The full `swift test` result in the report (Core 5085, AppKit 2848 with the one known `ViewTestabilitySpike.swift:202` issue).
- The origin of the "four" in comment concern 1.
- Whether the round-2 report's remaining non-runnable cells are acceptable to the coordinator; I only recorded that they are
 still in place and annotated.
