# Hang bounds, and a loop that refuses to count nothing — design

**Date:** 2026-10-05. **Base:** `develop` at `770472ac`.

Two rows of `docs/BACKLOG.md`, both named by that file's own
"If you don't know where to start" section: row 149 (hang bounds) and row 280
(`--filter` against a suite display name). Row 151, the third candidate, is
**out of scope**: it needs the Docker rig, which may only be started from the
main checkout, and `docs/BACKLOG.md` carries its own open row saying probes
and a shared checkout do not mix.

Neither change is user-visible, so no user documentation is owed.

## What was measured before designing, and what it overturned

Everything below was re-run at `770472ac` on 2026-10-05. Two measurements
killed the framing this design started from — including the framing of a
question already put to the maintainer, which had to be withdrawn and asked
again.

**Row 149's title is wrong in two ways, and the row is to be corrected when
it is closed.** It reads "The new hang bounds are one minute where this
project's three-core precedent is five".

1. **One minute is this project's default, not an anomaly.** Counted
   2026-10-05:

   ```
   grep -rc 'timeLimit(.minutes(1))' Tests/ | grep -v ':0' | wc -l
   grep -ro 'timeLimit(.minutes(1))' Tests/ | wc -l
   grep -rc 'timeLimit(.minutes(5))' Tests/ | grep -v ':0' | wc -l
   ```

   printed **79**, **99** and **8**: ninety-nine one-minute annotations
   across seventy-nine files, against eight files carrying five minutes.
   Five minutes is the exception, carried by heavy suites
   (`SubprocessRunner`, `SSHKeyPassphraseTool`, `ConnectionDiagnostics`, the
   rig suites). So `ProbeStartTests` at one minute — one of the two sites
   the row names — matches the project and wants no change at all.
2. **The real asymmetry is four `@Test` overrides inside a five-minute
   suite, not one.** `ConnectionDiagnosticsJumpTests.swift` declares
   `@Suite(… .timeLimit(.minutes(5)))`, and four `@Test` annotations inside
   it tighten that to one minute:

   ```
   grep -n 'timeLimit(.minutes(1))' Tests/macSCPCoreTests/ConnectionDiagnosticsJumpTests.swift
   ```

   printed four lines — `:289`, `:331`, `:726`, `:980`. The four are `aCancelledWalkStillClosesTheJumpConnection`,
   `aJumpConnectionThatArrivesAfterItsDeadlineIsClosed`,
   `theTraceFromTheJumpIsRacedAgainstTheTraceBudget` and
   `anEarlierStepsOutputDoesNotTurnALaterNeverStartedStepIntoATimeout`. The
   row names only the last.

**And the five minutes are one case's justification, not a project
precedent.** The sentence the row cites belongs to
`ConnectionDiagnosticsTests.aStepBeyondItsTimeoutIsSettledByItsDeadline`:
"The limit is a hang bound, not a ceiling on the deadline: CI run
35405472152 took 87.253 s to get here on the three-core runner, and the
limit sits well above that." That case parks on a `DispatchQueue.global()`
timer which gets no thread while the cooperative pool is busy — the 87 s is
how long the runner took to *reach* the assertion, not how long the test
works.

**Row 280's gap is narrower than the row says, and the narrowing is the
design.** The row asks for a helper that refuses a run whose output carries
the warning. One already exists: `scripts/mutation-probe` reports
`NO TESTS RAN` as one of its seven outcomes, "the build succeeded but the
filter matched nothing". `scripts/hang-hunt` does not — it takes a `FILTER`
from the environment, loops `swift test`, and judges each run only by
whether the process outlived `TIMEOUT`. A display-name filter there produces
`RUNS` runs of nothing, every one counted as not-hung, which is the 40-run
loop the row records losing. Measured 2026-10-05: `grep -c 'No matching' scripts/hang-hunt` printed
**0**, against `grep -c 'NO TESTS RAN' scripts/mutation-probe`, which
printed a non-zero count — the positive beside that negative, so the zero
measures a missing gate and not a mistyped pattern.

**One further bite, found while reading it:** the worker ends each
non-hanging run with `rm -f "$log"`. The warning is one line in that log, so
today the evidence is deleted before anyone could check.

## Part A — the four overrides go, and the suite's bound is inherited

Delete the four `@Test(.timeLimit(.minutes(1)))` annotations in
`ConnectionDiagnosticsJumpTests.swift`, leaving the four `@Test`s plain so
each inherits `@Suite(… .timeLimit(.minutes(5)))`.

**Maintainer's ruling, 2026-10-05, taken on the measured framing above
after an earlier question on the row's own framing was withdrawn:** remove
the overrides rather than keep one minute with four written justifications,
or measure the four under saturation first. Removing an override is smaller
than changing a number; the bound then follows the suite, so a later change
to the suite carries these four with it; and all four are deadline or
cancellation cases on the same machinery the five minutes were written for,
which the suite's own justification already covers.

**`ProbeStartTests` is not touched.** It carries the project's default and
the row's claim about it is withdrawn, not acted on.

### What proves this, and what cannot

There is no red first, and the spec says so rather than inventing one: a
wider hang bound produces no failure, it prevents one. A test that would go
red against the one-minute bound is a test that hangs, which is the defect
the bound exists to catch, not a fixture to plant.

What is checkable:

- **`everyCallerOfPollUntilDeclaresATimeLimit` is not evidence here.**
  Fix round 1 withdraws this bullet's first version, "stays green", and its
  claim that the guard is "the one guard that could have gone red on this
  change": it could not, because it never examines this file. That guard
  (`PollingGuardTests`) requires a file calling `pollUntil(` or a polling
  helper to carry `.timeLimit(`. It is a **per-file** check —
  `callers.filter { !$0.text.contains(".timeLimit(") }` — which was read
  correctly at `770472ac` and matters nothing here: the check considers
  only suite files that contain `pollUntil(` or call a polling helper, and
  `ConnectionDiagnosticsJumpTests.swift` contains neither. Counted
  2026-10-05, each printing 0:
  `grep -c -F 'pollUntil(' Tests/macSCPCoreTests/ConnectionDiagnosticsJumpTests.swift`,
  and the same with `'waitFor('`, `'waitForFailure('` and
  `'waitForRequests('`. A reviewer also removed the suite annotation, and
  the comment's mention of it, so the file carried no `timeLimit(` at all,
  and the guard still passed. What the change rests on instead: the four
  cases still run and pass under the suite's bound
  (`swift test --build-system native --filter ConnectionDiagnosticsJumpTests`:
  45 tests in 1 suite passed), and the suite's trait applies to them
  because they sit directly in the struct, with no nested `@Suite`
  (`grep -c -F '@Suite' Tests/macSCPCoreTests/ConnectionDiagnosticsJumpTests.swift`
  prints 1).
- **The suite stays green**, with the four cases still running.
- **The file still contains `.timeLimit(`** exactly once, at the suite.
  `grep -c 'timeLimit(' Tests/macSCPCoreTests/ConnectionDiagnosticsJumpTests.swift`
  printed **5** before the change (one suite, four overrides) and must print
  **1** after. Fix round 1 withdraws "must print **1** after": it prints
  **2**, because the doc comment this change adds quotes the removed
  override. The code carries exactly one `.timeLimit(`, at the suite.

## Part B — `hang-hunt` refuses a run that tested nothing

`scripts/hang-hunt` gains a gate, in the shape `mutation-probe` already
uses: a run that tested nothing is its own outcome, distinct from green and
from hung.

- **The negative:** if the first run's log carries
  `warning: No matching test cases were run`, the worker stops, keeps the
  log, prints a refusal naming the filter, and exits non-zero. It does not
  count runs.
- **The positive beside it**, because this project requires one: the run
  must also carry positive evidence that tests ran — the
  `Test run with N tests` line — and the refusal fires when that evidence
  is absent, not only when the warning is present. A log with neither is
  exactly as worthless as one with the warning, and a negative check that
  only looks for a known warning string goes quiet the day SwiftPM rewords
  it.
- **The log survives a refusal.** `rm -f "$log"` stays for real runs and is
  skipped on the refusal path, so the evidence outlives the decision.

The gate reads the **first** run only. A filter cannot start matching
halfway through a loop, so checking every run would buy nothing and cost a
grep per iteration.

### What proves this

Red first, and it is cheap here: set `FILTER` to a suite **display name**,
`RUNS=2`, and run `scripts/hang-hunt`.

- Before the change: it prints `w1: 2 runs, no hang` and exits 0, having run
  no test.
- After: it refuses on the first run, names the filter, keeps the log, and
  exits non-zero.

Then the same filter spelled as the **type name**, `RUNS=1`, must still pass
the gate and loop normally — the positive beside the negative at the level
of the script's own behaviour, so the gate cannot be satisfied by refusing
everything.

## Closeout

Both rows are closed in `docs/BACKLOG.md` with `**Done 2026-10-05**`
passages. Row 149's closure also **corrects the row**, quoting what it
withdraws: that one minute is the project default rather than an anomaly,
and that four overrides exist where it named one.

Two findings from this design go into the record rather than into the
change, because neither is in scope:

- `everyCallerOfPollUntilDeclaresATimeLimit` is a **per-file** check, so a
  file can satisfy it with one suite annotation while a `@Test` that needs
  its own bound has none. Fix round 1 withdraws "That is the property this
  change relies on": the change relies on neither reading, since the guard
  never examines the file. It stays a weakness worth its own row.
- `scripts/hang-hunt` deletes the log of every non-hanging run, so any
  evidence a passing run carried is gone. Part B keeps the log only on the
  refusal path; whether the others should survive is a separate question.

## Out of scope

- Row 151 (three accepting host-key deciders) — needs the rig from the main
  checkout.
- Widening or narrowing any other `.timeLimit` in the tree.
- `scripts/mutation-probe`, which already has this gate.
