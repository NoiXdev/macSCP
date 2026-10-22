# Task 10 review — the Object Lock sheets

Reviewer: task reviewer, 2026-10-21. BASE `2d489afd`, HEAD `7afd772f` (one
commit). Worktree `/Users/noidee/macSCP/.claude/worktrees/diff-view`, tree clean
before and after this review (`git status --porcelain` empty; checked before
each mutation probe and after the last revert).

What I ran, so a later reader lands on the same starting set:

```
swift test --filter 'ObjectLockSheetTests|BucketObjectLockSheetTests|ConnectionActionRouteTests|RigidControlScanTests|BoundedViewCoverageTests|GermanAddressFormTests'
```

→ `Test run with 114 tests in 5 suites passed after 2.528 seconds`. The two
Object Lock suites alone are 79 tests (the `mutation-probe` control run under
`--filter ObjectLockSheetTests` prints `control: 79 test(s) ran, 0 pre-existing
failures`), which is the figure the report states.

Two mutation probes of my own, both through `scripts/mutation-probe` on the
committed tree — see Finding I-1.

---

## Verdict 1 — spec compliance

**Met, with every step done and five disclosed deviations that are each equal to
or better than the brief** — except that the one requirement the brief singles
out (COMPLIANCE "with a clear warning") is implemented and held by nothing,
which is Finding I-1.

### Step 1 — write the failing tests

All four of the brief's bodies are in
`Tests/macSCPAppKitTests/ObjectLockSheetTests.swift`, under the brief's own
names, in the section `// MARK: - The brief's four cases`, with the brief's
values:

| brief | committed | verdict |
| --- | --- | --- |
| `complianceCannotBeRunUntilItIsAcknowledged` | `:39-46`, `retainUntil = Self.newYear` where `newYear = Date(timeIntervalSince1970: 1_798_761_600)` — the brief's literal, named | done as written + `now:` |
| `governanceNeedsNoAcknowledgement` | `:48-52`, identical | done as written + `now:` |
| `theAcknowledgementNamesTheDate` | `:54-60`, asserts the literal key `"s3.objectLock.complianceAcknowledgement %@"` and `acknowledgementDateText.isEmpty == false` | done as written + `now:` |
| `aBucketWithoutObjectLockOffersNoLockAtAll` | `:62-68`, including the brief's "Review Focus 5" comment verbatim and the literal `"s3.objectLock.notEnabledOnThisBucket"` | done as written + `now:` |

The only edit is the injected `now: { Self.now }` (deviation 5, ruled on below).
The two asserted string literals are the brief's, character for character —
`ObjectLockModel.complianceAcknowledgementLine.key` and
`ObjectLockLines.notEnabledOnThisBucket.key` both carry exactly those spellings,
and the en catalogue has both keys.

### Step 2 — run them and watch them fail

The brief's expected failure is `cannot find 'ObjectLockModel' in scope`. The
commit message's red #3 quotes
`ObjectLockSheetTests.swift:448:20: error: cannot find type 'ObjectLockModel' in
scope`, with "76 of them `cannot find 'ObjectLockModel' in scope`". **Not
re-verifiable by me**: the reds are against pre-commit trees that no longer
exist, and the stripped logs live in a session scratchpad I cannot read. What is
verifiable is that nothing *behavioural* is claimed to have gone red, and the
report says so in those words. Consistent with the brief; recorded as
unverified.

### Step 3 — implement both sheets

`Sources/MacSCPAppKit/ObjectLockSheet.swift` (695 lines) and
`Sources/MacSCPAppKit/BucketObjectLockSheet.swift` (468). The brief's required
spelling is honoured: `ObjectLockSheet.retentionForm` uses
`CheckboxRow(model.acknowledgementSentence, isOn: $model.acknowledged, wraps: true)`,
and `BucketObjectLockSheet.form` the same, pinned by
`RigidControlScanTests.onlyTheListedSitesOptIntoWrapping` (the two new sites are
in its `expected` table) and by `theAcknowledgementIsAWrappingCheckboxRow` in
each suite.

Done differently: one sheet per focus rather than one sheet carrying mode, date
and the hold toggle together (deviation 1, ruled on below).

### Step 4 — read the bucket's lock state lazily, cache it for the session

`Sources/MacSCPAppKit/ObjectLockStateCache.swift`. Built on
`hasObjectLock(ofBucket:)`, which is what the brief's correction note demands,
and the choice is pinned twice —
`theCacheAsksWhetherThereIsALockAndNotWhetherThereIsADefault` asserts
`probe.defaultReads.isEmpty`, and `aLockedBucketWithNoDefaultIsOfferedTheLock`
asserts the case the correction exists for (lock present, default `nil`,
`canRun == true`). The implementer's own probe P9 plants the wrong call and is
caught by 13 tests. I confirmed the Core doc the brief cites:
`Sources/macSCPCore/RemoteFS/S3BucketSettings.swift`, `hasObjectLock` — "`false`
is the store's answer that the bucket has none (`404`
`ObjectLockConfigurationNotFoundError`, measured 2026-10-19); any other failure
throws, and is never `false`" — so the cache's premise holds.

The brief's test body is committed with one substitution: the brief's
`CountingBucketSettings` / `probe.hasObjectLockCalls == 1` / `== 2` became
`FakeBucketSettings` / `probe.hasLockReads == ["b"]` / `== ["b", "other"]`
(`ObjectLockSheetTests.theLockStateIsReadOncePerBucket`). That is the brief's
assertion plus *which* bucket was read — strictly stronger. Deviation 4.

"A `404` is cached as 'no lock', not as a failure to retry" — pinned by
`aBucketWithNoLockIsRememberedAsSuch` (one read for two asks) and
`aFailedReadIsNotRememberedAsAnAnswer` (`hasLockReads == ["b", "b"]`), with
probe P10 planting the confusion. "Owned by the session, so it dies with it" —
`BrowserSession.objectLockStates` in `SessionTab.swift`, set in
`ContentView.startSession`.

### Step 5 — the two `fileActions` and their dispatch arms

`BackendDescriptor.s3Descriptor.fileActions` gains `s3.retention` and
`s3.legalHold` with keys `browser.action.retention` / `browser.action.legalHold`
— the brief's two ids exactly. The arm is in `handleBrowserMenuEntry`, keyed off
`action.id` through `ObjectLockFileAction`, beside the presigned-URL arm. The
route arm `ConnectionActionRoute.objectLock` is added for the bucket default.
I checked that a live-and-inert row is not reachable: `BrowserContextMenu.entries`
returns `[.copyPath]` for any container row and appends `fileActions` only under
`only.kind == .file`, so `ObjectLockTarget.resolve` cannot be handed a bucket or
a folder from the menu.

### Step 6 — tests, catalogue entries, commit

39 `s3.objectLock.*` keys in each of the four catalogues — verified, one key per
line so `grep -c` is the right tool here:

```
grep -c '^"s3\.objectLock\.' Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings  # 39
```
and the same 39 for `de`, `fr`, `pl`. Plus `browser.action.retention` and
`browser.action.legalHold` in all four. The commit subject is the brief's
string, verbatim.

### The five disclosed deviations, ruled on

1. **One sheet per focus rather than one combined sheet — better.** The safety
   argument the implementer gives is sound (a click meant to lift a hold is
   never a field away from a COMPLIANCE write), and the brief argues for it
   itself without noticing: it asks for **two** `FileActionContribution` ids,
   `s3.retention` and `s3.legalHold`. Two differently-named menu items that both
   open the same combined sheet would be the odd construction. The split is
   pinned by `theLegalHoldSheetNeverWritesARetention` and by the sweep's
   per-focus assertions. Cost, and it is real but small: a user asking "why can
   I not delete this file" must open both sheets, because the retention sheet
   never says whether a hold is on and the hold sheet never says whether a
   retention is in force. Worth a sentence in the user docs at closeout; not
   worth a redesign.
2. **The bucket default carries the same COMPLIANCE ceremony — better.** A
   COMPLIANCE default is every future file's lock, so it is strictly more
   far-reaching than the per-file write the brief did ceremonialise. Leaving it
   bare would have been the inconsistency.
3. **`1...36500` days — equal.** The floor is Core's
   (`setObjectLockDefault` refuses fewer than one day, and
   `FakeBucketSettings` mirrors that refusal); the ceiling is labelled as
   macSCP's own and not as a claim about any store, which is the right framing.
   See Finding M-9 for the one thing the comment overstates about *why*.
4. **`FakeBucketSettings` over a new `CountingBucketSettings` — better**, and it
   is what the dispatch asked for. One fake, extended by an `ObjectLockFixture`
   whose absence keeps the six calls `operationNotSupported`.
5. **An injected `now:` in the brief's four tests — better, and close to
   required.** The brief's literals are `2027-01-01`; as written the four cases
   compare them against the wall clock and would go red on that date. CLAUDE.md
   forbids exactly that shape. The brief's values are preserved as named
   constants (`Self.newYear` is the brief's `1_798_761_600`), so nothing about
   the cases' content changed.

---

## Verdict 2 — task quality

**High, with one hole that must be closed before the task is accepted**: the
COMPLIANCE warning — the one thing the maintainer made a requirement — is
displayed correctly and is held by no test, measured by two green mutation
probes. Everything else I checked is sound: the state sweeps are real (both
sides populated, oracle restated independently), every blocker stands alone,
the acknowledgement's lifecycle has no stale path I could find, the four
catalogues are complete and format-compatible, the committed figures reproduce
under the commands beside them, and no error `reason:` reaches a sentence or a
failure message.

---

## Findings

Counts: **0 Critical, 2 Important, 11 Minor.**

### Important

#### I-1. Nothing holds the COMPLIANCE warning in place (`ObjectLockSheet.swift`, `ObjectLockModel.modeDetailLine` and `ObjectLockSheet.retentionForm`; same shape in `BucketObjectLockSheet.swift`)

**What is wrong.** The maintainer's decision of 2026-10-19 makes the warning a
requirement of this task, not a nicety. The warning is implemented and its text
is good (see M-2 for the one thing I would change). But the link from "the user
chose COMPLIANCE" to "the user is shown the warning" is asserted by no test, in
either sheet. Every test that mentions the warning reads the static constant
`ObjectLockModel.complianceWarningLine` / `BucketObjectLockModel.complianceWarningLine`
directly — I checked all of them:

```
grep -rn "modeDetailLine\|complianceWarningLine" Tests/ Sources/MacSCPAppKit
```

prints seven test lines, all of them naming the constant, and not one naming
`modeDetailLine`. `ObjectLockModel.lines` does include `modeDetailLine`, but
`fixedLines` already contains the warning, so the catalogue tests
(`everyLineResolvesInAllFourLocales`, `theEnglishCatalogueSaysTheDefault`)
resolve it whether or not any state ever shows it.

**How I know.** Two mutation probes, each via `scripts/mutation-probe` on the
committed tree (clean before each; `git status --porcelain` empty after the
reverts). Each reported `control: 79 test(s) ran, 0 pre-existing failures`.

Probe A — COMPLIANCE's detail line becomes the *governance* note, so the user
choosing the irreversible mode is shown "Someone with the right permission can
still shorten or remove a governance retention":

```
scripts/mutation-probe --filter ObjectLockSheetTests --apply "perl -pi -e 's/case [.]compliance: return Self[.]complianceWarningLine/case .compliance: return ObjectLockLines.governanceDetail/' Sources/MacSCPAppKit/ObjectLockSheet.swift"
```
→ `RESULT: GREEN — 79 test(s) ran and NONE of them noticed the plant.`

Probe B — the warning is deleted from the sheet's body outright (the plant
removed 6 lines, so it was not a silent no-op; the script printed
`1 file changed, 6 deletions(-)`):

```
scripts/mutation-probe --filter ObjectLockSheetTests --apply "perl -0pi -e 's/            if let detail = model[.]modeDetailLine [{]\n                Text\(detail[.]text\)\n                    [.]font\([.]caption\)\n                    [.]foregroundStyle\(model[.]mode == [.]compliance \? Color[.]red : Color[.]secondary\)\n                    [.]fixedSize\(horizontal: false, vertical: true\)\n            [}]\n//' Sources/MacSCPAppKit/ObjectLockSheet.swift"
```
→ `RESULT: GREEN — 79 test(s) ran and NONE of them noticed the plant.`

This is the shape CLAUDE.md's guard section is about from the other side: not a
negative check gone stale, but a property with **no** check, on the one
irreversible operation on the branch. The implementer's own 34 probes are
thorough about *whether the write happens*; none of them is about *whether the
person was told*. Mutation testing verifies sensitivity, never scope — and this
is the scope gap.

I measured only the per-file sheet. `BucketObjectLockModel.modeDetailLine` has
the identical `switch` and `BucketObjectLockSheet.form` the identical
unconditional `Text(model.modeDetailLine.text)`, with no test naming either, so
I expect the same two probes green there; I did not run them.

**What a fix would be.** Two cheap assertions, one per sheet, plus one scan.
(a) Model side: `modeDetailLine` is `complianceWarningLine` when
`mode == .compliance` and `ObjectLockLines.governanceDetail` when it is
`.governance` — compared by `key`, derived from the type, not spelled as a
literal. Beside it the positive that both arms are reachable, so a
`modeDetailLine` that returned the warning always would also be red.
(b) View side: a source scan of `ObjectLockSheet.swift` /
`BucketObjectLockSheet.swift` asserting that the `retentionForm` / `form` region
reads `model.modeDetailLine` — the same shape as the existing
`theSheetIsOpenedAndRunForTheFileThatWasChosen`, which already scans those files
for `model.run(` and `model.load(`. Both plants above would then be red.

#### I-2. `s3.objectLock.mode.governance.detail` tells the user a governance retention can be shortened or removed, and macSCP cannot shorten one (`ObjectLockLines.governanceDetail`, `ObjectLockSheet.swift`)

**What is wrong.** The en text is "Someone with the right permission can still
shorten or remove a governance retention." That is true of the store and false
of this app, and the app is where the sentence is read. Core says so in its own
doc comment — `Sources/macSCPCore/RemoteFS/S3BucketSettings.swift`,
`setRetention`: "Shortening a GOVERNANCE retention needs a bypass header this
call does not send, so the store refuses it." There is no other call in the tree
that shortens or removes a retention. So within macSCP a GOVERNANCE retention is
also, in practice, only extendable.

Two consequences, both in the same sheet. First, the sentence that justifies
GOVERNANCE getting no ceremony ("it's reversible") invites a user to set one
casually in the belief that this app will let them undo it. Second, the same
sheet, after they try, shows `s3.objectLock.error.refused`: "A retention that is
already in force may not be shortened…". A user reads those two sentences as a
contradiction, and the sheet never resolves it.

**How I know.** Read `ObjectLockLines.governanceDetail` and
`ObjectLockLines.retentionRefused` in `Sources/MacSCPAppKit/ObjectLockSheet.swift`;
read `setRetention`'s doc comment in
`Sources/macSCPCore/RemoteFS/S3BucketSettings.swift`; searched the tree for any
bypass-sending path with

```
grep -rni "x-amz-bypass" Sources Tests
```

which prints 3 lines, **none of them under `Sources`**: two in
`Tests/macSCPCoreTests/S3ObjectLockGatedTests.swift` (the rig measurement that
got 403 under COMPLIANCE and 204 under GOVERNANCE), and one in
`Tests/macSCPCoreTests/S3ObjectLockTests.swift:509`, which asserts
`sent.value(forHTTPHeaderField: "x-amz-bypass-governance-retention") == nil` —
so "macSCP never sends it" is already a pinned property of Core, and the App's
sentence is the only place that reads as though it did.

**What a fix would be.** Say who can, and that it is not here: a governance
retention can be shortened or removed with the right permission, but not from
macSCP, so treat the date as the one that will hold. It is a sentence change in
four catalogues, and it is the sentence on which "GOVERNANCE needs no
acknowledgement" rests, so it is worth getting right rather than deferring. A
test like `theComplianceWordsSayWhatCannotBeUndoneInPlainEnglish` — a positive
on the phrase that names the limit — would hold it.

### Minor

#### M-1. The English refusal sentence is the only one of the four that is not hedged (`s3.objectLock.error.refused`)

The report's concern 6 asks whether the hedge is honest or vague. It is honest
in three languages and **not hedged at all in the fourth, which is the source
text**. Run from the repository root:

```
grep -h '^"s3.objectLock.error.refused"' Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings Sources/MacSCPAppKit/Resources/de.lproj/Localizable.strings Sources/MacSCPAppKit/Resources/fr.lproj/Localizable.strings Sources/MacSCPAppKit/Resources/pl.lproj/Localizable.strings
```

- `en`: "A retention that is already in force **may not** be shortened" — reads
  as a flat rule.
- `de`: "darf **möglicherweise** nicht verkürzt werden"
- `fr`: "ne **peut peut-être pas** être raccourcie"
- `pl`: "**być może** nie wolno skracać"

So the three translations carry a hedge the source text does not, which is the
reverse of the direction CLAUDE.md's translation rule allows: `en` is what every
other catalogue is measured against, and here it asserts more than the
measurement supports — the report states plainly that a refused `setRetention`
was never measured on the rig. It also reads as a contradiction of
`governanceDetail` in the same sheet; that is I-2, the same sentence pair from
the other end.

**Fix:** hedge the English the way the other three already are, and say what the
person can do next. Whichever wording wins, the four must agree.

#### M-2. `notEnabledOnThisBucket` offers a choice the tree does not have yet (`ObjectLockLines.notEnabledOnThisBucket`)

The sentence ends "it can be chosen when a bucket is created" (de: "sie lässt
sich beim Erstellen eines Buckets wählen"). At this commit macSCP creates no
buckets: `ls Sources/MacSCPAppKit | grep -i bucket` prints
`BucketCORSSheet.swift`, `BucketObjectLockSheet.swift` and
`BucketVersioningSheet.swift` and no create-bucket sheet, and
`ConnectionActionRoute` has cases for `versioning`, `cors` and `objectLock` only
— the descriptor's `s3.createBucket` contribution is unrouted. A user who reads
the sentence today is sent looking for something their build does not have,
which is what the project's "features not yet in a release are marked as coming"
rule exists to prevent.

It becomes true at Task 11. **Fix:** leave the sentence and put it on the
branch's closeout checklist as a thing Task 11 makes true, or hedge it now. Not
worth blocking Task 10 for; worth not forgetting.

#### M-3. `FakeBucketSettings.defaultWrites`' doc comment is contradicted by the test beside it

`Tests/macSCPAppKitTests/FakeBucketSettings.swift:158` reads
`/// The setObjectLockDefault calls that were not refused, in order.` But
`setObjectLockDefault` appends the `DefaultWrite` in its *first* `withLock`,
before the `writeError` check in its *third*. So a call refused by `writeError`
**is** recorded — and
`BucketObjectLockSheetTests.aRefusedWriteKeepsTheStateAndSaysWhyInAFixedSentence`
asserts exactly that (`#expect(probe.defaultWrites.count == 1)` with a
`writeError` set). Only the two guard refusals (fewer than one day, a bucket
with no lock) record nothing.

**How I know:** read `setObjectLockDefault` in full
(`sed -n '/func setObjectLockDefault/,/^    }/p' Tests/macSCPAppKitTests/FakeBucketSettings.swift`)
against the field's comment and against the test that uses it.

**Fix:** say what it means — the calls that reached the store, whether or not
the store then refused them — and name the two guards that record nothing.

#### M-4. The 256-state sweep's comment claims more than the sweep covers (`ObjectLockSheetTests.Scenario`, `ObjectLockSheetTests.model(for:)`)

Both sides of the sweep are populated, which was the thing to check. With
`lock` 4-way, `current` 2-way and the other five dimensions 2-way, only
`lock == .present && current == .read` can write — 32 of the 256 — of which
`mayWrite` passes 6 of the 16 retention states (`day == .future` halves them to
8; the 4 governance ones all pass, the 4 compliance ones only when
`acknowledged`) and 8 of the 16 legal-hold states (`holdWanted`). So 14 writes
against 242 refusals, and the test asserts `wrote > 0` and `refused > 0`
explicitly rather than leaving it to be inferred. `mayWrite` is an independent
restatement of the rule as a conjunction rather than as a filtered list, which
is the right construction. No complaint about the sweep. The 288-state sweep is
the same shape, with `Same.sameAsDefault` collapsed in `model(for:)` and the
collapse disclosed in its own comment.

The comment is what overreaches: "What the model's facts can be, as data. The
cross product **is the sheet's state space**." It is not quite — `model(for:)`
always builds `ObjectLockModel.Current(retention: nil, legalHold: false)`, so no
scenario has a file that already carries a retention or is already held. Two
consequences: inside the sweep `holdUnchanged` is only ever exercised in its
`legalHold == false` form, and the `retentionLine` branch of `currentLine` /
`currentSentence` is never reached from the sweep (it is reached through
`fixedLines`). Both are covered by separate tests
(`aLegalHoldIsPlacedAndLiftedOnTheNamedKey`,
`aLegalHoldLoadReadsTheHoldAndStartsTheToggleWhereTheStoreIs`,
`aLoadReadsTheCurrentRetentionOfTheNamedKey`), so nothing is unheld — it is the
sentence that is wrong, and this project has a rule about a comment that
describes other code.

**Fix:** either say "the decision inputs, with the file's own current values
fixed empty; the non-empty ones are in the loading tests", or add `Current` as a
third dimension — that would take the sweep to 1024 and the oracle's legal-hold
arm to `holdWanted != currentlyHeld`.

#### M-5. `noOtherBackendContributesThem` is all-negative, with its positive in a different test

`ObjectLockSheetTests.noOtherBackendContributesThem` is a loop of
`#expect(!ids.contains(...))` and nothing else. If `ObjectLockFileAction.allCases`
emptied, or `ConnectionKind.allCases` filtered to nothing, it would pass while
measuring nothing — which reads exactly like a check that is satisfied. The
positive does exist (`eachFileActionIsAnIdTheS3DescriptorContributesAndMapsToItsOwnFocus`
asserts `!ObjectLockFileAction.allCases.isEmpty`) but one test away, so the
pairing CLAUDE.md asks for is not beside it.

**Fix:** count the iterations in the test's own body and assert the count —
`checked == (ConnectionKind.allCases.count - 1) * ObjectLockFileAction.allCases.count`
— the way `theTitlesOfTheTwoActionsResolveInEveryLanguage` already does with its
own `checked` counter.

#### M-6. `acknowledged` is an unguarded `var`, and nothing counts its writers (`ObjectLockModel.acknowledged`, `BucketObjectLockModel.acknowledged`)

An accepted hole rather than a live one, and the report discloses it. It cannot
be `private(set)`, because the view needs `$model.acknowledged`. Every other
decision field on both models *is* `private(set)`; this one is the exception, on
the one decision that gates the irreversible write, and `run()` cannot tell a
tick from the checkbox from a tick set programmatically.

**How I know** it is not live today:

```
grep -rn 'acknowledged = ' Sources/MacSCPAppKit
```

prints 10 lines, all in the two model files: the two declarations
(`var acknowledged = false`) and eight resets to `false` (two `didSet` pairs,
the bucket model's designated init, its `load`, and the two `run`/`save`
success paths). Nothing in `Sources` sets it `true`; only the two
`CheckboxRow(..., isOn: $model.acknowledged, ...)` bindings do.

**Fix, if the maintainer wants it closed:** a source scan asserting that
`acknowledged` is written only at the sites the models own plus the two
bindings, derived from the symbol rather than a hand-written list; or an
`acknowledge(mode:retainUntil:)` method that sets the flag only when its
arguments match the model's current state, with the binding going through it.
The scan is cheaper and catches the case the report names.

#### M-7. `ObjectLockModel.load()` does not clear `acknowledged`, where `BucketObjectLockModel.load()` does

`BucketObjectLockModel.load` ends its success path with `acknowledged = false`;
`ObjectLockModel.load` never touches it. Not reachable today: the acknowledgement
checkbox lives inside `retentionForm`, which is only built once
`model.currentSentence` is non-`nil` — i.e. after the read landed — and `.task`
calls `load` only while `bucketLock == .reading`. It is the one asymmetry between
the two models, and asymmetry is what makes the next reader of either file guess.

I checked the acknowledgement's other exits, since the brief asks. A change of
`mode` or `retainUntil` clears it (`didSet`, with `guard … != oldValue` so a
redraw's write-back of the same value does not); a *successful* retention write
clears it; a *failed* write does not, which is right — the mode and date are
unchanged, so it is the same decision being retried. All three directions are
pinned (`changingTheDateTakesTheAcknowledgementBack`,
`leavingComplianceAndComingBackTakesTheAcknowledgementBack`,
`writingBackTheSameValueKeepsTheAcknowledgement`) with
`tickingAgainAfterAChangeRunsIt` as the positive beside them. **No stale path
found.**

**Fix:** add `acknowledged = false` to `ObjectLockModel.load` for symmetry, or a
line in it saying why it is not needed here and is in the other.

#### M-8. The retention form does not start from the retention already in force (`ObjectLockModel.load`, `ObjectLockModel.retainUntil`)

`load` reads the file's current retention into `current` and the sheet shows it
("Current retention: Governance, until …"), but `retainUntil` stays at
`defaultDate(from: now())` — a week ahead. On a file already locked past that
date the sheet's default value is therefore a *shortening*, which the store
refuses (macSCP sends no bypass header, as I-2 shows), so the user meets M-1's
refusal sentence before deliberately changing anything. The common gesture on an
already-locked file is to extend it, and the sheet starts on the one value that
cannot be saved.

The report discloses the general shape ("No behaviour is restricted by the
file's current retention") and declines to add a rule about what S3 allows,
which is the right call — this is not a rule, it is a starting value.

**Fix:** once the read lands, start `retainUntil` at the later of
`defaultDate(from: now())` and the current retention's `retainUntil`. It needs
care with the acknowledgement, because the seeding is itself a change of
`retainUntil` and would clear a tick — harmless, since it happens before the
checkbox is drawn, but that should be tested rather than assumed.

#### M-9. The `dayRange` comment attributes the ceiling to the calendar, and the calendar is not where 36,500 comes from (`BucketObjectLockModel.dayRange`)

"The ceiling is macSCP's own and not a claim about any store" is exactly right
and well said. The clause after it — "It exists because the acknowledgement
names the day a file added now stays locked until, and a period too long for the
calendar to count would leave that sentence naming the wrong day" — is true of
`Int.max`, where `Calendar.date(byAdding:)` returns `nil` and
`acknowledgementDate` falls back to `now()`. It is not true anywhere near
36,500: a hundred years is well inside what the calendar counts. The stated
reason justifies *some* ceiling, not *this* one, which is a policy choice.
`theAcknowledgementDateDoesNotRunPastTheCeiling` pins the clamp either way.

**Fix:** keep both sentences and separate them — a ceiling is needed so the
arithmetic cannot fail, and 36,500 is the figure chosen, which is macSCP's.

#### M-10. The German acknowledgement reads awkwardly around the substituted date

`de`: "die gespeicherten Daten dieser Datei **vor dem %@** löschen", and for the
default "bleibt **bis zum %@** gesperrt". `%@` is a long date *and* a short time
(`ObjectLockDates.text` uses
`Date.FormatStyle(date: .long, time: .shortened)`), so it renders as "vor dem
1. Januar 2027 um 00:00" — grammatical but stilted, with the dative article in
front of a date-plus-time. Cosmetic; the du-form and the content are right, and
`GermanAddressFormTests` covers the form (the implementer's probe P23).

**Fix:** reword to put the date in apposition, or leave it — a native reader
should decide.

#### M-11. The bucket default's acknowledged sentence drifts with the clock while the tick stands (`BucketObjectLockModel.acknowledgementDate`)

`acknowledgementDate` is computed from `now()` on every read, so the sentence
the user ticked ("A file added now stays locked until X") names a later day a
minute later, and nothing clears `acknowledged` for that. Nothing wrong is
written — `save` sends `days`, and a change of `days` does clear the tick — and
the drift runs in the direction the sentence already describes ("a file added
*now*"). Since `now()` is not observable, the drawn sentence is more likely
simply stale than visibly drifting. Harmless either way, and the comment on
`acknowledgementDate` is honest about what the value is for.

**Fix:** none needed. If the maintainer wants the sentence to be a fixed
statement, freeze the date when the mode becomes `.compliance` and clear the
tick whenever it is refreshed.

---

## The brief's specific questions, answered

**Are both sides of the 256- and 288-state sweeps populated?** Yes, and by a
wide margin on the refusing side. Derived from the scenario generators and the
oracles rather than instrumented:

- 256: only `lock == .present && current == .read` can write (64 → 32). Of the
  16 retention states there, `day == .future` leaves 8, and `(governance ||
  acknowledged)` passes 6 of those 8 (`(g,F)`, `(g,T)`, `(c,T)` × 2 hold values,
  minus the 2 `(c,F)`). Of the 16 legal-hold states, `holdWanted` passes 8.
  **14 writes, 242 refusals.**
- 288: `lock == .present && currentRead` leaves 36; `dayCount >= 1` leaves 24;
  `same != .sameAsDefault` leaves 16 (the collapse in `model(for:)` makes every
  `sameAsDefault` state refuse); `(governance || acknowledged)` passes 3 of the
  4 mode/tick combinations. **12 writes, 276 refusals.**

Both tests also assert it directly (`#expect(wrote > 0)`, `#expect(refused > 0)`),
so neither half of the `allowed == mayWrite` equality is vacuous. The oracles
(`Scenario.mayWrite`, `Scenario.maySave`) are conjunctions written from the
other end rather than copies of `activeBlockers`, which is what makes the
equality worth asserting at all.

**Does each blocker in `everyBlockerCanBeTheOnlyReasonRunIsOff` really stand
alone, or does a second blocker shadow some of them?** Each stands alone, and
the test's `aloneIn == expected` is set equality, so it is simultaneously the
completeness check and the positive. I worked out an isolating scenario by hand
for all seven of the non-`applying` cases and they are all in the generated
product:

| blocker | isolated by |
| --- | --- |
| `lockUnread` | `lock=.reading, current=.read, retention, governance, day=.future` |
| `lockReadFailed` | the same with `lock=.failed` |
| `noLockOnBucket` | the same with `lock=.absent` |
| `currentUnread` | `lock=.present, current=.unread, retention, governance, day=.future` |
| `dateNotInFuture` | `lock=.present, current=.read, retention, governance, day=.past` |
| `complianceNotAcknowledged` | the same with `compliance, ack=false, day=.future` |
| `holdUnchanged` | `legalHold` focus, `lock=.present, current=.read, holdWanted=false` (the date blocker is focus-gated, so `day` cannot shadow it) |

`applying` is excluded by name and held by
`aSecondRunWhileOneIsInFlightSendsNothing`, which observes it through the fake's
held write rather than racing it. The bucket default's twin
(`everyBlockerCanBeTheOnlyReasonSavingIsOff`) is the same construction and the
same eight-minus-one set; `unchanged` is isolated by `same == .sameAsDefault`
and `daysOutOfRange` by `days == .none` with `same == .differs`.

**Is there a path that keeps a stale acknowledgement across a change that
matters?** None that I could find. See M-7 for the three exits I traced and the
one asymmetry between the two models. The one I looked hardest at — a *failed*
write leaving the tick standing — is correct: mode and date are unchanged, so
the retry is the same decision, and the alternative (clearing on failure) would
make a transient 500 cost the user a second reading of the same sentence.

**`acknowledged` is a plain `var` — real hole or accepted one?** Accepted. See
M-6, with the command that shows nothing in `Sources` sets it `true`.

**Does the COMPLIANCE warning say the thing that is true, in words a
non-technical user reads correctly?** Yes, and it is the best-judged text in the
diff. Two things it gets right that a weaker version would not:

- It says *"erase this file's stored data"*, not "delete this file". Under
  COMPLIANCE a `DELETE` without a version id still succeeds and still writes a
  delete marker, so "nobody can delete this file" would have been false. The
  chosen phrase is true of the thing that actually cannot happen.
- It translates the bypass into the three people a reader cares about — "not
  you, not the account owner, not an administrator" — instead of naming a header
  the reader has no way to check. `theComplianceWordsSayWhatCannotBeUndoneInPlainEnglish`
  pins that negative (no "bypass", "header", "403", "x-amz", "version id",
  "delete marker") with positives beside it (`nobody`/`not you`, `undone`,
  `before`).

The acknowledgement names the exact date and time, formatted for the reader, and
`theAcknowledgementSentenceCarriesTheFormattedDate` asserts both that the date
is in the sentence and that no `%@` is left unfilled, in all four locales. The
bucket default's pair is its own wording and is held distinct in every language
(`theDefaultsWarningIsItsOwnSentence`).

**Does any sentence promise something unmeasured?** Three do, in descending
order: I-2 (`governanceDetail` promises a reversibility this app cannot deliver),
M-1 (the English refusal asserts a store rule the report says was not measured),
M-2 (`notEnabledOnThisBucket` offers a bucket-creation choice the tree does not
have yet). Nothing else I read overstates.

**The hedged refusal sentence (concern 6) — honest, or vague enough to be
useless?** Honest in de/fr/pl, over-asserted in en, and in all four it stops
one sentence short of useful: it names two possible causes and no next step. See
M-1.

**`startSession` creating the cache: is the scan a negative check with a
positive beside it?** It is **entirely positive**, which is better than the
rule asks. `startSessionPutsTheCacheOnTheSessionItBuilds` asserts
`source.matches(of: "BrowserSession.objectLockStates(for:").count == 1` (a count
that fails loudly if the call moves or is spelled differently), `#require`s the
`tab.session = BrowserSession(` range, and asserts the ordering of the two.
`aConnectionWithTheCapabilityGetsACacheAndOneWithoutDoesNot` pairs the
capability positive with its negative in one body. The implementer's probes P17
and P18 are each caught by exactly one of these, and the hazard they close was
real: without the cache the menu row and both file actions are live and open
nothing. Good catch by the implementer, and the right fix (a named function with
a test, not a condition inline).

**Does any new comment state a number or an enumeration the tree contradicts?**
I re-ran every figure the diff writes down, in the form it is committed, from the
worktree root:

| claim | command | result |
| --- | --- | --- |
| 39 `s3.objectLock.*` keys per catalogue | `grep -c '^"s3\.objectLock\.' …/en.lproj/Localizable.strings` (and de, fr, pl) | 39, 39, 39, 39 ✓ |
| `BoundedView` conformer floor 37 | `grep -rhn -e '^ *struct [A-Za-z]* *: BoundedView {' Sources/MacSCPAppKit \| wc -l` | 37 under the session's `grep` and `/usr/bin/grep` ✓ |
| `wraps:` sites now 7 | `grep -rn 'wraps:' Sources/MacSCPAppKit \| wc -l` | 7 under both ✓ |
| rigid-control sites print 13, 4 and 10 | `grep -rn 'SegmentedChoice[(]' Sources/MacSCPAppKit \| wc -l` etc. | 13, 4, 10 under both ✓ |
| "27 lines in all, and the counts below sum to 26" | summed the three `sites` tables: 13 + 4 + 9 | 26, against 27 grep lines, the one difference being `RigidControls.swift`'s own header prose ✓ |
| 11 new registry entries | counted `BoundedViewEntry(` in the diff | 11 (7 `ObjectLockSheet`, 4 `BucketObjectLockSheet`) ✓ |
| 79 tests across the two suites | `mutation-probe` control run under `--filter ObjectLockSheetTests` | `control: 79 test(s) ran` ✓ |

Every corrected paragraph quotes the wording it withdraws, verbatim, as
CLAUDE.md requires — `BoundedViewCoverageTests` ("The floor is 35 on
2026-10-20", "(which prints 35;", "raise it when a thirty-sixth view lands"),
`RigidControlScanTests` twice ("print 13, 2 and 7: 22 lines in all, and the
counts below sum to 21"; "which prints 5 lines", "the one site that opts in"),
`BackendContributions.swift` ("S3's holds `s3.presignedURL`.") and
`handleBrowserMenuEntry` ("Currently the only backend-contributed action is S3's
presigned URL (M14/T5)"). I checked each quotation against the base, by
extracting `git show 2d489afd:<path>` to a scratch file and running

```
grep -n -F -e 'The floor is 35 on 2026-10-20' -e '(which prints 35;' -e 'raise it when a thirty-sixth view lands' <base BoundedViewCoverageTests>
grep -n -F -e 'print 13, 2 and 7: 22 lines in' -e 'counts below sum to 21' -e 'which prints 5 lines' -e 'the one site that opts in' <base RigidControlScanTests>
```

(and the two one-liners for `BackendContributions.swift` and
`ContentView+MenuActions.swift`). Six of the seven patterns matched on a line of
their own. The seventh, `the one site that opts in`, returned nothing and exit 1
— **not because the wording is absent but because the comment wraps it**: the
base reads "`SnippetsSheet.swift` the one" at one line's end and "site that opts
in." at the next, so a line-oriented `grep` cannot see it. Read as two lines
(`sed -n '775,780p'`) the quotation is exact. `grep -F` was the wrong tool for a
quotation that crosses a line, which is the same shape as this project's
`grep -c` lesson one level up; the withdrawal itself is sound.

The three comments that *are* contradicted by the tree are M-3 (the fake's
`defaultWrites`), M-4 (the sweep's "state space") and M-9 (the day ceiling's
stated reason). None of them is a count.

**Should the file-action rows' availability read the cache?** No, and I would
leave it. Three reasons. The rows are only ever offered on a row whose
`kind == .file` — `BrowserContextMenu.entries` returns `[.copyPath]` for any
container row and gates `fileActions` behind `only.kind == .file` — so there is
no live-and-inert row on a bucket or a folder, which was the thing to rule out.
Reading the cache to decide availability would make opening a context menu
perform a network read, and the first one would have to answer synchronously or
the row would flicker. And the sheet's answer is better than a missing row: a
greyed or absent "Retention…" tells the user nothing, where the sheet says
Object Lock is not switched on for this bucket and that macSCP does not switch it
on afterwards. This is the project's own `supportsChecksum` judgement — "a dead
menu item is not an answer" — applied the same way.

---

## What I could not check

- **The three reds.** They are against pre-commit trees that no longer exist and
  logs in a session scratchpad outside the worktree. The quoted first error lines
  are consistent with the brief's expected failure and with the files' contents;
  nothing behavioural is claimed to have gone red, and the report says so in
  those words.
- **The 34 mutation probes in the commit message.** I did not re-run any of
  them. I ran two of my own (Finding I-1) and both came back GREEN, so the probe
  harness is working and the table's `RED (caught)` verdicts are at least
  measurable; whether each one reproduces is unverified.
- **Anything visual.** No test in this project draws a view, and I did not launch
  the app. How the radio group, the date picker, the wrapped acknowledgement and
  the days stepper actually look is the maintainer's check, and I-1 is partly
  about the fact that nothing *can* see it.
- **The rig.** The 403-even-with-bypass measurement is cited, not re-measured: the
  Docker rig must be started from the main checkout and this session is confined
  to a worktree. I did verify it is pinned inside the repository —
  `Tests/macSCPCoreTests/S3ObjectLockGatedTests.swift` sends the bypass header
  and `S3ObjectLockTests.swift:509` asserts the production path does not.
- **The full suite.** I ran six filtered suites (114 tests, all green), not
  `swift test`. The report's own green is "App 2742 run, exactly one failure,
  `ViewTestabilitySpike` … not re-measured against this task's base", and I did
  not re-measure it either.
- **Polish wording.** I read the `de` and `fr` catalogues as prose; for `pl` I
  only checked what the tests check — key coverage, resolution in all four
  locales, and format-specifier equality with the English
  (`everyTranslationKeepsTheSpecifiersOfTheEnglish` in both suites). A native
  reader should still look at the two COMPLIANCE sentences.
- **Whether 36,500 days is the right policy ceiling.** It is labelled as macSCP's
  own, which is the part I can judge. The figure is the maintainer's call.
