# The cleanup sweep and the third outcome — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a diagnostic step that never started its own honest outcome, and work off the thirteen rows of deferred minors that closed plans left behind — sized on 2026-09-24 at 53 open items — closing what is cheap, measuring what is not, and splitting out what needs its own design instead of burying it here.

**Architecture:** Eight tasks. Task 1 is the maintainer's answer of 2026-09-25: a step that could not be started says so rather than "timed out". Tasks 2-6 group the deferred minors BY AREA rather than by the row they were recorded in — a sweep, a guards cluster, a diagnostics-and-jump cluster, a forwarding-and-dial cluster, and the interface leftovers. Task 7 is the three flakes. Task 8 is the closeout. Every task names its `docs/BACKLOG.md` rows by title; read each row in full first — each carries its own measurement and often its own fix shape — and re-verify every anchor with `grep -n`, because several of these rows were recorded weeks ago.

**Tech Stack:** Swift 6 strict, SwiftPM (Xcode 27 / Swift 6.4 locally; CI Swift 6.1.2, macos-15, **macOS 15.5 SDK**, three cores, zero-warning budget), Swift Testing, SwiftUI/AppKit, the Docker rig (S3 half now `rustfs/rustfs:1.0.0`, started from the MAIN checkout).

## Global Constraints

- **The maintainer's answer of 2026-09-25 binds Task 1**: a step that never started gets its own third outcome, not "timed out". They were offered "leave it and document" and chose the change.
- **A deferred minor is allowed to stay deferred.** Several of these items are measurement gaps or need a design; the honest outcome for one of those is a measurement and a row, not a hurried change. Say which you did and why — a task that closes an item by weakening what it checked is a defect, not progress.
- **User documentation ships with the feature** (CLAUDE.md, 2026-09-19). The docs live in `/Users/noidee/_dev/noix-docs` on branch `docs/macscp-next`, pushed at `b6ff620`. Work in a git worktree on that branch (the previous session's worktree is under a scratchpad that may be swept; `git worktree prune` in the docs repo first if it is stale), mark anything unreleased `*(next version)*`, `npm run build` and `npm run check` green, commit there and do not push unless asked.
- No secret in any store, state, log, reason, report, row or test message; no real host names in tests. TOFU is a hard stop. NO secret through the CLI.
- Swift Testing, red first (recorded); tests never block the cooperative pool — every wait is an `await`; **no wall-clock ceiling**, and no fake that finishes on its own while a deadline races it; no `#require` on a non-optional; polling goes through `pollUntil` under the suite's own `.timeLimit`.
- **A deadline armed at creation bounds the cooperative pool's queueing, not only the work** — measured 2026-09-25, a detached body started 10.0001 s after creation under 200 CPU-bound tasks, and two tests went red on CI for it. A test that drives a real probe against a short step budget and asserts SUCCESS is the shape to avoid; three such cases are recorded and untouched.
- Every App string through `L10n.string(_:_:)` in `en`, `de`, `fr`, `pl` (German du-form); Core's own catalogue through `CoreL10n`. The CLI's JSON: add keys, never rename.
- Source-scanning guards read through `Tests/MacSCPTestSupport/SourceCorpus.swift`; a negative check keeps a positive beside it. `SourceCorpus.code` blanks comments AND string literals; `SourceCorpus.commentFree` blanks only comments; `SourceCorpus.text` is raw and lets a comment quoting a pattern satisfy the scan — measured 2026-09-24, when a decoy comment misdirected exactly such a guard.
- **CI's SDK is older than this machine's** (macOS 15.5 vs macOS 27), measured the hard way when `ENOTCAPABLE` compiled here and not there. Say what you could not verify locally.
- Zero compiler warnings. Conventional Commits, English, one blank line before the footer `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. Do not push; **do not launch the app binary** (`macSCP` is the AppKit product and hangs; the CLI is `macscp-cli`); do not stage `docs/BACKLOG.md` before Task 8. Run the suite in the FOREGROUND.
- A number or an enumeration written into a comment or a row is counted in that same moment. Four numbers in the previous plan had to be corrected after being written down, twice by the coordinator.

---

### Task 1: A step that could not be started says so

**Row:** "CI starvation: the deadline, bcrypt and audit-append costs left open" (the deadline half is Done; this is the consequence found on 2026-09-25) — and the investigation record archived at `~/.claude/projects/-Users-noidee-macSCP/sdd-ledgers/2026-09-24-ci-red-investigation.md`, whose "For the maintainer" section states the shape, the cost and what speaks against it. **Read that section first; it is this task's spec.**

- [ ] The measurement this rests on: `DetachedProbe`'s deadline is armed when the probe is CREATED, not when its body starts, so on a saturated machine the deadline can expire before the work begins and the row reads `timedOut` — accusing a server that was never contacted. The recorded shape is a third outcome, measured by a flag the probe body raises as its FIRST statement.
- [ ] Build it: `DetachedProbe` (and `BlockingProbe` where the same applies — say whether it does) distinguishes "the deadline expired while the body was still queued" from "the body ran and overran". The hard limit does not move: a probe that never starts must still end by its deadline, which is the whole point of the 2026-09-24 ruling.
- [ ] The outcome reaches the user: a reason in Core, a row in the diagnostics panel, the CLI and its JSON (add a key, never rename), in four languages, German du-form. `ConnectionDiagnostics.swift`'s rule about what a step's outcome means changes with it — the record names the line.
- [ ] Tests, red first: a probe whose body is never scheduled reads the new outcome, not `timedOut`; a probe that starts and overruns still reads `timedOut`; the deadline still bounds both. Prove the first WITHOUT a wall-clock ceiling — the in-process pool-starvation harness the 2026-09-25 investigation built is the precedent, and it is described in the archived record.
- [ ] Whole suite, zero warnings; docs updated (the diagnostics page: what the new row means and that it is about the user's own machine, not the server). Commit `feat(diagnostics): a step that could not be started says so`.

---

### Task 2: The trivial sweep

**Rows:** "Task 1's review minors: SFTP connect-timeout doc and wording" (M1, M3, M4), "The review-follow-ups plan's deferred minors: guards" (items 2 and 3), "The source-corpus guard plan's deferred minors" (item 2), "The jump plan's deferred minors: diagnostics through the jump" (items 4 and 6), "The resume-identity and window-scope plan's deferred minors" (item 4).

- [ ] Thirteen items sized trivial on 2026-09-24: comments, renames, line numbers, a type that sits in the wrong file. Each row states its own; read them, and **re-locate every anchor before editing** — one of these (row 66's M3, cited at `ConnectionViewModel.swift:1212`) was measured on 2026-09-24 to no longer match its description, and must be re-found or dropped with a note rather than edited blind.
- [ ] Named ones to expect: `connectTimeoutSeconds`' doc not saying it also bounds the SFTP version wait; `failureKind(for:)`'s `.other` wording; `firstOffset`/`closingOffset` living on a dialog-named type that a non-dialog scan borrows; `ConvertKeyWiringGuardTests`' own forwarder instead of the shared scanner; three `static let` regex patterns still using `try!` instead of `CompiledPattern.regex` (`SettingsViewDiagnosticLogGuardTests.swift:147`, `CLISettingsCompletionGuardTests.swift:229`, `WhatsNewWiringGuardTests.swift:129` — all three confirmed unchanged on 2026-09-24); `ConnectionDiagnosticsJumpRigTests` setting `authKind` twice; `DiagnosticJump.form` comparing the jump host case-sensitively (deliberate and safe — decide whether to keep it and say so); `SecretChain(sources:)`'s `kinds` default, judged harmless.
- [ ] A trivial item that turns out not to be trivial is moved to its own row with what you found, not forced.
- [ ] Whole suite, zero warnings. Commit as one or a few; say which split you chose.

---

### Task 3: The guards cluster

**Rows:** "The review-follow-ups plan's deferred minors: guards" (item 1 and item 4), "Task 3's review deferred minors: a guard's spelling sensitivity and a shared helper move" (items 1-4), "The source-corpus guard plan's deferred minors" (items 1 and 3), "The resume-identity and window-scope plan's deferred minors" (item 2).

- [ ] The theme: guards that buy one spelling and reveal another, and guards nothing holds to their own rule. CLAUDE.md's "Guards that name what they watch" is the standard, and its own conclusion applies — when a scan keeps buying one spelling, the property wants a STRUCTURAL boundary rather than another anchor. This session has two precedents: a `String` and a `Bool` that cannot be exchanged, and a read whose order became impossible to bind wrongly.
- [ ] Items: the fail-closed refusal that also refuses markers inside plain prose; the `isPrimaryWindow` literal guard that is spelling-sensitive rather than structural; `isActiveTabConnected` pinned by nothing; a full-screen guard binding two independent `.contains` calls where one would do; `body(after:in:)`-shaped logic duplicated across many guard files that could be one helper; the no-cycle invariant between the two `readStream` spellings, carried only by a comment; and M6 of the source-corpus row — nothing enforces that no test writes under `Sources/`/`Tests/`.
- [ ] For each: state whether you made it structural or anchored it better, and **measure the sensitivity** — plant the violation the guard exists for and record the rate, not one red run (CLAUDE.md: one red run is evidence a check CAN catch something, not that it does).
- [ ] The 23 App test files left unconverted to comment handling (row 48, item 4) are NOT in this task — count them, say what converting them would cost, and leave them a row.
- [ ] Whole suite, zero warnings. Commit `test(guards): the guards that bought a spelling now hold a property`.

---

### Task 4: Diagnostics and the jump

**Rows:** "The jump plan's deferred minors: diagnostics through the jump" (items 1, 2, 3, 5, 7), "The jump plan's deferred minors: the jump-host probes" (items 2, 5), "The jump plan's deferred minors: the jump tests" (item 1).

- [ ] Items: `DirectTCPIPRejection.reasonCode(inDescription:)` tested only on hand-written strings, with the rig covering one code; a case that goes red only via its `.timeLimit` rather than by observing the missing close; the panel's idle text saying nothing about a jump, in four catalogues; `DiagnosticJump.form` not comparing the key path, so a stored passphrase can be tried against a different local key file; `jumpExecRefused`'s detail being a generic library error that tells the user nothing; a headerless BSD traceroute test that is constructed rather than recorded; and `aRefusedJumpFailsTheNewTabVisiblyAndLeavesTheFirstAlone` dialling `127.0.0.1:1`, which hangs if anything listens there.
- [ ] `ConnectionDiagnostics.swift` has grown past 1400 lines and `JumpProbes.swift` past 990 (both counted 2026-09-24 — recount). Splitting either is an organisation change with no behaviour: decide whether it belongs in this task or its own row, and say why. Do not half-split.
- [ ] Whole suite plus `MACSCP_ITEST=1` against the rig from the MAIN checkout; report the jump sections specifically. Zero warnings. Commit as you judge; say the split.

---

### Task 5: Forwarding, dial and keys

**Rows:** "The review-follow-ups plan's deferred minors: forwarding" (items 3, 4), "The review-follow-ups plan's deferred minors: dial and keys" (items 2, 3, 4, 6), "The jump plan's deferred minor: the tab title's cost".

- [ ] Items: the `localConnected`/`LocalConnectedHook` seam wanting an explicit ruling (it is a decision, not code — make it and record it); a "reported once" check that races a delayed duplicate; `aFailedStateAlwaysCarriesAFailureReason` bundling two properties into one case; a close-await step's contribution not isolated from an exec step's; `managedKeyStoreUnreadable` naming the fact but not the store's location; `ConnectionFormView`'s Connect button building its own `ManagedKeyStore` inline instead of taking the injected one; and `TabTitlePlan.stored(_:)` scanning the session list up to twice per call, once per tab per render.
- [ ] The tab title's cost is a performance item with no visible effect today. Measure before and after rather than asserting an improvement, and if the measurement says it does not matter, say so and leave it.
- [ ] The two items in these rows that need a design — the third stop window in `RemoteForward.serve`, and the SFTP-failure-after-`openSFTP` release path needing a signing mock agent — are NOT in this task. Give each its own row with what the row already measured.
- [ ] Whole suite, zero warnings. Commit as you judge; say the split.

---

### Task 6: The interface leftovers

**Rows:** "The review-follow-ups plan's deferred minors: terminal" (both items), "Task 7's review deferred minors: notifications" (both items), "The review-follow-ups plan's deferred minors: dial and keys" (item 7).

- [ ] These are the ones most likely to end as measurements rather than changes, and that is an acceptable outcome: a synthetic Control-click menu request with paste-on-right-click on and Option not held, unmeasured for VoiceOver; key-window routing unmeasured; a notification posted during the first authorization prompt being lost; transfer-failed and connection-lost both firing for one drop, undeduplicated by design.
- [ ] For each: either measure it and record what you found, or change it and pin the change. **Do not guess at AppKit behaviour** — you may not launch the app binary, so anything that needs a running app is a measurement the maintainer makes, and your deliverable is a precise sight-check instruction for the closeout's sight-check row.
- [ ] Item 7 of the dial-and-keys row is a native-speaker review of the `de`/`fr`/`pl` strings added by that plan. You are not a native speaker of all three: list the strings, flag anything that reads like machine output, and leave the rest as a maintainer item.
- [ ] Whole suite, zero warnings. Commit as you judge.

---

### Task 7: The three flakes

**Rows:** "`completionAgainstRealListingFindsSeededSubdirectory` flaked once under load", "A flake at `DiagnosticLogSharedSinkTests.swift:800`, once under load", "Three SSH-rig cases go red under the full gated run and pass in isolation".

- [ ] The first two are single unreproduced observations; the honest deliverable may be a better record rather than a fix. Say for each whether you reproduced it, and how many attempts under what load. Do not "fix" a flake you cannot reproduce — that is a change nothing measures.
- [ ] The third is well characterised and worth real work: six full gated runs by four different agents gave 8, 7, 11, 10, 6 and 5 issues, a DIFFERENT set each time, every one an SSH handshake or channel error or WebDAV leftover state, all green in isolation. The rig's own config contradicts the throttling explanation (`PerSourcePenalties no` and `MaxStartups 100:30:200`, mounted into all eight sshd services). One measured load change is on record: four cases now call `rigKnownHosts(in:)`/`rigHostKeyEntries()` before dialling, each spawning two `docker exec` subprocesses. Measure before theorising — an isolated load test, then a hypothesis, then one change.
- [ ] A mitigation the row already names: caching the host keys once per run rather than per case. Measure whether it helps before building it.
- [ ] Whole suite plus the gated run, several times; report every run's issue count and set. Commit what you change; if the answer is a record, commit the record.

---

### Task 8: Closeout

- [ ] `docs/BACKLOG.md`: every row named above gets a **Done** sentence leading it with its commits, or — where the honest outcome was a measurement — a sentence saying what was measured and what stays open. Items moved out into their own rows get those rows, each carrying the measurement it was recorded with, copied and not paraphrased. Every decision taken FOR the maintainer is listed so it can be overturned. The sight checks Task 6 produces join the grouped sight-check row. This plan's step boxes ticked. The docs worktree's commits are named in the report. Commit `docs(backlog): the cleanup sweep of 2026-09-27 is recorded`.

## Self-review

- Coverage: the maintainer's answer → Task 1; the thirteen deferred-minors rows → Tasks 2-6 grouped by area; the three flake rows → Task 7; Task 8 closes.
- Placeholders: every task states that an item which resists a cheap fix becomes a row rather than a forced change, and Tasks 6 and 7 may legitimately deliver measurements. Each names what is explicitly NOT in it.
- Type consistency: `DetachedProbe`, `BlockingProbe`, `DeadlineTimer`, `ConnectionDiagnostics`, `DiagnosticJump`, `JumpProbes`, `DirectTCPIPRejection`, `TabTitlePlan`, `ConnectionFormView`, `ManagedKeyStore`, `CompiledPattern`, `SourceCorpus` and `rigKnownHosts(in:)` all exist at `e192ad2c`; the anchors inside the rows are older and each task is told to re-verify them.
