# Ceilings Under Other Spellings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The wall-clock ceilings that survived the polling plan because
they are spelled without `ContinuousClock` — a latch waited on with a
timeout, a delivery waiter with a ceiling task, a sleeping child racing
real work in a task group — are replaced by waits the harness time limit
ends, and the guard learns those spellings.

**Architecture:** Three shapes, one rule each. (1) `AsyncSignal.wait(timeout:)`
callers use `wait()` — it returns `.cancelled` when the harness limit
cancels the test, so the "never arrived" branch keys on `.cancelled`
instead of `.timedOut`. (2) `Box.waitForFirstDelivery(timeout:)` parks on
its continuation with a cancellation handler that resumes it, no ceiling
task. (3) A `Task.sleep` child racing work inside `withThrowingTaskGroup`
goes; the work is awaited directly under the suite's `.timeLimit`, and the
floor beside it stays. `PollingGuardTests` gains a check per spelling,
each with a positive companion. Two sites keep their timeout because the
timeout IS what they measure, and the row says so.

**Tech Stack:** Swift 6 strict, Swift Testing (`.timeLimit`),
`MacSCPTestSupport.pollUntil`, `AsyncSignal` (Tests support).

**Spec:** the Open list of the `docs/BACKLOG.md` row "Wall-clock ceilings
still in the tree" as written in `0069953f` (measured 2026-09-04):
`AsyncSignal.wait(timeout:)` with four callers outside its own tests —
`SubprocessRunnerTests.swift:418`, `LoopbackTLSStub.swift:107` (60 s),
`EmbeddedKeyPorterTests.swift:146` and `:152` (10 s);
`Box.waitForFirstDelivery(timeout:)` in `TerminalPanelViewModelTests.swift`
(30 s, three callers); three sleep races —
`ConnectMainActorLivenessTests.swift:418-420` (5 s child throwing
`DeadlineNotEnforced` against a 400 ms connect timeout, flips the
assertion at :435 on a starved runner), `CitadelShellIntegrationTests.swift:134`
(10 s against the stream's end, `#expect(ended, …)`), and its
`collectUntil(timeout:)` (:64-65, 10 s default, 20 s at :176, five
callers). Rule: CLAUDE.md, "A wall-clock ceiling in a test measures the
runner".

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; commit per task; zero warnings; do not push.
- No wall-clock ceiling in any test; a floor is allowed; the harness `.timeLimit` is the only clock, `.minutes(1)` unless the suite's doc comment says why more. Every suite touched carries one.
- Tests never block the cooperative pool; no `#require` on a non-optional; `#expect` prints its source text.
- The migration changes no assertion's meaning: the outcome each race asserted (the connect ended with an error; the stream ended; the marker arrived; the latch was raised) stays asserted; only the clock beside it goes.
- Two timeouts stay because they are the measurement, and each says so in a comment: `SubprocessRunnerTests.swift:418` (`started.wait(timeout: startBound)` — a block that cannot start inside the bound is the saturation being measured; gated `MACSCP_SATURATION`), and nothing else. A third candidate is a finding, not a silent keep.
- A negative source-scanning check needs a positive check beside it; comments quoting code near an anchor move the anchor — describe in prose; a number in a comment or row is counted when written.
- Red first: for each site, the mutation that the old ceiling would have flagged (the latch never raised; the stream never ending; the connect never returning) is planted once against the new shape under the suite limit and observed as a red naming the test (`scripts/mutation-probe`, RESULT line in the commit body).

---

### Task 1: Latches and the delivery waiter

**Files:**
- Modify: `Tests/macSCPCoreTests/LoopbackTLSStub.swift:100-110` (`ready.wait(timeout: .seconds(60))` → `ready.wait()`, the `guard … == .signalled` keeps throwing `listenerNeverBecameReady` on `.cancelled`; every suite using the stub carries `.timeLimit` — list them by grep and add where missing)
- Modify: `Tests/macSCPCoreTests/EmbeddedKeyPorterTests.swift:140-156` (`finished.wait(timeout: .seconds(10))` → `finished.wait()`; the `Issue.record` and the FIFO unblock run on `.cancelled`; the second `wait(timeout:)` after the unblock → `wait()` too; suite `.timeLimit(.minutes(1))`)
- Modify: `Tests/macSCPCoreTests/TerminalPanelViewModelTests.swift:1020-1040` (`waitForFirstDelivery(timeout:)` → `waitForFirstDelivery()`: `withTaskCancellationHandler` around `parkUntilDelivered()`, `onCancel` calls `resumePendingWaiter()`; the ceiling task goes; three callers; the suite already carries `.timeLimit`)
- Modify: `Tests/macSCPCoreTests/SubprocessRunnerTests.swift:418` — no code change; the comment beside it says the timeout is the measurement (see Global Constraints)

**Interfaces:**
- Consumes: `AsyncSignal.wait()` (`Tests/macSCPCoreTests/Support/AsyncSignal.swift:79`, returns `.cancelled` when the task is cancelled).
- Produces: `Box.waitForFirstDelivery()` with no parameter.

- [ ] **Step 1: Red first** — plant "the latch is never raised" in `EmbeddedKeyPorterTests` (comment out `finished.signal()`) under the new shape: `scripts/mutation-probe --filter EmbeddedKeyPorterTests --apply "perl -0pi -e 's/^(\s*)finished\.signal\(\)/\1\/\/ finished.signal()/m' Tests/macSCPCoreTests/EmbeddedKeyPorterTests.swift"` — RESULT RED after the harness limit (about 60 s), naming the test.
- [ ] **Step 2: Implement** the four sites; `swift test --filter "EmbeddedKeyPorter|TerminalPanelViewModel|LoopbackTLS"` green; full `swift test` green; zero warnings.
- [ ] **Step 3: Commit** `test: latches and the delivery waiter end through the harness limit, not a timeout`.

---

### Task 2: The three sleep races

**Files:**
- Modify: `Tests/macSCPCoreTests/ConnectMainActorLivenessTests.swift:405-440` (the `withThrowingTaskGroup` with the 5 s `DeadlineNotEnforced` child → a direct `try await bootstrap.connect(host:port:).get()` inside a `do/catch`; `thrown != nil` and the floor `elapsed > .milliseconds(300)` stay; `DeadlineNotEnforced` and its `#expect` go; suite `.timeLimit(.minutes(1))`)
- Modify: `Tests/macSCPCoreTests/CitadelShellIntegrationTests.swift:60-70` (`collectUntil(_:marker:timeout:)` → `collectUntil(_:marker:)`: reads `shell.output` until the marker is seen, no timeout child; the partial-text box stays for the failure message; five callers) and `:128-140` (the `ended` race → `for try await _ in shell.output {}` directly, `ended` becomes "the loop returned", the `thrown` capture stays; gated `MACSCP_ITEST` suite; `.timeLimit(.minutes(2))` if the suite's own doc says the rig's shell startup needs it — count the cases and say)

**Interfaces:**
- Consumes: nothing new.

- [ ] **Step 1: Red first** — for the liveness test, plant a resolver that answers (so the connect cannot time out in the resolving state) only if such a fixture exists; otherwise plant `connectTimeout(.seconds(90))` and observe the harness red at 60 s: `scripts/mutation-probe --filter theConnectDeadlineAlsoCoversNameResolution --apply "perl -0pi -e 's/connectTimeout\(\.milliseconds\(400\)\)/connectTimeout(.seconds(90))/' Tests/macSCPCoreTests/ConnectMainActorLivenessTests.swift"` — RESULT RED. For the shell: `MACSCP_ITEST=1 scripts/mutation-probe --filter CitadelShellIntegrationTests --apply "…"` planting a marker that never appears (`marker: "never-\(UUID())"` at one call site) — RESULT RED.
- [ ] **Step 2: Implement**; `swift test --filter ConnectMainActorLiveness` green; `MACSCP_ITEST=1 swift test --filter CitadelShellIntegrationTests` green (rig up, from the main checkout); full `swift test` green; zero warnings.
- [ ] **Step 3: Commit** `test: the three sleep races await the work under the harness limit`.

---

### Task 3: The guard learns the spellings, and the row closes

**Files:**
- Modify: `Tests/macSCPCoreTests/PollingGuardTests.swift` (two new checks: `noLatchIsWaitedOnWithATimeout` — `wait(timeout:` occurs nowhere in `Tests/` except `AsyncSignalTests.swift`, `Support/AsyncSignal.swift` and the one saturation site (`SubprocessRunnerTests.swift`, matched by the sentence in its comment that names the measurement — derive the exemption from that sentence, not from the file name), with the positive that `AsyncSignalTests.swift` contains it; `noSleepingChildRacesWorkInAGroup` — no `addTask` whose first statement is a `Task.sleep(for:` in `Tests/`, with the positive that a fixture in `Support/` (never scanned) shows the pattern matching)
- Modify: `docs/BACKLOG.md` (the row: the Open list shrinks to the saturation site and the three production-bound `now.advanced(by:)` arguments; the commits; the three RESULT lines)

- [ ] **Step 1:** write the checks; `swift test --filter PollingGuardTests` green; plant one `wait(timeout:` in a test file → RED; plant one sleeping child → RED (RESULT lines into the commit body).
- [ ] **Step 2:** the row; count the sites changed in Tasks 1–2 from the diffs.
- [ ] **Step 3: Commit** `test: the guard reads the other spellings of a ceiling, and the row says what stays`.
