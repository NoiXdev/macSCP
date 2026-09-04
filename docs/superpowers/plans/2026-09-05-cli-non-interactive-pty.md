# CLI Non-Interactive Under A PTY Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the backlog row "`--non-interactive` cannot be told
apart from its own absence in this harness": measure the flag's own
contribution by running the CLI under a pseudo-terminal, where
`isatty(stdin)` is true.

**Architecture:** `SubprocessRunner` hands every child `/dev/null` as
stdin, so `CLIEnvironment.hasTTY` is false and
`HostKeyPolicy.decision(for: .ask, hasTTY: false)` already resolves to
`.reject` before the flag is read (`SessionConnecting.swift:21-23`,
`:130`; `CLIEnvironment.swift:7`). A test-support `PTYSubprocess`
(`posix_openpt`/`grantpt`/`unlockpt`/`ptsname`, then `posix_spawn` with
the slave as stdin/stdout/stderr) runs the CLI with a real terminal;
the case that closes the row asserts that `--non-interactive` refuses
an unknown host key under the PTY, while the same command WITHOUT the
flag reaches the prompt (observed as the prompt text on the PTY, then
the test writes `no` and the CLI refuses).

**Tech Stack:** Swift 6 strict, Swift Testing, Darwin PTY calls,
`MacSCPTestSupport`, the Docker rig (`MACSCP_ITEST=1`).

**Spec:** `docs/BACKLOG.md`, row "`--non-interactive` cannot be told
apart from its own absence in this harness".

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; commit per task; zero warnings; do not push.
- The PTY runner is test support only (`Tests/MacSCPTestSupport/PTYSubprocess.swift`); production code does not change unless the measurement proves the flag does nothing — in which case STOP and report, do not fix speculatively (the row's own words).
- Every wait is an `await` under a suite `.timeLimit`; the PTY's output is read on a dedicated thread or a `DispatchIO` channel into an `AsyncStream` — never a blocking `read` on the cooperative pool; no wall-clock ceiling; the child is killed in a `defer` and its exit awaited so no process outlives the test.
- Nothing is typed into the PTY but `no`/`yes` answers to the host-key prompt; no secret crosses it (the rig's password rides the existing secret-relay environment variable, never the terminal).
- Red first; no `#require` on a non-optional; a negative check has a positive beside it; a number in a comment is counted.

---

### Task 1: `PTYSubprocess` in test support, and the measurement

**Files:**
- Create: `Tests/MacSCPTestSupport/PTYSubprocess.swift` (`public struct PTYSubprocess` — `static func run(executable: URL, arguments: [String], environment: [String: String], input: AsyncStream<String>?) async throws -> Result` where `Result` carries `output: String` (everything read from the master until EOF) and `status: Int32`; a `write(_:)` for answers; `terminate()`; implemented with `posix_openpt`, `posix_spawn_file_actions_adddup2` for fds 0/1/2, `posix_spawnattr_setflags` with `POSIX_SPAWN_SETSID` so the slave becomes the controlling terminal; the master read through `DispatchIO`; `waitpid` awaited through a continuation resumed from a `DispatchSource.makeProcessSource(.exit)`)
- Test: `Tests/macSCPCoreTests/PTYSubprocessTests.swift` (ungated: `/usr/bin/tty` prints a `/dev/ttys` path — the positive that `isatty` is true; `/bin/sh -c 'read x; echo got:$x'` with input `hello` echoes `got:hello`; a child killed by `terminate()` reports a signal status; no child outlives the test — `ps` is not consulted, the `waitpid` result is)
- Test: `Tests/macSCPCoreTests/CLIMatrixITests.swift` (gated `MACSCP_ITEST=1`): `nonInteractiveUnderAPTYRefusesWithoutPrompting` — the CLI binary from `CLIMatrix`'s existing lookup, `ls --non-interactive --json <target>` against a fresh known-hosts file: output carries the refusal and NOT the prompt text (name the exact prompt string from `SessionConnecting.swift`'s announcing branch — count its occurrences); `askUnderAPTYPromptsAndNoRefuses` — the same command without the flag: the prompt text appears, the test writes `no`, the CLI refuses with the same exit code. The pair is the measurement: same TTY, the flag is the only difference.
- Modify: `docs/BACKLOG.md` (the row → Done: the two cases, the exit codes observed, the prompt text counted), `docs/superpowers/plans/2026-09-05-cli-non-interactive-pty.md` checkboxes.

- [ ] **Step 1: Red first** — `cannot find 'PTYSubprocess'`; then, with the support in place, the gated pair against the rig.
- [ ] **Step 2: Implement**; `swift test --filter PTYSubprocess` green; `MACSCP_ITEST=1 swift test --filter "CLIMatrix"` green; full `swift test`; zero warnings.
- [ ] **Step 3: Commit** `test(cli): --non-interactive is measured under a pseudo-terminal, where the flag is the only difference`.
