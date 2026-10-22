# Task 9 report: the CORS sheet, form and text

Status: DONE_WITH_CONCERNS (concerns below; none blocks).
Commit: `ca2df320` on top of BASE `302043de` (three working commits squashed locally, not pushed).
The full red/probe record is in that commit's message; this report does not restate it, it adds decisions and edges.

## What was built

- `Sources/MacSCPAppKit/BucketCORSSheet.swift` (new): `BucketCORSModel`, `BucketCORSSheet: BoundedView` (`.size(width: 620, height: 620)`, both panes `paneHeight = 320`), private `CORSFormPane`, `CORSRuleCard`, `CORSTextEditor` (NSTextView, substitutions off), private `ElementCensus`.
- Wiring, the way `1eb09f39` did it: `ConnectionActionRoute.cors = "s3.cors"` (own arm, own availability line), the arm in `handleConnectionAction`, `ContentView.BucketCORSSheetItem` + `corsSheetItem`, `.sheet(item: $corsSheetItem)` in `ContentView+Sheets.swift`.
- 31 `s3.cors.*` keys in en/de/fr/pl (`grep -c '^"s3[.]cors[.]'` on each file prints 31). German uses du; `GermanAddressFormTests` is green and a polite-form plant is red (P16).
- Tests: `BucketCORSSheetTests` (37), `ConnectionActionRouteTests` (new `corsNeedsTheCapabilityAndABucket`; presentation test rewritten), registry entries (5), floor 34 -> 35, `RigidControlScanTests` site table, `FakeBucketSettings` extended (cors/setCORS, mimics the store: `setCORS([])` reads back `nil`).

## Design decisions you may want to push back on

1. **Source of truth = the text; the lossy parse is handled by a census, not by `rules == parse(rawBody)`.** `BucketCORS.rules` alone cannot show that something was dropped. The model parses the text, writes the parsed rules back out with `S3SettingsXML.corsBody`, and compares the multiset of element names plus attribute names (xmlns excluded) of the two documents. Any element the rules have no place for, a second `ID`/`MaxAgeSeconds`, a nested element, a stray attribute or a rule inside a rule changes the census. This is App-local (`ElementCensus`), about 25 lines; I did not add Core API because the brief lists App files only. If you want it in Core next to `parseCORS`, it moves cleanly.
2. **A loaded configuration is shown as `rawBody` when it is lossy**, otherwise as a tidied document built from `rules`. `canSave` requires `isLossless`: saving the parsed rules would drop what the text holds, so nothing is saveable until the text stops saying it. `baselineWasLossless` makes removing such an element count as a change even though `rules == baseline`.
3. **The form is off for three reasons, not one**: unreadable text (key `s3.cors.formNeedsReadableText`), lossy text, a method outside the five, or a value over several lines (all three of the latter: `s3.cors.formCannotShowThis`). The brief fixes only the one key, and the sentence for it lists the categories rather than naming the exact element. If "names what it cannot show" should be sharper (the element name), that needs the census to keep names; say so.
4. **A method outside the five (FETCH) disables the form** as well as blocking save with `problem == .methodNotAllowed("FETCH")`. The form has five checkboxes and nowhere to put it.
5. **Fields hold exactly what was typed** (one `TextField` per entry, no trimming), because a derived binding that trims or drops blank lines makes it impossible to type a space or a newline. A blank/whitespace-only origin is a real value and fails `validate()` with `.noOrigin`, which the sheet names with the rule number.
6. **Saving zero rules is allowed** when the store has some: it calls `setCORS([])` (the clear), and the sheet says so before the click (`clearsAll`). With nothing stored and nothing typed, Save is disabled (not dirty).
7. **Failures are fixed sentences.** A `RemoteFSError.finding` says its own message, so a pre-send `corsRuleInvalid` reads "nothing was sent", not an unusable-answer sentence (test pins the two differ). Permission errors have their own line. No error `reason` is ever quoted (test plants a `KEY:SECRET@host` reason; the Bool is computed before `#expect`).
8. **After a write the sheet re-reads** and shows the store's answer; if the read-back fails the sent rules are taken as stored.
9. **Pane height is fixed (320).** The first implementation let the form scroll view size to its content and `BoundedViewLayoutGuardTests` correctly measured it as 1069 pt / 591 pt tall against a granted 560. The guard measures as if nothing scrolls, so a bounded view needs a bounded pane. Sheet is 620 tall; the tallest measured state is 579 (fr, "configuration the fields cannot show"), via `MACSCP_BOUND_FIGURES=1 swift test --filter BoundedViewFigureReportTests`.

## Red, stated as it was observed

- Before any production change: build stopped on `ConnectionActionRouteTests.swift` only (first line `ConnectionActionRouteTests.swift:92:39: error: type 'ConnectionActionRoute' has no member 'cors'`; 6 error lines in that file). **`BucketCORSSheetTests.swift` reported no error line, so I did not observe `cannot find 'BucketCORSModel'`, and no behavioural test of the model was seen red before the model existed.** I did not hand-revert files to force it (no `git checkout`). Model behaviour is instead covered by 18 mutation probes, each caught.
- Reds I did observe on the first implementation (first full `swift test`): `noViewNeedsMoreThanItsBoundGrantsInAnyLanguage` (8 issues, e.g. `needs 1069.15966796875 pt tall, granted 560.0 pt`) and `noRigidComponentIsHeldToAWidthFrame(component:)` for SegmentedChoice and CheckboxRow (2 issues, `BucketCORSSheet.swift` in `inspected`, absent from the table). Both fixed.

## Green

`swift test`, no flags, committed tree: Core 5074 passed; App 2639 run, exactly one failure, `ViewTestabilitySpike` "Varying only isRegex leaves the pixels unchanged" (`ViewTestabilitySpike.swift:202:9`), the one Task 8's commit records on its own base. I did not re-measure it against `302043de`. `swift build`, no flags, clean.

## Mutation probes

18 through `scripts/mutation-probe`, all RED (caught), control green each time, `git status --porcelain` empty before and after each; exact `--filter`/`--apply` strings are in the commit message (P1-P18). P1-P6 ran at `6455aef9`, P7-P18 at the following commit (both pre-squash). Notable: P5 (lossy baseline no longer a change) and P6 (`save()` guard) are each caught by one test only; P3 is caught by four.

## Corrections made in measurement-record files (old wording quoted verbatim in each)

- `BoundedViewCoverageTests.theScanFindsTheConformancesAtAll` doc comment: floor 34 -> 35; `grep -rhn -e '^ *struct [A-Za-z]* *: BoundedView {' Sources/MacSCPAppKit | wc -l` prints 35 under the session's grep and `/usr/bin/grep`.
- `RigidControlScanTests` Component doc comment: "(12 lines)", "(6)", "20 lines in all", "the counts below sum to 19" -> 13, 7, 22, 21 (the three `grep -rn '<X>[(]'` commands re-run under both greps). Site table gains `BucketCORSSheet.swift` for SegmentedChoice and CheckboxRow.
- `ConnectionActionRouteTests.theStateTheDispatcherSetsIsTheOneASheetIsPresentedFor`: it hard-coded one expected sheet (`BucketVersioningSheet`); now derived per arm from the item type the arm constructs, with each check bounded to its own `.sheet(` closure, plus a count check (one distinct state per route). Old lines quoted in the doc comment. A check loosened to pass for two sheets would have proved neither.

## Concerns

- **Not visually verified.** No test draws an `NSViewRepresentable`; the text editor's caret behaviour when the binding changes, and the look of the form, need the maintainer's eye. App not launched (as instructed). `theTextEditorSwitchesOffTheSubstitutionsThatBreakMarkup` pins the four substitution switches from source.
- **French/Polish/German translations are mine and unreviewed by a native speaker.** Parity (keys + specifiers, one specifier per string, order-sensitive) and du-form are machine-checked.
- **User docs.** CLAUDE.md requires user documentation with every user-visible feature (`/Users/noidee/_dev/noix-docs`, `src/content/docs/macscp/`). The brief gave this task no docs file, so I did not touch that repo; the plan's closeout task presumably owns it. Flagging so it is not forgotten.
- The census treats attribute names and element names but not text outside elements or comments/PIs (they carry no rule data). Namespaced element names with a prefix are not parsed by `parseCORS` at all (unreadable), so they never reach the census.
- `ViewTestabilitySpike` failure is pre-existing (see above), unrelated to this change.
