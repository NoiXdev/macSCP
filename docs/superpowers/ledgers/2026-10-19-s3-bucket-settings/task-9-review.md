# Task 9 review — the CORS sheet, form and text

Reviewed: `ca2df320` on BASE `302043de`, from the worktree
`/Users/noidee/macSCP/.claude/worktrees/diff-view`. Read: the task-reviewer
rubric, `task-9-brief.md`, `task-9-report.md`, the review package
`review-302043de..ca2df320.diff` (2345 lines, read in full), the worktree
`CLAUDE.md`, design §6.3 (and §7, for the refusal path),
`Sources/macSCPCore/RemoteFS/S3BucketSettings.swift:97-104`, and — for the
named risks below — `Sources/macSCPCore/S3/S3SettingsXML.swift` (`parseCORS`,
`corsBody`, `CORSDelegate`), `Sources/macSCPCore/S3/S3XMLText.swift`,
`CORSRule.validate()`, `BoundedViewLayoutGuardTests.swift`,
`BoundedViewRegistry.swift`, `task-8-review.md`/`task-8-report.md`.

`git status --porcelain` was empty before the first probe and is empty after
the last. Nothing was committed, pushed, amended, or edited in `Sources/` or
`docs/`. One scratch test file was created untracked, run, and `rm`-ed (named
under "What I ran" below); the tree was verified clean before the mutation
probes began.

---

## Spec Compliance

**✅ Spec compliant**, with one ⚠️ that the dispatch reserves to the
maintainer (see "Two placement judgments").

File-by-file against the brief's list:

| Brief | Diff | |
|---|---|---|
| Create `Sources/MacSCPAppKit/BucketCORSSheet.swift` | +895 | ✅ |
| Modify `ConnectionActionRoute.swift` | `case cors = "s3.cors"` + its own availability arm | ✅ |
| Modify `ContentView+MenuActions.swift` | `case .cors:` arm | ✅ |
| Modify `ContentView.swift` | `BucketCORSSheetItem` + `@State var corsSheetItem` | ✅ |
| Modify `ContentView+Sheets.swift` | `.sheet(item: $corsSheetItem)` | ✅ |
| Test `BucketCORSSheetTests.swift` | +585, 37 tests | ✅ |
| Test `BoundedViewRegistry.swift` | 5 CORS entries + `corsRules` fixture | ✅ |
| (brief) `BoundedViewCoverageTests` floor raised | 34 → 35 | ✅ |

The brief's three Step-1 tests are all present, with the exact assertions the
brief spells, including `formUnavailableReasonKey == "s3.cors.formCannotShowThis"`.

Step 3's requirements are met: `SegmentedChoice` from `RigidControls.swift`
(`BucketCORSSheet.swift`, the `editor` property); editing either pane rewrites
the other (`commit` → `source` → `reanalyze`, and `text`'s setter →
`reanalyze`); the text is the source of truth (`rules` is always
`parseCORS(source)`); the form switches itself off when the text holds what it
cannot represent (`formIsAvailable`).

**Nothing extra.** The files beyond the brief's list are all consequences the
project's own guards force: the four `Localizable.strings` catalogues (house
rule), `ConnectionActionRouteTests` (the brief's wiring paragraph),
`RigidControlScanTests`' permitted-site table (the rigid-control guard went red
without it), `FakeBucketSettings` (`cors`/`setCORS` previously threw). No
unrequested feature, no speculative abstraction.

**⚠️ Cannot settle from the diff alone — §6.3's "names what it cannot show".**
The design says the form "disables itself and names what it cannot show". The
shipped sentence names three *categories* in a disjunction, not the offending
element, method, or value. The brief fixed a single key
(`s3.cors.formCannotShowThis`), so the implementer built what the brief
specified and raised the gap itself (its concern 8). Per the dispatch this is a
maintainer ruling, not a finding; my recommendation is below.

---

## Strengths

- **The `ElementCensus` mechanism is better than its own description.** The
  report and the commit message sell it as "comparing element and attribute
  counts", which reads like a heuristic. Read against `CORSDelegate` it is a
  structural statement: see the verdict section — I could not construct a false
  positive in 28 inputs, and the only census-invisible losses are things XML
  and S3 do not carry either.
- **The honest-edge chain is complete and each link is pinned.** `isLossless`
  → `canSave` → `baselineWasLossless` (so tidying a lossy document is a change
  to save) → `adopt` showing `rawBody` rather than a tidied document. P5 and P6
  are each caught by exactly one test, and the report says so rather than
  rounding up.
- **`read`'s failure modes are distinguished properly.** `parseCORS` throwing →
  `isReadable: false, isLossless: false`; `corsBody` or either census failing →
  rules kept but `isLossless: false`. A conservative fallback in both, so no
  path reaches "saveable" by accident.
- **The leak discipline is right on both exits.** `aFailureNeverQuotesTheReasonItWasGiven`
  keeps the planted endpoint in `let planted`, computes `quoted` before the
  expectation, and the one expectation that could print a string
  (`#expect(!shown.isEmpty)`) can only fail when the string is empty. No
  expectation anywhere in the new test file embeds a payload. `message(for:)`
  routes `.finding` to `finding.message` (Core guarantees a finding carries no
  foreign text) and everything else to a fixed catalogue sentence.
- **The `ConnectionActionRouteTests` rewrite answers Task 8's review I6
  exactly** ("bounding `rest` to the closure … would make it say what it
  means") and adds two positives the old test did not have: one assignment per
  route, and distinct states. I re-ran Task 8's P12 and a plant of my own
  against it; both red (below).
- **The fixed pane height is a fix, not a silencing.** Both panes scroll — the
  form is a `ScrollView`, the text pane an `NSScrollView` — so 320 pt bounds the
  viewport, not the content. P15 (320 → 700) is red, so the figure is pinned.
- **Every committed figure reproduces.** Four counts, two correction records,
  all verbatim (below).
- **Catalogue coverage is total, not sampled.** `everyLine()` builds nine model
  states so that all 31 lines are reached, and both
  `everyLineResolvesInAllFourLocales` and `theEnglishCatalogueSaysTheDefault`
  loop them over four locales.
- **`FakeBucketSettings` keeps the store's asymmetry and documents why**, so a
  sheet test cannot pass against a fake that is kinder than S3.

---

## The `ElementCensus` mechanism — verdict

**It is the right tool for the structural half of the question, and it is not a
near-miss. It does not cover the value half, which one line would close.**

### Why it is stronger than a count

`CORSDelegate` produces each value from exactly one element: an origin from one
depth-3 `AllowedOrigin` inside a depth-1 `CORSRule`, a rule from one depth-1
`CORSRule`, an `ID`/`MaxAgeSeconds` from the last such element in its rule.
So there is an **injective map** from every element `corsBody` writes back to a
distinct element of the original document, hence `census(ours) ⊆
census(theirs)` for every input. Equality therefore holds **iff that map is
onto** — iff every element in the document was consumed. That is not a proxy
for "nothing was dropped at the element level"; it is that property. An extra
element, a foreign name, a second `ID`, an element at the wrong depth, an
element nested inside a value, an attribute: each adds to `theirs` and nothing
can compensate it in `ours`.

The three compensation attempts the dispatch asks about all fail to defeat it
for that reason, and I ran them rather than only arguing them.

### The inputs I constructed and what happened

Run through the real mechanism (`BucketCORSModel.read`, `formCanShow`, and
`parseCORS(corsBody(rules))`) from a scratch test; `lossless` is
`Reading.isLossless`.

**Something dropped, counts differ (caught — the intended behaviour):**

| Input | Result |
|---|---|
| `<ID>a</ID><ID>b</ID>` (duplicate single-valued field) | lossless=false, id kept = `b` |
| `<MaxAgeSeconds>1</…><MaxAgeSeconds>2</…>` | lossless=false, kept = 2 |
| `<AllowedOrigin>a<ID>b</ID></AllowedOrigin>` (known element nested in a value) | lossless=false, **origin became `""`** |
| the same, with the rule also carrying `<ID>r</ID>` (compensation attempt) | lossless=false |
| `<AllowedOrigin>a<AllowedMethod>GET</AllowedMethod></AllowedOrigin>` (nested list name, outer level short one) | lossless=false |
| `<MaxAgeSeconds>5</…>` placed as a child of the root, not of a rule | lossless=false |
| `<CORSRule>…</CORSRule><AllowedHeader><AllowedOrigin>x</AllowedOrigin></AllowedHeader>` (stray after the rules, exercising the parser's never-reset `inRule`) | lossless=false |
| `<AllowedOrigin kind="x">` (attribute on a field) | lossless=false |
| `<Extra/>` beside the rules | lossless=false |
| a rule inside a rule | lossless=false |

**Nothing dropped, counts equal (no false positive):**
the canonical document; differently-named siblings in a swapped order;
same-name values interleaved with another name (`a`,`b` order preserved);
a foreign `xmlns` URI; an unused `xmlns:a` on a field; `<MaxAgeSeconds> 007 </…>`
and `+5`; CDATA; `&amp;`; `&#42;`; `<ID></ID>`; `<CORSConfiguration></CORSConfiguration>`;
a pretty-printed document with whitespace-wrapped values; two ordinary rules.
**No input produced a needless form switch-off.**

**Something dropped, counts equal (the gap):**

1. `<AllowedOrigin>a&#13;b</AllowedOrigin>` — lossless=**true**, and the
   round-trip is **not stable**: the rules hold `a\rb`, `corsBody` writes the CR
   literally, and re-parsing that body yields `a\nb`. So the sheet calls the
   document lossless, allows the save, and the store reads back a different
   value. Measured: `ROUND|S …|lossless=true|stable=false|first=["a\rb"]|second=["a\nb"]`.
2. Comments, processing instructions, the `xmlns` URI, and unused prefix
   declarations are census-invisible and silently rewritten on save. The report
   discloses this. It costs nothing in practice: S3 re-serializes a CORS
   configuration, so none of these survives a `PUT` whoever sends it.

(1) is the only demonstrated hole, and it is a **value**-level loss, which is a
different question from the structural one the census answers. Closing it is one
line in `read`: `parseCORS(canonical) == rules` beside the census comparison.
That also removes the need to reason about which text normalizations the parser
performs.

**So: the right tool, used correctly, with its claim one notch broader than its
reach.** The doc comment says the model "asks the question the parse cannot
answer for itself: does the text say anything the rules do not?" — the census
answers that for elements and attributes, not for the text inside them.
CLAUDE.md's "a scan that keeps buying one spelling" warning does not bite here,
because the census is not matching spellings: it is counting consumption, and
the counting is exhaustive by construction. It earns the structural boundary
it stands in for.

---

## What I ran

### The 18 probes, unrepaired, from the commit message

Extracted from `git log -1 --format=%B ca2df320`, run verbatim from the
worktree root through `scripts/mutation-probe`. **All 18 reproduce RED
(caught).** `git status --porcelain` empty before the first and after the last,
and after each (the harness reverts index-safely).

| | Control ran | Result | Caught by |
|---|---|---|---|
| P1 | 37, 0 pre-existing | RED | 10 tests, incl. `aConfigurationTheFormCannotShowDisablesTheForm` (report claimed 8) |
| P2 | 37 | RED | multiple |
| P3 | 37 | RED | multiple |
| P4 | 37 | RED | multiple |
| P5 | 37 | RED | `removingWhatTheRulesCouldNotHoldIsAChangeToSave` (one test, as reported) |
| P6 | 37 | RED | `aStateThatCannotBeSavedSendsNothing` (one test, as reported) |
| P7 | 37 | RED | `savingWritesTheRulesOnceToTheNamedBucketAndShowsTheStoresAnswer` |
| P8 | 37 | RED | `aFailureNeverQuotesTheReasonItWasGiven` |
| P9 | 37 | RED | `theFormIsNeverTheVisiblePaneWhileItIsUnavailable` |
| P10 | 11 | RED | `theStateTheDispatcherSetsIsTheOneASheetIsPresentedFor` |
| P11 | 11 | RED | same |
| P12 | 11 | RED | `corsNeedsTheCapabilityAndABucket` |
| P13 | 37 | RED | `everyLineResolvesInAllFourLocales` |
| P14 | 37 | RED | `theTextEditorSwitchesOffTheSubstitutionsThatBreakMarkup` |
| P15 | 9 | RED | `noViewNeedsMoreThanItsBoundGrantsInAnyLanguage` |
| P16 | 5 | RED | `noGermanStringAddressesTheUserInThePoliteForm(relativePath:)` |
| P17 | 37 | RED | `aMethodTheFormHasNoBoxForDisablesTheForm` |
| P18 | 37 | RED | `theFieldsAreNotEditedAndNotSwitchedToWhileTheyAreOff` |

Every `--apply` ran as committed; none needed repair. One reproduction note,
not a discrepancy: the commit message records control = 36 for P1–P6 and 37 for
the rest, because P1–P6 ran on the pre-squash tree before the 37th test was
added. On the committed tree every `BucketCORSSheetTests` control is 37.

P16 is the polite-form plant the report claims went red; re-run above, red,
caught by Core's `GermanAddressFormTests`.

### Task 8's P12 against the rewritten test

Plant (the versioning equivalent of this task's P10): delete the
`.sheet(item: $versioningSheetItem) { … }` block from
`ContentView+Sheets.swift`.

```
── control: 11 test(s) ran, 0 pre-existing failures
RESULT: RED — caught by ConnectionActionRouteTests/theStateTheDispatcherSetsIsTheOneASheetIsPresentedFor()
```

**Still caught. The rewrite did not weaken the property Task 8's review relied
on.** I added one plant of my own, for the hole the bounding is supposed to
close — make the `$corsSheetItem` closure build `BucketVersioningSheet(`
instead of `BucketCORSSheet(`, which the old unbounded `rest.contains(built)`
would have accepted:

```
RESULT: RED — caught by theStateTheDispatcherSetsIsTheOneASheetIsPresentedFor()
```

### The layout guard's fix, and a state the registry does not hold

The fix is a fix: both panes scroll, so 320 pt bounds the viewport. Nothing is
clipped. P15 pins the figure.

The registry's five states do not include the one combination that puts the
longest notice and a refused save on screen together (form off because a value
runs over several lines — which keeps `isLossless` true and `problem` nil, so
the save is offered — plus a `saveFailure`). I measured it myself with the
suite's own instrument (`SheetBound.$isSuspendedForMeasurement` +
`LayoutMeasure.minimumHeight`, at `BucketCORSSheet.bound.grantedWidth`):

```
en 553.0   de 553.0   fr 566.0   pl 553.0      granted 620.0
```

It fits, with 54 pt to spare in the worst language. No finding against the
bound; see Minor 9 for the registry gap.

### Figures and correction records

Verbatim check against `git show 302043de:<path>` — all four quoted strings
present at BASE, exactly as quoted:

- `BoundedViewCoverageTests.swift`: "The floor is 34 on 2026-10-20" (:104),
  "(which prints 34;" (:106), "raise it when a thirty-fifth view lands" (:109).
- `RigidControlScanTests.swift`: "(12 lines)" (:371), "(6)" (:372),
  "20 lines in all" (:374), "the counts below sum to 19" (:375).

New counts, re-run under the session's `grep` and `/usr/bin/grep`:

```
grep -rhn -e '^ *struct [A-Za-z]* *: BoundedView {' Sources/MacSCPAppKit | wc -l   → 35  / 35
grep -rn 'SegmentedChoice[(]' Sources/MacSCPAppKit | wc -l                          → 13  / 13
grep -rn 'RadioChoice[(]' Sources/MacSCPAppKit | wc -l                              →  2  /  2
grep -rn 'CheckboxRow[(]' Sources/MacSCPAppKit | wc -l                              →  7  /  7
```

13 + 2 + 7 = 22 ("22 lines in all" ✓). The site tables sum to 13 + 2 + 6 = 21
("the counts below sum to 21" ✓), and the one difference is still the single
`CheckboxRow[(]` line in `RigidControls.swift` (confirmed: exactly one of the
seven matches is in that file). The `declared.count >= 35` floor matches the
command. Every figure reproduces from the command committed beside it.

### Localization

31 `s3.cors.*` keys in each of `en`, `de`, `fr`, `pl`; the key sets are
identical across all four (`diff` of the sorted key lists: empty for de, fr,
pl against en). Specifier parity checked per line over all 124 lines (key
specifiers vs value specifiers, in order): **0 problems**, 0 unparsed lines.
No polite-form pronoun in the new German block (`Sie`/`Ihr`/`Ihre`/`Ihren`:
none); the imperatives are `Füge`, `Bearbeite`, `Entferne`, `Verwende`, and the
possessive is `Dein`. Nothing is hardcoded in the sheet: every display string
goes through a `CatalogueLine` or `L10n.string`, and
`everyKeyTheSheetUsesIsOneTheCatalogueChecksCover` reads the file back for the
keys. The HTTP method names in the checkbox row are protocol tokens, correctly
not catalogued.

### `setCORS([])` and the store's asymmetry

- The model sends the empty list (`let sent = rules`; `settings.setCORS(sent,
  ofBucket:)`), and Core's `setCORS` documents the empty list as the clear
  (`DELETE ?cors`, idempotent) — `S3BucketSettings.swift`, "An empty list
  clears the configuration". So the clear is what happens; the model does not
  build an empty body anywhere.
- The sheet says so **before** the click: `clearsTheConfiguration` is true
  whenever `rules.isEmpty && !baselineRules.isEmpty`, and `editor` renders
  `clearsAllLine` ("Saving without any rules removes this bucket's CORS
  configuration.") in the notice stack above the buttons.
  `savingWithNoRulesClearsTheConfiguration` asserts the flag before `save`.
- `FakeBucketSettings.setCORS` keeps the asymmetry: `rules.isEmpty ? nil :
  BucketCORS(...)`, documented in the type's header, and the test then asserts
  `model.hasNoConfiguration` after the save — i.e. the read-back was `nil`, not
  zero rules.

### The pre-existing red

`swift test --filter ViewTestabilitySpike` at HEAD: `✘ "Varying only isRegex
leaves the pixels unchanged" … at ViewTestabilitySpike.swift:202:9`, 1 issue of
7 tests. The file is untouched by this diff and the test concerns search-field
pixels, nothing the CORS sheet reaches. Consistent with Task 8's commit record.
Set aside, as instructed.

### The source-level substitution test, as a stand-in

`theTextEditorSwitchesOffTheSubstitutionsThatBreakMarkup` reads
`SourceCorpus.code(of:)` (comments *and* string literals blanked, so it cannot
be satisfied by the doc comment that names the same four properties) and
requires `"<property> = false"` for the four substitutions, with
`source.contains("NSTextView")` as its positive. **Adequate for what it
claims** — that the four switches are set — and P14 proves it sensitive. It is
not and does not claim to be evidence about the caret, the undo stack, or the
accessibility label reaching the real view; `updateNSView`'s guarded
assignment and `setAccessibilityLabel` are unverified behaviourally, and the
report says so.

### The TDD gap

Confirmed as disclosed: no behavioural model test was observed red before the
model existed, and `cannot find 'BucketCORSModel'` was never seen. Judged on
substance, the 18 probes cover the model's decision surface closely —
`isLossless`, `validate`, all three `canSave` terms the probes touch, the save
guard, the read-back, the failure sentence, `visiblePane`, `selectPane`, the
method half of `formCanShow`, and the catalogue. What **neither a red nor a
probe pins**, and what a reader should know is unmeasured:

1. **Pane continuity across a save** — nothing pins it, and it is broken (see
   Important 1). This is the CLAUDE.md pattern exactly: the probe battery tests
   the places the author enumerated.
2. `document(for:)`'s pretty-printing. The only tests on it assert that it
   re-parses to the same rules, which the unformatted body also does, so
   deleting every `replacingOccurrences` line would stay green.
3. `isSaving` as a gate. Asserted incidentally (`#expect(!model.isSaving)`),
   never probed, and the `.disabled(model.isSaving)` on the pane is unpinned.
4. The one-line half of `formCanShow` (ids, origins, headers) — covered by
   `aValueOverSeveralLinesDisablesTheForm`, but not probed; P17 only removes
   the method check.

A red-first model test would not have caught (1) either, so the gap is a
process miss rather than the cause of the defect. Worth the controller's note
for Task 10's ordering: writing the brief's three tests *alone* in Step 1
produces the predicted red, which is the same observation Task 8's review made.

---

## Issues

### Critical (Must Fix)

None.

### Important (Should Fix)

**I1. A successful save throws the user out of the Text pane.**
`Sources/MacSCPAppKit/BucketCORSSheet.swift`, `adopt(_:)`'s last line —
`pane = formIsAvailable ? .form : .text` — and `save(bucket:via:)`, which calls
`adopt` on the read-back. Measured:

```
PANE|before-save|pane=text|visible=text|canSave=true
PANE|after-save |pane=form|visible=form|failure=nil
PANE2|before-save|pane=text|canSave=true      (loaded by read(), edited, saved)
PANE2|after-save |pane=form
PANE3|after-failed-save|pane=text              (a failed save leaves it alone)
```

So: open the sheet, switch to Text, edit the document, press Save — and the
sheet silently flips back to Fields. A user working in the text pane is moved
out of it on every successful save, and the pane they were editing in is the
sheet's headline interaction. It is incorrect behaviour rather than polish:
nothing on screen explains the jump, and the asymmetry with a *failed* save
(which keeps the pane) makes it read as a bug to anyone who hits both.

Why it matters beyond annoyance: the text pane is the only pane that can show a
lossy or unshowable configuration, so the one user most likely to be editing
as text is the one with the most reason to stay there.

Fix: `adopt` conflates "take this as the stored state" with "choose the opening
pane". Split them — have `init(loaded:)` and `read(bucket:from:)` set the
opening pane, and let the post-write `adopt` leave `pane` alone (`visiblePane`
already covers the case where the form has become unavailable, so no clamp is
needed). Ship it with a test that saves from `.text` and asserts the pane, and
a probe that deletes the line.

### Minor (Nice to Have)

**M1. The census cannot see a value-level rewrite, and `read`'s doc comment
claims it can.** `BucketCORSSheet.swift`, `read(_:)` and the type's header
("does the text say anything the rules do not?"). Demonstrated with
`<AllowedOrigin>a&#13;b</AllowedOrigin>`: `isLossless == true`, yet
`parseCORS(corsBody(rules)) != rules` (`a\rb` → `a\nb`). One line closes the
class: compare `parseCORS(canonical)` with `rules` beside the census. Not
reachable from a real S3 answer — but the mechanism's stated claim should match
its reach either way.

**M2. (Core, out of this task's file list) `corsBody` is documented as
`parseCORS`'s inverse and is not, for a value holding a carriage return.**
`Sources/macSCPCore/S3/S3SettingsXML.swift`, `corsBody`'s doc comment: "this
stays the inverse of `parseCORS` for any rule, valid or not". A CR in a value is
written literally and XML line-end normalization turns it into LF on the way
back; writing it as `&#13;` would make the claim true. Worth a
`docs/BACKLOG.md` row with the measurement above rather than a change here.

**M3. Two near-duplicate notices are shown at once.** `BucketCORSSheet.swift`,
the notice stack in `editor`: `formUnavailableLine` and `blockerSentence` are
rendered independently, so a lossy document puts
`s3.cors.formCannotShowThis` (~240 characters) directly above
`s3.cors.problem.dropsSomething` (~95), and unreadable text puts "The fields
are off until the text is a readable CORS configuration again." above "The text
is not a readable CORS configuration yet, so it cannot be saved." Both pairs say
one thing twice. Suppress the blocker line when the form-off line already
carries the same cause.

**M4. A negative `MaxAgeSeconds` passes the pre-send gate.** The form's field
rejects it (`maxAge(fromField:)` requires `seconds >= 0`), but the text pane
accepts `<MaxAgeSeconds>-5</MaxAgeSeconds>`: `parseCORS` reads it,
`CORSRule.validate()` does not check the range
(`S3BucketSettings.swift:309-320` checks origins and methods only), so
`canSave` is true and the user gets the generic "could not be saved" instead of
a named reason. The fix belongs in `validate()` (Core), which the brief
excluded — a backlog row, with the sheet inheriting it for free.

**M5. One expectation compares against a sentence the sheet never shows.**
`BucketCORSSheetTests.swift`,
`aRuleRefusedBeforeSendingIsNotReportedAsAnUnusableAnswer`:
`let unusable = RemoteFSError.protocolError(reason: "x").localizedDescription`
is not what `message(for:)` produces for a non-finding error — that is
`saveFailedLine.text`. The preceding expectation already pins the sentence
exactly, so nothing is lost, but the second line asserts almost nothing while
looking like the guard named in the test's title. Compare against
`BucketCORSModel.saveFailedLine.text`.

**M6. The new file is 895 lines and holds four responsibilities.**
`BucketCORSSheet.swift`: the model with its 31-line catalogue, `ElementCensus`,
the sheet, and three private views. A split at the model/view line (or at
least moving `ElementCensus` out — see the placement recommendation) would make
each half readable on its own. Flagging what this change contributed, not a
pre-existing size.

**M7. The "Fields" segment stays clickable while the form is off.**
`BucketCORSSheet.swift`, the `SegmentedChoice` binding: `selectPane` returns
early for `.form` while unavailable, so the click does nothing and the control
snaps back. The notice explains *why* the form is off, but a control that
accepts a click and ignores it is worse than a disabled one.

**M8. "needs at least one allowed origin" while an origin field is visibly
filled.** `s3.cors.problem.noOrigin %lld`, reached when an origin is blank or
whitespace-only (`validate()` treats it as no origin). The user sees a field
with a space in it and a sentence saying there is no origin. "Rule %lld needs
an allowed origin that is not blank" would be true of both cases.

**M9. The registry does not hold the form-off-plus-refused-save state.**
`Tests/macSCPAppKitTests/BoundedViewRegistry.swift`: five CORS entries, none
with `saveFailure` set (it is `private(set)`, so an entry would have to drive a
failing save). I measured the state at 553–566 pt against 620 granted, so it
fits today; nothing pins it, and it is the tallest combination the sheet can
reach.

**M10. The catalogue-key scan checks one direction.**
`everyKeyTheSheetUsesIsOneTheCatalogueChecksCover` asserts used ⊆ covered; a
line declared in `fixedLines` and never shown would pass. All 31 are currently
used, so this is a future-proofing note.

**M11. A lossy stored document whose rules parse to zero would clear without
the warning.** `clearsTheConfiguration` requires `!baselineRules.isEmpty`, so a
bucket whose configuration parsed to no rules at all would let the user save
`setCORS([])` — a `DELETE ?cors` — with no "this removes the configuration"
notice. Near-unreachable (S3 rejects a zero-rule configuration, and a
`CORSRule` with no recognized children still parses to a rule), which is why
this is Minor; `!baselineWasLossless` in the condition would close it.

---

## Not findings, as instructed

- No `noix-docs` page: the plan's closeout task owns it. The report flags it.
- The text pane's caret behaviour is not visually verified; no test draws an
  `NSViewRepresentable` and the app was not launched.
- The `ViewTestabilitySpike` red: confirmed present at HEAD, unrelated, not
  re-measured at BASE by the implementer and not claimed to be.

---

## Two placement judgments — recommendations

**1. `ElementCensus` (report concern 7): move it to Core, beside `parseCORS` —
as a follow-up, not a reopening of Task 9.**

Three reasons, in order of weight. (a) The property it measures is a property of
`parseCORS`, not of a sheet: the lossiness is documented on
`S3BucketSettings.cors(ofBucket:)` and on `parseCORS` itself, both in Core, and
the sheet is only the first caller to care. (b) **Its correctness depends on
`CORSDelegate`'s internals.** The reason I can call the census structural rather
than heuristic is the injective map from written elements back to consumed ones
— a statement about the parser's depth bookkeeping, which lives one target
away. A change to `parseCORS` (a new recognized element, a different depth
rule) can falsify the App's check without touching the App, and nothing would
go red. That is CLAUDE.md's "comments that describe other code" failure mode
with a scan in place of the comment. (c) A second caller is already foreseeable
— the version-history half, or anything that wants "are these rules everything
the store sent?" without a view.

Shape I would prefer: not `ElementCensus` lifted verbatim, but one Core
function that answers the whole question —
`S3SettingsXML.parseCORSReportingLoss(_:) -> (rules: [CORSRule], isLossless: Bool)`
— with the census private inside it and the value round-trip (M1) folded in,
tested beside `S3CORSTests` where the parser's own cases already live. The App
then drops ~35 lines and the "did anything get dropped" question has one
answer in the codebase instead of one per caller.

Cost and why it is yours: it is a Core API addition, which the brief excluded,
and Core API here is held to its own review standard. Doing it now reopens a
task that is otherwise finishable; doing it at closeout costs one small, well-
scoped commit and a backlog row. I recommend the latter.

**2. The form-off sentence (report concern 8): sharpen it, and do it now rather
than at closeout.**

The implementer's self-criticism is correct and understated: §6.3's words are
"names what it cannot show", and the shipped sentence names three categories in
a disjunction. For the audience §6.3 posits — someone who does not necessarily
know what CORS is — "an element that is not part of a rule, a method other than
GET, PUT, POST, DELETE or HEAD, or a value spread over several lines" is the
hardest sentence in the sheet, and it is the one shown at the moment the user is
most lost. It is also the longest string in the catalogue, which is why it
drives the sheet's measured height.

Recommendation: **three keys instead of one, and name the offender in the two
that can.** The model already distinguishes the causes, so no new state is
needed:

- method outside the five — `problem` already holds
  `.methodNotAllowed("FETCH")`, so: "“FETCH” is not a method the fields can
  show. Edit the rules as text." (and this case can then drop the separate
  `problem.method` notice, closing M3 for it).
- a value over more than one line — `formCanShow` knows which rule, so: "A
  value in rule %lld runs over more than one line, which a field cannot hold.
  Edit the rules as text."
- lossy — the only one that genuinely cannot name the offender today, and that
  is an argument for keeping names rather than for staying vague:
  `ElementCensus` already holds both multisets, so `theirs - ours` yields the
  offending element names for free. "The text holds something a rule has no
  place for (%@). Edit the rules as text."

Why now and not at closeout: it is a four-language catalogue change, and the
sentence it replaces is the one the 620 pt bound was measured against — so
deferring it means re-measuring `BoundedViewLayoutGuardTests` and the figure
report a second time. Shipping it with I1 is one pass over the same file and
the same four catalogues. If you would rather not spend it, the honest middle is
to split only the lossy case from the other two: the current sentence is wrong
mainly because it offers three explanations when the model knows one.

---

## Assessment

**Spec compliance:** ✅ Spec compliant (one ⚠️: §6.3's "names what it cannot
show" is implemented as three categories, ruled to the maintainer above rather
than reported as a finding).

**Task quality:** Needs fixes

**Reasoning:** The honest edge is built properly and its mechanism is stronger
than the report's own description of it — 28 constructed inputs produced no
false positive and only one census-invisible loss, which is a value-level
rewrite that one line in `read` would close. All 18 probes reproduce unrepaired,
every committed figure reproduces from its command, both correction records
quote verbatim, and the `ConnectionActionRouteTests` rewrite answers Task 8's
review without losing P12. The one thing that blocks is behavioural and
untested: a successful save silently moves the user out of the Text pane, which
is the interaction this whole task exists to provide.
