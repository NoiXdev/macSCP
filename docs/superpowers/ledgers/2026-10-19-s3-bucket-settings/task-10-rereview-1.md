# Task 10, fix round 1 — scoped re-review

Re-reviewer, 2026-10-21. Round BASE `9bc01f3a`, HEAD `75bd8c50` (one commit, 9
files, 335 insertions). Task commit `7afd772f`; the commits between it and the
round BASE are the controller's documentation commits and touch no source —
measured, not assumed: `git diff --stat 7afd772f 9bc01f3a` prints two files,
`docs/BACKLOG.md` (1 line) and `docs/superpowers/plans/2026-10-19-s3-bucket-settings.md`
(244 lines added), so `75bd8c50`'s 9 files are the whole source delta since the
task commit.

Worktree `/Users/noidee/macSCP/.claude/worktrees/diff-view`, tree clean before
and after every probe (`git status --porcelain` empty; checked before the first
probe and after the last revert).

**Scope.** Whether each of the 13 findings is closed, and whether the fix
introduced anything new. Not a re-review of Task 10 as a whole. No subagents
dispatched; nothing fixed.

---

## 1. Probes I ran myself

Three, each through `scripts/mutation-probe` on the committed tree, with the
`--apply` taken verbatim from `75bd8c50`'s commit message (copied out of the
message, not retyped):

| probe | plant | control | outcome |
| --- | --- | --- | --- |
| R1 | COMPLIANCE's `modeDetailLine` returns `ObjectLockLines.governanceDetail` | `control: 91 test(s) ran, 0 pre-existing failures` | **RED — 91 test(s) ran**, caught by `ObjectLockSheetTests/choosingComplianceShowsTheWarningAndGovernanceDoesNot()` |
| R2 | the warning's `Text` deleted from `retentionForm` (`1 file changed, 6 deletions(-)` — not a silent no-op) | `control: 91 test(s) ran, 0 pre-existing failures` | **RED — 91 test(s) ran**, caught by `ObjectLockSheetTests/theRetentionFormDrawsTheLineUnderTheModeChoice()` |
| R5 | GOVERNANCE's `modeDetailLine` returns `Self.complianceWarningLine` | `control: 91 test(s) ran, 0 pre-existing failures` | **RED — 91 test(s) ran**, caught by `ObjectLockSheetTests/choosingComplianceShowsTheWarningAndGovernanceDoesNot()` |

None reported `BUILD FAILED`; each printed its plant's diffstat, so each plant
landed. R1 and R2 are the two probes that came back GREEN over 79 tests on the
pre-fix tree in the task review; both are RED now. R5 is the positive arm.

The test count reconciles independently of the report: 79 → 91 is 12 tests, and
the diff adds exactly 12 `@Test func` bodies (8 in `ObjectLockSheetTests`, 4 in
`BucketObjectLockSheetTests`, plus one rename that is not a new case). The
report's whole-suite figure 2754 is the review's 2742 + 12, consistent but not
re-measured by me.

I did not run R3, R4 or R6–R13.

---

## 2. I-1 — the COMPLIANCE warning

**CLOSED.**

The hole the review measured was that every test named the constant
`complianceWarningLine` while the form reads `modeDetailLine`. The new guards do
not name a second constant one step further out; the chain is closed at both
links, and each link is a positive check:

- **Identity, by `key`, both arms reachable.**
  `choosingComplianceShowsTheWarningAndGovernanceDoesNot` (one per sheet) reads
  `model.modeDetailLine?.key` after setting `mode = .compliance` and again after
  `.governance`, and compares against `ObjectLockModel.complianceWarningLine.key`
  and `ObjectLockLines.governanceDetail.key` — both derived from the owning type,
  no literal. The third expectation,
  `shownForCompliance != shownForGovernance`, is what makes a line that answered
  the warning for every mode red; R5 confirms it empirically.
- **The form reads that property.** `theRetentionFormDrawsTheLineUnderTheModeChoice`
  `#require`s the `retentionForm` range, bounds the region at
  `legalHoldForm`, and asserts the body contains `model.modeDetailLine`; then it
  `#require`s `present` and asserts it names `retentionForm` and `legalHoldForm`.
  Entirely positive — no `!contains` anywhere in the new scans — so a wrong span
  fails loudly rather than passing silently. R2 confirms it.
- **The legal-hold sheet.** `theLegalHoldSheetShowsNoModeLine` asserts
  `modeDetailLine == nil` for that focus and `!= nil` for the retention focus:
  the negative and its positive in one body.

The bucket default has the same pair (`choosingComplianceShowsTheWarningAndGovernanceDoesNot`,
`theFormDrawsTheLineUnderTheModeChoice`), which the review expected to be needed
and did not measure. The report says R3/R4 are RED there; I did not re-run them.

Two observations, neither a finding:

1. The bucket scan's span is the **rest of the file**
   (`String(source[form.upperBound...])`), where the per-file scan bounds its
   region between two declarations. `private var form` is the last declaration in
   `BucketObjectLockSheet.swift` today (it ends at the file's close, and
   `modeDetailLine` appears at three places in the file: the property, `lines`,
   and the one `Text` in `form`), so the span is exactly the form right now. It
   stops being so the moment anything is appended to that file.
2. The scans assert `body.contains("model.modeDetailLine")` and
   `body.contains(".text")` as two independent `contains`, not as one adjacency,
   so a form holding both anywhere would satisfy them. Both are positive, so this
   is looseness, not staleness. And `"model.modeDetailLine"` is a spelled symbol
   (CLAUDE.md's "a guard that spells a symbol it could read instead") — a rename
   turns these red rather than silent, which is the acceptable side of that rule
   and the same shape as the existing `theSheetIsOpenedAndRunForTheFileThatWasChosen`.

What still holds nothing, and is outside I-1 as the review wrote it: the
*conditionality of the colour* (`model.mode == .compliance ? .red : .secondary`)
and the fact that the acknowledgement checkbox is drawn only in COMPLIANCE
(`if model.mode == .compliance` in `retentionForm`). Noted, not opened as a
finding — the review's I-1 asked for the line's identity and the form's reading
of it, and it got both.

---

## 3. I-2 — the governance note

**CLOSED.**

All four catalogues moved together, and all four now say the same thing as `en`:

| locale | text |
| --- | --- |
| `en` | "Someone with the right permission can shorten or remove a governance retention, but not from macSCP." |
| `de` | "Jemand mit der passenden Berechtigung kann eine Governance-Aufbewahrung verkürzen oder aufheben, aber nicht in macSCP." |
| `fr` | "Une personne disposant de l'autorisation nécessaire peut raccourcir ou supprimer une rétention de gouvernance, mais pas depuis macSCP." |
| `pl` | "Osoba z odpowiednimi uprawnieniami może skrócić lub usunąć okres przechowywania w trybie Governance, ale nie z poziomu macSCP." |

The fact is kept in all four ("with the right permission" / "mit der passenden
Berechtigung" / "disposant de l'autorisation nécessaire" / "z odpowiednimi
uprawnieniami"), and the promise is gone: "still" / "weiterhin" / "encore" /
"nadal" is removed from every one of them, and each adds the limit naming the
app. The three translations are not more hedged than `en` and not less; the
limit clause is a flat statement in all four, as it is in `en`. No second-person
address, so the `du`-form question does not arise here.

`theGovernanceNoteSaysItCannotBeLiftedFromHere` holds it: a per-locale positive
(`namesTheApp`) across all four, plus the English negative `!promises`
("still") beside two positives (`limit`, `fact`). The Bools are computed before
the expectation, as CLAUDE.md asks. The locale loop has no iteration count, but
the English assertions below it are positives in the same body, so an emptied
`Self.locales` cannot make this read as satisfied.

---

## 4. The refusal sentence — ruling on the argument

**M-1: CLOSED on what it asked for; the argument is accepted in part.**

The new `en`: "The change was refused. Perhaps a retention that is already in
force cannot be shortened, or your access key is not allowed to change it."

What M-1 actually required was that the four agree and that `en` not assert more
than the measurement supports. Both are now true: all four hedge, and `en` is no
longer the outlier. `theEnglishRefusalIsHedgedAsTheTranslationsAre` pins
"perhaps" (positive) and the absence of the old flat phrase (negative beside
it), and de/fr/pl are untouched.

**On the implementer's reason.** I checked it rather than took it. The rig
measurement in `Tests/macSCPCoreTests/S3ObjectLockGatedTests.swift` is about
versioned **DELETE**s (`bypassStatus == 204` for GOVERNANCE), not about a
refused `setRetention`; and `S3BucketSettings.setRetention`'s doc comment states
"Shortening a GOVERNANCE retention needs a bypass header this call does not
send, so the store refuses it" **without** a measured-on date, where the
sentence beside it about a COMPLIANCE delete does carry "measured 2026-10-19".
So "a refused `setRetention` has not been measured on the rig" is accurate as
written. The claim about *which* of two causes produced a given refusal is
genuinely not knowable from the answer — `ObjectLockLines.message(for:during:)`
maps both `RemoteFSError.permissionDenied` and `.authenticationFailed` to this
one sentence during `.applyingRetention`, so the sentence really is standing in
for several causes. **Accepted on the attribution.**

**Where I do not follow it.** The wording moves the hedge onto the store rule
("Perhaps a retention … cannot be shortened") rather than onto the attribution,
and the same round's I-2 fix states that same rule flatly, two sentences up the
same sheet ("… but not from macSCP"). So the pair this round rewrote now asserts
and hedges one fact. The honest register the argument describes would be to keep
the rule flat and hedge which cause applied — "A retention already in force
cannot be shortened from macSCP, and your access key may also not be allowed to
change it" is the same information with the uncertainty where the uncertainty is.
Nothing here is false, so I am not opening a finding; I am recording that the
register of the two sentences disagrees and that one of them should move if the
maintainer wants the sheet to read as one voice.

The review's other half of M-1 — "it stops one sentence short of useful: it names
two possible causes and no next step" — is **not closed**, and the report says so
plainly ("I did not add one"). See NEW-2, which is the same sentence from a third
end: the enumeration of two causes is now demonstrably incomplete.

---

## 5. The seven Minor in scope

Mapping first, since the report numbers them 1–7 and the review lettered them:
1 = M-7, 2 = M-11, 3 = M-8, 4 = M-3, 5 = M-4, 6 = M-5, 7 = M-9.

### M-7 — `ObjectLockModel.load` did not clear `acknowledged`. CLOSED.

`load` now sets `acknowledged = false`, and the review's second option (a line
saying why) is there as well. `aLoadTakesAnyAcknowledgementBack` says which,
and adds two expectations the review did not ask for and that are right to have:
`mode == .compliance` after the read ("the person's choice of mode is not the
read's to change") and `!canRun`. R7 is the implementer's probe for it.

Two notes. The placement is **not** symmetric with the bucket model, contrary to
the fix report's sentence "at its start, like the bucket model":
`ObjectLockModel.load` clears at its start, before the first `await`, so a failed
read clears it too; `BucketObjectLockModel.load` clears at the end of its
success path (after `objectLockDefault` lands), so a failed read leaves it. The
committed comment claims only that the bucket default's `load` also clears it,
which is true, so the code and the commit message are right and the fix report's
one sentence is not. The remaining asymmetry is harmless (both sheets build the
checkbox only after the read has landed) but it is still an asymmetry, which is
what M-7 was about.

### M-11 — the acknowledged sentence drifted with the clock. CLOSED (and see NEW-1).

The review's own prescription here was "**Fix:** none needed", with the
freeze-and-clear design offered only "if the maintainer wants the sentence to be
a fixed statement". The round implemented it unasked. What it does:
`acknowledgementDate` is now `startOfDay(now() + days)`, rendered through the new
`ObjectLockDates.dayText` (`.long` date, `time: .omitted`); `acknowledgedDay` is
captured in `acknowledged`'s `didSet`; and `complianceNotAcknowledged` is active
unless `acknowledged && acknowledgedDay == acknowledgementDate`.

The substance is sound, and I checked the thing most likely to be wrong: the
flooring to `startOfDay` does **not** make the sentence false. A file added now
with a 30-day default really expires at an instant on day *now+30*, and
`startOfDay` keeps the calendar day, so the day the sentence names is the day of
expiry; only the internal `Date` used for the comparison is floored, which is
exactly what the comparison wants. `aDayIsWrittenInTheReadersLanguageAndWithoutATime`
pins the month name in all four locales (positive) and the absence of a `:`
(negative beside it), plus `expected.count == Self.locales.count` so an emptied
locale list cannot pass. `aTickGivenForOneDayDoesNotStandForAnother` moves an
injected clock, and has its positives beside its negatives (the same day a
second later still saves; the re-tick saves; `defaultWrites.count == 1` at the
end). No wall-clock ceiling anywhere in it.

The cost is NEW-1 below, which is the state the fix creates at the day boundary.

### M-8 — the retention form did not start from the retention in force. CLOSED for the date (and see NEW-2).

`load`'s retention arm now does
`retainUntil = max(retainUntil, Self.roundedUpToTheMinute(held.retainUntil))`,
and `roundedUpToTheMinute` rounds up, never down, with the reason written beside
it ("a rounding down would be a shortening"). Two tests, the later case and the
earlier-so-unchanged case, and the later one also asserts the seconds are zero,
which the picker and the sentence both need. R8 and R9 are the implementer's
probes, and R9 is specifically the round-down mutation — the right probe to have
written.

The review's caution ("it needs care with the acknowledgement, because the
seeding is itself a change of `retainUntil` and would clear a tick — that should
be tested rather than assumed") is answered by `aLoadTakesAnyAcknowledgementBack`
plus the unconditional clear at the top of `load`. Tested, not assumed.

The mode half of the same problem is left open on purpose; that is NEW-2.

### M-3 — `FakeBucketSettings.defaultWrites`' doc comment. CLOSED.

The new wording says what it means ("the calls that reached the store, in order,
whether or not the store then refused them") and names the two guards that record
nothing (fewer than one day, a bucket with no Object Lock), which is exactly the
review's prescription. The withdrawal quotes the old sentence verbatim and cites
the test that contradicted it.

### M-4 — the sweep's comment claimed more than the sweep covers. CLOSED.

The comment now says "the model's decision inputs … with the file's own current
values held empty", quotes the withdrawn sentence verbatim, names the three
loading tests that hold the non-empty cases, and discloses that widening was
weighed and declined. The sweep is not widened, which is the review's own first
option.

Everything the new comment asserts about other code, I checked, because it is an
enumeration and a claim about a function:
- `model(for:)` does always build `Current(retention: nil, legalHold: false)` —
  the one occurrence of `Current(retention` in the file outside this comment is
  `ObjectLockSheetTests.swift:674`, inside `model(for:)`, and the only variation
  is `.read` vs `nil`.
- all three named tests exist: `aLoadReadsTheCurrentRetentionOfTheNamedKey`
  (`:394`), `aLegalHoldLoadReadsTheHoldAndStartsTheToggleWhereTheStoreIs`
  (`:405`), `aLegalHoldIsPlacedAndLiftedOnTheNamedKey` (`:513`).
- the comment states no count, so there is no number to re-derive.

### M-5 — `noOtherBackendContributesThem` was all-negative. CLOSED.

The positive is now in the same body, and in two forms: S3 does contribute both
ids (`#expect(s3.contains(action.rawValue))` per action), and the loop counted
its iterations (`checked == others * actions`, with `checked > 0` beside it).
Both numbers are derived from `.allCases.count`, not written down. This is the
construction the review pointed at (`theTitlesOfTheTwoActionsResolveInEveryLanguage`'s
`checked` counter).

### M-9 — the `dayRange` comment attributed the ceiling to the calendar. CLOSED.

The two claims are separated exactly as asked: "Some ceiling is needed so the
date arithmetic behind the acknowledgement cannot fail … That reason is for
having one, not for this figure; 36,500 days is the choice macSCP made, and it is
a policy figure, not the calendar's limit." The withdrawal quotes the old clause
verbatim and says why it was withdrawn (a hundred years is well inside what the
calendar counts; the clause is true near `Int.max`).
`theAcknowledgementDateDoesNotRunPastTheCeiling` still measures the clamp
relatively (`dayRange.upperBound` vs `Int.max / 2`), so the `startOfDay` change
did not quietly turn it into a tautology.

---

## 6. The four deferred findings — untouched?

| deferred | verdict |
| --- | --- |
| M-6, `acknowledged` as an unguarded `var` | **Untouched in substance.** Still a plain `var` on both models; nothing in `Sources` sets it `true`. The bucket model's *declaration* gained a `didSet` (Minor 2's machinery), which does not guard the setter and does not close M-6 — but see NEW-3, which is about that `didSet`. |
| M-2, the bucket-creation promise in `notEnabledOnThisBucket` | **Untouched.** `en` still reads "it can be chosen when a bucket is created" (`en.lproj:497`), `de` still "sie lässt sich beim Erstellen eines Buckets wählen" (`de.lproj:491`); the key is not in the diff for any of the four. |
| M-10, the German acknowledgement's date phrasing | **No German text changed** — the `de` catalogue's one edit in this diff is `s3.objectLock.mode.governance.detail` (I-2). But the *bucket default's* German sentence now renders without a time, because `acknowledgementDateText` moved to `dayText`: "bleibt bis zum 1. Januar 2027 gesperrt" rather than "… um 00:00". That is half of what M-10 complained about, removed as a side effect of Minor 2 rather than by editing German. The per-file sheet's "vor dem %@ löschen" still carries the long date plus short time, so M-10's other half stands exactly as the review left it. Worth knowing, not a breach of the deferral. |
| whether 36,500 is the right policy figure | **Untouched.** `static let dayRange = 1...36_500`. The comment around it changed (M-9) and says in so many words that the figure is a policy choice, which is what the deferral left to the maintainer. |

---

## 7. NEW findings

### NEW-1 (Minor). At the day boundary the bucket default shows a ticked box beside "Tick the box to confirm.", or takes the tick back on a click that explains nothing (`BucketObjectLockModel.save`, `isActive(.complianceNotAcknowledged)`, `BucketObjectLockSheet.present`)

Asked directly: is it a silent no-op? **Not quite, and the honest answer is in two
parts, because what the person sees depends on whether SwiftUI happened to
re-draw.**

`acknowledgementDate` is computed from `now()`, and `now()` is not an observable
dependency of the `@Observable` model, so the clock crossing local midnight
invalidates nothing and triggers no re-draw. From there:

- **No re-draw since midnight.** The sheet is still drawn as it was: box ticked,
  Save enabled (`.disabled(!model.canSave)` was evaluated before the boundary),
  no caption. The person clicks Save. `save()`'s first statement clears
  `acknowledged`, which *is* an observable change, so the body re-evaluates: the
  tick vanishes, Save greys out, and `explanationSentence` appears as
  `notAcknowledgedLine` — "Tick the box to confirm.". Then
  `guard canSave else { return }` returns. Nothing is sent; no `applyFailure`, no
  `isSaved`, no sentence about what just happened. So there *is* feedback — the
  box clears and a caption appears — but it is the generic blocker sentence, and
  nothing tells the person their tick was taken back or why. The report's
  description ("the person sees the box clear, and nothing is sent") is accurate
  as far as it goes; what it does not say is that the only explanation offered is
  an instruction to do again what they just did.
- **Any re-draw since midnight** (the person touches anything observable, or
  SwiftUI re-renders for its own reasons): `canSave` is already `false`, so the
  sheet shows a **ticked** checkbox, a greyed-out Save button, and the caption
  "Tick the box to confirm." That is a flat contradiction between what the box
  shows and what the sheet asks, with no way to discover that un-ticking and
  re-ticking is the cure. The round's own test records this state: it asserts
  `!model.canSave` *before* it calls `save()`, which is the same thing as saying
  the button would be dead at that moment.

Why Minor and not Important: the direction is fail-safe (the irreversible write
is blocked, never performed), nothing wrong is written, the recovery is one click
and is what the caption asks for, and the window is a sheet left open across
local midnight. Why it is a finding at all: it is a new state created by a fix
for a finding whose own prescription was "**Fix:** none needed", and in the
second ordering the sheet contradicts itself on the branch's most far-reaching
irreversible choice.

Cheapest honest close: give the stale case its own blocker and its own sentence
("the day this was confirmed for has passed; the box now confirms a different
day"), so the caption explains rather than instructs. Clearing the tick the
moment the day turns is not available without an observable trigger, which
`now()` is not.

### NEW-2 (Minor). A file already under COMPLIANCE is offered GOVERNANCE as its default, nothing says the mode cannot be weakened, and the refusal then names neither cause (`ObjectLockModel.mode`, `ObjectLockModel.load`, `ObjectLockSheet.retentionForm`)

Answering the question Minor 3's half-fix leaves: **the sheet does not tell the
user the current mode cannot be weakened. It lets them walk into the refusal.**
Measured, not inferred:

- `mode` initialises to `.governance` in all three initialisers, and `load` seeds
  only `retainUntil` — `git show 75bd8c50:Sources/MacSCPAppKit/ObjectLockSheet.swift`
  has no assignment to `mode` anywhere in `load`.
- `isActive(_:)` has no blocker relating `mode` to `current?.retention?.mode`;
  the seven non-`applying` cases are the same seven the review enumerated.
- `retentionForm` says nothing about it: the mode radio group, `modeDetailLine`,
  the date picker, and the acknowledgement checkbox under
  `if model.mode == .compliance`. The current retention's mode appears only
  above the form, in `retentionLine` ("Current retention: %1$@, until %2$@.").
- And Minor 3's seeding **removes the last obstacle**: on a COMPLIANCE file
  `retainUntil` is now the held date rounded up to the minute, so
  `dateNotInFuture` is inactive, GOVERNANCE needs no acknowledgement, `canRun` is
  `true`, and "Set Retention" is live on a change the store refuses. Before the
  fix the week-ahead default was *also* refused, so the defect is not new — but
  it is the only one of the two that Minor 3 left standing, and it is now the
  single reason the sheet's own default cannot be saved.
- What the person then reads is the sentence this same round rewrote.
  `ObjectLockLines.message(for:during:)` maps both
  `RemoteFSError.permissionDenied` and `.authenticationFailed` to
  `retentionRefused` during `.applyingRetention`, and `retentionRefused` names
  two causes — a retention already in force that cannot be shortened, and an
  access key that is not allowed. A COMPLIANCE-to-GOVERNANCE mode change is
  neither. So the sheet offers a default it cannot save and then misattributes
  the refusal.

Minor, by the same weighting the review gave M-8: it is a starting value and a
missing sentence, nothing irreversible happens, and the user is blocked rather
than harmed. The one consideration that would raise it to Important is that the
refusal sentence actively names the wrong reasons, and a sentence that tells the
user something untrue is how I-2 earned its class. I would not block the gate on
it, but it should be closed or deferred **by name** rather than left silent,
because the implementer's own report flags the hole and then does not say what
happens to the person who meets it.

Fix directions, both cheap: keep `mode` on GOVERNANCE (the implementer's
reasoning for that is right) and either (a) add a blocker — a COMPLIANCE
retention in force with GOVERNANCE chosen cannot be saved — with its own
sentence, which turns the refusal into a greyed button and an explanation before
the attempt; or (b) widen `retentionRefused` to name the third cause. (a) is
better: it stops the attempt rather than explaining it afterwards.

### NEW-3 (Minor, latent and unmeasured). `acknowledged`'s new `didSet` has no `oldValue` guard, so a same-value write re-stamps the day the tick was given for (`BucketObjectLockModel.acknowledged`)

```
var acknowledged = false {
    didSet { acknowledgedDay = acknowledged ? acknowledgementDate : nil }
}
```

Every other decision field on this model guards it — `mode` and `days` both open
`guard X != oldValue else { return }`, and the review's M-7 paragraph says in so
many words why ("so a redraw's write-back of the same value does not" clear the
tick). This one does not. A second write of `true` therefore recomputes
`acknowledgementDate` from the current clock and stores it, which turns a stale
tick fresh again and voids Minor 2 exactly where Minor 2 matters.

I cannot measure whether that write happens: `CheckboxRow` is a plain
`Toggle(label, isOn: isOn).toggleStyle(.checkbox)`, nothing in this project draws
a view, and I did not launch the app. A `Toggle` is not expected to write its
binding on a re-draw — but the two guarded fields beside it in the same `form`
are a `RadioChoice` over `$model.mode` and a `TextField(value:format:)` plus
`Stepper` over `$model.days`, and a `TextField` with a parsed value really does
write its binding back, which is the hazard the `days` guard exists for. So the
hazard is established for at least one neighbour and the question is only whether
a checkbox shares it. The asymmetry is the finding, not a measured defect. Closing it is one line (`guard acknowledged != oldValue else { return }`)
plus the test that a repeated tick does not refresh the day.

---

## 8. Project rules this diff is bound by

**A correction quotes verbatim what it withdraws.** The round rewrites prose in
five places and quotes all five. I checked each quotation against the *base at
`7afd772f`*, not against the report's transcription, and not line-oriented: the
new comments wrap, so a line `grep -F` is the wrong tool here for the same reason
`grep -c` is the wrong tool for an occurrence count. The script is
`checkquotes.py` in this session's scratchpad; it pulls every `verbatim: "…"` out
of the committed HEAD comment text itself (extracted, not retyped), strips `//`
prefixes from both sides, collapses whitespace, and looks for the quote in the
base. Run from the worktree root with `python3 -I`, it printed five quotes
checked, five found in the base, none missing:

| withdrawn in | quote | found at `7afd772f` in |
| --- | --- | --- |
| `ObjectLockLines.retentionRefused` | "The change was refused. A retention that is already in force may not be shortened, and your access key may not be allowed to change it." | `en.lproj/Localizable.strings` **and** `ObjectLockSheet.swift` |
| `ObjectLockLines.governanceDetail` | "Someone with the right permission can still shorten or remove a governance retention." | `en.lproj/Localizable.strings` **and** `ObjectLockSheet.swift` |
| `BucketObjectLockModel.dayRange` | "It exists because the acknowledgement names the day a file added now stays locked until, and a period too long for the calendar to count would leave that sentence naming the wrong day." | `BucketObjectLockSheet.swift` |
| `FakeBucketSettings.defaultWrites` | "The `setObjectLockDefault` calls that were not refused, in order." | `FakeBucketSettings.swift` |
| `ObjectLockSheetTests.Scenario` | "What the model's facts can be, as data. The cross product is the sheet's state space; no combination is written out by hand, so a state nobody thought of is still run." | `ObjectLockSheetTests.swift` |

One rewrite is **not** quoted: the bucket test's doc comment changed from "The
date in the acknowledgement…" to "The day in the acknowledgement…", and the test
was renamed `theAcknowledgementNamesTheDateAFileAddedNowIsLockedUntil` →
`theAcknowledgementNamesTheDayAFileAddedNowIsLockedUntil`. CLAUDE.md scopes the
quoting rule to the measurement record — `docs/BACKLOG.md` rows, the specs and
plans under `docs/superpowers/`, the SDD ledgers — and a test's doc comment is
not in it; the round quoted four source comments anyway, which is above what the
rule asks. Not a breach. Nothing still names the old test name: a `git grep` for
it at `75bd8c50` returns nothing.

**A negative check needs a positive beside it.** Every new negative has one in
the same body: `!promises` with `limit` and `fact`; `!flat` with `hedged`;
`!hasTime` with `hasMonth` and `expected.count == Self.locales.count`;
`modeDetailLine == nil` for the hold focus with `!= nil` for the retention focus;
`defaultWrites.isEmpty` with `canSave` before it and `defaultWrites.count == 1`
after it; `!ids.contains(...)` with `s3.contains(...)` and
`checked == others * actions` and `checked > 0`. The two source scans contain
**no** negative check at all — every assertion is a `contains` or a `#require`
that fails loudly when what it names moves. This was the rule the round was most
exposed to and it is clean.

**A number or an enumeration in a comment is a claim to verify.** The new
comments carry no counts. The one enumeration is the sweep comment's three
loading tests; all three exist (§5, M-4), and its claim about `model(for:)` holds.

**No hardcoded display string; four catalogues; `du`-form.** No production string
is hardcoded — the four changed values are catalogue entries and the two Swift
`english:` defaults beside them, which is this project's existing construction.
The English phrases inside the new tests ("still", "not from macscp", "perhaps",
the four month names) are assertions *about* catalogue text, the same shape as
the existing `theComplianceWordsSayWhatCannotBeUndoneInPlainEnglish`. All four
catalogues moved for `governance.detail`; `error.refused` is English-only by
design (de/fr/pl already hedged) and the round says so. No second-person German
text changed, so the `du`-form is not at issue; `GermanAddressFormTests` is in
the green run below.

**No wall-clock ceiling; a hang bound is `.timeLimit`.** No new test asserts
elapsed time. `aTickGivenForOneDayDoesNotStandForAnother` moves an injected
`Clock` rather than sleeping, and
`theFormStartsAtTheRetentionAlreadyInForceWhenThatIsLater`'s
`model.retainUntil < later.addingTimeInterval(60)` is a bound on a *value*, not
on a duration. `@unchecked Sendable` on the test-local `Clock` is house style
here (78 files under `Tests/` use it).

**`#expect` prints the source text of its expression.** Nothing secret is in
play, and the round nonetheless computes its Bools into named constants before
the expectation throughout, which is the construction the rule asks for.

---

## 9. Green run I made myself

```
swift test --filter 'ObjectLockSheetTests|BucketObjectLockSheetTests|ConnectionActionRouteTests|RigidControlScanTests|BoundedViewCoverageTests|GermanAddressFormTests|PluralCatalogTests'
```

→ `Test run with 137 tests in 6 suites passed after 2.627 seconds`. That is the
task review's set (114 tests in 5 suites) plus `PluralCatalogTests`, which I
added because this diff edits four catalogues; 114 + 12 new + 11
plural-catalogue tests = 137. The `mutation-probe` control runs printed
`91 test(s) ran, 0 pre-existing failures` three times.

I did **not** run `swift test` with no flags. The report's "Core 5074 passed; App
2754 run, exactly one failure, `ViewTestabilitySpike`" is unverified by me;
2742 + 12 = 2754 is consistent with the review's figure and with the 12 new
tests, and the pre-existing `ViewTestabilitySpike` failure is the one the review
also recorded as not re-measured against this task's base.

---

## 10. Verdict per finding

| finding | verdict |
| --- | --- |
| I-1, nothing holds the COMPLIANCE warning | **CLOSED** (R1, R2, R5 re-run by me, all RED over 91 tests) |
| I-2, the governance note promised an undo | **CLOSED** (four catalogues agree; fact kept, promise gone) |
| M-1, the English refusal was the only unhedged one | **CLOSED** on what it asked (the four now agree); the "no next step" half is **OPEN** and disclosed, and see NEW-2 |
| M-2, `notEnabledOnThisBucket` offers a choice the tree lacks | **OPEN by ruling** — deferred, untouched, confirmed |
| M-3, `defaultWrites`' doc comment | **CLOSED** |
| M-4, the sweep's "state space" | **CLOSED** |
| M-5, `noOtherBackendContributesThem` all-negative | **CLOSED** |
| M-6, `acknowledged` an unguarded `var` | **OPEN by ruling** — deferred, untouched in substance; the bucket declaration gained a `didSet` (NEW-3) |
| M-7, `load` did not clear `acknowledged` | **CLOSED** (placement still asymmetric; the fix report mis-describes it, the code does not) |
| M-8, the form did not start from the retention in force | **PARTLY** — the date is closed; the mode is NEW-2 |
| M-9, the `dayRange` comment's attribution | **CLOSED** |
| M-10, the German acknowledgement's phrasing | **OPEN by ruling** — deferred; no German edited, though the bucket sentence now renders without a time |
| M-11, the acknowledged sentence drifted with the clock | **CLOSED** — fixed though the review asked for no fix; see NEW-1 |

New: **NEW-1 Minor**, **NEW-2 Minor**, **NEW-3 Minor**. No new Important, no
Critical.

## 11. Can the gate close?

**Yes, on the two Important findings — both are closed, and I measured I-1
myself rather than taking the report's word.** The three NEW findings are all
Minor, all fail-safe (nothing irreversible is written, nothing false is
persisted), and all three are of a kind this branch has been deferring
explicitly. My recommendation is that the gate closes with NEW-1, NEW-2 and
NEW-3 recorded by name — NEW-2 in particular, because its half was declined
knowingly and the report does not say what the person who meets it reads.

## 12. What I could not check

- **R3, R4 and R6–R13.** I re-ran three of the thirteen probes. The bucket
  default's pair (R3/R4) is the one I would run next, since the review never
  measured that sheet and I took its guards from reading the diff.
- **The full suite.** See §9. Core was not run at all by me.
- **Anything drawn.** No view is rendered by any test here and I did not launch
  the app. NEW-1's two orderings are derived from `@Observable`'s invalidation
  rule and the `.disabled(!model.canSave)` / `explanationSentence` wiring, not
  observed on screen; NEW-3 is explicitly unmeasured for the same reason. The
  colour of the warning line and the conditional drawing of the acknowledgement
  checkbox remain held by nothing, as they were.
- **The rig.** Not contacted — the Docker rig must be started from the main
  checkout and this session is confined to a worktree. So whether the store
  refuses a COMPLIANCE-to-GOVERNANCE mode change (NEW-2's premise) rests on
  `S3BucketSettings.setRetention`'s doc comment and on S3's documented
  semantics, not on a measurement in this tree — which is the same footing the
  refusal sentence's hedge stands on, and I have treated it that way in both
  places.
- **Polish and French wording.** I read the four `governance.detail` strings as
  prose and checked that each carries the fact and the limit. A native reader
  should still look at `pl`'s "ale nie z poziomu macSCP" and `de`'s "aber nicht
  in macSCP", which are not quite the same construction as `fr`'s "mais pas
  depuis macSCP" — all three mean it, none is wrong, and which reads best is not
  mine to call.
