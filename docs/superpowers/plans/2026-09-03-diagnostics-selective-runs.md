# Diagnostics: Run One Probe, and a Trace That Reads as a Table — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Maintainer feedback on the dev build (2026-09-03): the panel
is right as it is, but (1) a single probe should be startable without
the whole diagnosis — a menu beside Run: complete, ping, trace, dial,
protocol probes — and (2) the trace row's hop list is hard to read as
one detail line; it should render as a table (hop, address, RTT,
outcome).

**Architecture:** Core gains `DiagnosticScope` (`.complete`, `.ping`
= resolve + TCP + ICMP, `.trace` = resolve + trace, `.dial` = resolve +
dial, `.contributions` = resolve + the protocol probes) as a parameter
of `ConnectionDiagnostics.run(scope:onStep:)` (default `.complete`; the
existing call stays); the runner skips the steps outside the scope with
no row for them (a scoped report says its scope in the header and in
the copied text). The trace step's hops are carried structurally on the
step (`DiagnosticStep.table: [[String]]?` with a header row — or a
`NetworkTraceHop` list on a typed payload; choose the smaller change
that keeps `DiagnosticStep` `Sendable`/`Equatable`), and the panel
renders a table when it is present, the detail line otherwise; the
copied Markdown renders the same table as a Markdown table, the plain
text as aligned columns.

**Tech Stack:** SwiftUI `Table`/`Grid`, Swift Testing; the doors guard on
`SwiftSource` views.

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; commit per task; zero warnings; do not push.
- Diagnostics still run only on the button — the scope menu changes what Run does, never starts anything by itself (the doors guard keeps its automatic-start checks over the new control).
- No secret and no URL the module did not build in any cell; the hop table's address column is the answering hop's address as measured.
- Display strings through `L10n.string(_:_:)`; four App catalogs (`en`/`de`/`fr`/`pl`), German du; keys `diagnostics.scope.complete/ping/trace/dial/contributions` and `diagnostics.trace.column.hop/address/rtt/outcome`.
- No wall-clock ceilings in tests; no `#require` on non-optionals (CI's compiler is Swift 6.1.2); every `#expect` in the test body.

---

### Task 1: Scope in Core

**Files:**
- Modify: `Sources/macSCPCore/Diagnostics/ConnectionDiagnostics.swift` (`DiagnosticScope`, `run(scope:onStep:)`, the step list filtered by scope, `DiagnosticReport.scope`), `DiagnosticReport.swift` (scope in the header of both renderers: "Scope: ping" — omitted for complete)
- Test: `ConnectionDiagnosticsTests` — each scope runs exactly its steps in order (fake probes recording calls), the report names the scope, `.complete` unchanged (the existing tests stay green byte for byte).

- [ ] Red first, implement, commit `feat(diagnostics): a diagnosis can run one probe instead of all of them`.

### Task 2: The hop table

**Files:**
- Modify: `Sources/macSCPCore/Diagnostics/DiagnosticStep.swift` (`table: DiagnosticTable?` — `struct DiagnosticTable: Sendable, Equatable { let columns: [String]; let rows: [[String]] }`, column names are catalog KEYS the panel maps), `NetworkTrace.swift`/`ConnectionDiagnostics.swift` (the trace step carries its hops as rows: hop, address or `*`, RTT in ms or `—`, outcome), `DiagnosticReport.swift` (Markdown table; plain text aligned)
- Test: the trace step's table from the fake hop source (three hops incl. a silent one); the renderers' output pinned on a hand-built report.

- [ ] Red first, implement, commit `feat(diagnostics): the trace carries its hops as a table`.

### Task 3: The panel — scope menu and the table

**Files:**
- Modify: `Sources/MacSCPAppKit/DiagnosticsPanel.swift` (a `Picker`/`Menu` beside Run with the five scopes, remembered per panel while open; the trace row renders `DiagnosticTable` as a SwiftUI `Table` or `Grid` under the row, the detail line stays for rows without a table), `Presentation/DiagnosticsViewModel.swift` (`scope` state passed to the runner), four catalogs
- Test: view-model (`run()` passes the chosen scope; default complete); `DiagnosticsDoorsGuardTests` — the scope control is wired to the view model and starts nothing by itself (positive anchor: it sets `scope`; negative: no `run(` in its action, on the strict view); the table rendering is wired to `DiagnosticTable` (positive anchor) and never re-splits the detail line (negative); catalogs complete.

- [ ] Red first, implement, `swift test --filter Localiz`, `GermanAddressForm`, full suite; commit `feat(diagnostics): choose what to run, and read the trace as a table`.

### Task 4: Closeout

- [ ] `docs/superpowers/specs/2026-08-25-backlog-connection-tools.md` gains a dated paragraph; `docs/BACKLOG.md` row updated; commit `docs(backlog): diagnostics run one probe and show the trace as a table`.
