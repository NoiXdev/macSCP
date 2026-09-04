# Diagnostics Running Step Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While a diagnosis runs, the panel's running line names the
step in flight — "Name resolution · measuring…" — instead of the bare
"Measuring…" it shows today.

**Architecture:** `ConnectionDiagnostics.run(scope:onStep:)` hands a
step over only when it has FINISHED (`DiagnosticStepObserver`); nothing
announces a start. The observer grows a second entry point —
`onStepStarted(id:titleKey:)`, called just before each step's timer
starts — carried by a small `DiagnosticRunObserver` value so the
existing `onStep` callers (the app's view model, the CLI's `diagnose`)
keep compiling. `DiagnosticsViewModel` keeps `runningStepTitleKey`; the
panel's measuring line renders the step's title (the existing
`diagnostics.step.<id>` keys) with a new `diagnostics.running.step`
format in four catalogs. The CLI prints nothing on start (its rows are
the finished steps, by design).

**Tech Stack:** Swift 6 strict, Swift Testing, SwiftUI; the diagnostics
module (`Sources/macSCPCore/Diagnostics/`), `DiagnosticsViewModel`,
`DiagnosticsPanel`, the four catalogs.

**Spec:** `docs/BACKLOG.md`, row "Diagnostics: a running row names its
step" (maintainer feedback 2026-09-04 from dev build dev-a61df6bd).
Measured at HEAD 06baa7c4: `DiagnosticsPanel.swift:154-155` renders
`ProgressView` + `L10n.text("diagnostics.running", "Measuring…")` when
`model.isRunning`; `DiagnosticsViewModel` has no notion of the current
step; `ConnectionDiagnostics.run` (`ConnectionDiagnostics.swift:203`)
takes `onStep: @escaping DiagnosticStepObserver`, invoked once per
finished step.

## Global Constraints

- English only in the tree; user-facing strings only via `L10n.string` in all four catalogs (`en`, `de`, `fr`, `pl`; German du); Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; commit per task; zero warnings; do not push.
- The step's title is the catalogue key the step already carries (`titleKey`); no second copy of a step name anywhere.
- No secret or configuration text reaches the running line: it renders a title key and nothing from the endpoint.
- Red first; no `#require` on a non-optional; no wall-clock ceiling; tests never block the pool; the existing `DiagnosticsDoorsGuardTests` and `ConnectionDiagnosticsTests` stay green; comments naming callers checked (`run(scope:onStep:)`'s callers: the view model, the CLI, the tests — count them).
- A negative source-scanning check needs a positive check beside it; comments quoting code near an anchor move the anchor.

---

### Task 1: The start event, the view model, the panel line

**Files:**
- Modify: `Sources/macSCPCore/Diagnostics/ConnectionDiagnostics.swift` (a `public struct DiagnosticRunObserver: Sendable { public var onStepStarted: @Sendable (String, String) async -> Void; public var onStep: DiagnosticStepObserver }` with an init defaulting `onStepStarted` to a no-op; `run(scope:observer:)` as the new primary; `run(scope:onStep:)` kept as a one-line wrapper so the CLI and the tests keep compiling; every place a step's timer starts calls `observer.onStepStarted(id, titleKey)` first — count the sites: resolve, tcp, icmp, trace, dial, each contribution)
- Modify: `Sources/MacSCPAppKit/Presentation/DiagnosticsViewModel.swift` (`@Published private(set) var runningStepTitleKey: String?`, set on start, cleared when the step's finished row lands and when the run ends or is cancelled)
- Modify: `Sources/MacSCPAppKit/DiagnosticsPanel.swift:150-156` (the measuring line: `ProgressView` + `L10n.string("diagnostics.running.step", "%@ — measuring…")` formatted with `L10n.string(runningStepTitleKey)` when one is set, else the existing `diagnostics.running`)
- Modify: the four `Sources/MacSCPAppKit/Resources/*.lproj/Localizable.strings` (`diagnostics.running.step` — de: "%@ · Prüfung läuft…", du-register irrelevant here; fr, pl)
- Test: `Tests/macSCPCoreTests/ConnectionDiagnosticsTests.swift` (an observer that records start ids in order → for `.ping` the sequence `resolve, tcp, icmp` starts, each start precedes its own finished row, and a cancelled run announces no start after the cancellation), `Tests/MacSCPAppKitTests/DiagnosticsViewModelTests.swift` or the existing VM tests (start → `runningStepTitleKey` set; finished row → cleared; cancel → cleared), and `DiagnosticsDoorsGuardTests` (the measuring line reads `runningStepTitleKey` and the `diagnostics.running.step` key; catalogue-key equality across the four catalogs already covers the new key)

**Interfaces:**
- Produces: `DiagnosticRunObserver`, `ConnectionDiagnostics.run(scope:observer:)`, `DiagnosticsViewModel.runningStepTitleKey`.
- Consumes: `DiagnosticStepTimer`/`timer(for:)` (where each step starts), `DiagnosticStepID`, the step `titleKey`s.

- [x] **Step 1: Red first** — the Core observer test: `cannot find 'DiagnosticRunObserver'`; the VM test: no `runningStepTitleKey`; the guard: red on the missing key.
- [x] **Step 2: Implement**; `swift test --filter "ConnectionDiagnostics|DiagnosticsViewModel|DiagnosticsDoors|Localiz"` green; full `swift test`; zero warnings.
- [x] **Step 3: Commit** `feat(diagnostics): the running line names the step in flight`.
- [x] **Step 4:** `docs/BACKLOG.md` row → Done (the commit, the start-site count, the key) in the same commit.
