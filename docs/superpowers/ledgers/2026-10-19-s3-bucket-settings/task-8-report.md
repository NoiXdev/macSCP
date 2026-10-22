# Task 8 report: the versioning sheet, and the menu's handler seam

Status: DONE_WITH_CONCERNS (concerns at the end).
BASE `dda95109`. One commit: `1eb09f39 feat(app): turn a bucket's versioning on, and say what suspending keeps`. Not pushed. The commit message carries the red quotes and all sixteen probe commands in the form they ran.

## What changed

- `Sources/MacSCPAppKit/ConnectionActionRoute.swift` (new, not in the brief's file list): `ConnectionActionContext` (the session's `S3BucketSettings?`, `rootIsContainerList`, the remote pane's path, the configured bucket; `bucket` derived from them) and `ConnectionActionRoute: String, CaseIterable` with one case, `versioning = "s3.versioning"`. It is the dispatch table, keyed by id. `static isAvailable(_ action:, in:)` answers `false` for an id with no case. Separate file because `theMenuNamesNoBackendKind` bans `.s3` in `ConnectionActionsMenu.swift`.
- `ConnectionActionsMenu.swift` (not in the brief's list; the seam cannot be per-row without it): `isAvailable: (ConnectionActionContribution) -> Bool` and `onSelect: (ConnectionActionContribution) -> Void`; `.disabled(!isAvailable(action))`.
- `ContentView+Lifecycle.swift`: the `nil` is replaced by two one-line closures that call `connectionActionIsAvailable` and `handleConnectionAction`.
- `ContentView+MenuActions.swift`: a second `extension ContentView` with `connectionActionContext(in:session:)`, `connectionActionIsAvailable`, `handleConnectionAction`. The handler re-checks availability, then `switch route` with no `default`. Dispatch is by id through the route enum, the way `action.id == "s3.presignedURL"` is, never by `ConnectionKind`.
- `ContentView.swift` + `ContentView+Sheets.swift`: `BucketVersioningSheetItem`, `@State versioningSheetItem`, and the `.sheet(item:)` (the `PresignedSheetItem` precedent: the bucket and capability are captured at presentation).
- `BucketVersioningSheet.swift` (new): `CatalogueLine`, `BucketVersioningModel` (`@MainActor @Observable`; `init(current:)`, `init()` for reading, `init(loadFailure:)`; `offeredStates`, `warning`/`warningKey`, `stateLine`, `read`, `apply`, `message(for:applying:)`) and `BucketVersioningSheet: BoundedView` (`.width(420)`).
- Catalogue: twelve `s3.versioning.*` keys in `en`, `de`, `fr`, `pl` (title, reading, three state sentences, the two warnings, two action labels, three failure sentences). German is du-form (`deinen Speicherkosten`, `Dein Zugangsschlüssel`); French follows the menu title's term ("gestion des versions").
- Tests: `BucketVersioningSheetTests` (20), `ConnectionActionRouteTests` (10), `FakeBucketSettings` (shared double, also used by the layout registry), the rewritten guard in `ConnectionActionsMenuTests`, four `BoundedViewRegistry` entries.
- Also touched, each for a reason: `BackendContributions.swift` (its doc comment said "Nothing routes by a connection action's `id` yet ... the toolbar menu has no handler wired (`ConnectionActionsMenu.onSelect`), so the rows render disabled" -- now false; corrected in place quoting that text verbatim, per the comment rule); `BoundedViewCoverageTests` (floor 33 to 34, command re-run, correction quotes the old wording); `ConnectionActionsMenuTests.theMenuLabelAndTooltip...` gained `@MainActor` (it produced two "main actor-isolated static property" warnings in every build since Task 7: lines 82 and 91, present in my first red log too).

## The warning copy

English (the source the others are measured against), the two sentences about money:

- Suspending (shown on an enabled bucket): "Suspending stops new versions from being kept. It does not remove any version that is already stored: every earlier version stays, and keeps counting toward your storage costs until it is deleted."
- Enabling (shown on a never-versioned bucket; **my addition, the brief only asked for the suspension warning**): "Once switched on, versioning can be suspended later but not removed. While it is on, every earlier version of a file is kept and counts toward your storage costs."

Neither names the store's mechanics (no delete marker, no provider name). `theSuspendWarningIsPlainAndNamesNoMechanics` holds that, with a positive half (it names cost).

## The red, observed

**1. The rewritten guard alone, against the unchanged menu.** Before any other test or production change. Command: `swift test --filter ConnectionActionsMenuTests`. Exit 1. ANSI stripped, the log is 293 lines. **Excerpt**, lines 249-252 and 291 of that file:

```
✘ Test aRowIsDisabledUnlessItsOwnIdIsAvailable() recorded an issue at ConnectionActionsMenuTests.swift:205:29: Expectation failed: menu.firstMatch(of: declaration)?.output[1].substring.map(String.init)
↳ menu.firstMatch(of: declaration)?.output[1].substring.map(String.init) → nil
↳   menu.firstMatch(of: declaration)?.output[1].substring → nil
✘ Test aRowIsDisabledUnlessItsOwnIdIsAvailable() failed after 0.020 seconds with 1 issue.
✘ Test run with 10 tests in 1 suite failed after 0.056 seconds with 1 issue.
```

That is the guard's first positive (`#require` on the availability predicate's declaration) failing because the old menu has `onSelect: ((...)?` and no such property. Red for the reason the brief predicted.

**2. All new tests, no production code.** Command: `swift test --filter BucketVersioningSheetTests --filter ConnectionActionRouteTests --filter ConnectionActionsMenuTests`. Exit 1, 217 lines ANSI-stripped. First error line, verbatim: `ConnectionActionRouteTests.swift:25:10: error: cannot find type 'ConnectionActionContext' in scope`. Counted over the whole log (`grep -o ... | sort | uniq -c`): 15x `cannot find 'ConnectionActionRoute' in scope`, 3x `generic parameter 'some StringProtocol' could not be inferred`, 2x `cannot find type 'ConnectionActionContext' in scope`, 2x `cannot find 'ConnectionActionContext' in scope`. **Only `ConnectionActionRouteTests.swift` reported errors: the build stopped at the first failing compile unit, so `BucketVersioningSheetTests.swift`'s `cannot find 'BucketVersioningModel' in scope` was NOT observed and I do not claim it.** (`FakeBucketSettings.swift` compiles on its own.)

## Green

- Targeted, final tree: `swift test --filter BucketVersioningSheetTests --filter ConnectionActionRouteTests --filter ConnectionActionsMenuTests` printed `Test run with 41 tests in 3 suites passed`. (Suites: 20 + 10 + 11.)
- Full, `swift test`, no flags, on the committed tree. Command for the figures: `grep -n -e '✘' -e 'Test run with'` over the ANSI-stripped log:

```
12314:✔ Test run with 5074 tests in 407 suites passed after 18.819 seconds.
18192:✘ Test "Varying only isRegex leaves the pixels unchanged" recorded an issue at ViewTestabilitySpike.swift:202:9: Expectation failed: off == on
18421:✘ Test run with 2597 tests in 233 suites failed after 23.878 seconds with 1 issue.
```

Core 5074 passed; App 2597 with exactly one failure, `ViewTestabilitySpike`, the same one Task 7's report records on its own base. **I did not re-measure it on `dda95109`**; I only know it is the same test, line and message, and that this change adds no `Toggle`. App was 2563 at Task 7's report, 2597 now: +34 (a first full run before two later additions printed 2595).
- The existing `BoundedViewLayoutGuardTests`, `BoundedViewCoverageTests`, `RigidControlScanTests` and `LocalizationParityTests` / `GermanAddressFormTests` all passed with the new sheet registered in four states and the catalogue in four languages. Warnings: the only one in the build output is SwiftTerm's `missing creator for mutated node`; the two `labelKey`/`helpKey` warnings are gone.

## Mutation probes

All through `scripts/mutation-probe` on the committed tree; `git status --porcelain` empty before the first and after the last (checked again after P-last). Sixteen probes; every one RED (caught) with the control run green. **The commands are in the commit message, verbatim, in the form they ran**; summary:

| | Plant | Filter | Caught by |
|---|---|---|---|
| P1 | menu `.disabled(false)` | ConnectionActionsMenuTests | aRowIsDisabledUnlessItsOwnIdIsAvailable |
| P2 | `.disabled(isAvailable(action))` (sense inverted) | same | same |
| P3 | the `.disabled` line deleted (Task 7's plant) | same | same |
| P4 | predicate asked of `descriptor.connectionActions[0]` | same | same |
| P5 | call site `isAvailable: { _ in true }` | ConnectionActionRouteTests | theWindowAsksTheRouteForAvailabilityAndForTheAction |
| P6 | call site `onSelect: { _ in }` | same | 4 tests |
| P7 | `default: break` in the dispatch switch | same | everyRouteHasItsOwnArmAndTheSwitchHasNoDefault |
| P8 | availability re-check removed from the handler | same | theDispatcherRechecksAvailabilityBeforeActing |
| P9 | capability check dropped from the route | same | versioningNeedsTheCapability |
| P10 | bucket-list branch disabled | same | atTheBucketListTheBucketIsTheFirstComponentOfThePath |
| P11 | bucket requirement dropped from the route | same | atTheBucketList..., inOneBucketTheBucketIsTheConfigured... |
| P12 | `.sheet(item:)` removed: a live, inert row | same | theStateTheDispatcherSetsIsTheOneASheetIsPresentedFor |
| P13 | never-versioned also offered `.suspended` | BucketVersioningSheetTests | 5 tests |
| P14 | enabled also offered `.never` | same | 3 tests |
| P15 | `apply` no longer refuses an unoffered state | same | aStateThatWasNotOfferedIsNeverSent |
| P16 | one warning deleted from `pl.lproj` | same | everyLineResolvesInAllFourLocales |

**Against the rewritten menu guard, as asked:** P1 (the brief's `.disabled(false)`), P2, P3 (the Task 7 deletion plant that came back green during that review) and P4. P2 and P4 are new with this task. P4 exists because of a hole I closed before probing: the guard first checked `argument.contains(row)`, a substring test, which `actions` or `connectionActions` would satisfy; it now matches whole identifiers (`ConnectionActionsMenuTests.names(_:in:)`, with `theIdentifierMatcherTakesWholeNamesOnly` on the cases that made it necessary, a positive first).

Not probed: the four registry entries and the localized text's wording (the layout guards ran green, but I planted nothing against them).

## Decisions I made that the brief did not make

1. **Where the bucket name comes from.** `S3BucketSettings` takes the bucket as an argument, and the App has no way to ask the connection which bucket it is in: `S3FileSystem.RootMode` is `internal`, and `rootIsContainerList` is the only root-mode fact exposed. So:
   - connection rooted in one bucket: the bucket is `tab.connectionViewModel.values[S3Field.bucket]`, trimmed. This is the form the dial was built from (`connect(in:stored:)` fills `tab.connectionViewModel` and then dials it), but it is a **copy of what Core decided**, not Core's answer.
   - connection at the bucket list: the first component of the remote pane's current path; at `/` there is no bucket and the row is unavailable.
   Both are in `ConnectionActionContext.bucket` and covered by tests. If you would rather have Core expose the connection's bucket (a read-only member beside `rootIsContainerList`), that is a small Core change I did not make because the brief limits this task to the App.
2. **Task 11's gate.** `ConnectionActionContext.rootIsContainerList` is what a bucket-list-only gate reads; Task 11's plan text says `CreateBucketModel.isOffered(rootMode: .bucketList)` with a `RootMode` the App cannot name in production code (it is `internal` to Core). Task 11 will want `isOffered(rootIsContainerList:)` or the like. `ConnectionActionRoute.isAvailable(in:)` is a `switch` with one arm per case, so Task 11's predicate is an arm of its own.
3. **The enabling warning** (above) is mine. The spec's sections 6.1 and 6.2 say the one-way door is worth saying; the brief only specified the suspension warning.
4. **No default action key on the apply button**, deliberately: enabling is one-way and Return should not be able to do it.

## Concerns

1. **Not seen running.** No GUI was launched, as instructed. Two things I could not check: (a) whether the menu re-renders its rows' enabled state when the remote pane navigates (the closure reads `session.remote.currentPath` while `ConnectionActionsMenu.body` runs, which should register for observation, but a `Menu`'s content closure may be evaluated outside that tracking). The handler re-checks availability at click time, so the worst case is a stale look, not a wrong action. (b) The sheet's actual appearance; the layout guard measures it in all four catalogues, which is all a test can do.
2. **The bucket-name source (decision 1)** is the weakest joint. A saved session whose form values were edited after connecting would give a different name than the live connection; the form is not shown while connected, so I believe it cannot happen, but that is reading, not a test.
3. **User docs.** The "Versioning…" row is live now, which is a user-visible change. The plan puts the `noix-docs` page in Task 13's closeout; I wrote none. Flagged because the project rule is "in the same piece of work".
4. **Audit trail.** A versioning change is not recorded yet; Task 12 owns that.
5. **`scripts/mutation-probe` and the session's command checker.** `--apply` is refused when the text sits in a construct the checker cannot verify: a redirect after it (`> log 2>&1; echo exit=$?`), or `sh <file>`. Plain `perl -pi -e ...` / `perl -0pi -e ...` with no redirect runs. Every command in the commit message is in the form that ran. The plain form prints its RESULT block to the terminal and not to a file, so the "caught by" lists above are transcribed from that output.
6. **Pre-existing, not touched:** the `ViewTestabilitySpike` red; the two `S3CreateBucketTests.swift:84` macro-expansion warnings Task 7's report names (they show in a build of that test target; not re-examined).
7. **Counts in my own comments**, per the rule: the registry comment says "Four states" (four entries, `grep -c 'BucketVersioningSheet(' Tests/macSCPAppKitTests/BoundedViewRegistry.swift` prints 4); the floor correction quotes 33/34 and `grep -rhn -e '^ *struct [A-Za-z]* *: BoundedView {' Sources/MacSCPAppKit | wc -l` prints 34 under both the session's grep and `/usr/bin/grep`. No `///` comment of mine wraps a command across lines.
