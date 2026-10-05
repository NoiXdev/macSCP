# Hang Bounds and a Refused Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let four tests inherit the hang bound their suite already justifies, and stop `scripts/hang-hunt` from counting runs in which no test ran.

**Architecture:** Three independent tasks. Task 1 deletes four annotations in one test file. Task 2 adds a refusal gate to one shell script. Task 3 closes two rows of `docs/BACKLOG.md` and corrects one of them. Nothing in Core or the App changes, and no behaviour a user can see.

**Tech Stack:** Swift 6 strict, SwiftPM, Swift Testing; `bash` for the script.

**Spec:** `docs/superpowers/specs/2026-10-05-hang-bounds-and-a-refused-loop-design.md` (committed `df0ba1a4`). **Base:** `develop` at `770472ac`. **Worktree:** `/Users/noidee/macSCP/.claude/worktrees/candidate-listing-shows-what-it-hides`, branch of the same name.

## Global Constraints

- **Every written artifact is English** — code, comments, test names, commit messages, backlog rows.
- **Conventional Commits**, enforced by CI. Footer on every commit: `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
- **Build and test with** `swift test --build-system native`. The flag is required — the default build system fails on SwiftTerm's `Shaders.metal`. **This worktree's build is cold**; the first run pays for a full build.
- **Expect exactly one failure** in a whole-suite run: `ViewTestabilitySpike`, "Varying only isRegex leaves the pixels unchanged", `ViewTestabilitySpike.swift:202:9`, `Expectation failed: off == on`. Any other red is yours.
- **Never pipe a test run through `tail`.** It discards the `✘ Test … recorded an issue` line that names the failure and leaves a summary that reads like an unattributed failure. Redirect to a file and read it.
- **A number travels with the command that produced it**, the command runs **in the form it is committed**, and it is run **again after** the sentence is written.
- **Today is 2026-10-05.** Get it from `date`, not from memory: every dated sentence in the last piece of work on this branch was written one day in the future because nobody ran `date`, and the correction is `770472ac`.
- **Prefer the symbol to the line number**; a number that stays is dated.
- **A correction quotes what it withdraws, verbatim**, sliced from the file's own bytes. Binds `docs/BACKLOG.md` rows and the documents under `docs/superpowers/`.
- **Only a negative check can go stale in silence**, so a negative needs a positive beside it.
- **Never run `git checkout -- <file>`** — it restores from the index and takes uncommitted edits with it.
- **BSD `sed -i` fails silently on macOS** when its argument form is wrong, and anything measured afterwards measures the unchanged file. Assert each anchor occurs exactly once before writing and re-assert after, or use an editing tool.
- Do not push. Do not start Docker. Do not launch the app.

---

### Task 1: Four tests inherit the bound their suite justifies

**Files:**
- Modify: `Tests/macSCPCoreTests/ConnectionDiagnosticsJumpTests.swift` (four `@Test` annotations, and the suite's doc comment)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: nothing later tasks consume. Task 3 closes the row this answers.

- [ ] **Step 1: Measure what is there, before changing it**

Run each and record what it printed:

```
grep -n 'timeLimit(' Tests/macSCPCoreTests/ConnectionDiagnosticsJumpTests.swift
grep -c 'timeLimit(' Tests/macSCPCoreTests/ConnectionDiagnosticsJumpTests.swift
```

At `770472ac` the first prints five lines — the suite at `:28` with `.minutes(5)`, and `@Test(.timeLimit(.minutes(1)))` at `:289`, `:331`, `:726` and `:980` — and the second prints `5`. **Your run governs.** If the count is not 5, or the four are not where this says, stop and report rather than adjusting anything.

For each of the four, record the function name on the line below it. They should be `aCancelledWalkStillClosesTheJumpConnection`, `aJumpConnectionThatArrivesAfterItsDeadlineIsClosed`, `theTraceFromTheJumpIsRacedAgainstTheTraceBudget` and `anEarlierStepsOutputDoesNotTurnALaterNeverStartedStepIntoATimeout`.

- [ ] **Step 2: Confirm the one guard that could go red, by reading it**

> Fix round 1: this step's premise was wrong. The heading's "the one guard that could go red" and the closing "this task's safety rests on that reading" are withdrawn: the guard cannot go red on this file, because it never examines it (see Task 3, Step 3). The per-file reading below is correct and was confirmed; it just carries no weight here. What this task rests on is that the four cases still run and pass under the suite's bound, which applies to them because they sit directly in the struct with no nested `@Suite`.

`PollingGuardTests.everyCallerOfPollUntilDeclaresATimeLimit` requires a suite file that calls `pollUntil(` or a polling helper to carry `.timeLimit(`. Read it and establish for yourself whether it is a **per-file** or a per-test check — the plan's claim is per-file, because it filters `callers.filter { !$0.text.contains(".timeLimit(") }` over whole files, which the suite annotation alone satisfies.

If you read it as per-test, stop and report: this task's safety rests on that reading.

- [ ] **Step 3: Delete the four annotations**

Replace each of the four occurrences of

```swift
    @Test(.timeLimit(.minutes(1)))
```

with

```swift
    @Test
```

Change nothing else on those lines or the lines around them. All four are the same text, so an edit tool replacing all occurrences is fine — but assert the count is exactly 4 before and 0 after.

- [ ] **Step 4: Write the reason into the suite's doc comment**

The suite's doc comment already carries a paragraph that begins `/// **Hang bound, not a ceiling** (2026-09-28).` and ends `/// this suite depends on it.` Append to that paragraph:

```swift
///
/// **Every case here takes that bound from the suite** (2026-10-05). Four
/// cases used to carry `@Test(.timeLimit(.minutes(1)))` of their own,
/// tightening the suite's five minutes to one inside a suite whose five
/// exist for a starved runner — `ConnectionDiagnosticsTests`'
/// `aStepBeyondItsTimeoutIsSettledByItsDeadline` records CI run 35405472152
/// taking 87.253 s merely to REACH its assertion on the three-core runner.
/// All four race steps against a budget through `DetachedProbe`, the same
/// machinery that justification is about, so the suite's bound covers them
/// and a per-case one only risked a red with no defect behind it. Removing
/// the override rather than widening the number also means a later change
/// to the suite's bound carries these four with it.
```

- [ ] **Step 5: Verify the file's own invariants**

Run:

```
grep -c 'timeLimit(' Tests/macSCPCoreTests/ConnectionDiagnosticsJumpTests.swift
grep -c '@Test$' Tests/macSCPCoreTests/ConnectionDiagnosticsJumpTests.swift
```

Expected: the first prints `1` — the suite annotation. (Fix round 1 withdraws "which is what keeps `everyCallerOfPollUntilDeclaresATimeLimit` satisfied": that guard does not consider this file. And it printed `2`, not `1`, because the doc comment below quotes the removed override; the code carries exactly one.) Record what the second printed; it is not a target, only evidence that four plain `@Test` lines now exist where the annotations were.

- [ ] **Step 6: Run the guard, then the suite, then the whole suite**

```
swift test --build-system native --filter everyCallerOfPollUntilDeclaresATimeLimit
swift test --build-system native --filter ConnectionDiagnosticsJumpTests
swift test --build-system native
```

Expected: PASS, PASS, and PASS except the known `ViewTestabilitySpike` failure. **Note the filter spelling:** `ConnectionDiagnosticsJumpTests` is the TYPE name. The suite's display name is "ConnectionDiagnostics through a jump host" and `--filter` would match nothing against it — which is the trap Task 2 exists for. If any run reports `No matching test cases were run`, you have hit it; fix the filter, and say so in your report.

Record, for the second run, how many tests ran.

- [ ] **Step 7: Commit**

Stage only the test file:

```
test(core): four jump cases take their hang bound from the suite

Four @Test(.timeLimit(.minutes(1))) annotations tightened
ConnectionDiagnosticsJumpTests to one minute inside a suite that declares
five, and the five exist for a starved runner:
ConnectionDiagnosticsTests' aStepBeyondItsTimeoutIsSettledByItsDeadline
records CI run 35405472152 taking 87.253 s merely to reach its assertion on
the three-core runner. All four race steps against a budget through
DetachedProbe, the same machinery that justification is about, so the
suite's bound already covers them.

Removing the overrides rather than widening the numbers keeps the bound in
one place, so a later change to the suite carries these four with it.
everyCallerOfPollUntilDeclaresATimeLimit stays satisfied because it is a
per-file check and the suite annotation remains: grep -c 'timeLimit(' on
the file goes from 5 to 1.

No red first, and there is none to have: a wider hang bound prevents a
failure rather than producing one. A test that would go red against one
minute is a test that hangs, which is the defect the bound exists to catch.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

> Fix round 1: the message above is not what was committed. It was committed with "from 5 to 2" for "from 5 to 1", and amended again to withdraw "everyCallerOfPollUntilDeclaresATimeLimit stays satisfied because it is a per-file check and the suite annotation remains": that guard does not consider this file, and the count is 2 because the doc comment quotes the removed override.

---

### Task 2: `hang-hunt` refuses a run that tested nothing

**Files:**
- Modify: `scripts/hang-hunt` (the header's Env/outcome documentation, and the worker loop)
- Modify: `.gitignore` (one stale path in a comment)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: nothing later tasks consume. Task 3 closes the row this answers.

**Context you need about the script.** `scripts/hang-hunt` loops `swift test` `RUNS` times per worker and judges each run by one question only: did the process outlive `TIMEOUT`? A run in which no test ran therefore counts as a clean run. `swift test --filter` matches type and function names, never a suite's **display** name, so a filter spelling the display name matches nothing: SwiftPM prints `warning: No matching test cases were run`, exits 0, and the loop counts greens. `docs/BACKLOG.md` records a 40-run loop lost to exactly that. The sibling `scripts/mutation-probe` already reports this as its own outcome, `NO TESTS RAN`.

- [ ] **Step 1: Red first — show the script counting nothing**

`ProbeStartTests` declares `@Suite("A probe that never began", …)`, so its display name and its type name differ. Run, from the repository root:

```
FILTER='A probe that never began' RUNS=2 OUT=.hang-evidence-probe scripts/hang-hunt
```

Expected today: it prebuilds, then prints `w1: 2 runs, no hang` and exits 0 — having run **no test at all**. Quote that line verbatim; it is the red.

`OUT` is overridden so this probe cannot disturb a real evidence directory. **`.hang-evidence/` is git-ignored** (`.gitignore:13`, with the trailing slash — note that `git check-ignore .hang-evidence` without the slash reports nothing for a directory that does not exist yet, which is misleading). Your `OUT` is **not** ignored, so remove it with `rm -r` when done and read `git status --porcelain` back.

- [ ] **Step 2: Capture what the output actually looks like**

Before writing the gate, run once more with the log kept, and record **verbatim**:

- the exact warning line SwiftPM printed, and
- whether a `Test run with N tests` summary line appears at all in a run that matched nothing.

Do not assume either. The gate's two halves are written against what you observed, and if the summary line is absent from a zero-test run, say so — that is the fact the positive half rests on.

- [ ] **Step 3: Add the gate to the worker loop**

In `worker()`, the loop currently ends each non-hanging iteration with:

```bash
        wait "$pid" 2>/dev/null
        rm -f "$log"
    done
```

Replace that with:

```bash
        wait "$pid" 2>/dev/null

        # A run that tested NOTHING is its own outcome, distinct from green
        # and from hung — the same distinction scripts/mutation-probe draws
        # with its NO TESTS RAN line, and for the same reason: a harness that
        # only watches for failure reads "nothing ran" as "nothing wrong".
        # `--filter` matches TYPE and FUNCTION names, never a suite's DISPLAY
        # name, so a filter spelling the display name matches nothing and
        # SwiftPM exits 0. docs/BACKLOG.md records a 40-run loop lost to it.
        # Checked on the FIRST run only: a filter cannot start matching
        # halfway through a loop.
        if [ "$i" -eq 1 ]; then
            if grep -q 'No matching test cases were run' "$log"; then
                echo "w$id: REFUSED after run 1 — that run tested NOTHING."
                echo "w$id: 'swift test' printed 'No matching test cases were run' and exited 0."
                echo "w$id: FILTER='$FILTER' matched no type or function name."
                echo "w$id: --filter matches TYPE and FUNCTION names, never a suite's display name."
                echo "w$id: log kept at $log"
                return 1
            fi
            # The positive beside that negative, because a negative check that
            # greps one known string goes quiet the day SwiftPM rewords it:
            # the run must also SAY how many tests it ran.
            local ran
            ran=$(grep -oE 'Test run with [0-9]+ test' "$log" | head -1 | grep -oE '[0-9]+')
            if [ -z "$ran" ] || [ "$ran" -eq 0 ]; then
                echo "w$id: REFUSED after run 1 — no evidence that any test ran."
                echo "w$id: its output carries no 'Test run with N tests' line."
                echo "w$id: FILTER='$FILTER'"
                echo "w$id: log kept at $log"
                return 1
            fi
            echo "w$id: run 1 ran $ran test(s) — looping."
        fi

        rm -f "$log"
    done
```

The log is kept on both refusal paths and still deleted for a real run, so the evidence outlives the decision instead of being removed with it.

- [ ] **Step 4: Document the outcome in the header**

The header's `Env:` block ends with the `OUT` line. After that block, add:

```bash
#
# A run that tested NOTHING is refused, not counted (2026-10-05). After run 1
# the worker checks for `warning: No matching test cases were run` AND for a
# `Test run with N tests` line, and on either failure it stops, keeps that
# run's log and returns non-zero. `--filter` matches TYPE and FUNCTION names,
# never a suite's DISPLAY name, so `FILTER='A probe that never began'` matches
# nothing where `FILTER=ProbeStartTests` matches a suite; before this gate the
# first spelling printed "N runs, no hang" and exited 0. The companion rule is
# scripts/mutation-probe's NO TESTS RAN outcome.
```

- [ ] **Step 5: Green after — both directions**

```
FILTER='A probe that never began' RUNS=2 OUT=.hang-evidence-probe scripts/hang-hunt
FILTER=ProbeStartTests RUNS=1 OUT=.hang-evidence-probe scripts/hang-hunt
```

Expected: the first now refuses on run 1, names the filter, keeps the log, and exits non-zero. The second passes the gate, reports how many tests ran, and loops normally — this is the positive beside the negative at the level of the script's own behaviour, so the gate cannot be satisfied by refusing everything.

Record both outputs verbatim and both exit statuses. Then `rm -r .hang-evidence-probe` and read `git status --porcelain` back.

- [ ] **Step 6: Correct the stale path in `.gitignore`**

The comment above the `.hang-evidence/` entry cites `docs/superpowers/specs/2026-08-08-testsuite-haenger-untersuchung.md`. That file does not exist: the 2026-09-01 translation pass renamed it to `2026-08-08-testsuite-hang-investigation.md`, which is the name `CLAUDE.md` cites. Verify both with `ls` before changing anything, then correct the comment.

`.gitignore` is not a measurement record, so this owes no in-file quote; account for it in the commit message.

- [ ] **Step 7: Commit**

```
build(scripts): hang-hunt refuses a run in which no test ran

swift test --filter matches type and function names, never a suite's display
name, so a filter spelling the display name matches nothing: SwiftPM warns,
exits 0, and a loop that asks only "did this run hang?" counts it as
evidence. docs/BACKLOG.md records a 40-run loop lost to exactly that, and
scripts/mutation-probe already draws the distinction with its NO TESTS RAN
outcome. hang-hunt did not.

Red first, measured: FILTER='A probe that never began' RUNS=2 printed
"w1: 2 runs, no hang" and exited 0, having run no test. After the gate the
same invocation refuses on run 1, names the filter and exits non-zero, while
FILTER=ProbeStartTests still loops — the positive beside the negative at the
level of the script's own behaviour, so the gate cannot be satisfied by
refusing everything.

The gate has two halves for the same reason: the warning string is one
wording away from going quiet, so the run must also carry a "Test run with N
tests" line. Both refusal paths keep the log, which the loop otherwise
deletes, so the evidence outlives the decision.

Also corrects the path in .gitignore's comment beside the evidence
directory: it cited the German filename that the 2026-09-01 translation pass
renamed, and the file has been 2026-08-08-testsuite-hang-investigation.md
since.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

---

### Task 3: Close both rows, and correct the one that was wrong about itself

**Files:**
- Modify: `docs/BACKLOG.md` (rows 149 and 280, and one new row)

**Interfaces:**
- Consumes: Tasks 1 and 2 and their commits.
- Produces: nothing.

- [ ] **Step 1: Close row 280**

Find it by title — `` `--filter` with a suite DISPLAY NAME matches nothing, and "No matching test cases were run" reads as green ``. Add a `**Done 2026-10-05**` passage recording what closed it, with Task 2's commit, and these three things the row did not know:

- `scripts/mutation-probe` **already** had the gate, as its `NO TESTS RAN` outcome, so the gap was one script wide rather than general. Commit the command that shows it, pipe-free, with its figure.
- `scripts/hang-hunt` was the gap, and it **deleted the log** of every non-hanging run, so the warning was gone before anyone could read it.
- The gate has a positive half as well as the negative one, and why.

This closure withdraws nothing, so it owes no quote.

- [ ] **Step 2: Close row 149, and correct it**

Find it by title — `The new hang bounds are one minute where this project's three-core precedent is five`. Its closure must **correct two false claims the row makes about itself**, each quoting the withdrawn wording verbatim, sliced from the file's own bytes:

1. The title's framing. One minute is this project's **default**, not an anomaly. Commit the commands and their figures — at `770472ac` they were 79 files carrying at least one `.timeLimit(.minutes(1))`, 99 such annotations in all, against 8 files carrying `.minutes(5)`. **Re-derive all three yourself** and write what you measure.
2. The count. The row names one tightened case; there are **four**. Commit the per-file command and its figure.

Then record what was done: the four overrides removed rather than widened, `ProbeStartTests` untouched because it carries the default, and the five minutes being one case's justification — `aStepBeyondItsTimeoutIsSettledByItsDeadline`'s 87.253 s to *reach* its assertion — rather than a project precedent.

- [ ] **Step 3: Write one new row for the two findings this work does not fix**

Both came out of the design and neither is in scope. One row, in the "Security and testability" section, carrying both with their measurements:

- `PollingGuardTests.everyCallerOfPollUntilDeclaresATimeLimit` is weak in **two** ways. (Fix round 1 withdraws "and Task 1 relies on both readings, which is exactly why they are worth a row": Task 1 relies on neither, see below. The two weaknesses are real and are the row's subject.)

  It is a **per-file** check: `callers.filter { !$0.text.contains(".timeLimit(") }`. So a file satisfies it with one suite annotation while a `@Test` that needs its own bound has none — the guard cannot tell a file that bounds every case from one that bounds the suite and forgets a case.

  And it reads **raw text**, not a comment-blanked view, so a `.timeLimit(` inside a COMMENT satisfies it. `PollingGuardTests.sources()` returns `(path: String, text: String, code: String)` — the blanked view is already in the same tuple and the check uses the raw one, so the repair is one word. CLAUDE.md has a rule about exactly this ("Source-scanning guards read comments too"). **Do not record a live instance from Task 1.** Fix round 1 withdraws the sentence that stood here, "Record the live instance Task 1 created: after that task, `ConnectionDiagnosticsJumpTests.swift` carries `.timeLimit(` twice — once in the suite annotation and once inside the doc comment that quotes the removed override — so that file now satisfies the guard from a comment as well as from code." The two occurrences are real (counted 2026-10-05: raw text 2, comment-blanked view 1), but the guard never examines that file: it considers only suite files containing `pollUntil(` or calling a polling helper, and this file contains neither (`grep -c -F` of `pollUntil(`, `waitFor(`, `waitForFailure(` and `waitForRequests(` each prints 0). A reviewer removed the suite annotation and the comment's mention so the file carried no `timeLimit(` at all, and the guard still passed. So the weakness has no instance there, and the file does not "satisfy the guard" from anywhere, because it is not asked to.

  **The raw-text weakness is WATCHED, not measured once.** Fix round 2 withdraws the paragraph that stood here, "Whether any file IS an instance was measured, and none is", in three parts: its instruction, "State the weakness in the row as **latent: looked for, no instance found**, with that measurement, rather than as a live one"; its figures, "39 direct and 5 indirect callers, 44 in all, counted 2026-10-05 through a temporary probe test over the guard's own `sources()` and `pollingHelperFunctionNames(in:)`, removed again"; and its result, "Result: raw 44, code 44, comment-only none". The probe could not be re-run, so the property was recorded and not watched. It is now a real test, `PollingGuardTests.noCallerOfPollUntilReliesOnATimeLimitOnlyInAComment` (commit `dcddbd57`), run on every CI run: for every member of the caller set, if the raw text holds `.timeLimit(` the comment-blanked `code` view must hold it too, with positives beside it (the helper names and the caller set are non-empty, and at least one caller's blanked view holds `.timeLimit(`). Its failure message prints `callers=… direct=… indirect=…`, so **cite the test in the row and write no caller-set figure into prose**: the figures re-derive themselves. Run: `swift test --build-system native --filter noCallerOfPollUntilReliesOnATimeLimitOnlyInAComment`.

  Red first, measured on one plant repeated five times: an untracked file under `Tests/macSCPCoreTests/` holding only a comment with `@Suite`, `pollUntil(` and `.timeLimit(.minutes(1))`. On it the existing `everyCallerOfPollUntilDeclaresATimeLimit` passed 5 of 5 (the defect, demonstrated) and the new test failed 5 of 5, printing `callers=45 direct=40 indirect=5`. Say in the row what the new test does **not** fix: the existing check still reads raw text, so a comment still satisfies **it**. The new test detects the situation and does not repair the old check; whether to switch that filter to `code` is a separate decision nobody has taken.
- `scripts/hang-hunt` deletes the log of every non-hanging run. Task 2 keeps it on the refusal paths only; whether a passing run's log should survive is undecided, and a passing run's log is the only place a future warning would appear.

Mark it `Not started.` so the candidate listing can see it.

- [ ] **Step 4: Run every command you committed, from the committed bytes**

Extract each command from the file as committed — do not retype — and run it. Every one must run unrepaired and print the figure its row claims. A command inside a `docs/BACKLOG.md` table cell must carry **no pipe**: a pipe splits the cell, so use several `-e` patterns rather than one `-E` alternation.

Then run them **again** after the sentences are written, and predict any self-match rather than discovering it: a row that quotes a pattern becomes part of what that pattern counts.

- [ ] **Step 5: Confirm nothing else moved**

```
git diff --stat docs/BACKLOG.md
```

Read the diff. Exactly two existing rows change, plus one row added. Confirm the added row sits **after** the last existing table row so no row number the file cites of itself moves, and confirm each touched row still carries exactly three `|`.

- [ ] **Step 6: Commit**

```
docs(backlog): two rows closed, and one that was wrong about itself

Row 280 is closed by the gate in scripts/hang-hunt, and its closure records
three things the row did not know: mutation-probe already had that gate as
its NO TESTS RAN outcome, so the gap was one script wide; hang-hunt deleted
the log of every non-hanging run, so the warning was gone before anyone
could read it; and the gate needs a positive half because a negative that
greps one known string goes quiet the day the string changes.

Row 149 is closed by removing four annotations, and corrected in place with
both withdrawn claims quoted. One minute is this project's DEFAULT, not an
anomaly — 99 annotations across 79 files against 8 files at five minutes —
so ProbeStartTests, one of the two sites the row named, wanted no change.
And four @Test overrides tightened the five-minute suite where the row named
one. The five minutes are also one case's justification rather than a
project precedent.

One new row carries the two findings this work does not fix: that
everyCallerOfPollUntilDeclaresATimeLimit is a per-file check, which
cannot tell a file that bounds every case from one that
bounds the suite and forgets a case, and which never examined the file
this work edited (Fix round 1 withdraws "which Task 1
relies on"), the second weakness (raw text) now being watched by
PollingGuardTests.noCallerOfPollUntilReliesOnATimeLimitOnlyInAComment
without being repaired; and that hang-hunt still deletes a
passing run's log, which is the only place a future warning would appear.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

---

## Notes for the coordinator

- **The build in this worktree is cold.** Task 1's first `swift test` pays for a full build; budget for it rather than reading a long silence as a hang.
- **Task 2 needs no Swift build of its own** beyond what `hang-hunt` prebuilds, and it writes only into an `OUT` directory it then removes. It starts no Docker rig and needs none.
- **Row 151** — the three accepting host-key deciders — is deliberately out of this plan: it needs the rig, which may only be started from the main checkout.
- **Nothing here is user-visible**, so no noix-docs work is owed.
- **Task 1 has no red first and the plan says so.** A reviewer should check that the claim is argued rather than merely asserted, not ask for a fixture that cannot exist.
