# Jump connections, tab titles, groups and jump diagnostics — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the maintainer's jump bug of 2026-09-18 (a second session over the same jump "does not open and the UI returns to the session info"), prove every two-connection jump case with tests, and build the other five reports of the same day: tab titles, "New group" in the folder menu and the session editor, the group tree in every group picker, and diagnostics that go through the jump.

**Architecture:** Nine tasks. Task 1 fixes the detail pane so a pending question is never covered by the session overview (the cause found for "returns to the session info"). Task 2 is the test matrix for two live connections through jumps, including key auth on the jump — the one variable the investigation left open for "the first connection drops". Task 3 is the tab title. Tasks 4-5 are groups (Core can create a nested group; one picker list with the tree). Tasks 6-7 are diagnostics through the jump. Task 8 moves a suite's log lines out of the maintainer's real log folder. Task 9 is the closeout. The investigation this plan rests on (measured vs read, file:line) is recorded in the `docs/BACKLOG.md` rows of 2026-09-18; read the row a task names first and re-verify its anchors with `grep -n`.

**Tech Stack:** Swift 6 strict, SwiftPM (Xcode 27 / Swift 6.4 locally; CI Swift 6.1.2 with a zero-warning budget), Swift Testing, SwiftUI/AppKit, Citadel fork 0.12.1-noix.3 (`jump(to:)`, direct-tcpip), the Docker rig (from the MAIN checkout; `sshd` 127.0.0.1:2222, `sshd2`, 2223 as a second jump — read `docker/test-server/compose.yml`).

## Global Constraints

- Maintainer, 2026-09-18: the jump bug is to be proved by a test first, "and all the other cases tested along with it". The other five reports are wishes of the same message; decisions this plan takes on the maintainer's behalf are listed in each task and repeated in the closeout so they can be overturned.
- The follow-ups plan `docs/superpowers/plans/2026-09-18-review-follow-ups.md` is parked after its Task 2 and resumes after this plan; do not touch its tasks' files beyond what a task here needs.
- TOFU is a hard stop; no accept-anything path — a diagnostics or test dial uses the refusing decider or the rig's recorded keys, never an accepting one. No secret in any store, state, log, reason, diagnostic report or test message; no real host names in tests; the rig from the MAIN checkout only; test keys generated at runtime with `ssh-keygen`, never committed.
- A remote command run on a jump host by diagnostics runs only when the user started diagnostics, passes the target host as a single shell-quoted argument after validating it as a host name or IP literal (reject anything else before any exec), and its output goes through the report's existing secrecy and userinfo filters.
- Swift Testing, red first (recorded); tests never block the cooperative pool (every wait an `await`); no wall-clock ceiling (inject deadlines and clocks; `.timeLimit` only as a hang bound); no `#require` on a non-optional. Nothing new may compile only on Swift 6.4.
- Every App string through `L10n.string(_:_:)` in `en`, `de`, `fr`, `pl` (German du-form); plurals through `Localizable.stringsdict`; Core-layer user-facing text through `CoreL10n` where it must live in Core.
- Source-scanning guards read `SwiftSource.blankingCommentsAndStrings`; a negative check has a positive beside it. Comments naming counts or callers are counted in the same pass. Scripted edits assert their anchor; probes are reverted with a file-scoped reverse patch verified by `cmp`; reports are written from `git diff --numstat` and `grep -n`.
- Subagents work in the FOREGROUND only. The Bash tool's timeout is the only timeout. If the first build fails on a stale Metal toolchain path after a reboot, delete the stale `XCBuildData` caches under `.build/out/Intermediates.noindex/` and rebuild.
- Zero compiler warnings (`swift build --build-tests` after touching every changed file; the SwiftPM "missing creator for mutated node" line is known noise). Conventional Commits, English, footer exactly `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. Do not push; do not launch the GUI; do not stage `docs/BACKLOG.md` or `docs/superpowers/specs` before Task 9.

---

### Task 1: A pending question is never covered by the session overview

**Row:** the Bugs row of 2026-09-18 about a second session through the same jump.

- [ ] Extract the unconnected-tab branch chain of the detail pane (`ContentView+Detail.swift`, the chain from `ConnectionSurfacePlan.surface(…)` through the `SessionOverviewView` branch to the `ConnectionFormView` fallback) into one pure plan, e.g. `DetailSurfacePlan.surface(…) -> .connecting | .lost | .failed | .form | .overview`, with the view switching on its answer only (one decision point).
- [ ] Rule: the overview is shown only when no host-key prompt is pending, the form holds no failure or refusal text a person must read (the `.needsPerson` kinds and the pre-dial refusals), and the mode is `.new` — as today otherwise.
- [ ] Failing tests first: `aPendingHostKeyPromptIsNeverCoveredByTheOverview`, `aNeedsPersonFailureShowsTheFormNotTheOverview`, `aPreDialRefusalShowsTheFormNotTheOverview`, and the positive partner `anIdleUnconnectedTabWithASelectionShowsTheOverview`; a guard that the view reads the plan (positive) and no second overview condition remains in the view (negative beside it).
- [ ] App-level jump tests (`JumpTwoTabsTests`): add a tab-factory seam to the sidebar start path (it hard-wires `makeTab()` with the real connector today) so the tests drive the real `connectFromSidebar`: two sessions through one jump → a second tab, the first tab stays connected with zero disconnects; the same session twice → the already-open question, "Open anyway" makes a second tab, the first survives; an unknown target key behind the jump → the plan answers `.form` and the card is reachable; a refused jump → the new tab fails with its text visible, the first tab untouched.
- [ ] Whole suite, zero warnings. Commit `fix(detail): a pending host-key question or a failure is never hidden behind the session overview`.

---

### Task 2: Two live connections through jumps, every case, on the rig

**Row:** the same Bugs row.

- [ ] Gated (`MACSCP_ITEST=1`), in the jump section of `CitadelFileSystemIntegrationTests`: a parameterised `twoLiveConnectionsThroughOneJumpStayIndependent` over — the same session twice; two different sessions through one jump; the jump host directly, then a session through it; the reverse order; the same session twice with concurrent dials; two different jumps at once. Each case proves connection 1 (a listing, `realpath`, a PTY shell), opens connection 2 and proves it, re-proves 1, closes 2, proves 1 again. Ordering through `await`s, no sleeps.
- [ ] The same matrix with KEY auth on the jump hop (key generated at runtime as the existing agent tests do) and, if the rig's agent tests allow it without a real agent socket leaking, agent auth on the jump hop. Key auth runs on the shared `MultiThreadedEventLoopGroup.singleton` — this is the variable the investigation left open for "the first connection drops".
- [ ] If any case goes red, stop: that red is the reproduction. Write it into the report with the output, then fix the cause (systematic debugging: root cause first, one change, the red test green) in the same task and commit separately as `fix(connect): …` naming the cause. If all cases are green, say so; the row keeps "the first connection drops" open for the maintainer's answer.
- [ ] Whole suite plus the gated SSH suites, zero warnings. Commit `test(jump): two live connections through jumps stay independent, with password and key auth`.

---

### Task 3: A tab says what it shows

**Row:** the Interface row of 2026-09-18 about the tab title while editing or previewing.

- [ ] One pure `TabTitlePlan.title(…)`: connected → the session name; connecting, failed or lost → the target session's name; editing → the edited session's name; showing the overview → the shown session's name (still drawn italic, as unconnected tabs are); otherwise "New Connection". Decision taken for the maintainer: the overview name applies only to the tab that is actually showing that overview (the active tab); other unconnected tabs keep their own attempt's name or "New Connection". Read how `overviewSession(for:)` is scoped per tab and state what you found.
- [ ] The view computes the title and hands it to the tab strip and the window title (`navigationTitle`); `SessionTab.displayTitle`'s own fallback stays for callers that have no view state (count them and say which).
- [ ] Tests: one `TabTitlePlanTests` case per state; a positive wiring guard that the tab strip and the window title draw the plan's output; catalogue entries (if any new key) in four languages.
- [ ] Whole suite, zero warnings. Commit `feat(tabs): a tab is titled by the session it shows or edits`.

---

### Task 4: A group can be created inside a group

**Row:** the Interface row of 2026-09-18 about "New group" on subfolders.

- [ ] Core: `createGroup(named:inGroup parentID: UUID?)` on `SessionListViewModel`, placing the new group after its siblings (reuse `SidebarOrdering`, not `position: 0`); a missing parent is refused with a typed error (the caller shows it), not silently lifted. The existing top-level call becomes the `nil` case.
- [ ] Sidebar: "New group…" on the folder-row menu, creating inside that folder through the new call (extend `beginNewGroup` with the pending parent); the new group is revealed (its parent expanded) and selected for rename as the top-level path does today — read that path and match it.
- [ ] Tests: `createGroupInsideAFolderSetsItsParent`, `aNewSubgroupLandsAfterItsSiblings`, `createGroupUnderAMissingParentIsRefused`; a positive guard that the folder menu offers the entry and wires it to the parent-taking call.
- [ ] Whole suite, zero warnings. Commit `feat(groups): a new group can be created inside a folder`.

---

### Task 5: Every group picker shows the tree, and the editor can create a group

**Rows:** the Interface rows of 2026-09-18 about the tree in group pickers and "New group" in the session editor's picker.

- [ ] Core: one builder, e.g. `GroupPickerEntries.build(groups:excluding:) -> [Entry(id, depth, name, path)]`, depth-first, reusing `GroupTree` and the cycle exclusion `SidebarOrdering.moveTargets` applies; `path` joined with " / " exactly as `SessionCatalog` renders it for the CLI (read it and reuse, do not re-spell).
- [ ] Presentation, decided for the maintainer: every picker lists entries in depth-first order and labels each with its full path ("Work / Prod"), because a SwiftUI `Picker` cannot indent; a `Menu` ("Move to") may nest submenus instead if that reads better — pick one per control kind and state it. All group-choosing places read the builder: the session editor's picker, the session row "Move to", the folder row "Move to", the "Import from Cyberduck" group choice. Count them again with `grep -n` and name any place not in this list.
- [ ] Session editor: a "New group…" entry in (or beside) the group picker opens a name prompt, creates the group through Task 4's call (top level, or inside the currently chosen group — decided: inside the currently chosen group, top level when "No group" is chosen), and selects it. Decided: the group stays created if the editor is cancelled, as groups are created immediately everywhere else.
- [ ] Tests: `GroupPickerEntriesTests` (order, depth, path, excluding self and descendants, an orphaned parent lifted to the top as `GroupTree` does); a positive guard whose count of builder readers matches the listed places; the editor selects the created group; catalogue entries in four languages.
- [ ] Whole suite, zero warnings. Commit `feat(groups): group pickers show where a group sits, and the editor can create one`.

---

### Task 6: Diagnostics check the jump, then reach the target through it

**Row:** the New-features row of 2026-09-18 about diagnostics and jump hosts.

- [ ] Carry the jump into diagnostics: stored sessions and the tab's form values both yield the jump (a session-mode jump resolved through `LoginResolver.resolveJump`, as the connect does; the jump hop's own secret slot looked up as the connect does). A guard/test pins that the dial's config never drops the jump when one is set (red first: today `SSHFieldSchema.makeConfig` skips it).
- [ ] For a session with a jump, the step sequence: `jump.resolve`, `jump.tcp`, `jump.icmp`, `jump.dial` (transport, jump host key with the refusing decider, jump auth; the connection stays open for the following steps), `jump.trace` (local, to the jump), `target.tcpViaJump` (a direct-tcpip open to target:port over the jump connection — its failure distinguishes "prohibited" from "connect failed"), `target.dialViaJump` (target host key, auth and SFTP through the jump), then contributions. If any jump step up to `jump.dial` fails, the target steps are `.skipped` with a reason naming the jump. Map the existing scopes onto both halves (`.ping`, `.trace`, `.dial`). Sessions without a jump keep today's sequence unchanged (test).
- [ ] Step names, the report text and the CLI's `diagnose` output show both halves with translated step titles (four languages); the CLI's JSON adds keys, never renames.
- [ ] Tests with injected probes: the order with a jump; skip propagation; unchanged order without a jump; the jump connection closed at the end. Gated: diagnostics on `sshd2` through 127.0.0.1:2222 report every jump step ok and `target.tcpViaJump` ok.
- [ ] Whole suite plus gated, zero warnings. Commit `feat(diagnostics): a session behind a jump is diagnosed through the jump`.

---

### Task 7: Diagnostics run resolve, ping and trace from the jump

**Row:** the same New-features row.

- [ ] Three exec probes over Task 6's open jump connection, using the existing exec plumbing (read `ChecksumCommandChannel` in `CitadelFileSystem.swift`): `target.resolveOnJump` (`getent hosts`), `target.icmpFromJump` (`ping -c 3`), `target.traceFromJump` (`traceroute -n -q 1`, falling back to `tracepath -n`). Each is `.unavailable` with its reason when exec is refused, the tool is missing, or the output does not parse — never a failure of the target.
- [ ] The target host is validated as a host name (RFC 1123 labels) or an IP literal before any exec and passed as one single-quoted argument; anything else is refused before the channel opens. Output passes the report's secrecy and userinfo filters.
- [ ] Tests: the quoting and validation (including hostile inputs: `;`, `$(`, backticks, quotes, spaces, a leading `-`); parsing of each tool's output from recorded samples; `.unavailable` on exec refused and on "command not found". Gated: on the rig jump, each probe is ok or `.unavailable` with a reason (read what the rig image carries and assert exactly that).
- [ ] Whole suite plus gated, zero warnings. Commit `feat(diagnostics): resolve, ping and trace run from the jump host`.

---

### Task 8: Tests write no lines into the real diagnostic log

**Row:** the Security-and-testability row of 2026-09-18 about test-shaped lines in `~/Library/Logs/macSCP`.

- [ ] Find the writer: which test (or test support) reaches the real log directory — plant a marker, run suites by filter, or read every construction of the diagnostic log's file sink in `Tests/`. Record how it was found.
- [ ] Route that path through the existing test-isolation seam (read the "[Tests reaching real stores]" spec and how stores are redirected); add a guard or test that fails if a test process writes into the real log directory (positive check that the redirect is in place).
- [ ] Do not delete or edit the maintainer's existing log files.
- [ ] Whole suite, zero warnings. Commit `test(logs): tests write no lines into the real diagnostic log`.

---

### Task 9: Closeout

- [ ] `docs/BACKLOG.md`: each row named above → Done 2026-09-18 with its commits (the file's convention: the row's text stays, a **Done** sentence is appended); the jump row keeps "the first connection drops" open unless Task 2 reproduced and fixed it; new rows for anything recorded as open; the decisions taken for the maintainer (Tasks 3 and 5) listed in the rows so they can be overturned; the sight checks this plan adds join a grouped sight-check row for 2026-09-18. This plan's `- [ ]` step boxes ticked (not the header line). Commit `docs(backlog): jump connections, tab titles, groups and jump diagnostics are recorded`.

## Self-review

- Coverage: report 6 → Tasks 1-2; report 1 → Task 3; report 2 → Task 4; reports 3-4 → Task 5; report 5 → Tasks 6-7; the investigation's log-folder note → Task 8.
- Placeholders: Task 2's fix is conditional on a red; Task 8 starts with finding the writer; Task 3 and Task 5 carry decisions named as such.
- Type consistency: `DetailSurfacePlan`, `TabTitlePlan`, `createGroup(named:inGroup:)`, `GroupPickerEntries` are introduced once each; `LoginResolver.resolveJump`, `SSHFieldSchema.makeConfig`, `SidebarOrdering.moveTargets`, `SessionCatalog` exist at `aa9b789e`.
