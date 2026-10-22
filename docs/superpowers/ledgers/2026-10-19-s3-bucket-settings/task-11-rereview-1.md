# Task 11, re-review of fix round 1

Scoped re-review of BASE `d7c6631c` .. HEAD `1d1dcec2` (4 commits), in the
worktree `/Users/noidee/macSCP/.claude/worktrees/diff-view`. In scope: I1, I2,
I3, I4, M2, M4, M5, M6, M8. Out of scope and required untouched: M1, M3, M7.

Written from the diff, from the committed tree, and from eight mutation probes
run here — three of the record's own and five of mine. Every figure below
carries the command that produced it, and every command was re-run after the
sentence was written. Commands scoped with `-- Sources Tests` or `-- Tests` are
scoped that way *so that this file cannot answer them*: this report is under
`.superpowers/`, outside every pathspec used.

---

## Out of scope: untouched, as instructed

- **M1.** No Core file is in the diff:
  `git diff --stat d7c6631c..1d1dcec2` lists eight files, none under
  `Sources/macSCPCore`. `listedItems` is unrenamed.
- **M3.** `Tests/macSCPAppKitTests/ConnectionActionRouteTests.swift` is not in
  the diff either; the widened test's two hand-written contexts stand.
- **M7, no rebase.** `git log --oneline -9 1d1dcec2` still carries
  `d7c6631c`, `b7371a8f`, `75fe0553`, `52e30257`, `8e21f073` in that order;
  `git merge-base --is-ancestor 8e21f073 1d1dcec2` exits 0 and
  `git cat-file -t 75fe0553` and `… b7371a8f` both print `commit`. Nothing was
  rewritten. No finding.

---

## The four Important

### I4 — the probe record: CLOSED

The record is the message of `1d1dcec2`, and it carries, per probe: id, what is
planted, `--filter`, `--apply` as the shell hands it over, the control count,
the result, and the catching tests by name. 23 probes (P1, P2, P3, P3b, P4–P13,
P14a, P14b, P15, P16, P16a, P16b, P17, P18, P19), all recorded RED.

I ran three, **extracted from the committed message rather than retyped**: the
message was saved with `git log -1 --format=%B 1d1dcec2`, and a runner pulled
the `--filter` and `--apply` lines out of it with `awk` and passed them to
`scripts/mutation-probe` unmodified.

| probe | why this one | control | result | caught by |
|---|---|---|---|---|
| **P3** | one of the three re-anchored by I3 | **60 tests, 0 pre-existing failures** | **RED** | `ConnectionActionRouteTests/createBucketIsLiveOnlyAtTheBucketList()`, `CreateBucketSheetTests/theRoutesGateAsksTheModelsRule()` |
| **P16** | the reviewer's own former-GREEN plant (both `%@` substitutions dropped) | **58 tests, 0 pre-existing failures** | **RED** | `CreateBucketSheetTests/aSubstitutedSentenceNeverShowsItsPlaceholder()`, `CreateBucketSheetTests/everyProblemSentenceIsPlainTextOnceFilledIn()` |
| **P17** | my choice: M4's claim, the creation clause deleted from all four catalogues | **60 tests, 0 pre-existing failures** | **RED** | `CreateBucketSheetTests/theObjectLockSentenceNamesWhatTheCheckboxIsCalled()` |

All three reproduced the record exactly — same control count (60, 58, 60), same
verdict, same catchers. None was `BUILD FAILED`, `PLANT CHANGED NOTHING` or
`RUN INCOMPLETE`. The tree was clean after each (`git status --porcelain`
empty).

The re-anchoring is stated in the record itself and is true of the tree: P1–P3's
original `--apply` matched `&& context.bucket == nil`, which I3 removed from
`ConnectionActionRoute.swift`. P4–P13 are the first report's strings unchanged.

One disclosed wrinkle, correctly disclosed: P5 and P8 name their catcher under
its pre-rename name (`aFailureOfTheSecondRequestSaysTheBucketWasCreated`),
because the rename landed in the same commit as the record; the message says so
in its own text.

### I1 — the two findings told apart: CLOSED

`.bucketAlreadyOwnedByYou` now inserts the name into `takenNames` and returns
`bucketMayExist: true`; `.bucketNameTaken` returns `false` and inserts nothing.

**The distinction is right.** Core's own definitions settle it
(`Sources/macSCPCore/RemoteFS/RemoteFSFinding.swift`, the doc comments on the
two cases): `.bucketNameTaken` is `BucketAlreadyExists` — "its name belongs to
someone else" — and `.bucketAlreadyOwnedByYou` is `BucketAlreadyOwnedByYou`,
"this account already owns one with that name". The `nameIsTaken` sentence says
"Your list already has a bucket with this name", so inserting another account's
bucket into the taken set would make it false. Leaving `canCreate == true` after
`.bucketNameTaken` opens no one-way door (the store refuses again, and the
refusal names its own cause), so the looseness there is bounded and honest.

**No sentence now claims more than the finding supports.** After
`.bucketAlreadyOwnedByYou` the sheet shows the finding's own message ("You
already own a bucket with that name"), and `showsNameIsTaken` is `false`, so the
"Your list already has…" line is suppressed rather than asserted — the test
pins exactly that (`aBucketTheStoreSaysYouOwnIsTakenAndTheListIsStale`:
`nameIsTakenKey == "s3.createBucket.nameIsTaken"` **and**
`showsNameIsTaken == false`). `settings.reads.isEmpty` is asserted too: no read
is spent on a question the store has answered.

**Do the probes carry the weight of the missing standalone red?** For I1, yes —
and I measured it rather than taking P14a/P14b's word for it. P14a and P14b each
undo one half of the fix. I planted the **exact pre-fix arm** instead (both
findings → `bucketMayExist: false`, no insert), which is the code the missing
red would have been run against:

```
RP4 --filter 'CreateBucketSheetTests|ConnectionActionRouteTests' \
    --apply "perl -0pi -e 'die \"anchor missed\n\" unless s/                takenNames\.insert\(bucket\)\n                return \.failed\(sentence: Self\.refusalSentence\(for: error\), bucketMayExist: true\)\n/                return .failed(sentence: Self.refusalSentence(for: error), bucketMayExist: false)\n/' Sources/MacSCPAppKit/CreateBucketSheet.swift"
── control: 60 test(s) ran, 0 pre-existing failures
RESULT: RED — 60 test(s) ran, and the plant was caught by:
  macSCPAppKitTests.CreateBucketSheetTests/aBucketTheStoreSaysYouOwnIsTakenAndTheListIsStale()
```

The pre-fix I1 defect is red against the committed suite. The probes carry the
weight.

For **M8** the same test came back the other way; see M8 below and new finding
**N1**.

### I2 — the sweep: CLOSED (the finding), with a new Minor on the guard

The four members the review named are now read by assertions, not mentioned:
`problemSentence` and `createdSentence` by
`aSubstitutedSentenceNeverShowsItsPlaceholder` (all four locales, three `%@`
sentences, each asserted to contain its argument and to contain no `%`) and
`everyProblemSentenceIsPlainTextOnceFilledIn`; `isEditable` by
`theFieldsAreEditableExceptWhileCreatingAndOnceCreated` (with `.editing` as the
written positive control); `isCreating` by
`theStateFlagsTheViewShowsAreTheOutcomeAndNothingElse`. The reviewer's own plant
is RED, measured here (P16 above).

The six further static lines the sweep turned up are all in the `shown` array of
`theLinesTheViewShowsAsTheyStandCarryNoPlaceholder`, which reads each line's
text in each of the four locales and asserts four things about it. Counted with

```
for m in actionLine creatingLine listingUnknownLine nameHintLine nameIsTakenLine versioningLabel; do
  sed -n '/let shown: \[CatalogueLine\] = \[/,/\]/p' Tests/macSCPAppKitTests/CreateBucketSheetTests.swift | /usr/bin/grep -c "$m"; done
```

→ `1` for each of the six. `#expect(shown.count == 9)` matches the array as
written (titleLine, nameLabelLine, nameHintLine, actionLine, versioningLabel,
objectLockLabel, nameIsTakenLine, listingUnknownLine, creatingLine).

They are read by an assertion — but the assertion is about the *line* (swept,
no placeholder, non-empty), not about the view showing that line in that place.
That is a real strengthening over "mentioned", and weaker than the `%@` pins
beside it. Recorded, not filed.

**Moving the two decisions out of the view did not change behaviour.** Checked
by algebra, not by assertion:

- `versioningCanBeChanged == isEditable && !versioningIsLocked`, and the view
  previously read `.disabled(!model.isEditable || model.versioningIsLocked)`.
  `!(a && !b) == !a || b` — identical.
- `versioningNoteLine == versioningIsLocked ? versioningHeldByObjectLockNote :
  versioningNote`, and the view previously held the same ternary on `.text`.
  Identical.

Both are pinned at the model by `theVersioningCheckboxAndItsNoteFollowTheLock`,
and P18/P19 are recorded RED.

### I3 — the predicate states the whole rule: CLOSED

`isOffered(rootIsContainerList:paneBucket:)` returns
`rootIsContainerList && paneBucket == nil`. It no longer returns its own
argument: `paneBucket` is a second, independent fact, and the committed
`theRowIsLiveOnlyWhileThePaneIsSHOWINGTheBucketList` asserts all three corners
that matter (`true/nil → true`, `true/"macscp-seed" → false`,
`false/nil → false`).

The three expectations are the brief's, verbatim — `task-11-brief.md:147–149`
against the committed body; only the comment differs (it now explains the rule
instead of citing the controller's amendment).

The route arm and the model agree rather than splitting the rule: the arm is
`context.settings != nil && CreateBucketModel.isOffered(rootIsContainerList:
context.rootIsContainerList, paneBucket: context.bucket)`, and
`theRoutesGateAsksTheModelsRule` now asserts both argument labels are present
**and** that the arm does not contain `context.bucket != nil` — a negative with
three positives beside it (`isOffered(`, both labels) and its own existence
control (`try #require(source.range(of: "case .createBucket:"))`). P3 and P3b
are RED; P3 reproduced here.

---

## The sweep test, and the `\b` nondeterminism

### The nondeterminism

**The hypothesis holds as a mechanism, and it cannot be the whole story.**

Swift `Set<String>` iteration order does vary between processes for exactly this
corpus. Five separate processes, the 27 member names the guard builds, printing
the first four elements of `Array(set)`:

```
first=nameIsTakenLine  order=nameIsTakenLine|nameLabelLine|versioningCanBeChanged|nameHintLine
first=nameLabelLine    order=nameLabelLine|nameHintLine|versioning|objectLockNote
first=problemSentence  order=problemSentence|failureSentence|listingUnknownKey|nameLabelLine
first=bucketMayExist   order=bucketMayExist|creatingLine|isEditable|versioningCanBeChanged
first=isCreated        order=isCreated|versioningNoteLine|Listing|bucketMayExist
```

(Script in the session scratchpad; it hard-codes the 27 names produced by
`sed -n '/^struct CreateBucketSheet/,$p' Sources/MacSCPAppKit/CreateBucketSheet.swift | /usr/bin/grep -oE '(model|CreateBucketModel)\.[A-Za-z_][A-Za-z0-9_]*' | sed 's/.*\.//' | sort -u | wc -l` → 27.)

So a guard that reported out of that `Set` unsorted would print a different
message every run with a stable verdict. **The committed guard cannot: `unnamed`
is `.sorted()` before it reaches the message.** That channel is closed in the
code as committed.

What the hypothesis does *not* explain is the implementer's specific
observation — "`canCreate` was 'unnamed' in one run and not in the next" — which
is a change of membership, not of order. I looked for a second cause and found
no live one:

- `SourceCorpus` is not a candidate. Its tables are `PerKeyCache`
  (`Tests/MacSCPTestSupport/PerKeyCache.swift`), whose store is a `Mutex`, and a
  reader that finds a key `.running` recomputes it rather than waiting, so the
  *value* is deterministic however the threads interleave.
- The draft is not in git. `git diff c50759d0..1d1dcec2 --stat` is one file, one
  line (the test rename), and the test was born in `c50759d0` already in its
  substring form. The `\b` version was never committed, so its cause is not
  recoverable from the record — it can only be re-derived by rewriting it.

**Verdict on the nondeterminism: unresolved and no longer load-bearing.** The
committed guard is stable, measured by repetition, which is the measurement this
project asks for:

- 5 runs of `swift test --filter 'everyMemberTheViewReadsIsNamedByATest'` on
  the clean tree: **5 of 5 passed** (0.050–0.054 s each).
- 3 runs of a plant that adds a member the view reads and no test names
  (`var zzzNothingNamesThis: Bool { false }` on the model plus
  `|| model.zzzNothingNamesThis` in the view, both anchors asserted with `die`,
  through the harness): **3 of 3 RED, 60 tests each, caught by
  `everyMemberTheViewReadsIsNamedByATest()` alone.**

That is a sensitivity figure, not a single red. The implementer's "I did not
find out why" is a gap in the record rather than a defect in the tree; the one
thing it leaves behind is that the replacement is weaker than what it replaced,
which I measured — see **N2**.

### Does the guard earn its keep?

**Yes, narrowly, and it is not the structural boundary the property wants.**

For it: it is a positive check with a positive control (`read.count >= 15`,
actual 27), it reads the view's source through `SourceCorpus.code`, so a comment
quoting `model.x` cannot satisfy it, and it caught, 3 of 3, a member the view
reads that nothing names. It is not a comment that runs: it has a measured
verdict against a measured plant.

Against it: the property it stands in for is "every sentence a person reads is
asserted by a test", and what it checks is "every member the view reads is
*spelled* somewhere in one test file". Three gaps, in descending order of how
much they cost:

1. **Nominal, by construction.** The implementer says so. A member mentioned in
   an assertion *message string* satisfies it (`SourceCorpus.commentFree` keeps
   string literals), as does a member named in a test that asserts nothing about
   it.
2. **Substring, measurably.** See **N2**: a member named `nameIsTaken` is
   bought by the existing `nameIsTakenKey` / `showsNameIsTaken` /
   `nameIsTakenLine`, measured GREEN. The `\b` draft would have been red on
   exactly this.
3. **One direction only.** It constrains what the view reads to be named; it
   does not constrain the view to read anything in particular. That is the hole
   **N1** falls through.

The project's own position applies: when a scan keeps buying one spelling, the
property wants a type that will not compile the violation. The shape available
here is the one the registry already gestures at — every user-visible decision
is a member of the model, and the view is a `BoundedView` whose on-screen states
are enumerated in `BoundedViewRegistry`, so a registry entry per decision
(including the partial-failure-with-a-taken-name state N1 needs) pins what a
person sees rather than what a test spells. I would keep the sweep — it is cheap
and it found eight real holes — and stop treating it as the guarantee.

---

## The five Minor

**M2 — CLOSED.** The key is `existsIncompletely` in all four catalogues, with
the old key gone from the tree except inside its own quoted withdrawal:
`git grep -n 'createdIncompletely' -- Sources Tests docs` prints exactly one
line, `Sources/MacSCPAppKit/CreateBucketSheet.swift:398`, which is the
`verbatim:` quote. Per locale,
`/usr/bin/grep -c 'existsIncompletely' Sources/MacSCPAppKit/Resources/<l>.lproj/Localizable.strings`
→ 1 in each of `en de fr pl`, and
`/usr/bin/grep -c '^"s3.createBucket' …` → 23 in each, unchanged.

No sentence asserts authorship from a read that establishes only existence. The
two rewritten ones say "A bucket named “%@” exists now…" and "The request to
create the bucket failed." The only remaining "was created" is
`s3.createBucket.created %@`, shown for `outcome == .created`, i.e. after the
create returned success — authorship established, claim allowed. `mayExistLine`
is unchanged and was already honest. `create(via:)`'s doc comment is corrected
in place with its old words quoted.

**M4 — PARTLY.** The deletion is really guarded: P17, re-run here, is **RED, 60
tests, caught by `theObjectLockSentenceNamesWhatTheCheckboxIsCalled()`**. The
derivation works out in all four locales — the title's words of ≥4 characters
that also occur in the name-field label reduce to the bucket noun in each
(`Create Bucket`/`Bucket name`, `Bucket erstellen`/`Name des Buckets`,
`Créer un bucket`/`Nom du bucket`, `Utwórz bucket`/`Nazwa bucketa`), and the
clause after the semicolon contains it in each. Nothing is spelled.

The disclosed limit is real and it is the part that matters here: what the guard
buys is "a semicolon clause exists and it mentions buckets". Rewrite the clause
to "…; a bucket cannot be changed afterwards." and it stays green while the
claim Task 10's sentence rests on is gone. **Partial is not enough to carry
Task 10's sentence**, and the strengthening is cheap and was not argued against:
`en` is the source text every other catalogue is measured against (CLAUDE.md),
so pinning the English clause's own words — that it says the lock *can be
chosen* at creation — is a legitimate assertion against the source language, not
a second copy of a name. I would ask for that one expectation before the task
closes. Everything else about M4 is done.

**M5 — CLOSED, and not reintroduced elsewhere.** The test now matches the
sibling shape exactly: `let planted = "https://AKIDEXAMPLE:SECRETEXAMPLE@store.invalid"`,
`let quoted = sentence.contains("SECRETEXAMPLE") || sentence.contains("store.invalid")`,
then `#expect(!quoted)` — the same two lines as
`BucketVersioningSheetTests.swift:191`/`:197`, and both halves (credential and
host) are checked now, where the old form checked only the credential. The only
other `#expect` in that test reads `sentence == CreateBucketModel.notCreatedLine.text`,
whose source text and value both carry nothing planted. `/usr/bin/grep -rn
'SECRET\|AKIDEXAMPLE' Tests/macSCPAppKitTests/CreateBucketSheetTests.swift`
returns three lines: the comment, the constant, the `quoted` computation. None
is inside an expectation.

**M6 — CLOSED on the code; its figure is wrong (see N3).** The init is
`init(existingNames: [String], listingIsKnown: Bool, outcome: Outcome = .editing, name: String = "")`
— no default on either. **The values are unchanged**, which is the thing I was
asked to confirm: the withdrawn defaults were `existingNames: [String] = []` and
`listingIsKnown: Bool = true` (`git show d7c6631c:Sources/MacSCPAppKit/CreateBucketSheet.swift`),
so every `CreateBucketModel()` rewritten as
`CreateBucketModel(existingNames: [], listingIsKnown: true)` passes exactly what
it passed before, and every site that already named `existingNames` kept its
array (`["macscp-seed", "macscp-second"]`, `["macscp-seed"]`) and gained only
`listingIsKnown: true`. Reading every changed line of the diff for
`Tests/macSCPAppKitTests/CreateBucketSheetTests.swift` and
`Tests/macSCPAppKitTests/BoundedViewRegistry.swift`: no expectation and no
argument value changed. The brief's six bodies keep their names, their names
under test and their expectations.

**M8 — PARTLY.** The behaviour is right and the decision is in one place:
`showsNameIsTaken == nameIsTakenKey != nil && !bucketMayExist`, read by the
view, pinned by `theTakenNameLineIsOnScreenOnlyWhenNothingElseSaysTheBucketExists`
with a written positive control (`taken.showsNameIsTaken == true`) and both
exit cases (partial failure, success). P15 is RED, as recorded.

But P15 is a *stronger* plant than the defect M8 was filed for: it strips the
suppression entirely, where the pre-fix code suppressed on `isCreated`. I
planted the pre-fix view condition itself, and it is not caught — see **N1**.
So for M8, unlike I1, the probes do **not** carry the weight the missing
standalone red would have carried: nothing in the suite is red against the code
as it stood before the fix.

---

## The new prose in three languages

Read against `en` as the source text. All three say what the English says, and
none asserts more.

`existsIncompletely` — English: "A bucket named “%@” exists now, but the request
to create it with the settings you chose did not complete. It may not have those
settings. Open Versioning and Object Lock for it to see what it has, and do not
create it again."

- **de**: "Ein Bucket namens „%@“ existiert jetzt, aber die Anfrage, ihn mit den
  gewählten Einstellungen zu erstellen, wurde nicht abgeschlossen. Er hat diese
  Einstellungen womöglich nicht. Öffne für ihn … und erstelle ihn nicht noch
  einmal." Existence asserted (the read establishes it), completion denied,
  settings hedged with "womöglich". **du-form**: `Öffne`, `erstelle` are
  du-imperatives; no `Sie`, no `Öffnen Sie`. Consistent with the rest of the
  `de` block ("Aktualisiere die Liste", "Dein Zugangsschlüssel").
- **fr**: "Un bucket nommé « %@ » existe maintenant, mais la demande de le créer
  avec les réglages choisis ne s’est pas terminée. Il se peut qu’il n’ait pas ces
  réglages. Ouvrez … et ne le recréez pas." Same three claims, same hedge, vous
  as elsewhere in `fr`; the typographic apostrophe and the spaced guillemets
  match the neighbouring entries.
- **pl**: "Bucket o nazwie „%@” istnieje teraz, ale żądanie jego utworzenia z
  wybranymi ustawieniami nie zostało ukończone. Może nie mieć tych ustawień.
  Otwórz … i nie twórz go ponownie." Same three claims; the „…” quoting matches
  the existing `pl` entries.

The plain-failure line — en "The request to create the bucket failed." — is
rendered de "Die Anfrage zum Erstellen des Buckets ist fehlgeschlagen.", fr "La
demande de création du bucket a échoué.", pl "Żądanie utworzenia bucketa nie
powiodło się." Each asserts the request failed and nothing about the bucket,
which is what was measured. The one wording drift is harmless: English says "the
settings you chose", the three translations say "the chosen settings" — the same
claim, one degree less personal, no hedge tightened and nothing added.

`theEnglishCatalogueSaysTheDefault` and `everyLineResolvesInAllFourLocales` both
live in `CreateBucketSheetTests` (`git grep -ln` over `Tests`), so the
`english:`-against-`en` equality and the four-locale resolution were inside
every one of my 60-test control runs, each with 0 pre-existing failures.

---

## Rules that bind this diff

- **Verbatim quotes.** Seven dated correction passages; I checked each against
  `git show d7c6631c:…` rather than against the report, and all seven quote the
  exact replaced wording: the old `isOffered` signature and body
  (base `:63–64`); `create(via:)`'s "found means the create had gone through"
  (base `:214–215`, wrapped across two `///` lines); the arm's "Only the create
  request can say the name is taken." (base `:237`); "The bucket could not be
  created." (base `:325`); the whole old `createdIncompletelyTemplate` — name,
  key `s3.createBucket.error.createdIncompletely %@` and the full English
  sentence (base `:330–332`); the two withdrawn `isOffered` calls in
  `theActionIsOfferedOnlyInBucketListMode` (base tests `:208–209`); and the
  Task 10 clause "…it can be chosen when a bucket is created", which is present
  in `en.lproj`. Three withdrawals carry no quote — **N4**.
- **A negative check needs a positive beside it.** The new negatives all have
  one: `#expect(!arm.contains("context.bucket != nil"))` sits under three
  positives and a `#require` anchor; `#expect(unnamed.isEmpty)` under
  `read.count >= 15`; `#expect(!quoted)` under
  `sentence == notCreatedLine.text`; `#expect(!problem.contains("%"))` under
  `problem.contains("_")`; `#expect(free.showsNameIsTaken == false)` under
  `taken.showsNameIsTaken == true`, written as the control.
- **A figure travels with its command, in the form committed.** The diff's own
  figures hold: `#expect(shown.count == 9)` matches the array (9 lines),
  `read.count >= 15` against an actual 27, 23 keys per locale in all four. The
  one bare figure in the fix report does not — **N3**.
- **`#expect` prints its source text.** M5's fix follows the sibling shape and
  introduces no new leak; no other expectation in the diff carries a planted
  value in its expression.
- **No wall-clock ceiling, no blocking wait.**
  `/usr/bin/grep -n 'DispatchSemaphore\|syncShutdownGracefully\|futureResult.wait\|ContinuousClock\|Date()\|elapsed\|timeLimit' Tests/macSCPAppKitTests/CreateBucketSheetTests.swift`
  prints nothing. Every wait in the new tests is an `await`.
- **Four catalogues, `en` the source.** 23 keys each, the rename landed in all
  four, `en` carries the source text the other three were written against.

---

## New findings

### N1 — M8's guard sits at the model; the view can be regressed to the pre-fix condition undetected (Minor)

**Where:** `Sources/MacSCPAppKit/CreateBucketSheet.swift`, `CreateBucketSheet.body`
(`if model.showsNameIsTaken {`), and `CreateBucketSheetTests`.

**What is wrong:** every M8 assertion reads the *model's* `showsNameIsTaken`.
Nothing requires the view to read it. Restoring the exact pre-fix condition in
the view reintroduces the defect M8 was filed for — the taken-name line beside
"A bucket named “X” exists now…" on a partial failure — and the suite does not
notice:

```
RP3 --filter 'CreateBucketSheetTests|ConnectionActionRouteTests' \
    --apply "perl -0pi -e 'die … unless s/if model\.showsNameIsTaken \{/if model.nameIsTakenKey != nil, !model.isCreated {/' Sources/MacSCPAppKit/CreateBucketSheet.swift"
── control: 60 test(s) ran, 0 pre-existing failures
RESULT: GREEN — 60 test(s) ran and NONE of them noticed the plant.
```

and again with every guard that reads this view in the filter:

```
RP3b --filter 'CreateBucketSheetTests|BoundedViewLayoutGuardTests|BoundedViewStateOnScreenTests|BoundedViewCoverageTests|RigidControlScanTests'
── control: 81 test(s) ran, 0 pre-existing failures
RESULT: GREEN — 81 test(s) ran and NONE of them noticed the plant.
```

`everyMemberTheViewReadsIsNamedByATest` cannot see it: the plant's three
replacement members (`nameIsTakenKey`, `isCreated`) are all named by tests, and
`read.count` stays above 15.

**Why it is Minor, not Important:** no defect is present in the committed tree;
the behaviour is correct and the decision is in one place. This is the guard's
reach, not the code's correctness — the same shape as I2, one level up, with the
derived value tested and the view's read of it not.

**A fix would** add one `BoundedViewRegistry` state this view does not have: a
partial failure whose bucket name is also in `existingNames`
(every existing entry either has no taken name or no failure outcome, which is
why RP3 is invisible to the on-screen guards), so the contradictory pair is on
screen in a state a guard renders.

### N2 — the sweep's substring check buys a name that is a substring of one already mentioned (Minor)

**Where:** `Tests/macSCPAppKitTests/CreateBucketSheetTests.swift`,
`everyMemberTheViewReadsIsNamedByATest`, `tests.contains($0)`.

**What is wrong:** the replacement for the undiagnosed `\b` draft is a plain
substring test, so a member whose name is a substring of a name the suite
already spells is treated as named. Measured, same plant shape as the one that
is RED 3 of 3, with only the new member's name changed to `nameIsTaken` (bought
by `nameIsTakenKey`, `showsNameIsTaken` and `nameIsTakenLine`):

```
RP2 --filter 'CreateBucketSheetTests|ConnectionActionRouteTests' \
    --apply "perl -0pi -e 'die … unless s/(var showsNameIsTaken: Bool \{ nameIsTakenKey != nil && !bucketMayExist \})/$1\n\n    var nameIsTaken: Bool { false }/; die … unless s/\.disabled\(!model\.versioningCanBeChanged\)/.disabled(!model.versioningCanBeChanged || model.nameIsTaken)/' Sources/MacSCPAppKit/CreateBucketSheet.swift"
── control: 60 test(s) ran, 0 pre-existing failures
RESULT: GREEN — 60 test(s) ran and NONE of them noticed the plant.
```

RP1, identical but for naming the member `zzzNothingNamesThis`, is RED 3 of 3.
So the guard's sensitivity depends on the spelling chosen, and this project's
member names are families of prefixes (`nameIsTaken*`, `versioning*`,
`isCreat*`), which is the worst case for a substring test.

**A fix would** either restore a word-boundary match — diagnosed this time, with
the verdict measured by repetition rather than the message trusted — or follow
the structural route in the sweep verdict above.

### N3 — the fix report's "35 sites" is wrong, and is the only bare figure in it (Minor)

**Where:** `task-11-fix-1-report.md`, M6: "spelled at every construction site
(35 sites in tests and the registry, …)".

**What is wrong:** the figure matches nothing I can measure. Counting
occurrences, not lines:

```
git grep -o 'CreateBucketModel(' 1d1dcec2 -- Tests | awk -F: '{print $2}' | sort | uniq -c
```

→ `41 Tests/macSCPAppKitTests/CreateBucketSheetTests.swift`,
`7 Tests/macSCPAppKitTests/BoundedViewRegistry.swift` = **48**, and
`/usr/bin/grep -c 'CreateBucketModel(' …CreateBucketSheetTests.swift` → 41 with
`/usr/bin/grep -o … | wc -l` → 41 as well, so no two occurrences share a line
and none sits on a comment line. Nor is 35 the number of sites the diff
*changed*: `git diff d7c6631c..1d1dcec2 -- Tests | /usr/bin/grep -c '^+.*CreateBucketModel('`
→ 40, and `… | /usr/bin/grep -o '^+.*listingIsKnown:' | wc -l` → 44. The
report's "none in Sources besides the `Listing` convenience init" is right:
one occurrence in `Sources/MacSCPAppKit/CreateBucketSheet.swift`.

This is the rule the project has a section for — the figure was written without
the command, so being wrong cost nothing. The code it describes is correct; only
the count is. (The pathspec `-- Tests` is what keeps this paragraph from
answering its own command: this file is under `.superpowers/`.)

**A fix would** correct the report's figure and write the command beside it.

### N4 — three withdrawals in this diff carry no quote while seven do (Minor)

**Where:** `Sources/MacSCPAppKit/CreateBucketSheet.swift` and
`Tests/macSCPAppKitTests/CreateBucketSheetTests.swift`.

```
git diff d7c6631c..1d1dcec2 | /usr/bin/grep -c -e '^-.*The create went through and the versioning request after it did not' -e "^-.*And the arm is the inverse of its neighbours" -e '^-.*#expect(model.bucketMayExist == false)'
```

→ 3, and `git grep -c -e 'The create went through and the versioning request after it did not' -e "And the arm is the inverse of its neighbours" -- Sources Tests`
exits 1 (no match), so neither sentence is quoted anywhere in the tree:

1. the doc comment on the old template, "The create went through and the
   versioning request after it did not." — the very authorship claim M2
   withdraws, replaced by a new sentence whose correction paragraph quotes the
   catalogue text but not this line;
2. `theRoutesGateAsksTheModelsRule`'s "And the arm is the inverse of its
   neighbours' bucket test: a row that is live only AT the list.", together with
   the `#expect(arm.contains("context.bucket == nil"))` it described — the claim
   is no longer true of the arm, and nothing records that it was made;
3. `aFindingSaysItsOwnSentence`'s `#expect(model.bucketMayExist == false)`,
   removed because it is no longer true of one of the two findings. This one is
   accounted for next door, in the doc comment of
   `aBucketTheStoreSaysYouOwnIsTakenAndTheListIsStale`.

CLAUDE.md scopes the quoting rule to the measurement record, and a code comment
is not that, so this is an inconsistency with the round's **own** practice
rather than a breach of the written rule — seven passages in the same diff do
quote, including comments. Filed so the next reader of these comments is not
told the old reading never existed.

---

## What I could not check

- **The first draft of the sweep's `\b` regex.** Never committed
  (`git diff c50759d0..1d1dcec2 --stat` is one file, one line), so its
  nondeterminism cannot be reproduced from the record. I established that the
  `Set`-ordering mechanism is real here and that it cannot explain a membership
  change, and that `SourceCorpus`/`PerKeyCache` is not a candidate; the actual
  cause stays unknown.
- **The full suite.** I did not run `swift test` whole. What I have instead is
  eight control runs of three filters, all with **0 pre-existing failures** —
  60 tests (`CreateBucketSheetTests|ConnectionActionRouteTests`), 58
  (`…|BoundedViewLayoutGuardTests|BoundedViewStateOnScreenTests`) and 81 (with
  the coverage and rigid-control scans added). The report's Core 5075 / App 2812
  figures and its one pre-existing red (`ViewTestabilitySpike`) are not
  re-measured here.
- **Twenty of the twenty-three recorded probes.** Three were re-run (P3, P16,
  P17) and all three reproduced exactly; the other twenty are believed on the
  record, which is now re-runnable as committed — the point of I4.
- **Per-commit greenness.** The fix report claims each of the four commits is
  green on its own; I checked only HEAD. M7 is out of scope, so the two
  pre-existing red commits beneath `d7c6631c` are untouched by design.
- **The rig and the GUI.** Neither was started. Nothing in this round touches
  the store path; the 404 → `.notFound` premise is still a reading of
  `S3ErrorCode.finding(forCode:status:path:)`, not a request.
- **Scope of the RP3 GREEN.** 81 tests, the five suites that read this view. I
  did not plant RP3 against the whole App suite, so "nothing in the tree catches
  it" is a claim about those five suites, not about 2812 tests.

---

## Verdict

| finding | verdict |
|---|---|
| I1 | CLOSED |
| I2 | CLOSED |
| I3 | CLOSED |
| I4 | CLOSED |
| M2 | CLOSED |
| M4 | PARTLY |
| M5 | CLOSED |
| M6 | CLOSED (code); its figure is wrong, N3 |
| M8 | PARTLY |
| M1 / M3 / M7 | untouched, as instructed |

Four new Minor findings, no new Important, no Critical. **The gate can close on
the four Important; it should not close on M4 and M8 without the two small
additions named above** — one English-clause expectation for M4, one registry
state for M8 — both of which are the difference between a guard at the model and
a guard on what a person reads.

Tree left clean and committed; all eight probes reverted through the harness,
`git status --porcelain` empty after each. No rig bucket was touched and the GUI
was never launched.
