# Task 8 review: the versioning sheet, and the menu's handler seam

Reviewed `dda95109..1eb09f39` (one commit) from the worktree
`/Users/noidee/macSCP/.claude/worktrees/diff-view`. Diff package:
`.superpowers/sdd/2026-10-19-s3-bucket-settings/review-dda95109..1eb09f39.diff`
(1665 lines, read in full). `git status --porcelain` was empty before the
first command of this review and empty after the last.

## Spec Compliance

**✅ Spec compliant.** Every item the brief names is present, and the two
things it did not name (the enabling warning, the `@MainActor` fix) are
justified below.

- Files: `BucketVersioningSheet.swift` (new, 300 lines),
  `ContentView+MenuActions.swift` (+58), `ContentView+Lifecycle.swift`
  (the `nil` replaced), `BucketVersioningSheetTests.swift` (new, 20 tests).
  All four brief-listed files have their hunk.
- The brief's three verbatim tests exist under their given names, with the
  given assertions: `BucketVersioningSheetTests.swift`
  `aNeverVersionedBucketOffersOnlyEnabling`,
  `anEnabledBucketCanBeSuspendedAndNotUnset`, `suspendingSaysWhatItDoesNotDo`
  (`warningKey == "s3.versioning.suspendKeepsVersions"`).
- Dispatch by **id**, never by `ConnectionKind`:
  `ConnectionActionRoute.swift:72` `init?(action:)` is
  `self.init(rawValue: action.id)`; the new `extension ContentView` in
  `ContentView+MenuActions.swift:90-146` contains no `ConnectionKind` token
  and no backend case. The switch in `handleConnectionAction` has no
  `default:` (`ContentView+MenuActions.swift:139-144`).
- An id with no case is **unavailable**, not silently enabled:
  `ConnectionActionRoute.isAvailable(_:in:)` returns `false` when
  `ConnectionActionRoute(action:)` is `nil` (`ConnectionActionRoute.swift:78-82`),
  and the menu reads that per row — `.disabled(!isAvailable(action))`
  (`ConnectionActionsMenu.swift`, inside the `ForEach`). Pinned twice, with
  the positive beside the negative:
  `ConnectionActionRouteTests.aWiredIdIsAvailableAndAnUnwiredOneIsNot`
  (asserts a wired row live *first*, `!wired.isEmpty`, and
  `wired.count + unwired.count == everyAction.count`) and
  `anIdWithNoArmIsDisabledWhateverTheConnectionIs` (a stray id no descriptor
  carries, so no later task can make it vacuous).
- §6.2's three states: `offeredStates` is `.never → [.enabled]`,
  `.enabled → [.suspended]`, `.suspended → [.enabled]`, `nil → []`
  (`BucketVersioningSheet.swift`, `offeredStates`). `.never` is never a
  destination — `noStateEverOffersNever` iterates `BucketVersioning.allCases`
  and pairs the negative with a total (`offered == allCases.count`), so an
  all-empty model cannot satisfy it. Suspension is never drawn as "off":
  there is no switch at all, only a state sentence plus one named button
  ("Suspend Versioning" / "Versionierung aussetzen"). `.never` is also
  refused one layer down in Core — `S3FileSystem.setVersioning` builds
  `S3SettingsXML.versioningBody(state)` first, which throws for `.never`
  before a request exists (`S3FileSystem.swift:1770-1773`).
- The store's answer is read back after a write, not assumed:
  `apply(_:bucket:via:)` does `setVersioning` then
  `load = .known((try? await settings.versioning(ofBucket: bucket)) ?? target)`.
  `FakeBucketSettings` makes a write change what the next read returns, so
  `enablingWritesOnceToTheNamedBucketAndShowsTheStoresAnswer` exercises the
  read-back rather than the value just sent.
- Catalogue: 12 `s3.versioning.*` keys per locale, and the four key sets are
  identical. Measured (occurrences, not lines — `grep -o | wc -l`):

  ```
  for l in en de fr pl; do
    grep -o '"s3\.versioning\.[^"]*"' Sources/MacSCPAppKit/Resources/$l.lproj/Localizable.strings | wc -l
  done
  ```
  prints `12` four times; the same extraction `sort`ed and `diff`ed against
  `en` is identical for `de`, `fr` and `pl`. The German entries are du-form
  (`deinen Speicherkosten` twice, `Dein Zugangsschlüssel`). Nothing is
  hardcoded: every string in the sheet goes through `L10n.string`, and
  `everyKeyTheSheetUsesIsOneTheCatalogueChecksCover` scans the view's own
  source (through `SourceCorpus.commentFree`, which keeps literals —
  the right view for that scan) for `"s3.versioning.*"` and fails on a key
  the catalogue checks do not cover, with `used.count > 0` as its positive.
- The guard was rewritten, not deleted:
  `ConnectionActionsMenuTests.aRowIsDisabledUnlessItsOwnIdIsAvailable`
  keeps both halves the brief required. Names derived, not spelled: the
  predicate's name comes from
  `let\s+(\w+):\s*\(ConnectionActionContribution\)\s*->\s*Bool` and the row's
  from `ForEach\([^)]*\)\s*\{\s*(\w+)\s+in`, both `#require`d so a file the
  patterns can no longer read fails loudly instead of satisfying a negative.
  Condition read, not merely present: `hasPrefix("!")` plus whole-identifier
  matches for the predicate and the row. The identifier matcher
  (`names(_:in:)`, NSRegularExpression lookarounds, because Swift `Regex`
  has no lookbehind — the comment's reason is correct) has its own test with
  a positive first, `theIdentifierMatcherTakesWholeNamesOnly`, including the
  `actions`-for-`action` case the implementer says forced it. Note the
  guard's checks are in **positive** form, so by CLAUDE.md's rule they
  cannot go stale in silence.

### ⚠️ Cannot verify from this diff

- **The menu's rows re-render when the remote pane navigates** (the
  implementer's concern 1a). Not testable here and no GUI was launched. I can
  narrow it by reading rather than measuring: the availability closure runs
  while `ConnectionActionsMenu.body` builds the `Menu`'s content, a `Menu`'s
  content is built no later than the moment it is opened, and the pane cannot
  be navigated while the menu is open — so the answer the user sees is the
  answer the click re-checks. The handler's re-check
  (`theDispatcherRechecksAvailabilityBeforeActing`) makes the residue a
  no-op, not a wrong action.
- **The sheet's appearance.** `BoundedViewRegistry` carries four states
  (never / enabled / suspended / failed read), so the layout guards measure
  all four catalogues; that is as far as a test reaches here.
- **User docs.** The "Versioning…" row is live now, which is user-visible,
  and the project rule is "in the same piece of work". The plan puts the
  `noix-docs` page in Task 13 (`docs/superpowers/plans/2026-10-19-s3-bucket-settings.md:1048-1059`),
  so this is a plan-level decision rather than a Task 8 omission. Controller
  should confirm it still intends the closeout placement.

## The bucket-name question, settled

**It cannot diverge from the bucket the live connection uses.** Established
by reading the write side and the read side and showing their windows are
disjoint, then checking the derivation is the same string:

1. **Core's own decision.** `S3FileSystem.init` sets
   `mode = config.startsAtBucketList ? .bucketList : .bucket(config.bucket)`
   and the doc above `RootMode` says it comes from
   `S3ConnectionConfig.startsAtBucketList` "and never re-derived"
   (`S3FileSystem.swift:60-110`). `rootIsContainerList` is derived from
   `mode`, not from the config (`S3FileSystem.swift:1058-1061`) — so the
   *branch* the App takes is Core's answer, not a copy. Only the bucket
   *name* in `.bucket` mode is copied.
2. **The same derivation.** `config.bucket` is
   `S3FieldSchema.bucketToCarry(values)` =
   `values[S3Field.bucket].trimmingCharacters(in: .whitespacesAndNewlines)`,
   blanked to `""` when `startsAtBucketList` is set
   (`S3FieldSchema.swift:209-213`). `ConnectionActionContext.bucket` applies
   the identical trim and treats empty as absent. And when the toggle is on,
   the App never reads `configuredBucket` at all — the path wins, which
   `atTheBucketListTheBucketIsTheFirstComponentOfThePath` pins by passing
   `configuredBucket: "ignored"`. So the stale-hidden-bucket hazard
   `bucketToCarry`'s own comment describes is unreachable here.
3. **Every writer of `values` runs only while `tab.session == nil`**, and the
   menu exists only while `tab.session != nil`
   (`ContentView+Lifecycle.swift:51`, `if let session = activeTab.session`).
   The writers, enumerated:
   - `ConnectionFormView` (user typing, and `selectBucketListMode`, which
     blanks the bucket at the flip) is constructed only in the
     `else` arm of `if let session = tab.session`
     (`ContentView+Detail.swift:411` opens the arm, `:894` builds the form);
     `DetailSurfacePlan.surface`'s own doc says `ContentView.detail` "reaches
     this function only while `tab.session == nil`"
     (`ContentView+Detail.swift:1559`).
   - `editStored` / `fillFromImported` / `newConnection` go through
     `formTarget()`, which returns a **fresh** tab when
     `tab.isConnected` (`ContentView.swift:3465-3471`), and
     `SessionTab.isConnected` is exactly `session != nil`
     (`SessionTab.swift:265`) — the same predicate the toolbar reads.
   - `connect(in:stored:)` tears the session down **before** it fills:
     `if tab.isConnected { await teardown(tab, reason: .userRequested) }`
     precedes `fillForm(form, from: stored)`
     (`ContentView.swift:2438-2448`). So a reconnect-in-place never has new
     values standing beside the old session.
   - `saveFormAsSession` → `beginEditing` is reachable only from the form
     view's `onSaveNew:` (`ContentView+Detail.swift:953`), i.e. the
     `session == nil` arm.
   - `openExternalTerminalFromSidebar` fills a throwaway
     `ConnectionViewModel`, not the tab's (`ContentView.swift:3553`).
   - `ContentView+Diagnostics.swift:56,60` only read `values`.
   A tab moved between windows carries its `connectionViewModel` and its
   `session` together, and the context is built from the pair in one closure,
   so a move cannot split them.

So the concern is **answered, not deferred**: this task did not owe the Core
member, and deferring it is right. One residual, recorded as Minor 1 below:
nothing in the tree *pins* that invariant, and the three facts that make it
true live in three other files.

## Warning-gate measurement

Commands, run from the worktree root, default build system, no
`--build-system` flag:

```
rm -rf $SP && mkdir -p $SP
swift build --target macSCPAppKitTests --scratch-path $SP   # $SP = a fresh dir
```
Exit 0, `Build complete! (97,42 Sek.)`, 1456 build tasks (a from-scratch
compile in that scratch path, not a cache hit). Applying the gate's own
pattern to the log:

```
/usr/bin/grep -E '^[^[:space:]]+:[0-9]+:[0-9]+: warning:' build-head.log | sort -u
```
→ **0 matching lines, 0 unique locations.** The only `warning:` anywhere in
that log is SwiftTerm's `missing creator for mutated node`, which carries no
`file:line:col` and does not match. **The branch clears `MAX_WARNINGS: 0` on
this target.**

The counterfactual, to establish the warnings existed before the fix. The
only difference in that file between `c3c811c8` and `1eb09f39` is the
attribute (`git diff c3c811c8 1eb09f39 -- Tests/macSCPAppKitTests/ConnectionActionsMenuTests.swift`
shows one changed line, `+    @MainActor @Test func theMenuLabelAndTooltip…`),
and the two `ConnectionActionsMenu.labelKey` access lines are 82 and 91 at
both commits. The plant went through `scripts/mutation-probe`, never a
hand-rolled restore:

```
scripts/mutation-probe --filter ConnectionActionsMenuTests --label "no-@MainActor counterfactual" \
  --apply "perl -pi -e 's/\@MainActor \@Test func theMenuLabelAndTooltip/\@Test func theMenuLabelAndTooltip/' Tests/macSCPAppKitTests/ConnectionActionsMenuTests.swift && swift build --target macSCPAppKitTests --scratch-path $SP > build-nomainactor.log 2>&1 || true"
```
(`RESULT: GREEN`, expected — the plant is a warning, not a behaviour change;
`git status --porcelain` empty after the revert.) The log carries **four**
warnings at four unique locations, not two:

```
…/ConnectionActionsMenuTests.swift:82:43: warning: main actor-isolated static property 'labelKey' can not be referenced from a nonisolated context
…/ConnectionActionsMenuTests.swift:82:75: warning: main actor-isolated static property 'helpKey'  …
…/ConnectionActionsMenuTests.swift:91:46: warning: main actor-isolated static property 'labelKey' …
…/ConnectionActionsMenuTests.swift:91:78: warning: main actor-isolated static property 'helpKey'  …
```

Two measurements the controller should have, both reported as Minors below:

- The figure "**two** … warnings … lines 82 and 91" in the report is a
  count of **lines**, not of warnings. There are four, at four unique
  `file:line:col` locations — which is the unit the gate counts.
- **As emitted here, those lines do not match the gate's pattern.** The
  compiler colours diagnostics even when stdout is a file or a pipe, so the
  raw line is `…:82:43: <ESC>[1;33mwarning: …` and
  `grep -E '^[^[:space:]]+:[0-9]+:[0-9]+: warning:'` matched **0** of the
  four on the raw log and **4** only after
  `perl -pe 's/\e\[[0-9;]*m//g'`. CI captures the same way
  (`2>&1 | tee "$RUNNER_TEMP/test.log"`, `.github/workflows/ci.yml:123-124`),
  so if its logs are coloured too, the warning gate cannot see a compiler
  diagnostic at all. I measured this locally only; CI's environment may
  differ. **Not a Task 8 defect** — a pre-existing gate question — but it
  means the premise "this would have failed CI" is unproven, while the
  conclusion "the branch is pushable" holds either way.

## Mutation probes

All sixteen commands were extracted from the commit message
(`git log -1 --format=%B 1eb09f39 | grep '^scripts/mutation-probe'` → 16
lines) and run unrepaired, each through `eval` so the shell parsing matches
what a shell does with the committed text. `git status --porcelain` was
checked after every probe.

PROBE_RESULTS_PLACEHOLDER

## Strengths

- **The seam is the right shape, and it is the shape Tasks 9-11 need.**
  `ConnectionActionContext` holds the four facts the window alone can see,
  `ConnectionActionRoute` is one `switch` arm per id, and the enum's
  exhaustiveness is what makes "a case without an arm does not compile"
  true rather than asserted. `rootIsContainerList` is already on the
  context, so Task 11's bucket-list-only gate has somewhere to attach —
  Task 7's I3 is discharged, and I2 with it.
- **P12's class of failure is really closed.**
  `theStateTheDispatcherSetsIsTheOneASheetIsPresentedFor` reads the state
  the arms *assign* (regex over the body after `switch `), then requires a
  `.sheet(item: $<that state>)` in `ContentView+Sheets.swift` and the sheet
  type after it, with `!assigned.isEmpty` as its positive. Removing the
  `.sheet` leaves a live, inert row, and nothing else in the suite would
  have seen it. This is the one guard in the batch that watches a property
  no other check covers.
- **Source scans use the right corpus view.** `SourceCorpus.code` (comments
  *and* string literals blanked) for the wiring scans, `commentFree`
  (literals kept) for the catalogue-key scan. The scans therefore cannot be
  satisfied by a comment that quotes the code — the failure mode CLAUDE.md
  records from 2026-08-29 — and `!body.contains("default:")` is beside
  three positive checks.
- **The leak test takes both exits.** In
  `aFailureNeverQuotesTheReasonItWasGiven` the planted endpoint lives in a
  named constant and the verdict is computed into `quoted` before the
  expectation, so the expectation that fails *when the leak happens* prints
  a `Bool`. The one expectation that does print `text`
  (`#expect(!text.isEmpty)`) can only fail when `text` is empty, i.e. when
  there is nothing to leak. That ordering is correct, not accidental.
- **Both corrections quote what they withdraw, verbatim.**
  `BackendContributions.swift` quotes the whole false paragraph;
  `BoundedViewCoverageTests.swift` quotes all three figures it moved
  ("The floor is 33 on 2026-10-18", "(which prints 33;", "raise it when a
  thirty-fourth view lands") and re-ran the command under both greps. I
  reproduced it: `grep -rhn -e '^ *struct [A-Za-z]* *: BoundedView {'
  Sources/MacSCPAppKit | wc -l` prints `34` under the session's grep and
  under `/usr/bin/grep`; `grep -o 'BucketVersioningSheet('
  Tests/macSCPAppKitTests/BoundedViewRegistry.swift | wc -l` prints `4`.
- **The copy says what it does and what it does not do.** "Suspending stops
  new versions from being kept. It does not remove any version that is
  already stored: every earlier version stays, and keeps counting toward
  your storage costs until it is deleted." — does, does-not, cost, no
  mechanics, no provider name. The three translations carry the same three
  clauses, and the German is du-form.
- **Scope is defensible file by file**, which is unusual for a diff that
  touches six files the brief did not list. `ConnectionActionRoute.swift`
  must be its own file: `theMenuNamesNoBackendKind` asserts
  `!menu.contains("ConnectionKind")` over `ConnectionActionsMenu.swift`
  (`ConnectionActionsMenuTests.swift:149-156`) and the route's doc comment
  names `ConnectionKind` — and that scan reads comments.
  `ConnectionActionsMenu.swift` cannot be per-row without the new property;
  `ContentView.swift`/`+Sheets.swift` are where a sheet is held and
  presented, following the `PresignedSheetItem` precedent exactly; the four
  catalogues are the brief's Step 5; the registry entry and the floor are
  forced by the project's own guards; the `BackendContributions.swift`
  comment had become false and the comment rule requires the correction in
  the same pass. No scope creep found.

## Issues

### Critical (Must Fix)

None.

### Important (Should Fix)

None.

### Minor (Nice to Have)

1. **The invariant the bucket name rests on is nowhere pinned.**
   `Sources/MacSCPAppKit/ContentView+MenuActions.swift:108-116`. The copy
   cannot diverge today, but only because of three facts in three other
   files (`formTarget()`'s fresh-tab rule, the detail pane's
   `session == nil` arm, `connect`'s teardown-before-fill). The doc comment
   says the value is "what the dial was built from" without naming what
   keeps it so, and a future change that renders the form for a connected
   tab would reintroduce the divergence silently — with an irreversible
   write at the end of it (§6.2; Object Lock in Task 10 is worse, §6.1 says
   it "can never be turned off"). Cheapest durable fix is the read-only
   Core member the implementer proposes, beside `rootIsContainerList`: it
   deletes the copy, and it also removes Task 11's `RootMode`-in-the-App
   problem. Recommend landing it before Task 10 rather than in this task.
2. **The report's warning figure is a line count, not a warning count.**
   `task-8-report.md`, "two 'main actor-isolated static property' warnings
   … lines 82 and 91": measured four, at `:82:43`, `:82:75`, `:91:46`,
   `:91:78`. Same distinction CLAUDE.md draws between `grep -c` and
   `grep -o | wc -l`, and the gate counts locations, so the unit matters.
3. **`message(for:applying:)`'s comment claims more about `RemoteFSFinding`
   than holds.** `Sources/MacSCPAppKit/BucketVersioningSheet.swift`,
   "A finding carries no foreign text and says its own sentence." Five
   findings interpolate a payload (`RemoteFSFinding.messageKey(for:)`'s
   first `case` group: `.unexpectedStatus`,
   `.pathExistsAndIsNotADirectory`, `.uploadPartUnacknowledged`,
   `.objectUnderLegalHold`, `.objectUnderRetention`), and one of them is
   reachable from here — `S3FileSystem.mapErrorStatus` returns
   `.finding(.unexpectedStatus(code: statusCode))` for any status that is
   not 403/404 and that `S3ErrorCode` does not name
   (`S3FileSystem.swift:1373-1387`). What reaches the screen is the
   localized sentence with a server-supplied status *number* in it — no
   secret, and the endpoint-bearing `reason` cases do all fall to the fixed
   sentence as the comment's second half claims. Narrow the sentence to the
   cases reachable here and name them, per this project's rule about
   comments that describe other code.
4. **Adding three du-pronoun strings falsified a counted enumeration the
   diff does not touch.** `Tests/macSCPCoreTests/GermanAddressFormTests.swift`
   lines 8, 15, 42 and the failure message at 234 all say "twenty-two
   strings in the App catalog carry a du-pronoun", counted 2026-09-10, with
   the enumeration listed. The new German entries add three
   (`enableIsOneWay`, `suspendKeepsVersions`, `error.denied`). Measured
   delta, not an absolute (my regex is broader than the one that produced
   "twenty-two", so I give only the difference):
   `git show <rev>:Sources/MacSCPAppKit/Resources/de.lproj/Localizable.strings`
   at `dda95109` and at `1eb09f39`, each through
   `/usr/bin/grep -cE '(^|[^A-Za-zÄÖÜäöüß])([Dd]u|[Dd]ich|[Dd]ir|[Dd]ein[a-zäöüß]*)([^A-Za-zÄÖÜäöüß]|$)'`,
   prints 47 and 50. The figure is dated, which mitigates it, and nothing
   asserts it numerically, so the suite stays green — this is exactly the
   silent kind of staleness the BoundedView floor correction avoided one
   file over. Either recount in that doc comment or annotate it.
5. **Resuming a suspended bucket is the one offered action that says
   nothing about cost.** `BucketVersioningSheet.swift`, `warning`:
   `.suspended` returns `nil`, and the comment says "Resuming a suspended
   bucket has nothing further to warn about." It has one thing: from the
   click on, every change keeps a version again and adds to storage cost —
   which is precisely what the `.never` path warns about. §6.2 does not
   require it and `eachStateSaysItsOwnThingBeforeTheClick` pins the `nil`,
   so this is a deliberate choice, not a slip; it is still the asymmetry a
   reader of the three states will notice. A third short line would close
   it (reusing `enableIsOneWay` would be wrong — the one-way door is
   already shut by then).
6. **`theStateTheDispatcherSetsIsTheOneASheetIsPresentedFor` checks the
   sheet type against the rest of the file, not against that closure.**
   `Tests/macSCPAppKitTests/ConnectionActionRouteTests.swift`, the
   `rest.contains(built)` at the end: `rest` is everything after the
   `.sheet(item: $versioningSheetItem)` occurrence, so a
   `BucketVersioningSheet(` anywhere later in `ContentView+Sheets.swift`
   would satisfy it. It caught P12 as it stands; bounding `rest` to the
   closure (to the next `.sheet(` or a brace match) would make it say what
   it means.
7. **The brief's expected red was not observed, and a cheaper ordering
   would have produced it.** The report is explicit and claims nothing it
   did not see, which is the right call. But the reason the build stopped
   before `BucketVersioningSheetTests.swift` is that both new test files
   were added at once; writing the brief's three tests alone (Step 1) would
   have produced `cannot find 'BucketVersioningModel' in scope` exactly as
   Step 2 predicts. Worth noting for the next task rather than fixing here.
8. **The new file's stated reason is slightly off.** The report says the
   separate file is "because `theMenuNamesNoBackendKind` bans `.s3` in
   `ConnectionActionsMenu.swift`". `.s3` would not have appeared —
   `any S3BucketSettings` and `"s3.versioning"` contain no `.s3`. What the
   guard would actually have caught is `ConnectionKind`, in the route's own
   doc comment. The decision is right; only the derivation given for it is
   not.
9. **Polish.** The sheet's Close button has no `.keyboardShortcut(.cancelAction)`,
   so Escape does not dismiss it; five other sheets in the tree set one,
   though the precedent this sheet names (`PresignedURLSheet.swift:112`)
   does not either. And a failed read offers no retry — the user must close
   and reopen the sheet. Neither is in the brief.

### Not findings

- `macSCPAppKitTests`'s one red, `ViewTestabilitySpike.swift:202` ("Varying
  only isRegex leaves the pixels unchanged"). Confirmed cheaply as not this
  task's: `git log --oneline main..1eb09f39 -- Tests/macSCPAppKitTests/ViewTestabilitySpike.swift`
  prints nothing, and `1eb09f39` touches no comparison source. Set aside.
- Task 11's `CreateBucketModel.isOffered(rootMode:)` problem — the
  controller's own amendment. On the shape question asked of me: the new
  context type is **right** for it. `rootIsContainerList` is already the
  Bool such a predicate needs, and `ConnectionActionRoute.isAvailable(in:)`
  gives the gate an arm of its own. One caution: if Task 11 keeps a model
  predicate *and* a route arm that re-decides the same thing, that is two
  answers to one question — better that the arm calls
  `CreateBucketModel.isOffered(rootIsContainerList:)` than that both spell
  the condition.
- The `@MainActor` addition to Task 7's test. Outside the brief, one
  attribute, removes four build warnings, no behaviour change. Justified.
- The enabling warning (`s3.versioning.enableIsOneWay`). The brief asked
  only for the suspension warning, but §6.1 is the authority the controller
  named and it is explicit: versioning "once on … can only be
  **suspended**, never returned to never-versioned", "Every version already
  stored stays and keeps costing storage", and "the honest sentence is not
  'you must decide now' but 'if you decide yes, you cannot undo it'". The
  added sentence says exactly that, in plain words, in all four locales,
  and `theTwoWarningsAreDistinctInEveryLanguage` holds the two apart. A
  one-way door that the one screen that opens it does not mention would be
  the worse outcome. Keep it.

## Assessment

**Spec compliance:** ✅ Spec compliant.

**Task quality:** Approved.

**Reasoning:** The handler seam is built the way the brief specified —
per-row, keyed by contribution id, exhaustive switch, a row with no arm
disabled rather than inert — and the rewritten guard keeps both properties
it was required to keep, with the plants to show it. The one concern worth a
Critical, an irreversible write landing on the wrong bucket, does not exist:
`values[S3Field.bucket]` is only ever written while the tab has no session,
which is exactly when the menu does not exist, and the one fact the App
copies is derived by the same trim Core uses. What is left is a set of
Minors, of which only the unpinned invariant (1) and the stale German
enumeration (4) are worth acting on before the next task.
