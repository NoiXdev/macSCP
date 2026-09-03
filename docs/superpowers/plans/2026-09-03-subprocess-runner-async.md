# Subprocess Tests Stop Parking Pool Threads — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The tests that run a child process (`macscp-cli`, `ssh-keygen`,
a shell) wait for it without parking a cooperative-pool thread, so three
of them running at once on a three-core CI runner cannot starve the
suite. CI on `develop` is red at `0175e90` (run 33681669890: the three
CLI subprocess tests reported empty output after 60 s, 3387 other tests
"passed after 80 s", 22 issues) and a diagnostic run of the same tree
hung to the 20-minute timeout with no child ever observed.

**Architecture:** One `SubprocessRunner` in `Tests/macSCPCoreTests/Support/`
replaces the three copies of `runProcess` (`CLISessionsJSONRoundtripTests`,
`CLISessionNameCompletionTests`, `CLIRootHelpTests`) and the
`DispatchSemaphore` wait in `EmbeddedKeyPorterTests` (:122). It is
`async`: `Process.terminationHandler` resumes a `CheckedContinuation`;
the two pipes are drained on `DispatchQueue.global()` into boxes and
joined by an `AsyncStream`/continuation, never by `DispatchGroup.wait`;
the timeout is a `Task` racing with `Task.sleep`, which on expiry
terminates then kills the child and throws the same `CLIProcessTimeout`
with the stderr so far. No `waitUntilExit`, no `.wait()`, no semaphore.
The tests become `async`. The runner is proved with an owned child that
sleeps past the timeout (throws, child gone) and one that prints to both
pipes above the 64 KB pipe buffer (both drained, no deadlock).

**Tech Stack:** Foundation `Process`, Swift concurrency continuations,
Swift Testing; CLAUDE.md "Tests never block the cooperative pool".

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **No blocking wait anywhere in a test target after this plan:** a
  guard scans `Tests/` for `waitUntilExit()`, `DispatchSemaphore`,
  `DispatchGroup.wait(`, `syncShutdownGracefully(` and
  `futureResult.wait()` outside a named allowlist (each allowed site
  carries a one-line reason in the allowlist, and the allowlist is
  expected to be EMPTY after Task 1 unless a site proves it cannot be
  async — `Tests/macSCPAppKitTests/LivenessProbeDropIntegrationTests.swift` (the `drained.wait()` at its frozen-peer close)'s `drained.wait()`
  is a candidate to convert, not to allow). Positive anchor: the runner
  file exists and the CLI suites call it.
- The four converted suites keep their assertions byte-for-byte; only
  the waiting changes.
- Swift 6; warning budget 1; TDD red first (the runner's own tests);
  commit per task; the controller pushes only after CI is green.

---

### Task 1: The runner, the long waits, the guard

Measured 2026-09-03 (grep over `Tests/` for `DispatchGroup…wait(`,
`DispatchSemaphore`, `waitUntilExit()`, `syncShutdownGracefully(`,
`futureResult.wait()`, `Thread.sleep`, `usleep(`): about seventy sites in
thirty files. Most wait a few milliseconds on `ssh-keygen`, `rm`, `dd`,
`stat` children. The ones that park a thread for seconds are the target of
this task; the rest are Task 1b.

**Files:**
- Create: `Tests/macSCPCoreTests/Support/SubprocessRunner.swift`
- Modify — the long waits, every one converted here:
  - `CLISessionsJSONRoundtripTests.swift` `runProcess` (60 s `group.wait` + `waitUntilExit`)
  - `CLISessionNameCompletionTests.swift` (same shape, :109)
  - `CLIRootHelpTests.swift` (same shape, :95)
  - `CLIRoundtripITests.swift` (same shape, :381–393; gated suite, convert anyway)
  - `EmbeddedKeyPorterTests.swift` :122–147 (`DispatchSemaphore`, 10 s, twice)
  - `LoopbackTLSStub.swift` :77–110 (`DispatchSemaphore` 60 s readiness wait) and :193
  - `Tests/macSCPAppKitTests/LivenessProbeDropIntegrationTests.swift` :311–312 (`drained.wait()` + `waitUntilExit`) and :478 (`Thread.sleep` — read what it does; convert if it runs on a pool thread)
- Test: `SubprocessRunnerTests` (timeout path with an owned `sleep 30` child: throws within the bound and the child is gone; big-output path: a child printing 256 KB to both pipes is drained without deadlock; exit status and both pipes for a normal child) and the guard `TestsNeverBlockThePoolGuardTests`.

**The runner:**

```swift
struct SubprocessResult: Sendable { let status: Int32; let stdout: Data; let stderr: Data }
struct SubprocessTimeout: Error { let stderrSoFar: Data }

enum SubprocessRunner {
    /// Runs `executable` with `arguments`, drains both pipes, and awaits
    /// termination without parking a cooperative-pool thread: the pipes are
    /// read on `DispatchQueue.global()`, termination arrives through
    /// `Process.terminationHandler`, and the wait is a continuation.
    static func run(_ executable: URL, arguments: [String], environment: [String: String]? = nil,
                    currentDirectory: URL? = nil, stdin: Data? = nil,
                    timeout: Duration = .seconds(60)) async throws -> SubprocessResult
}
```

Timeout: race the continuation against `Task.sleep(for: timeout)`; on
expiry `terminate()`, then after two seconds `kill(pid, SIGKILL)`, resume
once (a flag guards exactly-once), throw `SubprocessTimeout`. The
readers finish on their own queue and are joined through a second
continuation or an `AsyncStream` — never `DispatchGroup.wait`.

**The guard** (`TestsNeverBlockThePoolGuardTests`): scans every `.swift`
under `Tests/` for the five patterns above outside comments. Files still
carrying short child waits are listed in an allowlist INSIDE the guard,
each with the pattern it is allowed to carry; the list is what Task 1b
shrinks to empty. Positive anchors: `SubprocessRunner.swift` exists and
defines `run(`; each of the four CLI suites calls `SubprocessRunner.run(`.
The allowlist is derived from the measured grep, not typed from memory —
run the grep, paste the file names.

- [ ] Red first for the runner's tests; convert the long waits; guard green; the CLI suites and the four converted files green; full unit suite green (the gated ITEST suites run if the rig is up); zero warnings; commit
  `test: subprocess tests await their children instead of parking pool threads`.

### Task 1b: The short waits

- [ ] Replace every remaining `waitUntilExit()` / semaphore under `Tests/`
  with `SubprocessRunner.run(` (test helpers become `async`; `try!` helpers
  become `throws`), shrink the guard's allowlist to empty, full suite green,
  commit `test: every child process in the suite is awaited`.

### Task 1c: The saturation test runs alone

Measured 2026-09-03 on CI (run 33705649537 at `126c5c88`): the test that
parks the global queue to prove the readers need no thread took 23.5 s on
the three-core runner and starved two neighbours past their bounds (a 2 s
bound firing after its 10 s child had exited; a 200 ms latch sleep measured
at 15.68 s against its 10 s ceiling). A test that saturates a shared pool cannot share a parallel
run.

- [x] Gate `readersDoNotNeedAFreeGlobalQueueThread` behind `MACSCP_SATURATION=1`
  (skipped by default, the skip reason names the run above); its doc
  comment keeps the measurement and the mutant evidence; the timeout test's
  child sleeps 60 s again so a late bound still finds it alive. Commit
  `test: the pool-saturation proof runs only when asked`.

### Task 2: Prove it where it failed

- [ ] Push (controller), watch CI: the Unit-Tests step back under four
  minutes and green; record the run id in the hang entry's follow-up
  paragraph (the one dated 2026-09-02 night), and close that paragraph.

## What is explicitly not in this plan

- The liveness ceiling (its own plan, running).
- Any change to the CLI itself.
