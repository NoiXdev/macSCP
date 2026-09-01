# P2 — Completion Report (Terminal edition)

**Status:** completed 2026-08-18. HEAD before this report:
`6c7d20b69578b72bbb6af75b71d45f976d6b3fcc`. Spec:
`2026-08-10-snippets-runde-2-design.md`, section "P2". Plan:
`../plans/2026-08-12-p2-terminal-fassung.md`. Ledger:
`.superpowers/sdd/2026-08-12-p2-terminal-fassung/progress.md`.

## Correction to the completion brief

The brief for this task describes "the phase in five commits
(`36cc3c0..HEAD`)" and in doing so lists all four task contents (edge
unification, `PaneVisibility` model, toolbar switches, persistence). That is
wrong: `git log 36cc3c0..HEAD` returns exactly **five** commits, but they
belong exclusively to Task 3 and Task 4 (the two toolbar switches +
critical fix, then persistence + its fix). Edge unification (Task 1) and the
`PaneVisibility` model (Task 2) sit **before** `36cc3c0`, i.e. outside this
range. The actual phase — from the plan commit to `HEAD` — is **nine**
commits, not five:

```
$ git rev-list --count 55d9dad..HEAD
9
$ git log --oneline --reverse 55d9dad..HEAD
acda5ca feat(app): give the terminal the inset the rest of the panel already uses
0ac5537 fix(app): unify the terminal panel's inset on the spec's decided 14/8
82d2c16 feat(core): decide pane visibility and which toggle is locked
36cc3c0 fix(core): enforce PaneVisibility invariant at construction, not just decode
294a2a3 feat(app): switch both window halves from the toolbar
00a57f2 fix(app): make the pane render read the same repaired visibility
66e535c test(app): guard detail's render conditions against the raw booleans
4cf2600 feat(core): remember which window halves a saved session shows
6c7d20b fix(app): restore the pane-visibility fold and pin its wiring
```

Reported rather than silently adjusted, as required by this task. All other
commands and paths in the brief (`swift test`, the `.strings` lint loop, the
`package-app` call, the checklist afterward) match reality and were run
unchanged.

## Commits of the phase

| Commit | Task | Content |
|---|---|---|
| `55d9dad` | — | Plan (= base, not phase content) |
| `acda5ca` / `0ac5537` | 1 | Terminal edge: first attempt 12/6 (own interpretation), fix round unifies onto the spec-mandated 14/8 |
| `82d2c16` / `36cc3c0` | 2 | `PaneVisibility` (Core): decision + locked last switch; fix round makes the fields `let` — violating the invariant is now a compile error |
| `294a2a3` / `00a57f2` / `66e535c` | 3 | Toolbar switches "Files"/"Terminal", critical fix: one repaired `PaneVisibility` feeds both toolbar AND layout, guard test against falling back to the raw booleans |
| `4cf2600` / `6c7d20b` | 4 | State per `StoredSession`, export/import, fix round: restore calls the same fold method instead of rebuilding it, plus a wiring guard |

## 1. Measured numbers

Measured directly in this session, not carried over from a report.

```
$ swift test 2>&1 | tail -3
✔ Suite "TerminalPanelViewModel" passed after 5.053 seconds.
✔ Test run with 1935 tests in 164 suites passed after 5.057 seconds.
```

**1935 tests / 164 suites, green** — matches the number at the end of
Task 4's fix round (Task 4 report); nothing was added or turned red between
the end of the phase and this completion.

**Eight `.strings` catalogs, `plutil -lint`:** all eight (`en/de/fr/pl` ×
`MacSCPAppKit`/`macSCPCore`) → `OK`. No new L10n keys in this phase (Task 4
adds no UI surface; Task 3's two new keys `browser.filesToggle`/
`browser.filesToggleHelp` are already included in the 1935 figure and were
already checked there against all four languages).

## 2. The dev build

```
MACSCP_VERSION="1.2.0-dev" MACSCP_BUILD="$(git rev-list --count HEAD)" ./scripts/package-app
```

Started in the background while the test measurement and the later
`if false` probe (section 3) ran in the foreground — no commit was added
afterward that could make it stale.

| Check | Result |
|---|---|
| Build | `Build complete!` (arm64 + x86_64, each individually) |
| `lipo -archs` on `dist/macSCP.app/Contents/MacOS/macSCP` | `x86_64 arm64` |
| `lipo -archs` on `dist/macSCP.app/Contents/MacOS/macscp-cli` | `x86_64 arm64` |
| Resource bundles | `macSCP_MacSCPAppKit.bundle`, `macSCP_macSCPCore.bundle` — both present |
| `.lproj` under `Contents/Resources` | `en`, `de`, `fr`, `pl` — all four present |
| `plutil -lint dist/macSCP.app/Contents/Info.plist` | `OK` |
| `CFBundleShortVersionString` / `CFBundleVersion` | `1.2.0-dev` / `940` — matches `git rev-list --count HEAD` |
| `scripts/release` | **not run** (published) |
| GUI | **not started** — see section 4 |

These checks are deliberately done twice: `package-app` itself aborts under
`set -euo pipefail` if any of the checks fail, but this task then
independently ran them again itself, rather than trusting only the script's
exit code.

## 3. What is held by tests — and what is only by review

This phase relies on **three source-reading guards**, all built on the same
pattern established in `SnippetMenuItemsKeyboardShortcutGuardTests` (no
rendering test tool in the project, see the P1 completion report):

1. **`TerminalPanelInsetTests`** (Task 1) — scans the `.running`/`.opening`
   and `TerminalPanelHeader` regions for numeric literals instead of the
   shared `DesignTokens` constants.
2. **`PaneRenderConditionGuardTests`** (Task 3, fix round 2) — scans
   `detail`'s body to confirm that no `if tab.showsFiles`/`if
   session.terminal.isVisible` reads the raw booleans directly anymore, and
   that both render conditions are derived from the same
   `effectivePaneVisibility`. Exists because that was exactly the critical
   finding of the round: the method was correct but not wired in, and no
   other test would have noticed.
3. **`PaneVisibilityWiringGuardTests`** (Task 4, fix round 1) — scans that
   `connect(in:stored:)` calls `restorePaneVisibility(` and that all three
   toggle sites in `ContentView+Lifecycle.swift` are followed by
   `persistActivePaneVisibility()`.

**Each of the three has documented blind spots** — line-based, not
control-flow-based. For the third, the sharpest of these spots was not
merely asserted in this session but **reenacted**: the
`connectRestoresPaneVisibility` check only tests whether the string
`restorePaneVisibility(` occurs anywhere in the function body — not whether
the call is reachable on every path. Probe (file restored byte-identical
afterward, confirmed via `diff`):

```
$ sed -i '' 's/restorePaneVisibility(for: tab, from: stored, descriptor: descriptor)/if false { restorePaneVisibility(for: tab, from: stored, descriptor: descriptor) }/' \
    Sources/MacSCPAppKit/ContentView.swift
$ swift test --filter "PaneVisibilityWiringGuardTests"
✔ Test connectRestoresPaneVisibility() passed after 0.003 seconds.
✔ Suite "Pane visibility wiring guard" passed after 0.003 seconds.
✔ Test run with 6 tests in 1 suite passed after 0.003 seconds.
```

The guard stays green even though the call is effectively dead through
`if false` — **verified, not assumed**, as the brief requires. This is the
same blind spot that Task 4's own report had already named ("a
reachability/control-flow check" is missing), but there only read about,
here actually reproduced.

**What is NOT held by a test in each case, only by reading:**

- Whether the three App-side call sites (`restorePaneVisibility`,
  `persistActivePaneVisibility` at the three toggle sites) actually do the
  right thing at runtime — the project has no view-instantiation tool,
  `ContentView` is never built in the test target.
- Whether automatically opening the shell on restore triggers no second
  connection setup, no repeated TOFU check, and no audit entry (Task 4's
  rationale) — verified by reading code (call chain traced through to
  `CitadelShell.open` on the same client, `AuditEvent.Kind` checked for
  having no shell case), not by a test that actually connects.
- External terminal mode: the terminal button deliberately bypasses the
  pane lock (gated only on `activeTabSupportsShell`), because this mode
  never touches `isVisible` — read, not pinned.

## 4. What export does with the new field, and why

The question was explicitly left open in the plan ("what does export do
today with `groupID`?", "report rather than adjust"). Task 4's answer, from
reading the existing code rather than an invented rule:

`SessionListViewModel.exportPayload` **always** carries `groupID` along
when the export scope includes groups — it is a top-level field on
`ExportedSession`, outside the backend's field bag (`fields`), so it does
not get lost in a round trip. On import, though, `SessionImportPlanner`
does **not** copy `groupID` literally: it is a reference into the
file-local group list, which gets rewritten onto a matching existing or
newly created group — otherwise an import would either collide with an
unrelated local group sharing the same UUID, or point at nothing.

**`paneVisibility` follows the same category, not the same mechanism.**
Like `groupID` it is a fact about the session, not a backend field — so it
also lives as a top-level field, not in the field bag — and on export it is
written **unconditionally** (unlike `groupID`, which is gated behind
`includeGroups`: that flag specifically concerns group membership,
`paneVisibility` is not one). But it needs NO rewriting on import, because
it is not a reference to something else in the file, but a plain value —
import therefore copies it literally, with a default fallback (`??
.bothVisible`) for files without the field.

`ExportedSession.paneVisibility` is, like `kind` in the same file, optional
and decodes to `nil` on legal legacy files; the `?? .bothVisible` default is
applied only on import in `makePlanned`, not already at decode time.
`StoredSession.paneVisibility`, by contrast, is non-optional with the
default directly in its own `init(from:)`, exactly like
`StoredSession.kind`. Both therefore follow the pattern their respective
type had already established for `kind` — not `groupID`'s pattern, which
does not fit here.

## 5. The GUI was not started

Explicitly, for the entire course of this phase (Tasks 1–5): no `open`, no
window invocation. Everything above rests on `swift test`, `swift
build`/`package-app`, and reading source. The following must be looked at
by the maintainer:

1. **The new edge** — 14 horizontal / 8 vertical around the terminal
   surface (`.running`/`.opening` state), now at the same value as the
   `.ended` text block and the header row. Whether this actually feels
   flush visually is a visual inspection; the three numbers themselves are
   only source-verified (`TerminalPanelInsetTests`).
2. **The two toolbar switches** "Files" and "Terminal" — whether they
   actually show/hide both window halves independently, whether their
   visual state (active/inactive) matches the actual panel state.
3. **The locked last switch** — whether it visibly shows itself disabled
   (not merely reacts without effect) when it is the last visible half;
   whether that correctly greys out the terminal switch for a session
   without a shell (S3/WebDAV), and "Files" is thereby locked.
4. **Above all: whether a reopened session actually comes up the way it
   last stood.** That is the core of Task 4 and the least verified part of
   this phase — the persistence and wiring logic is covered by tests and
   the two guards from section 3, but **no runtime smoke test of the chain
   toggle → disconnect → reconnect was performed in this or a previous
   session.** Neither "terminal off, files on, disconnect, reconnect,
   terminal stays off" nor the reverse case has ever been observed on a
   running app.

## 6. Carried forward from the ledger — open minor findings

None fixed in this phase, because each was outside the scope of its
respective task or stands as a deliberate, documented decision:

1. **`PaneRenderConditionGuardTests` is line-/literal-based** (Task 3):
   `if tab.showsFiles == true`, a condition split across multiple lines, a
   rename of `visibility`/`tab`, or a third render site outside `detail`
   would not be caught by it.
2. **External terminal mode bypasses the pane lock** (Task 3): deliberate,
   since this mode never touches `isVisible`.
3. **Restore opens the built-in panel even when
   `settingsStore.terminalTarget != .builtIn`** (Task 4): inconsistent, but
   not a trap — the panel remains closable.
4. **`PaneVisibilityWiringGuardTests`'s connect-path check is textual, not
   a control-flow check** (Task 4) — reenacted in section 3 of this
   session, not merely carried over.

## 7. What remains open

- The four minor findings from section 6.
- **The visual inspections from section 5** — especially item 4
  (reopening a session), not yet done.
- **Release backlog:** `git rev-list --count origin/develop..develop` →
  **62**; `git rev-list --count origin/main..develop` → **472**. Kept
  growing since the P1 completion (then 47/457).
- **P3 from the spec** — host tags on `StoredSession`, sidebar filter,
  import/export of snippets through the envelope machinery from M19. So
  far only sketched, not part of this phase.
- **Multi-window** remains, per project rule, v2 — a separate window for a
  pure terminal was therefore excluded from the start, see spec.

## For the release notes

**One sentence:** Terminal and file view can now be shown and hidden
independently, and the choice is preserved per saved session.

---

## Addendum: maintainer ruling on the default (re-review of the fix round)

**A missing `paneVisibility` means: files only, no terminal.**

The original default `.bothVisible` was wrong, and consequentially so:
`restorePaneVisibility` **opens** the panel and starts a shell whenever a
saved session had the terminal visible — so every existing saved session
would have gotten a terminal on its next connect. The doc comment claimed
the opposite ("exactly how every session behaved before this field
existed") and was the one statement in the field that no test had
observed.

As of `74d8c2b`, `PaneVisibility.filesOnly` is the one spelling for
"nothing recorded" (`StoredSession` default and decode, import planner,
lenient decode). `bothVisible` remains a valid value, but is no longer a
default. An **explicitly** stored `showsTerminal: true` still restores the
terminal; a missing field and an explicit
`{showsFiles: true, showsTerminal: false}` are equivalent on connect —
both cases are pinned side by side, so that this does not turn into "a
terminal is never restored".

In addition, `restorePaneVisibility` now has real behavioral coverage for
the first time: the decision now lives in
`SessionTab.applyRestoredPaneVisibility(_: hasShell:)`, and `ContentView`
retains only the `toggle()` call. Suite after the round: **1958 tests /
166 suites**.
