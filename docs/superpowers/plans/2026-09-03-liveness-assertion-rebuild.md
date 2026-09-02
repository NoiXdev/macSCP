# Liveness Assertion Rebuild: a Block Is Seconds, Noise Is Milliseconds — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ConnectMainActorLivenessTests` keeps proving that awaiting a
connect (and a real stalled dial) does not block the main actor — and
stops going red in a full gated run for scheduling noise. Measured
2026-09-02: sixteen of nineteen full runs red on gaps of 0.7–1.3 s
against a ceiling of 0.3–0.7 s; twenty-five of twenty-five green alone.

**Architecture:** The property the two timing tests exist for is a
BLOCK: the defect they were written against parked the main thread in a
synchronous wait for the connector's whole duration — the connect
timeout, 30 s in the app, whatever the test dials with. Scheduling
noise under a full suite is under two seconds. So the two magnitudes
are separable by an order of magnitude, and the assertion should say
so: the ceiling becomes `max(ambient × 3, 2 s)` while the dial under
test is made to last at least 5 s (a stalled loopback endpoint that never
answers, with the connect timeout at 6 s), so a real block shows as a
gap ≥ 5 s and noise never reaches 2 s. The ambient window stays (it
documents the run's load in the failure message), and each timing test
keeps its mutation proof: plant the synchronous wait (`blockThisThread`
on the main actor around the connect) → red every run; unplanted →
green under a full run, measured ten times (CLAUDE.md: a guard's
sensitivity is a number).

**Tech Stack:** Swift Testing; `Tests/macSCPCoreTests/ConnectMainActorLivenessTests.swift`
(`ambientGap(over:)`, `ceiling(forAmbient:)`, `StalledLoopbackEndpoint`,
`blockThisThread`); the docs entry `2026-08-08-testsuite-hang-investigation.md`.

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **The property stays measured, not assumed:** both timing tests keep a
  wall-clock assertion; what changes is the ceiling's relation to the
  dial's duration. No `.disabled`, no skip under load.
- **Sensitivity is measured by repetition:** the planted block must be
  red in 10 of 10 runs; the unplanted test green in 10 of 10 FULL gated
  runs (not alone) before the plan closes — the numbers go into the
  entry.
- Tests never block the cooperative pool (the planted block is a probe
  run once, then removed — never committed).
- Swift 6; warning budget 1; commit per task; do not push.

---

### Task 1: The ceiling and the dial

**Files:**
- Modify: `Tests/macSCPCoreTests/ConnectMainActorLivenessTests.swift`
  (`ceiling(forAmbient:)` → `max(ambient * 3, .seconds(2))`; the dial
  under test lasts ≥ 5 s: `awaitingTheConnectorDoesNotKeepTheMainActor`'s
  fake connector sleeps 5 s; `theMainActorKeepsRunningWhileARealDialStalls`
  dials the stalled endpoint with a 6 s connect timeout — read what the
  endpoint does today and keep the test's total under ~8 s); the doc
  comment at :32-45 and :120-125 rewritten to the new relation: "a block
  is the dial's duration; noise is milliseconds; the ceiling sits between").
- [ ] **Step 1: the mutation probe first** — plant `blockThisThread(forMilliseconds: 5_000)`
  on the main actor around the awaited connect in each timing test, run
  each 10 times (`for i in 1..10: swift test --filter ConnectMainActorLivenessTests`),
  record 10/10 red; remove.
- [ ] **Step 2:** the new ceiling; run alone 10 times → green; then the
  full gated run (`MACSCP_ITEST=1 swift test`) 10 times → record the
  liveness suite's result each time (the whole point).
- [ ] **Step 3: Commit** — `test(ssh): the liveness ceiling separates a block from scheduling noise`

### Task 1b: A green run prints its numbers

Measured in fix round 1 of Task 1 (2026-09-03): one planted full gated
run showed an ambient of 5.73 s on test 1 — above the 4 s cap — while every
green run before it printed nothing, so nobody can say how often the cap
binds. A green run that prints `ambient` and `largestGap` for both timing
tests (one line each, through the same `print` the red path already
uses, e.g. `liveness: <test> ambient=<s> gap=<s> ceiling=<s>`) makes
that a question a grep over CI logs answers.

**Files:** `Tests/macSCPCoreTests/ConnectMainActorLivenessTests.swift` only.

- [ ] Add the two lines; run the suite alone once and paste the two
  printed lines into the report; zero warnings; commit
  `test(ssh): the liveness tests print their ambient and gap on green as well`.

### Task 2: The entry closes its tally

**Files:**
- Modify: `docs/superpowers/specs/2026-08-08-testsuite-hang-investigation.md`
  (the "Noted 2026-09-02" table gets a closing row per run of Step 2;
  the sentence that the tally stops growing; what the ceiling means now)

- [ ] Commit — `docs(spec): the liveness tally closes at N of N green under load`

## What is explicitly not in this plan

- No isolated gate run for the suite; no `.serialized` changes.
- No change to the connect timeout in the app.
