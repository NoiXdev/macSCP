# PV + P0 — Completion Report (View testability and the decoupling of `ContentView`)

**Status:** completed 2026-08-11. HEAD before this report: `295a856`.

Twelve tasks: a time-boxed spike on view testability, five extractions that
lifted decision logic out of `ContentView` into tested types, five mechanical
file splits with no state relocation, and this completion report. Spec:
`2026-08-10-snippets-runde-2-design.md` (sections "PV" and "P0"). Plan:
`../plans/2026-08-10-pv-p0-entkernung.md`.

## Commits

Basis of the plan: `01a8396`.

| Commit | Content |
|---|---|
| `01a8396` | Plan (= base) |
| `1811a18` / `7de6986` / `ab9c186` | Task 1 — PV spike, report, fix round (removed a two-variable confound) |
| `7fa35a1` | Task 2 — `TabCloseWarning` |
| `d2457fa` | Task 3 — `SubmitRefusalText` |
| `9fcf3a0` / `bd9b034` | Task 4 — `SessionSecretPolicy`, fix round (two missing coverage tests) |
| `0196266` | Task 5 — `CrossSessionTargets` |
| `3d02ddd` | Task 6 — `ImportFeedbackText` |
| `7546320` | Task 7 — `ContentView+Detail.swift` |
| `90231c2` | Task 8 — `ContentView+Sheets.swift` |
| `3d3bfe6` | Task 9 — `ContentView+Lifecycle.swift` |
| `716509d` | Task 10 — `ContentView+Transfers.swift` |
| `7e019f1` | Task 11 — `ContentView+ExportImport.swift` |
| `295a856` | Task 12 — corrected `tabIDs`' doc comment (see below) |

**Unpushed:** `git rev-list --count origin/develop..develop` → **30** before
this report commit. **Release backlog:**
`git rev-list --count origin/main..develop` → **440**.

## 1. Measured line counts and test counts

The "before" numbers are not copied from the plan or the brief — they were
remeasured in this session, in a separate worktree at the plan's base commit
(`01a8396^` = `d69c403`), and then removed.

| | before (`d69c403`, isolated worktree) | after (`295a856`, this tree) |
|---|---|---|
| `ContentView.swift` | **3464** lines | **1360** lines |
| Suite total | **1756 tests / 144 suites** | **1785 tests / 150 suites** |

`ContentView.swift` shrinks by **2104 lines (61%)**. The suite grows by
**+29 tests, +6 suites** — fully accounted for: `ViewTestabilitySpike` (+7),
`TabCloseWarning` (+3), `SubmitRefusalText` (+3), `SessionSecretPolicy`
(+4, then +2 in the fix round = 6), `CrossSessionTargets` (+3),
`ImportFeedbackText` (+7). 7+3+3+6+3+7 = 29, six new suites. No existing
test changed status.

**Where the 2104 lines went** (all values remeasured in this tree):

| File | Lines | Kind |
|---|---|---|
| `ContentView+Lifecycle.swift` | 671 | Split |
| `ContentView+Detail.swift` | 535 | Split |
| `ContentView+Sheets.swift` | 344 | Split |
| `ContentView+Transfers.swift` | 250 | Split |
| `ContentView+ExportImport.swift` | 149 | Split |
| `ImportFeedbackText.swift` | 106 | Extraction (App) |
| `SessionSecretPolicy.swift` (Core) | 75 | Extraction (Core) |
| `SubmitRefusalText.swift` | 47 | Extraction (App) |
| `TabCloseWarning.swift` | 33 | Extraction (App) |
| `CrossSessionTargets.swift` | 27 | Extraction (App) |

Five split files, five extraction files — exactly the ten the plan called
for. No new L10n key: `git diff --stat 01a8396..HEAD --
Sources/MacSCPAppKit/Resources Sources/macSCPCore/Resources` is empty,
measured, not assumed.

The four other large App files stayed untouched, as the spec prescribes
(`SettingsView.swift` 1306, `RemoteFileTableView.swift` 1050,
`LoginSetsSheet.swift` 1048, `ConnectionFormView.swift` 1001 — all four
remeasured against in this run, unchanged from the spec's figures).

## 2. Which decision logic is now held by tests

**Held (five new types, 22 tests plus the A/B/A spike tests):**

- `TabCloseWarning` — which of the two warning reasons are named when
  closing a tab, in what order, and the special case of "neither of the
  two".
- `SubmitRefusalText` — all eight `SubmitRefusal` cases mapped to text, with
  a completeness and collision assertion.
- `SessionSecretPolicy` (Core) — which value is written to a session's own
  secret slot, including the `catch → true` branch (an error while looking
  up never persists a second time) and the trim rule on the key path.
- `CrossSessionTargets` — which other tabs are offered as a transfer target
  (own tab excluded, a tab without a session excluded, a connected tab
  stays in — the third rule was only added during the fix round/extension
  of the task).
- `ImportFeedbackText` — the three text mappings for session import and
  export, with completeness over all `SessionExportError` cases.

**Not held:**

- The five split files (`ContentView+Detail/Sheets/Lifecycle/
  Transfers/ExportImport.swift`) move code, add no test. What is in them —
  sheet/alert ordering, toolbar button gating, window lifecycle including
  the `cancelAll → shutdown → disconnect` teardown order, drag-and-drop
  uploads — remains as unverified as it was before. In this phase the
  evidence for that is review only (diff inspection, byte comparison of
  individual functions against the prior state), not a suite.
- The wiring button/menu → the five new types (`requestClose` calls
  `TabCloseWarning`, the login form view calls `SubmitRefusalText`, etc.) is
  a `ContentView` line, read, not executed — the same boundary as in M29-P2
  for `SubmitRefusal` itself.
- `requestExternalTerminal`/`performExternalOpen` in `ContentView`: pure
  wiring to `ExternalTerminalLauncher` (already its own tested type since
  M29-P1), but the wiring itself is unverified.

## 3. The "no behavior changed" assertion — basis and boundary

**This assertion rests explicitly on build and suite, not on visual
inspection. The GUI was not started a single time during this entire
phase** — no `open`, no invocation that shows a window. What actually ran in
this session:

| Run | Result |
|---|---|
| `swift build` | `Build complete!` |
| `swift test` | **1785 tests in 150 suites, green** (3.9–4.4 s depending on the run) |
| `MACSCP_VERSION="1.2.0-dev" MACSCP_BUILD="$(git rev-list --count HEAD)" ./scripts/package-app` | `wrote dist/macSCP.app` |
| `lipo -archs` on `macSCP` and `macscp-cli` | both `x86_64 arm64` |
| Resource bundles | `macSCP_MacSCPAppKit.bundle`, `macSCP_macSCPCore.bundle` present |
| `en/de/fr/pl.lproj` markers | all four present under `Contents/Resources` |
| `plutil -lint dist/macSCP.app/Contents/Info.plist` | `OK` |
| `CFBundleVersion` / `CFBundleShortVersionString` | `907` / `1.2.0-dev` — `907` matches `git rev-list --count HEAD` at the then-current `HEAD` (`7e019f1`) |
| `scripts/release` | **not run** (published) |
| GUI | **not started** |

One caveat about the build itself: the dev build was run on `7e019f1`,
before this report added commit `295a856` (the `tabIDs` comment correction,
see section 5). The diff between the two is a single comment line with no
effect on generated code — the build remains representative of the
committed code, but was not rerun afterward.

Build and suite prove that **no automatically checkable behavior** has
changed. They do not prove how the app actually looks or handles. **Visual
inspection is the maintainer's responsibility.** Specifically, these are the
spots that deserve a look, because they were moved in Part B but never
rendered:

1. **The order of the sheets/alerts in `ContentView+Sheets.swift`.**
   Multiple `.sheet` modifiers on the same view — login sets, server
   certificates, hidden imports, snippets, export/import dialogs, password
   hint, external terminal error. Order decides which sheet wins when
   several conditions are true at once.
2. **The tab-close warning dialog**, when both reasons apply (active and
   incoming transfers) — now built from `TabCloseWarning.message`.
3. **The refusal message in the login form**, for at least one of the eight
   `SubmitRefusal` cases — now built from `SubmitRefusalText.message`.
4. **The target selection for cross-session transfer** (`CrossSessionTargets`) — whether the list looks as expected in the UI.
5. **The detail panel layout** (`splitLayout`, `windowChrome`, `terminalPanel`
   in `ContentView+Detail.swift`) after the pure file move.
6. **Window lifecycle**: window size at launch (`shrinkIfPristine`), menu
   bar wiring, close confirmation — all now in
   `ContentView+Lifecycle.swift`.

## 4. The PV result and its consequences for the views

**Yes — SwiftUI views from `MacSCPAppKit` can be instantiated in the test
target, rendered with `ImageRenderer`, and distinguished by a pixel
comparison, without any new dependency, compatible with Swift Testing, and
for pure SwiftUI views without a running `NSApplication`.** Proved with a
runnable example (`Tests/macSCPAppKitTests/ViewTestabilitySpike.swift`,
seven tests, remains in the tree) and a real A/B/A control, after the first
version contained a two-variable confound and a warm-up confounder (both
cleared in the fix round, see section 5).

**The caveat outweighs the yes:** `ImageRenderer` does **not** draw
`NSViewRepresentable`. Content from AppKit-backed controls —
`TextField`, `Toggle`, tables — does not reach the rendered bitmap.
Measured, not assumed: the same `SheetSearchField` with `text: "a"` and with
39 characters renders **identically**. Exactly these control types dominate
this app's forms and lists. So the technique holds for layout and pure
SwiftUI views, but not for the content that carries the most decision logic
in `ContentView` and the sheets.

**Consequence for P0:** As the spec prescribes for the negative case, this
phase followed the alternative — as much decision logic as possible moved
into types with tests, the views remain drawing. No view test was written
for the five split files, even though the PV result formally came out
positive: the coordinator made this choice because the load-bearing caveat —
AppKit controls are invisible — excludes exactly the views P0 works on. For
P1 the same line the spec already anticipates follows from this:
`SnippetMenuModel` lives in Core, not as views with pixel tests.

**Open from PV:** whether the technique holds in a GUI-less CI session has
not been checked locally with root (`launchctl bsexec 1` would need
passwordless `sudo`, not available). The spike stays in the tree; the next
CI run answers it for free.

## 5. Findings within the plan itself — and what they cost

Spread across the phase, several tasks found real errors in the plan's own
prose, not in existing production code:

- **Wrong isolation annotation (Task 2).** The plan's code block for
  `TabCloseWarning` carried no `@MainActor` marking. `hasIncomingTransfers`
  reads `SessionTab` fields, `SessionTab` is `@MainActor`; without the
  annotation the type does not compile. Cost: a targeted fix (only the one
  function, not the whole type, otherwise the plan's own test would no
  longer have compiled) — no fix round needed, found and fixed within the
  same task.
- **Two factually wrong tests (Task 3, Task 6).** `noTwoRefusalsReadTheSame`
  and `noTwoExportErrorsReadTheSame` claimed a collision-freedom that never
  existed: `SubmitRefusalText` deliberately bundles three cases onto
  `loginSets.missingSet`, `ImportFeedbackText` deliberately bundles two
  pairs (with doc comments that already said so before this phase). Both
  tests were replaced by a variant that checks the same collision-freedom
  against an allow-list of documented collisions. Cost: no fix round, but
  in both cases a pause and a justified deviation in the task report rather
  than a silent rewrite.
- **A wrong type name (Task 4).** The "Produces" signature named
  `authChoice: AuthKind`; the real parameter is
  `ConnectionViewModel.AuthChoice`, its own form-side type that only
  coincidentally shares the same raw values as `StoredSession.AuthKind`.
  `AuthKind` alone does not resolve in Core. Cost: no fix round — the
  implementer caught the error while matching signatures, before writing
  the type.
- **Tests that stayed green against a constant return value (Task 4,
  fix round 1).** The four brief tests did not cover the exemption path
  (`aManagedKeyWithAStoredPassphraseIsExemptFromPersisting`) or the catch
  branch (`anUnreadableKeychainIsTreatedAsAlreadyStored`); a re-review
  mutation-tested both constants live and showed that a policy that always
  returns `false` would still have passed all four original tests. Cost: a
  full fix round — two new tests, a rewrite of the padded-path test (which
  previously would also have stayed green with the `.trimmingCharacters`
  line removed), two doc comment corrections.

**This is not cosmetic.** Each of these four findings, undiscovered, would
have left a gap exactly where this phase was meant to close one: decision
logic that looks tested but, at the decisive point, is not. At the same
time: **not one of them was in existing production code** — every
correction concerned the plan or the test templates the plan shipped with,
never a line that already ran before this phase. This is the same lesson
M29-P2 already drew ("an assertion shipped with the plan is a hypothesis,
not a result"), repeated four times here instead of once.

**Also fixed in this task:** the `tabIDs` doc comment claim that Task 7
deferred as "FIX IN THE FINAL WAVE". It said "see the
`.onChange(of: tabIDs)` call above" — the call has lived in a different
file since Task 9 (`ContentView+Lifecycle.swift`), "above" was wrong.
Commit `295a856`, one line, no behavior change.

## 6. What carries forward from the ledger — open minor findings

These four remain open after this report; none was fixed in this phase
because each was outside its scope or needs a maintainer decision:

1. **`warmUpRenders = 3` (Task 1) is an empirically measured value, not a
   proven minimum.** Backstopped by the A/B/A control in every affected
   test — if three renderings stop being enough in the future, the test
   goes red instead of silently measuring wrong. No action needed as long
   as the control stays green; check there first on flakiness.
2. **`TabCloseWarningTests` checks only the number of lines, not their
   order (Task 2).** A swapped pair of lines (active transfers and
   incoming transfers swapped in the message) would not turn the three
   brief tests red. The code itself has a fixed, documented order; the
   test cannot currently protect it. An addendum would be an
   `#expect(text == "…\n…")` with a fixed order for the both-reasons case.
3. **Three `SubmitRefusal` cases read identically to the user
   (Task 3).** `.targetSetMissing`, `.jumpSetMissing`, and
   `.jumpSessionLoginUnresolvable` share `loginSets.missingSet` — a prior
   decision from M29-P2, not this phase. Whether that is sufficient for
   the user or the three deserve their own texts is a maintainer decision;
   text changes were out of scope for this phase.
4. **`LoginSetsSheet.swift` runs its own, parallel text mapping
   (Task 6).** The file has its own `readErrorMessage`/
   `importErrorText`/`importResultText` for the login-set import format —
   with **different** L10n keys and a **different** collision grouping
   than `ImportFeedbackText`. Two code locations answer the same question
   ("how do I describe an import error") with different answers — exactly
   the drift class this project has already paid for once (the spec's
   rationale for `SnippetMenuModel` in P1 names this pattern explicitly).
   No unification in this phase — the two formats (session export/import
   vs. login-set import) are genuinely different today, a merge would be
   its own decision.

**Closed in this report:** the `tabIDs` doc comment claim from Task 7 (see
section 5) — of the five ledger entries, it was the only one explicitly
deferred to this completion.

## 7. What remains open

- The four minor findings from section 6 — unchanged, none of them caused
  by this phase.
- **Visual inspection by the maintainer** (section 3) — not yet done, since
  the GUI was not started during this phase.
- **The GUI-less-CI question from PV** — not resolvable locally, will be
  answered by the next CI run since `ViewTestabilitySpike.swift` stays in
  the tree.
- **View tests for the five split files** — deliberately not part of this
  phase (section 4); a future decision on whether it is even worthwhile
  given the AppKit limitation.
- **P1–P3** from the spec — making snippets reachable, the terminal
  edition, host tags/import-export — none of them the subject of this
  phase.
- **The release backlog:** 30 commits ahead of `origin/develop`, 440 ahead
  of `origin/main` (the "Commits" section above) — kept growing, unchanged
  from the backlog.

## For the release notes

None — this phase is pure internal refactoring with no user-visible
change.
