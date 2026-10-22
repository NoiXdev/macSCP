# Task 12 report: the audit trail

Written from `git log --oneline 341434f8..HEAD` and `git diff --stat 341434f8..HEAD`
(26 files, 952 insertions, 117 deletions), read back before describing.

## 1. What changed

Three commits on `s3-bucket-settings` over BASE `341434f8`:

- `7abc77b8` feat(core): four audit kinds, the recorder, the labels, the widened guard.
  - `AuditEvent.Kind` gains `bucketCreated`, `versioningChanged`, `corsChanged`, `objectLockChanged`.
  - `AuditRecorder` gains `recordBucketCreated`, `recordVersioningChanged`, `recordCORSChanged`,
    `recordObjectLockChanged`, plus `AuditRecorder.ObjectLockChange`
    (`.retention`, `.legalHold`, `.bucketDefault`). Each takes `failure: String?` with no default;
    a non-nil failure is `isError: true` with the sentence as `errorMessage`. A retention line names
    mode and date (UTC, internet date-time), e.g. `retention of b1/reports/q3.pdf set to COMPLIANCE until 2027-01-15T08:00:00Z`.
  - Four catalogue labels in each of en/de/fr/pl (`audit.kind.<rawValue>`); de/fr/pl reuse the
    existing terms "Objektsperre" (de), "Verrouillage d’objet" (fr), "Blokada obiektów" (pl).
  - `ConnectionHistory.rows` has an exhaustive `switch` over `Kind`; the four are added to its explicit ignored set.
  - `everyKindHasACatalogLabel` widened to `allCases` x `Self.languages` (Ruling 14).
  - New `Tests/macSCPCoreTests/AuditRecorderBucketSettingsTests.swift` (10 tests).
- `c355dd63` feat(app): the five apply paths record.
  - `recorder: AuditRecorder?` added, required with no default, to `CreateBucketModel.create(via:recorder:)`,
    `BucketVersioningModel.apply(_:bucket:via:locks:recorder:)`, `BucketCORSModel.save(bucket:via:recorder:)`,
    `ObjectLockModel.run(key:bucket:via:recorder:)`, `BucketObjectLockModel.save(bucket:via:recorder:)`;
    also a required `let recorder` and first init parameter on the five sheet structs, and a required
    `recorder` on the five `ContentView.*SheetItem` structs, filled from `tab.auditRecorder` in
    `ContentView+MenuActions.swift` and passed on as `item.recorder` in `ContentView+Sheets.swift`.
  - Recording happens at the moment the store accepts the write (before the read-back) or refuses it. A click the
    sheet itself refuses (`canRun`/`canSave`/`canCreate` false, or a dropped target) records nothing.
  - Existing tests: 68 call sites gained `recorder: nil`, 37 sheet constructions (35 in `BoundedViewRegistry`, 1 in
    `CreateBucketSheetTests`, 1 in `BucketCORSSheetTests`) gained `recorder: nil`; two source scans that pin the sheets'
    call text (`theSheetSavesAndLoadsTheBucketItWasOpenedFor`, `theSheetIsOpenedAndRunForTheFileThatWasChosen`) and one
    in `CreateBucketSheetTests` (`aMadeBucketRefreshesThePaneThatListsIt`) now expect `recorder: recorder`.
  - Stale comments corrected (see Ruling 15): `SessionTab.auditRecorder` and `ContentView.attachAuditRecorder` docs.
  - New `Tests/macSCPAppKitTests/BucketSettingsAuditTests.swift`.
- `98ffbc7a` test(app): two source scans that the tab's recorder reaches each sheet item and each sheet
  (`everySheetItemIsBuiltWithTheTabsRecorder`, `everySheetIsBuiltWithItsItemsRecorder`; type names read from the
  types with `String(describing:)`, not spelled).

Counts above: `git show c355dd63 -- Tests | grep '^+' | grep -o ', recorder: nil)' | wc -l` prints 68;
`... | grep -E -o 'Sheet\(recorder: nil|^\+ *recorder: nil,$' | wc -l` prints 37 (run on a saved copy of the diff).
The `c355dd63` commit message says "69 test call sites and 40 sheet constructions"; both figures are wrong
(69 counted one string literal in a source scan; 40 was never counted). 68 and 37 are the measured ones. Per
Ruling 16 the commit is not rewritten; `ee0bbf0a` quotes the wrong wording and carries the two commands (section 7).

Design notes. The table in `BucketSettingsAuditTests` has six rows for the five methods because
`ObjectLockModel.run` serves both retention and legal hold (told apart by `focus`). The audit sheet's filter
facets use `default:`, so the four new kinds appear under All and Errors only; adding a facet is not done.

## 2. The red, verbatim

Three reds were observed. None is reconstructed.

**Ruling 14, the widened guard.** First, `swift test --filter SnippetAuditWiringGuardTests` with the guard widened and
nothing else changed: `✔ Test everyKindHasACatalogLabel(kind:) with 15 test cases passed` (15 existing kinds, all
four languages: the positive control). Then with the four `Kind` cases declared and only the English labels added:

```
✘ Suite "Snippet audit wiring" failed after 0.049 seconds with 12 issues.
✘ Test everyKindHasACatalogLabel(kind:) with 19 test cases failed after 0.049 seconds with 12 issues.
↳ missing for bucketCreated in de   (and fr, pl)
↳ missing for versioningChanged in de   (and fr, pl)
↳ missing for corsChanged in de   (and fr, pl)
↳ missing for objectLockChanged in de   (and fr, pl)
```
(12 `missing for <kind> in <lang>` lines, none for `en`; saved to the scratchpad as `guard-red.txt`.) Two things worth
knowing: the failure message prints the whole catalogue text because `#expect` expands `text` (pre-existing style, I left
it); and the premise "an English-only label would pass in silence" is only partly true, because the key-set parity
tests (`LocalizableStringsTests`) would very likely have caught an en-only key. I did not verify that by running
them red, so it is a likelihood, not a measurement. The widened guard names the kind and language directly either way.

**Core recorder.** Tests written before the methods; red was a compile error, not an assertion:
`AuditRecorderBucketSettingsTests.swift:39:35: error: value of type 'AuditRecorder' has no member 'recordBucketCreated'`
(and the same for the other three methods). Green after: `Test run with 10 tests in 1 suite passed`.

**App apply paths.** The five apply methods and sheets were given the required `recorder:` parameter first, doing
nothing with it, so the new tests failed by assertion and not by compile error.
`swift test --filter BucketSettingsAuditTests`:

```
✘ Suite "Bucket settings audit" failed after 0.072 seconds with 60 issues.
✘ Test eachOperationRecordsExactlyOneEventOfItsOwnKind(operation:) with 6 test cases failed after 0.022 seconds with 24 issues.
✘ Test aRefusedOperationRecordsTheFailureAndNotASuccess(operation:) with 6 test cases failed after 0.020 seconds with 24 issues.
✘ Test aRefusalsOwnWordsNeverReachTheTrail(operation:) with 6 test cases failed after 0.021 seconds with 6 issues.
✘ Test anObjectLockLineNamesWhichOfTheThreeOperationsItWas() failed after 0.023 seconds with 5 issues.
✘ Test aRunTheSheetRefusesBeforeAnyRequestRecordsNothing() failed after 0.020 seconds with 1 issue.
```
(sample issue: `Expectation failed: events.count == 1` at `BucketSettingsAuditTests.swift:159` / `:180`.) Passing in that same red run,
as expected: `theTableCoversEveryNewKind`, `anAdHocConnectIsGivenARecorderUnderTheAdHocLogID`, and
`withNoRecorderTheWriteStillGoesThroughAndNothingIsRecorded` (which passes vacuously before recording exists; its
positive control is `eachOperationRecordsExactlyOneEventOfItsOwnKind`, same operations).

**No red observed** for the two later source scans (`everySheetItemIsBuiltWithTheTabsRecorder`,
`everySheetIsBuiltWithItsItemsRecorder`): they were written against already-correct code and went green at once.
Their sensitivity is what probes P8 and P9 (section 4) measure.

## 5. The four rulings, one line each

- **Ruling 12 (five shapes, not one signature):** done. `BucketSettingsAuditTests.operations` is a table of
  (name, expected kind, invoking closure) with one closure per apply method (six rows for five methods, because
  `ObjectLockModel.run` serves retention and legal hold); `eachOperationRecordsExactlyOneEventOfItsOwnKind` is
  parameterised over it, and so are the refusal test, the store's-words test and the no-recorder test.
- **Ruling 13 (required, no default, optional type):** done. `recorder: AuditRecorder?` has no default on all five apply
  methods, on all five sheet inits (first parameter) and on all five `ContentView.*SheetItem` memberwise inits; doc
  comments say "No default value" in the words of `BucketVersioningModel.init(current:bucketHasObjectLock:)`. A new
  apply path or sheet without a decision does not compile. The compiler cannot check the VALUE passed, so two small
  source scans (commit `98ffbc7a`) check that the dispatcher passes `tab.auditRecorder` and the sheet builder passes
  `item.recorder`.
- **Ruling 14 (catalogue guard x four languages):** done; red quoted in section 2.
- **Ruling 15 (ad-hoc has no recorder; pin it as a known absence):** done, but the premise is false in the tree and I
  did not follow it literally. `ContentView.startSession` calls `attachAuditRecorder(... sessionID:
  AdHocAudit.logSessionID(storedID: storedSession?.id) ...)` for every connect, so an ad-hoc connect DOES get a recorder,
  logging under `AdHocAudit.sessionID` (M31, commit `ea1338e9`; the "Ad-hoc audit log" menu item reads it). The claims
  that said otherwise were stale since M31: `SessionTab.auditRecorder` ("never for an ad-hoc connect"),
  `attachAuditRecorder` ("Never called for an ad-hoc connect"), and the comment in `TeardownStage.swift`
  (`tab.auditRecorder` "is nil for an ad-hoc connect"). I corrected the first two in `c355dd63` (they name callers of
  code I was wiring) and did NOT touch `TeardownStage.swift`: its decision (a log line, not an `AuditEvent`) is yours,
  but one of its two reasons is wrong, so the decision should be re-read. The real nil, measured in code: the `onDelete`
  closure in `ContentView+Detail.swift` sets `tab.auditRecorder = nil` on purpose when the sidebar deletes a stored
  session under an open tab. The known-absence test is
  `withNoRecorderTheWriteStillGoesThroughAndNothingIsRecorded` (the write reaches the store, no failure shown,
  nothing recorded); its other half is `anAdHocConnectIsGivenARecorderUnderTheAdHocLogID` (source scan of
  `ContentView.swift` plus `AdHocAudit.logSessionID` both ways). Consequence for the plan's closeout question about
  auditing ad-hoc connections: the audit log already covers them; only the stale comments said otherwise.
  Residual edge: the item captures the recorder when the sheet opens, so a stored session deleted from another window
  while a bucket sheet is open would let that sheet recreate the deleted session's log file (the orphan `onDelete` is
  written to prevent). Not handled, not tested.

## 6. Not done / not verified (so far; final list at the end)

- No GUI, no app binary, no Docker rig, no network: everything ran against `FakeBucketSettings` and temp directories.
  Nothing was drawn, so the four new rows in the audit sheet have not been looked at.
- The claim "recorded before the read-back, so nothing after can lose it" is a design statement in comments; no test
  can fail it, because the fake's read-back never throws or cancels. Not verified.
- The audit sheet's filter facets (Transfers, File ops, Terminal, Connection) do not include the four kinds (they use
  `default:`); they show under All and Errors. No "Bucket settings" facet was added.
- No German/French/Polish wording review by a native reader; the four labels reuse the terms the catalogues already
  use for the same features ("Objektsperre", "Verrouillage d’objet", "Blokada obiektów").
- User documentation (`noix-docs`) not touched: the audit log is existing, user-visible behaviour, and four new row labels
  appear in it. That is a closeout-task item under the project's docs rule, not done here.
- `TeardownStage.swift`'s stale reasoning not touched (Ruling 15).

## 5b. Rulings 16 and 17 (arrived mid-run)

- **Ruling 16 (no history rewrite):** followed. `c355dd63` is not amended or rebased. The two wrong figures in its message
  ("69 test call sites and 40 sheet constructions") are corrected in a follow-up commit that quotes them verbatim (section 7).
- **Ruling 17 (does the pre-existing path have the same capture hole?):** answered by reading, NOT by running anything, and
  nothing was fixed. What I read, all at `HEAD` (`git grep -n "auditRecorder\|auditSink = " HEAD -- Sources/MacSCPAppKit`):
  - `ContentView.sendSnippet` (`ContentView.swift`, `let recorder = activeTab.auditRecorder`, then
    `terminal.send(bytes) { recorder?.recordAction(...) }`): captures the recorder BY VALUE when the snippet is sent and
    records in a completion closure. It does not re-read the tab and nothing releases it on delete. Same capture shape as
    the five sheets, over a window of one terminal send.
  - `ContentView+Lifecycle.swift` `attachAuditRecorder`: `tab.transferQueue.auditSink` and `tab.session?.remote.auditSink`
    are closures that capture `recorder` by value at connect time and live as long as the tab. These are the pre-existing
    long-lived holders, and `ContentView+Detail.swift` `onDelete` explicitly clears them (`tab.auditRecorder = nil`,
    `tab.transferQueue.auditSink = nil`, `tab.session?.remote.auditSink = nil`), with a comment naming exactly this hazard
    (the next event recreating `audit/<id>.json` as an unreachable orphan).
  - `TabTeardown.swift` clears the same three on teardown.
  So the answer is neither clean branch. The mechanism (capture by value, no re-read) is pre-existing, and the one-shot
  `sendSnippet` path has the same hole in principle with a window of milliseconds. But the pre-existing LONG-lived holders
  are released by an explicit step at the delete site, and the five sheets are long-lived holders (open for as long as the
  person leaves the sheet up) that `onDelete` does not know about. Task 12 therefore added five long-lived captures to a
  pattern whose long-lived members are all released on delete. Under your rule as written (the path "captures the same way"
  so do not fix, write it up) it goes to the closeout as a backlog row; I did not fix it. Reachability: a sheet is
  window-modal, so the delete has to come from another window's sidebar. Candidate fixes for whoever owns it, none tried:
  the sheet takes a closure that reads `tab.auditRecorder` at the write, or `onDelete` closes the tab's open bucket sheets.
  File and symbols for the row: `Sources/MacSCPAppKit/ContentView+Detail.swift` (`onDelete`), `ContentView+MenuActions.swift`
  (`handleConnectionAction`, the file-action arm), `ContentView.swift` (`*SheetItem.recorder`).

## 3. The green

Full `swift test`, no flags, on `d10d21c8` (the last commit that changes files; `ee0bbf0a` is message-only), output saved
to the scratchpad as `full2.txt`:

```
✔ Test run with 5085 tests in 408 suites passed after 24.738 seconds.
✘ Test "Varying only isRegex leaves the pixels unchanged" recorded an issue at ViewTestabilitySpike.swift:202:9: Expectation failed: off == on
✘ Test run with 2839 tests in 239 suites failed after 49.064 seconds with 1 issue.
```
The one failure is the known pre-existing `ViewTestabilitySpike` at `:202`. `swift test` prints two runs (5085 and 2839
tests); I did not establish which target each belongs to, only that all failures in both are that one test. A first full
run on `c355dd63`'s tree (before the two source scans and the test fix) gave the same shape: 5085 passed, 2837 with the
same single failure. Targeted: `--filter BucketSettingsAuditTests` 10 tests pass; `--filter
"AuditRecorderBucketSettingsTests"` 10 tests pass; `--filter SnippetAuditWiringGuardTests` 2 tests pass (19 cases of the guard).

## 4. The probes

Eleven probes, all through `scripts/mutation-probe` from the repository root on a committed, clean tree, each with the
script's own control run first (0 pre-existing failures in every control). The tree was verified clean after the last one
(`git status --porcelain` empty). Every one is recorded with its exact `--filter` and `--apply` in the commit message of
`ee0bbf0a` (`git log -1 --format=%B ee0bbf0a`), where `$1` in P7 is escaped as `\$1` so the line runs unedited in a shell;
filter `F` there is `BucketSettingsAuditTests`. Outcomes:

| probe | what is planted | file | control ran | outcome |
|---|---|---|---|---|
| P1 | versioning success not recorded | BucketVersioningSheet.swift | 10 | RED: eachOperationRecordsExactlyOneEventOfItsOwnKind |
| P2 | versioning refusal recorded as success | BucketVersioningSheet.swift | 10 | RED: aRefusedOperationRecordsTheFailureAndNotASuccess |
| P3 | create refusal not recorded | CreateBucketSheet.swift | 10 | RED: aRefusalsOwnWordsNeverReachTheTrail, aRefusedOperationRecordsTheFailureAndNotASuccess |
| P4 | CORS success records 0 rules | BucketCORSSheet.swift | 10 | **GREEN on 98ffbc7a**; fixed; RED on d10d21c8 (eachOperationRecordsExactlyOneEventOfItsOwnKind) |
| P5 | retention always recorded as GOVERNANCE | ObjectLockSheet.swift | 10 | RED: anObjectLockLineNamesWhichOfTheThreeOperationsItWas |
| P6 | legal hold recorded inverted | ObjectLockSheet.swift | 10 | **GREEN on 98ffbc7a**; fixed; RED on d10d21c8 (eachOperationRecordsExactlyOneEventOfItsOwnKind) |
| P7 | bucket-default refusal recorded as success | BucketObjectLockSheet.swift | 10 | RED: aRefusedOperationRecordsTheFailureAndNotASuccess |
| P8 | per-file dispatcher passes no recorder | ContentView+MenuActions.swift | 10 | RED: everySheetItemIsBuiltWithTheTabsRecorder |
| P9 | per-file sheet built with `recorder: nil` | ContentView+Sheets.swift | 10 | **GREEN on 98ffbc7a**; fixed; RED on d10d21c8 (everySheetIsBuiltWithItsItemsRecorder) |
| P10 | retention line drops its date | AuditRecorder.swift (Core) | 20 | RED: App anObjectLock... + Core aRetentionDateIsWrittenInUTC... + Core anObjectLock... |
| P11 | retention refusal not recorded | ObjectLockSheet.swift | 10 | RED: aRefusalsOwnWordsNeverReachTheTrail, aRefusedOperationRecordsTheFailureAndNotASuccess |

Three greens were real findings about my tests, fixed in `d10d21c8`: the table test only checked that a line named a bucket
(P4, P6), and the sheet scan found `ObjectLockSheet(` by substring inside `BucketObjectLockSheet(`, so it never looked at the
per-file sheet's call (P9). The first-run outputs are kept in the scratchpad as `P4-first.txt`, `P6-first.txt`,
`P9-first.txt`. Not probed: the other four dispatcher arms and four sheet builders individually (the scans loop over all
five; only the per-file one was planted), and the Core `recordBucketCreated`/`recordVersioningChanged`/`recordCORSChanged`
detail wording (pinned by exact-string Core tests that I did not mutate).

## 7. Commit-message corrections (Ruling 16)

`ee0bbf0a` (message only, `--allow-empty`) quotes `c355dd63`'s "69 test call sites and 40 sheet constructions" verbatim,
says both are wrong, gives 68 and 37, how each was wrong (69: a string literal in a source scan was rewritten by the same
script; 40: never counted), and the two commands that print them, re-run before committing:
`git show c355dd63 -- Tests | grep '^+' | grep -o ', recorder: nil)' | wc -l` prints 68;
`git show c355dd63 -- Tests | grep '^+' | grep -o 'recorder: nil,$' | wc -l` prints 37. `ee0bbf0a` was amended once, before
anything else sat on it, to escape `$1` in the P7 line.

Final "not done / not verified" additions to section 6: the capture edge of Ruling 17 is written up, not fixed; the Spike test
is not mine; the full suite was run once after the last code change (`d10d21c8`), and not again after the message-only commit.
