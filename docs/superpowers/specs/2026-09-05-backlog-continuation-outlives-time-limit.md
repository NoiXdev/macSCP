# Backlog: a test parked on a bare continuation outlives its time limit

**Logged:** 2026-09-05, as a side finding of the diagnostic-log plan's
Task 1 round 2. **Not a design.** A read observation from one reverted
test, not a survey of every continuation-based wait in the suite.

## The finding

Measured in this plan's Task 1 round 2
(`DiagnosticLogTests.offResolvesAPendingFlush`, reverting
`DiagnosticLog.configure`'s waiter-resolution fix to reproduce the bug it
closes): `swift test --filter offResolvesAPendingFlush` recorded Swift
Testing's own "Time limit was exceeded: 60.000 seconds" for the suite's
`.timeLimit(.minutes(1))`, yet the `swiftpm-testing-helper` process was
still running two minutes later and had to be killed by hand. A bare
`CheckedContinuation` awaited inside `DiagnosticLog.flush()` does not
observe `Task` cancellation, so Swift Testing's time-limit cancellation
reaches the test's own task but never unparks the continuation underneath
it — the "exceeded" report is not the process actually stopping. On CI
this is a materially worse failure mode than a slow-but-bounded test: the
job does not fail at the suite's stated limit, it runs on to whatever the
CI step's own outer timeout is, or the runner's default if none is set.

## Open questions

1. Whether every CI job in this repo needs an explicit per-step
   `timeout-minutes` set below the runner's own default, so a hang of
   this shape is caught by minutes rather than by the runner's ceiling.
2. Whether every test-side wait on a continuation should be required to
   go through a cancellation-aware, polling-free helper (the
   `AsyncSignal`/`pollUntil` shape already used elsewhere in this suite)
   rather than a bare `withCheckedContinuation`, so a hang of this shape
   cannot recur silently in a future test.

Neither question is decided here.
