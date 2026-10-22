# Task 8 minors report (review Minors 1, 4, 5)

Status: DONE. Commits on top of `471065f5`, `1eb09f39` not amended, not pushed:

- `27d0df5f test(app): pin that a connected tab's form is never edited` (Minor 1)
- `acdc5775 feat(app): say what resuming versioning starts again` (Minor 5)
- `806eb22f docs(test): the du-pronoun count was a dated figure, so count it and date it` (Minor 4; its message also carries all five probe commands, in the form they ran)

`git diff --stat 471065f5 HEAD`: 9 files, 206 insertions, 11 deletions. `git status --porcelain` empty.

## The revert, and what was redone

When the coordinator's warning arrived, `git status --porcelain` showed only two survivors: the modified `ContentView+MenuActions.swift` (Minor 1 comment) and the untracked `ConnectedTabFormInvariantTests.swift` (untracked files are not touched by `checkout -- .`). The Minor 5 changes (sheet, four catalogues, `BucketVersioningSheetTests.swift`) and the Minor 4 change (`GermanAddressFormTests.swift`) were gone. I redid both from the review text and from the scripts I had saved in the scratchpad, committed Minor 1 and Minor 5 as soon as each compiled and its tests passed, and ran every probe on a committed tree. Everything below is read from the diff and the command output of this redo, not from memory. The redone parts are **reconstructions in the sense that they were written a second time**; the English and translations are the same strings from my saved script, and the test and comments were re-typed.

## Minor 1: the invariant the bucket name rests on

- `ContentView+MenuActions.swift`: the doc comment on `connectionActionContext` now names the three facts (`formTarget()` gives a connected tab's form-filling actions a fresh tab; the detail pane constructs `ConnectionFormView` only in the arm taken while `tab.session` is `nil`; `connect(in:stored:)` tears down before it fills the form) and names the suite.
- New `Tests/macSCPAppKitTests/ConnectedTabFormInvariantTests.swift`, 3 tests, one per fact, reading `SourceCorpus.code` (comments and literals blanked) and `SourceSpan`:
  1. `formTarget` body: the condition must be exactly `<x>.isConnected` (a regex on `if\s+(\w+)\.isConnected\s*\{`, so `&& false` leaves the tokens but fails the match), the block must contain `makeTab(`, and it must precede `return tab`.
  2. The set of AppKit files that construct the form is *derived* (type name from `String(describing: ConnectionFormView.self)`, file set from the sources) and must be exactly `ContentView+Detail.swift`; the session arm (`if let session = tab.session {`) must be followed by `else`, and every construction must lie after the arm's closing brace.
  3. `connect(` body: `if tab.isConnected { await teardown(` must precede `fillForm(`.
  Every anchor is `#require`d (the positives), so a renamed symbol fails by name.
- Probes (on committed `27d0df5f`; exact commands in the `806eb22f` message), all RED, 3 tests ran each, 0 pre-existing failures:
  - `formTarget` condition made `&& false`: `formTargetGivesAConnectedTabAFreshOneInstead`.
  - session arm made unreachable (`, false {`), so the form is mounted for a connected tab: `theFormIsConstructedOnlyInTheArmWithoutASession`.
  - teardown line deleted from `connect`: `connectTearsTheOldSessionDownBeforeItFillsTheForm`.
- **Not probed:** a second construction of `ConnectionFormView` in another file (the derived file-set check). No plant was run against it.
- **What it does not pin**, said in the suite's doc comment: a new writer of `values` that bypasses all three facts. The Core member exposing the connection's own bucket would delete the copy and this suite with it.

## Minor 4: the counted enumeration

**Chosen: both.** The failure message loses its figure (so it cannot go stale); the doc comment keeps the dated count and gains a correction that quotes verbatim the three sentences/phrases it withdraws, plus a count taken now with its command.

- The command had to be earned first. Pattern (one line in the comment, inside a fenced block so it does not wrap):
  `perl -CSD -ne 'print "$1\n" if /^"([^"]*)" = ".*\b(?:[Dd]u|[Dd]ich|[Dd]ir|[Dd]ein\w*)\b.*";$/' <de Localizable.strings>`
  Run over the catalogue at `eb0c387f` (the commit that wrote "The twenty-two,") it prints 22 lines and, sorted, the 22 keys are identical to the 22 enumerated in the comment (`diff` empty). So the pattern reproduces the old claim.
- Over the catalogue as it stands it prints **51** (`| wc -l`). Of the 29 added since (51 less 22), the `s3.versioning` ones are **4** (`| grep -o '^s3\.versioning' | wc -l`), which is: `enableIsOneWay`, `suspendKeepsVersions`, `error.denied` and the new `resumeKeepsVersions`.
- Both committed commands were extracted from the committed comment with `grep -e '^/// git show' -e '^/// perl'` and run in that form **after** the surrounding sentences were written: 22, then 51. I did not adopt the reviewer's 47/50.
- Caveat in the comment: it counts lines, so an entry split across two lines would be missed. It is a dated count (51 on 2026-10-20) and will move.
- Failure message in `noGermanStringAddressesTheUserInThePoliteForm`: "twenty-two strings in the App catalog carry a du-pronoun and" became "many strings in the App catalog carry a du-pronoun and"; the old wording is quoted verbatim in the correction.

## Minor 5: resuming says something about cost

- New key `s3.versioning.resumeKeepsVersions` in `en`, `de`, `fr`, `pl`. English: "Turning versioning back on keeps the earlier version again every time a file is changed or deleted, and those versions count toward your storage costs." German is du-form ("Wenn du die Versionierung wieder einschaltest … zu deinen Speicherkosten"). It does not reuse `enableIsOneWay`.
- `BucketVersioningModel.warning` now returns it for `.suspended` (`nil` only for an unknown state); the doc comment is corrected, quoting the withdrawn sentence "Resuming a suspended bucket has nothing further to warn about."
- **Test that pinned the `nil` was updated:** `eachStateSaysItsOwnThingBeforeTheClick` formerly ended `#expect(suspended == nil)`; it now requires all three warnings non-nil and pairwise different. Its comment quotes the withdrawn assertion and sentence. New test `resumingSaysWhatItStartsAgainAndNotTheOneWayThing`: positive (English names cost) beside negative (does not say "not removed" or "cannot").
- Probes (on committed `acdc5775`), both RED, 21 tests ran each: resume key swapped to `enableIsOneWay` (caught by `eachStateSaysItsOwnThingBeforeTheClick`, `resumingSaysWhatItStartsAgainAndNotTheOneWayThing`, `theEnglishCatalogueSaysTheDefault`); the German line deleted (caught by `everyLineResolvesInAllFourLocales`).
- The existing catalogue checks passed without edits: `LocalizationParityTests`, `GermanAddressFormTests`, the BoundedView layout guards (the new line is in the enabled/suspended sheet states).

## Test summary

`swift test`, no flags, on the committed tree: Core 5074 passed; App 2601 run with exactly 1 failure, `ViewTestabilitySpike` "Varying only isRegex leaves the pixels unchanged" (`ViewTestabilitySpike.swift:202:9`), the same one as in Task 8's own report, not re-measured on an older base. (2597 before this round; +4 = 3 invariant tests + 1 resume test.)

## Could not do

- No probe against the derived file-set half of the Minor 1 guard (above).
- The probe run for Minor 1 and 5 was done after the revert, on committed trees, as asked. The two earlier probe runs of Minor 1 in the lost window did not happen (I had only written the tests).
