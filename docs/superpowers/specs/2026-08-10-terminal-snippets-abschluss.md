# Terminal Snippets — Completion Report

**Status:** completed 2026-08-10. HEAD before this report: `d1db769`.

Reusable command lines that can be inserted from the terminal menu into the
SSH terminal panel — or, when explicitly marked, executed immediately.
`Snippet`, `SnippetStore` and `SnippetKeystrokes` live in Core and are
fully covered by tests; `SnippetsSheet` and the menu wiring are on the
app side and remain unpinned.

The milestone has **two real findings**, and neither sits where the plan
would have expected it: the line terminator had to be measured, and
triggering a snippet would have run **silently into the void** on a
freshly connected tab. Both are covered below in their own sections.

Spec: `2026-08-10-terminal-snippets-design.md`.
Plan: `../plans/2026-08-10-terminal-snippets.md`.

## Commits

Base of the milestone: `7a1777b` (the plan commit itself).

| Commit | Content |
|---|---|
| `7a1777b` | Plan (= base) |
| `f7457d6` | T1 — `Snippet` + `SnippetStore` |
| `af9dba2` | T2 — `SnippetKeystrokes` and the **measured** line terminator |
| `1ae8416` | T2 fix round — two overreaching comment claims |
| `7b4d92c` | T3 — `SnippetsSheet` |
| `b8152c0` | T4 — entries in the terminal menu + shortcuts catalog |
| `d1db769` | T4 fix round — the wait policy moved to Core, `Divider()`, silent timeout removed |

**Unpushed:** `git rev-list --count origin/develop..develop` → **9** before
this report, **10** after. **Release backlog:**
`git rev-list --count origin/main..develop` → **419** (420 after this
commit); the spec named 410 at the start, M29-P2 named 408.

Milestone diff (`git diff --shortstat -M 7a1777b..HEAD -- Sources Tests`):
**15 files, +1060 / −2**. The three new Core files carry +60
(`Snippet.swift`), +49 (`SnippetKeystrokes.swift`) and +46
(`SnippetStore.swift`), the new app file `SnippetsSheet.swift` +308; the
two new test files +81 and +91.

## Verification at completion

Everything below was **run in this session**. Where something is taken
over from a task report, that is stated explicitly.

| Run | Result |
|---|---|
| `swift build` | `Build complete! (5.34s)` |
| `swift test` | **1749 tests in 143 suites, green** (3.655 s) |
| `docker compose -f docker/test-server/compose.yml up -d` | rig up (sshd, sshd-2, minio, minio-init, webdav), started from the **main checkout** |
| `MACSCP_ITEST=1 swift test` | **1749 tests in 143 suites, green** (12.449 s) |
| `MACSCP_KEYCHAIN=1 swift test --filter Keychain` | **29 tests in 11 suites, green** (0.066 s) |
| `plutil -lint` over all eight catalogs (4× App, 4× Core) | every file `OK` |
| `pgrep -fl swiftpm-testing-helper` | no hits, no orphans |
| `git status --porcelain` | empty before the report commit, and also after the mutation probe below |
| `scripts/release` | **not run** (binding requirement) |
| GUI | **not started** (binding requirement) |

**That the gated suite really ran** is legible from the runtime
(3.655 s ungated versus 12.449 s gated) and from the output naming the
suite `CitadelFileSystem against Docker SSH server` by name. The test
count is identical in both runs because the integration tests internally
return early via the environment variable — the same explanation as
since M24.

**The 0% CPU hang known since M20 did not occur in either run.** An
observation, not proof of its absence.

### Test counts, before and after

The **before** number is not carried forward, it is measured: the base
commit `7a1777b` was checked out into its own worktree and `swift test`
run there (the worktree was then removed). The value confirms the number
the task briefs stated — but here it is the measurement, not an
inheritance of it.

| | Base `7a1777b` | HEAD `d1db769` |
|---|---|---|
| Total | **1735 tests / 141 suites** | **1749 tests / 143 suites** |

So **+14 tests, +2 suites**. The difference is fully accounted for and
counted out:

| Suite / file | new `@Test` |
|---|---|
| `SnippetStoreTests` (new suite) | 6 |
| `SnippetKeystrokesTests` (new suite) | 4 |
| `TerminalPanelViewModelTests` (existing suite) | 4 |
| **Sum** | **14** |

No existing test changed status.

## The ten success criteria

Evidence names test names and symbols, **never line numbers**.

| # | Criterion | Result | Evidence |
|---|---|---|---|
| 1 | An inserted snippet ends **without** a line terminator | **met** | `anInsertingSnippetEndsWithoutATerminator` checks the bytes produced by `SnippetKeystrokes.bytes(for:)` |
| 2 | An executing snippet ends with **exactly one** line terminator, the one from the return key | **met** | `anExecutingSnippetAppendsExactlyOneTerminator` (exactly one extra byte) and `theTerminatorIsCarriageReturn` (it is `0x0D`). The byte is **measured** — own section below |
| 3 | A command containing a line break is rejected | **met** | `aCommandWithALineBreakIsRefused` (initializer, `\n` and `\r`) and `aHandEditedMultiLineCommandDoesNotDecode` (JSON literal, i.e. a hand-edited store) |
| 4 | The store survives writing and reading unchanged | **met** | `aSavedSnippetSurvivesTheRoundTrip`; plus `savingTheSameIdTwiceReplaces` and `removingAnIdLeavesTheOthers` |
| 5 | A missing store returns an empty list, not an error | **met** | `aMissingFileReadsAsAnEmptyList` |
| 6 | Executing snippets appear in the menu in their own section | **review point; the marking itself checked since the fix round** | see the dedicated paragraph below |
| 7 | Entries are disabled without a connected session | **review point, no test** | see the dedicated paragraph below |
| 8 | The store never contains a secret | **met, read as a commitment** | `Snippet`'s doc comment states it on the type ("Never holds credentials… this project keeps secrets exclusively in the Keychain"). The editor in the sheet carries the same note with a rationale. There is **no** test that could enforce the absence of a secret — snippets are free text |
| 9 | All four catalogs carry the new keys | **met** | **22** new keys in `en` (with the fix round below: **25**); the key-set difference against `en` is **empty** for `de`, `fr` and `pl` (counted out from the milestone diff). The guard `LocalizableStringsTests` (`appLayerLanguagesMatchEnglishKeys`, `coreLayerLanguagesMatchEnglishKeys`) stays green, as does `KeyboardShortcutsCatalogTests.everyLabelKeyResolves`; `plutil -lint` on all eight catalogs `OK`. This milestone did NOT touch the **Core** catalogs — they were still linted along with the rest |
| 10 | The shortcuts catalog names the new shortcuts | **met** | New group `settings.shortcuts.group.snippets` with the line `settings.shortcuts.label.insertSnippet` / "Insert snippet 1–3" / glyph `⌃⌘1–3`; in addition the shortcut enumeration in the catalog's own doc comment (finding site 1, the SwiftUI menus) is extended with `⌃⌘1–3` — both spots the catalog itself names as mandatory |

### Criteria 6 and 7: review, not test

**Both were explicitly not tests at completion, and this report claimed
no test coverage for them.** The menu wiring is on the app side, and this
project cannot render a `View` — the same boundary M29 exposed. What was
in place at completion was code that had been read. *(Partially
superseded: the fix round pulled the marking from criterion 6 into a pure
function and tested it there — the menu itself still renders under no
test. See the insert under criterion 6.)*

- **Criterion 6:** `MacSCPApp.snippetMenuItems` splits the list into
  `inserting` and `executing`. Between the two sits an explicit
  `Divider()`, above that a `Section` titled
  `menu.snippets.runsImmediately`. The separation deliberately rests on
  the divider: **nobody has seen how `Section` draws its title in a menu
  bar menu.** The title is the bonus, the divider the load-bearing
  part — that's also what the function's doc comment says.

  > **Wrong, corrected in the fix round (`429fdaf`).** The sentence "the
  > divider is the load-bearing part" has no basis: `snippetMenuItems`
  > set **three** equally-ranked `Divider()`s — before the snippet
  > block, before the `Section`, before "Manage Snippets…". A divider
  > therefore marks nothing in particular; the insert band looked like
  > the execute band looked like the management band. Only the
  > `Section` title would have carried the distinction — exactly the
  > piece nobody has seen drawn.
  > **New:** the marking now sits in the title of the entry itself
  > (`SnippetMenuEntry.title(for:)`, key
  > `menu.snippets.executingItem`, "%@ (runs immediately)"). A title is
  > text the menu reliably draws, and it holds even when there are no
  > inserting snippets at all and the grouping has nothing left to
  > contrast against. Grouping and the `Section` title remain as a
  > bonus. The function's doc comment now says both things this way.
  > **And with that, tested for the first time:**
  > `onlyAnExecutingEntryIsMarkedInItsTitle` and
  > `theExecutingMarkerResolvesFromTheCatalog` in
  > `SnippetsPresentationTests` (app test target `macSCPAppKitTests`,
  > which has existed since M29-P1). The menu itself still renders under
  > no test — what is tested is the title it gets.
- **Criterion 7:** every snippet entry in `MacSCPApp.snippetButton`
  carries the same expression as the two pre-existing entries of the
  menu, `!tabCommands.isActiveTabConnected || !tabCommands.activeTabSupportsShell`
  — taken over character-for-character, not newly derived. "Manage
  Snippets…" is deliberately **not** disabled; that follows the Sessions
  menu, whose management entries likewise carry no `.disabled`.

So far only a reader of the source has seen either of these. **The
maintainer's visual check is still outstanding.**

## Finding 1: The line terminator is measured, not assumed

**Result: CR, `0x0D`. Not LF.**

The spec deliberately did not commit to this and only required that the
answer be measured. That was the right caution: **a plan that had
asserted `\n` would have shipped a snippet marked "run immediately" that
silently does nothing** — the text lands on the input line and just sits
there.

The chain, worked through in Task 2 and **independently retraced in this
session against the pinned revision**:

1. `Package.swift` pins SwiftTerm to a fixed revision; the checkout
   under `.build/checkouts/SwiftTerm` reports exactly this as `HEAD`. So
   the code read was the code this package actually builds against.
2. An unmodified return key falls through all special-case branches in
   `MacTerminalView.keyDown(with:)` and is turned by AppKit into the
   command `insertNewline(_:)`.
3. `doCommand(by:)` answers `#selector(insertNewline(_:))` with
   `send(EscapeSequences.cmdRet)`.
4. `EscapeSequences.cmdRet` is `[ 13 ]` — one byte, `0x0D`, neither LF nor
   a CR-LF pair.
5. The bytes reach `TerminalPanelViewModel.send(_:)` unchanged via
   `SSHTerminalView.Coordinator.send(source:data:)`.

Three counter-checks from Task 2 that support the finding:

- **LF is declared but dead.** `EscapeSequences.cmdNewLine` (`[ 10 ]`)
  has exactly **one** hit across the whole `Sources/SwiftTerm` tree: the
  declaration itself. Recounted in this session — still one.
- **LNM / `convertEol` does not touch the input.** `Terminal.lineFeedMode`
  is only read in output handling and mode-report handling, at no
  keyboard input site.
- **The Kitty path confirms the legacy encoding.** Without
  report-all-keys, an unmodified return key lands on
  `legacySpecialKeySequence` → `[ControlCodes.CR]` = `0x0d`.

**The finding's boundary, explicitly:** this is a **static source-code
trace, not a runtime capture** — the GUI was not started, neither in
Task 2 nor here. It is the strongest evidence obtainable without starting
the app, and it claims no more than that.

**And it is not mode-independent.** The first draft of the comment
claimed that; the review rejected it and `1ae8416` corrected it. When a
program negotiates the report-all-keys tier of the Kitty keyboard
protocol, a real return keypress is encoded as `ESC [ 13 u`; in that mode
a snippet's bare CR is **not** byte-identical to a keypress. The
deliberately assumed scope is the legacy encoding at the shell prompt —
exactly what a snippet targets. `SnippetKeystrokes`'s doc comment now
says this itself, complete with a pointer to
`theTerminatorIsCarriageReturn` as the location of the full evidence
chain.

## Finding 2: Triggering would have run silently into the void

Found in Task 4, while reading `TerminalPanelViewModel` — the plan had
nothing on this.

`send(_:)` began with `guard let shell else { return }`. The panel starts
closed (`isVisible = false`, `state = .closed`). A snippet on a freshly
connected tab — **exactly the moment the menu entries first become
enabled** — would have opened the panel and sent its bytes into that same
`guard`: swallowed, without a trace. The spec says an entry that runs
into the void is worse than a greyed-out one; here it would have run into
the void without being greyed out.

The first draft waited in the view with a bounded poll. The review pushed
back: the timeout was itself silent and thereby reproduced exactly the
defect it was meant to fix, and the policy sat untestable in view code.
The fix round moved it to Core — and in doing so **it became smaller than
the poll it replaced**: `send(_:)` buffers while `state == .opening`, and
`flushPendingBytes()` plays it back in the same synchronous step that
sets `.running`. That leaves no timeout that could ever expire. In the
view, three straightforward calls remain: show the panel →
`openIfNeeded()` → `send(...)`.

**And it fixed a pre-existing bug along the way:** keystrokes typed into
the panel during `.opening` fell through the same `guard` — the panel
mounts `SSHTerminalView` for `.opening` too. They are now delivered as
well. That was not the goal, but a by-product of fixing the bug at its
root instead of at the call site.

Four new tests hold this (`sendDuringOpeningIsDeliveredOnceRunning`,
`bytesHeldWhileOpeningKeepTheirOrder`,
`bytesHeldWhileOpeningAreDroppedWhenTheOpenFails`,
`bytesHeldWhileOpeningAreBounded`). **Three of them were demonstrably
red** — the red output is in the Task 4 report and **was not reproduced
in this session**. The fourth is honestly named for what it is: it
guards against the new failure mode the fix introduces (a stale buffer
replaying into a later shell) and is trivially green without the fix.

### Remeasured: the four clear sites and the two `replayBuffer` sites

The Task 4 report states the buffer is cleared at four sites, "each next
to the existing `replayBuffer` reset it sits beside". **The second half
of that sentence is not true, and this report does not carry it
forward.** Recounted in `TerminalPanelViewModel`:

| | Sites |
|---|---|
| `pendingBytes = []` as a lifecycle clear | **four** — `openIfNeeded()`, the `catch` of a failed open, `finishShell`, `shutdown()` |
| `replayBuffer = []` | **two** — `openIfNeeded()` and `shutdown()` |

So only **two** of the four clear sites even have a `replayBuffer` reset
as a neighbor; `catch` and `finishShell` have none. The narrower claim in
the source itself — that the **cap** follows the model of
`maxReplayBytes` — is correct, though, and stands.

### Remeasured: one of the four clears is dead code

The clear in the `catch` of a failed open is **inert**, but its comment
presents it as load-bearing ("Whatever was buffered was meant for THIS
attempt's shell — there is none…").

Two independent measurements:

1. **Reachability.** The only reader of the buffer is
   `flushPendingBytes()`, and it is reached exclusively on the success
   path of `openIfNeeded()` — which is itself immediately preceded by its
   own clear. So after the `catch`, nobody can reach the bytes anymore,
   whether they stay or not.
2. **Mutation probe.** With the line and its comment removed,
   `swift test --filter TerminalPanelViewModel`: **17 tests in 1 suite,
   all green** — no test holds it, not even
   `bytesHeldWhileOpeningAreDroppedWhenTheOpenFails`. Reversion
   confirmed: `git status --porcelain` and `git diff --stat` both empty.

This is not a security hole and not a behavioral bug — the bytes are
lost either way, as they should be. It is a **comment falsehood**:
defensive redundancy presenting itself as a necessity. By the same logic,
the clears in `finishShell` and `shutdown()` are also defensive rather
than load-bearing. Left open as a small follow-up (below).

> **Done in the fix round (`53f7fe1`).** The line stays, the comment now
> says what it is: defensive, not load-bearing. It does have an
> effect, just a different one than claimed — it frees up to
> `maxPendingBytes` (64 KiB) **immediately** instead of only at the next
> `openIfNeeded()`/`shutdown()`. Rechecked at all four write sites of
> `pendingBytes`; the only reader remains `flushPendingBytes()` on the
> success path.

## What remains open from the ledger

All of the following points were deliberately deferred during the reviews.

- ~~**Empty separator band in the menu** when there are executing but
  **no** inserting snippets~~ — **done in `429fdaf`**: the middle
  divider is now only set when there is something on both sides.
- **`prefix(maxPendingBytes - count)` would crash on a negative
  argument.** Currently unreachable, because the append never runs past
  the cap; a `max(0,)` would cost nothing.
- **`resize()` still discards during `.opening`**, while `send(_:)` no
  longer does — the same `guard let shell` spot, without an `.opening`
  branch. Pre-existing asymmetry; presumably swallows the first
  `sizeChanged` of a freshly opened panel.
- **Two snippets triggered within the same `.opening` window** now
  concatenate in **defined** order instead of unspecified order — the
  result is still one composite input line either way. Held by no test,
  requested by nobody as meaningful.
- **The silent `try? await Task.sleep`** from the first draft no longer
  exists: the poll it lived in was removed entirely with the fix round.
  Done, not open — named here so the ledger line doesn't keep living on
  as an open point.
- ~~**The dead `pendingBytes = []` in the `catch`** with its misleading
  comment~~ — **done in `53f7fe1`**: the line stays, the comment now
  tells the truth (see above).

## Fix round after the whole-branch review (2026-08-10)

The review over `7a1777b..53f3b4f` came back with **fix first**: two
important items, three minor ones. All five points were rechecked
independently before being fixed; all five held up.

| Commit | Content |
|---|---|
| `53f7fe1` | Core — order in the store, `sendTask` lifecycle, comment in the `catch` |
| `429fdaf` | App — an unreadable store is now reported, executing entries carry the marking themselves |

**The third silent failure, closed.** `SnippetStore.all()` throws on a
file it cannot decode — a hand-entered multi-line command is enough. Both
readers had flattened that to `[]`: the menu showed no snippet entries,
and the management sheet — per the `ContentView` comment "the place to
notice" — wrote "No snippets yet." over a file that still contained every
snippet. Nothing is lost in the process (`save`/`remove` read first and
also throw), but there was no signal either. `SnippetsLoad` now carries
the read result instead of a bare list: the sheet shows the read error in
its existing error slot and no longer claims the store is empty; the menu
gets a **disabled hint entry** — exactly the vocabulary this menu already
uses to say "currently unavailable" —, while "Manage Snippets…" beneath
it stays active. Verified in `anUndecodableStoreIsUnreadableRatherThanEmpty`
(app test target): the same file shape as the Core test, but on the
app-side read path.

**The two minor items from Core.** `SnippetStore.save` replaced via
`removeAll` + `append` and thereby moved an edited snippet to the end —
the position-bound ⌃⌘1–3 silently drifted along with it. It now replaces
in place (`replacingAnExistingIdKeepsItsPosition`); the shortcuts
catalog's promise, "in the order the menu lists them", holds again.
`TerminalPanelViewModel` only reset `sendTask` in `shutdown()`, so after
`.ended` → reopen, a `send` to the **new** shell could queue up behind a
`send` to the closed one. A delay, not a misdelivery.
`cancelPendingSends()` now runs everywhere the current shell stops being
the target. Mutation probe: without the fix,
`aSendToAnEndedShellDoesNotDelayTheNextOne` fails after 2.8 s, with the
fix it runs green in 0.08 s.

**Catalogs.** Three new keys (`snippets.load.error`,
`menu.snippets.executingItem`, `menu.snippets.unreadable`) in all four app
catalogs; the milestone sum thereby rises from **22** to **25** (counted
via `git diff 7a1777b~1 -- …/en.lproj/Localizable.strings`).
`plutil -lint` on all **eight** catalogs: OK. **FR and PL are
machine-generated and unreviewed.**

**Suite:** **1756 tests in 144 suites**, green (previously 1749 in 143).
`swift build` including the app target clean.

**What this round did NOT verify:** the surface. The app was again not
started — the hint entry in the menu, the error text in the sheet, and
the title marking are read, tested source code; nobody has seen them.

## What is NOT verified in this report

- **The entire surface.** The app was **not started** — binding
  requirement. So **nobody has seen**: the two sections in the terminal
  menu, how `Section` draws its title "Runs Immediately" (or whether at
  all), the greyed-out state of the entries without a connection, the
  `SnippetsSheet` with list, search field, editor and credentials note,
  and the shortcuts tab with the new group. Criteria 6 and 7 are review
  points; the **maintainer's visual check is still outstanding.**
- **The wiring from menu to Core.** There is **no test** that traces
  `MacSCPApp.snippetMenuItems` → `TabCommands.runSnippet` →
  `ContentView.triggerSnippet(_:)` → `TerminalPanelViewModel.send(_:)`
  end to end. The chain has been read, not executed. No view-testing
  tool exists in the project — deliberate, see M29.
- **The line terminator at runtime.** A static source-code trace against
  the pinned SwiftTerm revision; not a single byte was actually sent over
  a real PTY. Equally unverified: that the far side reacts to CR the way
  a POSIX terminal usually does.
- **The red states.** The compile failures from T1/T2 and the red run of
  the three buffer tests from T4 are **taken over** from the task
  reports, not newly reproduced in this session. What was newly produced
  in this session is exclusively the mutation probe on the dead `catch`
  branch above.
- **The FR and PL translations of the 22 new keys** are machine-generated
  and **not reviewed by a native speaker**; the project's standing
  reservation applies unchanged. The German version is hand-written.
- ~~**The whole-branch review over `7a1777b..HEAD`** has not run yet.~~
  **It has run**, with exactly the expected result: it found two further
  false claims that had survived this report. Both are corrected above,
  the fix round has its own section.
- **`scripts/release`** — not run.
- **That the test-suite hang no longer occurs** — it did not occur in
  either run; nothing more is claimed than that.

## For the release notes

**One sentence.** Frequently used commands can be saved as snippets and
inserted into the terminal.

## What remains open

- **The visual check of the GUI** — the only way to lift criteria 6 and 7
  from "read" to "seen".
- The **three** still-open minor items from the section above
  (`prefix` with a negative argument, `resize()` during `.opening`, two
  snippets triggered within the same `.opening` window); two more were
  resolved in the fix round.
- Explicitly excluded from the spec and unchanged open: placeholders,
  export/import of snippets, binding to hosts or groups, multi-line
  scripts — and **agent forwarding** as its own milestone, on the
  backlog since M10d.
- **M29-P3** — decoupling the rest of `ContentView`.
- Unchanged from the backlog: the stale slot of a set-bound session, the
  editor friction when editing a login set, an app-wide audit area, the
  0% CPU test-suite hang, the path via which the shipped app finds its
  resource bundle.
- **The release backlog: 419 commits ahead of `origin/main`** (M29-P2
  named 408, M29-P1 397). Grown further.
