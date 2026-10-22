# Task 11b review

Reviewer pass over BASE `eff615ef` .. HEAD `31c39ec1` (two commits, the second
empty and carrying the probe record). Worktree
`/Users/noidee/macSCP/.claude/worktrees/diff-view`, tree clean at start and at
end. No code was changed by this review; the only writes are this file and two
probe scripts in the session scratchpad.

## Verdict 1 — spec compliance: DONE AS WRITTEN, with one step exceeded and one deviation argued

The brief's seven steps, walked:

| Step | Outcome |
| --- | --- |
| 1 — write the four failing tests | **As written.** All four appear verbatim in `Tests/macSCPAppKitTests/BucketVersioningSheetTests.swift` (`aLockBearingBucketIsNotOfferedSuspension`, `aBucketWithoutALockIsStillOfferedSuspension`, `anUnreadLockStateOffersNothingAndSaysNothingAboutLocks`, `enablingIsNeverBlockedByALock`), including their comments. Diffed against the brief: no assertion weakened, none added, the `for lock in [true, false]` loop kept. |
| 2 — watch them fail, quote the compiler | **As written.** The report quotes `BucketVersioningSheetTests.swift:41:83: error: extra argument 'bucketHasObjectLock' in call`. Not re-reproducible after the fix (the signature now exists), so taken on the report's word; the column and the shape are consistent with the committed line 41. |
| 3 — no default, explicit at every construction site, count it with its command | **Done differently, defensibly.** The parameter is on `init(current:bucketHasObjectLock:)` only; see ruling 3 below. The count reproduces exactly (see "Figures re-run"). |
| 4 — catalogue entry in four languages, says no more than the truth, German du-form | **As written.** See ruling 7. |
| 5 — wire the opener to the session cache, one load covering both reads, no blocking read to open | **As written, with a fallback the brief did not ask for.** The lock read is folded into `BucketVersioningModel.read(bucket:from:locks:)` before `load` leaves `.reading`; the sheet opens on `.reading` and nothing blocks. The deviation is `session.objectLockStates ?? ObjectLockStateCache(settings: settings)` instead of the sibling arm's `guard let states`; see ruling 4. |
| 6 — two probes, both RED | **Exceeded: seven probes, all RED.** The brief's two are P1 and P2. The probe record is commit `31c39ec1`. P5 re-run by this review: RED. P7: see below. |
| 7 — run the tests and commit with the given message | **As written.** `c98649ca` carries the brief's message verbatim; footer present. |

Spec §4's rule is applied in the direction the spec states it and no further:
`offeredStates` gates only the `.enabled → .suspended` offer, `.never`/`.suspended`
still offer `[.enabled]` whatever the lock says, and `blockedReason` is non-nil
only for a lock **read** as `true`. The three-state `Bool?` the brief insisted on
is honoured at every decision point.

## Verdict 2 — task quality: STRONG, with three Important items to settle before closeout

The model work is exact, the probes are real, and every figure in the report
reproduces from the command beside it. Three items to settle: the lock-read
failure spends reach it need not spend (I1, the controller's own concern, ruled
on below); nothing holds the sheet's **body** to drawing the blocked sentence —
the one user-visible half of the task, and the only wiring link none of the seven
probes touched (I2); and the user documentation has not shipped with the feature
(I3, disclosed by the implementer). None is a behaviour defect in what was asked
for; I2 and the Minor doc-comment staleness are the project's own documented
failure modes (an unprobed link, a stale enumeration beside changed code). All
five disclosed concerns are real and correctly characterised.

## Figures re-run (all from the repository root, in the form the report commits them)

```
grep -rno 'BucketVersioningModel(' Sources Tests | wc -l
```
prints **44** under the session `grep` and under `/usr/bin/grep` alike, split
`1` / `5` / `38` across `Sources/MacSCPAppKit/BucketVersioningSheet.swift`,
`Tests/macSCPAppKitTests/BoundedViewRegistry.swift`,
`Tests/macSCPAppKitTests/BucketVersioningSheetTests.swift` — exactly the report's
breakdown. The "before" figure of 28 reproduces as `23 + 4 + 1` from
`git show eff615ef:<each file> | grep -o 'BucketVersioningModel(' | wc -l`.

```
grep -rno 'BucketVersioningModel(current: [^)]*)' Sources Tests | wc -l
```
prints **31**, and piping that through `grep -vc 'bucketHasObjectLock'` prints
**1**: `BucketVersioningSheetTests.swift:29`, which is the doc comment quoting the
old construction. So 30 code sites name the lock and none relies on a default —
the report's claim, confirmed, with the comment hit correctly subtracted rather
than quietly dropped. The report uses `grep -o`/`wc -l` for occurrences and
`grep -vc` only where each match is already on its own output line, which is the
right way round under the project's counting rule.

`plutil -lint` is OK on all four catalogues, and each carries each new key exactly
once (2 matching lines per file for the two-key alternation).

## P5 and P7, re-run by this review

Both `--apply` programs were **extracted** from `31c39ec1`'s message rather than
retyped: the message was read with `git log -1 --format=%B`, each paragraph
unwrapped newline→space, and the `s/.../.../` program between `s/` and `/ on `
taken as-is. The file names came from the message (`S` is
`Sources/MacSCPAppKit/BucketVersioningSheet.swift` per its own note). Each program
was put in its own scratchpad script and passed to `scripts/mutation-probe` as
`--apply`, so the plant went through the harness, not a hand-rolled restore.

- **P5** (opener ignores the session cache), `scripts/mutation-probe --filter
  BucketVersioningSheetTests`: control **32 tests ran, 0 pre-existing failures**;
  planted run **32 tests ran**, `RESULT: RED` caught by
  `macSCPAppKitTests.BucketVersioningSheetTests/theCacheTravelsFromTheSessionToTheRead()`
  — that one test and no other. Tree reverted clean (`git status --porcelain`
  empty).
- **P7** (sheet never reads; `--apply` replaces the `await model.read(...)` with
  `_ = locks`): control **32 tests ran, 0 pre-existing failures**; planted run
  **32 tests ran**, `RESULT: RED` caught by
  `macSCPAppKitTests.BucketVersioningSheetTests/theCacheTravelsFromTheSessionToTheRead()`
  — that one test and no other. Tree reverted clean.

Both outcomes, both control figures and both catcher attributions match the
record in `31c39ec1` exactly — including the report's "control 32 tests /
0 pre-existing failures".

### One defect in the record itself (Minor M3)

The record's `--apply` strings **cannot be run in the form they are committed**.
Two reasons, both the project's own rule about a command travelling with its
figure:

1. They are hard-wrapped inside the commit message, and the unwrap is not
   specified. Newline→space is the only reading that works, and it inserts
   whitespace the original did not have: P5's replacement becomes
   `ObjectLockStateCache( settings: settings))` with a space after the paren.
   Swift does not care, so the probe reproduces — but the record is reproducible
   only because the target language is whitespace-insensitive, not because the
   text is faithful.
2. The file arguments are basenames (`S`, `ContentView+MenuActions.swift`) while
   the message says the programs are "run from the repository root", where those
   basenames do not resolve. The reader has to supply
   `Sources/MacSCPAppKit/...` themselves.

A fix: commit each `--apply` as a single unwrapped line (or as a script under
`scripts/`), with the path the command actually takes.

## Rulings on the seven questions

### 1 — the controller's third option for concern 1: RIGHT, and incomplete by one piece

The premise checks out against the code and against the brief's fourth test.

- `offeredStates` treats `.never` and `.suspended` in one arm, `[.enabled]`,
  with no reference to `bucketHasObjectLock`. The brief's
  `enablingIsNeverBlockedByALock` pins that for `.suspended` across both lock
  values, and `aNeverVersionedBucketOffersOnlyEnabling` pins `.never`. So the
  lock answer cannot change what is **offered** in either state.
- `blockedReason` guards on `current == .enabled`, so no lock claim is made in
  those states either, and `warning` for `.never`/`.suspended` does not read the
  lock. So the lock answer cannot change what the sheet **says** there.
- Therefore, with `current != .enabled`, failing the whole load on a lock-read
  failure spends the sheet's entire reach for an answer that changes nothing.
  The controller is right, and the change is mechanically small: `read` already
  has `state` in hand before it asks the cache, so the lock `catch` becomes
  `if state == .enabled { load = .failed(Self.lockReadFailedLine.text); return }`
  and otherwise falls through to `bucketHasObjectLock = nil; load = .known(state)`.

The piece the proposal inherits from the alternative the implementer rejected:
with the load no longer fatal in `.never`, the user can click Enable, `apply`
sets `load = .known(.enabled)`, and `bucketHasObjectLock` is still `nil` from the
failed read. In that state `offeredStates` is `[]`, `blockedReason` is `nil` and
`warning` is `nil` — a settled sheet with a state line and nothing else. That is
exactly the "no suspend button after `apply(.enabled)`" cost the implementer
cited; the third option does not remove it, it moves it behind one click. Today
that state is unreachable in production (the only production route to
`.known(.enabled)` with an unread lock is through a lock-read failure, which is
currently fatal), which is why the committed code has no sentence for it.

So the fix to record is the third option **plus** one of:

- `apply` re-asks `locks.hasObjectLock` after a successful write — a failure is
  never cached by `ObjectLockStateCache`, so this is a real retry and it restores
  the suspend button in the normal case; or
- the model distinguishes "lock read failed" from "lock not asked yet", so an
  enabled bucket whose lock read failed can show `lockReadFailedLine` inline
  instead of being settled and silent.

Without one of those two the third option trades a lost sheet for a silent one.
With one of them it is strictly better than what is committed. Recorded as
Important finding **I1**.

Also worth carrying into that fix: `s3.versioning.error.lockRead` currently reads
"...so its versioning cannot be changed here", which is true of the committed
code in every state. Under the third option it would only be shown for
`current == .enabled`, where it stays true. No rewording needed, but the sentence
must not escape to the `.never`/`.suspended` paths, where it would become false.

### 2 — concern 2, the `warning` behaviour change: YES there is a deliberate test, and YES the locked-enabled case asserts its warning

`aReadOfALockBearingBucketOffersNothingAndSaysWhy`
(`Tests/macSCPAppKitTests/BucketVersioningSheetTests.swift`) reads a lock-bearing
bucket through the cache and asserts, with the comment "A warning about a click
that is not on offer would be noise.":

- `model.blockedReasonKey == "s3.versioning.objectLockKeepsItOn"`
- `model.warning == nil`

and then, on an unlocked control built the same way,
`control.offeredStates == [.suspended]`, `control.blockedReasonKey == nil` and
`control.warningKey == "s3.versioning.suspendKeepsVersions"`. So the change is
pinned deliberately, in both directions, with a positive control beside the
negative assertion. The controller's reading — that showing both sentences would
be the contradiction Task 11 spent a round removing — is the one the test
encodes. No finding on the behaviour.

Two smaller holes in the same area:

- The **unread** lock case (`anUnreadLockStateOffersNothingAndSaysNothingAboutLocks`)
  asserts `offeredStates` and `blockedReasonKey` but says nothing about
  `warning`, although the new `.enabled where !offeredStates.contains(.suspended)`
  arm nils it there too. Unreachable in production, so Minor (**M2**).
- `eachStateSaysItsOwnThingBeforeTheClick` has **no companion of the same shape**
  for the locked case, and should not have one: the locked case's property is
  that it has no warning at all, which the test above asserts. Confirmed, as the
  controller said, that the three-way test was not weakened — all three
  constructions pass `bucketHasObjectLock: false`, and the three `!= nil` plus
  three pairwise `!=` assertions are untouched. What the locked case gets instead
  is its own catalogue coverage: `everyLine()` now appends
  `BucketVersioningModel(current: .enabled, bucketHasObjectLock: true).lines`, so
  the blocked sentence is held by `everyLineResolvesInAllFourLocales` and
  `theEnglishCatalogueSaysTheDefault`, and
  `theLockSentenceClaimsNoRefusalAndIsSaidInEveryLanguage` holds it per language.
  `everyKeyTheSheetUsesIsOneTheCatalogueChecksCover` keeps `everyLine()` honest.

### 3 — the parameter on one init, not three: the reasoning HOLDS

No path reaches a decision about suspension through `init()` or
`init(loadFailure:)` without the lock answer having been set:

- Both leave `current == nil` (`load` is `.reading` / `.failed`), so
  `offeredStates` is `[]` and `blockedReason` is `nil` by their own `current`
  guards.
- `apply` is gated on `offeredStates.contains(target)`, empty in both states, so
  no write and no `load = .known(...)` can originate there.
- The only transition out of either state is `read`, which sets
  `bucketHasObjectLock` **before** it sets `load = .known(...)`, and resets it to
  `nil` on entry — so a reused model cannot carry a stale answer into a new read.
- The only production construction of the model is the sheet's
  `model: BucketVersioningModel = BucketVersioningModel()` default: the single
  `BucketVersioningModel(` occurrence under `Sources` is that line.

The one default in play is the stored property's implicit `nil`, and `nil` is the
safe value under this design (offers nothing, claims nothing) — the opposite of
the `BackendDescriptor.connectionActions` hazard the brief cited. Putting the
parameter on the other two inits would add a value `read` immediately overwrites.
Accept as argued; no finding.

### 4 — the fallback that replaced a `guard let`

**In reads it costs nothing today, and in reach it buys nothing today.** The
right-hand side of `??` is an autoclosure, so no cache is constructed while
`session.objectLockStates` is non-nil. And it is always non-nil where this arm
runs: `BrowserSession` is constructed in exactly one place
(`Sources/MacSCPAppKit/ContentView.swift:2029` — the only `BrowserSession(` under
`Sources/`) with `remoteFS: fs`, and `ContentView.swift:2066` sets
`objectLockStates = BrowserSession.objectLockStates(for: fs)` from that same `fs`
with no `await` between them outside a closure; the row's own gate is
`context.settings = session.remoteFS as? any S3BucketSettings`
(`ContentView+MenuActions.swift:145`), the same `as?` the cache factory performs.
So `context.settings != nil` implies the session has a cache, and the fallback
branch is unreachable in a live session. The implementer's own decision 4 reached
the same conclusion by a different route (the two existing wiring tests).

Consequence: the comment's justification — "a sheet that cannot ask whether the
bucket has a lock has no button and nothing to say, and that is worse than one
extra read" — describes a situation that cannot arise, so the fallback's only
live effect is the masking the implementer discloses in concern 4. It also
diverges from the sibling `.objectLock` arm's `guard let states` eight lines
below, the pattern `SessionTab.objectLockStates`' own doc comment explains
("Without the cache the \"Object Lock…\" row and the two file actions are live and
open nothing"). That comment is still accurate — it names the other row and the
two file actions, not this one — so nothing stale there.

What takes the sting out: the masking is caught by a **source** guard rather than
a behavioural one. P5, re-run above, plants exactly "the opener stops reading the
session cache" and goes RED on `theCacheTravelsFromTheSessionToTheRead`. So the
wiring is pinned; the fallback removes only the second, behavioural line of
defence.

Were a fresh cache ever actually used, the cost would be one `hasObjectLock`
round trip **per sheet opening** rather than one per session:
`ObjectLockStateCache` keeps answers in its own `answers` dictionary, so a fresh
instance starts empty, and it caches no failures by design. Recorded as Minor
finding **M1** — fix is either the sibling arm's `guard let` or a comment that
says the branch is unreachable today and exists as defence in depth.

### 5 — three probes on one catcher: the scan is sound; concentration is acceptable, scope is the real limit

`theCacheTravelsFromTheSessionToTheRead` is a **positive** check throughout, with
a positive control on each of its three slices:

- `#expect(reads == ["bucket: bucket, from: settings, locks: locks"])` is a
  whole-value equality over every `model.read(...)` argument list the sheet source
  contains. It cannot go stale in silence: if the call disappears the list is
  empty and the equality is red (P7), if an argument changes the captured string
  differs (P6). It also pins the count at exactly one, so a second read cannot be
  added unnoticed.
- The second and third slices are anchored by `try #require(... .range(of:) ...)`
  — the positive control that the sliced thing exists at all — and then assert
  `contains` on substrings, which are presence checks, not absence checks.

It also sidesteps the project's documented comment-collision hazard by
construction: `Self.code` is `SourceCorpus.code(of:)`, i.e.
`SwiftSource.blankingCommentsAndStrings`, so a comment or string literal quoting
`states: session.objectLockStates` cannot satisfy the scan. Blanking preserves
length, so the `prefix(400)` / `prefix(300)` windows stay aligned.

On concentration: the three probes are three links of **one** chain (session →
item → sheet → `read`), and one test per chain is the right unit; splitting it
three ways would add no sensitivity, and the whole-value equality plus the two
`#require`s mean a mis-resolved corpus path fails loudly rather than passing
vacuously. What the single catcher does concentrate is the scope limit the report
itself names: it buys three **spellings** of the wiring, not the property. Per
CLAUDE.md, a scan that keeps buying spellings is the signal to reach for a
structural boundary — here a `BucketVersioningSheetItem` constructible only from
a session (so the opener cannot name a cache at all), or a sheet that takes the
session rather than the cache. A backlog row, not a change in this task.

### 6 — P2, the probe the brief predicted: the prediction HELD

The record's P2 (`bucketHasObjectLock == false ? [.suspended]` →
`bucketHasObjectLock != true ? [.suspended]`) is caught by
`aSuspensionOnALockBearingBucketIsNeverSent` and
`anUnreadLockStateOffersNothingAndSaysNothingAboutLocks`, and **not** by
`aLockBearingBucketIsNotOfferedSuspension`. Verified by reading the code rather
than only the record: under the plant, `bucketHasObjectLock == true` still yields
`[]`, so the brief's first test is satisfied by the mutant; the only tests that
separate `nil` from `false` are the brief's third test and the apply gate. That
is exactly what the brief predicted when it called `nil`-treated-as-`false` "the
plant a careless fix leaves green" and asked for a third test to cover it. So the
brief's own third test is load-bearing and the prediction is evidence for the
brief, not merely for the code. I did not re-run P2 (P5 and P7 were the two
asked for), so this is a code reading plus the record, not my own measurement.

### 7 — the sentence, the four catalogues, the German, and the lockRead line

The blocked sentence, `s3.versioning.objectLockKeepsItOn`, in all four
catalogues:

- `en`: "This bucket uses Object Lock, so its versioning cannot be switched off."
- `de`: "Dieser Bucket verwendet die Objektsperre, deshalb lässt sich seine
  Versionierung nicht ausschalten."
- `fr`: "Ce bucket utilise le verrouillage d'objet ; sa gestion des versions ne
  peut donc pas être désactivée."
- `pl`: "Ten bucket używa blokady obiektów, więc jego wersjonowania nie można
  wyłączyć."

All four say the bucket uses Object Lock and that its versioning cannot be
switched off, and **none** attributes the rule to a store refusal, a denial, an
error or a failure. `theLockSentenceClaimsNoRefusalAndIsSaidInEveryLanguage`
pins that on the English with two positive halves (`contains("object lock")`,
`contains("cannot")`) beside the six negatives
(`refus`/`reject`/`denied`/`error`/`fail`/`store`), and pins de/fr/pl as
non-empty and not the English text. German is `du`-compatible: the two new lines
address the reader not at all, and no `Sie`-form appears; the surrounding
`s3.versioning.*` lines use `Dein`. `Objektsperre` is the term the rest of the
`de` catalogue already uses for Object Lock (`connection.action.objectLock`,
the whole `s3.objectLock.*` block), so there is no second name for the feature.

`plutil -lint` is OK on all four files, and each carries each new key exactly
once.

`s3.versioning.error.lockRead` — "Whether this bucket uses Object Lock could not
be read, so its versioning cannot be changed here." — says nothing unmeasured.
The first clause is this session's own observation (the read threw); the second
is a statement about macSCP's behaviour, which is true of the committed code
(the load is `.failed`, so no action is offered in any state). It does not
attribute anything to the store, and the error text is never quoted —
`aLockThatCouldNotBeReadLeavesASentenceAndNoOffer` plants
`https://AKIDEXAMPLE:SECRETEXAMPLE@store.invalid` in the thrown reason, computes
the `Bool` into `quoted` before the expectation and asserts `!quoted`, which is
the project's two-exits rule applied correctly (neither the value nor its
spelling can reach a failure message). No finding.

One asymmetry, not a defect: the lockRead sentence has no "claims no refusal"
test of its own, unlike the blocked sentence. It does not need one — it describes
a failure that did happen — but note that the English negative list in the
blocked-sentence test is English-only, so a translation that dropped the Object
Lock name or gained a refusal claim would pass. That is the usual limit of a
per-language check and matches how the rest of this suite works.

## Project rules, checked one by one

**Verbatim quotes for withdrawn prose.** Two quotes are present and both are
exact against `eff615ef`:

- `offeredStates`' doc comment quotes "The states the sheet offers to move to:
  one, or none while the state is unknown. Never `.never`." —
  `git show eff615ef:Sources/MacSCPAppKit/BucketVersioningSheet.swift` carries
  precisely those two lines, word for word and backtick for backtick.
- `anEnabledBucketCanBeSuspendedAndNotUnset`'s new doc comment quotes
  `BucketVersioningModel(current: .enabled)` as the construction it used to use;
  the base file's line is `let model = BucketVersioningModel(current: .enabled)`,
  so the quoted expression is verbatim.

Changed prose that carries **no** quote, and whether one was owed:

- `read(bucket:from:)` → `read(bucket:from:locks:)`, old comment "Reads
  `bucket`'s versioning and shows it, or shows why it could not." Superseded by a
  signature change rather than falsified as a claim; no quote owed. Defensible.
- `init(current:)`'s comment, and the sheet init's `model`-default comment: both
  extended, nothing withdrawn. The default-comment keeps its first and last
  sentences verbatim and inserts a new one. No quote owed.
- `BoundedViewRegistry`'s "Four states" → "Five states (four until Task 11b
  added the lock-bearing one, below the refused read)". This is the right
  pattern: it recounts in the same moment and says what changed. The count is
  correct — five entries, and
  `grep -rno 'BucketVersioningModel(' Tests/macSCPAppKitTests/BoundedViewRegistry.swift`
  returns 5.

**A negative check needs a positive beside it.** Every negative assertion added
by this task has one: `theLockSentenceClaimsNoRefusalAndIsSaidInEveryLanguage`
pairs six `!contains` checks with `namesTheLock` and `saysCannot`;
`aLockThatCouldNotBeReadLeavesASentenceAndNoOffer` pairs `!quoted` with
`!text.isEmpty` and an exact `load == .failed(...)`;
`aSuspensionOnALockBearingBucketIsNeverSent` pairs two `writes.isEmpty` checks
with a `writes.count == 1` control; `aReadOfALockBearingBucketOffersNothingAndSaysWhy`
pairs `offeredStates == []` / `warning == nil` with a full unlocked control. The
source scan is positive throughout (ruling 5).

**A figure in a comment is counted in the same moment, with its command, and the
command runs as committed.** The report's figures all reproduce (see "Figures
re-run"). The one place the rule is not met is the probe record's `--apply`
strings, which do not run as committed (Minor M3). No new figure was written into
a source comment except the registry's "Five states", which is right.

**Four catalogues with `en` as source text.** All four updated, both keys, lint
OK, and `theEnglishCatalogueSaysTheDefault` plus
`everyLineResolvesInAllFourLocales` hold both new lines through `everyLine()`,
which `everyKeyTheSheetUsesIsOneTheCatalogueChecksCover` keeps honest.

**No hardcoded display string.** The new `Text(blocked.text)` resolves through
`CatalogueLine.text` → `L10n.string`. No literal added to the view.

**Every wait an `await`; no wall-clock ceiling.** `theVersioningAnswerDoesNotSettleBeforeTheLockAnswer`
uses `AsyncSignal` (`_ = await entered.wait()`, `await reading.value`), no
semaphore, no `syncShutdownGracefully`, and its `.timeLimit(.minutes(1))` is a
hang bound, not an asserted elapsed figure. The fake's new gate signals before it
parks and holds no lock across the `await`
(`FakeBucketSettings.hasObjectLock(ofBucket:)` takes its mutex twice, with the
`await` between). No `elapsed <` assertion anywhere in the diff.

**Tests never block the cooperative pool.** Nothing added blocks; the one spawned
`Task` is awaited.

**User documentation ships with the feature.** Not done, and correctly flagged by
the implementer as concern 5. Finding I3.

## Findings

Counts: **0 Critical, 3 Important, 4 Minor.**

### Important

**I1 — a lock-read failure costs the sheet reach it does not need to spend.**
`Sources/MacSCPAppKit/BucketVersioningSheet.swift`,
`BucketVersioningModel.read(bucket:from:locks:)`. A throw from
`locks.hasObjectLock(bucket)` sets `load = .failed(lockReadFailedLine.text)`
unconditionally, so an access key that can read versioning but not the Object
Lock configuration can no longer enable versioning on a never-versioned bucket —
reach Task 8's sheet had. How I know: the `catch` has no reference to `state`,
which is already bound above it; and `offeredStates` / `blockedReason` /
`warning` provably do not read the lock for `.never` or `.suspended`, so the lock
answer cannot change anything the sheet offers or says there (the brief's
`enablingIsNeverBlockedByALock` and `aNeverVersionedBucketOffersOnlyEnabling`
pin that). Fix: make the failure fatal only when `state == .enabled` and
otherwise settle `load = .known(state)` with `bucketHasObjectLock = nil` — plus
the missing piece, either re-asking the cache after a successful
`apply(.enabled)` or giving "lock read failed" a representation distinct from
"lock not asked yet" so an enabled bucket with an unreadable lock can still say
`lockReadFailedLine` instead of standing settled and silent. New tests: the
`.never` path survives a failed lock read and still offers `[.enabled]`; and the
post-`apply(.enabled)` state says something.

**I2 — nothing holds the sheet's body to drawing the blocked sentence.**
`Sources/MacSCPAppKit/BucketVersioningSheet.swift`, the
`if let blocked = model.blockedReason { Text(blocked.text) }` block in the
`.known` branch. Delete that block and, as far as I can tell, the suite stays
green: `grep -rn blockedReason Tests/` returns six hits, all of them
`model.blockedReasonKey` assertions on the model, none on the view; the key is
not a string literal in the view, so `everyKeyTheSheetUsesIsOneTheCatalogueChecksCover`
does not see it; and the seven probes plant on the model, the opener and the read,
never on the draw. So the one user-visible half of this task — the sentence that
replaces the vanished button — is the one link with no guard, in a task whose own
report asks "what would be green if this were never wired?". Fix: extend
`theCacheTravelsFromTheSessionToTheRead`'s sibling idea to the draw (a source
scan over the sheet's body asserting the `.known` branch reads
`model.blockedReason`, with the existing `model.warning` draw as its positive
control), and add it as probe P8 by deleting the block. I did not re-run a probe
to confirm green, so the claim "stays green" is read off the test corpus, not
measured.

**I3 — no user-documentation change.** `noix-docs`,
`src/content/docs/macscp/guide/`. This is a user-visible behaviour change (a
button disappears on a lock-bearing bucket; a new sentence appears; a new failure
sentence exists), and the project rule is that the docs ship in the same piece of
work. How I know: the brief's file list omits `noix-docs`, and nothing in the two
commits touches it. The implementer flagged it as concern 5 for the closeout
task, which is the right call to escalate rather than silently skip; recording it
so the closeout cannot lose it. Fix: a paragraph on the versioning page saying a
bucket that uses Object Lock cannot have its versioning switched off, marked as
coming in the next version.

### Minor

**M1 — the opener's fallback cannot buy the reach its comment claims.**
`Sources/MacSCPAppKit/ContentView+MenuActions.swift`, the `.versioning` arm:
`session.objectLockStates ?? ObjectLockStateCache(settings: settings)`. The
fallback branch is unreachable in a live session (derivation in ruling 4), so its
stated justification describes a situation that cannot arise, and its only live
effect is to mask a future wiring gap for this sheet — while diverging from the
sibling `.objectLock` arm's `guard let states` eight lines below. How I know:
`BrowserSession(` occurs once under `Sources/` (`ContentView.swift:2029`,
`remoteFS: fs`), `ContentView.swift:2066` sets the cache from the same `fs` with
no `await` between them outside a closure, and the row's gate is the same `as?`
(`ContentView+MenuActions.swift:145`). Fix: either use `guard let states` for
consistency — the wiring stays pinned by P5's catcher either way — or reword the
comment to say the branch is unreachable today and exists as defence in depth.

**M2 — two doc comments next to changed code enumerate the old set of lines.**
`Sources/MacSCPAppKit/BucketVersioningSheet.swift`:

- `lines`: "…where the bucket stands, the warning, and the offered buttons",
  three items, while the body one line below is now
  `[stateLine, warning, blockedReason].compactMap { $0 } + …`. The diff changed
  the body and left the enumeration at three — the project's own rule 2 about
  cardinality in comments, introduced by this task.
- `warning`: its doc comment explains three sentences and says nothing about the
  new `.enabled where !offeredStates.contains(.suspended)` arm, which is the
  behaviour change the implementer flagged as beyond the brief. Not falsified
  ("all three" sentences are still three), but silent about the branch a reader
  most needs explained.

Fix: add the blocked reason to `lines`' enumeration, and one sentence to
`warning` saying an enabled bucket with no suspension on offer warns about
nothing, with the blocked reason standing in its place. Neither withdraws a
measurement, so neither owes a quote.

**M3 — the probe record's `--apply` strings do not run in the form they are
committed.** `31c39ec1`'s message. Hard-wrapped mid-program with the unwrap
unspecified (newline→space is the only reading that works, and it inserts
whitespace the original did not have — P5's replacement becomes
`ObjectLockStateCache( settings: settings))`), and the file arguments are
basenames while the message says the programs run from the repository root. How
I know: I extracted and ran P5 and P7 that way and both reproduced, but only
because Swift ignores the inserted space, and I had to supply
`Sources/MacSCPAppKit/` myself. Fix: one unwrapped line per `--apply`, with the
path the command actually takes, or the programs committed as scripts.

**M4 — a false sentence in the registry comment this task edited (inherited, not
introduced).** `Tests/macSCPAppKitTests/BoundedViewRegistry.swift`, the versioning
block's lead comment: "the suspended one its own state sentence and **no
warning**". `BucketVersioningModel.warning` returns
`s3.versioning.resumeKeepsVersions` for `.suspended`, and
`eachStateSaysItsOwnThingBeforeTheClick` asserts it is non-nil. How I know:
`git show eff615ef:Tests/macSCPAppKitTests/BoundedViewRegistry.swift` carries the
same sentence, so it predates this task — it went stale when the Task 8 review's
Minor 5 (2026-10-20) gave `.suspended` a warning. This task edited the first line
of that same comment without re-reading the rest of it, which is the
"comments that describe other code" sweep the project asks for. Separately, the
lead comment now says "Five states … because each carries sentences the others
do not:" and then enumerates four; the fifth is explained three lines later, at
its own entry, which mitigates but does not satisfy the cardinality rule. Fix:
correct the suspended clause and either extend the enumeration to five or point
it at the per-entry comment.

Also noted, below the threshold for a finding: `anUnreadLockStateOffersNothingAndSaysNothingAboutLocks`
makes no assertion about `warning`, although the new arm nils it in that state
too (production-unreachable); the blocked sentence's "claims no refusal" checks
run on English only; and no probe plants on the lock-read-failure branch, though
`aLockThatCouldNotBeReadLeavesASentenceAndNoOffer` would catch the obvious
mutation by reading `load` exactly.

## What I could not check

- The red quoted in the report (`BucketVersioningSheetTests.swift:41:83: error:
  extra argument 'bucketHasObjectLock' in call`) is not reproducible now that the
  parameter exists; taken on the report's word, consistent with the committed
  line 41.
- The full-suite claim. I ran `scripts/mutation-probe --filter
  BucketVersioningSheetTests` twice (control 32 tests, 0 pre-existing failures,
  both times) but no full `swift test`. The report's one failure,
  `ViewTestabilitySpike` "Varying only isRegex leaves the pixels unchanged", is in
  a file this diff does not touch, which supports the pre-existing claim without
  proving it.
- P1, P2, P3, P4 and P6 were not re-run (P5 and P7 were the two asked for). P2's
  predicted non-catch I verified by reading the mutant's behaviour against the
  three tests, not by running it.
- I2's "stays green if the draw is deleted" is read off the test corpus
  (`grep -rn blockedReason Tests/`, the view's absent literal, the seven probes'
  targets), not measured with an eighth probe.
