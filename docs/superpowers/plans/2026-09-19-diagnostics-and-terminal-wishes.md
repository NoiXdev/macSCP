# Diagnostics and terminal wishes of 2026-09-19 — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build four wishlist items from 2026-09-16 whose shape is clear enough to build without a new design round: reverse DNS in diagnostics, the throughput test to the server over the session's own protocol, an action that resolves an entered host name to an address, and a choice of terminal emulation type.

**Architecture:** Five tasks. Task 1 adds a PTR lookup and a forward-confirm check to the resolve step (report, never judge). Task 2 adds a throughput step that uploads and downloads a test payload over the session's own backend and always removes it. Task 3 adds a "Resolve to address" action beside the connection form's host field for SSH/SFTP sessions. Task 4 adds a terminal type setting with a per-session override, limited to types measured as rendered by SwiftTerm. Task 5 is the closeout. Every task names its `docs/BACKLOG.md` row by title; read the row first and re-verify its anchors with `grep -n`.

**Tech Stack:** Swift 6 strict, SwiftPM (Xcode 27 / Swift 6.4 locally; CI Swift 6.1.2 with a zero-warning budget), Swift Testing, SwiftUI/AppKit, SwiftTerm, Citadel fork 0.12.1-noix.3, the Docker rig (from the MAIN checkout).

## Global Constraints

- Maintainer, 2026-09-18: "danach dann gerne weiter im backlog". Wishlist answers of 2026-09-16 bind (recorded in the rows): the speed test is "both" — this plan builds only the server half; the general internet speed test waits for the maintainer's choice of service (asked in chat). Left out on purpose because they need a maintainer decision: custom terminal themes (presets, editor or import), SSH compression (a fork change), the internet half of the speed test. Decisions this plan takes on the maintainer's behalf are named in each task and repeated in the closeout so they can be overturned.
- TOFU is a hard stop; no accept-anything path. No secret in any store, state, log, reason, diagnostic report or test message; no real host names in tests (loopback, TEST-NET, `.invalid` and the rig only); the rig from the MAIN checkout only.
- Swift Testing, red first (recorded); tests never block the cooperative pool; no wall-clock ceiling — a throughput number is never asserted against a bound; no `#require` on a non-optional. Nothing new may compile only on Swift 6.4.
- Every App string through `L10n.string(_:_:)` in `en`, `de`, `fr`, `pl` (German du-form); Core-layer user-facing text through `CoreL10n` where it must live in Core. The CLI's JSON output: add keys, never rename or remove one.
- Source-scanning guards read `SwiftSource.blankingCommentsAndStrings`; a negative check has a positive beside it. Comments naming counts or callers are counted in the same pass. Scripted edits assert their anchor; probes are reverted with a file-scoped reverse patch verified by `cmp`.
- Subagents work in the FOREGROUND only. If the first build fails on a stale Metal toolchain path after a reboot, delete the stale `XCBuildData` caches under `.build/out/Intermediates.noindex/` and rebuild.
- Zero compiler warnings (`swift build --build-tests` after touching every changed file; the "missing creator for mutated node" line is known noise). Conventional Commits, English, footer exactly `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. Do not push; do not launch the GUI; do not stage `docs/BACKLOG.md` or `docs/superpowers/specs` before Task 5.

---

### Task 1: Diagnostics look up each address's name and check it resolves back

**Row:** "Diagnostics: reverse DNS and host name check (maintainer wishlist)".

- [ ] For each address the resolve step found (and, for a session behind a jump, the jump's resolve step too), a PTR lookup (`getnameinfo` with `NI_NAMEREQD`, off the cooperative pool as the resolver already runs) and a forward-confirm: the returned name resolves back to that address. Decided for the maintainer: report, never judge — a missing or non-matching PTR is a detail on the resolve row, never a failure of the step (the row's own reading and its S3-access-probe precedent). Trace hops are not named in this task (open in the row).
- [ ] The lookups count against the resolve step's budget (inject the resolver; a lookup that does not answer in the budget is reported "no answer", not a failure). Output passes the report's filters.
- [ ] Tests with an injected resolver: PTR present and confirming; PTR present, not confirming; no PTR; lookup cut by the budget; several addresses. Report text and CLI `diagnose` output (text and JSON — keys added only) in four languages.
- [ ] Whole suite, zero warnings. Commit `feat(diagnostics): the resolve step names each address and checks the name resolves back`.

---

### Task 2: A throughput test to the server over the session's own protocol

**Row:** "A speed test in diagnostics (maintainer wishlist)".

- [ ] A new diagnostics step (and scope, e.g. `.throughput`, never part of the default complete run — decided for the maintainer: it moves data on the user's server, so it runs only when chosen explicitly) that uploads a generated payload to a uniquely named temporary file in the session's home or start directory, downloads it, verifies the bytes, and removes it — on success, failure and cancel alike (test each). Payload size is a setting with a small default (decided: 8 MiB; range 1–256 MiB).
- [ ] It uses the session's own backend through the same `RemoteFileSystem` the browser uses (SFTP, S3, WebDAV all get it); the configured bandwidth limits apply and the row says so when a limit is set. The result is a rate up and a rate down, reported, never judged; no test asserts a rate.
- [ ] The temporary name cannot collide with a user file (a `.macscp-throughput-<uuid>` name) and a leftover from a crashed run is found and removed at the next run only if its name matches exactly that pattern.
- [ ] Tests with an in-memory file system: the order of operations, removal on each exit path including cancel mid-transfer, the byte check, the leftover sweep never touching a non-matching name. Gated (`MACSCP_ITEST=1`): SFTP on the rig ends with no file left behind.
- [ ] App panel and CLI (`macscp-cli diagnose --scope throughput`, JSON keys added only), four languages. Whole suite plus gated, zero warnings. Commit `feat(diagnostics): a throughput test to the server over the session's own protocol`.

---

### Task 3: The connection form can resolve its host name to an address

**Row:** "Offer to resolve an entered host name to its IP (maintainer wishlist)".

- [ ] An action beside the host field ("Resolve…") for SSH/SFTP sessions only — decided for the maintainer: not for S3 or WebDAV, because a TLS endpoint validates its certificate against the name and an address would not match (the row's constraint). It resolves the entered name (reuse the diagnostics resolver, made reachable through a narrow public seam rather than widening `HostResolver`) and offers the addresses as a menu (IPv4 first, then IPv6, in resolver order within each); choosing one replaces the host field's text. No address → an inline message; the field is untouched.
- [ ] Consequences stated in the UI as a one-line note under the menu (four languages): the server will be asked to confirm its host key again for the address (known hosts are keyed by host and port), and the name is not kept. Decided: nothing else changes — no automatic known-hosts copy (that would be an accept path), no hidden name field.
- [ ] Tests: the address ordering; the action is absent for S3/WebDAV; choosing an address writes only the host field; a failing lookup leaves the form unchanged; a guard that no known-hosts write happens on this path (negative beside a positive that the action exists).
- [ ] Whole suite, zero warnings. Commit `feat(connect): the connection form can swap a host name for one of its addresses`.

---

### Task 4: The terminal type is a setting with a per-session override

**Row:** "Terminal emulation type (maintainer wishlist)".

- [ ] Measure first which terminal names SwiftTerm renders faithfully: read SwiftTerm's own terminfo/`TERM` handling and its emulation (it is an xterm-compatible emulator) and decide from that which names are honest to offer. Decided for the maintainer, subject to the measurement: offer `xterm-256color` (default, today's value), `xterm`, and `vt100`; offer `linux` or `screen`/`tmux` names only if the reading shows SwiftTerm handles their differences; write the reasoning into the report and the row.
- [ ] A global setting in Settings → Terminal and a per-session override in the session editor ("Use the global setting" as the default); the value reaches `openShell(terminal:…)` in `TerminalPanelViewModel` instead of the literal. Stored sessions without the field decode as "use the global setting" (backward compatible; test decoding an old `sessions.json`). The CLI does not open shells, so nothing changes there — state it.
- [ ] Tests: resolution order (session override → global → default); the value passed to `openShell`; old-file decoding; catalogue entries in four languages; a guard that `TerminalPanelViewModel` no longer passes a literal terminal name (negative beside a positive that it reads the resolved value).
- [ ] Whole suite plus the gated SSH suites (the rig's shell receives the chosen `TERM`: assert `echo $TERM` for one non-default value), zero warnings. Commit `feat(terminal): the terminal type is a setting with a per-session override`.

---

### Task 5: Closeout

- [ ] `docs/BACKLOG.md`: each row named above gets a **Done 2026-09-19** sentence leading the row (the original text stays after it as history) with its commits; open remainders get their own rows grouped by feature; the decisions taken for the maintainer (Tasks 1-4) are listed in the rows so they can be overturned; this plan's sight checks join a grouped sight-check row for 2026-09-19. This plan's `- [ ]` step boxes ticked (not the header line). Commit `docs(backlog): diagnostics and terminal wishes of 2026-09-19 are recorded`.

## Self-review

- Coverage: reverse DNS → Task 1; the server half of the speed test → Task 2; resolve-to-IP → Task 3; terminal type → Task 4. Left out with reasons in the Global Constraints: themes, compression, the internet speed test.
- Placeholders: Task 4 starts with a reading that can narrow the offered list; each task's decisions are named.
- Type consistency: `RemoteFileSystem`, `HostResolver`, `openShell(terminal:cols:rows:)`, `TerminalPanelViewModel` exist at `af05535a`.
