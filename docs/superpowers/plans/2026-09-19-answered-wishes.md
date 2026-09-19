# The answered wishes of 2026-09-19 — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build what the maintainer decided in chat on 2026-09-19: a forwarding that stops looking healthy after three failed connections, the managed key's passphrase winning over a stale jump slot, terminal themes as presets plus iTerm2 import, an internet speed test whose service is a setting (Cloudflare by default), and a measured answer on SSH compression upstream.

**Architecture:** Six tasks. Task 1 is the forwarding glyph. Task 2 is the jump-secret precedence (a recorded bug, now decided). Task 3 is terminal themes. Task 4 is the internet half of the speed test. Task 5 is the upstream compression measurement, which writes a record and no product code. Task 6 is the closeout. Every task names its `docs/BACKLOG.md` row by title; read the row first, including the maintainer's answer appended to it, and re-verify its anchors with `grep -n`.

**Tech Stack:** Swift 6 strict, SwiftPM (Xcode 27 / Swift 6.4 locally; CI Swift 6.1.2, macos-15, three cores, zero-warning budget), Swift Testing, SwiftUI/AppKit, SwiftTerm, the Docker rig (from the MAIN checkout).

## Global Constraints

- The maintainer's answers of 2026-09-19 bind, and each is recorded at the end of its BACKLOG row: orange after three failed connections in a row, green again after the next success; the managed key's passphrase wins; presets plus `.itermcolors` import, no editor; the speed-test service is a setting, default Cloudflare; compression starts with an upstream check.
- **User documentation ships with the feature** (CLAUDE.md, 2026-09-19). Every task that changes something a user sees also writes it into the docs worktree at `/private/tmp/claude-501/-Users-noidee-macSCP/c68e1585-ea4f-4194-a037-c8f1c3a96a0d/scratchpad/noix-docs-macscp`, branch `docs/macscp-next`, marked `*(next version)*`, with `npm run build` and `npm run check` green, committed there and not pushed. No tech-stack terms in those pages.
- TOFU is a hard stop; no accept-anything path. No secret in any store, state, log, reason, report or test message; no real host names in tests; the rig from the MAIN checkout only, and never `minio`.
- Swift Testing, red first (recorded); tests never block the cooperative pool; no wall-clock ceiling, and no fake that finishes on its own while a deadline races it; no `#require` on a non-optional. Nothing new may compile only on Swift 6.4.
- Every App string through `L10n.string(_:_:)` in `en`, `de`, `fr`, `pl` (German du-form); plurals through `Localizable.stringsdict`. Settings keys go through `SettingsStore`. The CLI's JSON: add keys, never rename.
- Source-scanning guards read through `Tests/MacSCPTestSupport/SourceCorpus.swift`; a negative check keeps a positive beside it. Scripted edits assert their anchor; probes are reverted with a file-scoped reverse patch verified by `cmp`.
- Subagents work in the FOREGROUND only. If the first build fails on a stale Metal toolchain path, delete the stale `XCBuildData` caches under `.build/out/Intermediates.noindex/` and rebuild.
- Zero compiler warnings. Conventional Commits, English, one blank line before the footer `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. Do not push; do not launch the GUI; do not stage `docs/BACKLOG.md` before Task 6.

---

### Task 1: A forwarding that keeps failing stops looking healthy

**Row:** "A forwarding that fails every connection still shows a green glyph and badge" (read the maintainer's answer at its end).

- [ ] A pure rule over the forwarding's own report stream: three connection failures in a row with no success between them make the state read "degraded" for the glyph and the badge; the next successful connection clears it. No new lifecycle state is added — the maintainer's 2026-09-16 ruling stands — so this is a presentation flag on the existing `.active` state. Read how `TunnelState` and the menu, list and badge read it today.
- [ ] Tests: two failures keep it green; the third turns it orange; a success between resets the count; a success after three turns it green again; a stop or restart clears the count. Pure, with no clock.
- [ ] The glyph, the menu item, the list row and the tooltip say it, in four languages. The CLI's `tunnels` output gains a key for it if it already reports state (add, never rename).
- [ ] Whole suite, zero warnings; docs updated in the docs worktree (the tunnels page). Commit `feat(tunnels): a forwarding that keeps failing stops reading healthy`.

---

### Task 2: The managed key's passphrase wins over a stale jump slot

**Row:** "A stale own jump slot wins over the managed key's slot, and the save guard silently skips a typed correction" (read the maintainer's answer at its end).

- [ ] Read `LoginResolver.fallingBackToManagedKeyPassphrase` and the save guard the row names. Change the precedence: for a hop whose key is managed, the managed key's passphrase is used, and the hop's own stored slot is only used when the managed store has none.
- [ ] The second half of the row: a typed correction must not be skipped by the save guard. Decide what "typed correction" means in the current code, state it, and make it save.
- [ ] Tests, red first: a stale own slot plus a managed passphrase connects with the managed one; a managed key with no passphrase falls back to the own slot; a typed correction is saved; no test message or log carries a secret (named constants, Bool computed first).
- [ ] Whole suite plus the gated key suites; zero warnings; docs updated if the behaviour is visible (the authentication page). Commit `fix(keys): a managed key's passphrase wins over the hop's own slot`.

---

### Task 3: Terminal themes — presets and iTerm2 import

**Row:** "Custom terminal themes (maintainer wishlist)" (read the maintainer's answer at its end).

- [ ] A theme is the terminal's background, foreground, cursor and the 16 ANSI colours. Ship a small set of presets (at least the current look as "macSCP", one light and one dark); read how `SSHTerminalView` takes its colours from `DesignTokens` today, and how SwiftTerm's `installColors(_:)` works at the pinned revision.
- [ ] Import an iTerm2 colour file (`.itermcolors`, a property list of colour components): a pure parser with tests over recorded sample files you write yourself (no third-party file committed without its licence — state what you used). A file that does not parse is refused with a fixed message, never a raw parser error.
- [ ] Decided for the maintainer, because the row leaves it open: the theme is a global setting in Settings → Terminal, with no per-session override in this task (the terminal type already has one; a per-session theme can follow if asked).
- [ ] Tests: the parser (valid, missing keys, out-of-range components, a hostile file), the resolution (imported theme, preset, default), the stored value surviving a restart, and a guard that the terminal view takes its colours from the resolved theme rather than the tokens directly.
- [ ] Whole suite, zero warnings; docs updated (the terminal page: presets, import, where the file comes from). Commit `feat(terminal): themes as presets and an iTerm2 import`.

---

### Task 4: The internet speed test

**Row:** "A speed test in diagnostics (maintainer wishlist)" (read the maintainer's answer at its end; the server half is already Done).

- [ ] A second diagnostics step, in its own scope beside `throughput`, that measures the internet connection rather than the server: download and upload against a service chosen in Settings. Default Cloudflare (`speed.cloudflare.com`), and at least one alternative plus "off"; the setting names the service, never a free-text URL a page could inject.
- [ ] It runs only when the user chooses that scope. It sends no session data, no credential and no host name to the service, and the report says which service was used. State the payload sizes and make them a setting or a fixed pair, with a bound so a slow line cannot run forever (no wall-clock assertion in tests).
- [ ] Tests with an injected transport: the rate is computed from bytes and elapsed time (inject the clock); a refused or slow service reads `unavailable` with a reason, never a failure of the session; the scope runs nothing else; no credential or host reaches the request. Gated live runs are not part of the suite.
- [ ] Whole suite, zero warnings; docs updated (the diagnostics page and the Settings table). Commit `feat(diagnostics): an internet speed test whose service is a setting`.

---

### Task 5: Does upstream carry SSH compression?

**Row:** "SSH compression as a setting and a session flag (maintainer wishlist)" (read the maintainer's answer at its end).

- [ ] Measure, and write a record; change no product code. For `apple/swift-nio-ssh` and `orlandos-nl/Citadel`: does either offer `zlib` or `zlib@openssh.com` today, and is there an open PR or issue for it? Use `git log`, `gh api` and the checkouts under `.build/checkouts`. Count what you find, with dates and commit or PR numbers.
- [ ] Also measure what a fork change would cost: which files the key exchange's algorithm lists live in, whether the packet layer has a seam for a compressor, and what the fork record (`docs/superpowers/specs/2026-08-20-backlog-dependencies.md`) says about the current distance from upstream.
- [ ] Write the answer into the dependencies record and into the BACKLOG row as a dated measurement, with a recommendation the maintainer can accept or refuse. No product change, no fork change.
- [ ] Commit `docs(deps): what upstream offers for SSH compression, measured`.

---

### Task 6: Closeout

- [ ] `docs/BACKLOG.md`: each row named above gets a **Done 2026-09-19** (or the day the work lands) sentence leading the row, with its commits; open remainders get their own rows; the decisions taken for the maintainer in Tasks 3 and 4 are listed so they can be overturned; the sight checks join the grouped sight-check row. This plan's step boxes ticked. The docs worktree's commits are named in the report. Commit `docs(backlog): the answered wishes of 2026-09-19 are recorded`.

## Self-review

- Coverage: the five answered rows → Tasks 1-5; the sixth task is the closeout.
- Placeholders: Task 2's "typed correction" and Task 4's payload sizes are decisions the implementer states; Task 5 is a measurement whose outcome is the deliverable.
- Type consistency: `TunnelState`, `LoginResolver.fallingBackToManagedKeyPassphrase`, `SSHTerminalView`, `DesignTokens`, `SettingsStore` and the diagnostics scopes exist at `feadb900`.
