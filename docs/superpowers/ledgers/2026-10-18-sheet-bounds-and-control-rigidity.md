# SDD ledger — plan: docs/superpowers/plans/2026-10-18-sheet-bounds-and-control-rigidity.md

Spec: docs/superpowers/specs/2026-10-17-sheet-width-and-control-rigidity-design.md (reachable, read)
Branch: sheet-bounds-and-control-rigidity, BASE ab5ef6f7 (= develop)
Worktree: /Users/noidee/macSCP/.claude/worktrees/diff-view

## Pre-flight conflict scan (2026-10-18)

### Pairs that share a file or an interface

| A | B | A produces / B consumes | Finding |
|---|---|---|---|
| T2 | T6 | `LayoutMeasure.minimumWidth(locale:of:)` / called with `entry.content` of type `@MainActor () -> AnyView` | Clean — `AnyView` is a `View`, the generic binds |
| T2 | T6 | `minimumHeight(locale:at:of:)` / `at: entry.bound.grantedWidth` | Clean — names and order match |
| T2 | T8, T10 | `LayoutMeasure` / rigidity and floor measurements | Clean |
| T4 | T5, T6 | `SheetBound`, `BoundedView`, `sheetBound(_:)` | Clean |
| T5 | T6 | `FileActionEditor.sheetWidth` renamed / exemplar guard references it | **Resolved in the plan before execution** — T5's Files block now carries the guard file and renames the reference in the same task; T6 deletes the file later. Without that, the build breaks between T5 and T6 |
| T3 | T6 | fourteen types become internal / registry constructs them | Clean — T3 precedes T6 |
| T3 | T6 | `BoundedViewVisibilityTests` / the registry | Overlap, not conflict: after T6 the visibility test is redundant but harmless, and it is the only check during T4–T5 |
| T5 | T7 | `: BoundedView` conformances / the set-equality scan reads them | Clean — T5 precedes T7 |
| T8 | T11 | `RigidControls.swift` / scan asserts the raw styles live only there | Clean |
| T9, T10 | T11 | migrated sites / scan finds none left | Clean |
| T3 | T10 | `SettingsView.swift` visibility / the same file's control sites | Clean — different lines, sequential |
| T5 | T12 | `scripts/sheet-bound-inventory` run expecting zero / the script is re-pointed | See Finding 1 |
| T2 | T9 | `theGermanFigureIsTheOneTheCommittedGuardReports` pins 411 / T9 changes that view's controls | See Finding 2 |

### Each task against itself

| Task | Finding |
|---|---|
| T1 | Agrees with itself. Three outcomes enumerated, one of them a stop |
| T2 | Agrees. Four tests, each against a function the task defines |
| T3 | Agrees. The red is a BUILD failure, which the task says to record verbatim |
| T4 | Agrees. Four tests against three cases and two computed properties |
| T5 | Agrees, after the ordering fix recorded above |
| T6 | Grouping imprecision, not a conflict: pass 3's heading says "both-axes sheets" while `SnippetEditorView` and `LoginSetEditorView` are `.width(460)`, and pass 4's says "capped" while `TerminalPanelHeader` is `.width(280)`. The entries are right; the headings describe most of their members. No ruling needed — the inventory is the authority for each bound |
| T7 | Agrees. Set equality, with its positive beside it |
| T8 | Agrees. The one algorithm the signature does not determine is given |
| T9 | Agrees. Expects reds and names the remedy route |
| T10 | Agrees, and carries the one sanctioned stop |
| T11 | Agrees. Negative with a positive beside it |
| T12 | Agrees |

### Findings and rulings

**Finding 1 — `scripts/sheet-bound-inventory` carries two hardcoded entries.**
Its `EXTRA` list spells `FileActionEditor` and the nested cap literally, so
after T5 it will print `0 returned by the three commands, plus 2 the commands
miss`. The 2 is a constant, not a measurement, and from T5 until T12 the
script reports a figure it did not measure.
`Ruling: T5's step 5 expectation stands as written — zero from the three commands is the real result — and T12 removes the hardcoded EXTRA when it re-points the script. — Why: the script is scaffolding for this plan, and the window in which it misreports is bounded by T12, which already owns it. — Costs if wrong: a reader between T5 and T12 believes two bounded views remain; the plan's own guard disagrees with them loudly, so the error cannot survive.`

**Finding 2 — T2 pins the German figure at 411, and T9 edits that view.**
`theGermanFigureIsTheOneTheCommittedGuardReports` asserts an exact 411 for
`FileActionEditor`. T9 replaces that view's three `.fixedSize()` controls
with components whose floor is the ideal. Minimum-under-floor equals
minimum-under-fixedSize, so 411 should hold — but it is an exact figure in a
test that a later task edits the inputs of.
`Ruling: keep the exact pin, and carry into T9's dispatch that a red there is answered by re-measuring and recording the new figure with its date, never by reverting the component. — Why: an exact pin is what makes the harness's agreement with the committed guard checkable at all, and the spec's remedies do not include undoing rigidity. — Costs if wrong: one extra fix round in T9 to update a number.`

**Finding 3 — Task 1 pushes.**
A push is normally a stop. The maintainer authorized it explicitly on
2026-10-17 (`push ist ok`) for this measurement.
`Ruling: Task 1 pushes the implementation branch and opens no pull request and merges nothing. — Why: the authorization is on the record and scoped to the measurement. — Costs if wrong: a branch on the remote that nobody asked for, deletable.`

## Progress

**Finding 4 (execution, 2026-10-18) — Task 1 cannot run as written.**
`.github/workflows/ci.yml` triggers on `push` to `main` and `develop` only,
plus `pull_request`. It carries no `workflow_dispatch`. Pushing the
implementation branch therefore starts no run, and Task 1's step 2 would
watch for a run that does not exist. The only mechanism that delivers the
measurement the maintainer authorized is a pull request, which is a
different artifact from the push they named.
`Ruling: Task 1 is deferred, not dropped, and the pull-request question goes to the maintainer now. Tasks 2 through 5 run meanwhile — the harness, the visibility change, SheetBound and the declaration migration do not consume Task 1's figures. Task 6 is the first task that compares a measurement against a bound, so the answer is needed before Task 6 and not before Task 2. — Why: the authorization on the record is for a push; a pull request notifies watchers and is a visible artifact in the maintainer's repository, which is the class of side effect this skill says to ask about. Reordering costs nothing because the dependency is on Task 6, not on Task 2. — Costs if wrong: if the maintainer declines a pull request, the CI figures cannot be taken at all, and the guard ships with figures measured on one platform; that is the status quo the plan set out to fix, and it would be recorded as such rather than silently assumed.`

## Progress

Task 1: DEFERRED pending the maintainer's answer on a pull request (Finding 4). Not started.

Task 2: DONE_WITH_CONCERNS from implementer af457347f28a4d0e7, commit 67c2a48e. Red recorded verbatim; 4/4 green; the four figures reproduce (en 364, de 411, fr 370, pl 405) and the outside-the-override figure for de is 373.

**Finding 5 — the plan put `LayoutMeasure` in a target that cannot reach `L10n`.**
The plan's Files block says `Tests/MacSCPTestSupport/LayoutMeasure.swift`.
`MacSCPTestSupport` is a plain (non-test) target — its own Package.swift
comment says so at line 163 — and `L10n` is internal to `MacSCPAppKit`. The
implementer made it work by adding `MacSCPAppKit` to TestSupport's
dependencies and using `@testable import`, which (a) only links in a
testable build, so `swift build -c release` of that target would fail, and
(b) makes `macSCPCoreTests` link AppKit, inverting the layering Core's tests
have never had to carry.
`Ruling: LayoutMeasure moves to Tests/macSCPAppKitTests/LayoutMeasure.swift and the Package.swift edit is reverted. — Why: every consumer in this plan (Tasks 6, 8, 10) is an AppKit test; nothing in Core's tests measures layout, so the shared target buys nothing and costs a layering inversion. The spec does not name a location; the plan's path was a guess I wrote, and it was wrong. — Costs if wrong: if a later Core test ever needs layout measurement, it moves back and the dependency question returns, with this ledger entry as the record of why it was refused once.`

**Finding 6 — two of the three harness functions have no committed test.**
`minimumHeight` and `idealWidth` were checked with a throwaway probe only.
Task 6 consumes `minimumHeight` for every view that fixes a height, and
Task 8 consumes `idealWidth` for the rigidity check. Both would ship
unpinned.
`Ruling: both get a committed test in this task, before review. — Why: a function two later tasks build on, verified by a probe that no longer exists, is a figure without its command. — Costs if wrong: none; the tests are cheap.`

Task 2: fix round 1/5 (2 addressed, 0 open — harness moved out of the plain target, Package.swift reverted, idealWidth and minimumHeight pinned; commits 67c2a48..eee2acb)

**Finding 7 (carried to Task 6) — `minimumHeight` measures nothing on content that is not vertically rigid.**
Measured by the Task 2 implementer while its own test went red: a bare
`Text` offered a height of 0 truncates to one line and reports 16.0 pt at
both 120 and 600 pt of width, while the same text under
`.fixedSize(horizontal: false, vertical: true)` reports 384.0 and 80.0.
Task 6 compares a minimum height against a granted height for the eleven
views that fix both axes. On content that is not vertically rigid, that
comparison is about 16 pt against 440 or more — green for every view,
always, whatever the content.
`Ruling: Task 6's height half must mark the measured content vertically rigid, AND carry a positive check that the height figure moves with the proposed width — the same shape as the width half's "the measurement moves with the language". A height guard that cannot go red is a comment that runs. — Why: this is the exact failure mode the project has recorded nine times, and it would arrive here as eleven green rows. — Costs if wrong: Task 6 spends one more fix round adding the positive check.`

Task 2: review clean (spec ✅, quality Approved, 4 minors, 0 Critical/Important).
Task 2: minor (deferred): `buildingOutsideTheOverrideUnderMeasures` depends on the test process's own language not being German — on a de-preferred machine outside == inside and it goes red. Only de has teeth; en/fr/pl measure the same either way.
Task 2: minor (deferred): `theGermanFigureIsTheOneTheCommittedGuardReports` compares to the literal 411 because the exemplar guard's `requiredWidth` is private, so the name promises an equality the body cannot express. Needs a comment saying a red here means re-measure, not revert.
Task 2: minor (deferred): the two new tests' comments cite figures (pl 173.5/219.0; 384.0/80.0/16.0) whose only source was a deleted probe — figures without their command, which this project has a rule about.
Task 2: minor (deferred): the idealWidth test's rigid half applies `.fixedSize()` and then `idealWidth` applies it again, so that half holds trivially; the bare half carries the property.
Task 2: complete (commits ab5ef6f..eee2acb, review clean)

Task 3: DONE_WITH_CONCERNS from implementer ad25155cbf0027170, commit 75ecc7df. Red recorded verbatim ("cannot find 'ChangeKeyPassphraseSheet' in scope"). No name collisions. Script and brief agreed.

**Finding 8 — fourteen source-scanning guards were anchored on the access level.**
Dropping `private` turned 14 guard tests red across five files
(`CLISettingsCompletionGuardTests`, `TerminalKeyboardWiringGuardTests`,
`TerminalMouseWiringGuardTests`, `SnippetCommandEditorGuardTests`,
`ReconnectWiringGuardTests`). They anchor on the literal text
`private struct X: View`. The implementer removed `private ` from nine
anchor strings. That is the right mechanical fix — but the anchors were not
re-checked for uniqueness afterwards, and a guard whose anchor was widened
is a guard whose scope changed.
`Ruling: the edit stands and stays in the task, because without it the branch is red and the guards are genuinely about wiring rather than access level. Before review, each of the nine widened anchors must be shown to match EXACTLY ONCE in the corpus. No mutation probe is required for them. — Why: widening an anchor can only add matches, never remove them, so these guards cannot have gone silent; the only reachable failure is an anchor that now matches a second site, and a uniqueness count tests exactly that, at a fraction of five probe runs each costing two full suites. — Costs if wrong: a widened anchor matches two sites and the guard passes on the wrong one; the uniqueness check is precisely what would have caught that, so the residual risk is a guard whose anchor is unique today and ambiguous after a later rename — which is the standing hazard of every source scan here, not one this task introduces.`
Task 3: closeout item — a guard that anchors on `private` is coupled to an access level it does not care about. Backlog row at Task 12.

Task 3: review 1 — spec ✅, quality Approved with 2 Important, 3 Minor. Reviewer verified the access-only change from the diff (14 lines, each `-private struct X: View` / `+struct X: View`), read every consumer of the five widened anchors and found none whose property changed, and independently reproduced the five counts.
Task 3: Important I1 — three comments now false, two of them directly above a changed declaration: `SSHKeysSheet.swift:615-618` ("`private` like its neighbours … so it stays usable … without needing wider visibility"), `SettingsView.swift:1854` ("the view is `private`"), `CLISettingsCompletionGuardTests.swift:509` ("a `switch` inside a `private` view").
`Ruling: I1 is fixed in this task, not deferred. — Why: this project's "Comments that describe other code" rule makes the comment search part of the SAME pass as the change, explicitly including files the diff does not touch; the brief's "change nothing else" scopes the TYPE declarations, and a comment that describes the access level a task just changed is part of that change, not a neighbour of it. — Costs if wrong: three comment edits in a task whose diff was otherwise purely mechanical, which a reader could mistake for scope creep; the commit message says why.`
Task 3: Important I2 — `eachWidenedGuardAnchorMatchesExactlyOnce` hand-types its own copy of the five anchors, the file paths and the `.code`/`.raw` tag; the guards' own constants are `private static`, so nothing links the two sets. A guard whose anchor is edited, repointed to another file, or switched between the blanked and raw view leaves the new test green.
`Ruling: I2 is fixed in this task. The guards' anchors become internal `static let` and the table reads them; the two guards holding inline literals get them hoisted first. — Why: "a guard that spells a symbol it could read instead is waiting for a rename" is this project's measured rule, and the test added to close a scope hole reproduces the hole one level up. It is bounded work in five files whose anchors were already being edited in this task. — Costs if wrong: more churn in five guard files than the finding strictly needs, in a task meant to be mechanical.`
Task 3: minor (deferred): the exactly-once test's failure message is a bare `#expect(count == 1)` labelled by index, so a red says "count → 2" without naming the anchor or the file.
Task 3: minor (deferred): `everyBoundedViewIsReachableFromTests` asserts `types.count == 14` against the literal list it counts — tautological at runtime; the real check is that the file compiles, and the brief prescribed that shape. The hard-coded 14 is also a second copy of what `scripts/sheet-bound-inventory` reports, and a fifteenth bounded type would turn nothing red.
Task 3: minor (deferred): `repoRoot` is derived by three `deletingLastPathComponent()` calls from `#filePath`, a third copy of how other suites find the root.
Task 3: the `git log --oneline -1` amend gap caused no damage — the reviewer read the surviving body, found it complete with the required footer, and the only thing replaced was the implementer's own wrong count.

Task 3: fix round 2/5 (2 addressed, 0 open — three stale comments corrected and checked against ImportKeySheet's own note; the five anchors hoisted to internal constants the test reads, byte-identical; failure message now names guard, anchor, file and view; commits 335d9fc..8b8173f)
Task 3: the re-reviewer ran its OWN sweep for stale comments rather than accepting the implementer's four patterns, and judged those patterns "weaker than they sound" — pattern 1 could not have found two of the three originals. Its independent sweep agreed with the result, so the verdict stands on the sweep, not on the patterns.
Task 3: minor (deferred): `CLISettingsCompletionGuardTests` comment now says "view's `body`" where the switch actually lives in the computed property `completionPresentation` (`SettingsView.swift:2036`).
Task 3: minor (deferred): the exactly-once failure message says "may be reading the wrong site" even when the count is 0, where the real meaning is that the guard's own anchor is missing.
Task 3: minor (deferred): `GenerateKeySheetRunWiringGuardTests` and `DiagnosticsDoorsGuardTests:116` anchor on BARE substrings (`struct GenerateKeySheet`, `struct ConnectFailureView`), are insensitive to the access keyword, and are not covered by the exactly-once test — a second site would be read first-match by them.
Task 3: residual sanctioned by ruling: the `.code`/`.raw` tag per row stays a literal; a guard that moves between the blanked and raw view is not caught. Documented in the test's leading comment.
Task 3: complete (commits eee2acb..8b8173f, review clean after 2 fix rounds)

Task 4: review 1 — spec ✅, quality Approved, 0 Critical/Important, 4 Minor.
Task 4: the conditional-content question is settled. `_ConditionalContent` adds no layout container; the branch is part of structural identity but `bound` is a type-level value so it never flips at runtime; the adopter's own `@State` lives above the conditional; and `some View` hides the concrete type, so none of the 33 views can depend on it. The reviewer named an alternative without conditional content (two chained frames with optional parameters) and judged it not worth two extra layout nodes per view. No change before Task 5.
Task 4: the cap mutation was enumerated from the code, not taken on trust: the reviewer listed every assertion touching a cap's `grantedWidth`, found the implementer's three reds are the COMPLETE set that should go red, and confirmed no assertion that ought to be sensitive is blind. A second mutation (rendering a cap at its minWidth) also goes red at `SheetBoundTests.swift:66`.
`Ruling: two of the four Minors are folded into one short fix round rather than deferred, because Task 6 depends on both. (a) `aBoundedViewStatesItsBoundOnTheType` never uses `BoundedView` as a generic constraint, so it would still pass if the `bound` requirement were removed from the protocol — and generic access through the protocol is exactly what Task 6's registry needs. (b) The identity argument above rests on `bound` being constant, which nothing states or enforces. The same compile also answers the reviewer's low-confidence note that `View` is `@MainActor` on macOS 15, so conformers' `static var bound` may be MainActor-isolated — which Task 6 must know before it writes a guard that reads it. — Why: all three are cheap now and each is discovered expensively inside Task 6, the task the whole plan pivots on. — Costs if wrong: one extra short round in a task that was already approved.`
Task 4: minor (deferred): `SheetBoundTests.swift:23` keeps a second copy of the literal 420 beside the `cap` constant; deriving it would make the assertion non-independent, so it stays.

Task 4: fix round 1/5 (2 addressed, 1 NEW Important — commits 371809c..c984521)
**Finding 9 — the isolation claim is false and the code written on it breaks CI's warning gate.**
The implementer reported `bound` is NOT main-actor isolated and that Task 6
could read it from either context. The scoped re-reviewer contradicted it,
having typechecked the real source with `swiftc -swift-version 6 -typecheck`
rather than arguing from the language. I confirmed it through the project's
own build rather than take either on trust:
`swift build --build-tests` after `touch`ing both files prints
`Tests/macSCPAppKitTests/SheetBoundTests.swift:92:11: warning: main actor-isolated static property 'bound' can not be referenced from a nonisolated context`
and the same at `:120:16`. `.github/workflows/ci.yml:38` sets
`MAX_WARNINGS: 0`, and its gate at `:190-197` counts unique
`file:line:col: warning:` locations across build and test logs.
**The first build I ran was incremental and printed neither warning** — a
green result that meant nothing, because the files were already compiled.
`Ruling: fix round 2 removes the nonisolated route entirely — delete `boundWidthFromNonisolatedContext` and its expectation, drop `nonisolated` from the generic helper, correct the doc comment's second paragraph, and correct the two false sentences in task-4-report.md. — Why: the claim is measured false in the project's own build, the gate would fail the run, and the report is a record Task 6 will read. The @MainActor route is the one that matters: the registry is @MainActor. — Costs if wrong: none identified; the @MainActor route was typechecked clean by the re-reviewer.`
Task 4: process note — the implementer saw the build succeed and did not read its warnings. Warnings do not fail a local build here; only CI's gate fails on them, and an incremental rebuild hides them entirely.

Task 4: fix round 2/5 (1 addressed, 0 open — nonisolated route removed, doc comment corrected, report corrected in place with three character-exact verbatim quotes; commits c984521..cff7e37)
Task 4: independently verified by the coordinator — after `touch`ing both files, `swift build --build-tests` prints 0 `main actor-isolated` warnings, using the same method that reliably printed two before the fix.
Task 4: the implementer's positive control (plant a nonisolated read, see the warning appear, remove it, see it gone) is sound: it shows the detection method sees this diagnostic, so the absence afterwards means something.
Task 4: process note — that plant was hand-rolled on a TRACKED file rather than run through `scripts/mutation-probe`, which this project's rules require. Verified by the re-reviewer as harmless here: the restore was a saved-copy write rather than `git checkout -- <file>`, `git diff --stat HEAD` is empty, and the committed diff carries no plant. The rule was breached; nothing was lost.
Task 4: minor (deferred): two further round-1 sentences in task-4-report.md still carry the withdrawn isolation claim without a quoted withdrawal (line 54 "It also records that `bound` is not main-actor isolated", and a clause at line 51). Deferred rather than fixed because this workspace is deleted at plan end and is not the permanent record; the practical risk is removed by carrying the fact into Task 6's dispatch instead.
Task 4: minor (deferred): the round-1 caveat about a `@MainActor`-typed conformer rejecting the generic route is now moot and not addressed by the correction.
Task 4: complete (commits 8b8173f..cff7e37, review clean after 2 fix rounds)

Task 5: review 1 — spec ❌ (one clause), quality not approved as-is: 3 Important, 5 Minor. Reviewer paired every removed literal with its added case across all 33 and found no transposed number and no wrong case; 32 of 33 are in-place single-line swaps.
Task 5: the one relocated frame (`CertificatePromptView`) was verified in the TREE, not from the report: the composed chain is VStack → padding(24) → cap → maxHeight, identical in order to the old call-site chain, and the type has exactly one call site, so no second site lost modifiers. That last fact is the one the diff cannot show and the report asserted.
Task 5: Important 1 — `TerminalPanelHeader.bound = .width(280)` is applied in `snippetPopover`, not in `body`, so the conformer invariant Task 6 rests on is broken. A registry entry whose `content` secretly renders the popover would pass Task 7's name-based set equality while measuring a different view than its name claims — the undetectable special case the anti-goals forbid. Measuring the header against 280 instead is vacuous: it truncates with `lineLimit(1)` and would never approach 280, while the popover, the thing that actually clips, goes unmeasured.
`Ruling: extract the popover into its own BoundedView before Task 6 starts, passing the six popover-local @State values as @Binding and LEAVING them on the header. — Why: the invariant is what makes Task 7's set equality meaningful at all, and the reviewer established the extraction is pixel- and behaviour-neutral only if the state stays put; moving it would reset search text and hover state on every reopen, a behaviour change this plan is not allowed to make. — Costs if wrong: a mechanical extraction in one file that Task 6 would otherwise have had to special-case forever.`
Task 5: Important 2 — the scan's negative half anchors on exactly eight leading spaces and integer digits, so a future view escapes silently by indenting differently (FileActionEditor's own application sits at twelve), by capping at a call site (the migrated nested cap sat at sixteen), by naming the number (`Self.someWidth` — the exact spelling that hid FileActionEditor from the inventory), or by a near-miss like `.frame(width: 420.0)`. The positive half is a real liveness check but cannot detect under-coverage: `>= 33` passes at 33 and at 100.
`Ruling: do not harden the scanner; write the gap down where the next reader hits it, and fix the doc comment this diff disproves. — Why: the structural half that actually covers a NEW view is `BoundedView` conformance plus Task 7's set equality, and a scanner chasing every spelling is the treadmill this project has measured five rounds of. The scan's own comment currently claims a deeper `.frame` "bounds a control inside the view, which is not what this scan is about" — the 16-space sheet bound this very task migrated disproves that sentence. — Costs if wrong: a reverted literal at an unusual indentation reaches CI instead of the local suite.`
Task 5: Important 3 — two stale comments describing the house sheet shape by the spelling just removed: `SSHKeysSheet.swift:14-15` and `SnippetsSheet.swift:8-9`, both naming `.frame(width: 720, height: 460)` which now exists in none of the four files they name. Fixed in this task under the project's comment rule.
Task 5: closeout item — `TabStripView.swift:540` (`.frame(minWidth: 120, maxWidth: 200, maxHeight: .infinity)`) is a root-level cap that can clip, is NOT among the 33, and is not expressible as a `SheetBound`. The plan's goal sentence is therefore not literally true after this task. The closeout must either widen `SheetBound` or say out loud that `maxHeight` caps and `minWidth`-only floors are out of scope. Root-level `minWidth`-only floors cannot clip and are genuinely a different category.
Task 5: closeout item — `docs/BACKLOG.md:238` and `:345` name `FileActionEditor.sheetWidth` in the present tense, and row 238's three committed verification commands, whose stated figures were 14/11/6, now return 0/0/0 against the migrated tree. Task 12 owes those rows a corrected-in-place note quoting the old wording.
Task 5: closeout item — both EXTRA rows in `scripts/sheet-bound-inventory:17-18` are now false statements about the tree, not merely a line to ignore.

Task 5: fix round 1/5 (4 addressed, 0 open — popover extracted with all seven @State left on the header, two stale comments corrected, the scan's blind spots written down and the sentence it disproved removed, the zip staleness closed; commits 72d1765..7e2cf48)
Task 5: the re-reviewer verified the state rule per value, not in aggregate: all seven `@State` stay at `ContentView+Detail.swift:2662-2681`, the popover's whole region declares no `@State`/`@StateObject`/`@Environment`, and every one of the seven bindings is WRITTEN somewhere in the popover, so none should have been a plain `let`. The seventh binding the implementer added on its own (`isPresented`) was necessary, not discretionary: without it the popover could not dismiss itself from its four closures.
Task 5: the re-reviewer separated what "holds by construction" really covers. The STATE claim is established by the code — `@Binding` has no storage, so the popover cannot reset what it does not own, whatever SwiftUI does on reopen. Two neighbouring sentences are NOT: "a popover's content is rebuilt each time it opens" is a claim about SwiftUI's lifecycle that nothing here measures, and pixel neutrality rests on "a custom View inserts no layout node", which is reasoning rather than measurement. Both get measured for real in Task 6, which hosts `TerminalSnippetPopover` against its bound — and the extraction is exactly what makes that measurement meaningful.
Task 5: complete (commits cff7e37..7e2cf48, review clean after 1 fix round)

**Finding 10 — the PLAN carried the stale name the fix had just retired.**
`docs/superpowers/plans/…:505`, Task 6 Step 3 pass 4, still listed
`TerminalPanelHeader` among the views to register. It is no longer a
conformer, so registering it would have failed Task 7's set equality — and
the brief for Task 6 is EXTRACTED from the plan, so the implementer would
have received the stale name as its requirements.
`Ruling: the plan is corrected in place, quoting the withdrawn line verbatim, and Task 6's brief is regenerated AFTER the correction. — Why: this is the exact failure recorded on the diff-view plan, where a plan was corrected in place but the extracted brief was not regenerated, and the implementer received a brief prescribing a withdrawn instrument. A brief is a snapshot. — Costs if wrong: none; the correction is a two-word substitution with its reason attached.`

**Finding 11 — Task 1's CI measurement is still unanswered, and Task 6 is the task that needed it.**
`Ruling: Task 6 proceeds without the CI figures. If the maintainer later authorizes the pull request and macos-15 disagrees with the local numbers, Remedy 2 applies — widen each bound to the maximum measured across catalogues AND platforms — which is one pass over the registry's bounds, not a rebuild. — Why: stalling the whole plan on an unanswered question costs more than the bounded rework, and the plan's own ordering argument ("before thirty-two more views inherit an unverified assumption") is about avoiding a SECOND pass, not about correctness. — Costs if wrong: one pass widening bounds, plus the embarrassment of having written figures into a guard that a runner disagrees with — which is the status quo the plan set out to fix, and would be recorded as such.`
Task 5: closeout item — nothing enforces the invariant Fix 1 established: a future edit could move the seven `@State`s into `TerminalSnippetPopover` and every test stays green. A negative check that the popover's region declares no `@State`, with a positive asserting the header declares seven, would pin what the commit message promises.
Task 5: closeout item — `TerminalPanelInsetTests.headerReadsTheSharedConstants` anchors on the FIRST `var body: some View {` in `ContentView+Detail.swift` (line 1203) while its failure message names `TerminalPanelHeader.body` (line 2683). Pre-existing, untouched, and a guard that names something it does not watch.
Task 5: minor (deferred): the header's `@State` doc comments at `ContentView+Detail.swift:2671` and `:2677` still name `commandPreviewLine(for:)`, a member that now lives on `TerminalSnippetPopover` — and the `(for:)` label was already wrong before this diff, since the member is a parameterless property.

Task 6: review 1 — spec ✅, quality Approved with findings: 3 Important, 5 Minor. The reviewer verified the 33 conformers against the registry's 33 distinct typeNames with an empty `diff`, and reproduced every figure it cites.
Task 6: **the seam is approved as committed.** The diagnosis was verified independently: all 33 apply `.sheetBound` inside `body`, only `FileActionEditor` exposes a `sheetContent`, so the brief's comparison was `w <= w` or `minWidth <= maxWidth` — vacuous for all 33 including the exemplar. The task-local is structurally identical to the existing `L10n.localeOverride` precedent, defaults false, is bound from nine sites all under `Tests/`, and `SheetBound` is internal so only `MacSCPAppKit` could bind it. A `@TaskLocal` is additionally self-limiting: `withValue` covers one synchronous scope and cannot survive the app's run-loop callbacks, so a mistaken binding could not leave a shipped app frameless. Worst case if it were somehow true: sheets size to content, cosmetic, no data or security consequence.
Task 6: the reviewer named a cheaper shape for the future — a `ViewModifier` reading `@Environment(\.sheetBoundIsSuspended)`, scoping suspension to the measured view tree instead of a task, touching one file. Not required now; recorded as the preferred shape if the seam is revisited.
`Ruling: do not change the seam's shape in this task. — Why: it is precedented, proven by three committed checks (does nothing / measures nothing / does not leak past scope), and Tasks 7 onward already depend on it; swapping a working seam for a nicer one mid-plan buys nothing the plan needs. — Costs if wrong: a one-file refactor later, with 33 views untouched either way.`
Task 6: Important I1 — the report says "Sixteen of the 38 entries report the same minimum width in all four catalogues". It is THIRTY-TWO, reproduced from the report's own committed command. Only 6 entries across 5 types have a width that can move with a catalogue at all. The follow-on claim that "their ideals do move with the language, often by hundreds of points" is false for 8 entries, whose widest run is fixture text (a fingerprint, a base64 blob, a host name, a version string) rather than a label — for those eight, Review Focus 1's property is structurally unreachable and no catalogue change can turn them red.
Task 6: Important I2 — the deleted exemplar's `theMeasurementIsNonZeroAndMovesWithTheLanguage` pinned THAT view's width to move with the catalogue; the replacement asserts only that SOME entry moves. With 6 of 38 moving, `FileActionEditor` could lose every rigid control, go flat, and the check would stay green on `AuditLogSheet` alone — which is exactly the regression Tasks 8-10 can introduce. The report claims all three positive checks survived "unchanged in meaning"; that is false of this one.
Task 6: Important I3 — the height half applies the rigidity, but its positive check does not pin it, and the implementer's own probe 5 proves it: `WhatsNewSheet` 480→150 is RED with `.fixedSize` and GREEN without, meaning the suite INCLUDING `theHeightMeasurementMovesWithTheProposedWidth` stays green while a real 236-in-150 overflow goes unreported. The check's doc comment claims it refuses "a height half that reports a truncated single line"; it does not. Something moves either way.
`Ruling: all three Important findings are fixed in this task, and the report is corrected in place quoting what it withdraws. — Why: I1 is the "a number travels with the command that produced it" rule on a figure whose disproving command was already committed; I2 and I3 are both guards that cannot catch what their own comments promise, which is the failure mode this entire plan exists to remove. Fixing a guard that cannot fail is not optional in this task of all tasks. — Costs if wrong: roughly a dozen lines across two test files plus a report correction.`
Task 6: nine of 38 entries are measured EMPTY (`.onAppear` never runs under `sizeThatFits`). The reviewer classified them rather than leaving it vague: genuinely covered are `AuditLogSheet` (463.5-575.5 of 640, the tightest margin in the registry and locale-sensitive) and `HiddenImportsSheet` (the only entry on either axis whose HEIGHT moves with the catalogue). Not genuinely covered are seven — `FileActionsSheet`, `KnownHostsSheet`, `LoginSetsSheet`, `ServerCertificatesSheet` (112 of 900), `SnippetsSheet`, `SSHKeysSheet`, `ImportFromSourceSheet` — locale-invariant on both axes with 2.4-8.3x slack. **Corrected 2026-10-18 by the final fix wave:** this read “locale-invariant on both axes with 3-8x slack.”; measured from `MACSCP_BOUND_FIGURES=1 swift test --filter BoundedViewFigureReportTests` on Darwin 27.0.0, the range runs from `FileActionsSheet` at 267.0 of 640 (2.4x) to `ImportFromSourceSheet` at 94.0 of 780 (8.3x), so the low end was overstated. The locale-invariance holds: each of the seven reports one width in all four catalogues. What they still buy: rows Task 7's set equality needs, and they would catch a later task narrowing a bound below the chrome minimum.
Task 6: what the five probes do NOT establish, so the record does not over-read them — probes 2 and 3 narrow a BOUND, showing the comparison is live for one entry, not that the guard catches CONTENT that grows; only probe 1 does that, and only for `FileActionEditor`. Probe 3's red is on a sheet measured empty, so it proves the height comparison runs, not that any real row is covered. The honestly recorded uncaught plant (a 99-character title → green) is the correct generalisation: the guard sees only text inside controls that cannot compress.

Task 6: fix round 1/5 (6 addressed, 1 NEW Important — commits 7a6fcb7..3b9e5e7)
Task 6: the re-reviewer re-derived the corrected figures from the gated reporter rather than accepting them, spot-checked ALL eight flat entries rather than the two asked for, and verified the leak fix changed no figure by diffing three pre-fix captures byte-for-byte against a post-fix one. It also confirmed "caught by nothing else" is plausible by enumerating `neededHeight`'s four call sites.
**Finding 12 — a correction that violated the rule it was applying: the withdrawal quotes a sentence that never existed.**
`BoundedViewLayoutGuardTests.swift:229-232` and the body of `812078ce`
claim the old text said a check refused "a height half that reports a
truncated single line". Verified by the coordinator, not taken from the
report: `git log -S'truncated single line' --all` returns ONLY `812078ce`,
the commit that claims to withdraw it, and
`git show 7a6fcb78:…/BoundedViewLayoutGuardTests.swift | grep -c` returns
0. The real sentence, at `:69-70` of the pre-fix file, is
"`theHeightMeasurementMovesWithTheProposedWidth` is the positive check
that this one does."
`Ruling: fixed in round 2 — quote the real sentence verbatim, and amend `neededHeight`'s doc comment, which still carries that over-claim untouched and now contradicts the new test's comment. — Why: a fabricated quote is worse than no quote, because it cannot be checked against anything and it buys the reader's trust under false pretences; this project's correction rule exists precisely to make a withdrawal checkable. — Costs if wrong: two comment edits.`
Task 6: minor (deferred): the corrected count's command is two-stage prose (grep to a file, then a Python parse) rather than one runnable form, and the parse lives only in the untracked report.
Task 6: minor (deferred): `theHeightHalfMeasuresRigidContent` and `theHeightMeasurementMovesWithTheProposedWidth` spell `"de"` and `"en"`, contradicting the suite header's claim that no locale code is spelled.
Task 6: minor (deferred): the report's line 265 says "No change to any catalogue can make them red", stronger than measured — a long enough label would reach the figure; the report's own next sentence hedges it correctly, so it contradicts itself slightly.
Task 6: closeout item — `CLAUDE.md` lacks a line for the sixth gate `MACSCP_BOUND_FIGURES`. The implementer deliberately did not touch that file. It is the maintainer's rule file; propose a line at closeout rather than editing it.

Task 6: fix round 2/5 (1 addressed, 0 open — the real sentence restored verbatim in two places, `neededHeight`'s contradicting doc repointed; commit 3b9e5e7..8039645)
Task 6: the re-reviewer compared the restored quotation against `git show 7a6fcb78:…` rather than against the report, and confirmed both copies match word for word including the line break. It ran both verification commands itself: the pinned `grep -c` returns 0 and can never change (7a6fcb78 is 812078ce^), the unpinned `git log -S` returns two commits today, and the committed text says outright which is which and gives the pre-fix answer.
**Finding 12, provenance — the fabrication was a CHAIN, and the coordinator is a link in it.**
The phrase originated in §8 of the task's own report, a table cell
describing the test. The task review quoted that cell and attributed it to
the CODE. The coordinator then copied that attribution verbatim into the
round-1 fix dispatch, presenting it as a quotation from a doc comment,
without running `git show <base>:<path> | grep`. The implementer withdrew
what it had been handed. Each link was faithful to the one before it and
none checked the source. Recorded so the record names the real failure
rather than the last person to touch it.
Task 6: complete (commits f8ebe1e..8039645, review clean after 2 fix rounds)

Task 7: fix round 1/5 (2 gaps closed — full suite run, second direction's red captured; commits c245f90..e012716)
Task 7: **Plant A returned BUILD FAILED, and that is a stronger result than a red.** `BoundedViewEntry.init<V: BoundedView>` makes a registry entry for a non-conformer a COMPILE error, so the "only in the registry" direction is structurally impossible except when the scan misses a real conformer. A type-system guarantee, not a test.
Task 7: Plant B (a typealias hiding the conformance from the scan) compiles and reports RED, verbatim `only in Sources: []; only in the registry: ["TagFilterSheet"]`, with the positive half also red at `the scan found 32 names`. **Finding: the scan cannot see a conformance spelled through a typealias or a refining protocol.** No such type exists today. Recorded in the suite header. The refining-protocol form was not planted.
Task 7: harness observation, second task in this plan to hit it — `scripts/mutation-probe` prints catcher test NAMES and deletes its log, so the issue message is never shown. The workaround used here was to have the `--apply` command also run the filtered test into a scratch log.

**Finding 13 — two compiler warnings on this machine that this branch did not cause, in files it never touched.**
`Sources/macSCPCore/FileActions/FileActionTemplate.swift:260:45` (trailing
closure confusable with the statement body) and
`Tests/macSCPCoreTests/ArchiveRunnerTests.swift:82:76` (`try` with no
throwing call). Settled by the coordinator rather than left open:
`git diff ab5ef6f7..HEAD --name-only` touches only
`Sources/MacSCPAppKit`, `Tests/macSCPAppKitTests` and
`docs/superpowers/plans`, and Core is upstream of AppKit, so nothing on
this branch can produce a diagnostic in a Core file.
`Ruling: not this branch's defect, and not fixed here. Carried to the maintainer instead. — Why: either CI's macos-15 toolchain does not emit these two diagnostics, in which case CI is green on develop and the local zero-warning check is simply noisier than the gate; or it does, in which case develop already fails the gate and the next push fails for a reason unrelated to this work. Both readings are the maintainer's to act on, and Task 1's CI reading would distinguish them in one run. — Costs if wrong: if they ARE new and I have misread the dependency direction, a push fails the warning gate and names both files, which is a loud failure, not a silent one.`

Task 7: review 1 — spec ✅, quality Approved with 1 Important, 3 Minor.
Task 7: Important I1 — the recorded limitation covers only the BENIGN case. The typealias plant was applied to a type already in the registry, so the red read "only in the registry". A NEW view declared `struct X: SomeRefiningProtocol` or through a typealias appears in NEITHER set: the compiler does not force a registry entry, nothing is red, and the guard is silent. The note also sits only in the test's header, not at `protocol BoundedView` where a contributor adds a conformance — while the registry header now claims "a view added there and not here is a red" without that qualifier.
`Ruling: close it with a scan rather than document it. A second check asserts that, over the blanked app sources, no `protocol … : BoundedView` exists other than the declaration itself and no `typealias … = BoundedView` exists, with a positive beside it. — Why: this task IS the structural half of the plan's coverage claim; a documented hole in the structural half is the shape the anti-goals forbid, and the reviewer established the refining-protocol form behaves identically to the typealias and is the likelier accident, since a helper protocol is a natural thing to add. — Costs if wrong: one more scan that a future legitimate refining protocol would make red, which is a loud, easily-read failure.`
Task 7: the reviewer corrected the implementer's strongest claim. "Structurally impossible" is overstated: `BoundedViewEntry.init<V: BoundedView>` forces CONFORMANCE, not "conformer declared in Sources/MacSCPAppKit". A non-private conformer declared in the TEST target would compile as an entry and appear as "only in the registry" — and two such probes already exist at `SheetBoundTests.swift:141,154`, private today. The accurate statement: the "only in the registry" list fills when the scan misses a real conformer, or when the registry holds a non-Sources conformer.
Task 7: the reviewer also named what is in fact **the cheapest evasion of all**, outside the brief's remit: a view that never conforms and simply calls `.sheetBound(.width(400))` directly. `sheetBound(_:)` is an unconstrained `extension View` method, and `BoundDeclarationScanTests` only counts occurrences of the literal `.sheetBound(Self.bound)`, so such a view escapes both guards while the suite's name reads as covering it.
`Ruling: fold that one in too, as a scan asserting every `.sheetBound(` argument is `Self.bound`. — Why: it is the actual cheapest hole and it costs one more scan in a suite already doing exactly this kind of reading; leaving it as a backlog row would ship a coverage guarantee the tree does not have. — Costs if wrong: a future deliberate non-conformer use of the modifier becomes a red that has to be argued with.`
Task 7: minor (folded in): the failure message names the gap but not the action — the "only in Sources" red should say to add an entry to `BoundedViewRegistry`.
Task 7: minor (folded in): the literal `33` in the positive half has no command beside it, and the floor never rises when a 34th view lands.
Task 7: minor (folded in): the report's "structurally impossible" is carried forward and should be corrected to the accurate statement above.

Task 7: fix round 2/5 (5 addressed) and fix round 3/5 (1 addressed, 0 open) — both indirection routes and the direct-call evasion closed by scans, counts compared; commits e012716..96df02e6
Task 7: the re-reviewer COMPILED the committed regexes against samples in a scratch program rather than reading them, and tabulated old-vs-new match counts. It confirmed the `\b` defect was real (`x.sheetBound(` and `Module.BoundedView` both matched 0 under the old form), that no `\b` remains, and that the `x.`-qualified sample is the discriminating one that would go red on a return to the old form.
Task 7: the declared evidence gaps were settled rather than waived — the missing R1/R2 control lines do not matter because `scripts/mutation-probe` prints `CONTROL NOT ESTABLISHED` and aborts when the control is dirty (lines 335-339), so a `RESULT: RED … caught by` line implies a clean control. R3's missing message is immaterial because the named catcher is the only assertion that plant can trip.
Task 7: equality over floor was judged correct: a floor is satisfied in exactly the direction that hides the copied view. The accepted cost — a conformer applying its bound twice goes red — is consistent with the tree, where conformers and application lines are one-to-one in every file.
Task 7: minor (deferred): the suite header says "Four checks close that" and lists five items.
Task 7: minor (deferred): the positive halves spell `"SheetBound.swift"` — the "spells what it could read" pattern, though a rename makes it loudly red.
Task 7: minor (deferred): `conformerNames` returns bare names, so two nested conformers sharing a name in different types would collapse in the set but not in the application count, a false red. Pre-existing in the set-equality check, not new here.
Task 7: deferred — a swap keeping both totals equal; a non-private conformer in the test target; a typealias split across lines; tying each application to its enclosing conformer; and the two floors of 33 must be raised by hand when a view lands.
Task 7: complete (commits 8039645..96df02e6, review clean after 3 fix rounds)

Task 8: review 1 — spec ✅, quality Approved with 2 Important, 3 Minor. The reviewer compiled a standalone copy of the layout outside the tree and measured it at five proposal kinds rather than reading the algorithm.
**Finding 14 — "a floor that still stretches" is the WRONG shape for two of the three controls, and the mistake is the coordinator's.**
Measured by the reviewer: a raw checkbox reports 101 pt at a 2000-pt
proposal — it never stretched. Nor does a radio group. Under the
committed design `CheckboxRow` and `RadioChoice` now report 2000, and
`aRigidControlStillStretches` actively PINS that greed. Consequences
measured: two `CheckboxRow`s in an `HStack` split the extra width, so the
second moves from 16 pt after the first to the midpoint; and
`HStack { Spacer(); CheckboxRow }` now lays out at the leading edge.
The floor-with-stretch decision was made to preserve the SEGMENTED
pickers' fill, which is real — several of the 21 do fill their row. It was
then applied to all three kinds without checking whether the other two
ever stretched. They do not.
`Ruling: the rigidity becomes per control kind. Segmented keeps the floor that stretches, because that preserves what it does today. Checkbox and radio become rigid AT the ideal and do not stretch, because that is what preserves what THEY do today. `aRigidControlStillStretches` then asserts stretching only for the segmented component, and the other two get an assertion that they do NOT stretch. — Why: the plan's non-goal is "no visual redesign", and the committed shape changes the layout of every migrated checkbox and radio call site that lacks `.fixedSize()`. Documenting it in the Task 10 brief would push a known visual change into a task whose job is substitution, not redesign; fixing the component removes the hazard instead of scheduling it. — Costs if wrong: if some checkbox call site did rely on stretching, it becomes visibly narrower, which Task 10's measurement and the sight check would surface.`
Task 8: Important I2 — the floor's VALUE is unpinned. Both measurements in `eachComponentIsRigidInEveryLanguage` go through the wrapper, so minimum and ideal agree for ANY floor, including a constant. The reviewer named a mutation that passes every committed test while re-enabling the squeeze: `let ideal = subviews[0].sizeThatFits(.zero)`. Nothing compares the wrapper's ideal against the bare control's ideal. Also unexercised: `placeSubviews` (changing it to propose `.unspecified` would draw the control at its ideal inside a 2000-pt slot with every test green), `proposal.height`, and deleting `.labelsHidden()`.
Task 8: M1 — an `.infinity` proposal returns infinite width; infinity is what stacks send when probing for a maximum. M2 — the single bare checkbox has no positive, only the HStack pair, so the pair's compressibility could come from the HStack rather than the toggle (the reviewer measured the single bare checkbox at minimum 21 / ideal 101, so it IS compressible). M3 — the committed doc comment quotes per-locale figures from a scratch probe that no longer exists, which fails the figure-travels-with-its-command rule; the cheapest fix is to point at `theRawControlsAreNotRigid`, which IS the measurement.
Task 8: the reviewer confirmed the compressible form cannot be written through the components — all stored properties private, no `@ViewBuilder` or style parameter, the picker style fixed inside the type. **Withdrawn 2026-10-18 by the final whole-branch review, with a measurement.** This line ended “A caller can still wrap the result in `.frame(width:)`, but that clips and overflows, which the Task 6 guard sees.” It does not. Measured on Darwin 27 in a standalone binary outside the repository, on a segmented control with three German labels: rigid alone reports minimum 477.0; in `.frame(width: 100)` 100.0; inside `.frame(maxWidth: 100)` 100.0; in a `VStack` inside `.frame(width: 100)` 100.0. A width frame collapses a rigid component's reported minimum exactly as a compressible control does, the overflow is drawn clipped, and NO measurement in the suite moves. The tree held that shape twice and this branch deleted both (`c8bfdb63`, `aece2e2b`), with nothing stopping either returning. `RigidControlScanTests.noRigidComponentIsHeldToAWidthFrame` (`399385a5`) now walks the modifier chain written on each of the 19 component call sites and was proved red through `scripts/mutation-probe`; a frame on an ENCLOSING container is still seen by nothing.

Task 8: fix round 1/5 (5 addressed, 1 NEW Important raised by the implementer — commits 4f27da2..a878162)
**Finding 15 — the premise behind `AtLeastIdealWidth` was never measured, and one measurement now contradicts it.**
The design's justification for a floor-that-stretches was the sentence
"several of the twenty-one segmented sites currently stretch to fill their
row, and shrinking them would change how up to twenty-seven controls
look". **The coordinator wrote that from intent; no command produced it.**
Measured by the Task 8 implementer on Darwin 27: a bare 3-segment picker
reports 242.5 at 40-200 pt offered and 295.5 at 300-2000 pt — it never
grows past its ideal. In a 2000-pt host it draws at its ideal, CENTRED,
even under `.frame(maxWidth: .infinity)`, in a `VStack` and in a `Form`.
`SegmentedChoice` reports 2000 at that offer and draws at the leading
edge. So the floor makes the component claim row width the bare control
never claimed and moves it from centred to leading — the layout change the
plan excludes, introduced by the decision meant to prevent it.
Corroborating, from the original defect report: the German picker was
"squeezed from 432 to 360", i.e. it took LESS than its ideal when offered
less. Compression below the ideal is real; growth above it is what is now
in doubt.
`Ruling: do not delete `AtLeastIdealWidth` on one synthetic measurement, and do not keep it on my unmeasured sentence. Measure the one container shape the implementer has not yet tried — a segmented picker in an HStack beside a flexible sibling, which is the shape the variable rows in `FileActionEditor` and `SnippetsSheet` actually use and the likeliest stretcher. If it does not stretch there either, `.fixedSize()` is behaviour-preserving for all three kinds: delete `AtLeastIdealWidth` and the production tree loses a custom Layout. — Why: the premise is the coordinator's and is now contradicted, so keeping it would be preferring my sentence to a measurement; but one synthetic sample is not the 21 real sites, and the plan's own anti-goal forbids figures measured once and generalised. — Costs if wrong: if some real site does stretch, the picker there becomes narrower than today, which the Task 6 guard will not catch (it is not an overflow) and only the sight check would.`
Task 8: the implementer recorded its contradicting measurement as a PASSING test (`aBareSegmentedPickerDoesNotGrowPastItsIdeal`) and marked the premise open in the doc comment rather than acting on it unilaterally. That is the right handling of a finding that contradicts an instruction.
Task 8: five probes all red and each caught by exactly one test — the `.zero` ideal mutation is caught only by the new bare-versus-rigid equality, with `eachComponentIsRigidInEveryLanguage` staying green under it exactly as the review predicted.
Task 8: concern carried — the stretch half of `eachKindStretchesOrHoldsAsItsRawControlDoes` is unmutated (re-adding a greedy floor to checkbox or radio was not probed). Moot if the ruling above collapses all three kinds onto `.fixedSize()`.

Task 8: fix round 2/5 (1 addressed — the deciding measurement came back: a segmented picker draws at its ideal 155.0 pt in all four HStack arrangements, the field taking the slack, so `AtLeastIdealWidth` is DELETED and all three components are their control plus `.fixedSize()`; commits a878162..24799bf, then the coordinator's doc corrections 666b5eb and aa709bf)
Task 8: the re-review found the Swift clean and findings 1-5 addressed, but finding 6 only PARTLY — and the unaddressed part was the coordinator's own correction commit. It quoted the PLAN's spelling where the spec's own text differs (period inside the bold), spliced itself into the middle of the paragraph leaving the withdrawn rationale standing as live text still attributed to "Author's call", left `applying the floor internally` uncorrected, and left the plan's architecture summary and the ENTIRE Task 8 section prescribing the deleted type — which a later reader could have followed to rebuild it.
`Ruling: repaired in aa709bff. The spec's paragraph is now quoted as a block from its own original; the structural-boundary clause carries its own withdrawal; the plan's summary and Task 8 heading both say the section is a record of what was tried, not instructions. The commit message also withdraws the previous commit's false claim that "Both documents quote the withdrawn wording". — Why: a correction that breaks the correction rule is worse than none, because it looks like the record was repaired. — Costs if wrong: none identified; it is prose about prose.`
Task 8: minor (deferred): `RigidControlTests.swift:209-211` still cites "101 pt" while the test asserts only `< 2000`, so the test cannot reproduce the figure.
Task 8: minor (deferred): `.labelsHidden()` and the accessibility-label argument are unfenced — every sample passes `""`, so dropping either would change no measured figure while a stray label would be visible at a real site.
Task 8: minor (deferred): `aBareSegmentedPickerDoesNotGrowPastItsIdeal` lacks an `ideal > 0` assertion and says "however much room it is offered" while testing only 2000 pt.
Task 8: carried to Task 9 — `SnippetsSheet.swift` around line 1202 pins its variable-row picker at `.frame(width: 150)`. That is an appearance change when it becomes a component, and it is the one site the migration must decide about rather than substitute blindly.
Task 8: complete (commits 96df02e6..aa709bff, review clean after 2 fix rounds)

Task 9: DONE_WITH_CONCERNS from implementer a25e6df3c100dc0e9. 14 of 17 in-scope sites migrated, 3 deliberately left, commits aa709bf..0810f6d. Layout guard green after every file; full suite green but for the standing ViewTestabilitySpike failure.

**Finding 16 — the net caught three real, silent, user-visible defects. This is the payoff.**
Each is a control that is compressed today and loses text in at least one
catalogue, with nothing overflowing, which is why no measurement has ever
seen it:
- `AuditLogSheet`'s filter bar: rigid it needs **fr 874 pt and pl 901 pt against 640**.
- `ConnectionFormView`'s jump SOURCE row: rigid it needs **de 525 pt against a 460 cap**.
- `ConnectionFormView`'s jump AUTHENTICATION row: rigid it needs **fr 486 pt against the same cap**.
`Ruling: remedy 3 for all three — replace the control kind, which the maintainer sanctioned on 2026-10-17 (`ja anderer typ erlaubt`) and which is what the exemplar fix itself did. A menu-style picker shows ONE label at a time, so its width is one label's rather than the sum of all of them, which is the whole reason a segmented control is the wrong kind for a long localized set. Measure after replacing: if a menu still overflows, the remedy is exhausted and the bound becomes a maintainer question — stop there and report, do not widen a sheet past what its window offers. — Why: remedy 2 (widen the bound) would take `AuditLogSheet` from 640 to over 900 points, past `MainWindowSizePlan.formSize` at 700, which spec Constraint 3 reserves for the maintainer; remedy 3 is on the record as allowed and changes no window. — Costs if wrong: three controls look different from today in a way the maintainer may dislike, which is visible immediately and revertible per site.`
Task 9: the `SnippetsSheet` pin decision was measured, not guessed: the picker's ideals are de 149, en 155, fr 174, pl 219, so the 150-point pin was already squeezing Polish from 219 to 150. The pin is deleted and the picker takes its ideal.
Task 9: **the registry had two blind states**, both found by this migration rather than by the guard: `ConnectionFormView`'s jump pickers were on screen in no registry state, and `SnippetEditorView`'s expanded declaration card was in none either. Entries were added for both — and the jump entry is what exposed the two overflows above. A coverage registry whose entries do not open the sheets' optional sections measures the easy half.
Task 9: concern carried to review — the implementer edited the guard itself (`ba9fec13`) because `entriesOfOneTypeMeasureDifferentStates` reported two `SnippetEditorView` states as twins once the rigid checkbox set both minima. It added the rigid height at the granted width to the comparison shape. That is a change to the net, and whether it weakened the twin check is a review question.
Task 9: minor — history is not clean: `4c4e5fbb` leaves one wiring-guard test red in isolation, repaired two commits later in `0810f6de`. Per-file runs were the layout guard only; the full suite is what caught it.
Task 9: minor — the `GenerateKeySheet` RSA key-size picker is migrated but unmeasured, because the sheet owns its form as private `@State` and the registry cannot reach that state. Its type row has 3 pt of slack (377 of 380).
Task 9: minor — figures in two commit messages come from throwaway tests since deleted; the `MACSCP_BOUND_FIGURES` lines are the reproducible ones.

Task 9: fix round 1/5 (3 addressed — remedy 3 applied to all three overflows, no bound widened; commits 0810f6d..40f05b1). After: `AuditLogSheet` 157.5/157.5/202.5/207.5 of 640 (was 874 fr / 901 pl rigid); `ConnectionFormView [jump]` 399/399/438/399 of 460 (was de 525 / fr 486).
Task 9: review 1 — spec ✅, quality NOT approvable as-is: 5 Important, 7 Minor. The reviewer reproduced the census independently, re-ran the figure reporter and confirmed EVERY "after" figure byte-for-byte, and read all 17 sites to check options, order, tags, bindings and `L10n` keys survived. No option dropped, no default selection moved.
Task 9: Important I1 — `BoundedViewLayoutGuardTests`'s own doc comment still says "32 of the 38 entries report the same minimum width in all four catalogues". This task took the registry to 40 and changed eight views' widths; counted from the committed command now, it is **29 of 40**. The file was edited in `ba9fec13` without re-counting, and the number is load-bearing: it is the argument for why the named `FileActionEditor` half of that check exists.
Task 9: Important I2 — **the guard loosening and this task's own additions certify each other.** The monotonicity argument is sound (the shape is a dictionary key, so a third element can only split buckets). But both entries this task added are byte-identical on BOTH widths in all four catalogues — `ConnectionFormView` 399/399/438/399 twice, `SnippetEditorView` 291/321/375/346 three times — so each is admitted past `entriesOfOneTypeMeasureDifferentStates` ONLY by the height term added one commit earlier, and each contributes zero committed width coverage. The class the check can no longer separate is "a state that renders the claimed section" from "a state that merely renders one extra line of text". The reviewer verified by hand that both claimed states do render today, and that nothing holds them there.
Task 9: Important I3 — `GenerateKeySheet` now sits 3 pt inside its bound (377 of 380), locale-invariant, **the thinnest margin in the registry** (next: 22 pt, then 27 pt). This task consumed 41 of its 44 pt.
Task 9: Important I4 — `CheckboxRow`'s `.fixedSize()` fixes BOTH axes, so `snippets.editor.skipPlacementCheck`, a full sentence (fr 62 chars), can no longer wrap. That one label now sets the measured minimum of all three `SnippetEditorView` entries in every catalogue (160 → 291/321/375/346). Rigidity's premise is that a squeezed control truncates and silently loses text — a WRAPPING label loses nothing, so this site traded a harmless two-line wrap for a 375-pt one-liner.
Task 9: Important I5 — `TagFilterJoinPicker` (`SidebarTagFilterBar.swift:162-184`) is a `.pickerStyle(.segmented)` with no rigidity that renders INSIDE `TagFilterSheet`, a `BoundedView` whose registry entry is named "two tags selected, so the join choice is on screen". The census missed it because it classifies by ENCLOSING type and this picker is its own type. 27 pt of slack.

Task 9: fix round 2/5 (5 addressed, 2 NEW Important — commits 40f05b1..005554b). The re-reviewer re-derived the count itself: **31 of 40** is right and 29 was the pre-Fix-4 head, so the implementer's correction of the coordinator's figure stands. Fix 4's knock-on confirmed: the open-card entry now moves with the language (260/266/285/330) and is told apart by width AND by an on-screen test, so its circularity is gone twice over; the jump entry's widths are still byte-identical to its sibling's, but its admission now rests on an oracle that is not a size measurement, so the circularity is broken there too.
Task 9: the on-screen oracle was judged sound — it walks `NSView.subviews`, downcasts to public `NSTextField`, and compares `placeholderString` for EXACT equality against a catalogue value resolved under the same override, with a positive and a negative beside each other so both degenerate oracles fail loudly.
**Finding 17 (new, Important) — the fix round's own remedy was applied to 4 of 8 bounded call sites, and its commit message asserted the wrong census.**
`SheetSearchField` has **nine** call sites, not the "four bounded sheets"
the commit message and the new doc comment claim. Four more sit inside
`BoundedView` conformers and did not get the switch:
`SnippetsSheet.swift:134`, `LoginSetsSheet.swift:130`,
`ServerCertificatesSheet.swift:82`, and `ContentView+Detail.swift:2805`
inside `TerminalSnippetPopover`. **That last one is already drawn
compressed**: its measured minimum is 76.0 flat in all four catalogues
while its ideal is de 327 / fr 284 / pl 321 against a 280-pt bound. So
making it rigid will go red for a real reason.
This is the "enumeration of call sites written without counting" failure
the project has a rule about, committed inside the round that found the
defect class by looking for it.
**Finding 18 (new, Important) — `RigidControls.swift`'s header now contradicts its own types.** It still says "Three controls that cannot be compressed below their ideal width" and "The compressible form is not writable through these types". With `wraps: true` and `holdsItsIdeal`, two per-site compressibility seams now exist, and a test asserts the wrapping one compresses. That header is the prose a future contributor reads to decide whether such a seam is permitted.
`Ruling: flip `holdsItsIdeal`'s polarity — rigid by default, with one explicitly named opt-out for the resizable surface. — Why: the reviewer's argument is the plan's own: the default is the unsafe form, forgetting the argument is SILENT (a compressible control reports a small minimum, so the guard stays green while labels are cut), and nothing today stops a future site from using the switch to turn a red green. A seam that must be typed to be unsafe is defensible; one that must be typed to be safe is the defect with a nicer name. — Costs if wrong: one more argument renamed across five call sites, all in this diff.`

Task 9: fix round 3/5 (2 addressed — census completed to all eight bounded sites, polarity flipped to `isInAResizableContainer` defaulting to false, header corrected; commits 005554b..0b0d14f)
Task 9: **the coordinator's instruction was the error, confirmed from a run.** `TerminalSnippetPopover` reports `wide de 114.0/327.0 … of 280.0` — the report prints `minimum/ideal`, so the 327/284/321 the coordinator cited were IDEALS and the guard compares minimums. The implementer measured, found nothing for remedy 2 to answer, and widened nothing despite holding authorisation to. Withdrawn: the dispatch's "Expect the fourth one to go red for a real reason."
Task 9: fix round 4/5 (1 addressed — the header's "Three more rigid controls are NOT components" was an uncounted and short enumeration; it is five, four of them in a bounded view, `SheetFacetPicker` being the missed bounded-view site; commit 0b0d14f..a78ca9c)
Task 9: verified by the coordinator directly rather than by a fifth re-review: `grep -rn 'pickerStyle[(][.]menu[)]' Sources/MacSCPAppKit` prints **5** under the session's ugrep AND under `/usr/bin/grep`, and `RigidControls.swift` does not appear in its own command's output. The implementer reworded the prose for exactly that reason — the old header spelled the style literally, so the same command printed six before the edit, and the sentence would have falsified itself.
Task 9: carried to Task 11 — the scan must put a POSITIVE check on both `var isInAResizableContainer = false` declarations and assert it finds exactly two. Flipping either default to `true` makes every call site compressible and nothing goes red today, because an allow-list of `: true` uses watches who walks through the seam rather than the seam itself.
Task 9: complete (commits aa709bff..a78ca9ca, review clean after 4 fix rounds)

Task 10: DONE_WITH_CONCERNS then fix round 1/5 (4 addressed; commits a78ca9c..638e041c). **The sanctioned STOP was NOT reached** — all six containers fit the width their window leaves them, in all four catalogues, and no window constant moved. The sidebar floor was not raised; remedy 3 answered both hard cases.
Task 10: the reviewer reproduced EVERY load-bearing figure in standalone binaries outside the repo — the 60.0 grouped-`Form` claim, both sets of rigid ideals, the regular-vs-small menu figures, the before and after row figures — all identical. It sharpened the Form finding: the blindness is specific to `.formStyle(.grouped)` (a default-style `Form` reports 608), and the grouped form's IDEAL is a flat 490, so ideal is no escape hatch either. It also closed a gap nobody raised: a `.menu` picker's width does not vary with the selection (delta 0.0 across eight label pairs), so single-state coverage is sound rather than lucky.
Task 10: **a second pre-existing defect found in passing** — `FileSearchBar`'s filter/jump choice was squeezed into 118 pt and rigid needs de 157 / fr 159, so the bar was already overflowing its pane by 4 pt before this task touched it.
Task 10: Important I1 — the join-picker scan counted without attributing: it asserted two calls and exactly one containing `.compactMenu`, never WHICH. Swapping them left it green while the suite measured a copy of the dialog's control and the real sidebar control was a segmented one needing 274 pt against 150. Two further holes in the same tie: a modifier after the call's closing paren was invisible (the slice stops at the first `)`), and anything beside the picker in the row was invisible (the suite measured the picker, never the row). **Fixed by making `HostTagFilterRow` internal and measuring the real row**, which removes the copy rather than patching the tie.
Task 10: Important I2 — nothing tied either Settings section to its extracted row, so the proxy could become an orphan; and `sectionBodies()` returning `section ∪ row` weakened the CLI guard, since its strings could be satisfied by either span. Fixed by requiring each section's body to draw its own row, and by reading the `allCases` iteration in the row alone and the `CompletionShellRow(` call in the section alone. Residual, stated: a section that draws the row AND a hand-written picker beside it is still not caught.
Task 10: Important I3 — `TagFilterJoinPicker.presentation: Presentation = .segmented` is a default nothing watches: flipping it turns the tag dialog into a pop-up with nothing red, because the dialog's call names no presentation and its bound guard only gets narrower. **Carried to Task 11 as the most important carry of the plan.**
Task 10: Important I4 — the search bar's pop-up had no accessibility name while its sibling, changed in the same commit, had one. Fixed with ONE NEW catalogue string in all four languages, `search.mode`: en "Search mode", de "Suchmodus", fr "Mode de recherche", pl "Tryb wyszukiwania". **Surfaced to the maintainer for wording.**
Task 10: the `isInAResizableContainer` opt-out is gone entirely — zero declarations — because both sites were resolved rather than opted out. The seam an earlier review called a deliberate hole no longer exists.
Task 10: closeout item — two user-visible control kinds changed (the sidebar all/any tags choice and the search bar filter/jump choice are now pop-ups) and neither has been looked at. **Corrected 2026-10-18 by the final fix wave:** “two user-visible control kinds changed” undercounts the branch, and this ledger carried no other count. It is FOUR user-visible changes — these two control kinds plus two widened sheet bounds, `GenerateKeySheet` 380 → 420 (`beff2664`) and `TagFilterSheet` 300 → 320 (`c0f1bf5b`), which read 420 and 320 at HEAD and which neither this ledger nor the closeout row recorded until now. The sidebar one is `.controlSize(.small)`, the only small control in that sidebar. Both may owe a `noix-docs` update. A 2-option pop-up costs a click and hides the alternative, which for a frequently toggled search mode is a real usability trade.
Task 10: closeout item — both Settings rows pass the same string twice (`LabeledContent(label) { SegmentedChoice(label, …) }`), so assistive technology may announce it twice.
Task 10: closeout item — a second pre-existing compiler warning, `#UnnecessaryEffectMarker` in a Core test using `#expect(await channel.stdins == …)`. Same class as Finding 13: this branch touches no Core test file.

Task 10: fix round 1/5 (4 addressed, 0 open — commits 5e7c25a3..638e041c). The tie was not patched but REMOVED: `HostTagFilterRow` became internal and the suite measures the real row, which retires all three holes rather than the first. Verified by the re-reviewer from a run: the row's figures equal the picker's alone, so the chip row contributes less than the picker — a measured figure, not a read-off.
Task 10: the re-reviewer found the implementer UNDERSTATED its own residual. `sectionBodies()` still returns `section ∪ row` and serves about seven strings, of which two were moved to section-only spans; the rest (`ShellCompletionRecipe.line(`, `Text(completionLine)`, `setString(completionLine,`, `CLICompletionPresentation.forState(`) still read the union. Minor, because the row carries only a `shell` binding and cannot plausibly satisfy any of them today — but the `rowDeclaration` comment is now stale for one string.
Task 10: the new catalogue string `search.mode` exists exactly once in each of the four `.lproj` files, with no placeholders and no escaping differences; parity, duplicate-key and German-address suites all pass. German is a bare noun, so the du-form rule has nothing to hold.
Task 10: minor (deferred): the container entry is named `typeName: "TagFilterJoinPicker"` but measures `HostTagFilterRow`; the figures are identical and the convention matches the Settings rows, but the doc does not say so.
Task 10: minor (deferred): nothing guards the search bar's new accessibility label — deleting it stays green.
Task 10: complete (commits a78ca9ca..638e041c, review clean after 1 fix round)

Task 11: review 1 — spec ✅ (the coordinator's override of the brief carried out faithfully), quality **Approved**, 0 Critical/Important, 6 Minor. The reviewer reproduced every count from the committed greps, confirmed all three defaults are checked on the DECLARATION rather than the call sites, and verified the catch-all does real work: a planted `.pickerStyle(.inline)` was caught by it alone.
**Finding 19 — the coordinator's brief was wrong about the regex engine, and the implementer measured it rather than obeying it.**
The dispatch asserted Swift's `\b` finds no edge in `x.sheetBound(`, citing
an earlier task's failure. The implementer measured: `NSRegularExpression`
matches `x.isInAResizableContainer`, `range(of:options:.regularExpression)`
matches, Swift's `Regex` does not — and this file uses
`NSRegularExpression`. So probe 14 (swapping the edges back to `\b`) came
back GREEN correctly, and the implementer **reported the green rather than
rounding to fourteen of fourteen**. The re-reviewer reproduced all three
engine results in its own throwaway program. The defensive edges are
harmless and guard a future port.
Task 11: fix round 1/5 (3 addressed, comment-only; commit 644f94c9..6f2fede9)
Task 11: the folded-in Minor that mattered — the "What none of this catches" note could give FALSE COMFORT. It named a styleless `Picker` but not a styleless `Toggle(`, and on macOS a bare `Toggle("label", isOn:)` IS a compressible checkbox by default. So "the checkbox style appears only in the component" did not mean no compressible checkbox exists elsewhere. Verified by the coordinator: `grep -rn -e '[^a-zA-Z]Toggle(' Sources/MacSCPAppKit` prints **37** under the session's ugrep AND `/usr/bin/grep`, and the implementer re-ran it after writing the sentence. No allow-list built over 37 sites — ruled not worth the debt register.
Task 11: minor (deferred): the `\b` sample's "catches the port" claim is weak but honestly worded; the regex is rebuilt per call; the allow-list is a debt register the five raw segmented sites will force an edit to.
Task 11: complete (commits 638e041c..6f2fede9, review clean after 1 fix round)

Task 12: review 1 — spec ✅, quality not approved as-is: 4 Important, 4 Minor, all "a claim whose own command does not test it". The reviewer ran every committed command in committed form under both greps, and checked every withdrawal against `git show 6f2fede9:docs/BACKLOG.md` line by line: all five quotes on row 238 and all three on row 345 are verbatim substrings and nothing was erased.
Task 12: the implementer's DEVIATION was confirmed right — `grep -c -F -e 'workflow_dispatch' .github/workflows/ci.yml` prints 0, Task 1 never ran, and splitting the unanswered macos-15 half into its own open row rather than closing by association is correct. `TagFilterSheet` at 306 of 320 really is the thinnest margin of all 40 entries.
**Finding 20 — the coordinator overstated the CI warning exposure to the maintainer, twice.**
The ledger and two messages to the maintainer said two pre-existing Core
warnings could fail the next push against `MAX_WARNINGS: 0`. The gate's
regex is `^[^[:space:]]+:[0-9]+:[0-9]+: warning:`, and the second warning's
line begins `macro expansion #expect:1:46: warning:` — the space puts it
outside the pattern, and its `ArchiveRunnerTests.swift:82:76` text appears
only on a `note:` line. **One location would be counted, not two.**
Corrected in the row and in the report; the maintainer was told.
Task 12: fix round 1/5 (4 Important + 1 Minor addressed, all with verbatim withdrawals; commits b175deec..77144096). The "37" is retitled "style unclassified" with what the commands do establish (2 styled, 1 menu item, 34 unclassified); the anchors row is retitled "four times in one plan, in three different ways" with each occasion classified (declaration text, content text, span) and the remedy scoped to the two it answers, saying outright it would not have prevented the other two; the red count is settled at seven with the withdrawn "six" quoted; a comment this commit falsified in an untouched file is fixed.
`Ruling: the Task 12 fix round's scoped re-review is folded into the final whole-branch review rather than dispatched separately. — Why: the fix is docs plus one comment, every command in a touched sentence was re-run after writing it, every withdrawal quotes verbatim, and the final reviewer reads the entire branch range including this diff. — Costs if wrong: a docs-only defect reaches the final review instead of a scoped one, where it is still caught before merge.`
Task 12: complete (commits 6f2fede9..77144096, review clean after 1 fix round)

---

## Closing — the final review, the fix wave, and the merge (appended 2026-10-19)

The twelve task entries above stop at `77144096`. Everything after it is
recorded here, appended on the day this ledger was copied out of
`.superpowers/sdd/2026-10-18-sheet-bounds-and-control-rigidity/progress.md`
into `docs/`. That directory is gitignored (`.gitignore:10`), so none of the
text above had ever appeared in a commit: it would have been lost with the
worktree, and the two deliberate wrong turns recorded in it — the layout that
was built, measured and deleted, and the exclusion that was pinned open on a
false premise — are the part of this record worth keeping.

### What the branch is, counted from the tree

Run from the repository root at `0f858325`:

```
git rev-list --count ab5ef6f7..0f858325
grep -rhno -E '(struct|private struct) +[A-Za-z0-9_]+ *: *BoundedView' Sources/MacSCPAppKit | sed -E 's/.*struct +([A-Za-z0-9_]+).*/\1/' | sort -u | wc -l
grep -o 'BoundedViewEntry(' Tests/macSCPAppKitTests/BoundedViewRegistry.swift | wc -l
```

80 commits, 33 distinct conforming types, 40 registry entries. The second
command is spelled against the declaration rather than the conformance because
`grep -rn ': BoundedView' Sources/MacSCPAppKit` prints **34** lines: the extra
one is the doc comment at `SheetBound.swift:52`, which is this project's
"Source-scanning guards read comments too" in miniature — a comment naming the
protocol is indistinguishable from a conformance to a scanner counting
conformances.

### The final whole-branch review and the fix wave

The final review was dispatched on the most capable model over the whole range
`ab5ef6f7..77144096`. Its findings produced a seven-commit fix wave,
`399385a5..e1f656bc`, and then a coordinator correction in `d9084704` and
`0f858325`. The wave's own report is committed beside this file as
`2026-10-18-sheet-bounds-and-control-rigidity-final-fix-report.md`, with its
commands, its figures and its seven residual concerns. **The final review's own
report was never written to disk** and is therefore not part of this record;
only the fix wave's report is.

**The review falsified this work's central claim twice, both times by
measurement.** Both are the same shape — a property the coordinator asserted in
prose and never measured:

1. **A width frame around a rigid component collapses its reported minimum
   exactly as before.** Measured through this repository's own `LayoutMeasure`
   in all four catalogues: `SegmentedChoice` alone reports de 149.0, en 155.0,
   fr 174.0, pl 219.0, and under `.frame(width: 100)`, `.frame(maxWidth: 100)`
   **and `.frame(minWidth: 100)`** reports 100.0 in every catalogue.
   `.frame(maxWidth: .infinity)` leaves it unchanged. Closed:
   `widthFramePattern` now reads
   `(?:width|maxWidth|minWidth)\s*:(?!\s*\.infinity)`, and the check was proved
   red twice through `scripts/mutation-probe`. The exclusion of `minWidth:` had
   been pinned open by an assertion on the reasoned premise that it "raises a
   floor rather than caps"; the measurement above withdrew it.
2. **A styleless `Toggle` is a compressible checkbox on macOS.** `form.jump.toggle`
   reports de 21.0 minimum against a 319.0 ideal, and 319.0/319.0 through
   `CheckboxRow`. Three such sites sit in `ConnectionFormView` (lines 469, 953,
   1253, bound `.capped(minWidth: 420, maxWidth: 460)`). **Open**, as measured
   debt in `docs/BACKLOG.md`: no allow-list was built over the 34 unclassified
   `Toggle(` sites, and that was a ruling, not an oversight.

So the honest statement of what this branch guarantees is narrower than the one
it was planned under: *a localized control in a measured view can no longer be
silently squeezed — if it is written through one of the three components and no
width frame stands around it.* Not more.

**The dominant pattern of the whole run, as in the diff-view work before it:
every load-bearing defect was found by a fresh reviewer or by an implementer
testing a coordinator claim, never by the author's own battery.** Four of the
heaviest were unmeasured coordinator sentences — the premise behind the deleted
layout, the width-frame exclusion above, a brief that prescribed a guard which
could not go red, and a fabricated code quotation whose chain of custody is
recorded in the task entries above.

### What the work found

Five controls that were silently losing text, all pre-existing, none visible as
an overflow: `AuditLogSheet` needed fr 874 / pl 901 against a granted 640; two
`ConnectionFormView` jump rows needed de 525 and fr 486 against 460;
`FileSearchBar`'s filter control overflowed its pane by 4 pt; the sidebar join
picker needed fr 306 against 300. All answered by replacing the control kind,
not by widening the window — **no window minimum moved, and the plan's
sanctioned STOP was never reached.** Two sheet bounds were widened:
`GenerateKeySheet` 380 → 420 (`beff2664`) and `TagFilterSheet` 300 → 320
(`c0f1bf5b`).

### The merge, and what it costs

`Ruling (maintainer, 2026-10-19): merge the branch into develop as a local
fast-forward rather than opening a pull request.` The final review had
recommended the opposite — open the PR so CI reads the figures before they
land — and the reason stands on the record either way: **no CI run has ever
executed any of these measurements.** Task 1, the CI reading, was deferred and
never ran; `grep -c -F -e 'workflow_dispatch' .github/workflows/ci.yml` prints
`0` (with exit status 1, as `grep -c` does on a zero count), so there was no
way to trigger one without a push. All 40 entries, in four
catalogues on both axes, are pinned on Darwin 27.0.0 / macOS 27.0.1 build
26A434 / arm64 / Swift 6.4, on one machine, including one exact-equality
literal (`411`). The thinnest margin of all 40 is `TagFilterSheet` at 306 of
320.

What the merge changes is only *when* that risk is read: the CI workflow
triggers on push to `develop`, so the figures first execute on the three-core
runner after the merge rather than before it. A figure that falls differently
there is a red run on `develop`, not on a pull request.

### Left to the maintainer

1. The wording of the new catalogue key `search.mode` in all four languages
   (en "Search mode", de "Suchmodus", fr "Mode de recherche",
   pl "Tryb wyszukiwania").
2. A sight check of the four user-visible changes: two controls that are now
   pop-up menus, one of them at `.controlSize(.small)`, and the two widened
   sheets above. Nobody has looked at them.
3. The two drafted `CLAUDE.md` lines for `MACSCP_BOUND_FIGURES` and
   `MACSCP_FLOOR_FIGURES`, named in the fix wave's report and **deliberately
   not applied** — that file is the maintainer's.

### What is not committed

The twelve task briefs and reports, and the per-task review diffs, stay out of
version control. The diffs are reconstructible (`git diff ab5ef6f7..0f858325`
and the per-task ranges named in the entries above); the reports are the
implementers' own accounts, and the measurements in them that carry weight were
folded into the entries above, into the test doc comments, or into
`docs/BACKLOG.md`.

### Suite state at `0f858325`

Core 4936 tests in 395 suites green. AppKit 2556 tests in 230 suites with a
single issue: the standing `ViewTestabilitySpike` case "Varying only isRegex
leaves the pixels unchanged" (`ViewTestabilitySpike.swift:202`), red on a clean
tree since Task 2 and not from this branch. Run by the coordinator on
2026-10-19 rather than relayed from a report. Because the merge into `develop`
is a fast-forward, that run is the merged tree: both resolve to tree
`e054fc13`.
