# Task 7, fix round 1

Status: DONE. One commit: `c3c811c8 fix(app): pin the disabled rows of the connection menu, correct two comments` (on top of `1a21c9e0`; `46bfdebb` not amended; not pushed). `git status --porcelain` printed nothing before the first probe and after the last.

## Scope handled

| Item | What I did |
|---|---|
| I1 | New test `theRowsAreDisabledWhileThereIsNoHandler` (see below). Reviewer's plant G, run verbatim through `scripts/mutation-probe`, is now RED. |
| m1 | Every `--apply` string is committed below, in the single-quoted form that was run (re-run in that form this round, all RED). |
| m2 | `BackendContributions.swift` `FileActionContribution` comment rewritten, withdrawn wording quoted. Coordinator's item. |
| m3 | `ConnectionActionContribution` comment: the present-tense "the window routes by it" claim reworded and quoted as withdrawn. |
| m4 | Not touched, per instruction. See "For the coordinator". |
| m5 | Acknowledged: my earlier report's "minus `BackendApply*`" subtracted an empty set. The starting set is `grep -rn 'apply:' Tests --include='*.swift'`, which prints 8 lines, no exclusions. |
| m6 | Label key hoisted to `ConnectionActionsMenu.labelKey`; the tooltip has its own key `connection.actions.menuHelp` ("Manage this connection"), `en`/`de`/`fr`/`pl`. |
| m7 | New test `theWindowPlacesTheMenuWithoutNamingABackend`: the toolbar stretch from the group's opening to the first `uploadButton(` must contain `ConnectionActionsMenu(` (positive) and none of `ConnectionKind`, `.s3`, `.ssh`, `.webdav`, `switch `, `case `. Probe H below measures it (the reviewer left this unmeasured). |
| m8 | No change asked for. |
| I2, I3 | Yours; untouched. |
| I4 | Not fixed, and the old figure is not carried forward. My earlier "two warnings at `S3CreateBucketTests.swift:84`" is withdrawn. Per the review's cold, default-build-system measurement: `:54`, `:65`, `:84` (six warnings) plus `ArchiveRunnerTests.swift:82`, none matched by `ci.yml`'s gate regex. I did not re-measure that and cite it as the reviewer's. |

## I1: the guard

`Sources/MacSCPAppKit/ConnectionActionsMenu.swift` line `.disabled(onSelect == nil)` was unguarded. `theRowsAreDisabledWhileThereIsNoHandler` in `Tests/macSCPAppKitTests/ConnectionActionsMenuTests.swift`:

- Reads the comment-and-string-blanked source (`SourceCorpus.code`), as every other scan there does.
- Derives the handler's name from the file's own declaration (regex `let\s+(\w+):\s*\(\(`, `#require`d), so the name `onSelect` is not spelled in the test.
- Requires a `.disabled(` after the `ForEach(` that draws the rows, and its argument to contain the derived name, `nil` and `==`.
- The test's comment cites the rule it enforces, `MacSCPApp.swift:144-148` ("a menu entry that is enabled and does nothing is exactly what `PaneToggleState`'s own doc comment rules out").

Probe G is the reviewer's plant, byte for byte. G2 is `.disabled(false)`, which checks the test is not just "the line exists".

## Probes (all via `scripts/mutation-probe`, run as written; control 10 tests, 0 pre-existing failures each; tree clean before and after)

The commands, exactly as run (outer single quotes; the inner double-quoted `perl -e` is handed to the script's `eval`, which is why `\$` appears; a `.` stands for a literal `"` in E):

```
scripts/mutation-probe --label 'G: .disabled line removed' --filter ConnectionActionsMenuTests --apply 'perl -ni -e "print unless /^                \.disabled\(onSelect == nil\)\$/" Sources/MacSCPAppKit/ConnectionActionsMenu.swift'
scripts/mutation-probe --label 'G2: .disabled made constant false' --filter ConnectionActionsMenuTests --apply 'perl -pi -e "s/\.disabled\(onSelect == nil\)/.disabled(false)/" Sources/MacSCPAppKit/ConnectionActionsMenu.swift'
scripts/mutation-probe --label 'H: window names a kind beside the menu' --filter ConnectionActionsMenuTests --apply 'perl -pi -e "s/^(\s+)let descriptor = BackendDescriptor\.descriptor\(\$/\1let _ = ConnectionKind.s3\n\1let descriptor = BackendDescriptor.descriptor(/" Sources/MacSCPAppKit/ContentView+Lifecycle.swift'
scripts/mutation-probe --label 'I: tooltip repeats the label in en' --filter ConnectionActionsMenuTests --apply 'perl -pi -e "s/^(.connection\.actions\.menuHelp. = ).*\$/\1\x22Connection Actions\x22;/" Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings'
scripts/mutation-probe --label 'A: condition removed' --filter ConnectionActionsMenuTests --apply 'perl -pi -e "s/if ConnectionActionsMenu\.isPresented\(for: descriptor\) \{/if true {/" Sources/MacSCPAppKit/ContentView+Lifecycle.swift'
scripts/mutation-probe --label 'B: icon before menu' --filter ConnectionActionsMenuTests --apply 'perl -pi -e "s/^(\s+)let descriptor = BackendDescriptor\.descriptor\(\$/\1let _ = uploadButton(in: activeTab, session: session)\n\1let descriptor = BackendDescriptor.descriptor(/" Sources/MacSCPAppKit/ContentView+Lifecycle.swift'
scripts/mutation-probe --label 'C: menu names a kind' --filter ConnectionActionsMenuTests --apply 'perl -pi -e "s/^(    let descriptor: BackendDescriptor)\$/\1\n    static let planted = ConnectionKind.s3/" Sources/MacSCPAppKit/ConnectionActionsMenu.swift'
scripts/mutation-probe --label 'D: always presented' --filter ConnectionActionsMenuTests --apply 'perl -pi -e "s/!descriptor\.connectionActions\.isEmpty/true/" Sources/MacSCPAppKit/ConnectionActionsMenu.swift'
scripts/mutation-probe --label 'E: pl objectLock entry missing' --filter ConnectionActionsMenuTests --apply 'perl -ni -e "print unless /^.connection\.action\.objectLock. = /" Sources/MacSCPAppKit/Resources/pl.lproj/Localizable.strings'
scripts/mutation-probe --label 'F: S3 list emptied' --filter BackendContributionTests --apply 'perl -0pi -e "s/connectionActions: \[\n\s+ConnectionActionContribution\(.*?\n        \],/connectionActions: [],/s" Sources/macSCPCore/Capabilities/BackendDescriptor.swift'
```

Results (each log's `RESULT:` line and catchers; baseline tree `c3c811c8`):

| Plant | Result | Caught by |
|---|---|---|
| G | RED, 10 ran | `theRowsAreDisabledWhileThereIsNoHandler` |
| G2 | RED, 10 ran | `theRowsAreDisabledWhileThereIsNoHandler` |
| H | RED, 10 ran | `theWindowPlacesTheMenuWithoutNamingABackend` |
| I | RED, 10 ran | `theMenuLabelAndTooltipResolveInAllFourLocalesAndDiffer` |
| A | RED, 10 ran | `theMenuIsConstructedOnlyWhereItIsPresented` |
| B | RED, 10 ran | `theMenuIsTheFirstThingInThePrimaryActionGroup` and, new this round, `theWindowPlacesTheMenuWithoutNamingABackend` (the first `uploadButton(` now precedes the menu, so the placement stretch loses its positive) |
| C | RED, 10 ran | `theMenuNamesNoBackendKind` |
| D | RED, 10 ran | `aBackendWithNoActionsRendersNoCapsule`, `presentationIsExactlyANonEmptyList` |
| E | RED, 10 ran | `everyActionTitleResolvesInAllFourLocales` |
| F | RED, 5 ran | all five `BackendContributionTests` |

A through F match the previous round's catchers, except B's extra catcher and the E/C/A/D/B plants now being written in their re-runnable single-quoted forms (last round's were double-quoted with `\"`/`\$` escapes). The `.` in E's pattern matches the quote characters, so the plant removes exactly the `connection.action.objectLock` line in `pl`.

## The comments (m2, m3), in `BackendContributions.swift`

- `FileActionContribution`'s header ended `(M12 seam; empty for ssh/s3 now — S3 presigned URL lands in M14).` That sentence is withdrawn in place, quoted verbatim in the new comment. Measured with `grep -n 'fileActions' Sources/macSCPCore/Capabilities/BackendDescriptor.swift` (coordinator's command): the stored property at 115, the doc reference at 118, then the three lists, ssh `[]` at 490, s3 non-empty at 515, webdav `[]` at 571. S3's list gained `s3.presignedURL` in `df0a74a3`, found with:
  `git log --oneline -S'FileActionContribution(id: "s3.presignedURL"' -- Sources/macSCPCore/Capabilities/BackendDescriptor.swift`, which prints exactly `df0a74a3 feat: surface backend file actions in the browser context menu`. The new text cites that hash and that command, and writes no count and no list of which backends are empty (that would be an enumeration to go stale).
- `ConnectionActionContribution`'s "the window routes by it and never by `ConnectionKind`" is withdrawn (quoted) as true of file actions and aspirational here; the replacement says nothing routes by a connection action's `id` yet because the menu has no handler.
- I searched the file for other comments naming these things: the `DiagnosticContribution` / `DiagnosticContext` comments below do not describe either list.

## Tests

- `swift test --filter ConnectionActionsMenuTests --filter BackendContributionTests`: `Test run with 5 tests in 1 suite passed` and `Test run with 10 tests in 1 suite passed`.
- Full `swift test` (no flags), on `c3c811c8`. Command for the figures: `grep -n -e '✘' -e 'Test run with'` over the ANSI-stripped log:

```
12344:✔ Test run with 5074 tests in 407 suites passed after 18.358 seconds.
18113:✘ Test "Varying only isRegex leaves the pixels unchanged" recorded an issue at ViewTestabilitySpike.swift:202:9: Expectation failed: off == on
18134:✘ Test "Varying only isRegex leaves the pixels unchanged" failed after 0.758 seconds with 1 issue.
18207:✘ Suite "ViewTestabilitySpike" failed after 22.112 seconds with 1 issue.
18330:✘ Test run with 2566 tests in 231 suites failed after 22.931 seconds with 1 issue.
```

Core is unchanged at 5074 passed. App went 2563 to 2566, which is the three tests added (`theRowsAreDisabledWhileThereIsNoHandler`, `theWindowPlacesTheMenuWithoutNamingABackend`, `theMenuLabelAndTooltipResolveInAllFourLocalesAndDiffer`). The one red, `ViewTestabilitySpike`, is the same pre-existing failure measured last round at BASE `f3ec6e07`.

## For the coordinator

- m4: `docs/superpowers/plans/2026-10-19-s3-bucket-settings.md` no longer reads as the review quoted at 631. `grep -n 'A synthetic descriptor exists' docs/superpowers/plans/2026-10-19-s3-bucket-settings.md` now prints one line, 634, `error.** This step first read "A synthetic descriptor exists in`, which is a correction already in the plan (HEAD moved to `1a21c9e0` and the diff `46bfdebb..c3c811c8` includes plan and spec edits that are not mine). I left the plan alone and have nothing further to report on m4.
- I did not touch `ci.yml`, the warnings, I2 or I3.
- Unmeasured: the German/French/Polish tooltip wording ("Diese Verbindung verwalten", "Gérer cette connexion", "Zarządzaj tym połączeniem") is mine, checked only by catalogue parity, not by a native speaker.
