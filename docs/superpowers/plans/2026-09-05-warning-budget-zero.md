# Warning Budget Zero Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The one warning CI still prints is gone, and the CI gate's
budget drops from 1 to 0 so the next warning fails the run.

**Architecture:** Measured 2026-09-05 on CI run 33922934415 (Swift
6.1.2, macos-15): exactly one unique warning location,
`Sources/MacSCPCLI/MacSCPCLI.swift:82:37` — "non-sendable result type
'any ParsableCommand' cannot be sent from nonisolated context in call
to static method 'asyncParseAsRoot'". The local toolchain (Swift 6.3.3)
prints none, so the fix is verified on CI, not locally. The gate is
`MAX_WARNINGS: 1` in `.github/workflows/ci.yml:39`, counting unique
`file:line:column` locations across the build and test logs.

**Tech Stack:** Swift 6 strict, swift-argument-parser
(`asyncParseAsRoot`), GitHub Actions.

**Spec:** the maintainer's "warnings chip" item (2026-09-04) and the
CI measurement above.

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; commit per task; zero warnings; do not push.
- The CLI's behaviour does not change: every `CLIMatrix` case and the ungated CLI tests stay green; `main()` still parses, runs and maps exit codes exactly as before.
- The fix is verified on CI (the local toolchain cannot show the warning): the task's commit is pushed by the coordinator, and only when the CI log prints `Unique warning locations: 0` does the budget commit follow — two commits, so a wrong fix does not also break the gate.

---

### Task 1: The warning, and the budget

**Files:**
- Modify: `Sources/MacSCPCLI/MacSCPCLI.swift:82` (the `asyncParseAsRoot()` call: keep the parsed command out of a cross-isolation send — e.g. parse and run inside one `@MainActor`-isolated or one nonisolated async context so the `any ParsableCommand` never crosses an isolation boundary; the diagnostic names the boundary, read `main()` for where the value travels; whichever shape compiles warning-free on Swift 6.1.2 — argument-parser 1.5's `asyncParseAsRoot` returns a non-`Sendable` existential, so the value must be consumed where it is produced)
- Modify (second commit, after CI confirms): `.github/workflows/ci.yml:39` (`MAX_WARNINGS: 0`)
- Test: none new (a warning is not testable in-tree); `swift test --filter CLI` green locally; the coordinator reads the CI log's `Unique warning locations:` line for the pushed commit.

- [ ] **Step 1:** the source change; `swift build --build-tests` zero warnings locally; `swift test --filter "CLI"` green; commit `fix(cli): the parsed root command is run where it is parsed, so nothing non-sendable crosses an isolation boundary`.
- [ ] **Step 2 (coordinator):** push; read the CI log: `Unique warning locations: 0`.
- [ ] **Step 3:** `MAX_WARNINGS: 0`; commit `ci: the warning budget is zero`; push; CI green.
