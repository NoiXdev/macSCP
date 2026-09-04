# `macscp-cli diagnose` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The connection diagnostics run from the terminal against a
stored session or a bare host, printing rows as steps finish, with a
`--json` shape and an exit code a script can branch on.

**Architecture:** Core gains a small rendering unit
(`Sources/macSCPCore/CLI/DiagnoseRendering.swift`: a step → text row, a
step → JSON object, a report → exit code) and a `ChainedSecretSource`
that turns the CLI's `[any SecretSource]` chain into the single source
`ConnectionDiagnostics` takes. The CLI gains `DiagnoseCommand`
(`Sources/MacSCPCLI/DiagnoseCommand.swift`), the seventh subcommand,
built the way `LsCommand` is: `GlobalOptions`, a session reference or
`--host/--port/--kind`, `--scope`, `--json`. The matrix gets its cases.

**Tech Stack:** Swift 6 strict, ArgumentParser, Swift Testing, the
Docker rig (`MACSCP_ITEST=1`), `ConnectionDiagnostics` (Core).

**Spec:** `docs/superpowers/specs/2026-09-04-cli-diagnose-design.md`.
Scheduled after the diagnostics leak-route fix (backlog row
"Diagnostics: error text as a leak route").

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; commit per task; zero warnings; do not push.
- No secret in argv, in a file, in any row, in any failure message; secrets travel in the child's environment in tests and through `SecretSource` in the process; a test that holds one computes its Bools before the expectation.
- Every child through `SubprocessRunner`; the rig only (127.0.0.1); every wait through `pollUntil` under a suite `.timeLimit`; no wall-clock ceiling.
- The CLI renders no reason text of its own: rows carry `DiagnosticStep.detail` and `DiagnosticOutcome` as Core delivers them (already `redacted`).
- Exit codes: `0` for ok/skipped/unavailable only; `CLIExitCode.diagnosis = 16` when any step is `failed` or `timedOut`; `usage` (2) for an unresolvable session or `--host` with `--scope dial`/`contributions`.
- The matrix's coverage guard (`everySubcommandTheBinaryOffersIsDrivenByACase`) must be red between Task 2 and Task 3 and green after — that red is Task 3's red-first.
- A number in a comment is counted; comments naming callers are checked (`ConnectionDiagnostics.init`'s callers gain one).

---

### Task 1: Core — `ChainedSecretSource` and `DiagnoseRendering`

**Files:**
- Modify: `Sources/macSCPCore/Sessions/CLISecretSources.swift` (append `ChainedSecretSource`)
- Create: `Sources/macSCPCore/CLI/DiagnoseRendering.swift`
- Modify: `Sources/macSCPCore/CLI/CLIExitCode.swift` (`case diagnosis = 16`, doc line)
- Test: `Tests/macSCPCoreTests/DiagnoseRenderingTests.swift`, `Tests/macSCPCoreTests/CLISecretSourcesTests.swift` (one case for the chain)

**Interfaces:**
- Produces:
  ```swift
  /// The CLI's secret chain as the one source `ConnectionDiagnostics` takes:
  /// the first source that answers non-empty wins, the same rule
  /// `SecretResolver` applies.
  public struct ChainedSecretSource: SecretSource {
      public init(_ sources: [any SecretSource])
      public var label: String   // the answering source's label after a hit, "none" before
      public func secret(for sessionID: UUID) throws -> String?
  }

  public enum DiagnoseRendering {
      /// One text row: `<id padded to 14>  <outcome word padded to 11>  <duration>  <detail>`;
      /// a trace step's hops follow as indented rows.
      public static func textRows(for step: DiagnosticStep) -> [String]
      /// One JSON object per step, keys: id, outcome, reason (absent for ok/timedOut),
      /// durationMs, detail, hops (trace only: [{hop, address, rttMs}]).
      public static func jsonObject(for step: DiagnosticStep) -> [String: Any]
      /// The final object: completion ("complete" | "running" | "cancelled"), endpoint (or null), steps.
      public static func jsonSummary(for report: DiagnosticReport) -> [String: Any]
      /// 0 for ok/skipped/unavailable everywhere; .diagnosis when any step failed or timed out.
      public static func exitCode(for report: DiagnosticReport) -> CLIExitCode
  }
  ```
- Consumes: `DiagnosticStep`, `DiagnosticOutcome`, `DiagnosticReport`, `DiagnosticTable` (the trace's table shape — read `DiagnosticStep.table`).

- [x] **Step 1: Red first.** Tests: a step with `.failed("x")` renders the outcome word `failed` and the reason; a trace step with two hops renders three rows; `jsonObject` carries `durationMs` as an integer and omits `reason` for `.ok`; `exitCode` is `.success` for a report of ok+skipped+unavailable and `.diagnosis` for one `.timedOut`; the chain answers the first non-empty source and skips an empty one (secret in a named constant, Bools first). Run: `swift test --filter "DiagnoseRendering|CLISecretSources"` — red: `cannot find 'DiagnoseRendering'`.
- [x] **Step 2: Implement** the three files.
- [x] **Step 3: Green**, full `swift test`, zero warnings.
- [x] **Step 4: Commit** `feat(cli): the diagnosis renders to rows, JSON lines and an exit code`.

---

### Task 2: The `diagnose` subcommand

**Files:**
- Create: `Sources/MacSCPCLI/DiagnoseCommand.swift`
- Modify: `Sources/MacSCPCLI/MacSCPCLI.swift:41-44` (`DiagnoseCommand.self` in `subcommands`)
- Modify: `Sources/MacSCPCLI/SessionConnecting.swift` (extract from `connect(to:options:)` the session-resolution head — store, reference, `secretSources`, — into `resolveSession(_:options:) -> (StoredSession, [any SecretSource])` so `diagnose` and `connect` share it; `connect` keeps its behaviour)
- Modify: `Sources/macSCPCore/CLI/CLIErrorMapping.swift` if the usage refusals need a case

**Interfaces:**
- Consumes: Task 1's `DiagnoseRendering`, `ChainedSecretSource`; `ConnectionDiagnostics(descriptor:values:secrets:sessionID:appVersion:)`; `BackendDescriptor.descriptor(for:)`, `.editBaseline`, `.sessionValues(_:)`; `DiagnosticScope` (`RawRepresentable`, so `@Option var scope: DiagnosticScope = .complete` with `ExpressibleByArgument`).
- Produces: `macscp-cli diagnose` with the two forms in the spec; `--scope` defaulting to `complete`; `--json`.

Behaviour:
- Session form: `resolveSession`, values = `editBaseline` merged with `sessionValues(stored)`, `sessionID = stored.id` (the login-set slot the app computes in `secretSlot` — read `ContentView+Diagnostics.secretSlot` and reproduce the rule, or expose it from Core if it is not there yet: say which in the report), secrets = `ChainedSecretSource(sources)`.
- Host form: `--host` required, `--port` optional, `--kind` default `.ssh`; values = `editBaseline` with the host/port fields set through the descriptor's field ids (read `DialProbes`/`BackendDescriptor.endpoint(_:)` to learn which fields carry them); `sessionID = nil`, `secrets = nil`; `--scope dial`/`contributions` → usage error before anything runs.
- Rows: `onStep` prints `DiagnoseRendering.textRows` (or the JSON object) as each step lands; after `run` returns, `--json` prints `jsonSummary`; the text form prints the report's completion line (`plainText()`'s last line — read it, do not reformat). Exit with `DiagnoseRendering.exitCode(for:)` through the same `Foundation.exit` path `MacSCPCLI.swift:84-90` uses.
- `--verbose` says which secret source answered, as `connect` does.
- `appVersion`: read the executable's version the way `MacSCPCLI` reports `--version` (find it); Core touches no bundle.

- [x] **Step 1: Red first.** `swift build --product macscp-cli` then `.build/debug/macscp-cli diagnose --help` — red: `Unknown subcommand`. After wiring, `.build/debug/macscp-cli diagnose --host 127.0.0.1 --port 2222 --scope ping` against the rig prints three rows (`resolve`, `tcp`, `icmp`) and exits 0 or 16 — record which and why (ICMP on loopback is the unmeasured cell).
- [x] **Step 2: Implement**; `swift build --build-tests` zero warnings; full `swift test` green EXCEPT the matrix's coverage guard, which is now red on `diagnose` — that is Task 3's red; say so in the report and commit anyway? No: the ungated guard must not be committed red. Order: implement Task 3's minimal coverage case in THIS commit only if the guard is ungated — read `CLIMatrixCoverage.everySubcommandTheBinaryOffersIsDrivenByACase` (it is gated on the binary; check) and decide: if it runs ungated, add the smallest `diagnose` case here and let Task 3 add the rest; state the decision in the report.
- [x] **Step 3: Commit** `feat(cli): macscp-cli diagnose runs the connection diagnostics from the terminal`.

---

### Task 3: The matrix cases and the docs

**Files:**
- Modify: `Tests/macSCPCoreTests/CLIMatrixITests.swift` (per backend: `diagnose <session> --scope ping --json` → JSON lines with ids `resolve`, `tcp`, `icmp`, exit 0 or 16 with the ICMP cell recorded; `diagnose <session> --scope dial --json` → the dial row `ok`, exit 0; one `diagnose --host 127.0.0.1 --port 2222 --scope trace --json` → a trace row with `hops` (any count ≥ 0) and a named ending; usage refusals: unknown session → exit 2, `--host … --scope dial` → exit 2, both without a connection)
- Modify: `Tests/macSCPCoreTests/Support/CLIMatrix.swift` only if the helper needs a JSON-lines-to-objects reader it lacks (it has `listing` for `ls`; a generic `jsonLines(_:)` may already exist — read first)
- Modify: `README.md` (the CLI section: one line and the two forms), `docs/BACKLOG.md` (a Done row naming this plan, the cases per backend counted, the ICMP-on-loopback measurement, the commits)

- [x] **Step 1: Red first.** `MACSCP_ITEST=1 swift test --filter CLIMatrix` — the coverage guard red on `diagnose` (if Task 2 did not already satisfy it), the new cases red because they do not exist.
- [x] **Step 2: Implement**; gated matrix green (count: 55 + the new cases); full `swift test` green; rig as found (diagnose creates nothing remote).
- [x] **Step 3: Commit** `test(cli): diagnose runs against every rig backend, and the docs say so`.
