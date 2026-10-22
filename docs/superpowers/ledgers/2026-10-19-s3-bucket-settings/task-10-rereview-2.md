# Task 10, fix round 2 — scoped re-review

Re-reviewer, 2026-10-21. Round BASE `75bd8c50`, HEAD `a4cdf0ea` (one commit,
8 files, 301 insertions, 42 deletions). Worktree
`/Users/noidee/macSCP/.claude/worktrees/diff-view`, tree clean
(`git status --porcelain` empty) before the first probe and after the last
revert.

**Scope.** The five items the controller listed, plus anything new this fix
introduced. Not a re-review of Task 10. No subagents dispatched; nothing fixed.

The test count reconciles independently of the report: round 1's probe control
ran **91**, this round's **96**, and the diff adds exactly **5** `@Test` bodies
(`aClickOnAStaleTickIsSomethingTheSheetCanSee`,
`tickingAnAlreadyTickedBoxDoesNotRefreshTheDay`,
`aFailedReadTakesAnyAcknowledgementBack`,
`governanceOverAComplianceRetentionInForceIsStoppedAndSaysWhy`,
`onlyAComplianceRetentionStillInForceStopsGovernance`) plus one rename
(`theEnglishRefusalIsHedgedAsTheTranslationsAre` →
`theRefusalKeepsTheRuleFlatAndHedgesTheCause`), which is not a new case.
91 + 5 = 96, and the report's App figure 2754 + 5 = 2759 is consistent with it.
Nothing in the tree still names the old test name (`git grep` returns nothing).

---

## 0. The correction of round 1's own report

**Accurate, in the direction it claims.** Round 1's report said the per-file
`load` clears the tick "at its start, like the bucket model"; round 1's
*re-review* had already recorded that as false, with the direction: the per-file
model cleared at the start, the bucket model at the end of its success path. The
fix report restates it the same way round, and that is what `75bd8c50` holds —
`git show 75bd8c50:Sources/MacSCPAppKit/BucketObjectLockSheet.swift` has
`acknowledged = false` inside the second `do` block, after `objectLockDefault`
landed, while the per-file `load` had it before the first `await`.

The consequence the report claims is also real, and it is the one thing round 1
called harmless: on the bucket model a **failed** read left a tick from before
standing. (Round 1 read that as harmless because the checkbox is drawn only
after the read lands — which is still true, so nothing could be written on it;
the models disagreeing is the defect that was fixed.)

---

## 5. The asymmetric clear — **CLOSED**

Verified in the source, not in the report. Both `load`s now clear the tick
before the first `await`:

- `Sources/MacSCPAppKit/ObjectLockSheet.swift`, `load(key:bucket:via:cache:)`:
  `acknowledged = false` after `currentFailure = nil`, before the
  `cache.hasObjectLock(bucket)` call (round 1's line, unchanged).
- `Sources/MacSCPAppKit/BucketObjectLockSheet.swift`, `load(bucket:via:cache:)`:
  `acknowledged = false` in the same position; the write that used to sit after
  `objectLockDefault` is gone.

`aFailedReadTakesAnyAcknowledgementBack` covers **both** models in one body: it
builds a `FakeBucketSettings` whose `hasObjectLock` throws, ticks each model
first (so neither assertion is vacuous), loads, and asserts `!acknowledged` on
the bucket model (plus `!canSave`) and `!acknowledged` on the per-file one. Both
arms take the `catch` that returns early, so both exercise the start-clear
rather than the success path. S8 (removing the bucket start-clear) is caught by
this test; the per-file arm is additionally pinned by round 1's
`aLoadTakesAnyAcknowledgementBack` and its probe R7.

One asymmetry left, immaterial: the bucket arm asserts `!canSave`, the per-file
arm asserts no `canRun`. A failed read blocks through `lockReadFailed` anyway.

---

## 3. NEW-3, the `oldValue` guard — **CLOSED**

The line is there, `Sources/MacSCPAppKit/BucketObjectLockSheet.swift`,
`acknowledged`'s `didSet`:

```
guard acknowledged != oldValue else { return }
acknowledgedDay = acknowledged ? acknowledgementDate : nil
```

`tickingAnAlreadyTickedBoxDoesNotRefreshTheDay` distinguishes the two writes in
one body, which is the thing I was asked to check: it ticks, moves the injected
clock two days, writes `true` **again** and asserts
`activeBlockers == [.acknowledgementStale]`; then unticks and re-ticks and
asserts `canSave`. The second arm is what a repeated `true` cannot produce, so
the test separates a same-value write-back from a genuine new decision rather
than merely observing staleness.

The first-tick path is not broken, and is pinned twice: the re-tick arm above
needs the stamp to equal the day the sentence names now, and
`aTickGivenForOneDayDoesNotStandForAnother`'s
`#expect(model.canSave, "the same day, a moment later")` needs a stamp that was
taken at all. S4 (the guard removed) is caught by the new test.

One thing the guard does **not** break, which is worth saying because it is the
invariant the stale blocker rests on: `acknowledged == false` still implies
`acknowledgedDay == nil`. The only transition that sets a day is `false → true`
and the only one that clears it is `true → false`; a `false → false` write (the
unconditional clear at the top of `load`, or `days`/`mode`'s `didSet`) has
nothing to clear.

---

## 4. The refusal sentence's register — **CLOSED**

All four moved, and all four now state the rule flat and hedge which cause
applied (read out of the catalogues, not out of the report):

| locale | text |
| --- | --- |
| `en` | "The change was refused. Either a retention that is already in force cannot be shortened from macSCP, or your access key is not allowed to change it." |
| `de` | "Die Änderung wurde abgelehnt. Entweder lässt sich eine bereits geltende Aufbewahrung in macSCP nicht verkürzen, oder dein Zugangsschlüssel darf sie nicht ändern." |
| `fr` | "La modification a été refusée. Soit une rétention déjà en vigueur ne peut pas être raccourcie depuis macSCP, soit votre clé d'accès n'est pas autorisée à la modifier." |
| `pl` | "Zmiana została odrzucona. Albo obowiązującego okresu przechowywania nie można skrócić z poziomu macSCP, albo Twój klucz dostępu nie ma uprawnień do jego zmiany." |

- The hedge is gone from the rule in every one: `grep` for the three hedges the
  commit message names (`möglicherweise`/`womöglich`, `peut-être`, `być może`)
  on the four `s3.objectLock.error.refused` lines returns nothing; each carries
  a two-branch connective instead (`Either … or`, `Entweder … oder`,
  `Soit … soit`, `Albo … albo`) and names the app inside the rule clause.
- `de` addresses the user as **du** ("dein Zugangsschlüssel"), as the catalogue
  must.
- **The contradiction is gone.** The governance note two sentences up states the
  same rule flat and with the same limit — en "but not from macSCP", de "aber
  nicht in macSCP", fr "mais pas depuis macSCP", pl "ale nie z poziomu macSCP" —
  so the pair no longer asserts and hedges one fact, which is what round 1's
  ruling asked for.
- The withdrawn English is quoted **verbatim** beside `retentionRefused` and in
  the commit message, and I checked the quote against `75bd8c50` rather than
  against the report (see §Rules below): found, in both
  `en.lproj/Localizable.strings` and `ObjectLockSheet.swift`.
- `theRefusalKeepsTheRuleFlatAndHedgesTheCause` holds it: `eitherOr` and
  `flatRule` positive, `!hedgedRule` negative beside them (and `hedgedRule`
  names both the round-1 and the round-0 wording, so neither can come back),
  plus a per-locale positive. S9 (the English reverted to round 1's wording) is
  caught by it and by `theEnglishCatalogueSaysTheDefault`, which is what holds
  the Swift `english:` default and the catalogue to each other.

What the guard does **not** hold, which is NEW-5 below: for `de`, `fr` and `pl`
the only assertion is `text.contains("macSCP")`. The register — flat rule, hedged
cause — is asserted for English alone, so a translation drifting back to
"möglicherweise" would stay green. The claim "all four say the same thing" is
true in the tree today because I read the four strings, not because a test says
so.

The two figures above, with the command that produced them (run from the
worktree root, `/usr/bin/grep` because a `grep` in a Claude session is an
embedded ugrep — CLAUDE.md's measurement of 2026-10-06):

```
/usr/bin/grep -h "s3.objectLock.error.refused" Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings Sources/MacSCPAppKit/Resources/de.lproj/Localizable.strings Sources/MacSCPAppKit/Resources/fr.lproj/Localizable.strings Sources/MacSCPAppKit/Resources/pl.lproj/Localizable.strings | /usr/bin/grep -o -e "möglicherweise" -e "womöglich" -e "peut-être" -e "być może" -e "perhaps" | wc -l
```

prints `0`, and the same first stage piped into
`/usr/bin/grep -o -e "Either" -e "Entweder" -e "Soit" -e "Albo" -e "macSCP" | sort | uniq -c`
prints one each of the four connectives and `4 macSCP` — one per catalogue. Both
re-run after this paragraph was written; the paragraph quotes no catalogue text
of its own, so it cannot match itself.

---

## 2. NEW-1, the stale tick — **CLOSED**

### What the mechanism is, read off the source

`BucketObjectLockModel` is `@MainActor @Observable`
(`BucketObjectLockSheet.swift:26-28`). The pieces:

- `private(set) var refusedSaves = 0` (`:111`) — still observable; `private(set)`
  restricts the setter, not the `access(keyPath:)` the macro puts in the getter.
- `acknowledgementIsStale` (`:185-191`) opens with `_ = refusedSaves` and then
  returns `mode == .compliance && acknowledged && acknowledgedDay != acknowledgementDate`.
- `activeBlockers` is `SaveBlocker.allCases.filter { isActive($0) }`, so **every**
  read of `canSave` or `explanation` evaluates the `.acknowledgementStale` arm
  and therefore reads `refusedSaves`.
- `save()` (`:361-375`) is `guard canSave else { refusedSaves += 1; return }`.

So the claim is exact: a refused save writes an observable property that the
view's own reads depend on. And the view really does hold both reads inside one
`body` — `.disabled(!model.canSave)` at `:437` on the Save button, and
`if let why = model.explanationSentence` at `:489` inside `present`, which is a
computed property of the same `View` and is evaluated during that `body`. One
invalidation therefore greys the button **and** brings the caption in.

`complianceNotAcknowledged` was narrowed to `mode == .compliance && !acknowledged`
at the same time, so the two blockers partition rather than overlap: an unticked
box gets "Tick the box to confirm.", a stale tick gets the new sentence. Nothing
can show both.

### Does it leave a ticked box, a live Save and a silent write?

**No silent one is left.** Walking the two orderings the report names:

1. **A redraw happened after local midnight.** `canSave` is already `false`:
   the box is ticked, Save is greyed, and the caption is the stale sentence —
   which is the state round 1 called a flat self-contradiction, and it now reads
   as an explanation instead of as an instruction to redo what was just done.
2. **No redraw since midnight.** The sheet is still drawn as it was: ticked box,
   Save live, no caption. The click refuses, increments `refusedSaves`,
   invalidates `body`, and ordering 1 is what the person then sees. The write
   does not happen, but the click is not silent: the button greys and the
   sentence appears in the same redraw.

I looked for a state where the caption cannot arrive and found none: the
checkbox is drawn only inside `present`'s `else` branch, which requires
`bucketLock == .present`, `currentFailure == nil` and `currentRead == true` —
the same branch that draws `explanationSentence` four lines below the form. A
box on screen and no place for the caption is not reachable.

Round 1's objection is answered on its own terms, and the tick no longer
disappears under the person's hands: `aTickGivenForOneDayDoesNotStandForAnother`
now asserts `model.acknowledged` **after** the refused save, with the stale
sentence on both sides of it.

### Does the test prove observability, or exercise it?

**It proves the link it tests, and not the wiring around it — in that order.**

`aClickOnAStaleTickIsSomethingTheSheetCanSee` wraps `_ = model.canSave` in
`withObservationTracking`, which is the same registration SwiftUI performs while
evaluating a body, then calls `save()` and asserts `redraw.raised` as well as
`refusedSaves == before + 1`. That is a real proof of the property under review:
*a refused save invalidates an observation that read `canSave`*. It is not a
tautology — the two halves of the mechanism are separately sensitive, and the
implementer's own probes show it: S6 (the `refusedSaves += 1` removed) and S7
(the `_ = refusedSaves` removed) are each RED, caught by this test. The second
is the one that matters, because `_ = refusedSaves` is a read whose only purpose
is the dependency, exactly the kind of line a later tidy-up deletes.

What it does **not** prove is that the sheet performs that read. No source scan
pins `.disabled(!model.canSave)` or `model.explanationSentence` —
`RigidControlScanTests` counts `CheckboxRow`/`RadioChoice` sites in this file,
not the button's `disabled` expression, and the file's own scans
(`theSheetSavesAndLoadsTheBucketItWasOpenedFor`,
`theAcknowledgementIsAWrappingCheckboxRow`,
`everyKeyTheSheetUsesIsOneTheCatalogueChecksCover`) do not reach it. I verified
the two reads by reading `:437` and `:489`; a rewiring of either would leave
this test green while the sheet went blind again. That is the honest limit of
it, and it is the same limit every other guard on this sheet has — nothing here
renders a view.

---

## 1. NEW-2, the COMPLIANCE-in-force blocker — **CLOSED**

`RunBlocker.complianceInForce` reads one private computed property:

```
private var weakensAComplianceRetentionInForce: Bool {
    guard focus == .retention, mode == .governance, let held = current?.retention else {
        return false
    }
    return held.mode == .compliance && held.retainUntil > now()
}
```

Three claimed boundaries, each against a test that distinguishes it — and each
against a probe, two of them mine:

| boundary | the test arm that distinguishes it | probe |
| --- | --- | --- |
| only while the held date is still ahead | `onlyAComplianceRetentionStillInForceStopsGovernance`'s `expired`: held until `Self.yesterday` (`now − 86_400`) with `retainUntil` still at `newYear`, so no other blocker is active; asserts `!activeBlockers.contains(.complianceInForce)` **and** `canRun` | P3 (= S2 verbatim), below |
| GOVERNANCE over COMPLIANCE only | the same test's `extend` (COMPLIANCE over COMPLIANCE, acknowledged → `canRun`) and `governanceHeld` (GOVERNANCE over an in-force GOVERNANCE retention → `canRun`) | P1 (= S3 verbatim), below |
| not for a legal hold | the same test's `hold`: `focus: .legalHold`, an in-force COMPLIANCE retention in `current`, `legalHold = true` → `canRun` | P2, mine, below |

And the positive end of it is
`governanceOverAComplianceRetentionInForceIsStoppedAndSaysWhy`:
`activeBlockers == [.complianceInForce]` (alone, so no other blocker is doing
the work), `!canRun`, `explanation?.key == complianceInForceLine.key`, and
`probe.retentionWrites.isEmpty` after `run` — the attempt is stopped, not sent.
`#expect(model.mode == .governance)` in the same body is what pins the ruling
that the starting mode is **not** seeded from the file's.

The sentence exists in four catalogues (`s3.objectLock.blocked.complianceInForce`
in `en`, `de`, `fr`, `pl`), is in `ObjectLockModel.fixedLines` — which is what
`everyLineResolvesInAllFourLocales` walks, so a missing translation is caught —
carries no placeholder, and needs no second person in `de`.

It names no tech-stack internals, but **by reading, not by a guard**: the
per-file sheet's jargon scan,
`theComplianceWordsSayWhatCannotBeUndoneInPlainEnglish`, checks only
`acknowledgementSentence` and `complianceWarningLine`, not every line the sheet
shows. The bucket sheet has the all-lines version
(`theDefaultsWordsNameNoStoreMechanics`, over `Self.everyLine()`), which does
cover the new `staleLine`. That gap predates this round; I note it because the
new sentence is the kind of text it exists for.

### The sweep's fourth input

- **512 states, counted from the enums, not written down.**
  `inNoStateDoesRunWriteWhatCanRunRefused` multiplies
  `focuses * locks * currencies * modes * days * tickAndHold * heldStates` with
  every factor read from `.allCases.count`, and asserts
  `scenarios.count == expectedCount`. 2·4·2·2·2·4·2 = 512, which is 256 × the
  new input's two arms.
- **The `nothing` arm is still populated.** `model(for:)` maps
  `Held.nothing` to `nil` and builds `Current(retention: nil, legalHold: false)`
  — the pre-fix behaviour — so the 256 old states are still run unchanged, and
  the new ones sit beside them rather than replacing them.
- **The new assertion has a reachable positive, and the oracle forces it.** The
  assertion is `for write in probe.retentionWrites where write.retention.mode == .governance { #expect(scenario.held == .nothing) }`.
  The state `focus: .retention, lock: .present, current: .read, mode: .governance,
  day: .future, held: .nothing` has `mayWrite == true`, so the adjacent
  `#expect(allowed == scenario.mayWrite)` **requires** that a GOVERNANCE write
  happen there: the loop body is entered by construction, not by luck. Its
  negative arm — a GOVERNANCE write with `held == .complianceInForce` — is
  reachable only under a mutation, and both mutations I ran make the sweep red.
  Worth stating plainly, though: in each case the oracle line two lines up goes
  red as well, so this assertion is the rule said a second time from the written
  side rather than the sole guard — the same construction as the COMPLIANCE
  block directly beneath it.
- **The blocker is reachable alone through the sweep.**
  `everyBlockerCanBeTheOnlyReasonRunIsOff` excludes only `applying` from its
  expected set, so `complianceInForce` must appear as a lone blocker in some
  state for that test to pass; the implementer's S1 (the blocker neutralised) is
  caught by it. This is the per-file sheet's counterpart of the exclusion the
  bucket sheet's version carries, and here nothing new was excluded.

---

## Project rules this diff is bound by

**A correction quotes verbatim what it withdraws.** Checked against the text at
`75bd8c50`, not against the report's transcription, and not line-oriented (the
comments wrap, so a line `grep -F` is the wrong tool here for the same reason
`grep -c` is the wrong tool for an occurrence count). The script is
`checkquotes2.py` in this session's scratchpad: it pulls every `verbatim: "…"`
out of the working tree's own text (extracted, not retyped — the tree is clean
and equals `a4cdf0ea`), strips `//` and `///` prefixes from both sides,
collapses whitespace, normalises curly quotes, and looks for each quote in
`git show 75bd8c50:<file>` dumps of the five files that could hold it. Run from
the worktree root with `python3 -I`, it printed **7 quotes extracted, 0
missing**. Three of the seven are this round's:

| withdrawn in | quote | found at `75bd8c50` in |
| --- | --- | --- |
| `ObjectLockLines.retentionRefused` | "The change was refused. Perhaps a retention that is already in force cannot be shortened, or your access key is not allowed to change it." | `en.lproj/Localizable.strings` **and** `ObjectLockSheet.swift` |
| `BucketObjectLockModel.save` | "A tick for another day is taken back here, where the person sees the box clear and the sentence name the day it names now." | `BucketObjectLockSheet.swift` |
| `ObjectLockSheetTests.Scenario` (the sweep's comment) | "every combination of them with the file's own current values held empty (`model(for:)` always builds `Current(retention: nil, legalHold: false)`)" | `ObjectLockSheetTests.swift` |

The other four are round 1's, carried forward untouched and still found at this
round's base, so nothing earlier was erased in passing. The sweep comment's
round-1 correction is kept **below** the round-2 one, so the row now shows two
generations of its own history rather than one.

Two rewrites are **not** quoted, both test doc comments: the clause "the stale
tick is taken back on the click, visibly, and nothing is sent." in
`aTickGivenForOneDayDoesNotStandForAnother`, and the whole body of the renamed
refusal test. CLAUDE.md scopes the quoting rule to the measurement record
(`docs/BACKLOG.md` rows, the specs and plans under `docs/superpowers/`, the SDD
ledgers), and a test's doc comment is not in it; round 1 took the same reading,
and both replacements describe in prose what they changed and why. Not a breach
— and the round quoted three source comments anyway, which is above what the
rule asks.

**A negative check needs a positive beside it.** Every new negative has one in
the same body: `!hedgedRule` beside `eitherOr` and `flatRule` and the per-locale
`namesTheApp`; `probe.retentionWrites.isEmpty` beside
`explanation?.key == complianceInForceLine.key` and `activeBlockers == […]`;
`!expired.activeBlockers.contains(.complianceInForce)` beside `expired.canRun`
and the two `canRun` positives either side of it; `!model.canSave` in
`tickingAnAlreadyTickedBoxDoesNotRefreshTheDay` beside
`activeBlockers == [.acknowledgementStale]` and the closing `canSave`;
`!acknowledged` in `aFailedReadTakesAnyAcknowledgementBack` beside a tick that
was set `true` first, which is what makes it non-vacuous. The two equality
assertions on `activeBlockers` are the strongest shape of all — they fail when
anything is added as well as when the expected case disappears.

**A number or an enumeration in a comment is a claim to verify.** Three
enumerations are new, all three check out:
`everyBlockerCanBeTheOnlyReasonSavingIsOff`'s comment names
`aSecondSaveWhileOneIsInFlightSendsNothing` (exists,
`BucketObjectLockSheetTests.swift`) and `aTickGivenForOneDayDoesNotStandForAnother`
(exists, and asserts `activeBlockers == [.acknowledgementStale]`, i.e. really
alone) for the two cases it excludes from its expected set; the sweep comment
names `everyBlockerCanBeTheOnlyReasonRunIsOff` (exists) and keeps round 1's
three loading tests, all of which still exist. The one new comment that does
make a false claim about other code is NEW-4 below. No new comment carries a
count.

**No hardcoded display string; four catalogues; `du`-form.** The two new lines
(`complianceInForceLine`, `staleLine`) are `CatalogueLine`s with an `english:`
default beside a key present in all four catalogues, which is this project's
existing construction; nothing is drawn from a literal. The English phrases
inside the tests ("either", "cannot be shortened from macscp", "macSCP") are
assertions *about* catalogue text. `de` is `du` throughout the two new strings
and the rewritten refusal ("dein Zugangsschlüssel", "Nimm es weg und setze es
erneut").

**No wall-clock ceiling; a hang bound is `.timeLimit`.** No new test asserts
elapsed time. The three clock-moving tests move an injected `Clock` instead of
sleeping, and the only `.timeLimit` in scope is on the two pre-existing
in-flight tests. `@unchecked Sendable` on the test-local `Clock` and `RedrawFlag`
is house style here.

**`#expect` prints the source text of its expression.** Nothing secret is in
play; the round computes its Bools into named constants before the expectation
throughout, which is the construction the rule asks for.

---

## The four deferred findings — untouched?

| deferred | verdict |
| --- | --- |
| `acknowledged`'s writers beyond the one-line guard | **Untouched.** The per-file `ObjectLockModel.acknowledged` is still a bare `var` with no `didSet` at all (`ObjectLockSheet.swift:279`); the bucket one gained the guard and nothing else. `git grep -n "acknowledged = true" -- Sources` still returns nothing, so no production code ticks the box. |
| the bucket-creation promise in `s3.objectLock.notEnabledOnThisBucket` | **Untouched.** `en` still reads "it can be chosen when a bucket is created" (`en.lproj:497`); the key is not in this diff for any of the four. |
| the German date phrasing | **Untouched.** The `de` catalogue's only edits in this diff are `s3.objectLock.error.refused` and the new `…blocked.acknowledgementStale`; neither acknowledgement sentence changed. |
| the 36,500-day figure | **Untouched.** `static let dayRange = 1...36_500` (`BucketObjectLockSheet.swift:68`); the comment around it is unchanged this round. |

---

## NEW findings

### NEW-4 (Nit). `refusedSaves`' doc comment claims to know who reads it, and a test reads it too (`BucketObjectLockSheet.swift:111`)

```
/// How many saves were refused. Only the stale blocker reads it; see there.
private(set) var refusedSaves = 0
```

`aClickOnAStaleTickIsSomethingTheSheetCanSee` reads it twice
(`BucketObjectLockSheetTests.swift:163` and `:169`). Counted with
`git grep -n "refusedSaves" -- Sources Tests`, which prints five lines: the
declaration, the comment above `acknowledgementIsStale`, the `_ = refusedSaves`
read, the `+= 1`, and the two test reads (two of those five lines are the test's).

This is CLAUDE.md's "comments that describe other code", in its enumeration
form: "only X reads it" is a claim about the rest of the tree, and it sounds
plausible exactly while you write it. It is true of `Sources`, and the fix is
one word ("in production" / "no other production code reads it"). Nit, not
Minor: nothing behaves differently, and the comment's intent — that this counter
is not a fact the sheet displays — survives. Flagging it because the same
sentence, read literally, would tell the next contributor that removing the
test's reads costs nothing.

### NEW-5 (Minor). The refusal's register is pinned in English only, so three catalogues can drift back to hedging the rule (`ObjectLockSheetTests.theRefusalKeepsTheRuleFlatAndHedgesTheCause`)

The per-locale loop asserts one thing, `text.contains("macSCP")`. Everything
that makes this round's ruling — flat rule, hedge on the cause — is asserted on
`en` alone. A `de` string reverted to "Möglicherweise lässt sich eine bereits
geltende Aufbewahrung in macSCP nicht verkürzen …" satisfies the loop. So the
report's claim that "de, fr and pl … moved with it" is true (I read the four
strings, and the hedge count is 0 — see §4) but not guarded.

The loop also has no iteration count, unlike
`aDayIsWrittenInTheReadersLanguageAndWithoutATime`, which carries
`expected.count == Self.locales.count` for exactly this reason. An emptied
`Self.locales` cannot make the test read as satisfied — the English positives
below it are in the same body — but it would silently drop the per-locale arm.

Cheapest close, in the shape the file already uses: per locale, assert the
two-branch connective positively from a small per-locale table (`Either`,
`Entweder`, `Soit`, `Albo`) and the absence of that language's hedge beside it,
with `table.count == Self.locales.count`. Minor: the risk is a future
translation edit, not today's text.

### NEW-6 (Minor, pre-existing, now asymmetric). The per-file sheet still has the silent clock-crossing click NEW-1 was opened for, and no counter (`ObjectLockModel.isActive(.dateNotInFuture)`, `ObjectLockModel.run`)

`dateNotInFuture` is `focus == .retention && retainUntil <= now()`, and `now()`
is not observable, so it is the same shape as the stale tick: a sheet drawn
while the chosen date was still ahead keeps a live "Set Retention" after the
date passes. `run()` is a bare `guard canRun else { return }` — no counter,
nothing observable is written — so that click writes nothing **and** changes
nothing the sheet watches. No caption appears, the button stays live, and a
second click does the same. That is precisely the state round 1 called out on
the bucket model, and this round fixed it there, in `save()`, with
`refusedSaves`.

Two things make it a finding rather than a complaint about scope: the remedy
now exists four hundred lines away and costs one counter plus one `_ = ` read,
and the round's own new blocker is clock-dependent in the same way (`held.retainUntil > now()`
— though that one fails safe: an expiring COMPLIANCE retention leaves the button
greyed and the sentence standing until something else redraws, which errs toward
refusing).

Two things keep it Minor: it is **pre-existing** — `dateNotInFuture` has read
the clock since the task commit, so this round neither introduced nor worsened
it — and reaching it means picking a date minutes away and then waiting past it
with the sheet open. Nothing irreversible happens; the write is refused, not
mis-sent.

---

## Probes I ran myself

Three, each through `scripts/mutation-probe` on the committed tree (clean before
the first and after the last; `.superpowers/` is gitignored, so this report does
not dirty it). Each control run printed
`control: 96 test(s) ran, 0 pre-existing failures` — a green run of the filtered
scope, measured by me three times, and 91 + 5 = 96 against round 1's control.

| probe | plant | source | outcome |
| --- | --- | --- | --- |
| P1 | the blocker's **mode condition dropped** (`guard focus == .retention, let held`), so COMPLIANCE over COMPLIANCE is blocked too — the widening the controller named as most likely to come back GREEN | S3, extracted verbatim from `a4cdf0ea`'s message, not retyped | **RED — 96 test(s) ran**, caught by `inNoStateDoesRunWriteWhatCanRunRefused()` and `onlyAComplianceRetentionStillInForceStopsGovernance()` |
| P2 | the blocker's **focus condition dropped** (`guard mode == .governance, let held`), so a legal hold is stopped by a retention — **not one of the implementer's 13** | mine | **RED — 96 test(s) ran**, caught by the same two |
| P3 | the blocker's **date condition dropped** (`return held.mode == .compliance`), so an expired COMPLIANCE retention still blocks | S2, extracted verbatim | **RED — 96 test(s) ran**, caught by `onlyAComplianceRetentionStillInForceStopsGovernance()` **only** |

None printed `BUILD FAILED`, `PLANT CHANGED NOTHING` or `RUN INCOMPLETE`; each
printed its plant's diffstat (`1 file changed, 1 insertion(+), 1 deletion(-)`),
so each plant landed, and each reverted.

**The widening is caught.** That answers the question it was asked for: the
blocker is not too broad, and a too-broad blocker does not survive here, because
the sweep's oracle states the rule from the other end and `extend`/`governanceHeld`
assert the two writes that must still be allowed.

**P3's narrower catch is worth recording**, because it says exactly how much the
sweep buys. The sweep's `Held.complianceInForce` is always *in force*
(`retainUntil: Self.newYear`, ahead of `Self.now`), so dropping the date
condition changes nothing in any of the 512 states; only
`onlyAComplianceRetentionStillInForceStopsGovernance`'s `expired` arm
distinguishes it. The expiry boundary therefore rests on **one** arm of **one**
test — correct, measured, and the thinnest of the three boundaries. A fifth
`Held` arm (`complianceExpired`) would put it in the sweep as well; I am not
opening a finding for it, since the arm that exists is a real positive
(`expired.canRun`) and P3 proves it sensitive.

---

## Addendum to §2 — the detail that decides whether NEW-1's mechanism works in the ordering the test does *not* exercise

The test tracks a read of `canSave` taken **after** the clock moved, so it reads
`false`. The ordering that matters in the app is the other one: the body was
evaluated **before** midnight, when `canSave` was `true`. The mechanism survives
that only because `_ = refusedSaves` sits *above* the condition rather than
inside it:

```
private var acknowledgementIsStale: Bool {
    _ = refusedSaves
    return mode == .compliance && acknowledged && acknowledgedDay != acknowledgementDate
}
```

`activeBlockers` evaluates every case of `SaveBlocker.allCases`, so this property
is read on every `canSave`, and the dependency is registered **unconditionally** —
no `&&` can short-circuit past it. Had the count been folded into the boolean
(`… && refusedSaves >= 0`), a pre-midnight body with `mode != .compliance`, or
with the tick not yet given, would never have registered it, and the stale click
would still be invisible in exactly the ordering NEW-1 described. It is written
the right way round, and that is what makes the test's ordering immaterial.

---

## Addendum to §1 — one thing there that is held by absence

"The starting mode is not seeded from the file's, as ruled" is true of the code —
`ObjectLockModel.load` assigns `retainUntil` and `legalHold` and never `mode` —
but no test would go red if a seeding line were added. The new test's
`#expect(model.mode == .governance)` is on a freshly built model, not on a loaded
one, and `aLoadTakesAnyAcknowledgementBack`'s
`#expect(model.mode == .compliance, "the person's choice of mode is not the read's to change")`
runs against a probe with **no** retention to seed from, so its `if let held`
arm is never entered. A ruling held by the absence of a line is the weakest
shape there is; one line in that existing test — load a COMPLIANCE-held file and
assert the mode is still what the person chose — would close it. Not opened as a
finding, because the ruling was the controller's and the code follows it; noted
so that it is a decision rather than an oversight.

---

## Verdict per item

| item | verdict |
| --- | --- |
| 1 — NEW-2, the COMPLIANCE-in-force blocker (Important) | **CLOSED.** All three boundaries pinned by arms that distinguish them; three probes of mine RED over 96 tests, including the widening named as the likeliest GREEN. |
| 2 — NEW-1, the stale tick | **CLOSED.** The mechanism does what it claims, no ticked-box/live-Save/silent-write state is left, and the test proves the invalidation link (not the view's wiring, which nothing here pins). |
| 3 — NEW-3, the `oldValue` guard | **CLOSED.** Line present, repeated `true` and a real re-tick distinguished in one body, first-tick path pinned twice. |
| 4 — the refusal sentence's register | **CLOSED.** Four catalogues flat on the rule and hedged on the cause, withdrawn English quoted verbatim, no contradiction with the governance note left. Guarded in English only (NEW-5). |
| 5 — the asymmetric clear | **CLOSED.** Both `load`s clear before the first `await`, verified in the source; one test covers both models with both arms non-vacuous. |
| round 1's report correction | **Accurate** in the direction it claims, and the consequence it names (a failed bucket read left a tick standing) is real. |

Deferred four: **all untouched**, confirmed one by one above.

New: **NEW-4 (Nit)**, **NEW-5 (Minor)**, **NEW-6 (Minor, pre-existing)**. No new
Important, no Critical.

## Can the gate close?

**Yes.** The Important finding this round existed for is closed and I measured it
myself rather than taking the report's word: the widening plant the controller
singled out is RED, and so are the two other boundary plants. The three new
findings are a comment's over-claim, a guard that pins one language of four, and
a pre-existing sibling of NEW-1 on the other sheet — none of them writes
anything wrong, and the COMPLIANCE path is more conservative after this round
than before it in every direction I could find. My recommendation is that the
gate closes with NEW-4, NEW-5 and NEW-6 recorded by name, NEW-6 explicitly as
pre-existing so that it is not read as a regression of this round.

## What I could not check

- **S1, S4–S8, S10–S13.** I ran three probes (two verbatim from the commit, one
  of my own). The ones I would run next are S7 (`_ = refusedSaves` removed) and
  S4, because they are the two single lines the whole of NEW-1 and NEW-3 rest on;
  I took their outcomes from the commit message.
- **The full suite.** Not run by me. The report's "Core 5074 passed; App 2759
  run, one failure, `ViewTestabilitySpike`" is unverified here; 2754 + 5 = 2759
  reconciles with the five new tests, and `ViewTestabilitySpike` is the
  pre-existing failure both earlier rounds recorded.
- **Anything drawn.** No view is rendered by any test here and I did not launch
  the app. §2's two orderings are derived from `@Observable`'s invalidation rule
  and from reading `:437`/`:489`, not observed on screen. The conditional colour
  of the mode line and the conditional drawing of the checkbox remain held by
  nothing, as they were.
- **The rig.** Not contacted — it must be started from the main checkout and
  this session is confined to a worktree. Whether the store refuses a
  COMPLIANCE-to-GOVERNANCE change still rests on S3's documented semantics and
  `S3BucketSettings.setRetention`'s doc comment, which is what the commit and the
  report both say, and is the same footing the refusal sentence's hedge stands on.
- **Polish, French and German wording as prose.** I checked that each of the four
  refusal sentences states the rule flat, names the app and carries a two-branch
  connective, and that `de` is `du`. Whether `in macSCP` / `depuis macSCP` /
  `z poziomu macSCP` read equally naturally is a native reader's call, not mine.

---

## Green runs I made myself

Three, all from the worktree root on the committed tree:

1. `swift test --filter 'ObjectLockSheetTests|BucketObjectLockSheetTests|GermanAddressFormTests|PluralCatalogTests|RigidControlScanTests|BoundedViewCoverageTests'`
   → `Test run with 130 tests in 5 suites passed after 2.301 seconds`.
2. `swift test --filter 'GermanAddressFormTests|PluralCatalogTests'`
   → `Test run with 11 tests in 1 suite passed after 1.117 seconds`, the suite
   being `Plural catalogs`.
3. `swift test --filter 'GermanAddressForm'`
   → `Test run with 5 tests in 1 suite passed after 0.021 seconds`, the suite
   being `German address form`.

Plus the three `mutation-probe` controls, each
`96 test(s) ran, 0 pre-existing failures`.

**Why three runs and not one, and a correction to round 1's report.** Run 2 names
two suites and ran **one**: `GermanAddressFormTests` lives in the `macSCPCoreTests`
target and did not run under that filter, which is also why run 1 reports 5 suites
where its regex names six candidates. It does run on its own (run 3), under a
filter that is not the type name — that is the mechanism I did not chase further.
The consequence for the record: round 1's re-review wrote
"`GermanAddressFormTests` is in the green run below" about a run of
`137 tests in 6 suites`, derived there as 114 + 12 new + 11 plural-catalogue
tests. That derivation leaves no room for this suite's **5** tests (137 + 5 =
142), so the `du`-form guard was **not** in round 1's green run, and that
sentence was false of it. It is in mine, run 3, and it passes with the German
catalogue as this round leaves it.
