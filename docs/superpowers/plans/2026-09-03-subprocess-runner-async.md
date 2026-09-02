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
  async — `LivenessProbeDropIntegrationTests.swift:311`'s `drained.wait()`
  is a candidate to convert, not to allow). Positive anchor: the runner
  file exists and the CLI suites call it.
- The four converted suites keep their assertions byte-for-byte; only
  the waiting changes.
- Swift 6; warning budget 1; TDD red first (the runner's own tests);
  commit per task; the controller pushes only after CI is green.

---

### Task 1: The runner, the four suites, the guard

**Files:**
- Create: `Tests/macSCPCoreTests/Support/SubprocessRunner.swift`
- Modify: the three CLI suites (delete their private `runProcess`, call
  the runner, tests `async throws`), `EmbeddedKeyPorterTests.swift`
  (the semaphore'd child at ~:122 and the `keygen.waitUntilExit()` at
  ~:844 — read what each waits for), any other `Process()` user under
  `Tests/` that waits synchronously (grep `waitUntilExit`, `DispatchSemaphore`,
  `.wait(`; `LoopbackTLSStub.swift:77` and `LivenessProbeDropIntegrationTests.swift:311`
  included — convert or allowlist with a reason)
- Test: `SubprocessRunnerTests` (timeout path; big-output path; exit
  status and both pipes) and the guard `TestsNeverBlockThePoolGuardTests`.

- [ ] Red first for the runner's tests; then the suites green; full unit suite; commit
  `test: subprocess tests await their children instead of parking pool threads`.

### Task 2: Prove it where it failed

- [ ] Push (controller), watch CI: the Unit-Tests step back under four
  minutes and green; record the run id in the hang entry's follow-up
  paragraph (the one dated 2026-09-02 night), and close that paragraph.

## What is explicitly not in this plan

- The liveness ceiling (its own plan, running).
- Any change to the CLI itself.
