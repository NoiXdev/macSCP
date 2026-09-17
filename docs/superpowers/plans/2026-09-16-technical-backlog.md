# Technical backlog of 2026-09-16 — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the open technical rows of `docs/BACKLOG.md` recorded between 2026-09-04 and 2026-09-16, with the four design choices the maintainer made on 2026-09-16.

**Architecture:** Nine independent tasks in dependency order. Tasks 1-5 are local correctness fixes with no model change. Task 6 changes the forwarding state model (typed failure); Task 7 builds on it (per-connection failures counted into the active state). Task 8 adds a forwarding connect path without an SFTP channel and a rig container to measure it. Task 9 is the closeout. Every task names its BACKLOG row(s) and ends with that row marked Done (in Task 9, from the commits).

**Tech Stack:** Swift 6 strict, SwiftPM (Xcode 27 / Swift 6.4 locally; CI runners macos-15 and macos-latest), Swift Testing, SwiftUI, SwiftNIO/Citadel fork 0.12.1-noix.3, the Docker rig (`docker compose -f docker/test-server/compose.yml up -d` from the MAIN checkout), GitHub Actions.

## Global Constraints

- Maintainer decisions of 2026-09-16, verbatim: per-connection forward failures → "Log + Zähler im Status" (each failure logged; the tunnel stays active but shows "active · N connections failed" with the last reason in the tooltip; a success resets the counter; no new lifecycle state); tunnel failure reasons → "Ja, typisiert + übersetzt" (the state carries the failure kind, the App translates in four languages, the log keeps the English sentence); SFTP channel on forwarding dials → "Ja, mit neuem Rig-Container" (forwardings connect without an SFTP channel; an extra sshd container without the SFTP subsystem proves it in a gated test; tabs keep the SFTP channel); CI and Xcode 27 → "Metal im CI installieren" (a step installs the Metal toolchain on runners whose Xcode needs it; the default build system stays).
- TOFU is a hard stop; no accept-anything path; no secret in any store, state, log, reason, test message; no key material committed; no real host names in tests; the rig from the MAIN checkout only.
- Swift Testing, red first (recorded); tests never block the cooperative pool (every wait an `await`, child processes via `SubprocessRunner`); no wall-clock ceiling (`.timeLimit` only; deadlines under test are injected, never measured against the runner); no `#require` on a non-optional.
- Every App string through `L10n.string(_:_:)` in `en`, `de`, `fr`, `pl` (German du-form), plurals through `Localizable.stringsdict` (`pl` one/few/many/other); Core-rendered log sentences stay English.
- Source-scanning guards read `SwiftSource.blankingCommentsAndStrings`; a negative check has a positive beside it. Comments naming counts or callers are counted in the same pass (grep for comments that describe a changed symbol in files the diff does not touch). Scripted edits assert their anchor; probes reverted with a file-scoped reverse patch; reports written from `git diff --numstat` and `grep -n`.
- Zero compiler warnings (`swift build --build-tests`; the SwiftPM "missing creator for mutated node" line is known noise). Conventional Commits, English, footer exactly `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. Do not push; do not launch the GUI.

---

### Task 1: CI installs the Metal toolchain where the runner's Xcode needs it

**Row:** "Xcode 27 / Swift 6.4" (added 2026-09-16).
**Files:** `.github/workflows/ci.yml`, `.github/workflows/release.yml` (the `build` job, before "Run tests"), `docs/BACKLOG.md` is Task 9's.

- [x] Add one step, identical in both jobs and placed before the first `swift build`/`swift test`, named `Metal toolchain (Xcode 26+)`: print `xcodebuild -version`; if `xcrun metal --version` succeeds, print it and stop; otherwise, if `xcodebuild -help` lists `-downloadComponent`, run `xcodebuild -downloadComponent MetalToolchain` and then `xcrun metal --version` (which must now succeed, else the step fails with a message naming the missing component); if the flag is not listed (an older Xcode that ships Metal in the toolchain), print that and stop. A comment above the step states the measurement of 2026-09-16 (Xcode 27 / Swift 6.4: `swift build` defaults to Swift Build, which compiles SwiftTerm's `Shaders.metal` and fails with "cannot execute tool 'metal' due to missing Metal Toolchain; use: xcodebuild -downloadComponent MetalToolchain") and that `scripts/package-app` pins the native build system for its own reason (both slices into one directory), so the release job needs this step only for "Run tests".
- [x] Verify locally what can be verified: `bash -n` on the step's script (extract it to a temp file), and run the script body on this machine (Metal present → it prints the version and stops). The runner behaviour is measured by the first CI run after push (coordinator).
- [x] Commit `ci: install the Metal toolchain on runners whose Xcode needs it`.
- [x] Done. Commits: `acd2fe40`, `712c23ea` (fix round 1 — SIGPIPE-safe `-help` capture via a bash glob match instead of `grep -q`, a guarded `::error::` on a failed download). 1 fix round.

---

### Task 2: A forwarding store that cannot be read is not rewritten from empty

**Row:** "`TunnelStore` writes rewrite an unreadable file from empty".
**Files:** `Sources/macSCPCore/Tunnels/TunnelStore.swift` (`upsert` :116, `delete` :126, `deleteAll` :143 go through `load()` :70); callers `Sources/MacSCPAppKit/TunnelManager.swift` (:198 `try? store.deleteAll`, :566 `upsert`, :575 `delete`) and `Sources/MacSCPCLI/StoreEditing.swift` (:202, :287); the sheet that shows a save failure; four App catalogs; the CLI error mapping.

- [x] Failing tests (Core): with a present-but-undecodable `tunnels.json` (garbage bytes, and a valid JSON of a future version the decoder rejects), each of `upsert`, `delete`, `deleteAll` throws a new `TunnelStoreError.unreadable` and leaves the file byte-identical; with no file, `upsert` creates it as today; `load()`'s readers (glyph, autostart) keep reading an empty store. CLI: `tunnels add` against an unreadable file exits non-zero with a message naming the file path and "could not be read", and does not modify it (a CLI test in the existing CLI test style, no rig).
- [x] Implement: writes read through `readProfiles()` and throw `.unreadable` on `.failure`; `TunnelManager` surfaces the throw to the sheet's existing error presentation with a new catalog key `tunnel.store.unreadable` ("The forwarding list could not be read, so it was not changed. Check %@." with the file path); `deleteAll(for:)` at :198 is `try?` today — decide from its doc comment (:193) whether a session deletion must now report it; if it stays silent, say why in the comment. CLI maps the error to a clear message and the existing exit code for a store failure.
- [x] Probes: route `upsert` back through `load()` → red. Whole suite, zero warnings. Commit `fix(tunnels): an unreadable forwarding store refuses writes instead of starting over`.
- [x] Done. Commit: `f31212b3`. 0 fix rounds (review raised only deferred minors, recorded as new BACKLOG rows in Task 9, not a fix round).

---

### Task 3: The SOCKS5 handshake has a deadline and a cap

**Row:** "The SOCKS5 handshake has no timeout".
**Files:** `Sources/macSCPCore/Tunnels/SOCKS5Handshake.swift` (`SOCKS5RequestBox` :547, `value()` :588), `Sources/macSCPCore/Tunnels/SOCKS5Listener.swift`, the runtime factory that starts the listener (`TunnelRuntime.swift`).

- [x] Failing tests with INJECTED values (no wall clock): a handshake whose client connects and sends nothing is closed and its box resolves with a failure once an injected deadline fires (drive the deadline through an injected clock/sleep seam or a manually fired trigger — read how the codebase already injects time in the tunnel runner's backoff tests and follow that); with an injected cap of 2, a third client that connects while two handshakes are parked is refused (socket closed promptly, no box parked) and a fourth is accepted once one of the two completes; a well-behaved client inside the deadline completes as today; `stop()` still resolves every parked box. Give `SOCKS5RequestBox.value()` the cancellation handler `OpenPortBox` (`RemoteForward.swift`) carries — its declaration says it would be needed — and test that cancelling the waiting task resolves the box once.
- [x] Defaults in production: deadline 30 s, cap 64, each a named constant with a comment stating the reasoning (a SOCKS greeting is a few bytes; `ssh -D` has neither, so these are this app's own limits; loopback bind by default). A refused or timed-out handshake writes one `.debug` line in the `tunnel` category with no client data beyond the local port.
- [x] Probes: remove the deadline → the stalled-client test red; remove the cap → the third-client test red. Whole suite, zero warnings. Commit `fix(tunnels): a SOCKS5 handshake has a deadline and a cap on parked handshakes`.
- [x] Done. Commits: `86135e0a`, `db432037` (fix round 1 — the vacuous handed-over deadline test, the port read moved before close). 1 fix round.

---

### Task 4: One name rule, an injected slow threshold, and two comments that overclaim

**Rows:** "The session-name authority is a second copy"; "`localFileSystemListWritesStartAndDoneWithoutAnEntrySlowLine` is a wall-clock claim"; the remaining prose items of "Polish: terminal resize, transfer cancel and paths"; the flake row "`NetworkTraceTests.aBrokenReceivingSocketIsAFailureAndNeverASilentHop`" (2026-09-16).
**Files:** `Sources/macSCPCore/Presentation/SessionListViewModel.swift` (`save`), `Sources/macSCPCore/Sessions/SessionNameRule.swift` (:96), `Sources/macSCPCore/RemoteFS/LocalMetadataSource.swift` (the slow threshold near :183-271), `Tests/macSCPCoreTests/DiagnosticLogSharedSinkTests.swift` (:122), `Sources/MacSCPAppKit/TerminalPanelViewModel.swift` (:326-328 comment), `Tests/macSCPAppKitTests/TerminalPanelViewModelTests.swift` (:473-474 comment), `Tests/macSCPCoreTests/NetworkTraceTests.swift`.

- [x] Name rule: failing test where the rule and a hand-written lookup would disagree (e.g. a name differing only in trailing whitespace, whichever normalisation `SessionNameRule.conflict(... matching: .exact)` applies — read it first and pick the case that separates them; if no such case exists today, write a test that pins `save` to replace exactly the session the rule names, by spying through the rule's seam); `save` asks `SessionNameRule.conflict` for the session it replaces. Red first.
- [x] Slow threshold: make the threshold (or the clock the line reads) injectable into `LocalMetadataSource`; the test proves the line absent with an entry that is fast by construction (threshold far above an instant fake clock) and present when a fake clock makes it slow. No elapsed-time assertion remains. Red first for the "present" half.
- [x] Prose: correct the two universal claims named in the Polish row to what the code does (count the writes in the same pass).
- [x] Flake: run `swift test --filter NetworkTraceTests` 20 times in a loop (sequentially, recording each result); if any run is red, read the test for a shared resource or a timing assumption and fix the cause with a red-first reproduction; if all 20 are green, record "20/20 green on 2026-09-16, not reproduced" for Task 9 and change nothing.
- [x] Whole suite, zero warnings. Commit(s) `fix(sessions): …`, `test(diagnostics): …`, `docs(comments): …` as the changes fall.
- [x] Done. Commits: `c0ee0261` (name rule), `92c0a9fc` (injected clock), `d89a10f2` (the two overclaiming comments). Flake: 20/20 green, filtered runs, not reproduced, nothing changed. 0 fix rounds (review's two findings concerned the scratch report only, no tracked-artifact fix).

---

### Task 5: Follow-ups of the PEM conversion and of the login-set re-point

**Rows (2026-09-16):** a jump added after a slot drop cannot authenticate; session export counts a converted session's passphrase as missing; `repointLoginSet` drops and redials even when `saveLoginSet` failed; the dialog title uses the captured set name; the count wording; `ContentView` in-place reconnect drops a dangling login set's resolver throw silently.
**Files:** `Sources/MacSCPAppKit/ContentView.swift` (jump fill ~2913/~2961, `repointLoginSet`, the in-place reconnect near ~2236/~2250), `Sources/macSCPCore/Presentation/SessionListViewModel+Submit.swift` (~95), `Sources/macSCPCore/Sessions/LoginResolver.swift` (~177, ~205, ~280), `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` (`buildJumpConfig` ~1951), `Sources/macSCPCore/Presentation/SessionListViewModel.swift` (`saveLoginSet` ~875, export ~1403), `Sources/MacSCPAppKit/ContentView+Sheets.swift` (dialog title), catalogs.

- [x] Jump fallback: a jump hop whose login is a private key and whose own/set/referenced slot is empty resolves the passphrase from the managed key's slot, through the same `ManagedKeyPassphrase.resolve` the target uses (Core test in `LoginResolver`'s or the jump builder's suite: empty jump slot + managed key slot → the managed value reaches the jump config; a password jump is unaffected). Keep `sessionServesAJumpHop`/`setServesAJumpHop` and their gates (defence in depth); update the design text in Task 9, not here.
- [x] `saveLoginSet` returns whether it saved (`@discardableResult`); `repointLoginSet` drops nothing and does not redial when it returns false (the view model's `errorMessage` already shows the failure). Guard: the drop and the retry sit after a positive check of the save result.
- [x] Dialog title and message use the freshly re-read set's name (the request's `set.name` only when the re-read finds nothing — which already routes to attempt-only). Count wording: en "…is used by %lld sessions, directly or as their jump host…" (one/other), translations accordingly.
- [x] Export: a session whose private key is managed and whose managed slot holds the passphrase counts as covered, not missing (Core test).
- [x] In-place reconnect: when the fill throws (a dangling login set), the tab shows the same message the sidebar's external-terminal path shows for that throw (read it; reuse its catalog key); test at the plan level if the decision is a pure function, otherwise a guard.
- [x] Whole suite, zero warnings. Commits per concern.
- [x] Done. Commits: `65f7c256`, `561fc589`, `615a417f`, `2914526a`, `a5c73952`, `24c7514f`; fix round 1 — `6a1b6a02`, `848cc2b3`, `f9ce645b`, `ff682ff8`, `9167f325`. 1 fix round.

---

### Task 6: A forwarding's failure is typed, logged in English, shown translated

**Row:** "A forwarding's failure reason is English on four localized surfaces" (+ the opaque `KeychainError` text row of 2026-09-16).
**Files:** `Sources/macSCPCore/Tunnels/TunnelProfile.swift` (`TunnelState.failed(reason: String)` :94), `TunnelStatePlan.swift`, `TunnelRunner.swift` (where `.failed(reason: DialSupport.reason(for:))` is applied, ~288), `Sources/macSCPCore/Diagnostics/DialProbes.swift` (`DialSupport.reason(for:)`), the four App surfaces (`TunnelProfilesSheet.stateLabel` and its callers `TunnelAutostartSheet.swift`, `TunnelDockPresence.swift`, `SessionSidebar.swift`), the tunnel sheet's second render site (`TunnelProfilesSheet.swift:~536`), four App catalogs, every test that spells a reason string.

- [x] Design inside the task (write it into the report before coding): `public enum TunnelFailure` already exists in Core (read it — it is what listeners report); decide whether `TunnelState.failed` carries it or a new `TunnelFailureKind` that also covers dial errors (host key mismatch/refused, auth failed, key passphrase required/wrong, PEM not readable, keychain unavailable, key store unreadable, network unreachable/refused/timeout, remote forward refused, local bind in use, unknown). The value carries data a sentence needs (host, port) but no secret and no raw error description. `DialSupport.reason(for:)` stays the English log sentence and gains a sibling `DialSupport.failureKind(for: any Error) -> TunnelFailureKind` (or the type's own initialiser) so both come from one switch; a test pins that every kind renders an English sentence and that the sentence equals today's for the kinds that existed (no log-text churn beyond the two opaque cases, which gain readable sentences: "the keychain could not be read" and "the managed key list could not be read").
- [x] App: `TunnelProfilesSheet.stateLabel` maps each kind through `L10n` (keys `tunnel.failure.<kind>` with `%@` for host/port where needed) in four catalogs; the four surfaces keep calling `stateLabel`. A guard pins that `stateLabel` renders no `String(describing:)` and that every kind has a key (derive the kind list from the enum via `CaseIterable` or an exhaustive switch in a test helper, not a literal list).
- [x] Update `TunnelStatePlan` transitions, the store round trip if state is persisted (read it), and every test spelling a reason string. Red first for the mapping test and the "every kind has a key" guard.
- [x] Whole suite, zero warnings. Commit `feat(tunnels): a forwarding's failure is typed, and shown in the app's language`.
- [x] Done. Commit: `ab4a2c4c`; fix round 1 — `8c9289a5` (typed remote-forward failures restoring the GatewayPorts hint and the port-0 refusal in the App). 1 fix round.

---

### Task 7: Per-connection forward failures are logged and counted in the active state

**Row:** "A local or dynamic forward's per-connection failures are never reported". Depends on Task 6.
**Files:** `Sources/macSCPCore/Tunnels/TunnelRuntime.swift` (`LiveTunnelRuntimeFactory.start` passes no `onFailure`/`onConnectionFailure`), `LocalForwardListener.swift`, `SOCKS5Listener.swift` (:57), `RemoteForward.swift` (:128), `TunnelRunner.swift`, `TunnelProfile.swift` (`.active(connections:)` :89), `TunnelStatePlan.swift`, `TunnelProfilesSheet.stateLabel` and its tooltip, catalogs.

- [x] State: `.active(connections: Int, failedConnections: Int, lastFailure: TunnelFailureKind?)` (or an equivalent struct payload — choose, and update every pattern match; count them first). A failure increments `failedConnections` and sets `lastFailure`; the next successfully opened channel resets both to 0/nil; entering `.active` from `.connecting`/`.reconnecting` starts at 0/nil. The lifecycle does not change (no transition to `.failed` from connection failures).
- [x] Wiring: `LiveTunnelRuntimeFactory.start` passes all three failure callbacks into the runner, and a success signal (read what the listeners report on a successful channel open — the per-connection `.debug` lines exist; add an `onConnectionOpened` seam if none exists) into the runner. Each failure writes one `.debug` line in the `tunnel` category via `DialSupport.reason`-style English text of the kind, no client data beyond ports.
- [x] App: when `failedConnections > 0`, `stateLabel` renders "active · %lld connections failed" (stringsdict, four languages) and the tooltip carries the translated last failure; `failedConnections == 0` renders as today.
- [x] Tests red first: plan transitions (failure increments, success resets, reconnect resets); factory wiring (a fake listener's `onFailure` reaches the runner — no rig); the label for 0/1/5. Gated rig case: a `-L` forward to a closed port on the rig (`127.0.0.1:2222` side target port with nothing listening) → one client connect → the tunnel stays `.active` and `failedConnections == 1`.
- [x] Whole suite + the gated case, zero warnings. Commit `feat(tunnels): a forwarding counts connections that failed, and says so while it stays up`.
- [x] Done. Commit: `b9ee7d22`; fix round 1 — `bc639257` (stopped-attempt reports no longer reach the next attempt, the aggregate prefers a failing active tunnel, a disconnected client's reply-write failure is not counted). 1 fix round.

---

### Task 8: Forwardings connect without an SFTP channel, measured against a server without SFTP

**Row:** "A forwarding dial opens an SFTP channel it never uses".
**Files:** `Sources/macSCPCore/Tunnels/TunnelConnection.swift` (:48, :96 `CitadelFileSystem.connect`), `Sources/macSCPCore/SSH/CitadelFileSystem.swift` (`connect` :121, `openSFTP` path), `docker/test-server/compose.yml` (+ a `sshd_config.d-nosftp` directory), `docker/test-server/README.md`, a gated test file.

- [x] Rig: add service `sshd-nosftp` modelled on `sshd` (same image, same `testuser`/`testpass`, a published loopback port not used by any other service — read the compose file and pick the next free one, state it), with an sshd config fragment that removes/disables the SFTP subsystem and keeps `AllowTcpForwarding yes`; document it in the rig README. Measure it from the MAIN checkout: `sftp -P <port> testuser@127.0.0.1` fails with the subsystem refusal, and `ssh -N -L` through it forwards to a port inside the container.
- [x] Core: a connect path that performs the same TOFU host-key validation, jump handling and authentication as `CitadelFileSystem.connect` and stops after user auth without opening the SFTP subsystem — factor the shared part rather than copying it (the TOFU hard stop must stay in one place; a guard or a test must pin that the new path uses the same validator). `TunnelConnection` uses it; tabs keep `CitadelFileSystem.connect`.
- [x] Tests: unit-level where a seam allows (the forwarding path never calls `openSFTP` — spy); gated rig case against `sshd-nosftp`: a `-L` forwarding reaches `.active` and carries bytes to a port inside that container (start a listener in the container with `docker exec` as other gated cases do), while `CitadelFileSystem.connect` against the same server fails at SFTP (proving the rig measures what it claims). Red first: the gated forwarding case red before the change (record the failure).
- [x] Whole suite + gated cases, zero warnings. Commits `test(rig): an sshd without the SFTP subsystem`, `feat(tunnels): a forwarding connects without an SFTP channel`.
- [x] Done. Commits: `c479fd37`, `f0d9f4ff`; fix round 1 — `feb0a55e` (a forwarding's disconnect now outlives Citadel's login timer). 1 fix round.

---

### Task 9: Closeout

- [x] `docs/BACKLOG.md`: every row named in Tasks 1-8 → Done with its commits (or, for the flake, the recorded 20-run result); the Xcode 27 row states the CI step and that its first runner measurement is pending until a runner has Xcode 26+. `docs/superpowers/specs/2026-09-06-port-forwarding-design.md`: a dated section for the typed failure, the connection-failure counter, the SOCKS5 limits, the SFTP-less connect and the store refusal. `docs/superpowers/specs/2026-09-10-pem-private-keys-design.md`: the jump fallback (Task 5) and that the jump predicates remain as defence in depth. README if a user-visible behaviour it describes changed. This plan's checkboxes. Commit `docs(backlog): the technical backlog of 2026-09-16 is closed`.
- [x] Done. `docs/BACKLOG.md` gained 16 "Done 2026-09-17" closures and 11 new open rows; both design docs gained a dated section/correction; README needed no change (it names no output format the plan altered). Commit: see this task's own report.

## Self-review

- Coverage: the four maintainer decisions → Tasks 7, 6, 8, 1; the older rows → Tasks 2, 3, 4, 7, 8; the 2026-09-16 rows → Tasks 4 (flake), 5, 6 (opaque Keychain text). Not covered and left open on purpose: "At login" (pending the maintainer's measurement), the second Keychain consent prompt (inherent to the design, documented), a corrupt `managed_keys.json` staying silent for managed encrypted keys (no surface to show it without a model change — kept as a row).
- Placeholders: Tasks 6 and 7 leave the exact enum shape to the implementer with explicit criteria and a written design step; every other value, key, file and test is named.
- Type consistency: `TunnelStoreError.unreadable`, `TunnelFailureKind`, `failedConnections`, `lastFailure`, `sshd-nosftp` are used consistently.
