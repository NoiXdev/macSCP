# CI starvation of 2026-09-19 — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the three-core CI runner its margin back. Two CI runs on 2026-09-19 (35405472152 attempt 1: 32 issues; 35424079396: 306 issues) went red on time limits alone — pure-function tests waited more than 60 s for a thread — because CPU-bound tests hold every cooperative-pool thread for tens of seconds.

**Architecture:** Four tasks. Task 1 makes the source-scanning guards read one shared, once-computed corpus per test process instead of re-reading and re-blanking every file per test. Task 2 takes the two blocking `ssh-keygen` waits in Sources off the cooperative pool. Task 3 shrinks the one O(n²) test. Task 4 is the closeout. The measurement this rests on is the local `sample` of 2026-09-19 (cooperative-pool thread time 46.2 s CPU, of which 33.8 s in source-scanning guards; the table of holders is recorded in the BACKLOG row "CI red 35405472152" — read it first).

**Tech Stack:** Swift 6 strict, SwiftPM (Xcode 27 / Swift 6.4 locally; CI Swift 6.1.2, macos-15, three cores, zero-warning budget), Swift Testing.

## Global Constraints

- A guard that loses sensitivity is a regression: every guard touched keeps its probe red (plant, red, revert with a file-scoped reverse patch verified by `cmp`, green) — a table in the report. Guards read `SwiftSource.blankingCommentsAndStrings` (App) / the Core equivalent; a negative check keeps a positive beside it; scope (what a guard scans) must not shrink — compare the scanned file list before and after.
- Tests never block the cooperative pool; no wall-clock ceiling; no `#require` on a non-optional. Nothing new may compile only on Swift 6.4.
- Measure, do not guess: record the cooperative-pool CPU of the guard suites before and after with the same `sample` method (the 2026-09-19 method: `sample <pid> 25 5` on the Core test process, aggregated per outermost test function), and the full-suite wall time locally before and after.
- Subagents work in the FOREGROUND only. If the first build fails on a stale Metal toolchain path, delete the stale `XCBuildData` caches under `.build/out/Intermediates.noindex/` and rebuild.
- Zero compiler warnings. Conventional Commits, English, footer exactly `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. Do not push; do not launch the GUI; do not stage `docs/BACKLOG.md` before Task 4.

---

### Task 1: The source-scanning guards read one shared corpus

**Row:** the Bugs row about CI red 35405472152 (its "guard CPU cost" part).

- [x] Inventory: every guard test that reads files from `Sources/` or `Tests/` (both test targets) — how it lists files, reads them, blanks them, and which regexes it compiles per call. Record counts and the top CPU users (the 2026-09-19 table names `DiagnosticLogSecrecyGuardTests`, `PollingGuardTests`, `TestsNeverBlockThePoolGuardTests`).
- [x] One process-wide, lazily built, thread-safe corpus per test target: the file list per root, each file's text, and its blanked views, computed once (a `static let` of an immutable value is enough — no locks on the read path). Every guard reads through it. Regexes compiled once (static), not per file or per call.
- [x] Same scope: a test pins that the corpus's file lists equal what a direct directory walk finds (positive), so a guard cannot silently start scanning less.
- [x] Probe table for every converted guard; before/after pool-CPU numbers and full-suite wall time. Whole suite, zero warnings. Commit `test(guards): the source guards read one corpus built once per test process`.

---

### Task 2: `ssh-keygen` runs never park a cooperative-pool thread

**Row:** the same Bugs row (its `waitUntilExit` part).

- [x] `SSHKeyGenerator.swift` and `SSHKeyImporter.swift` (re-verify the anchors) wait for `ssh-keygen` with `Process.waitUntilExit()` on whatever thread calls them — from async code that is a cooperative-pool thread. Move the wait off the pool the way the project's subprocess runner already does (read `SubprocessRunner` and its readers; reuse it rather than writing a second one) so callers `await` without parking a thread.
- [x] Tests: behaviour unchanged (existing key tests green); a guard that no `waitUntilExit` remains in Sources outside the sanctioned runner (negative beside a positive that the runner is used). The `TestsNeverBlockThePoolGuardTests` scope note says it covers only `Tests/` — add Sources coverage for `waitUntilExit` if it fits that guard, or state why not.
- [x] Whole suite, zero warnings. Commit `fix(keys): ssh-keygen runs are awaited without parking a thread`.

---

### Task 3: The audit log's rolling-cap test stops being quadratic

**Row:** the same Bugs row (its `AuditLogStore` part).

- [x] `AuditLogStoreTests.rollingCapKeepsNewest` appends 1001 events, each rewriting the whole log (7 s locally, 46–55 s on CI). Make the cap injectable (production default unchanged) and test the property with a small cap; keep one test that the production default is the documented value. Decide whether the production append should stop rewriting the whole file per event: measure the cost at the default cap, and change it only if a real user path pays it (state the numbers either way; if unchanged, record it as open).
- [x] Whole suite, zero warnings. Commit `test(audit): the rolling cap is tested at a small cap`.

---

### Task 4: Closeout

- [x] `docs/BACKLOG.md`: the CI-red row's parts get **Done 2026-09-19** sentences with commits and the before/after numbers; what remains (the production `DispatchQueue.global()` deadline weakness, the bcrypt test cost, anything measured but not changed) stays open in its own row. This plan's step boxes ticked. Commit `docs(backlog): the CI starvation fixes of 2026-09-19 are recorded`.

## Self-review

- Coverage: the three measured holder classes (guards, `waitUntilExit`, the O(n²) test) → Tasks 1-3. The production deadline weakness is deliberately not in this plan (it needs its own design: what a diagnostics deadline should be when the process is saturated).
- Placeholders: Task 3's production change is conditional on a measurement, stated.
