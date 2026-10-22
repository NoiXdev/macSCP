# Task 11 review: the create-bucket sheet

Reviewer pass over BASE `8e21f073` .. HEAD `d7c6631c` (4 commits), in the
worktree `/Users/noidee/macSCP/.claude/worktrees/diff-view`. Written from the
diff and from commands run on the committed tree, not from the report.

Note on the brief: the re-extracted `task-11-brief.md` given to this review is
350 lines and DOES contain the section "Where `existingNames` comes from, and
the trap in it" (`grep -n existingNames task-11-brief.md` prints lines 134 and
154). The report's claim that the brief it worked from had no such section is
judged charitably per the controller's correction; the code below is judged
against the brief as given.

---

## Verdict 1 — spec compliance, step by step

### Step 1, the six test bodies the implementer's brief carried

Each is present in `Tests/macSCPAppKitTests/CreateBucketSheetTests.swift` with
the brief's name and values.

| Brief body | Committed | Verdict |
|---|---|---|
| `aNameTheStoreWouldRejectBlocksTheButtonAndSaysWhy` | same name, `"My_Bucket"`, `canCreate == false`, `problem == .uppercase` | done as written |
| `objectLockIsFinalAndTheSheetSaysSo` | same name, `objectLockNoteKey == "s3.createBucket.objectLockIsFinal"` | done as written |
| `objectLockImpliesVersioning` | same name and both expectations | done as written |
| `theModelHandsCoreTheOneChoiceCoreAccepts` | same name, all four `protection` expectations in the brief's order, including the refused untick | done as written |
| `theActionIsOfferedOnlyInBucketListMode` | same name, both expectations | done as written |
| `aNameAlreadyInTheListBlocksTheButton` | same name, `existingNames: ["macscp-seed", "macscp-second"]`, `"macscp-seed"`, `"macscp-third"`, the `nameIsTakenKey` value, and the positive control; one extra assertion (`nameIsTakenKey == nil` on the free name) | done as written, strengthened |

The comment bodies are carried over too, including the "spec §6.1 withdrew"
reasoning and the measured-on-the-rig note.

### Step 1, the seventh body — NOT done as written

`theRowIsLiveOnlyWhileThePaneIsSHOWINGTheBucketList` and the signature change
it carries (`isOffered(rootIsContainerList:paneBucket:)`) are absent.
`CreateBucketModel.isOffered` has one parameter, and the pane half of the rule
lives in the route's arm instead:

```
context.settings != nil
    && CreateBucketModel.isOffered(rootIsContainerList: context.rootIsContainerList)
    && context.bucket == nil
```

The brief's own prose prescribes exactly this arm text
(`context.settings != nil && context.rootIsContainerList && context.bucket == nil`)
while also prescribing the two-parameter predicate, so the brief is internally
split; the implementer landed the arm and not the predicate. See finding **I3**:
the PROPERTY (live only at the list) is covered by
`createBucketIsLiveOnlyAtTheBucketList` and by probes P1–P3, so nothing is
unguarded — but `isOffered(rootIsContainerList:)` is now the identity function
on its argument, and the rule the brief wanted inside the model is split across
two files.

### The four dated controller amendments

1. **2026-10-20, the wiring** (`route case` / dispatcher arm / sheet item /
   presentation / `BoundedViewRegistry` entries / `BoundedViewCoverageTests`
   floor). **Done as written.** `ConnectionActionRoute.createBucket =
   "s3.createBucket"`, an arm in `ContentView+MenuActions.swift`,
   `ContentView.CreateBucketSheetItem`, `.sheet(item: $createBucketSheetItem)`
   in `ContentView+Sheets.swift`, seven registry entries, floor 37 → 38.
   `ContentView+Lifecycle.swift` is listed in the brief's file list but needed
   no change: the hook there already reads
   `connectionActionIsAvailable($0, in: activeTab, session: session)`
   (`ContentView+Lifecycle.swift:68`), which routes to
   `ConnectionActionRoute.isAvailable`. Defensible, and the report says so.
2. **2026-10-19, `createBucket(_:protection:)` not `(_:versioning:objectLock:)`.**
   **Done as written.** No pair of `Bool`s reaches Core; `protection` folds
   them, lock first.
3. **2026-10-20, `isOffered(rootIsContainerList:)` not `isOffered(rootMode:)`.**
   **Done as written.** Nothing in the App names `S3FileSystem.RootMode`.
4. **2026-10-21, Task 10's sentence.** **Done as written**, and verified below
   (singled-out item 6).

The brief's optional suggestion — "a test that asserts no two of the four are
live at the same place" — is partly honoured:
`createBucketIsLiveOnlyAtTheBucketList` ends with a loop asserting the three
neighbours are dead at the list and live inside a bucket, which is the
partition for the two places that matter.

### Steps 2–5 (red, implement, catalogue, commit)

- Red quoted verbatim in the report for Core
  (`value of type 'RemoteBrowserViewModel' has no member 'listedItems'`) and
  for the App (`cannot find 'CreateBucketSheet' in scope`, `type
  'ConnectionActionRoute' has no member 'createBucket'`). The Core red is
  structurally real: `git grep -n listedItems 8e21f073` prints nothing, so the
  test could not have compiled at BASE.
- Catalogue: 23 keys per locale in all four, confirmed with
  `grep -c '^"s3.createBucket' Sources/MacSCPAppKit/Resources/<l>.lproj/Localizable.strings`
  → `en 23, de 23, fr 23, pl 23`, and
  `grep -o '"s3\.createBucket\.[^"]*"' Sources/MacSCPAppKit/CreateBucketSheet.swift | sort -u | wc -l`
  → 23. German is du-form throughout ("Nimm", "deinen Speicherkosten",
  "Wähle einen anderen Namen", "Aktualisiere die Liste").
- Commit message is the brief's exact text for the main commit.

---

## The seven singled-out items

### 1 — `RemoteBrowserViewModel.listedItems`, the only Core change

**Is it the minimum?** Yes. Nine lines, six of them comment, one computed
`public var listedItems: [RemoteFileItem] { displayedAll }` over an existing
private stored property (`Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift`,
symbol `listedItems`, directly under `displayedAll`). No new state, no new
writer, no behaviour change for any existing reader.

**Does it duplicate something under another name?** No. Before this task the
only public `[RemoteFileItem]` members were `items` (post-search) and
`selectedItems`; a grep for `public var .*[RemoteFileItem]` on the file prints
exactly `items`, `selectedItems`, `listedItems`. `displayedAll` was private,
and `git grep -n listedItems 8e21f073` prints nothing.

**Is the red real?** Yes, structurally: the symbol did not exist at BASE, so
`RemoteBrowserViewModelTests.listedItemsIgnoreTheSearchFilter` could not
compile — the quoted `value of type 'RemoteBrowserViewModel' has no member
'listedItems'` is the only red it could have produced. The test has its
positive control in its last line (`vm.listedItems == vm.items` with the
filter cleared), so it is not satisfiable by a member that returns `[]`.

**Is it named for what it is?** This is the one weak point (finding **M1**).
`listedItems` and `items` are one word apart and neither name says which is
filtered; the distinction is carried entirely by the doc comment. The property
is "the listing before the search filter" — `itemsBeforeSearch`,
`unfilteredItems` or `directoryContents` would make the wrong choice harder to
write. The mistake this guards against has already been made once in this very
task (`items` was the implementer's first choice).

**The `.loaded` condition, and what the sheet does when the listing is NOT
known.** `CreateBucketModel.listing(of:)` returns
`isKnown: browser.state == .loaded`, and `RemoteBrowserViewModel.State` has
exactly three cases (`loading`, `loaded`, `failed(message:)`), so `.loaded` is
the only affirmative one and the condition is right. **The arm that covers an
unknown listing exists and is not silent:**

- `canCreate` opens with `return listingIsKnown && problem == nil && …`, so
  Create is dead;
- `create(via:)` is guarded by `canCreate`, so nothing reaches the store;
- `listingUnknownKey` → `s3.createBucket.listingUnknown`, rendered red under
  the name field, tells the person why and what to do ("Refresh the list, then
  try again"), in all four languages;
- `aListThatWasNeverReadCannotVouchForANameBeingFree` pins all three
  (`canCreate == false`, the key, `settings.creates.isEmpty`) and carries its
  own positive control (`CreateBucketModel(existingNames: [])` →
  `listingUnknownKey == nil`), and `aListingThatHasNotLoadedIsNotKnown` pins
  `listing(of:)` itself against a real `RemoteBrowserViewModel` before and
  after `load()`. P6 is reported RED.

So the "passes everything when the state is not `.loaded`" defect is not
present. One consequence worth recording, not a defect: the listing is a
snapshot captured at presentation time, so a sheet opened while the pane
happens to be re-reading comes up permanently unusable (there is no way to
re-ask from inside the sheet). It fails safe and the sentence tells the user to
refresh and retry, so this is noted rather than filed.

**One thing checked and clean:** `displayedAll` is the listing after the
hidden-files filter, so a "hidden" bucket could in principle be missing from
the taken-name check — but a bucket name cannot begin with `.`
(`BucketNameProblem.badEdge`: it must start and end with a lowercase letter or
digit), so no bucket can be hidden. The accessor is adequate for this caller.

### 2 — the failure-path disambiguation nobody asked for

The mechanism (`CreateBucketModel.failure(for:bucket:protection:via:)`) is:
`.bucketNameTaken`/`.bucketAlreadyOwnedByYou` → the finding's own sentence, no
read; `protection == .none` → the refusal sentence, no read; otherwise ONE
`versioning(ofBucket:)` read, and then bucket found → `createdIncompletely`
(+ name into the taken set, `bucketMayExist: true`), `RemoteFSError.notFound` →
the create's own refusal sentence, anything else → `mayExist` (+ taken set,
`bucketMayExist: true`).

**Is an extra request on a failure path right here?** Yes, on balance. It is
one GET, only after a failure, only when a protection was asked for, and what
it buys is the difference between "nothing happened" and "a bucket exists that
you did not finish configuring and must not create again" — on a call whose own
doc comment says it does not delete what it made. The cheaper alternative
(always say "may exist") would train the user to ignore the sentence. The read
is correctly skipped in the two cases where it could tell nothing new.

**Does each of the three sentences say something true?** Two of three, with a
caveat on the first.

- `createdIncompletely` asserts "The bucket “X” was created, but switching on
  versioning failed." The read it is derived from answers *does a bucket of
  this name exist now*, not *did this request create it*. Those come apart when
  the bucket pre-existed but was absent from the pane's listing — a stale list,
  or a create refused with `permissionDenied` on a bucket the key can still
  read. Then the sheet asserts a creation that did not happen. The hedge that
  follows ("It may not have the settings you chose. Open Versioning and Object
  Lock for it to see what it has, and do not create it again") keeps the
  *advice* correct in that case, so the damage is a false clause rather than
  harmful instruction. Finding **M2**.
- `notFound` → "The bucket could not be created." True whenever the premise
  below holds.
- `mayExist` → "Creating the bucket did not finish, and the bucket may exist
  now. Refresh the list; if it is there, open Versioning and Object Lock…"
  **The hedge is honest**: it asserts only non-completion, which is known, and
  marks existence as unknown, which it is.

**Is the fallback on the safe side as claimed?** Yes. The unknown-answer arm
inserts the name into the taken set and sets `bucketMayExist: true`, which both
blocks the re-create inside the sheet and triggers the pane refresh. The
`protection == .none` arm does not (`bucketMayExist: false`, name left free) —
defensible, because a no-protection re-create sends no versioning request and
so opens no one-way door, but note that "The bucket could not be created." is
then asserted with no check at all, and a create that timed out after the store
made the bucket would be reported as a plain failure. Low consequence; rolled
into **M2**.

**Is the unmeasured premise load-bearing?** Reviewed by reading Core, not by
running the rig. `S3FileSystem.mapErrorStatus` maps 404 → `.notFound(path:)`
**only if** `S3ErrorCode.finding(forCode:status:path:)` returns `nil` for the
body's code, and that function names five codes —
`ObjectLockConfigurationNotFoundError`, `BucketNotEmpty`,
`BucketAlreadyExists`, `BucketAlreadyOwnedByYou`, `NotImplemented` — none of
them `NoSuchBucket`. So the implementer's reading is correct for any store that
answers a missing bucket's `GET ?versioning` with 404 and a
`NoSuchBucket`-or-unnamed code.

**It is load-bearing for precision, not for safety.** If a store answers
otherwise, the error does not match `catch RemoteFSError.notFound` and the code
falls into the generic arm — the `mayExist` sentence plus the taken-set
insertion, i.e. the conservative outcome. The unmeasured premise buys only the
*stronger* sentence; being wrong about it loses the sentence, not the
protection. That is an acceptable place to leave a reading unmeasured, and the
report says plainly that it is one.

**One real asymmetry in this mechanism — finding I1.**
`.bucketAlreadyOwnedByYou` is the store's named statement that a bucket of this
name exists *in this account*. The code treats it as `bucketMayExist: false`
and does **not** add the name to the taken set, so after that refusal:
`canCreate` goes back to `true` (the same freeing
`aRefusedPlainCreateSaysItWasNotCreatedAndNamesNoCause` asserts deliberately
for a generic refusal), `nameIsTakenKey` stays `nil` so the sheet never says
"choose a different name", and `onCreated()` is not called so the pane's stale
list is never refreshed to show the bucket that does exist. The model adds the
name to the taken set when a bucket *may* exist and not when the store says it
*does*. (`.bucketNameTaken` — another account's bucket — is correctly left out:
adding it would make the `nameIsTaken` sentence, "Your list already has a
bucket with this name", false.)

### 3 — P9, re-run on the committed tree

Re-run by me through the harness, on `d7c6631c` with a clean tree; plant =
remove `if objectLock && !versioning { versioning = true }` from
`CreateBucketModel.versioning`'s observer, by a perl script outside the
repository that asserts its anchor and dies on a miss:

```
scripts/mutation-probe --label "P9 re-run (reviewer)" \
  --filter 'CreateBucketSheetTests|ConnectionActionRouteTests' \
  --apply "perl <scratchpad>/plant-p9.pl Sources/MacSCPAppKit/CreateBucketSheet.swift"
```

Observed:

```
── control: 49 test(s) ran, 0 pre-existing failures
RESULT: RED — 49 test(s) ran, and the plant was caught by:
  macSCPAppKitTests.CreateBucketSheetTests/theLockRefusesToLetVersioningBeUntickedAndShowsItTicked()
```

Tree clean afterwards (`git status --porcelain` empty). The hole the implementer
found is closed, by exactly one test, named — one run, which is evidence the
guard *can* catch it, not a sensitivity figure.

**The question the GREEN exposed, answered: no, and there is more of it.**
Counted on the committed test file with
`/usr/bin/grep -o <member> Tests/macSCPAppKitTests/CreateBucketSheetTests.swift | wc -l`:
`problemSentence` 0, `createdSentence` 0, `isEditable` 0, `isCreating` 0 —
four user-visible members no test in the suite reads, each covered only by a
derived value that happens to be right (`problemLine`/`problem`, `isCreated`,
`canCreate`, `outcome`). I probed the two that carry a format argument:

```
scripts/mutation-probe --label "R1 reviewer: the two %@ sentences no test reads" \
  --filter 'CreateBucketSheetTests|BoundedViewLayoutGuardTests|BoundedViewStateOnScreenTests' \
  --apply "perl <scratchpad>/plant-r1.pl Sources/MacSCPAppKit/CreateBucketSheet.swift"
```

plant: `problemSentence` returns `line.text` unformatted and `createdSentence`
returns `Self.createdLine.text` unformatted — i.e. a person sees a literal
`“%@”` where the character or the bucket name belongs, in all four languages.

```
── control: 47 test(s) ran, 0 pre-existing failures
RESULT: GREEN — 47 test(s) ran and NONE of them noticed the plant.
```

The layout guards were in the filter on purpose, so this is not "no unit test
reads it" but "nothing in the tree reads it". Finding **I2**. (The third `%@`
sentence, `createdIncompletelyLine(bucket:)`, IS pinned, by
`aFailureOfTheSecondRequestSaysTheBucketWasCreated`'s
`#expect(sentence.contains("macscp-third"))` — exactly the shape the other two
want.)

### 4 — the route arm

The arm is the inverse of its three neighbours, as required
(`Sources/MacSCPAppKit/ConnectionActionRoute.swift`, `isAvailable(in:)`,
`case .createBucket`):
`context.settings != nil && CreateBucketModel.isOffered(rootIsContainerList:) && context.bucket == nil`.

**Is the scan a positive check with its own positive control?** Yes.
`CreateBucketSheetTests.theRoutesGateAsksTheModelsRule` asserts
`arm.contains("CreateBucketModel.isOffered(")` and
`arm.contains("context.bucket == nil")` — both positive, both fail loudly if
the text moves — and its anchor is
`try #require(source.range(of: "case .createBucket:"))`, the positive control
that the region exists at all. It reads `SourceCorpus.code`, which blanks
comments *and* string literals (`Tests/MacSCPTestSupport/SourceCorpus.swift`,
`code(of:)` → `SwiftSource.blankingCommentsAndStrings`), so the arm's own long
doc comment — which names `isOffered` in prose — cannot satisfy the scan. That
is the "source-scanning guards read comments too" trap, avoided.

**Is the row asserted dead inside a bucket as well as live at the list?** Yes.
`ConnectionActionRouteTests.createBucketIsLiveOnlyAtTheBucketList` asserts live
at `/` and `//`, dead at `/macscp-seed` and `/macscp-seed/x/`, dead without the
capability, dead on a one-bucket connection with both a configured bucket and a
blank one (the case a `bucket == nil` test alone would let through), and ends
with the mirror loop over `versioning`/`cors`/`objectLock`. Positives precede
every negative. P1–P3 are reported RED.

**One looseness, not filed:** `theRoutesGateAsksTheModelsRule` derives the
"arm" as the text from `case .createBucket:` to the next `case .`, and
`.createBucket` is the last case in that switch, so the span actually runs to
end of file (one small `static func` follows). It narrows by itself when a
fifth route lands. The same holds for
`theDispatcherHandsTheSheetTheRemotePanesListing` and
`aMadeBucketRefreshesThePaneThatListsIt` in `ContentView+MenuActions.swift`.

### 5 — the pre-existing test the new row falsified

`ConnectionActionRouteTests.aWiredIdIsAvailableAndAnUnwiredOneIsNot` now asks
that a wired id be live in **at least one** of two contexts (inside one bucket;
at the list of a bucket-list connection), and an unwired id in **neither**. The
old wording is quoted in the doc comment, including the removed line
`let context = Self.inOneBucket()`.

**Is it still a guard?** Yes, and weakened in a bounded way. Before: every
wired row is reachable, in one specific place. Now: every wired row is
reachable *somewhere among the two places this app has rows for*. The property
that actually matters — a wired id live nowhere, i.e. a view with no reachable
route, which this plan has produced repeatedly — is still caught: a row dead in
both contexts is red. What it no longer catches is a row live in the *wrong*
one of the two, and that is picked up by each row's own test
(`versioning…`, `cors…`, `objectLock…`,
`createBucketIsLiveOnlyAtTheBucketList`), all of which assert both halves. The
unwired half was *strengthened* (now checked in both contexts).

Applying "only a negative check can go stale in silence": the weakened half is
the positive one, which cannot go stale silently — it fails the moment a row is
live nowhere. The negative half is unchanged and is flanked by
`#expect(!wired.isEmpty)` and
`#expect(wired.count + unwired.count == Self.everyAction.count)`. Accepted as
written; the residue is that the two contexts are now a hand-written list a
future third place would have to be added to, and nothing says so. Filed as
**M3** (a note, not a code change).

### 6 — Task 10's sentence

**The clause is now true.** `s3.objectLock.notEnabledOnThisBucket` ends "…it
can be chosen when a bucket is created", and the sheet offers
`CheckboxRow(CreateBucketModel.objectLockLabel.text, isOn: $model.objectLock)`,
whose tick reaches Core as `BucketProtection.lockedAndVersioned`
(`protection`), which `S3FileSystem.createBucket` turns into
`x-amz-bucket-object-lock-enabled: true` on the create itself
(`protection.enablesObjectLock`). The sentence's other clause — "macSCP does
not switch it on for a bucket that already exists" — is also still true: this
task added no enabling call, and the protocol comment forbidding one is
untouched. The sentence was correctly left unchanged in all four catalogues.

**Checked per locale** (`grep '^"s3.objectLock.notEnabledOnThisBucket'` and
`grep '^"s3.createBucket.objectLock"'` in each `.lproj`):

| locale | label | named in the sentence |
|---|---|---|
| en | `Object Lock` | yes ("Object Lock is not switched on…") |
| de | `Objektsperre` | yes ("Die Objektsperre ist…") |
| fr | `Verrouillage d’objet` | yes ("Le verrouillage d’objet n’est pas activé…", same typographic apostrophe) |
| pl | `Blokada obiektów` | yes ("Blokada obiektów nie jest włączona…") |

**Does the new guard read the label rather than spelling it twice?** Yes.
`theObjectLockSentenceNamesWhatTheCheckboxIsCalled` reads both sides from the
catalogue through the symbols that own them
(`ObjectLockLines.notEnabledOnThisBucket.text` and
`CreateBucketModel.objectLockLabel.text`) under `L10n.$localeOverride`, and
compares with `localizedCaseInsensitiveContains`. No literal is spelled, which
is the rule in "a guard that spells a symbol it could read is waiting for a
rename".

**But it does not guard the clause it is named for** — finding **M4**. What it
pins is that the two strings share a noun. Delete the final clause ("…it can be
chosen when a bucket is created") from all four catalogues and the test stays
green, because the sentence still opens with the label. The thing this task was
to make true is therefore still unguarded. Not probed by the implementer
either, as its report says.

### 7 — concern 2: is the cause-naming sentence only shown where Core produced it?

**Yes, and it is never inferred.** The only path to a cause-naming sentence is
`CreateBucketModel.refusalSentence(for:)`, whose first arm is
`case RemoteFSError.finding(let finding): finding.message` — the text belongs to
the finding Core constructed, and Core constructs
`.bucketNameTaken`/`.bucketAlreadyOwnedByYou` only from
`S3ErrorCode.finding(forCode:…)` matching the literal store codes
`BucketAlreadyExists`/`BucketAlreadyOwnedByYou`
(`Sources/macSCPCore/S3/S3ErrorCode.swift`). The model never builds a finding,
never parses a message, never guesses one from a status: the other two arms are
a fixed denied sentence (for `permissionDenied`/`authenticationFailed`) and a
fixed "could not be created" sentence. The early-out in
`failure(for:bucket:protection:via:)` matches the two findings by case, not by
text, and only to skip a read that could tell nothing new —
`aTakenNameFindingNeedsNoFollowUpRead` pins `settings.reads.isEmpty` for it.

`aFindingSaysItsOwnSentence` loops over both findings and asserts
`failureSentence == finding.message`, so the mapping is pinned on the test side
too. Execution of the ruling: correct. (The behavioural gap next to it is
**I1** above, which is about the taken set, not about the sentence.)

---

## A note on counting the amendments

The dispatch names "four dated controller amendments". The re-extracted brief's
Task 11 portion carries eleven dated markers
(`grep -o` for `Added/added/Corrected/Extended 2026-10-NN` prints 11, several
of them repeats of the same intervention). The six distinct ones, and where
each is accounted for above: the wiring (2026-10-20) and the
`isOffered(rootIsContainerList:)` correction (2026-10-20) and the gate's
consumer (2026-10-20) → "The four dated controller amendments"; the
`createBucket(_:protection:)` correction (2026-10-19) → same;
`theModelHandsCoreTheOneChoiceCoreAccepts` (2026-10-21) → the Step 1 table;
the `existingNames` section with `isOffered(rootIsContainerList:paneBucket:)`
and `theRowIsLiveOnlyWhileThePaneIsSHOWINGTheBucketList` (2026-10-21) → "the
seventh body" and **I3**; Task 10's sentence (2026-10-21) → singled-out item 6.
None is left unexamined.

---

## Verdict 2 — task quality

### Correctness

The model's core logic is right where it matters. `protection` folds the two
switches lock-first, so the unrepresentable combination can never reach Core
(`everyChoiceCoreAcceptsIsOneTheSheetCanProduce` also closes the other
direction: every `BucketProtection.allCases` member is reachable from some pair
of switches). `canCreate` requires a known listing, a valid name and a free
name, and `create(via:)` re-checks it, so no taken name reaches the store
(`aTakenNameNeverReachesTheStoreEvenIfAskedTo`). The `init` ordering fix in
`d7c6631c` is correct and explained in a comment that names the cause
(observers on an `@Observable` class run in `init`); the double write to
`outcome` it needs is ugly but honest.

Two behavioural gaps, both named above: **I1** (the
`.bucketAlreadyOwnedByYou` refusal does not mark the name taken and does not
refresh) and **M2** (an existence read reported as authorship). One UI
consequence of the same area: **M8**, a partial failure renders the
`createdIncompletely` sentence AND the `nameIsTaken` red line ("Your list
already has a bucket with this name. Choose a different name.") at the same
time, because the latter is suppressed only by `!model.isCreated` and the
outcome here is `.failed`. The success case was thought about; the partial
failure was not.

Core-side: no change beyond `listedItems`, no case added to
`BucketProtection`, nothing in Core learns about windows or sheets.

### The tests' sensitivity

- 36 tests in `CreateBucketSheetTests` (`/usr/bin/grep -c '@Test func'` → 36),
  plus one Core test and one new route test, plus the widened route test and
  the three updated scans. The report's figure of 36 is right.
- Every negative check I found has a positive beside it:
  `#expect(uncovered.isEmpty)` is preceded by `#expect(used.count > 0)`;
  `settings.creates.isEmpty` has `aPlainBucketIsSentWithNoProtection` and
  `theSwitchesAreSentToTheNamedBucketAsOneChoice` as controls;
  `listingUnknownKey == nil` is the control for the unknown-listing case;
  `createBucketIsLiveOnlyAtTheBucketList` asserts live before dead;
  `aValidNameIsTheCaseTheTestAboveIsTheNegativeOf` and
  `versioningIsFreeWhileObjectLockIsOff` are explicit controls written as such.
  The Core test's control is its last line.
- Source scans read `SourceCorpus.code` (comments and string literals blanked)
  for the wiring and `SourceCorpus.commentFree` (strings kept) for the key
  sweep — the right view in each case.
- The measured hole is **I2**: four user-visible members (`problemSentence`,
  `createdSentence`, `isEditable`, `isCreating`) that no test reads, two of
  which I proved unguarded with a GREEN probe. This is the same shape as P9 and
  it was not swept for after P9 was fixed.
- Sensitivity numbers: P9 is caught by exactly one test, measured once. No
  repetition figure exists for any probe on this task (see **I4**).
- Pool and clock rules: no `DispatchSemaphore`, no `syncShutdownGracefully`, no
  `futureResult.wait()` in anything this task added; every wait is an `await`.
  No elapsed-time assertion anywhere in the new tests, so no wall-clock
  ceiling and no `.timeLimit` needed.
- `#expect` source-text rule: one breach, **M5**.

### The catalogues

23 keys × 4 locales, counted above; `en` is the source text and
`theEnglishCatalogueSaysTheDefault` pins each `english:` default against the
`en` catalogue; `everyLineResolvesInAllFourLocales` pins all four against a
sentinel; `everyKeyTheSheetUsesIsOneTheCatalogueChecksCover` closes the loop
from the source's literals back to `allLines`, so a key used and not listed is
red. German is du-form throughout and `GermanAddressFormTests` is in the suite.
`theTwoFinalSwitchesDoNotSayTheSameThing` is a good addition: it pins, per
locale, that the three one-way notes are three different sentences.

Content is honest: the Object Lock note is about irreversibility, not timing
(the brief's ruling); the versioning note names both the suspend-not-remove
asymmetry and the cost; the `listingUnknown` sentence says what macSCP cannot
check and what to do. No store text is ever quoted —
`refusalSentence(for:)`'s `default` arm is a fixed sentence, and
`aRefusedPlainCreateSaysItWasNotCreatedAndNamesNoCause` plants an endpoint-like
`reason` to prove it.

The menu row's own strings (`connection.action.createBucket`) already existed
in all four catalogues from the earlier task that added the contribution
(`BackendDescriptor.swift:522`); this task did not need to add them, and the
row was the "disabled, no arm" case the brief describes.

### The wiring

All five links exist and each has a check that is red without it: the route
case (no `default` in `handleConnectionAction`, so a missing arm does not
compile), the arm's availability
(`createBucketIsLiveOnlyAtTheBucketList`, P1–P3), `isOffered` having a caller
(`theRoutesGateAsksTheModelsRule`, P2), the dispatcher building the sheet from
the pane's listing (`theDispatcherHandsTheSheetTheRemotePanesListing`, P10),
the presentation (`theStateTheDispatcherSets…` extended with
`CreateBucketSheet`, plus the `…Item` name assertion in
`ConnectionActionRouteTests`, P11), and the refresh
(`aMadeBucketRefreshesThePaneThatListsIt`, P12/P13). The availability hook in
`ContentView+Lifecycle.swift` needed no change and the report says so, which I
confirmed by reading line 68 of that file. The `BoundedView` set equality plus
the raised floor forces the registry entries to exist.

`onCreated` is called only when `model.bucketMayExist`, which is the right
condition (it covers both a success and a partial failure, and not a refusal)
— except in the `.bucketAlreadyOwnedByYou` case, which is **I1**.

### The comments' truthfulness

Every number and enumeration I found in the diff's comments, checked in the
same pass:

| claim | where | verified |
|---|---|---|
| floor 38, "which prints 38", "a thirty-ninth view" | `BoundedViewCoverageTests` | `grep -rhn -e '^ *struct [A-Za-z]* *: BoundedView {' Sources/MacSCPAppKit \| wc -l` → **38** under the session `grep` and **38** under `/usr/bin/grep` |
| "print 13, 4 and 12: 29 lines in all, and the counts below sum to 28" | `RigidControlScanTests` | the three committed commands → **13 / 4 / 12** under both greps (29); the table sums to 13 + 4 + 11 = **28** |
| "Seven states" | `BoundedViewRegistry` | 7 `BoundedViewEntry` additions in the diff |
| "one example of each problem" / `#expect(samples.count == 6)` | `CreateBucketSheet.everyProblem`, `everyProblemTheValidatorReportsHasItsOwnSentence` | `BucketNameProblem` has exactly 6 cases (`S3BucketName.swift:7–13`), and `line(for:)` has no `default` |
| "The inverse of the three above" / "Two facts are needed" | the route arm | 3 neighbouring arms, 2 conditions beyond `settings != nil` |
| "Core makes two requests when versioning is on" | `create(via:)`'s doc comment | `S3FileSystem.createBucket`: `sendExpectingSuccess` then, under `protection.enablesVersioning`, `setVersioning(.enabled, …)` |
| "the rig answers a re-create with success" | the model's header and the commit message | quoted from `S3BucketSettings.createBucket`'s doc comment, which dates and names the measurement (`S3CreateBucketGatedTests`, 2026-10-19); not re-measured here |

Both in-place corrections (the coverage floor, the rigid-control counts) quote
verbatim the wording they withdraw and leave the previous task's paragraph
standing, which is the rule as written. The widened route test quotes the line
it removed. I found no comment in the diff that describes a caller wrongly.

One comment that overstates slightly, folded into **M2** rather than filed
separately: `create(via:)`'s doc comment says "found means the create had gone
through". Found means a bucket of that name exists.

### Record keeping

`docs/BACKLOG.md` is untouched by this task, which is right — nothing here is
deferred work, and the closeout (Task 13) owns the backlog and the user docs.
The report's concern 4 (user docs not written) is correctly deferred: the plan's
Task 13 is "Closeout — docs, backlog, and the rig's leftover" and names the
`noix-docs` guide page (`docs/superpowers/plans/2026-10-19-s3-bucket-settings.md:1410`).
No finding.

Rig and GUI: I ran no rig command and launched nothing. The rig buckets are
untouched; the new tests use a fake capability, `LocalFileSystem`, and
temporary directories they remove themselves.

---

## Findings

4 Important, 8 Minor, 0 Critical.

### I1 — a `bucketAlreadyOwnedByYou` refusal leaves the name free and the list stale (Important)

**Where:** `Sources/MacSCPAppKit/CreateBucketSheet.swift`,
`CreateBucketModel.failure(for:bucket:protection:via:)`, the first arm.

**What is wrong:** that finding is the store's named statement that a bucket of
this name exists in this account. The arm returns `bucketMayExist: false` and
does not insert the name into `takenNames`, so `canCreate` returns to `true`,
`nameIsTakenKey` stays `nil` (the sheet never says "choose a different name"),
and `onCreated()` is never called, so the pane's listing — which demonstrably
did not contain this bucket, or `canCreate` would have been false — is never
refreshed. The model is more cautious about a bucket that *may* exist than
about one the store says *does*.

**How I know:** read the arm against `canCreate` and `nameIsTakenKey`;
`aRefusedPlainCreateSaysItWasNotCreatedAndNamesNoCause` asserts
`#expect(model.canCreate == true)` for a refusal and documents the freeing as
deliberate ("The failure frees the name again: nothing was made"), and
`aFindingSaysItsOwnSentence` covers these two findings without asserting
`canCreate` or `nameIsTakenKey` at all.

**A fix would:** treat `.bucketAlreadyOwnedByYou` as evidence the name is taken
— insert it into `takenNames` and set `bucketMayExist: true` so the pane
refreshes — while leaving `.bucketNameTaken` (another account's bucket) out of
the taken set, since the `nameIsTaken` sentence says "Your list", and give that
case its own sentence if one is wanted. Whatever is chosen, a test should assert
`canCreate` and `nameIsTakenKey` per finding, which nothing does today.

### I2 — the two sentences that substitute an argument are read by nothing (Important)

**Where:** `Sources/MacSCPAppKit/CreateBucketSheet.swift`,
`CreateBucketModel.problemSentence` and `CreateBucketModel.createdSentence`
(and, less sharply, `isEditable` and `isCreating`).

**What is wrong:** no test in the tree reads them, so a defect in the
substitution is invisible. Both would show a literal `“%@”` to the user, in all
four languages — the `invalidCharacter` sentence and the confirmation of a
created bucket. It is exactly the hole P9 exposed, one layer over: the derived
value the tests do read (`problemLine`, `isCreated`) stays right.

**How I know:** `/usr/bin/grep -o problemSentence …CreateBucketSheetTests.swift | wc -l`
→ 0, same for `createdSentence`, `isEditable`, `isCreating`; and a probe through
`scripts/mutation-probe` with both substitutions dropped, filtered over
`CreateBucketSheetTests|BoundedViewLayoutGuardTests|BoundedViewStateOnScreenTests`,
reported `GREEN — 47 test(s) ran and NONE of them noticed the plant.`

**A fix would:** assert the rendered sentences the way
`aFailureOfTheSecondRequestSaysTheBucketWasCreated` already does for the third
`%@` line — the substituted character in `problemSentence` and the bucket name
in `createdSentence` — and re-run the plant to confirm RED.

### I3 — the brief's pane-level predicate and its test are absent (Important)

**Where:** `Sources/MacSCPAppKit/CreateBucketSheet.swift`,
`CreateBucketModel.isOffered(rootIsContainerList:)`;
`Tests/macSCPAppKitTests/CreateBucketSheetTests.swift`.

**What is wrong:** the brief rules that the signature becomes
`isOffered(rootIsContainerList:paneBucket:)` and carries the test body
`theRowIsLiveOnlyWhileThePaneIsSHOWINGTheBucketList` with three expectations.
Neither landed. The pane half of the rule lives in the route's arm
(`context.bucket == nil`) instead, which leaves
`isOffered(rootIsContainerList:)` returning its own argument unchanged — a
predicate that states no rule — and splits one rule across two files. The
PROPERTY is guarded (`createBucketIsLiveOnlyAtTheBucketList`, P1–P3), so
nothing is unprotected; what is missing is the brief's shape and its named
test. (The controller's correction notes the implementer's brief lacked the
section that rules this; the deviation is recorded here, not blamed.)

**How I know:** the brief at lines 143–150 and 168–175 versus the committed
signature and the arm; `grep paneBucket` over the tree prints nothing.

**A fix would:** move `bucket == nil` into the predicate as `paneBucket`, have
the arm pass `paneBucket: context.bucket`, and add the brief's test body
verbatim. `theRoutesGateAsksTheModelsRule` would then need its second
expectation re-pointed at the call rather than at `context.bucket == nil`.

### I4 — thirteen probe verdicts with no command beside them (Important)

**Where:** `.superpowers/sdd/2026-10-19-s3-bucket-settings/task-11-report.md`,
the probe table; and the four commit messages.

**What is wrong:** the table records P1–P13 as English descriptions and a
verdict. No `--filter` and no `--apply` is written anywhere, so twelve of the
thirteen cannot be re-run in the form they were committed; the report also says
"I did not capture which test caught each plant", so no RED is attributable to
a guard. This is the "a number travels with the command that produced it" rule
applied to a verdict instead of a figure, and it is why I had to reconstruct P9
from its prose description rather than re-run it.

**How I know:** `git log 8e21f073..d7c6631c --format='%H%n%B'` piped through a
grep for `probe|apply|filter|P[0-9]` matches only the commit subject line
"pin what the mutation probe found unguarded in the create sheet" and two lines
of unrelated prose; `git notes list` is empty. (My own P9 reconstruction did
reproduce the fixed state: RED, caught by the named test.)

**A fix would:** write each plant's `--apply` command (and the `--filter`) into
the report beside its verdict, with the catching test named, so the table can be
re-run rather than believed.

### M1 — `listedItems` is one word from `items` and the difference is only in prose (Minor)

`Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift`, `listedItems`.
Neither name says which is filtered; the mistake the accessor exists to prevent
was made once already in this task. A name like `itemsBeforeSearch` or
`unfilteredItems` would carry the distinction. A fix is a rename plus the two
call sites (`CreateBucketModel.listing(of:)` and the Core test).

### M2 — an existence read reported as authorship (Minor)

`CreateBucketSheet.swift`, `failure(for:…)` and the doc comment on
`create(via:)` ("found means the create had gone through"). The read answers
whether a bucket of that name exists, which is not the same as whether this
request made it; the two come apart on a stale listing or a create refused on a
bucket the key can still read, and the sheet then asserts a creation that did
not happen. The same arm's sibling, `protection == .none`, asserts "The bucket
could not be created." with no check at all. A fix would soften the clause to
what the read supports (a bucket of this name is there now) and keep the advice
that follows it unchanged.

### M3 — the widened route test's two contexts are an unannotated list (Minor)

`ConnectionActionRouteTests.aWiredIdIsAvailableAndAnUnwiredOneIsNot`. The
assertion is now "live in at least one of these two contexts", and the two are
hand-written. A fifth row live in a third kind of place would pass only if
someone remembers to add it. A fix is a sentence in the doc comment saying the
list must grow with the places rows can be live in.

### M4 — the Task 10 sentence guard does not pin the clause it exists for (Minor)

`CreateBucketSheetTests.theObjectLockSentenceNamesWhatTheCheckboxIsCalled`. It
asserts the sentence contains the checkbox's label. Deleting the final clause
("…it can be chosen when a bucket is created") from all four catalogues leaves
it green, because the sentence still opens with the label. A fix would also pin
something that only the creation clause can satisfy.

### M5 — a secret-shaped token written into an `#expect` expression (Minor)

`CreateBucketSheetTests.aRefusedPlainCreateSaysItWasNotCreatedAndNamesNoCause`:
`#expect(!sentence.contains("SECRET"))`. `#expect` prints the source text of
its expression, which is the thing the project's "two exits" rule forbids; all
four sibling suites (`BucketVersioningSheetTests`, `BucketCORSSheetTests`,
`BucketObjectLockSheetTests`, `ObjectLockSheetTests`) already do it the other
way — a named `planted` constant, a `quoted` `Bool` computed first, and both the
credential and the host checked. This test checks only the credential half. The
token here is fabricated, so nothing real leaks; the deviation from a written
rule and four precedents is the finding. A fix is to follow the sibling shape.

### M6 — `listingIsKnown` defaults to the permissive answer (Minor)

`CreateBucketModel.init(existingNames:listingIsKnown:outcome:name:)`:
`listingIsKnown: Bool = true`. A future call site that forgets the argument
gets "the bucket list is known", which is the side that lets a name through.
The plan's own sibling ruling (Task 11b, Step 3, for `bucketHasObjectLock`)
refuses a default for exactly this reason. Production cannot reach it today —
`CreateBucketSheet` always builds through `convenience init(listing:)` — so this
is a Minor. A fix is to drop the default, or default it to `false`.

### M7 — two of the four commits leave the suite red (Minor)

`75fe0553` and `b7371a8f` do not carry the `RigidControlScanTests` site entry
for `CreateBucketSheet.swift` (added only in `d7c6631c`), and that scan asserts
exact per-file equality (`RigidControlScanTests.swift:635`,
`#expect(inspected == component.sites, …)`), so both commits are red on it; the
same two are red on `entriesOfOneTypeMeasureDifferentStates`, which `d7c6631c`
exists to fix. The branch is therefore not bisectable across this task. A fix
is to squash or reorder so each commit is green.

### M8 — a partial failure shows two sentences that disagree in tone (Minor)

`CreateBucketSheet.body`: `if model.nameIsTakenKey != nil, !model.isCreated`.
After a create that failed with the bucket made, the outcome is `.failed`, so
the sheet shows "The bucket “X” was created, but switching on versioning
failed…" and, above it, "Your list already has a bucket with this name. Choose
a different name." The success case was guarded against exactly this and the
partial-failure case was not. A fix is to suppress the taken-name line whenever
`bucketMayExist` holds, not only when `isCreated` does.

---

## What I could not check

- **The rig and the GUI.** Neither was touched, by instruction. So the
  404 → `.notFound` premise is confirmed only by reading
  `S3FileSystem.mapErrorStatus` and `S3ErrorCode.finding(forCode:status:path:)`
  (where `NoSuchBucket` is deliberately unnamed), not by a request.
- **The full `swift test` run.** I did not repeat it. The two probe control runs
  establish 0 pre-existing failures within
  `CreateBucketSheetTests|ConnectionActionRouteTests` (49 tests) and within
  `CreateBucketSheetTests|BoundedViewLayoutGuardTests|BoundedViewStateOnScreenTests`
  (47 tests). The report's one red,
  `ViewTestabilitySpike` "Varying only isRegex leaves the pixels unchanged", is
  recorded as pre-existing in the Task 2, 3, 5, 7, 8, 9 and 10 records in this
  same directory.
- **P1–P8 and P10–P13.** Re-running them was not asked for, and **I4** means
  they cannot be re-run as committed without reconstructing each plant. P9 was
  reconstructed and reproduced.
- **Sensitivity as a number.** Each probe here is one run. The project's rule
  that a guard's sensitivity is measured by repetition is not satisfied by
  anything on this task, mine included.

---

## The two verdicts

**Verdict 1 — spec compliance: PASS WITH ONE DEVIATION.** All six test bodies
the implementer's brief carried are committed with the brief's names and
values, the wiring, the catalogues and the three dated corrections are done as
written, and Task 10's sentence is now true and was correctly left alone; the
one thing not done is the re-extracted brief's seventh body and its
`isOffered(rootIsContainerList:paneBucket:)` signature, whose property is
nonetheless guarded elsewhere (**I3**).

**Verdict 2 — task quality: GOOD, NOT YET CLOSEABLE.** The model is correct
where the one-way doors are, the comments' figures all reproduce under both
greps, the wiring has a red-without-it check at every link, and the sheet never
quotes the store — but a measured GREEN probe shows two user-visible sentences
nothing reads (**I2**), a definite "this name is taken" finding is treated more
loosely than a maybe (**I1**), and the thirteen probe verdicts were recorded
without the commands that produced them (**I4**).

Tree left clean and committed at `d7c6631c`; both probes reverted through the
harness, `git status --porcelain` empty. No rig bucket was touched and the GUI
was never launched.
