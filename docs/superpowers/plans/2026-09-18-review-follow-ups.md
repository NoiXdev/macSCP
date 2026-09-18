# Review follow-ups of 2026-09-18 — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the open technical rows the last three plans' reviews left behind that need no maintainer decision: forwarding report precision, two dial and store failure gaps, a live dialog count, the terminal follow-ups, and one shared source scanner for the App test guards.

**Architecture:** Ten tasks. Tasks 1-3 are the forwarding rows (reports, the CLI's generic reason, bind-failure detail). Task 4 is the dial failure path's event-loop release. Task 5 strengthens the forwarding path's no-SFTP pin. Task 6 surfaces an unreadable managed key store. Task 7 is the login-set dialog's live count. Task 8 is the terminal follow-ups. Task 9 converges the App tests' source scanners. Task 10 is the closeout. Every task names its `docs/BACKLOG.md` row by title; read the row first — it carries the measured facts and file:line anchors (re-verify them with `grep -n`; several moved).

**Tech Stack:** Swift 6 strict, SwiftPM (Xcode 27 / Swift 6.4 locally; CI Swift 6.1.2 with a zero-warning budget), Swift Testing, SwiftUI/AppKit, SwiftTerm, SwiftNIO, Citadel fork 0.12.1-noix.3, the Docker rig (from the MAIN checkout).

## Global Constraints

- Maintainer, 2026-09-17: "erstmal weiter bauen", and 2026-09-18: "danach dann gerne weiter im backlog" — no release, no cleanup, the "At login" measurement later. Left out on purpose because they need a maintainer decision: "A forwarding that fails every connection still shows a green glyph and badge" (threshold), "A stale own jump slot wins over the managed key's slot…" (precedence), "An unattended CLI run may need a second Keychain consent" (needs a signed-binary measurement).
- TOFU is a hard stop; no accept-anything path; no secret in any store, state, log, reason, notification text or test message; no real host names in tests; the rig from the MAIN checkout only.
- Swift Testing, red first (recorded); tests never block the cooperative pool (every wait an `await`); no wall-clock ceiling (inject deadlines and clocks; `.timeLimit` only as a hang bound); no `#require` on a non-optional. Nothing new may compile only on Swift 6.4 (CI runs 6.1.2).
- Every App string through `L10n.string(_:_:)` in `en`, `de`, `fr`, `pl` (German du-form); plurals through `Localizable.stringsdict`; Core-layer user-facing text through `CoreL10n` where it must live in Core.
- The CLI's JSON output is read by scripts: add keys, never rename or remove one.
- Source-scanning guards read `SwiftSource.blankingCommentsAndStrings`; a negative check has a positive beside it. Comments naming counts or callers are counted in the same pass. Scripted edits assert their anchor; probes are reverted with a file-scoped reverse patch verified by `cmp`; reports are written from `git diff --numstat` and `grep -n`.
- Subagents work in the FOREGROUND only (background-command notifications never reach them). The Bash tool's timeout is the only timeout (`timeout` is not installed). If the first build fails on a stale Metal toolchain path after a reboot, delete the stale `XCBuildData` caches under `.build/out/Intermediates.noindex/` and rebuild (measured 2026-09-18).
- Zero compiler warnings (`swift build --build-tests` after touching every changed file; the SwiftPM "missing creator for mutated node" line is known noise). Conventional Commits, English, footer exactly `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. Do not push; do not launch the GUI; do not stage `docs/BACKLOG.md` or `docs/superpowers/specs` before Task 10.

---

### Task 1: Forwarding reports say the same thing for the same event

**Rows:** "A SOCKS5 reply write's own handler-removal failure is no longer reported"; "A stop race in `RemoteForward.swift` reports the same stop inconsistently, and a reconnect can show a transient failure count"; "A per-connection failure logged while a forward is torn down prints `port=-`".

- [ ] SOCKS5: in `LocalForwardListener.accepted`'s `catch where replying` branch, tell the confirm write's failure (the client's, not reported — the maintainer's ruling) apart from `SOCKS5Handshake.succeed`'s own `removeHandler` failure (internal, reported through `onFailure`). Failing tests first: a removal failure is reported once; a confirm-write failure still is not.
- [ ] `RemoteForward.swift`: both "the forward has been stopped" stop races are treated the same — a stop is never a connection failure. Test each race through the existing seams; neither calls `onConnectionFailure`.
- [ ] Transient count: a connection failure caused by the SSH connection dropping mid-flight must not show "N connections failed" before `.reconnecting`. Decide from the report stream's order what the runner can know (read `TunnelRunner`'s report handling); state the rule in the report. Test: a drop with an in-flight connection goes straight to `.reconnecting` with no intermediate failure count.
- [ ] `TunnelRunner`: the per-connection failure `debug` line reads the port captured when the forward started (as the `active` line does), so a report drained during `releaseCurrent()` logs the real port. Test through the log seam.
- [ ] Whole suite, zero warnings. Commit `fix(tunnels): a stop is never a connection failure, and a drained report logs its port`.

---

### Task 2: `tunnels start --json` says when its reason is generic

**Row:** "`tunnels start --json` falls back to the kind's generic sentence when the runner holds no reason".

- [ ] Measure first: which production paths reach `.failed` without a `failureReason` (read `TunnelRunner`'s writes of the state and the reason). Write the answer, with file:line, into the report.
- [ ] The `failed` JSON object gains a key `"reasonIsGeneric"` (Bool, always present on a `failed` line): `true` when `reason` fell back to `kind.sentence`. `reason` keeps its current value (scripts read it). The text line is unchanged. Tests: a runner with a reason → `false`; without → `true`; the key set of the `failed` object is pinned.
- [ ] If the measurement finds no production path to a reasonless `.failed`, add a test that pins that for the runner paths read, beside the JSON change.
- [ ] Update the CLI's `--json` documentation where the `failed` object's keys are listed (grep `docs/` and the CLI help text for the key list). Whole suite, zero warnings. Commit `feat(cli): a failed tunnel line marks a generic reason`.

---

### Task 3: A local bind failure keeps its cause in the App

**Row:** "A forwarding's local-bind failure message loses its errno/detail text on non-loopback and non-port-in-use failures".

- [ ] Measure which errors SwiftNIO throws for a local bind to an address this Mac does not have (`EADDRNOTAVAIL`) and to a refused port, on loopback-only tests (bind to a TEST-NET address such as 192.0.2.1 for the first; read, do not guess, what the second produces on macOS 15 without root — if it succeeds, say so and drop that case).
- [ ] Map each measured cause to its own `TunnelFailure` case (as `portInUse` is mapped from `EADDRINUSE` in `LocalForwardListener`), with a `TunnelFailureKind` and a translated fixed sentence on the App's four surfaces (the ones the row names; read how `portInUse`'s sentence reaches them). The log and the CLI keep the full detail text as today.
- [ ] Tests: each measured errno maps to its case; the App sentence for each comes from its catalogue key in all four languages (parity suites); an unknown errno still yields `bindFailed`.
- [ ] Leave the native-speaker review of the `de`/`fr`/`pl` strings open in the row (it is not something an implementer can close). Whole suite, zero warnings. Commit `fix(tunnels): a local bind failure names its cause in the app`.

---

### Task 4: A dial that fails partway outlives Citadel's login timer before releasing its group

**Row:** "A dial that fails partway shuts the agent-auth group down while Citadel's login timer may still be pending".

- [ ] Read `CitadelFileSystem.releaseAfterCitadelTimer`, its success-path callers (`CitadelFileSystem.swift`, `SSHForwardingConnection.swift`) and every failure path that shuts a dedicated event-loop group down today (grep `shutdownGracefully` in `Sources/macSCPCore/SSH`). List them in the report with file:line.
- [ ] Route every failure-path shutdown of a group that a Citadel handshake ran on through `releaseAfterCitadelTimer` (host-key rejection, auth failure, cancellation), for tabs and forwardings alike.
- [ ] Tests: through the release seam (inject the release function or observe it with a spy), a host-key rejection and an auth failure each release through the delayed path, never an immediate shutdown; a source guard pins that no `shutdownGracefully` on a dial group remains outside `releaseAfterCitadelTimer` in those files (positive check: the function exists and is called on each listed path).
- [ ] Whole suite plus the gated SSH suites (`MACSCP_ITEST=1`, rig from the main checkout), zero warnings. Commit `fix(connect): a failed dial releases its event loop only after Citadel's login timer`.

---

### Task 5: The forwarding path's "no SFTP" pin catches a background open

**Row:** "An SFTP open started in the background on the forwarding path would go unnoticed, its error never caught".

- [ ] Measure first why `theForwardingPathOpensNoChannelWhereTheTabPathOpensOne` misses the review's probe B (an `openSFTP` started in a background task): plant it, run the test, record the outcome and the reason (likely the channel count is read before the request reaches the fake server). Revert with `cmp`.
- [ ] Rebuild the check so it reads after an ordering point, not after a race: e.g. disconnect the forwarding connection and await the fake server's observation of the connection close — any channel request sent before the close has been processed by then, because SSH messages on one connection are ordered. Then assert zero SFTP subsystem requests. No sleeps, no wall-clock ceiling.
- [ ] Prove sensitivity by repetition: probe B red in 10 of 10 runs of the rebuilt test (record the count), and the unmodified tree green.
- [ ] Whole suite, zero warnings. Commit `test(forwarding): the no-SFTP pin reads after the connection has closed`.

---

### Task 6: An unreadable managed key store is named when it costs a connection

**Row:** "A corrupt `managed_keys.json` surfaces only as a missing passphrase".

- [ ] Keep the deliberate behaviour: an unreadable store still answers nil, so sessions whose key it does not manage are not stopped.
- [ ] Add: the source records that the store was unreadable (no key material, no file content — only the fact and the decode error's type name) in the diagnostic log once per read, and a connection that then fails for a missing passphrase of a MANAGED key says the key store could not be read — a new catalogue key (e.g. `core.connect.managedKeyStoreUnreadable`, four languages) on the App surface, a fixed `DialSupport.reason` sentence, and the CLI's error line. Read how the current missing-passphrase failure travels to find where the fact can join it; state the path in the report.
- [ ] Tests: a corrupt store file plus a managed encrypted key → the failure names the store; the same corrupt store with an unmanaged key → unchanged behaviour; no test message or log line contains the file's content (named-constant rule from `CLAUDE.md`).
- [ ] Whole suite, zero warnings. Commit `fix(keys): a connection that fails on an unreadable key store says so`.

---

### Task 7: The login-set question counts what depends on the set when you answer

**Row:** "The login-set repoint question's session/jump count is captured when the dialog opens".

- [ ] The dialog's plural count (`connection.convertKey.repoint.message %lld %@`, `ContentView+Sheets.swift`) is read from the current sessions at render time, as the title already re-reads the set's current name; the request no longer carries a captured count (or carries only what cannot be re-read — state which).
- [ ] Tests: a pure function over the current sessions gives the count; a guard pins that the message formats that function's result, not a stored field (positive check beside the negative one).
- [ ] Whole suite, zero warnings. Commit `fix(login-sets): the repoint question counts at the moment it is shown`.

---

### Task 8: Terminal follow-ups for copy on select and paste on right click

**Row:** "Task 6's review deferred minors: terminal copy on select / paste on right click".

- [ ] Paste on right click fires from the real right mouse button (`rightMouseDown(with:)`, and Control-click through `mouseDown` if SwiftTerm swallows it — read SwiftTerm's `MacTerminalView` and state what reaches which method), not from `menu(for:)`; `menu(for:)` keeps returning the snippet menu (Option-right-click while paste is on) and never pastes, so a synthetic menu request (VoiceOver's "show menu") opens the menu instead of pasting. Tests through `TerminalRightClickPlan` and a guard on the hooks.
- [ ] The copy-pasteboard reassignment guard also scans the terminal view's own file and derives the file name instead of spelling it.
- [ ] The right-click tests release their named pasteboards (`releaseGlobally()`).
- [ ] Copy on select builds the selection text only when a selection gesture ended with a changed selection, not on every click (keep the existing "changed selection" rule and its test).
- [ ] Whole suite, zero warnings. Commit `fix(terminal): right-click paste follows the real mouse button`.

---

### Task 9: One source scanner for the App test guards

**Rows:** "Task 5's review deferred minor: a duplicated dialog scanner"; "[Polish: terminal resize, transfer cancel and paths]" (the four comment/string strippers in `Tests/macSCPAppKitTests`).

- [ ] Count the strippers and dialog scanners in `Tests/macSCPAppKitTests` and `Tests/macSCPCoreTests` (grep for functions that remove or blank comments and string literals, and for the confirmation-dialog span scanners); list them with file:line in the report.
- [ ] Converge the App test target on `SwiftSource.blankingCommentsAndStrings` / `blankingComments` (the App-side `SwiftSourceStripping.swift`), and the dialog guards on one scanner. The Core test target's older `stripCommentsAndStrings` stays unless it can move without widening this task — say which, and why.
- [ ] Every converted guard keeps its sensitivity: re-run each converted guard's own probe (or plant one per guard) and record red → revert (`cmp`) → green. A guard whose probe goes green after conversion is a regression, not a simplification.
- [ ] Whole suite, zero warnings. Commit `test(guards): the app guards read source through one scanner`.

---

### Task 10: Closeout

- [ ] `docs/BACKLOG.md`: each row named above → Done 2026-09-18 with its commits (the file's convention: the row's text stays, a **Done** sentence is appended); new rows for anything the tasks recorded as open; the sight checks this plan adds join the grouped sight-check row. This plan's `- [ ]` step boxes ticked (not the header line). Commit `docs(backlog): the review follow-ups of 2026-09-18 are recorded`.

## Self-review

- Coverage: every open technical row that needs no maintainer decision and is not a pure sight check → Tasks 1-9; the three left out are named in the Global Constraints with the reason.
- Placeholders: Tasks 1 (transient-count rule), 2 (reasonless paths), 3 (errno set), 4 (failure paths), 5 (miss reason) and 6 (the fact's path) start with a measurement whose result the implementer writes down; the fix is specified by its observable outcome.
- Type consistency: `TunnelFailure`/`TunnelFailureKind`, `releaseAfterCitadelTimer`, `TerminalRightClickPlan`, `SwiftSource.blankingCommentsAndStrings` are named as they exist at `864e103e`.
