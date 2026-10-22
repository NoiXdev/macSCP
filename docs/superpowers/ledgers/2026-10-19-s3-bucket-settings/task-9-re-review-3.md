# Task 9, fix round 3: re-review

Reviewed `6d0cc4cc` (base `9ba2d1d2`, one commit) in the worktree `/Users/noidee/macSCP/.claude/worktrees/diff-view`. Nothing committed, amended or edited. `git status --porcelain` was empty before the first probe, after each of the nine probes, and is empty at the end. Every probe below uses the command string from `git log -1 --format=%B 6d0cc4cc`, unrepaired, run through `scripts/mutation-probe` (one correction of my own is disclosed under F800).

Disclosure of my own method: for the sweep, the labels and the completeness question I wrote one untracked Swift Testing file (`Tests/macSCPAppKitTests/ZZScratchReview3Tests.swift`) that re-implements the nine causes independently, ran `swift test --filter ZZScratchReview3Tests`, printed figures and ~30 extra documents, and then `rm`'d it. Porcelain empty before and after. I also ran `MACSCP_BOUND_FIGURES=1 swift test --filter BoundedView` (22 tests passed). I did not run the whole suite; the one known red (`ViewTestabilitySpike.swift:202`) is out of scope.

## Per-item verdicts

| Item | Verdict |
|---|---|
| 1. The Important (multi-line value beside a method outside the five) | ADDRESSED |
| 2. The three false comments, quoting what they withdraw | ADDRESSED |
| 3. The derived battery `everyCombinationOfCausesThatBlocksASaveSaysWhy` | ADDRESSED (sound; see the sweep section for what it cannot see) |
| 4. The fixture derivation (`corsOverlongLength = 800`) | ADDRESSED, with one Minor (stale "twenty times" comments, below) |
| 5. The `blockerLine` first paragraph vs the English method line | ADDRESSED, line unchanged |

**Open findings: none that blocks Task 9.** One Minor (stale comments), two observations. Details at the end.

## Probes H1-H5 (re-run, all reproduce)

Control for each: 60 tests, 0 pre-existing failures.

| Probe | Result | Caught by |
|---|---|---|
| H1 method no longer outranks a value | RED, 60 ran | `aMethodIsSaidBesideAValueOverSeveralLines`, `everyCombinationOfCausesThatBlocksASaveSaysWhy` |
| H2 `blockingSentence` loses the method case | RED, 60 ran | the same two |
| H3 unformatted blocker restored | RED, 60 ran | `everyCombinationOfCausesThatBlocksASaveSaysWhy` (only) |
| H4 value sentence only for a method | RED, 60 ran | `aValueThatChangesOnTheWayBackIsNotLossless`, `everyCombinationOfCausesThatBlocksASaveSaysWhy`, `everyKeyTheSheetUsesIsOneTheCatalogueChecksCover` |
| H5 fixture 800 -> 300 | RED, 60 ran | `theOverlongFixtureIsLongEnoughToCatchTheClip` |

Every "caught by" list equals the one in the commit message. H1 is RED under both the sweep and the named pair, as claimed.

## Probes F120 / F200 / F400 / F800 (re-run, all reproduce)

Each through `scripts/mutation-probe --filter BoundedViewLayoutGuardTests`; control 9 tests, 0 pre-existing failures.

| Probe | Result |
|---|---|
| F120 | GREEN, 9 ran, none noticed |
| F200 | GREEN, 9 ran, none noticed |
| F400 | RED, `BoundedViewLayoutGuardTests/noViewNeedsMoreThanItsBoundGrantsInAnyLanguage` |
| F800 | RED, same test |

F800: the commit's command is the method-clip plant alone, one file. I first ran it with a no-op second substitution (`800` -> `800`) that I had added by hand, which is a repair; I re-ran it exactly as committed (RED, same test, `1 file changed`) and report that one. A detail the commit message gets slightly wrong: it says "2 files changed in each", but F800 as committed changes 1 file; F120/F200/F400 change 2. Also in those three, the first `s///` matches a second place: the doc comment on `corsOverlongLength` quotes `String(format: line.text, Self.clipped(method))`, so the plant rewrites that comment line in the registry too (stat: 3 insertions, 3 deletions). It does not change any outcome.

**Is the derivation re-runnable?** Yes. The comment on `corsOverlongLength` names the plant (`String(format: line.text, Self.clipped(method))`, which the message of `9ba2d1d2` carries verbatim as probe G1b, checked), the suite filter, the four lengths and the results, and points at the probes of "the commit that wrote this comment" for the exact commands. It gives no hash, so a reader needs `git log -S corsOverlongLength`; Minor, not a defect. The headroom figure is re-derivable and I re-derived it: `MACSCP_BOUND_FIGURES=1` prints `tall ... 536 ... of 620.0` for "CORS text with an overlong method name" in all four locales, and 620 - 536 = 84. The ratios are right: floor 400 = half of 800; longest known blind (200) x4 = 800. The wording is honest, "known to work/fail", not "the threshold". The threshold lies in (200, 400], not pinned finer.

**Does the test pin the floor at 400?** `theOverlongFixtureIsLongEnoughToCatchTheClip` expects `corsOverlongLength >= 400` and `> nameLimit`. H5 (800 -> 300) is RED under exactly that test, so yes. It pins a number to a measurement, not the property itself (a layout change that moves the threshold above 400 would not be noticed). Same standing as the by-value pin of `nameLimit` accepted in round 2.

## The battery: does the sweep generate what it claims?

My independent re-implementation of the generator, run on the same nine causes:

- subsets: **512**; documents: **1534**; distinct documents: **1244**.
- The two "missing" ones: 512 x 3 = 1536, and the empty subset yields one document (`documents(having: [])` returns the single valid rule), not three, so 1536 - 2 = 1534. Deliberate and correct: with no cause there is nothing to arrange.
- The 290 duplicates are inherent, not a bug: a single cause is the same text in all three arrangements (9 x 2 = 18), and in the one-rule arrangement some pairs collapse (`noOrigin` clears the origins a multi-line or carriage-return cause added; `noMethod` clears `FETCH`). Those pairs cannot exist in one rule, and the "apart" arrangements put them in different rules. So "1534 documents" is right and "1534 combinations" would overstate by a fifth. Observation only.
- Outcomes: `canSave` true in **22**, false in **1512**; a blocking sentence present in **1512**; a document that is saveable AND has a sentence: **0**; unsaveable with NO sentence: **0**; label mismatch against my own labels: **0**. 22 = the empty subset (1) + the 7 non-empty subsets of the three multi-line causes x 3 arrangements, exactly the documents with no blocking cause.

**Positive beside the negative: yes.** Both sides are populated (22 saveable, 1512 blocked) and the sweep asserts `blocked > 0`, `saveable > 0` and the full count. The saveable side is thin, 22 of 1534, and consists of the empty subset plus the multi-line documents; a regression that made a multi-line document block is caught, and one that made a clean document block is caught by the empty-subset document and by `aDocumentThatCanBeSavedHasNoBlockingSentence`.

## Is each `Cause`'s `blocksSaving` label correct against production?

Checked two ways: (a) a single-cause document per cause, printing `canSave`, `isLossless`, `formBlock`, `problem` and the sentence; (b) the sweep passing at HEAD (0 failures in the unplanted control of every H probe), plus my own copy of the labels agreeing with the model on all 1534 documents.

| Cause | Label | What the model does (single-cause document) | Why |
|---|---|---|---|
| `leftOutElement` | blocks | `canSave` false, `isLossless` false, `.leftOut(["Extra"])`; sentence "...cannot be saved as it is" | element census differs, so not lossless |
| `methodOutsideTheFive` | blocks | `canSave` false, `problem` `.methodNotAllowed("FETCH")`, `.method("FETCH")`; sentence names FETCH | `CORSRule.validate()` refuses it |
| `multiLineOrigin` | does not block | `canSave` TRUE, lossless, `.value(rule: 1)`, `blockingSentence` nil | value reads back as it went out |
| `multiLineID` | does not block | same | same |
| `multiLineHeader` | does not block | same | same |
| `carriageReturnOrigin` | blocks | `canSave` false, `isLossless` false, `.value(rule: 1)`, blocker "Saving would change a value in the text" | `&#13;` reads back as a newline |
| `noOrigin` | blocks | `canSave` false, `problem` `.noOrigin`, "Rule 1 needs at least one allowed origin" | `validate()` |
| `noMethod` | blocks | `canSave` false, `problem` `.noMethod`, "Rule 1 needs at least one allowed method" | `validate()` |
| `blankOrigin` | blocks | `canSave` false, `problem` `.noOrigin`, same sentence | `validate()` trims whitespace-only origins |

All nine labels are true. The `switch` spells out all nine cases with no `default`, so a tenth case does not compile until it is classified, as claimed.

## Is `Cause` complete?

What a rule can carry that blocks a save, searched with ~30 extra documents of my own (printed, none left in the tree):

- **In the nine, as classes:** an element left out (a stray element, a duplicated `<ID>`, a duplicated `<MaxAgeSeconds>`, an attribute on the rule, a child element inside a value: all `.leftOut`, one code path), a method outside the five (an empty `<AllowedMethod>`, lowercase `get`: all `.method`), a carriage return, no origin, no method, a blank origin.
- **Not in the nine, by design:** unreadable text (own test `unreadableTextSaysWhyItCannotBeSaved`; a non-integer `<MaxAgeSeconds>`, a control character and a wrong root all came back `.unreadable` with the unreadable sentence); and the non-text blockers (nothing changed, a write in flight, store not read), which `blockingSentence` documents as not the text's.
- **Not in the nine, not a blocker:** a negative `MaxAgeSeconds`, a tab, padded spaces, an empty `<ID/>`, U+2028 and U+0085 (the last two are multi-line values like `\n`, saveable). All came back saveable with no sentence, which is what the labels would have said.
- **Nothing found that blocks a save and has no cause.** One gap I could not fill: `.unstable` (the `FormBlock` case for "a value would change on the way back, and nothing above says why"). I found no document that reaches it, and no `Cause` produces it. It is the deferred `FormBlock.unstable` item; not raised.

**A sensitivity limit, not a finding:** the multi-line causes are asserted only to *not block*. A regression that stopped `firstUnshowable` from detecting a value at all would leave those documents saveable with no sentence, which the sweep calls correct. Value detection is guarded elsewhere (the control in `aMethodIsSaidBesideAValueOverSeveralLines`, `formUnavailableReasonKey` tests), not by the sweep. Likewise `ExposeHeader` is scanned by `firstUnshowable` but has no `Cause` (same list concatenation as `AllowedHeader`); I checked by hand that a multi-line `ExposeHeader` gives `.value(rule: 1)`, saveable, and beside `FETCH` gives the method.

## The precedence decision

A method now outranks a value wherever each sits (`firstUnshowable` returns the first method at once and remembers only the first value). The named pair and each arrangement, on my own copy:

| Document | `canSave` | form-off | blocking sentence |
|---|---|---|---|
| value in rule 1, `FETCH` in rule 2 | false | method | "“FETCH” is not a method that can be allowed, so the fields are off. Use GET, PUT, POST, DELETE or HEAD in the text." |
| `FETCH` in rule 1, value in rule 2 | false | method | same |
| value and `FETCH` in one rule | false | method | same |
| the value alone | true | value ("A value in rule 1 runs over more than one line...") | nil |

True in every arrangement. Is it the sentence the user needs? Yes: the method is what stops the save, the sentence names it and says what to type. It says "the fields are off", not "Save is off", but it is the sentence the method-alone case has had since round 1, so this adds no inconsistency. The value sentence no longer shows while the method is there and returns when the method is fixed (the document is then saveable), the right order: no sentence is shown that is not a reason Save is off. A third sentence would repeat the cause (round 1 removed that on purpose). With a carriage return in a different rule both are shown (form-off method, blocker "Saving would change a value"), as `aMethodAndACarriageReturnAreBothSaid` pins. Verdict: sound.

## The three corrected comments, against `git show 9ba2d1d2:Sources/MacSCPAppKit/BucketCORSSheet.swift`

- `firstUnshowable`: quotes "The first thing in `rules` the fields cannot show, in document order, or `nil`" (original lines 215-216, wrapped; verbatim apart from the wrap). The withdrawal says what it is instead, and I checked it against the code: first method in document order, else first value. OK.
- `blockerLine`: quotes "`blockingSentence` is the one that is always there." (original 558) and, for the method, "A method outside the five, and an element a rule has no place for, each have a sentence of their own that says the text cannot be saved as it is" (original 545-547). Both verbatim. The third edit in that comment, "carry their own "cannot be saved as it is" in the form-off sentence" -> "carry their own sentence in the form-off line", is a shortening that withdraws nothing, because the first paragraph still says (and it is true: `formCannotShowThisLine` and `valueChangesLine` both contain "cannot be saved as it is" in the English catalogue) that leftOut and `.unstable` say so. Owes no quote.
- `blockingSentence`: quotes "the form-off sentence for the causes whose sentence says the text cannot be saved as it is" (original 590-591). Verbatim.

**Fifth item:** the first `blockerLine` paragraph now says the method sentence "says the method cannot be allowed ... without the word "save" in it". The English line is "“%@” is not a method that can be allowed, so the fields are off. Use GET, PUT, POST, DELETE or HEAD in the text." It agrees. The line is unchanged: the diff `9ba2d1d2..6d0cc4cc` touches three files and the sheet's hunks contain no catalogue entry.

## Findings

- **Minor: three comments still call the overlong fixture "twenty times" the clip length**, the relationship this round untied: `Sources/MacSCPAppKit/BucketCORSSheet.swift:389` (the `nameLimit` doc: "feed the clip text of twenty times this length"), `Tests/macSCPAppKitTests/BoundedViewRegistry.swift:367` ("given text twenty times as long as the sheet shows of it") and `Tests/macSCPAppKitTests/BucketCORSSheetTests.swift:684` ("the registry feeds the clip text twenty times as long"). True today by arithmetic (800 = 20 x 40), false in the one case the round argued from (lowering the limit), and it is the CLAUDE.md rule on comments that name a relationship you have just changed; the first one is in a file this diff touched. Fix: say "`corsOverlongLength` characters, see there". Does not block the task.
- **Observation: the sweep's 1534 documents are 1244 distinct ones.** The claim is right; it must not be read as 1534 distinct combinations. No change needed.
- **Observation: the commit message's "2 files changed in each" is wrong for F800 (1 file).** No test or comment relies on it.

## "No red before the production change"

Disclosed again; weighed in one line: H1 restores the pre-fix shadowing almost literally and is RED under both the sweep and the named pair, so the new tests are red-first by construction for the Important itself, and I do not count it against the round.

## Verdict

Fix round 3 closes the Important. Every probe reproduces (H1-H5 RED as claimed, F120 and F200 GREEN, F400 and F800 RED), all nine labels are true, the sweep has a positive beside its negative, and the three comments quote what they withdraw. The only open item is the Minor stale-comment finding. **No Important or Blocking finding remains open.**

Paths: this file `.superpowers/sdd/2026-10-19-s3-bucket-settings/task-9-re-review-3.md`; source `Sources/MacSCPAppKit/BucketCORSSheet.swift`; tests `Tests/macSCPAppKitTests/BucketCORSSheetTests.swift`, `Tests/macSCPAppKitTests/BoundedViewRegistry.swift`.
