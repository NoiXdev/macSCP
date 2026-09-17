# Next build of 2026-09-17 — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the one user-facing hang found on 2026-09-17, close the tunnel follow-ups the reviews left, and build the five wishlist items the maintainer already decided.

**Architecture:** Eight tasks. Task 1 bounds the SFTP start of a tab dial. Task 2 is the forwarding follow-ups. Tasks 3-7 are the decided wishlist items, each self-contained in the App layer with Core seams where logic is testable. Task 8 is the closeout. Every task names its `docs/BACKLOG.md` row by title; read the row first — it carries the measured facts and file:line anchors (re-verify them with `grep -n`, several moved).

**Tech Stack:** Swift 6 strict, SwiftPM (Xcode 27 / Swift 6.4 locally; CI Swift 6.1.2 with a zero-warning budget), Swift Testing, SwiftUI/AppKit, SwiftTerm, Citadel fork 0.12.1-noix.3, `UserNotifications`, the Docker rig (from the MAIN checkout; `sshd-nosftp` on 127.0.0.1:2236).

## Global Constraints

- Maintainer, 2026-09-17: "erstmal weiter bauen" — no release, no cleanup, the "At login" measurement later. Wishlist decisions of 2026-09-16 (recorded in `docs/BACKLOG.md`, accepted in chat): the upload/download toolbar buttons ask only when the selection holds more than one item or a folder; copy on select and paste on right click are two separate switches, both default off, and while paste on right click is on the snippet menu moves to Option-right-click; macOS notifications (not in-app banners) for a lost connection, a failed transfer and a failed forwarding.
- TOFU is a hard stop; no accept-anything path; no secret in any store, state, log, reason, notification text or test message; no real host names in tests; the rig from the MAIN checkout only.
- Swift Testing, red first (recorded); tests never block the cooperative pool (every wait an `await`); no wall-clock ceiling (inject deadlines and clocks; `.timeLimit` only as a hang bound); no `#require` on a non-optional. Nothing new may compile only on Swift 6.4 (CI runs 6.1.2).
- Every App string through `L10n.string(_:_:)` in `en`, `de`, `fr`, `pl` (German du-form); plurals through `Localizable.stringsdict`. Settings keys go through `SettingsStore` (read how existing boolean settings are declared, persisted and tested).
- Source-scanning guards read `SwiftSource.blankingCommentsAndStrings`; a negative check has a positive beside it. Comments naming counts or callers are counted in the same pass. Scripted edits assert their anchor; probes are reverted with a file-scoped reverse patch; reports are written from `git diff --numstat` and `grep -n`.
- Subagents work in the FOREGROUND only (background-command notifications never reach them). The Bash tool's timeout is the only timeout (`timeout` is not installed).
- Zero compiler warnings (`swift build --build-tests` after touching every changed file; the SwiftPM "missing creator for mutated node" line is known noise). Conventional Commits, English, footer exactly `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. Do not push; do not launch the GUI; do not stage `docs/BACKLOG.md` or `docs/superpowers/specs` before Task 8.

---

### Task 1: A tab dial against a server without SFTP ends, and says why

**Row:** "A tab dial against a server without the SFTP subsystem never returns".

- [ ] Read the row, `CitadelFileSystem.connect`'s SFTP step (the R-1 comments, `releaseAfterCitadelTimer`, `citadelOpenSFTPTimer`) and `SSHForwardingConnection` (the no-SFTP path).
- [ ] Failing tests first: (a) a unit test through an injected SFTP-open seam that never answers: the dial fails with a new typed error (e.g. `SFTPStartError.noResponse`) once an INJECTED deadline fires (deterministic trigger, no real waiting), and the SSH client is closed (spy) — no connection is left behind; (b) the same seam answering normally still yields a file system; (c) gated (`MACSCP_ITEST=1`): a tab dial (`CitadelFileSystem.connect`) against `sshd-nosftp` returns the typed error within the suite's `.timeLimit` — replace the control test's log-racing workaround in `ForwardingWithoutSFTPITests` with this direct assertion, so the gated suite no longer abandons a suspended dial.
- [ ] Implement: bound the SFTP version wait with the session's connect timeout (the same value the dial already carries); on expiry close the client (through the existing delayed group release) and throw the typed error; map it in `ConnectionViewModel`'s failure mapping to a new catalogue key `core.connect.sftpUnavailable` ("This server did not start SFTP. It may not offer SFTP at all.") in four languages, a fixed `DialSupport.reason(for:)` sentence ("the server did not start the SFTP subsystem"), and `ConnectFailureKind` as the design of `failureKind(for:)` says (read it: is this `.other`?). Cancel of such a dial must now end it (verify through the same seam: cancelling the dial task closes the client).
- [ ] Whole suite + the gated SFTP-less and SSH integration suites, zero warnings. Commit `fix(connect): a tab dial against a server without SFTP ends with its own error`.

---

### Task 2: Forwarding follow-ups from the reviews

**Rows:** "A saved forwarding refused by an unreadable store still stops its running tunnel first, and three smaller gaps beside it"; the row about buffered per-connection reports applied during `stop()`; "`TunnelManager.forgetEverything`'s … ordering" and "the CLI's `sessions rm` aborts the removal …" (test-only rows).

- [ ] `TunnelManager.save`/`remove`: perform the store write before `discardRunner`; a refused write leaves a running tunnel running (test: running tunnel + unreadable file → `save` throws, the runner was not stopped, the state is still active).
- [ ] Orphan rows: the activation reconcile drops rows whose session no longer exists from the in-memory mirror (and leaves the file alone); test.
- [ ] `sessions rm`: when the forwarding count cannot be read, the prompt and `--verbose` say the count is unknown instead of "0" (new CLI message text; test).
- [ ] `CLIExitCode.swift`: the doc of the code returned for an unreadable forwarding or session store states that case too (no code change unless the enum has a better existing case — read it; do not renumber).
- [ ] `TunnelRunner`: once stopping has begun, drop buffered per-connection reports instead of applying them as intermediate `.active` states and log lines; keep the reader awaited on release; test with many buffered reports that no `.active` state is published after stop began.
- [ ] Tests for the two unpinned rows: `forgetEverything` removes the rows before any `await` (observe ordering deterministically, e.g. a start racing a parked discard); `sessions rm` over a `tunnels.json` that decodes but cannot be written aborts with its message.
- [ ] Whole suite + gated `TunnelRigITests`, zero warnings. Commits per concern.

---

### Task 3: The main window keeps its size across launches

**Row:** "The main window's size across launches (maintainer wishlist)".

- [ ] Reproduce by reading, and write the finding into the report: which frame the autosave stores at quit after (a) a connected session, (b) a disconnect that shrank the window, and what a connect after relaunch grows to. No GUI launch: reason from `applyFrameAutosave`, `shrinkIfPristine` and `lastBrowserSize`, and pin each decision in a plain-function plan type (the project renders no SwiftUI in tests).
- [ ] Implement: the browser size a user chose is persisted (settings or `UserDefaults` under a documented key) and used after relaunch instead of the 930×620 floor; a shrink to the form size is not what the autosave keeps as the window's remembered size (e.g. restore the browser frame before saving at quit, or keep the autosave on the browser frame only — pick the smallest change and justify it). Fix the stale comment at `resizeWindow(toWidth:height:)`.
- [ ] Tests on the plan type (which size a connect grows to, with and without a persisted size; what quit stores after a shrink). Whole suite, zero warnings. Commit `fix(window): the main window comes back at the size it was used at`.

---

### Task 4: The Settings window can be resized

**Row:** "A resizable Settings window (maintainer wishlist)".

- [ ] Replace the fixed `.frame(width: 680, height: 620)` with a minimum of 680×620 (every pane fits at that size today in all four languages) and a flexible maximum; make the Settings scene's window resizable (read how `MacSCPApp` declares `Settings { }` and what `.windowResizability` Swift 6.1-compatible API is available on macOS 15) and give it a frame autosave name so the size is remembered. A guard pins the minimum and that no fixed width/height frame remains on the root. Commit `feat(settings): the settings window can be resized and remembers its size`.

---

### Task 5: Upload and download ask before moving several items or a folder

**Row:** "A confirmation before \"upload all / download all\" (maintainer wishlist)".

- [ ] A pure plan function decides whether to ask: selection count > 1 or any directory → ask; one file → no question. Tests for 1 file, 2 files, 1 folder, file+folder.
- [ ] The two toolbar buttons (`uploadButton`/`downloadButton`) route through it; a confirmation dialog in the house shape (read the tab-close dialog in `ContentView+Sheets.swift`: `presenting:`, catalogue keys only) names the count and whether folders are included (stringsdict, four languages); confirm → `transferSelection`, cancel → nothing. Whether the context-menu and drag-and-drop routes ask too: the decision covers the toolbar buttons only — say so in a comment and leave the other routes unchanged.
- [ ] A guard pins that both buttons call the plan and that `transferSelection` is reached only from the confirm action or the no-question branch. Commit `feat(transfers): the toolbar asks before transferring several items or a folder`.

---

### Task 6: Terminal copy on select and paste on right click

**Row:** "Terminal: copy on select, paste on right click (maintainer wishlist)".

- [ ] Two settings in `SettingsStore`, both default off, with Settings toggles in the terminal section (four languages).
- [ ] Copy on select: when a selection ends in the terminal view, its text goes to the general pasteboard (read SwiftTerm's selection API in `.build/checkouts/SwiftTerm`; no copy of an empty selection).
- [ ] Paste on right click: a right click pastes through the same bracketed-paste path a normal paste uses (`bracketedPasteQuery`); while this setting is on, the snippet menu opens on Option-right-click instead (read `attachSnippetMenu`/`snippetContextMenu`); with the setting off, behaviour is unchanged.
- [ ] Pure decision function for the right-click routing (setting × modifier × snippets present) with tests; a guard for the wiring. Commit `feat(terminal): copy on select and paste on right click, each behind its own setting`.

---

### Task 7: macOS notifications for a lost connection, a failed transfer and a failed forwarding

**Row:** "Notifications on errors and disconnects (maintainer wishlist)".

- [ ] A small App-layer notifier over `UNUserNotificationCenter` behind a protocol seam; it requests authorization at the first notification it would post (not at launch); it does nothing when `Bundle.main.bundleIdentifier` is nil (an unbundled `swift run`), measured by reading, stated in a comment. A Settings toggle "Notifications" (default on) gates all three.
- [ ] Events: a tab's connection is lost (the liveness surface's transition to lost — read `ConnectionLiveness`/the lost surface wiring); a transfer fails (the transfer queue's failure — read where a failed item is recorded); a forwarding enters `.failed` (the `TunnelManager` state mirror). Post only when the app is not frontmost or the window is not key (decide from what AppKit exposes; state it). One notification per event; no repeats for the same tab/transfer/forwarding state.
- [ ] Text: title from catalogue keys, body with the session or forwarding NAME only (no host, no path, no reason sentence, no secret) — a guard pins that the notifier's text comes from catalogue keys plus the name.
- [ ] Tests with a fake notifier: each event posts once, the setting off posts nothing, repeated states do not repost. Commit `feat(notifications): lost connections, failed transfers and failed forwardings notify`.

---

### Task 8: Closeout

- [ ] `docs/BACKLOG.md`: each row named above → Done 2026-09-17 with its commits; new rows for anything the tasks recorded as open. The port-forwarding design's "Changes 2026-09-17" section gains the Task 2 behaviour; README only where a user-visible behaviour it describes changed. This plan's checkboxes (only the `- [ ]` step boxes — not the header line). Commit `docs(backlog): the next build of 2026-09-17 is recorded`.

## Self-review

- Coverage: the order the maintainer accepted ("1. SFTP hang, 2. review follow-ups, 3. wishlist without further questions") → Tasks 1, 2, 3-7. Left out on purpose: the stale own jump slot (needs a maintainer decision on typed vs managed passphrase precedence), the Termius sidebar and "Open with" (mockups first).
- Placeholders: Task 3's persistence mechanism and Task 7's frontmost rule are left to the implementer with explicit criteria and a written decision in the report.
- Type consistency: `SFTPStartError`, `core.connect.sftpUnavailable`, the settings and notifier seams are named in one place each.
