# Diagnostic Log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A diagnostic log the app writes to `~/Library/Logs/macSCP/`
at a level the user picks in Settings (Off / Errors / Info / Debug),
instrumented so a listing that takes five minutes names the entry that
took them.

**Architecture:** Core gains `DiagnosticLog` (a shared sink with a
level, a lock-protected buffer and one writer task; `log` never touches
the disk on the caller's path) and `DiagnosticLogLevel`. The App gains
`SettingsStore.diagnosticLogLevel`, a General-pane row, and the launch
wiring. The instrumentation lands where the events happen: the local
and remote listing, the connect phases, the SFTP wrapper, transfers,
and the App's error mapping. A secrecy guard scans every call site.

**Tech Stack:** Swift 6 strict, Swift Testing, SwiftUI, `FileHandle`,
`ISO8601DateFormatter`, `SettingsStore`, the four catalogs.

**Spec:** `docs/superpowers/specs/2026-09-04-diagnostic-log-design.md`
(the tester's report against 1.3.0, the two hypotheses, the line format,
what is never logged).

## Global Constraints

- English only in the tree; user-facing strings only via `L10n.string` in all four catalogs (`en`, `de`, `fr`, `pl`; German du); Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; commit per task; zero warnings; do not push.
- **Never logged, at any level:** passwords, passphrases, private keys, tokens, presigned URLs, transfer bytes, host keys (the decision and the key TYPE only). The guard in Task 3 enforces the spelling; the reviewer enforces the meaning.
- `log` never blocks the caller and never evaluates its message when the level drops it (`@autoclosure`); the writer is one task; the file is opened once per day, appended, and closed on `configure(level: .off)`.
- Line format exactly: `<ISO 8601 with fractional seconds and offset> [<level>] <category> <text>` — one line per call; a message containing a newline is written with the newline replaced by `⏎`.
- Red first; no `#require` on a non-optional; no wall-clock ceiling; tests never block the pool (the flush is awaited through the sink's own `flush()`); every negative source check has a positive beside it; a number in a comment is counted; comments describe scanned code in prose.
- Do NOT launch the GUI; the dev build is the maintainer's sight check.

---

### Task 1: The sink

**Files:**
- Create: `Sources/macSCPCore/Diagnostics/DiagnosticLog.swift` (`DiagnosticLogLevel` — `off, error, info, debug`, `Comparable` by declaration order, `RawRepresentable` by name, `CaseIterable`; `DiagnosticLog` — `shared`, `configure(level:directory:)` (directory defaults to `~/Library/Logs/macSCP`), `log(_:_:_:)`, `flush() async`, `currentFileURL: URL?`; a `Mutex`/`NSLock`-protected state: level, buffer `[String]`, file handle, the date the handle is for; the writer task drains the buffer, opens `macSCP-<yyyy-MM-dd>.log` when the day changes, appends; `configure` prunes files older than 7 days matching `macSCP-*.log`)
- Test: `Tests/macSCPCoreTests/DiagnosticLogTests.swift` — against a temporary directory (`FileManager.default.temporaryDirectory` + UUID, removed in a `defer`): a `debug` line is absent at `.info` and present at `.debug`; at `.off` nothing is written and no file is created; the autoclosure of a dropped line is never evaluated (a counter in the closure); three lines in call order are three lines in file order; the line format matches the regex `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2} \[info\] browser\.local list start path=/x$`; a message with `\n` is written with `⏎`; rotation: create `macSCP-2026-08-20.log` and `macSCP-2026-09-01.log` in the directory, `configure` at a fixed `now` of 2026-09-04 (inject `now` through a parameter defaulting to `Date()`), the first is gone and the second stays; `configure(level: .off)` after lines were written closes the handle (a subsequent line creates no new file).

- [x] **Step 1: Red first** — `cannot find 'DiagnosticLog'`.
- [x] **Step 2: Implement**; `swift test --filter DiagnosticLog` green; full `swift test`; zero warnings.
- [x] **Step 3: Commit** `feat(diagnostics): a diagnostic log with a level, written off the caller's path`.

---

### Task 2: The setting, the pane row, the launch wiring

**Files:**
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift` (`diagnosticLogLevel: DiagnosticLogLevel`, default `.off`, stored by raw value under `Keys.diagnosticLogLevel`; an unknown stored value reads as `.off`)
- Modify: `Sources/MacSCPAppKit/SettingsView.swift` (General pane: a `Picker` labelled `settings.general.diagnosticLog` = "Diagnostic log" with the four levels labelled `settings.general.diagnosticLog.off|errors|info|debug`, a caption with the folder path, a button `settings.general.diagnosticLog.reveal` = "Show in Finder" calling `NSWorkspace.shared.activateFileViewerSelecting([folderURL])`)
- Modify: `Sources/MacSCPAppKit/MacSCPApp.swift` (at launch, beside the what's-new decision: `DiagnosticLog.shared.configure(level: store.diagnosticLogLevel)` then `log(.info, "app", "launch version=… build=…")`; `onChange` of the setting reconfigures; on `NSApplication.willTerminateNotification` an `app quit` line and `flush`)
- Modify: the four catalogs (de: "Diagnoseprotokoll", "Aus", "Fehler", "Info", "Debug", "Im Finder zeigen"; fr, pl)
- Test: `SettingsStoreTests` (default `.off`, round trip, an unknown raw value reads `.off`); `SettingsViewDiagnosticLogGuardTests` shaped like `SettingsViewAppearanceToggleGuardTests` (the picker is bound to `diagnosticLogLevel` and labelled through the key; the reveal button exists; negative: no `Text("` literal in the row, beside the positive); catalogue equality for the `settings.general.diagnosticLog` keys; a launch-wiring guard: `MacSCPApp.swift` calls `DiagnosticLog.shared.configure(` and logs `launch`.

- [x] **Step 1: Red first** — the store test (`diagnosticLogLevel` missing), the guards.
- [x] **Step 2: Implement**; green; zero warnings.
- [x] **Step 3: Commit** `feat(settings): the diagnostic log has a level, a folder, and a way to find it`.

---

### Task 3: The instrumentation, and the secrecy guard

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift` (`list`: `info` start / done with count and ms / failed with the mapped reason; per entry, measure `item(for:)` with `ContinuousClock` and log `debug` `entry slow name=… ms=…` when ≥ 500 ms — the threshold a `static let` with its reason)
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` (the remote listing's start / done / failed, category `browser.remote`, the backend kind if reachable there; else in the place that calls `fs.list` — find it)
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` (`connect start`, the phases the model already distinguishes — read it: resolve, tcp, auth, host key — `connect done ms=…`, `connect failed reason=…` with the mapped reason, `disconnect`; the auth METHOD name and the host-key DECISION only)
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift` (every protocol method — count them at HEAD, 12 by `grep -c` of the `RemoteFileSystem` methods it implements — logs `debug` `sftp <op> path=… ms=… ok` / `failed reason=…`; one private helper `measured(_ op: String, path: String, _ body:)` so the twelve sites are one shape), `CitadelShell.swift` (shell open / close at `debug`), the keep-alive tick if one exists (`grep -rn keepAlive Sources/macSCPCore`)
- Modify: `Sources/macSCPCore/RemoteFS/TransferEngine.swift` (transfer start / done / failed at `info` with direction, path, bytes, ms)
- Modify: the App's error mapping — find the one place a thrown error becomes a user-facing message for the browser (`ContentView+Detail.swift` or `BrowserPane.swift`; grep `sidebarErrorBanner\|errorMessage =`) — `error` lines with the mapped text
- Test: `Tests/macSCPCoreTests/DiagnosticLogSecrecyGuardTests.swift` — over every `.swift` in `Sources/`: collect every `DiagnosticLog.shared.log(` call's brace-balanced argument text (comment-and-string-blanked for the SCAN of interpolations, un-blanked for the category literal); negative: no interpolation `\(…)` in any call names an identifier matching `password|passphrase|secret|token|privateKey|presigned|fingerprint` (case-insensitive); positives beside it: the call-site count is ≥ 20 (count them when writing; write the count into the guard's doc comment and into the backlog row) and every category literal is one of a fixed list (`app`, `browser.local`, `browser.remote`, `connect`, `sftp`, `shell`, `transfer`, `error`); `LocalFileSystemTests`: listing a temporary directory writes `list start` and `list done count=<n>` to a sink configured into a temporary folder at `.info`, and no `entry slow` line at `.debug` for three plain files (the threshold is not crossed — assert the ABSENCE beside the presence of `list done`); `ConnectionDiagnosticsTests`-adjacent: none (the connect phases are covered by the guard's category list and by reading).
- Modify: `docs/BACKLOG.md` (a new row "Diagnostic log, and the home-folder listing that never finishes": the tester's report, the two hypotheses, what the log records, the call-site count, what the dev build should show — Settings › General › Diagnostic log = Debug, open the local home folder, then Show in Finder and read the `browser.local` lines), `README.md` (one sentence: the app can write a diagnostic log; no tech-stack terms).

- [x] **Step 1: Red first** — the secrecy guard red on zero call sites (its positive), the `LocalFileSystemTests` case red on the missing lines.
- [x] **Step 2: Implement**; `swift test` green; zero warnings; `MACSCP_ITEST=1 swift test --filter Citadel` green against the rig (the SFTP lines must not change any behaviour).
- [x] **Step 3: Commit** `feat(diagnostics): listings, connects, SFTP requests and transfers write to the diagnostic log`.
