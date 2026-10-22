# Task 12, fix round 1b -- re-review

Scope `e298c50f..31e24403` (five commits). Worktree `/Users/noidee/macSCP/.claude/worktrees/diff-view`, tree clean at the start (`git status --porcelain` printed nothing). Written section by section as each check finishes.

## Check 9 -- the exhaustive switch (static)

Commands (scratch files in the session scratchpad):
- Kind cases: `sed -n 46,110p Sources/macSCPCore/Sessions/AuditEvent.swift`, filtered with `/usr/bin/grep -o -e '^ *case [a-zA-Z]*$'`, then `sort -u`: **19** names (the enum's `upload`/`download` at lines ~127-128 are another enum, outside the range).
- Arm names: the body of `static func segment(of`, comments stripped, `return ...` tokens removed, every `.name` token sorted: 20 tokens = the 19 kinds + the `Kind` of `AuditEvent.Kind`; `uniq -d` printed nothing (no kind named twice); `diff` against the 19 names showed only that extra `Kind`.
- Result: every one of the 19 kinds is named exactly once in `segment(of:)`.
- Old behaviour, from `git show e298c50f:Sources/MacSCPAppKit/AuditLogSheet.swift` (`matchesFilter`): transfers = {transferFinished, transferFailed, transferCancelled, editUpload, crossSessionTransfer}; fileOps = {rename, delete, permissions, newFolder, newFile}; terminal = {snippetExecuted}; connection = {connected, disconnected, connectFailed}. New arms list exactly those plus, under fileOps only, {bucketCreated, versioningChanged, corsChanged, objectLockChanged}. No other kind's segment changed.
- `plaintextConfirmed`: named in none of the four old inner switches (each ended in `default: return false`), so it was unsegmented before; it is `return nil` now. Confirmed.
- `.all`/`.errors` arms of the old `matchesFilter` are unchanged in `Filter.includes` (`true`, `event.isError`).

## Check 6 -- every withdrawal quotes verbatim

Old wording recovered with `git show e298c50f:<path>` (the parent of the five commits) into the scratchpad, then a script (`python3 -I quotes.py`) strips the `//`/`///` markers from the OLD file, collapses whitespace (so a rewrap across comment lines is ignored) and asks whether each quote, copied from the new comment, is a substring. Result: FOUND for all of:

- `SessionTab.swift`: "an ad-hoc one, which has no audit trail to write it into (see `attachAuditRecorder`'s own doc comment)"
- `TabTeardown.swift`: "only present for a stored session (`attachAuditRecorder` never runs for an ad-hoc connect), so this is a no-op otherwise"
- `RemoteBrowserViewModel.swift`: "default nil (no logging — matches ad-hoc/unstored sessions)" and "wires this to an `AuditRecorder.recordAction` closure for stored sessions" (the em dash is the same character)
- `TransferQueueViewModel.swift`: "default nil (no logging — matches ad-hoc/unstored sessions)" and "wires this to an `AuditRecorder.recordTransfer` closure for stored sessions"
- `ContentView.swift`: "every stored-session tab's `AuditRecorder`"
- `CreateBucketSheet.swift`: `if case .failed(let sentence, _) = outcome`

Each of the five corrected sites withdrew the claim(s) it had and the quotes cover them: I read each old comment and each new one in the diff and found no withdrawn sentence left unquoted (e.g. the `SessionTab` old text also said the clause was "(see `attachAuditRecorder`'s own doc comment)"; that is inside the quote).

One imprecision, not a lost word: the test comment in `BucketSettingsAuditTests.swift` says "(Withdrawn wording, verbatim: `if case .failed(let sentence, _) = outcome { recorder?.recordBucketCreated(...) }`.)". The old code was three lines (`if case ... {` / `recorder?.recordBucketCreated(bucket: bucket, protection: choice, failure: sentence)` / `}`), so the quote is joined onto one line and the call's arguments are elided with `...` while labelled verbatim. The first half is the real expression and is verbatim; the label over-claims for the rest. Nothing is lost (the old text is in git), so I class it a nit.

Facts the new comments assert, re-checked rather than read from the report:
- `startSession` (`ContentView.swift:1987`) calls `attachAuditRecorder` at `:2157` with `AdHocAudit.logSessionID(storedID: storedSession?.id)`; `AdHocAudit.logSessionID` exists (`Sources/macSCPCore/Sessions/AdHocAudit.swift:24`). True.
- `attachAuditRecorder`'s doc comment (`ContentView+Lifecycle.swift:392-395`) now says "called from `startSession` for every connect, stored or not". True, so "The doc comment the withdrawn clause cited had been rewritten to say so" is true.
- `auditRecorder = nil` appears in source at `ContentView+Detail.swift:71` (sidebar delete) and `TabTeardown.swift:209` (after teardown); the property is never set to nil elsewhere (`grep -rn auditRecorder Sources`, comment lines excluded). So "absent only when the stored session was deleted under the open tab" is true for a tab that has connected; a tab that never connected (or whose connect failed before `startSession` reached the attach) also has no recorder at teardown, which the new `TabTeardown` comment's "present for every connect" scoping covers but "absent only when" does not say. Cosmetic.

## Checks 7 and 8 -- the sweep's figures

Sweep A script extracted from the report with `awk '/^#!\/usr\/bin\/env bash$/{f=1} f&&/^```$/{exit} f'` (10 lines, not retyped or repaired). Revisions exported with `git archive -o <x>.tar <rev> Sources Tests` (rev = `c355dd63^`, `e298c50f`, `31e24403`), each untarred into its own empty directory, then `bash sweepA.sh <dir> > out; wc -l < out`.

| tree | claimed | observed (`wc -l` of the script's output = hit lines) |
|---|---|---|
| `c355dd63^` | 51 | **51** |
| `e298c50f` | 64 | **64** |
| `31e24403` | 74 | **74** |

All three reproduce, and the script runs in the form it is committed in the report (it needs no repair; it is not in a table cell). The count is hit LINES (one line printed once however many times it matches), as the report says.

Check 8, the positive check. In the `c355dd63^` output, each of the seven sites the report names as false is a hit line (`/usr/bin/grep -n -e <phrase> outA1.txt`):
`ContentView+Lifecycle.swift:395` "Never called for an ad-hoc connect"; `SessionTab.swift:252` "never for an ad-hoc connect"; `SessionTab.swift:144` "has no audit trail to write it into"; `TabTeardown.swift:194` "never runs for an ad-hoc"; `TeardownStage.swift:117` "is nil for an ad-hoc connect"; `RemoteBrowserViewModel.swift:100` and `TransferQueueViewModel.swift:381` ("ad-hoc/unstored sessions)"). The claim holds: the sweep finds what was already known.

I also read all 74 hit lines at `31e24403` for a live claim. The remaining false-claim hit is `TeardownStage.swift:117` (deliberately left, maintainer decision). The others are corrections quoting what they withdraw, or true statements (M31 text, `ContentView.swift:744` "an ad-hoc connect has one", `SessionTab.swift:257`). I found no further live stale claim.

Sweep B: the report DESCRIBES `sweepB.sh` ("the same shape, regex `stored|not saved|never saved|unstored|saved session`, restricted to `//` lines", 3-line window, "49 at `e298c50f`, 52 at `HEAD`") but does not carry it verbatim. I did not reconstruct it; its figures 49 and 52 are NOT reproduced. That is a gap in the record under the project's "a number travels with the command that produced it" rule: sweep B's two figures and the one false claim it found (`ContentView.auditStore`) cannot be re-run from the report as it stands. (The claim itself, `ContentView.auditStore`, is a real site and is corrected in the diff, so the substantive outcome is not in doubt; the figures are.)

## Check 5 -- nothing that must not leak reaches a failure message (static)

Read from the diff, not run:
- `AuditLogFilterTests`: every `#expect` message or expression carries only `AuditEvent.Kind` / `Filter` values and counts. The two interpolations are `"\(kind) is in more than one kind segment"` and `"kinds the switch does not name: \(unnamed)"`, both enum case names. Events are built with `detail: "x"`. No endpoint, key, credential, token or bucket name appears in the file.
- `createRecordsItsRefusalWithoutAnOutcomeGate`: the expressions are `recordingCalls == 2`, `!hasGate` (the `Bool` is computed first, as CLAUDE.md prescribes) and `#require(lines.firstIndex { ... })`; the source text `#expect` would print is a type name and a call name. The source scanned is `CreateBucketSheet.swift`, which a failure does not print.
- `Refusal` (new, `private struct`, two stored properties `sentence`, `bucketMayExist`): conforms to nothing, so it has no `description` that could print. Every `Refusal(sentence:...)` takes the same value the old `.failed(sentence:...)` took (`Self.refusalSentence(for:)`, `existsIncompletelyLine(bucket:)`, `mayExistLine.text`), unchanged by the diff; `refusalSentence`'s own doc says the error is never quoted (its text sits just below the diff hunk). The new line `recorder?.recordBucketCreated(..., failure: refusal.sentence)` records the same string the old `failure: sentence` did. So the audit `detail` path is unchanged: `bucket` (the name the user typed) and a fixed sentence. A bucket name is user input but is not a secret in this app's model.
- Not run: I did not execute an audit-line test with a planted secret endpoint; existing `aRefusalsOwnWordsNeverReachTheTrail(operation:)` already covers that and is exercised by P5-like plants in the round's own report; I did not re-run it for this section apart from it being inside the `BucketSettingsAuditTests` runs below.

## Check 2 -- Important 1's governing plants (in progress; filled in below as probes finish)

Runner: `scripts/mutation-probe --filter 'ObjectLock|Audit' --apply "bash <plant>.sh"` against the committed tree `31e24403` (`git rev-parse HEAD`, `git status --porcelain` empty before starting). The plants are the review's N3 and N4 verbatim (the `perl -0pi -e` substitutions described in `task-12-review.md` Important 1, on the `failure: applyFailure` arm of `ObjectLockSheet.swift`), kept as files in the session scratchpad so the quoting cannot drift.

Control observed: **253 tests, 0 pre-existing failures** (not 245). The 8 extra are exactly this round's 8 new test functions that match `Audit` (7 in `AuditLogFilterTests`, 1 `createRecordsItsRefusalWithoutAnOutcomeGate` in `BucketSettingsAuditTests`); `245 + 8 = 253`.

- (a) N3, refused retention forced to `.governance`: **`RESULT: GREEN — 253 test(s) ran and NONE of them noticed the plant.`** (log: scratchpad `log-pa.txt`)
- (b) N4, refused legal hold inverted (`!wanted`): **`RESULT: RED — 253 test(s) ran`**, caught by `BucketSettingsAuditTests/aRefusedOperationRecordsTheFailureAndNotASuccess(operation:)` (log `log-pb.txt`). Control 253, 0 pre-existing failures.

Reading of (a): N3 is GREEN at `31e24403` because the plant is *equal* to the attempt the table makes. The `set a file's retention` row builds `ObjectLockModel(focus: .retention, bucketHasLock: true)` with no mode set, and `ObjectLockModel.mode` defaults to `.governance` (`ObjectLockSheet.swift:263`); the row's `detailPrefix` is "retention of b1/reports/q3.pdf set to GOVERNANCE until ". Forcing the refused line to GOVERNANCE therefore produces the identical text. No test in `Tests/macSCPAppKitTests` refuses a COMPLIANCE retention: the only COMPLIANCE runs (`aRunTheSheetRefusesBeforeAnyRequestRecordsNothing`, `anObjectLockLineNamesWhichOfTheThreeOperationsItWas`) either never reach the store or succeed. So the review's "smallest fix" (reuse `detailPrefix` on the refusal path) closes N4 and the other five rows, and cannot close N3 as written: N3 is the one defect in Important 1 that names COMPLIANCE, and nothing drives a refused COMPLIANCE attempt. The commit message of `e298c50f` records only the pre-fix GREENs for N3 and N4, never a post-fix RED for either. This is not caused by the five commits under review (none touches `ObjectLockSheet.swift`, and the refusal test body is unchanged by them: the only addition to `BucketSettingsAuditTests.swift` is the 29-line `createRecordsItsRefusalWithoutAnOutcomeGate` block), so it is a hole in `e298c50f`'s fix that the carried-over check exposes, not a regression of this round. I did not run the plants at `e298c50f` itself; the unchanged-by-the-five-commits argument above is by reading the diff stat and the diff, not by probe.

## Check 3 -- the round's own probes, re-run (against the committed tree `31e24403`)

Same mechanism as above: `scripts/mutation-probe --filter <f> --apply "bash <plant>.sh"`, each plant the report's `perl -0pi -e` string put in a file unchanged (with `$1`/`$2` literal in the file, so no shell-escaping difference from the report's `\$1`). Every run printed its own control first; a 'PLANT CHANGED NOTHING' would have been its own RESULT, none appeared, and each log shows a one-file diffstat.

| probe | filter | control | RESULT | caught by |
|---|---|---|---|---|
| P3 against `31e24403` (strengthened guard) | `AuditLogFilterTests` | 7 tests, 0 pre-existing failures | **RED** | `theClassificationHasNoDefaultArm()` only |
| P4 | `BucketSettingsAuditTests` | 11 tests, 0 pre-existing failures | **RED** | `createRecordsItsRefusalWithoutAnOutcomeGate()` only |
| P3 against `74bb1b55` (the weaker guard) | see "P3 green half" below | | | |

P3 and P4 agree with the report's table (P4: "caught ONLY by the guard"). P1, P2 and P5 were not re-run (the brief asked for P3 and P4 at minimum).

### P3 green half (against `74bb1b55`)

Method: `git checkout --detach 74bb1b55` in this worktree (a branch switch, tree clean before and after), then the same probe, then `git checkout s3-bucket-settings`. Afterwards `git rev-parse HEAD` printed `31e24403083e6abb6279f1a0cc96c50f8b5573a8`, `git branch --show-current` printed `s3-bucket-settings`, `git status --porcelain` printed nothing.

`scripts/mutation-probe --filter AuditLogFilterTests --apply "bash p3.sh"` at `74bb1b55`: control 7 tests, 0 pre-existing failures; **`RESULT: GREEN — 7 test(s) ran and NONE of them noticed the plant.`** (`swift test` exited 0; one-file diffstat shown.) So the report's green half reproduces, and the strengthened guard in `31e24403` was needed. Both halves agree with the report's table.

## Check 4 -- fresh plants against the two new guards (all at `31e24403`)

None of these is in the author's battery. Each ran through `scripts/mutation-probe` with the plant file kept unedited, control 0 pre-existing failures, a one-file diffstat in the log, and `swift test` exiting 0 (GREEN means the plant compiled and the filtered tests ran).

### `theClassificationHasNoDefaultArm()` / the segment filter

| plant | what it does | filter | control | RESULT |
|---|---|---|---|---|
| H1 | appends `case _: return nil` AFTER the `plaintextConfirmed` arm, every kind still named | `AuditLogFilterTests` | 7 | **GREEN** |
| H2 | `matchesFilter` (the sheet's only caller of the filter) returns `true` instead of `filter.includes(event)` | `Audit` | 101 | **GREEN** |
| H6 | `Filter.includes`: `.errors` arm returns `true` instead of `event.isError` | `Audit` | 101 | **GREEN** |

- **H1 is a hole in the guard's stated purpose.** The guard's wildcard test is "every kind is named in the body". A wildcard placed after all current kinds are named satisfies it, and from then on a new `AuditEvent.Kind` falls into `_` and compiles, which is precisely what the exhaustive switch exists to prevent. The report concedes this ("a compiler warning, not a hole the guard owns"); the project does not build with warnings as errors (`grep -n -e warnings -e unsafeFlags -e treatAllWarnings Package.swift` printed nothing), so the warning stops nothing. Fix shape: the guard should also refuse `case _`/`case let`/`default` as an arm label, not only check that kinds are named (or compare the number of arm labels with `allCases.count`).
- **H2: the sheet's own use of the classification is covered by no test.** The new tests exercise `Filter.includes`; `AuditLogSortWiringGuardTests` only requires that the text `matchesFilter(` appear in `filteredEvents`. A `matchesFilter` that ignores the segment passes 101 tests. The report concedes "tested at `Filter.includes`, not by driving the sheet"; this probe shows what that costs: the picker would do nothing. Nothing in the five commits makes this worse than before for the old inline switch (it was equally untested), but the forwarder is new code and was the natural place to pin.
- **H6:** the `.errors` arm moved into `includes` with the refactor and is pinned by one positive case (a failed lock write is listed). Nothing asserts a non-error is NOT listed under Errors. Same remark: moved code, not new behaviour.
- The guard reads `SourceCorpus.commentFree(of:)` (comments blanked, string literals KEPT), not `SourceCorpus.code(of:)`. A kind name inside a string literal in the body would satisfy the "named" half. Not planted; I note it because the brief asked which view each guard reads. The path `Sources/MacSCPAppKit/AuditLogSheet.swift`, `"func segment(of"` and `"switch kind"` are spelled literals; a rename of the function fails the `#require` loudly (the positive check), so that is a loud rename-wait, not a silent one.
- Not planted, reasoned only: the same `default:` regression in `Filter.includes` (outside the guard's scanned span, which is only `segment(of:)`); behavioural tests would catch a change of classification but not a re-introduced catch-all that preserves today's answers.

### `createRecordsItsRefusalWithoutAnOutcomeGate()`

| plant | what it does | filter | control | RESULT |
|---|---|---|---|---|
| H3 | `guard case .failed = outcome else { return }` immediately before the refusal record | `BucketSettingsAuditTests` | 11 | **GREEN** |
| H4 | `if failureSentence != nil { <record> }` | same | 11 | **GREEN** |
| H5 | `switch outcome { case .failed: <record> default: break }` | same | 11 | **GREEN** |

All three are the outcome gate Ruling 20 removed, spelled other than `if case`. The guard's negative half is the literal substring `"if case"` (the round's own P4 plants exactly that spelling), so any other conditional passes. Each plant is behaviourally invisible (`outcome` is always `.failed` there), as the round's report says of the original gate, so the guard is the only possible catcher and it catches one spelling of three tried. Fix shape: assert on the property rather than a keyword, e.g. that the text between `catch {` and the second `recordBucketCreated(` contains no read of `outcome`/`failureSentence` and no `if`/`guard`/`switch`, or that the call sits at the `catch` body's own indent level. The positive half (`recordingCalls == 2`) is fine and is beside the negative, as the project rule requires. `Self.code(...)` is `SourceCorpus.code(of:)`, so a comment cannot satisfy it.

## Verdicts, written up

- **Minor 1 (Ruling 19):** the switch is exhaustive over 19 kinds with each named once, nothing else moved, `plaintextConfirmed` was and is unsegmented (check 9). Closed. The structural guard has two holes (H1; H2/H6 for the surrounding code) listed above.
- **Minor 2 (Ruling 20):** the diff shows `create` recording unconditionally from the bare `catch` and `failure(for:)` returning the private `Refusal`; the `if case .failed` gate is gone. Closed. Its guard catches one spelling of the gate of four tried (H3-H5 hole).
- **Important 2:** the five comments carry the withdrawn wording verbatim; the sweep figures reproduce; the only remaining live false claim among the 74 hits is `TeardownStage.swift:117`, left on purpose. Closed (modulo that deliberate site).
- **Important 1 (carried over, not in scope of the five commits):** the N4 half survives, the N3 half does not hold (see check 2). Not closed for N3.

## Not verified

- I did not run the full `swift test`; only the filtered runs the probes performed (`ObjectLock|Audit` 253, `AuditLogFilterTests` 7, `BucketSettingsAuditTests` 11, `Audit` 101, each as its own control). The report's full-suite figures (Core 5085, AppKit 2847 with the one known `ViewTestabilitySpike.swift:202` issue) are not re-measured.
- Plants (a) and (b) were not run at `e298c50f`; that N3 was never red is inferred from the five commits not touching `ObjectLockSheet.swift` or the refusal test body (diff stat and diff read), not from a run there.
- P1, P2 and P5 of the round's table not re-run.
- Sweep B (49 / 52 hit lines, the `ContentView.auditStore` find) not reproduced: the report carries no verbatim script for it. I did not reconstruct one.
- The 74 pass-A hit lines were read for live stale claims; claims phrased with neither an ad-hoc nor a stored word (the report's own stated blind spot) were not searched for by me either. `docs/` and `.superpowers/` not scanned.
- `commentFree` vs `code` blanking behaviour (comment nested in a multi-line string) not measured.
- The File Ops segment was not seen in the GUI (no app launched); only `Filter.includes`.
- Each probe ran once; sensitivity is one run per plant, not a repetition rate.
- The brief's statement that `ConnectionHistory.rows` demands the same exhaustiveness was taken as given.
