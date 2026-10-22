# Task 9 re-review, fix round 1

Scope: `b2631aa4` (the implementer's fix round) on `8d9d2c95` (the controller's docs commit), against `task-9-review.md` (reviewed head `ca2df320`). Worktree `/Users/noidee/macSCP/.claude/worktrees/diff-view`. Read: the re-review contract, the original review, the fix report, `review-ca2df320..b2631aa4.diff` (via `git diff` of each file), `CLAUDE.md`, and the final `BucketCORSSheet.swift` where the diff left it ambiguous.

`git status --porcelain` was empty before the first run and is empty after the last. Nothing was committed, pushed or amended. Two scratch test files were created untracked, run, and `rm`-ed (named under "What I ran"). No app or GUI binary was launched. `swift test` ran with no `--build-system` flag.

---

## Finding Verdicts

**I1. A successful save moved the user out of the Text pane: ADDRESSED.**
- Every `pane` assignment in `Sources` (`grep -rn '\.pane = \|selectPane' Sources`, and `grep -n 'pane = '` in the file): `BucketCORSSheet.swift:118` (`init(rules:)`), `:304` (inside `chooseOpeningPane()`), `:336` (`selectPane`). `adopt(_:)` assigns none.
- `adopt` has three callers: `init(loaded:)` (`:128`, followed by `chooseOpeningPane()` at `:129`), `read` (`:470`, followed by `chooseOpeningPane()` at `:471`), `save`'s read-back (`:496`, nothing follows). `chooseOpeningPane()` has exactly those two call sites. The `.task` in the view guards `read` with `if case .reading = model.load`, so a view re-appearing does not re-run `read` and re-pick the pane. A successful save and a refused save therefore both leave the pane alone, and a read still picks the opening pane.
- The three things the round claims tests for each exist: `aSuccessfulSaveLeavesTheChosenPaneAlone` (loops over text and fields, so the positive is built in), `aRefusedSaveLeavesTheChosenPaneAlone`, `aReadOpensOnThePaneThatCanShowTheConfiguration` (lossy to text, plain to form).
- Probes F1, F2, F3, F4: all RED, each caught by the test named for it (table below). F3 is the original line re-added at the end of `adopt` and is caught by `aSuccessfulSaveLeavesTheChosenPaneAlone`.
- Remark, not a finding against this item: `init(rules:)` (`:118`) still spells `pane = formIsAvailable ? .form : .text` inline instead of calling `chooseOpeningPane()`. It is an init and nothing has been chosen yet, so it is correct. But `chooseOpeningPane()`'s doc comment says "Called by the paths that open a sheet", and `init(rules:)` is a path that opens a sheet and does not call it (see New Breakage, Minor N3).

**Value-level census hole (`a&#13;b`): ADDRESSED.**
- The check is in production code: `read` computes `let valuesSurvive = (try? S3SettingsXML.parseCORS(canonical)) == rules` and returns `isLossless: theirs == ours && valuesSurvive` (`BucketCORSSheet.swift:189-192`). It is not only in a test.
- `a&#13;b` is covered by `aValueThatChangesOnTheWayBackIsNotLossless`. It asserts `reading.leftOut.isEmpty` (the census sees nothing), that the re-parse differs from the rules, `!reading.isLossless`, `!canSave`, and that the blocker is `valueChanges`. The positive control beside it is `aValueThatSurvivesTheRoundTripIsLossless` (`a&amp;b&#42;` is lossless and parses to `a&b*`).
- I ran a 16-document false-positive battery through the real `read` (canonical, reordered fields, interleaved same-name values, `007`, `+5`, CDATA, `&amp;`, `&#42;`, empty `ID`, padded `ID`, NBSP, `&#xE9;`, a combining accent, tab, double space, a foreign `xmlns`, empty configuration): **all 16 lossless, no leftOut.** The new round-trip check adds no false positive to those. `&#x2028;` and `&#x85;` are lossless to the round trip and switch the form off through the multi-line rule, as before. `&#xB;` is unreadable (invalid XML).
- Doc-comment correction: `read`'s doc quotes the withdrawn sentence "A document that holds anything the rules do not has a different count, in whatever order its fields come." The original, from `git show ca2df320:Sources/MacSCPAppKit/BucketCORSSheet.swift`, lines 142-143, reads the same words with a line break after "do not"; the quote joins them. Verbatim up to the rewrap, which owes no quote. The two other corrections in the file also quote verbatim: `adopt`'s `pane = formIsAvailable ? .form : .text` and `clearsTheConfiguration`'s `load == .ready && isReadable && rules.isEmpty && !baselineRules.isEmpty`.
- Probe F5 (drop `&& valuesSurvive`): RED, caught by `aValueThatChangesOnTheWayBackIsNotLossless` and `everyKeyTheSheetUsesIsOneTheCatalogueChecksCover`.

**M11. A lossy baseline parsing to zero rules cleared without the warning: ADDRESSED.**
- `clearsTheConfiguration` is now `load == .ready && isReadable && rules.isEmpty && (!baselineRules.isEmpty || !baselineWasLossless)` (`:460-463`); `hasNoConfiguration` requires `baselineWasLossless` (`:447-449`).
- I constructed the input and drove it through `read` and `save` against `FakeBucketSettings` (scratch test, since removed). Raw `<CORSConfiguration><Unknown>x</Unknown></CORSConfiguration>` with `rules: []`:
  - on open: `pane=text`, `clears=true`, `none=false`, `canSave=false`. The warning is shown from the start and `hasNoConfiguration` no longer claims there is none;
  - `save` before cleaning the text: `corsWrites.count == 0`;
  - after the text is set to `<CORSConfiguration/>`: `clears=true`, `none=false`, `canSave=true`, and `lines` contains `s3.cors.clearsAll`. The clear is reachable only with the warning on screen (the view renders `clearsAllLine` whenever `clearsTheConfiguration`, `:812`);
  - after that save: one write, and `clears=false`, `none=true` (the read-back is a lossless empty baseline).
- The unreadable baseline (raw `<<not xml`, rules `[]`) is the same flag: after replacing it with `<CORSConfiguration/>`, `clears=true` and `canSave=true`. No test pins that variant (see "What no probe pins").
- Probes F6 (drop the `!baselineWasLossless` clause) and F7 (drop `baselineWasLossless` from `hasNoConfiguration`): both RED, both caught by `aLossyDocumentWithNoRulesStillWarnsThatSavingClears`.

**M5. An expectation compared against a sentence the sheet never shows: ADDRESSED, with a note.**
- It now compares `model.saveFailure` with `BucketCORSModel.saveFailedLine.text`, which is what `message(for:applying: true)` returns for a non-finding error (`:513-514`). That string can occur on screen, so the expectation is no longer vacuous in the way the original was.
- Note: it remains logically implied by the line before it (`saveFailure == corsRuleInvalid.message`), since it can only fail if the two catalogue strings are equal. It is not probed and is no longer wrong. Not a finding.

**M7. The "Fields" segment stayed clickable while the form was off: ADDRESSED, by a substitution I judge sound.**
- `git diff ca2df320 b2631aa4 -- Sources/MacSCPAppKit/RigidControls.swift` prints nothing (0 lines), as the report says.
- The report's account of the failed first attempt is consistent with the tree: no `disabled:` parameter exists on `SegmentedChoice`, and the quoted red is in the commit message. I did not reproduce the failed attempt (it would mean planting it); I did check that the final guard reads the hosted view.
- Substitution on the merits. `hasAnotherPaneToChoose` is `Pane.allCases.contains { $0 != visiblePane && canSelect($0) }`, with `canSelect(t) = t == .text || formIsAvailable`.
  - Form off implies `canSelect(.form)` is false, and `visiblePane` is `.text` (either `pane == .text`, or `pane == .form` and the form is unavailable), so the candidate set is empty and the control is greyed. True in every form-off state.
  - Form on implies `.form` and `.text` are both selectable and only one is visible, so the control is enabled. Not greyed in any form-on state.
  - So the greying equals "form off" exactly. The only segment it additionally greys is the one that selects the pane already shown, a no-op either way. It is not a broader disable than the finding asked for in any state where a click could have done something. It also fixes the original problem completely, where a per-segment disable that the hosted control ignored would not have.
- The guard reads the hosted view: `thePaneControlIsGreyedWhileTheFormIsOff` walks `NSHostingView` subviews for an `NSSegmentedControl` whose segment label is the Fields label and returns `isEnabled`. The comparison is against `Bool?`, so a control that is never found fails both `== true` and `== false`. Positives beside the negative: form on gives `true`, and form available with the user in the text pane gives `true`.
- Probe F8 (`.disabled(false)`): RED, caught by `thePaneControlIsGreyedWhileTheFormIsOff`.
- Not checked, and not checkable here: how a greyed control that shows "Text" selected looks. The report discloses it; the app was not launched.

**The form-off sentence names the offender: ADDRESSED.**
- Three keys: `s3.cors.formCannotShowThis` (`%@` is up to three element/attribute names), `s3.cors.formCannotShowMethod %@`, `s3.cors.formCannotShowValue %lld`. `FormBlock` carries the offender; `formUnavailableSentence` fills it in.
- Catalogue (script `spec.py` in the scratchpad, run with `python3 -I`): 32 `s3.cors.*` keys in each of en, de, fr, pl; key sets identical; **0 specifier-parity problems** across all 128 lines (value specifiers equal English's, and equal the key's where the key has a suffix); the three new keys carry exactly one `%@`, `%@`, `%lld` in all four locales. German has none of `Sie/Ihr/Ihre/Ihren/Ihnen/Ihrem/Ihrer` in any `s3.cors` value; the imperatives are `Entferne`, `Verwende`, `Bearbeite`. The removed keys `s3.cors.problem.method` and `s3.cors.problem.dropsSomething` have no remaining reference in `Sources`, `Tests` or `docs`. Strings live in `CatalogueLine`s, the project's own pattern; nothing hardcoded in a view.
- Behaviour I ran: a document with five unknown names (one 200 characters long, one attribute) gives `leftOut == ["A1","B2","C3","D4","D4@x","ZZZ…"]` and the sentence "…(A1, B2, C3, …), so the fields are off and the text cannot be saved as it is…" (cap of three plus the ellipsis, sorted); a multi-line `ID` in rule 1 gives "A value in rule 1 runs over more than one line…"; method `FETCH` gives the method sentence.
- **Payload check.** The element and attribute names reach exactly one place: `Text(sentence)` in `notice(...)`, a `String` argument, so verbatim (no Markdown, no `LocalizedStringKey`). They are formatted into the sentence as *arguments* of `String(format:)`, never as the template; a method named `%@%lld%s` rendered literally. They reach no log (there is none in the file: no `Logger`, `print` or `os_log`), no `reason:` string, and no error value. `lines` (which tests and the catalogue scan read) returns the unfilled templates. In the tests, the assertions that touch a name are on test constants (`"Unknown"`, `"Extra1"`, the `x` run), the multi-line test computes `let names = sentence.contains(...)` before `#expect`, and no `#expect` embeds a store-supplied value. XML itself limits what a name can carry (no whitespace, quotes, or bidi controls).
- **The method name is not clipped, which is the one place the "bounded sentence" reasoning stops short.** See New Breakage N1.
- Probes F9, F10, F11, F12, F13: all RED (table below). Two parts of the new behaviour are not pinned by any test or probe: the 40-character figure and the ", …" suffix (see "What no probe pins").

---

## New Breakage in the Fix Diff

No new Critical or Important problem.

**N1. Minor. The method name in `s3.cors.formCannotShowMethod %@` is not clipped, though the element names beside it are.**
`BucketCORSSheet.swift:362` (`case .method(let method)?: return String(format: line.text, method)`) against `listed(_:)` (`:393-396`), which clips names to 40 characters "because the sheet's height was measured against a sentence of bounded length". The same reason applies to the method. Measured with the suite's own instrument (`SheetBound.$isSuspendedForMeasurement` + `LayoutMeasure.minimumHeight` at the granted width, scratch test, since removed): a 600-character `AllowedMethod` gives **653 pt against the 620 pt bound** in all four locales; `FETCH` gives 523 (en) / 536 (de, fr, pl). Three 40-character `W` names give 575; three 40-character CJK names give 562. The unclipped method already existed in `ca2df320` (the old `s3.cors.problem.method %@` blocker was unclipped too), so this round did not introduce the exposure; it moved the sentence and clipped its neighbour. Reaching it needs a document with a method name of several hundred characters, typed or sent by the store; the effect is the user's own sheet overflowing its bound, with Save disabled throughout (`canSave` is false while a method is outside the five). Fix is `String($0.prefix(40))` on the method, with one assertion beside `aListOfNamesIsShortAndEachNameIsClipped`.

**N2. Minor. The bound is measured for one of the new sentences, not for the states the round created.**
`BoundedViewRegistry.swift` is untouched by the round; "a CORS configuration the fields cannot show" (one short name) is the only form-off state registered. The method, multi-line value, carriage-return and unreadable states are not, and neither is the worst realistic names state. I measured them (scratch test): method `FETCH` 523/536, value 523, carriage return 540, unreadable 557, three wide names 575. All fit under 620 with at least 45 pt to spare; no sentence reaches the bound except the unclipped method of N1. This is the original M9 (deferred and not mine), widened by the sentences the round added. Recorded so the final review has the figures.

**N3. Minor. Two comment slips in the fix.**
(a) The type header (`BucketCORSSheet.swift:19-20`) now has the new sentence "Two questions make one answer…" joined onto the end of the preceding line, so one doc line is 128 characters where its neighbours are 60-80, and "The spec (section 6.3) calls this the honest edge:" now trails it mid-line. A rewrap was missed. (b) `chooseOpeningPane()`'s doc comment says it is "Called by the paths that open a sheet", but `init(rules:)` (`:118`) is a path that opens a sheet and repeats `pane = formIsAvailable ? .form : .text` inline. The expression exists twice and can drift. CLAUDE.md's "comments that describe other code" rule is why this is worth a line.

**Fix round's layout figure: reproduced.**
`MACSCP_BOUND_FIGURES=1 swift test --filter BoundedViewFigureReportTests` prints the CORS entries as `tall` 510 (fields), 510 (text), **536** (cannot show), 523 (no method), 130 (could not be read), each identical in de/en/fr/pl, of 620. 536 is the tallest registered state, as the commit says. The "before" figure (579 fr / 553 en) is not reproduced: it would need the old tree, and I may not check one out. The new 536 is first-hand. The 8d9d2c95 docs commit does not contradict the round or the tree: its claim that Task 9 "closes the user-visible half" of `a&#13;b` is true at `b2631aa4`.

---

## What I ran

**The 13 probes**, extracted from `git log -1 --format=%B b2631aa4` and run unrepaired through `scripts/mutation-probe`, one at a time, `git status --porcelain` empty after each. All reproduce RED; control 51 tests, 0 pre-existing failures each time.

| | Plant | Result | Caught by |
|---|---|---|---|
| F1 | save re-chooses the pane | RED | `aSuccessfulSaveLeavesTheChosenPaneAlone` |
| F2 | refused save re-chooses the pane | RED | `aRefusedSaveLeavesTheChosenPaneAlone` |
| F3 | `adopt` chooses the pane (the original line) | RED | `aSuccessfulSaveLeavesTheChosenPaneAlone` |
| F4 | `read` no longer chooses | RED | `aReadOpensOnThePaneThatCanShowTheConfiguration` |
| F5 | value round trip removed | RED | `aValueThatChangesOnTheWayBackIsNotLossless`, `everyKeyTheSheetUsesIsOneTheCatalogueChecksCover` |
| F6 | lossy baseline not a configuration | RED | `aLossyDocumentWithNoRulesStillWarnsThatSavingClears` |
| F7 | `hasNoConfiguration` ignores lossy baseline | RED | `aLossyDocumentWithNoRulesStillWarnsThatSavingClears` |
| F8 | pane control never greyed | RED | `thePaneControlIsGreyedWhileTheFormIsOff` |
| F9 | census names dropped | RED | `aConfigurationTheFormCannotShowDisablesTheForm`, `aLoadedConfigurationWithMoreThanItsRulesShowsTheRawBodyAndNoForm`, `anAttributeIsNamedWithItsElement`, `everyKeyTheSheetUsesIsOneTheCatalogueChecksCover`, `theLossySentenceNamesTheElementsLeftOut` |
| F10 | method gets a second red sentence | RED | `aCauseIsNotSaidTwice` |
| F11 | method sentence drops the name | RED | `theMethodSentenceNamesTheMethod` |
| F12 | method key removed from `de` | RED | `everyLineResolvesInAllFourLocales` |
| F13 | cap raised to six | RED | `aListOfNamesIsShortAndEachNameIsClipped` |

**Two probes of my own** for behaviour the round added, through the same harness, against the committed tree:
- `prefix(40)` to `prefix(55)`: **GREEN, 51 tests, none noticed.**
- the `", …"` suffix removed: **GREEN, 51 tests, none noticed.**

(A third attempt at planting the `.unstable` branch had a malformed plant and `scripts/mutation-probe` reported `BUILD FAILED`, "this probe measured NOTHING". It is void and I do not count it.)

**Tests.** Focused: `swift test --filter BucketCORSSheetTests --filter ConnectionActionRouteTests --filter LocalizationParityTests --filter GermanAddressFormTests --filter BoundedView` gave 84 tests in 8 suites, all passed. Full `swift test`, no flags, on the committed tree: Core 5074 tests in 407 suites passed; App 2653 tests in 235 suites with **exactly one failure**, `ViewTestabilitySpike.swift:202:9`, "Varying only isRegex leaves the pixels unchanged", the known pre-existing red. This matches the report's figures.

**Scratch tests, created untracked, run, deleted** (`Tests/macSCPAppKitTests/ScratchReReview.swift`, `ScratchHeights.swift`): the 16-document battery, the unstable-value inputs, the names/format-injection/mixed-cause cases, the M11 flow through `read` and `save`, and the height measurements. A Python script in the scratchpad (outside the repo) checked the catalogue.

---

## The round's disclosure about the red, weighed

The report says that before the production change the only red observed was the failed first M7 attempt, and that the tests for I1, the value hole, M11 and the sentences were written in the same pass as the code and so are not claimed seen red first.

That is stated honestly and matches the commit message. Weighed on substance: the 13 probes cover what a red-first test would have, for the six items. Each item has at least one probe that restores or approximates the defect, and F3 restores the original I1 defect exactly. I take the report at its word that there was no earlier red, because the probes show the tests are sensitive, which is the property a red-first run exists to establish.

Behaviour that neither a red nor any of the 13 probes pins (two I measured green, the rest are inspection):
1. **The 40-character clip.** `aListOfNamesIsShortAndEachNameIsClipped` asserts `clipped.count < 60`, so a clip anywhere from 1 to about 55 passes. Measured GREEN at 55.
2. **The overflow marker.** Nothing asserts the ", …" after three names. Measured GREEN with it removed.
3. **The unreadable-baseline clear** (stored body not parseable, then replaced by an empty configuration): same flag as F6 but no test builds that input. I ran it and it behaves correctly.
4. **`FormBlock.unstable`.** Unreachable from the inputs I tried (`&#13;` becomes a multi-line value first; `&#xB;` is unreadable). Its sentence is the same one as `valueChanges`. No test or probe reaches the branch, and the report calls it unreachable.
5. **Precedence among `FormBlock` causes** (unreadable, left-out, first unshowable in document order). Only single-cause documents are tested. I ran one mixed document (method `FETCH` in rule 1, carriage return in rule 2): form block is `.method("FETCH")`, `blockerLine` is nil, `canSave` is false. The method sentence then says nothing about the save being blocked, only to fix the method. After the fix the value cause surfaces with its blocker. Not wrong, not tested.
6. **The method name's length** (N1).
7. **M5's second expectation** is implied by the first.

---

## Out-of-Scope Observations

None beyond N1 and N2, which are in or beside the diff. M2, M4, M6, M8, M9, M10 and moving `ElementCensus` to Core were not examined, as instructed.

---

## Verdict

**Fix round:** All six findings addressed. **No new Critical or Important problem.** Three Minor notes (N1 unclipped method name, N2 unregistered new sentence states, N3 two comment slips) and two unpinned figures (the 40-character clip and the ", …" marker) for the controller to ledger for the final review.
