# Small follow-ups of 2026-09-19 — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close three open rows of 2026-09-19 that need no maintainer decision: an S3 Cancel that reads "Connection lost", the one known flake in `EditSessionManagerTests`, and the second subprocess runner in `SSHKeyConverter`.

**Architecture:** Four tasks. Task 1 maps a user's cancellation to a cancellation on the S3 (and, if the same shape exists there, WebDAV) transport. Task 2 finds and fixes the flake's root cause. Task 3 moves `SSHKeyConverter` onto the shared `SubprocessRunner`. Task 4 is the closeout. Each task names its `docs/BACKLOG.md` row by title; read it first and re-verify anchors with `grep -n`.

**Tech Stack:** Swift 6 strict, SwiftPM (Xcode 27 / Swift 6.4 locally; CI Swift 6.1.2, macos-15, three cores, zero-warning budget), Swift Testing.

## Global Constraints

- Maintainer, 2026-09-18: "weiter im backlog". Rows that need a maintainer decision stay out (they are asked in chat).
- Swift Testing, red first (recorded); tests never block the cooperative pool; no wall-clock ceiling; no fake that finishes on its own while a deadline races it (CI run 35405472152); no `#require` on a non-optional. Nothing new may compile only on Swift 6.4.
- Source-scanning guards read through `Tests/MacSCPTestSupport/SourceCorpus.swift` (2026-09-19); a negative check keeps a positive beside it. Scripted edits assert their anchor; probes are reverted with a file-scoped reverse patch verified by `cmp`.
- Every App string through `L10n.string(_:_:)` in `en`, `de`, `fr`, `pl` (German du-form).
- Subagents work in the FOREGROUND only. If the first build fails on a stale Metal toolchain path, delete the stale `XCBuildData` caches under `.build/out/Intermediates.noindex/` and rebuild.
- Zero compiler warnings. Conventional Commits, English, footer exactly `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` after one blank line. Do not push; do not launch the GUI; do not stage `docs/BACKLOG.md` before Task 4.

---

### Task 1: A user's Cancel of an S3 transfer reads as cancelled

**Row:** "S3: a user's Cancel of an upload or download can read \"Connection lost\"".

- [x] `S3FileSystem.send` (and every other place the S3 transport wraps errors — grep for the `connectionFailed` wrapping) passes a `CancellationError` and a `URLError.cancelled` through as the queue's cancellation, not `connectionFailed`. Read how the transfer queue recognises a cancellation for SFTP and match it exactly. Check WebDAV's transport for the same shape and fix it there too if present (state what you found).
- [x] Tests, red first: an injected transport throwing `CancellationError`, and one throwing `URLError(.cancelled)`, during an upload and a download → the queue item reads cancelled, not "Connection lost"; a real transport failure (`URLError(.networkConnectionLost)`) still reads "Connection lost". The throughput probe's and the multipart abort's handling of cancellation (2026-09-19) must stay as they are — run their suites.
- [x] Whole suite, zero warnings. Commit `fix(s3): a cancelled transfer reads as cancelled, not as a lost connection`.

---

### Task 2: The `EditSessionManager` flake has a root cause

**Row:** "The flake `EditSessionManagerTests.twoFastChangesTriggerSingleUpload`".

- [x] Systematic debugging: read the test and `EditSessionManager`'s debounce/upload path; form a hypothesis about how two fast changes can yield two uploads (a timer, a file-system event coalescing boundary, a main-actor ordering); reproduce it deterministically (repeat the test under load, e.g. alongside a CPU-bound loop, and record the rate), then confirm the cause with the smallest instrumented change.
- [x] Fix the cause — in the product if the product can upload twice for one burst a user would consider one change, in the test if the test encodes a timing assumption (then the test must assert the property without a wall-clock ceiling). State which, and why.
- [x] Prove it: the reproduction's rate before and after (e.g. N of M under the same load).
- [x] Whole suite, zero warnings. Commit `fix(edit): …` or `test(edit): …` naming the cause.

---

### Task 3: One subprocess runner

**Row:** "Task 2's deferred minors: the async key-tool surface" (its `SSHKeyConverter.waitForExit` item).

- [x] `SSHKeyConverter` (re-verify: `waitForExit(_:)` near `:116`) awaits its own `Process` with a private helper. Move it onto `SubprocessRunner` (`Sources/macSCPCore/Subprocess/`, `package` access, 2026-09-19) the way `SSHKeyGenerator`/`SSHKeyImporter` now use it; behaviour, error mapping and passphrase handling unchanged (read how the passphrase reaches `ssh-keygen` here and keep it exactly as private).
- [x] Tests: the existing converter tests green; the guard in `TestsNeverBlockThePoolGuardTests` (or a sibling) pins that no second runner shape remains in Sources (negative beside a positive that the converter uses the runner).
- [x] Whole suite, zero warnings. Commit `refactor(keys): the key converter awaits ssh-keygen through the shared runner`.

---

### Task 4: Closeout

- [x] `docs/BACKLOG.md`: each row named above gets a **Done 2026-09-19** sentence leading the row with its commits (history kept after it); anything recorded as open gets its own row. This plan's step boxes ticked. Commit `docs(backlog): the small follow-ups of 2026-09-19 are recorded`.

## Self-review

- Coverage: three open rows with no decision needed → Tasks 1-3.
- Placeholders: Task 2's fix location depends on its root cause, stated as a decision the implementer records.
