# The dial step needs the launch seam its neighbour already has

**Date:** 2026-09-28
**Commissioned:** by the maintainer on 2026-09-28, after `develop` went red
twice in six CI test-step runs of the same code, with no test failing twice.
(The sixth, run 36444927836, went green after the commissioning question was
put; the count is recorded here rather than left at the number the question
carried.)
**Backlog rows:** "Starved CI runners settle diagnostics probes as
`notStarted`, and the positive companions catch it" and its parent
"Wall-clock ceilings still in the tree" (measured 2026-09-04: 8 files, 12
`waitUntil` definitions, 79 callers).

## Correction, 2026-09-28, before any of this was built: the seam is not needed

Everything below was written before the affected cases were read one by one.
Reading them changed the answer, and the design section below is superseded.

**What the measurement found.** The three cases that went red build their
dial from `Self.constantContribution(…)` — a contribution that RETURNS A
CONSTANT. It computes nothing. The only thing that can fail in it is being
given a thread. Above it sits `ConnectionDiagnosticsTests.run(…)` at `:1692`,
whose signature carries `stepTimeout: Duration = .seconds(5)`.

A five-second budget over a body that returns immediately measures the runner
and nothing else. That is not a case for a new seam; it is the wall-clock
ceiling CLAUDE.md already forbids, sitting in a default argument.

**The blast radius, counted 2026-09-28.** `Self.run(` has **12** call sites
in that file. **Two** pass their own `stepTimeout` — `.milliseconds(200)` and
`.seconds(1)` — and they are exactly the two cases that WANT the deadline to
fire (`aStepBeyondItsTimeoutIsSettledByItsDeadline`,
`aProbeThatIgnoresCancellationDoesNotHoldTheStepPastItsDeadline`). The other
**ten** take the default. So raising the default heals ten cases at once and
cannot reach the two that depend on a small budget, because they do not use
it.

**The shape, and it is this file's own precedent.**
`aStepBeyondItsTimeoutIsSettledByItsDeadline` already carries
`@Test(.timeLimit(.minutes(5)))` as a hang bound in place of a wall-clock
ceiling, and asserts `settledByItsDeadline` so that it tolerates both of the
deadline's outcomes. The complement, for cases that want the probe to ANSWER,
is a budget no assertion depends on plus the same kind of hang bound. No
production code changes.

**What stays true from the design below:** the diagnosis (the reds are
`notStarted` from a starved pool), the classification of which cases must
keep a small budget and which must not, the rule that no positive companion
may be removed, and the closing measurement (a single green run proves
nothing — the count must be compared).

**What is withdrawn:** the stored `stepLaunch` seam in
`ConnectionDiagnostics`, and with it the premise that a launcher can
guarantee a body begins. `DetachedProbe.Launch` is
`(@escaping @Sendable () async -> Void) -> Task<Void, Never>`; every task it
can return still waits for the same cooperative pool, so no launcher
expressible through that signature could have delivered what the design
asked of it. The seam was the wrong tool, and it was specified before the
cases were read.

**This is the third design in this session that measurement changed**, after
the scope of the typed-findings block (16 sites to 22) and its census recipe.
The pattern is consistent enough to name: the cheap step is reading the
things the change will touch, one by one, before deciding the shape.

---

## What is red, and why it is not a defect in the code under test

Two CI runs of the same sources went red on 2026-09-28, with different tests
each time:

| run | failing cases | how long each waited |
|---|---|---|
| 36435034775 (attempt 2) | `aHostileTargetHostIsRefusedBeforeAnyCommandRuns`, 1 of its 7 arguments | — |
| 36443098104 | `aBackendErrorsOwnDescriptionNeverReachesTheRow`, `aForeignErrorsLocalizedSentenceNeverReachesTheRow`, `aURLWithUserinfoNeverReachesTheReport` | 49.6 s each, in a 67.175 s suite |

The second run's outcome text names the mechanism outright:
`.notStarted("this Mac was too busy to start the measurement")` where the
cases expect `.failed(…)`. `notStarted` is the third outcome added on
2026-09-25 by the answered-decisions plan **for exactly this state**, and
these cases predate it.

**What went red is the positive companion, not the property.** All three of
the second run's cases are secrecy cases, and every negative check in them —
the planted credential absent from the outcome, the detail, the plain text
and the Markdown — passed. Red were `dial.outcome == .failed(neutral)`
(`ConnectionDiagnosticsTests.swift:1138`) and `== .failed(rendered)`
(`:1209`), the two assertions that exist so the negatives cannot pass by
reading nothing.

That is CLAUDE.md's "a negative check needs a positive check beside it"
doing its job. Without those two lines the three cases would have gone
**green while checking nothing at all**. The fix must not remove them.

## The seam exists, one file over

`ConnectionDiagnostics` already takes a launch seam for the jump dial:

```swift
private let jumpDialLaunch: DetachedProbe.Launch            // :283
jumpDialLaunch: @escaping DetachedProbe.Launch = DetachedProbe.detach,  // :401
let answer = await DetachedProbe.run(timeout: stepTimeout, launch: jumpDialLaunch) { … }  // :940
```

and `DiagnosticJumpStep.race` takes the same one a layer down (`:999`), whose
own doc comment already says what it is for: *"a launcher that HOLDS the body
when the suite needs a probe that never began."*

`ConnectionDiagnosticsJumpTests` injects it six times (`:336`,
`jumpDialLaunch: abandoned.launch`, and its two factories at `:1695`/`:1705`
default to `DetachedProbe.detach`).

**`ConnectionDiagnosticsTests` injects it zero times**, because the step its
cases read has no seam to inject into:

```swift
// ConnectionDiagnostics.bounded(_:_:), :1391
let answer = await DetachedProbe.run(timeout: stepTimeout) {
    await contribution.run(values, context)
}
```

Its own comment three lines above says *"The dial's start AND every
contribution's, because both arrive here: they are the two kinds of step that
come through the seam"* — it names a seam the call does not use.

## The design

**One stored seam, `stepLaunch`, not two.** `bounded` serves both the dial
and every contribution; splitting it would give two names for one decision
and force every caller to say the same thing twice. Defaulted to
`DetachedProbe.detach`, exactly as `jumpDialLaunch` is, so production is
unchanged and no non-test caller needs editing.

```swift
private let stepLaunch: DetachedProbe.Launch
// init(…, stepLaunch: @escaping DetachedProbe.Launch = DetachedProbe.detach, …)
let answer = await DetachedProbe.run(timeout: stepTimeout, launch: stepLaunch) { … }
```

**The test-side launcher starts the body immediately and on this task.** The
jump suite's `abandoned.launch` is the opposite tool — it holds a body so the
suite can observe a probe that never began. This work needs the complement: a
launcher under which the body cannot fail to begin, so `notStarted` is not a
reachable outcome and the positive companions read a settled step.

**The critical distinction, and the reason this is not a mechanical sweep.**
`ConnectionDiagnosticsTests.swift` holds **52** `@Test` cases, of which
**14** read `dial.outcome` (counted 2026-09-28). They are not one kind:

- Cases that assert a **settled** outcome — a failure's sentence, a path
  kept, a credential absent — want the deterministic launcher. Starvation is
  noise for them, and today it is the only thing that makes them red.
- Cases that assert the **timing behaviour itself** — a step settled by its
  deadline, a probe that never began, the `notStarted` outcome — must keep
  the real `DetachedProbe.detach`. Giving those the deterministic launcher
  would delete the property they exist for.

Each of the 14 is classified individually, in the plan, with the assertion
that decides it. A case whose classification is not obvious from its
assertions is left on the real probe: the failure mode of guessing wrong in
that direction is a flaky test, and in the other direction it is a test that
no longer tests anything.

## What this deliberately does not do

- **It does not raise `stepTimeout`.** Every budget in this suite is
  `.seconds(5)` and raising it moves a threshold rather than removing a
  dependency. The parent backlog row measured this pattern across 8 files and
  79 callers on 2026-09-04; this work removes the dependency for one step's
  callers and leaves that row standing with a smaller number.
- **It does not touch the jump suite's own red case.**
  `aHostileTargetHostIsRefusedBeforeAnyCommandRuns` fails through
  `jumpDialLaunch`, a seam that already exists and that the case already
  could have used. Whether it should is a separate judgement about that
  case's subject, and it gets its own task rather than being folded in here.
- **It removes no positive companion.** The two assertions that went red are
  what made the starvation visible instead of silent; they stay exactly as
  they are.

## Testing

1. A guard that the production default is unchanged: constructing
   `ConnectionDiagnostics` without naming `stepLaunch` uses
   `DetachedProbe.detach`. A negative check ("no production caller names it")
   needs this positive beside it.
2. For each case moved to the deterministic launcher: it still goes red
   under the mutation it was written for. A case that stops being sensitive
   has been weakened, not stabilised, and that is the failure mode this
   work must prove it avoided.
3. At least one case kept on the real probe, asserted to still reach
   `notStarted` when its launcher holds the body — so the outcome this work
   routes around is still reachable and still tested.

## How this will be known to have worked

Not by one green CI run. Today's measurement is six test-step runs with two
red — and the two greens that followed the second red are exactly why a
single green proves nothing here. The same code must be run again after the
change and the count compared.
A single green run after a fix is what this project's own rule calls evidence
that a check *can* pass, not that it does.
