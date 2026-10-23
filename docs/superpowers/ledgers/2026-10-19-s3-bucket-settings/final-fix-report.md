# Final fix report — the three findings of the whole-branch review

Branch `s3-bucket-settings`, worktree `/Users/noidee/macSCP/.claude/worktrees/diff-view`.
BASE `97dfc236`, tree clean at the start. The review this answers is
`.superpowers/sdd/2026-10-19-s3-bucket-settings/final-review.md`
(F1 = Section 6's first finding, F2 its second, F3 its third; Section 7 holds N1–N4).

Each section below was written when its work STARTED, with its method complete and its
verdict `VERDICT PENDING`, and the verdict filled in afterwards. Numbers carry the command
that produced them.

**Not run here:** the gated suites (`MACSCP_ITEST=1`), the rig (down, out of reach, not
started), and the GUI (never launched, nothing seen on screen). See the closing section.

## F1 — `create` reads back what it wrote

**The finding.** `CreateBucketModel.create(via:recorder:)` in
`Sources/MacSCPAppKit/CreateBucketSheet.swift` asserted success from the absence of a throw:
`try await settings.createBucket(bucket, protection: choice)`, then `outcome = .created` and
`recorder?.recordBucketCreated(bucket: bucket, protection: choice, failure: nil)`. The other
four write paths read back. The branch's own gated test
`S3CreateBucketGatedTests.recreatingABucketTheKeyOwnsDoesNotEnableObjectLockButDoesEnableVersioning`
measures that a re-create of a bucket the key owns succeeds, does NOT retrofit Object Lock and
DOES apply the versioning, so for this one call the absence of a throw is not the fact the
sheet and the audit line claimed.

**The ruling implemented (the maintainer's, not mine).**

1. After `createBucket` returns, read the properties the request claimed — the bucket's Object
   Lock state (`hasObjectLock(ofBucket:)`) and its versioning (`versioning(ofBucket:)`) —
   through the same capability the other four paths use. No pre-flight existence check.
2. A read-back that matches: `.created`, audit line as before.
3. A read-back that does not match: the sheet says so, in the wording
   `existsIncompletelyTemplate` already carries for this situation ("Open Versioning and Object
   Lock for it to see what it has"), as a new catalogue entry in `en`, `de`, `fr`, `pl`, German
   in du-form, never a literal.
4. The audit line records the protection that was READ BACK, not the one requested.
5. A read-back that FAILS is a third outcome: the bucket was created, its settings could not be
   confirmed. Neither full success nor failure of the create.

**Method.** Red first: a test that fails because `create` reports full success for a partial
result, run and quoted verbatim, then the fix. The App-side fake `FakeBucketSettings` is where
"the create answered 200 but the bucket has no lock" is expressed; the fake previously left its
state untouched on a successful create (nothing read it back), so it is first taught to model
the store — a create it accepts applies the protection — plus ONE knob for the measured
divergence.

**The red, observed.** `swift test --filter 'CreateBucketSheetTests|BucketSettingsAuditTests'`
(no `--build-system` flag), from the worktree root, filtered with
`/usr/bin/grep -E '^✘ Test [a-z].*(recorded an issue|failed after)' | sort -u` — 20 lines, of
which these are the issue lines. The catalogue entries, the
`protection(hasObjectLock:versioning:)` fold and the fake's `CreateEffect` were already in
place when this ran, so it is a test red and not a build failure:

```
✘ Test aCreateWhoseObjectLockDidNotTakeIsNotSaidToBeDone() recorded an issue at CreateBucketSheetTests.swift:428:9: Expectation failed: settings.hasLockReads == ["macscp-third"]
✘ Test aCreateWhoseObjectLockDidNotTakeIsNotSaidToBeDone() recorded an issue at CreateBucketSheetTests.swift:429:9: Expectation failed: model.isCreated == false
✘ Test aCreateWhoseObjectLockDidNotTakeIsNotSaidToBeDone() recorded an issue at CreateBucketSheetTests.swift:430:28: Expectation failed: model.failureSentence
✘ Test aCreateWhoseObjectLockDidNotTakeIsNotRecordedAsHavingIt() recorded an issue at BucketSettingsAuditTests.swift:334:9: Expectation failed: detail == "created bucket macscp-third with versioning"
✘ Test aCreateWhoseObjectLockDidNotTakeIsNotRecordedAsHavingIt() recorded an issue at BucketSettingsAuditTests.swift:335:9: Expectation failed: detail.contains("Object Lock") == false
✘ Test aCreateWhoseObjectLockDidNotTakeIsNotRecordedAsHavingIt() recorded an issue at BucketSettingsAuditTests.swift:338:9: Expectation failed: events.first?.isError == true
✘ Test aCreateWhoseObjectLockDidNotTakeIsNotRecordedAsHavingIt() recorded an issue at BucketSettingsAuditTests.swift:339:9: Expectation failed: (events.first?.errorMessage ?? "").isEmpty == false
✘ Test aCreateWhoseSettingsTookIsStillSaidToBeDone() recorded an issue at CreateBucketSheetTests.swift:452:9: Expectation failed: settings.hasLockReads == ["macscp-third"]
✘ Test aCreateWhoseSettingsTookIsStillSaidToBeDone() recorded an issue at CreateBucketSheetTests.swift:453:9: Expectation failed: settings.reads == ["macscp-third"]
✘ Test aCreateWhoseVersioningDidNotTakeIsNotSaidToBeDone() recorded an issue at CreateBucketSheetTests.swift:465:9: Expectation failed: settings.reads == ["macscp-third"]
✘ Test aCreateWhoseVersioningDidNotTakeIsNotSaidToBeDone() recorded an issue at CreateBucketSheetTests.swift:467:9: Expectation failed: model.isCreated == false
✘ Test aCreateWhoseVersioningDidNotTakeIsNotSaidToBeDone() recorded an issue at CreateBucketSheetTests.swift:468:28: Expectation failed: model.failureSentence
✘ Test aReadBackThatIsRefusedSaysTheSettingsCouldNotBeConfirmed() recorded an issue at CreateBucketSheetTests.swift:485:9: Expectation failed: model.isCreated == false
✘ Test aReadBackThatIsRefusedSaysTheSettingsCouldNotBeConfirmed() recorded an issue at CreateBucketSheetTests.swift:486:28: Expectation failed: model.failureSentence
✘ Test run with 68 tests in 2 suites failed after 0.268 seconds with 14 issues.
```

The run also printed `settings.hasLockReads → []` and `settings.reads → []` under the first
two. That is the finding in one line: no read was made at all, on the arm that reported full
success.

**What landed.**

- `CreateBucketModel.readBack(_:ofBucket:via:)`, a private static returning a three-case
  `ReadBack` (`asAsked` / `notAsAsked(BucketProtection)` / `unconfirmed`). `.none` reads
  nothing (it claimed no setting, and the failure path makes the same cut); `.versioned` reads
  versioning only (no lock header was sent, so nothing about the lock was claimed);
  `.lockedAndVersioned` reads the lock FIRST and then versioning, so a failing lock read does
  not spend the second request. No pre-flight existence check.
- `CreateBucketModel.protection(hasObjectLock:versioning:)`, the same fold as the `protection`
  property but over what the store ANSWERED. The lock is read first, for the reason that
  property gives: `BucketProtection` has no case for a lock without enabled versioning, and a
  line that dropped the lock would under-state what the bucket enforces.
- `create`'s success side is now three arms. `.created` unchanged; `.notAsAsked` sets
  `.failed(sentence: settingsDidNotTakeLine(bucket:), bucketMayExist: true)` and records the
  protection READ BACK; `.unconfirmed` sets `settingsUnconfirmedLine(bucket:)` and records the
  attempt with that sentence as its failure. Both keep `bucketMayExist: true`, so the pane
  refreshes and the taken-name check holds the same sheet back from re-sending.
- Two catalogue entries, `s3.createBucket.error.settingsDidNotTake %@` and
  `s3.createBucket.error.settingsUnconfirmed %@`, in `en`, `de`, `fr`, `pl` (German du-form:
  "Öffne für ihn …", "erstelle ihn nicht noch einmal"). Both keep
  `existsIncompletelyTemplate`'s second half word for word ("Open Versioning and Object Lock
  for it to see what it has, and do not create it again"); the first halves differ because what
  was measured differs — the request DID complete, so "did not complete" would be false, and
  the read establishes the settings are absent, so "It may not have those settings" would be
  weaker than the evidence. Neither says "was created": the read answers existence, not
  authorship, which is the withdrawal `failure(for:...)` already carries. Key counts after,
  `grep -c '^"' Sources/MacSCPAppKit/Resources/<l>.lproj/Localizable.strings` (this counts
  LINES beginning with a quote, which is one key per line in these files): `en 1552, de 1552,
  fr 1552, pl 1552`, from 1550 each. **That figure is at `0537fdc3`, this finding's own commit,
  and it has since moved**: F3 adds two more keys, so the same command run on the tree today
  prints 1554 four times. Re-run against this commit (`git show 0537fdc3:Sources/...`) or
  expect 1554. Both lines are in `allLines`, so
  `everyLineResolvesInAllFourLocales` and `theEnglishCatalogueSaysTheDefault` cover them
  without being told to.
- `FakeBucketSettings`: `createBucket` now changes what the next read returns, like the other
  writes, plus one knob — `CreateEffect` (`asAsked` / `ignoresTheObjectLockHeader` /
  `ignoresTheVersioningRequest`), the second being the rig's measured answer. The lock fixture
  is ESTABLISHED whenever the create carried the header, either way, because
  `.operationNotSupported` from a fake with no fixture is a DIFFERENT outcome (the read-back
  failing) and would have hidden this one.
- Seven new tests: four behavioural (the lock half, its positive control, the versioning half,
  the refused read-back), one that no read is spent for `.none`, one over all five combinations
  of the fold, and one in `BucketSettingsAuditTests` on what the line claims — that last with
  its own positive control, so it is not a test that passes because the words never appear.
- `createMakesExactlyTwoRecordingCalls` is corrected in place and renamed
  `createMakesOneRecordingCallPerArmItCanTake`, `2` → `4`, with the withdrawn wording quoted
  verbatim in its doc comment. The class doc's "**The taken-name check is the only thing
  between a person and a silent one-way door.**" is corrected the same way, quoted: it stopped
  being the only thing.

VERDICT: fixed. Red observed and quoted above, green after. Whole suite after:
`✔ Test run with 5085 tests in 408 suites passed after 18.297 seconds` (Core) and
`✘ Test run with 2855 tests in 240 suites failed after 29.436 seconds with 1 issue` (AppKit),
the one issue being `ViewTestabilitySpike.swift:202` ("Varying only isRegex leaves the pixels
unchanged", `off == on`) — the known pre-existing local failure, out of scope. 2855 is the
review's 2848 plus the seven new cases.

## F2 — `deleteTree` asks the bucket's lock state once, not once per refused key

**The finding.** `S3FileSystem.deleteTree(at:)` in
`Sources/macSCPCore/S3/S3FileSystem.swift` walks every `<Error>` element of a 200
`DeleteResult` and calls `lockFinding(forRefusedDeleteOf:inBucket:)` for each `AccessDenied` —
two signed GETs (`?legal-hold`, then `?retention`) per key. On a bucket with no Object Lock
neither establishes anything, so the loop pays and learns nothing. Batches are up to 1000 keys
and `Task.checkCancellation()` ran once per BATCH, never inside the loop, so a key with list
but not delete permission deleting a 1000-object folder spends about 2000 extra requests
before a generic failure, past the only cancellation check. All four existing tests of this
path use a batch with exactly ONE refused key, which is why none of them could see it.

**The ruling implemented (the maintainer's).** The lock state is a property of the BUCKET, not
of the key, so hoist it: determine it at most once per `deleteTree` call, lazily — only when a
refusal actually appears, so a clean delete costs nothing extra — and reuse it for every later
refusal in that call. A bucket with no Object Lock does no per-key probing at all. Plus a
cancellation check inside the per-key loop.

**Method.** Red first, on the REQUEST COUNT: a `deleteTree` whose batch carries several refused
keys on a bucket with no Object Lock. The existing tests are extended rather than replaced —
their shared helper grows from one echoed key to a list, and each gains the bucket lock-state
answer their probe list now starts with.

**The red, observed.** `swift test --filter 'S3ObjectLockTests'`, from the worktree root:

```
✘ Test aBatchOfRefusedKeysAsksTheBucketsLockStateOnlyOnce() recorded an issue at S3ObjectLockTests.swift:725:9: Expectation failed: outcome.probeRequests == 1
↳ outcome.probeRequests == 1 → false
↳   outcome.probeRequests → 8
✘ Test aBucketWithObjectLockStillNamesTheKeyUnderAHold() recorded an issue at S3ObjectLockTests.swift:743:9: Expectation failed: outcome.error == .finding(.objectUnderLegalHold(path: "/d/a"))
↳ outcome.error → .protocolError(reason: "S3 deleteTree: one or more objects could not be deleted")
✘ Test aBucketWithObjectLockStillNamesTheKeyUnderAHold() recorded an issue at S3ObjectLockTests.swift:744:9: Expectation failed: outcome.probeRequests == 2
✘ Test run with 51 tests in 1 suite failed after 0.033 seconds with 3 issues.
```

`outcome.probeRequests → 8` over a batch of four refused keys is 2 per key: the finding itself,
in the figure the fixture was built to produce. The second case is red for the mirror reason
— it supplies the bucket's lock-state answer first, which the unhoisted code reads as the
key's `?legal-hold`.

**What landed.**

- `S3FileSystem.BucketLockState`, a four-case private enum (`notAsked` / `inForce` / `absent` /
  `unknown`), and `bucketLockState(ofBucket:)`, which is `hasObjectLock(ofBucket:)` once with
  its failure folded into `.unknown`.
- `deleteTree` holds one `var bucketLock = BucketLockState.notAsked` for the whole call,
  across batches. The `AccessDenied` arm asks for it only if it is still `.notAsked`, so a
  delete that goes through makes no extra request at all, and probes `lockFinding` only while
  the state is not `.absent`.
- `try Task.checkCancellation()` at the head of the per-key refusal walk.
- `.unknown` still probes. That is the one judgement the ruling left open, and it is deliberate:
  nothing was established, and `lockFinding`'s own rule is that a probe's failure never replaces
  the answer it was asked about. The cost of the other choice is a lost
  `.objectUnderLegalHold` where the bucket-level read is refused and the object-level one is
  not, which is an ordinary permission split. It is named in "Concerns" below, because it means
  the request count is NOT bounded in that case.
- The shared fixture `deleteTree(sending:refused:probes:)` takes `refused` as a LIST. Three
  existing call sites pass a one-element array; two of them (`aKeyRefusedUnderALockIsNamedAtTheCallersOwnKey`,
  `theCallersSpellingIsUsedWhenTheStoreEchoesAnEquivalentOne`) gained the bucket's
  lock-enabled answer at the head of their probe list. `aKeyTheBatchNeverHeldIsNeverShownAsAPath`
  needed no change, and its `probeRequests == 0` now also pins that a skipped entry never
  reaches the bucket read. Two new cases: the four-refusal no-lock batch above, and
  `aBucketWithObjectLockStillNamesTheKeyUnderAHold`, which is the positive control — a bucket
  that HAS Object Lock still has its keys probed and still names the hold, at 2 requests.

VERDICT: fixed. Red observed and quoted above, green after. Whole suite after:
`✔ Test run with 5087 tests in 408 suites passed after 17.187 seconds` (Core, the review's
5085 plus the two new cases) and `✘ Test run with 2855 tests in 240 suites failed after
29.427 seconds with 1 issue` (AppKit), the one issue again `ViewTestabilitySpike.swift:202`.
`swift build` prints one `warning:` line, SwiftPM's own `missing creator for mutated node`
about SwiftTerm's bundle, which the review also recorded as not from this branch's code.

## F3 — the zero-bucket account gets an empty state instead of a blank pane

**The finding.** Task 6 removed the `RemoteFSError.bucketListEmpty` refusal so an account with
no buckets can connect, which is the flow this branch went out of its way to unlock.
`RemoteBrowserViewModel.State` has three cases (`loading`, `loaded`, `failed(message:)`) and no
empty one, so a zero-bucket account reaches `.loaded` with zero rows, and `BrowserPane`'s
`ZStack` draws an overlay only for `.loading` and `.failed`. Nothing on screen says the account
has no buckets or offers to make one; the only route to the action is the toolbar's
`ellipsis.circle` menu, labelled "Connection Actions". Spec §6.1 required that "the empty state
it creates must offer the one action that resolves it rather than being blank".

**The ruling implemented (the maintainer's).** Fix it: draw the empty state, say the account has
no buckets yet, and offer the action that resolves it. Catalogue entries in all four languages,
never a literal. If the `BoundedView` / `BoundedViewRegistry` layout guard covers views of this
kind, the new view joins the registry like the others.

**Method.** The rule goes in a `nonisolated static` the way `CreateBucketModel.isOffered` does,
so it can be exercised without a window, and the view is a `BoundedView` with a registry entry
— that is the one automated check available for text nobody can look at, since it measures all
four catalogues against the bound. The red is the finding's own shape: a scan, over
COMMENT-FREE source so a comment cannot satisfy it, asserting that the pane draws this state at
all. It is run with the view, its rule and its catalogue entries already in place, so what is
red is the pane, not the build.

**The red, observed.** `swift test --filter 'EmptyContainerListTests'`, from the worktree root,
filtered with `/usr/bin/grep -E '^✘ Test [a-z].*recorded an issue' | sort -u`. Eight issues
across three cases; the view, its rule, its two catalogue entries in four languages and its
registry entry were all in place, so what is red is the wiring:

```
✘ Test thePaneDrawsTheNoticeAndAsksTheRuleForIt() recorded an issue at EmptyContainerListTests.swift:149:9: Expectation failed: pane.contains("EmptyContainerListView.isShown(")
✘ Test thePaneDrawsTheNoticeAndAsksTheRuleForIt() recorded an issue at EmptyContainerListTests.swift:150:9: Expectation failed: pane.contains("EmptyContainerListView(")
✘ Test thePaneDrawsTheNoticeAndAsksTheRuleForIt() recorded an issue at EmptyContainerListTests.swift:153:9: Expectation failed: pane.contains("listedItemCount: viewModel.listedItems.count")
✘ Test theButtonIsRoutedThroughTheConnectionAction() recorded an issue at EmptyContainerListTests.swift:166:9: Expectation failed: actions.contains("func openCreateContainerSheet(")
✘ Test theButtonIsRoutedThroughTheConnectionAction() recorded an issue at EmptyContainerListTests.swift:168:9: Expectation failed: actions.contains("ConnectionActionRoute(action: $0) == .createBucket")
✘ Test theButtonIsRoutedThroughTheConnectionAction() recorded an issue at EmptyContainerListTests.swift:170:9: Expectation failed: detail.contains("onCreateContainer:")
✘ Test theButtonIsRoutedThroughTheConnectionAction() recorded an issue at EmptyContainerListTests.swift:171:9: Expectation failed: detail.contains("openCreateContainerSheet(")
✘ Test theLocalPaneIsNotOfferedTheAction() recorded an issue at EmptyContainerListTests.swift:191:9: Expectation failed: remoteBlock.contains("onCreateContainer:")
```

The last line is the POSITIVE control of a negative check going red while the negative half
passed, which is the shape CLAUDE.md asks for: "the local pane does not carry it" was
satisfied by a tree in which nobody carried it.

**What landed.**

- `Sources/MacSCPAppKit/EmptyContainerListView.swift`: an icon, a headline, a sentence, and the
  create button when `onCreate` is non-nil. `nonisolated static func isShown(scope:state:listedItemCount:)`
  holds the rule, the way `CreateBucketModel.isOffered` does: the root lists containers AND the
  pane is standing at that list (`BrowserScope.isContainerListRoot`), the listing has LOADED,
  and it holds nothing. The count is `listedItems`, not `items`: a search matching no bucket is
  not an account without any — the same distinction `CreateBucketModel.listing(of:)` makes.
- The button's title is `CreateBucketModel.titleLine`, read rather than spelled again, so the
  button and the toolbar row a person may already have found cannot drift apart.
- Two catalogue entries, `browser.pane.noContainers.title` and `browser.pane.noContainers.body`,
  in `en`, `de`, `fr`, `pl` (German du-form: "Erstelle einen, um hier Dateien abzulegen."). Key
  counts after, same command as F1's: `en 1554, de 1554, fr 1554, pl 1554`.
- `BrowserPane.onCreateContainer`, a callback with a `nil` default, wired only on the REMOTE
  pane in `ContentView+Detail.swift` to a new
  `ContentView.openCreateContainerSheet(in:session:)`. That function looks the contribution up
  in the backend's own descriptor and hands it to `handleConnectionAction`, which re-asks
  availability and builds the sheet — so the availability rule and the sheet's construction
  stay spelled once, and this is not a second door into an irreversible write.
- It IS a `BoundedView`, with a `BoundedViewRegistry` entry, so the layout guard measures the
  new text in all four languages. That is the only reader this text has, since nothing on this
  branch has been seen on screen. The bound is `.capped(minWidth: 220, maxWidth: 260)`: a cap
  because the pane is resizable, with the maximum 20 pt inside `BrowserPane.minimumWidth`
  (280). Measured with `MACSCP_BOUND_FIGURES=1 swift test --filter BoundedViewFigureReportTests`
  (a read-only measurement record, no rig involved), which printed for this entry:
  `wide de 66.0/454.0 en 66.0/414.0 fr 66.0/521.0 pl 66.0/463.0 of 260.0` — the figure the guard
  compares is the first of each pair, 66.0 pt in every language, against 260.0 granted.
- `IconTooltipLintTests.decorativeIcons` gained one entry for the `tray` glyph, with its reason,
  the same shape as the lost-connection surface's icon. Without it that lint was red, which is
  the project's own guard working: `everyIconIsExplainedOrDeliberatelyDecorative` recorded an
  issue at `IconTooltipLintTests.swift:214:29` for the new file.
- Ten tests in a new suite: the rule's positive case, its five negatives, a case tying the
  notice to the availability of the action it offers, three catalogue cases, and the two wiring
  scans — over COMMENT-FREE source, so the long explanation in the view's own doc comment cannot
  satisfy a scan looking for the code it describes.

**NOT VERIFIED VISUALLY.** Nothing on this branch ever has been: no GUI was run, no screenshot
taken, the app and its binary were never launched, and that was a constraint on this work, not
an omission. What is measured about this view is the rule (ten tests), the four catalogues
(resolution, the English default, and title-vs-body distinctness), the wiring (two source
scans), and the layout figures above. What is NOT measured is how it looks: spacing, the icon's
weight, whether the button reads as the obvious next step, and whether the sentence lands where
a person's eye goes.

VERDICT: fixed in code, unverified on screen. Red observed and quoted above, green after.
Whole suite after: `✔ Test run with 5087 tests in 408 suites passed after 17.863 seconds` (Core)
and `✘ Test run with 2865 tests in 241 suites failed after 29.854 seconds with 1 issue`
(AppKit) — the one issue `ViewTestabilitySpike.swift:202` again. 2865 is F2's 2855 plus the ten
new cases, and 241 suites is 240 plus the new one.

## Catalogue parity after all three findings

Four keys were added in all (two in F1, two in F3), and the four catalogues are still at exact
key parity. Two commands, from the worktree root, run after this paragraph was written:

- `grep -c '^"' Sources/MacSCPAppKit/Resources/<l>.lproj/Localizable.strings` per language
  (LINES beginning with a quote, one key per line): `en 1554, de 1554, fr 1554, pl 1554`, from
  the review's 1550 each.
- Key SETS, as the review's Section 1 did it: `sed -n 's/^"\([^"]*\)" *=.*/\1/p` over each
  catalogue, `sort`ed, `diff`ed against `en`. All three diffs are EMPTY (0 lines of output),
  so the four catalogues declare exactly the same keys. The script that ran it is
  `/private/tmp/claude-501/-Users-noidee-macSCP--claude-worktrees-diff-view/c68e1585-ea4f-4194-a037-c8f1c3a96a0d/scratchpad/keyparity.sh`,
  which is a scratchpad file and not part of the tree; the commands in it are the two above.

German is du-form in both new pairs ("Öffne für ihn …", "erstelle ihn nicht noch einmal",
"Erstelle einen, um hier Dateien abzulegen."), which `GermanAddressFormTests` also holds.

VERDICT: parity holds, on counts and on key sets.

## The commits

Three, one per finding, on `s3-bucket-settings` over BASE `97dfc236`. **Not pushed.**

1. `0537fdc3` — `fix(app): read back what a create wrote before calling it done` (F1)
2. `a9a24a13` — `perf(core): ask a bucket's Object Lock state once per deleteTree, not per
   refused key` (F2)
3. `6d0c87c8` — `feat(app): draw the empty state an account with no buckets lands on` (F3)

Each quotes its own observed red verbatim in its message. The tree is clean at `6d0c87c8`.

## Concerns

Four, in the order I would want to hear them.

1. **F2's `.unknown` arm leaves the request count unbounded in one case, and that was my
   judgement, not the ruling's.** The ruling says to hoist the lock state and that a bucket with
   no Object Lock does no per-key probing. It does not say what happens when the hoisted read
   itself FAILS. I made that `.unknown` and kept probing, because nothing was established and
   `lockFinding`'s own rule is that a probe's failure never replaces the answer it was asked
   about; the alternative loses a real `.objectUnderLegalHold` where `GET ?object-lock` on the
   bucket is refused while `GET ?legal-hold` on the object is not, which is an ordinary
   permission split. The cost of my choice: an access key that can list, cannot delete, and
   cannot read the bucket's lock configuration still pays two signed GETs per refused key. If
   you would rather bound it absolutely, the change is one line (`!= .absent` becomes
   `== .inForce`) and it needs a test of its own.
2. **F3's shape is mine inside your ruling, and the part I am least sure of is the button.** You
   ruled "offer the action that resolves it". I made it a real button rather than a sentence
   naming the toolbar menu, which means a second door into the create-bucket sheet. I routed it
   through `handleConnectionAction` so the availability rule and the sheet's construction are
   still spelled once — but it is still a second place a person can reach an irreversible
   switch from, and that is worth a look. The cheaper reading of your ruling (the review's own
   suggestion) was one sentence naming where Create Bucket is, which adds no door.
3. **F1's `.unconfirmed` audit line records the ATTEMPT, not a read-back.** Ruling 4 says the
   line records what was read back. On this arm nothing was read back, so there is nothing to
   record; the line carries the requested protection with the "could not be confirmed" sentence
   as its failure, which is what the other four paths do for a write whose read-back failed. I
   believe that is the only honest option available without changing
   `AuditRecorder.recordBucketCreated`'s signature, but it is the one place F1 does not do
   literally what ruling 4 says, and I would rather you knew than discovered it.
4. **F1 reads the lock only where the lock was asked for.** Your ruling says to read "the two
   properties the request claimed — the bucket's Object Lock state and its versioning". A
   `.versioned` create sends no Object Lock header, so I read only versioning there, which saves
   a request on the common case. If you meant both reads on every protected create, that is a
   two-line change — and it would also catch a `.versioned` create that landed on a bucket which
   already HAS a lock, a state the sheet currently reports as fully as asked.

## Not done / not verified

- **Nothing was pushed.** Three commits sit on `s3-bucket-settings` in this worktree.
- **The gated suites never ran.** `MACSCP_ITEST=1` (the Docker rig) is down and reachable only
  from the main checkout, which this session cannot touch. I did not start it, and I named no
  rig bucket. F1's mechanism is still pinned only by a gated test nobody has run
  (`recreatingABucketTheKeyOwnsDoesNotEnableObjectLockButDoesEnableVersioning`) and by the
  manual 2026-10-19 probe in the spec. `MACSCP_KEYCHAIN=1`, `MACSCP_PIPE_TIMING=1`,
  `MACSCP_SATURATION=1` and `MACSCP_DIFF_COST=1` did not run either. The one gated thing I DID
  run is `MACSCP_BOUND_FIGURES=1 swift test --filter BoundedViewFigureReportTests`, which is a
  read-only layout measurement with no rig and no keychain behind it.
- **Nothing was seen on screen.** No GUI, no screenshot, the app and its binary were never
  launched. F3 in particular is unverified visually — see its own section.
- **No mutation probe was run.** I planted nothing and did not invoke `scripts/mutation-probe`,
  so no claim here rests on a probe. The three new negative checks I added each have a positive
  check beside them in the same test, which is the cheaper half of the same property, and
  F3's `theLocalPaneIsNotOfferedTheAction` was in fact caught by its positive control going red.
- **`docs/BACKLOG.md` has no row for any of the three**, and the SDD ledger is not updated. That
  is the coordinator's closeout, not mine, and I did not want to write into the measurement
  record on a dispatch that was not asked to.
- **The user documentation is untouched.** F1 changes what a sheet says and F3 adds a screen, so
  both are user-visible and `noix-docs` owes them a paragraph under the house rule — but I was
  told not to touch `/Users/noidee/_dev/noix-docs`, and I did not.
- **AWS is still unmeasured**, which is what would bound F1's reach there: whether a re-create
  answers `BucketAlreadyOwnedByYou` in every region. The read-back makes the question less
  urgent, because the fix does not depend on which refusal a store picks.
- **The one known local red stands**: `ViewTestabilitySpike.swift:202`, "Varying only isRegex
  leaves the pixels unchanged", `off == on`. Pre-existing, out of scope, untouched.

---

# Fix round 2 — the coordinator's rulings on the four concerns

Two of the four judgements were upheld as they stood (concerns 2 and 3), and two were ruled
differently (concerns 4 and 1). Both of the latter are fixed below, each red before green, each
in its own commit. The coordinator's own words on concern 4: "This is the one I got wrong" --
the ruling "read the two properties the request claimed" assumed the only harm runs one way.

## F1b — read the lock state on every create that asks for any protection (concern 4)

**What the ruling changes.** The F1 read-back asked `hasObjectLock` only where the create had
carried the Object Lock header, because a `.versioned` create claims nothing about the lock.
The mirror is the heavier half: a `.versioned` create answered with success can land on a bucket
that ALREADY has Object Lock -- the same stale-listing re-create with the switches the other way
round. Object Lock cannot be switched off once a bucket has it, so the person ends up owning a
protection they never chose and can never remove, with the sheet saying the bucket was created
and the audit line reading "created bucket X with versioning" and nothing more. The property is
therefore not "what was asked for arrived" but "what the bucket now has is what the sheet and
the audit line say it has".

**Method.** Two new tests -- one behavioural, one on the audit line -- plus a correction to the
existing `aCreateWhoseVersioningDidNotTakeIsNotSaidToBeDone`, which asserted
`settings.hasLockReads.isEmpty` as a PROPERTY and now asserts the opposite. The fake needed one
correction first, so the red is behavioural rather than a build failure: it established the lock
fixture only for a create carrying the header, so a `.versioned` create left no fixture and
`hasObjectLock` would have thrown `.operationNotSupported` -- the read-back FAILING, a different
outcome that would have hidden this one.

**The red, observed.** `swift test --filter 'CreateBucketSheetTests|BucketSettingsAuditTests'`:

```
✘ Test aCreateOntoABucketThatAlreadyHasObjectLockIsNotSaidToBeAsAsked() recorded an issue at CreateBucketSheetTests.swift:508:9: Expectation failed: settings.hasLockReads == ["macscp-third"]
↳   settings.hasLockReads → []
✘ Test aCreateOntoABucketThatAlreadyHasObjectLockIsNotSaidToBeAsAsked() recorded an issue at CreateBucketSheetTests.swift:509:9: Expectation failed: model.isCreated == false
↳   model.isCreated → true
✘ Test aCreateOntoABucketThatAlreadyHasObjectLockIsNotSaidToBeAsAsked() recorded an issue at CreateBucketSheetTests.swift:510:28: Expectation failed: model.failureSentence
↳   failureSentence → nil
✘ Test aCreateOntoAnAlreadyLockedBucketRecordsTheLockItFound() recorded an issue at BucketSettingsAuditTests.swift:377:9: Expectation failed: detail == "created bucket macscp-third with versioning and Object Lock"
↳   detail → "created bucket macscp-third with versioning"
✘ Test aCreateOntoAnAlreadyLockedBucketRecordsTheLockItFound() recorded an issue at BucketSettingsAuditTests.swift:378:9: Expectation failed: events.first?.isError == true
✘ Test aCreateOntoAnAlreadyLockedBucketRecordsTheLockItFound() recorded an issue at BucketSettingsAuditTests.swift:379:9: Expectation failed: (events.first?.errorMessage ?? "").isEmpty == false
✘ Test aCreateWhoseVersioningDidNotTakeIsNotSaidToBeDone() recorded an issue at CreateBucketSheetTests.swift:474:9: Expectation failed: settings.hasLockReads == ["macscp-third"]
✘ Test run with 70 tests in 2 suites failed after 0.295 seconds with 7 issues.
```

`detail → "created bucket macscp-third with versioning"` is the false record the fix exists for,
printed by the run rather than argued for.

**What landed.** In `readBack`, the conditional read becomes unconditional:
`let hasLock = try await settings.hasObjectLock(ofBucket: bucket)`. `.none` still reads neither
property. `FakeBucketSettings.createBucket` establishes the lock fixture for any protection and
leaves an existing `hasLock` alone unless the header is both sent and honoured -- a create never
REMOVES a lock, which the old shape got wrong as well as narrow.

**NO new catalogue entry, and that is a judgement I made inside the ruling.** The sentence shown
is the existing `settingsDidNotTake`: "A bucket named “X” exists now, and it does not have the
settings you chose. Open Versioning and Object Lock for it to see what it has, and do not create
it again." It is true of this case under the reading that the sheet offers TWO switches and "the
settings you chose" is the pair -- a lock the person unticked and got anyway is a setting the
bucket does not match -- and its second half points at the one place that shows the lock. The
create sheet's `objectLockNote` has already told them the lock can never be switched off. If you
want the permanence named at this moment instead of inferred, that is a third catalogue entry in
four languages and I did not add it uninvited.

VERDICT: fixed. Red observed and quoted above, green after. `✔ 5087 Core` and
`✘ 2867 AppKit … with 1 issue` (`ViewTestabilitySpike.swift:202`).

## F2b — bound the `.unknown` arm (concern 1)

**What the ruling changes.** The reasoning for probing when the bucket's own lock state cannot be
read is upheld: nothing was established, and a probe's failure must not replace the answer it was
asked about. What is added is the bound the user's ONE message justifies. (1) An informative
probe ends the walk -- which the F2 fix already had, because an informative `lockFinding` throws.
(2) `.unknown` buys at most ONE probe per call: with the bucket's configuration unreadable and
the first object's lock state uninformative, nothing distinguishes the five-hundredth key from
the first.

**The red, observed.** `swift test --filter 'S3ObjectLockTests'`, with both reason constants
already in place and the plain one already thrown, so this is a test red and not a build failure:

```
✘ Test anUnreadableBucketLockStateProbesOnlyTheFirstRefusedKey() recorded an issue at S3ObjectLockTests.swift:765:9: Expectation failed: reason == S3FileSystem.deleteTreeRefusedWithUnreadableLockStateReason
↳   reason → "S3 deleteTree: one or more objects could not be deleted"
✘ Test anUnreadableBucketLockStateProbesOnlyTheFirstRefusedKey() recorded an issue at S3ObjectLockTests.swift:766:9: Expectation failed: reason != S3FileSystem.deleteTreeRefusedReason
✘ Test anUnreadableBucketLockStateProbesOnlyTheFirstRefusedKey() recorded an issue at S3ObjectLockTests.swift:767:9: Expectation failed: outcome.probeRequests == 3
↳   outcome.probeRequests → 9
✘ Test run with 53 tests in 1 suite failed after 0.034 seconds with 3 issues.
```

9 = one bucket read plus two per refused key over a batch of four. The bound makes it 3: the
bucket read, then one key's hold and its retention.

**What landed.** A per-call `var probesWhileUnknown = 0` beside `bucketLock`, and the probe gate
becomes a `switch` over the four states with no `default` (`.notAsked`/`.absent` no,
`.inForce` yes, `.unknown` only while nothing has been probed). The generic failure's `reason` is
now one of two named constants, `S3FileSystem.deleteTreeRefusedReason` and
`.deleteTreeRefusedWithUnreadableLockStateReason`; the second is the first plus "; the bucket's
Object Lock state could not be read". Named so a test reads them rather than keeping a second
copy, and neither carries anything the store wrote.
`aBucketWhoseLockStateReadsGivesThePlainReason` is the positive control, so neither spelling is
the answer to every refusal. `BucketLockState.unknown`'s doc comment is corrected in place and
quotes what it replaces.

**WHAT THIS TRADES AWAY, said plainly, because the next person may decide it differently:** a key
further down the batch can carry a legal hold the first refused key does not. In that
configuration -- bucket lock configuration unreadable, first refused key not under a hold, a
later key under one -- the user now gets the generic message instead of "this file is under a
legal hold". Before this bound they would have got the hold, at up to 2000 requests. The
`reason` records which case it was, which is the only compensation offered. It is written at the
line in `deleteTree` as well as here.

VERDICT: fixed. Red observed and quoted above, green after. `✔ 5089 Core` (the two new cases) and
`✘ 2867 AppKit … with 1 issue`.

## Concerns 2 and 3 — upheld, nothing changed

Concern 2 (F3's button) and concern 3 (F1's `.unconfirmed` audit line) were upheld as they stand.
`AuditRecorder.recordBucketCreated`'s signature is untouched, as instructed. No code changed for
either.

## Round 2 state

Five commits now, over BASE `97dfc236`, in order:

1. `0537fdc3` — `fix(app): read back what a create wrote before calling it done` (F1)
2. `a9a24a13` — `perf(core): ask a bucket's Object Lock state once per deleteTree, not per
   refused key` (F2)
3. `6d0c87c8` — `feat(app): draw the empty state an account with no buckets lands on` (F3)
4. `a89e7ed9` — `fix(app): read a created bucket's lock state even where no lock was asked for`
   (F1b, concern 4)
5. `df948f90` — `perf(core): bound deleteTree's probing when a bucket's lock state cannot be
   read` (F2b, concern 1)

Each quotes its own observed red verbatim. Tree clean at `df948f90`, nothing pushed. Final suite:
`✔ Test run with 5089 tests in 408 suites passed` (Core) and `✘ Test run with 2867 tests in 241
suites failed … with 1 issue` (AppKit), the issue being `ViewTestabilitySpike.swift:202`.
`swift build` still prints only SwiftPM's own `missing creator for mutated node` warning. No new
catalogue key in round 2, so the counts and the key-set parity recorded above stand unchanged at
1554 per language.

## One more thing that may make a ruling the wrong shape

**A `.none` create still reads nothing, so the mirror survives one step further.** The ruling
scoped the new read to "every create that asks for any protection", and I implemented that
literally: a plain create -- both switches off -- spends no read. But a plain create answered
with success can land on a bucket that already has versioning AND Object Lock, and it is
reported as "The bucket “X” was created." with an audit line of "created bucket X" and no
protection named. No line CLAIMS a protection that is not there, so the property you stated
holds. What does not hold is the other half of it: the bucket has two protections the person
did not choose, one of them permanent, and nothing on the sheet or in the trail says so.

It is the same harm as F1b with the switches one notch further off, and the cost of closing it
is two requests on the one path that currently costs none. I did not widen the ruling on my own.
If you want it closed, it is the `guard choice != .none else { return .asAsked }` line in
`readBack` plus a sentence for "the bucket you asked for plainly already has protections" --
which, unlike F1b, I do think needs its own catalogue entry, because
`settingsDidNotTake`'s reading ("you chose both switches off and the bucket does not match")
is true but the sentence would be the only thing telling a person their plain bucket is
permanently locked.

---

# Fix round 3 — the `.none` create (the ruling's third shape)

The coordinator closed the question I raised at the end of round 2: a plain create reads back
too. Their words: "Walk it to the end" -- and walked to the end it is the heaviest of the three,
not the lightest.

## F1c — every create reads back, and a mismatch has a direction

**The harm, which is the reason the cheapest-looking path is the most expensive.** A person
creates `reports`. They already own that name, and its bucket has Object Lock and -- because
this branch ships the feature that sets them -- possibly a COMPLIANCE default retention. The
create answers 200. The sheet says "The bucket “reports” was created." The audit line says
`created bucket reports`, naming no protection, so the property round 1 established holds:
nothing CLAIMS something that is not there. Then they start writing files into it. Every object
inherits the bucket's default retention, and under COMPLIANCE nobody can delete those objects
until their dates pass -- not them, not the account owner. They chose nothing, were told
nothing, and the one irreversible thing this software can do has happened to data they put
somewhere they believed was empty and ordinary.

**The ruling.** Read back on every create, `.none` included. Keep `settingsDidNotTake` for a
setting that was CHOSEN and did not take. Add exactly ONE new entry for the inverse, used for
both the `.versioned`-onto-locked case and this one, and have it name the permanence at the
moment it matters rather than leaving it to `objectLockNote` on the sheet the person has just
dismissed. The audit line records what was read back.

**The red, observed.** `swift test --filter 'CreateBucketSheetTests|BucketSettingsAuditTests'`,
with the new catalogue entry and `protectionRank` already in place so this is a test red and not
a build failure. 12 issues across 4 cases; the load-bearing lines:

```
✘ Test aPlainCreateOntoAnAlreadyProtectedBucketIsNotSaidToBeDone() recorded an issue at CreateBucketSheetTests.swift:546:9: Expectation failed: settings.hasLockReads == ["macscp-third"]
↳   settings.hasLockReads → []
✘ Test aPlainCreateOntoAnAlreadyProtectedBucketIsNotSaidToBeDone() recorded an issue at CreateBucketSheetTests.swift:548:9: Expectation failed: model.isCreated == false
↳   model.isCreated → true
✘ Test aPlainCreateOntoAnAlreadyProtectedBucketRecordsWhatItFound() recorded an issue at BucketSettingsAuditTests.swift:400:9: Expectation failed: detail == "created bucket macscp-third with versioning and Object Lock"
↳   detail → "created bucket macscp-third"
✘ Test aCreateOntoABucketThatAlreadyHasObjectLockIsNotSaidToBeAsAsked() recorded an issue at CreateBucketSheetTests.swift:521:9: Expectation failed: sentence == CreateBucketModel.protectionNotChosenLine(bucket: "macscp-third")
↳   sentence → "A bucket named “macscp-third” exists now, and it does not have the settings you chose. Open Versioning and Object Lock for it to see what it has, and do not create it again."
✘ Test aPlainCreateOntoAnEmptyNameIsStillSaidToBeDone() recorded an issue at CreateBucketSheetTests.swift:631:9: Expectation failed: settings.reads == ["macscp-third"]
✘ Test run with 73 tests in 2 suites failed after 0.294 seconds with 12 issues.
```

`detail → "created bucket macscp-third"` is the silent line, and `settings.hasLockReads → []` is
why it was silent.

**What landed.**

- `readBack` loses its `guard choice != .none`. Every create reads the lock and the versioning.
- A mismatch now carries its DIRECTION: `ReadBack.notAsAsked(_)` splits into
  `.lessThanAsked(_)` and `.moreThanAsked(_)`, decided by `protectionRank`, a chain
  (`.none` inside `.versioned` inside `.lockedAndVersioned`, because Object Lock cannot be had
  without versioning). The chain is what makes the comparison TOTAL: no mismatch is
  incomparable with two sentences competing for it. No `default`, so a fourth
  `BucketProtection` case must be placed in the chain rather than silently rank as something.
- One new catalogue entry, `s3.createBucket.error.protectionNotChosen %@`, in `en`, `de`, `fr`,
  `pl`, German du-form ("die du nicht gewählt hast"). English: "A bucket named “%@” already
  existed, and it carries protection you did not choose. Object Lock, once a bucket has it, can
  never be switched off. Open Versioning and Object Lock for it to see what it has, and do not
  create it again." It says nothing about "the settings you chose", which is what lets one
  sentence serve a plain create as well as a versioned one -- and drops the stretch round 2
  flagged. The permanence clause is a property of Object Lock, not a claim about THIS bucket,
  so the sentence stays true where what was found is versioning alone.
- `settingsDidNotTake` keeps the `.lessThanAsked` arm and now means only what its name says.
- Both arms record the protection READ BACK. On `.moreThanAsked` that is the other half of the
  property: no line claims what is not there, and none leaves out what is.
- Five new tests: the plain-create case, its positive control (a plain create onto a free name
  is still said to be done), the direction table over all six ordered pairs, and the two audit
  cases.
- Corrections in place, each quoting what it replaces: `readBack`'s doc paragraph on `.none`;
  the `.versioned`-onto-locked test's doc, which argued the `settingsDidNotTake` reading now
  dropped; `aCreateWithNoProtectionSpendsNoReadBack`, whose NAME and whole body asserted the
  saved requests as a property, now `aPlainCreateOntoAnEmptyNameIsStillSaidToBeDone`;
  `createMakesOneRecordingCallPerArmItCanTake`, 4 → 5; and
  `FakeBucketSettings.createBucket`'s guard, which left a plain create with no lock fixture.

**Catalogue figures, re-run after writing this.**
`grep -c '^"' Sources/MacSCPAppKit/Resources/<l>.lproj/Localizable.strings` prints `1555` for
each of `en`, `de`, `fr`, `pl`, from 1554 before this round. **That supersedes the round-2
sentence above** which read, verbatim: "No new catalogue key in round 2, so the counts and the
key-set parity recorded above stand unchanged at 1554 per language." It was true of round 2 and
is not true of the tree now. Key SETS: the `sed`/`sort`/`diff` comparison against `en` is still
EMPTY for all three other languages, so parity holds at five added keys in total.

VERDICT: fixed. Red observed and quoted above, green after.
`✔ Test run with 5089 tests in 408 suites passed` (Core) and
`✘ Test run with 2870 tests in 241 suites failed … with 1 issue` (AppKit), the issue being
`ViewTestabilitySpike.swift:202`. `swift build` prints only SwiftPM's own
`missing creator for mutated node`.

## THE MIRROR SURVIVES A FOURTH NOTCH. Reported, not fixed, as instructed.

It is no longer a case the read-back can close, which is why it stops being a fix.

**What survives.** `readBack` compares the bucket's protection against the request's. When the
two are EQUAL it answers `.asAsked`, and it cannot tell a bucket this create made from one that
was already there carrying exactly what was asked for. Two instances:

1. **A `.lockedAndVersioned` create onto a bucket that already has Object Lock AND a bucket
   DEFAULT RETENTION.** The read-back asks `hasObjectLock` (true) and `versioning` (enabled), so
   `actual == choice`, the sheet says "The bucket “X” was created." and the line says
   `created bucket X with versioning and Object Lock`. Every word of that is true of the bucket.
   What nobody is told is that the bucket is not new and carries a default retention the person
   did not set -- and `createBucket` never sets one, so it is the existing bucket's. If that
   default is COMPLIANCE, this is the same harm as the `.none` case with the switches at the
   other end: every file they write becomes undeletable by anyone until its date.
   `objectLockDefault(ofBucket:)` is on the capability and is not read here.
2. **A `.versioned` create onto an existing `.versioned` bucket**, which reads identically to a
   fresh one. Lighter -- no permanence -- but the same blindness: they adopted a bucket and were
   told they made one.

**Why no read closes it.** The two states differ only in what was true BEFORE the call, and the
only way to establish that is to look before -- which is the pre-flight existence check ruling 1
forbade as a time-of-check race, and rightly: between the look and the create, the answer can
change. Reading the default retention afterwards would narrow instance 1 (a default is evidence
the bucket is not new, since this call never sets one) without closing it: a bucket that was
already there with a lock and NO default still reads exactly like a fresh one. So the honest
statement of the open question is the coordinator's own: **whether `create` can report anything
truthful about authorship at all without reading the bucket first.** That is a design decision,
not a fix.

**What it would cost to narrow instance 1**, for whoever takes that decision: one more read
(`objectLockDefault`) on the `.lockedAndVersioned` arm, a sentence for "this bucket already has
a default retention you did not set", and an answer to what to do when the default is absent --
where the ambiguity is total and the sheet would have to either say nothing or hedge. I did not
write any of it.

## Round 3 state

Six commits, over BASE `97dfc236`, in order:

1. `0537fdc3` — `fix(app): read back what a create wrote before calling it done` (F1)
2. `a9a24a13` — `perf(core): ask a bucket's Object Lock state once per deleteTree, not per
   refused key` (F2)
3. `6d0c87c8` — `feat(app): draw the empty state an account with no buckets lands on` (F3)
4. `a89e7ed9` — `fix(app): read a created bucket's lock state even where no lock was asked for`
   (F1b)
5. `df948f90` — `perf(core): bound deleteTree's probing when a bucket's lock state cannot be
   read` (F2b)
6. `b6534374` — `fix(app): read back a plain create too, and say when a bucket carries
   protection nobody chose` (F1c)

Each quotes its own observed red verbatim. Tree clean at `b6534374`, nothing pushed. The
"Not done / not verified" list above stands unchanged: no gated suite, nothing seen on screen,
no mutation probe, `docs/BACKLOG.md` / the SDD ledger / `noix-docs` untouched.

This is the last code change asked for on this branch. A scoped re-review of the whole fix wave
comes next and is not mine.

---

# Fix round 4 — the default retention (the maintainer's answer to the fourth notch)

The maintainer chose the narrowing this report costed out: read the default retention, close the
harmful half, leave the residual ambiguity as a backlog row. BASE for this round was `b6534374`.

## F1d — `objectLockDefault` is read whenever the bucket has a lock

**The harm.** `readBack` compared the bucket's protection against the request's, and when the
two were EQUAL it could not tell a bucket this create made from one already there carrying
exactly what was asked for. So a `.lockedAndVersioned` create onto a bucket that already had
Object Lock AND a default retention said "The bucket “X” was created." and recorded
`created bucket X with versioning and Object Lock` -- every word true of the bucket, nothing said
about the default. Under COMPLIANCE every file the person then adds is held until its date and
nobody can delete it, the account owner included.

**The evidence that makes this closable.** `S3BucketSettings.createBucket(_:protection:)` takes
a `BucketProtection` and nothing else, so it cannot set a default. A default that is present was
set by somebody else at some other time, which is the one piece of authorship evidence available
without looking before the create -- and looking before is the time-of-check race the design
ruled out.

**The red, measured through `scripts/mutation-probe` and not by hand.** This is the one round
where I wrote the implementation before running the tests, so the first run was green and there
was no red to quote. Asserting one after the fact is not a measurement, so it was taken against
the committed tree with the harness, whose plant reverts the trigger condition to one that can
never fire for a locked bucket:

```
scripts/mutation-probe --filter 'CreateBucketSheetTests|BucketSettingsAuditTests' \
  --apply "perl -0pi -e 's/guard actual == \.lockedAndVersioned else/guard actual == .none else/' \
    Sources/MacSCPAppKit/CreateBucketSheet.swift"
```

```
── control test --filter CreateBucketSheetTests|BucketSettingsAuditTests
── control: 80 test(s) ran, 0 pre-existing failures
── plant
   Sources/MacSCPAppKit/CreateBucketSheet.swift | 2 +-
   1 file changed, 1 insertion(+), 1 deletion(-)
── (baseline: staged tree at b88b0302)
RESULT: RED — 80 test(s) ran, and the plant was caught by:
  macSCPAppKitTests.BucketSettingsAuditTests/aBucketDefaultFoundOnACreateIsRecordedWithItsModeAndDays()
  macSCPAppKitTests.CreateBucketSheetTests/aBucketWithADefaultRetentionIsNotReportedAsFreshlyCreated()
  macSCPAppKitTests.CreateBucketSheetTests/aDefaultReadThatIsRefusedClaimsNeitherADefaultNorItsAbsence()
  macSCPAppKitTests.CreateBucketSheetTests/aLockedBucketWithNoDefaultIsStillReportedAsCreated()
  macSCPAppKitTests.CreateBucketSheetTests/aPlainCreateOntoABucketWithADefaultGetsTheRetentionSentence()
── revert
```

The control line carries as much as the RESULT: 80 tests ran with 0 pre-existing failures, so
this is RED and not `BUILD FAILED` or `NO TESTS RAN`, which the harness reports as outcomes of
their own. The fifth name is the positive control for the read itself -- it asserts the default
IS asked for even when the answer is nothing -- so the plant takes it down too. `b88b0302` is
the pre-amend commit the probe measured against; the message was then amended to carry the
measurement, and `git log -1` before the amend printed that hash with this subject. The tree was
clean after the harness reverted.

**What landed.**

- `readBack` splits into two stages: the protection pair, then -- only when `actual ==
  .lockedAndVersioned`, because only a locked bucket can carry one -- `objectLockDefault`. The
  trigger is the BUCKET's state, not the request's: a plain create onto a locked bucket asks, a
  create onto a lockless one does not.
- A sixth `ReadBack` case, `.defaultRetentionNotSetHere(_, days:, mode:)`, which outranks the
  three protection answers because it is strictly more than any of them establishes.
- One new catalogue entry, `s3.createBucket.error.defaultRetentionNotSetHere %@`, in four
  languages, German du-form. It states the harm: the bucket already existed, the default was not
  set here, every file added is held until its date, and a COMPLIANCE retention cannot be lifted
  by anyone, not even the account owner. Both clauses are true of EITHER mode, since the bypass
  header that could shorten a GOVERNANCE retention is one nothing here sends
  (`S3BucketSettings.setRetention`), so the sentence needs no hedge about which mode was found.
  The mode and the day count are deliberately not in it: naming them would be a second
  placeholder and a plural rule per language, and the sentence points at the sheet that shows
  both.
- `AuditRecorder.recordBucketCreated` gains `bucketDefault: (days: Int, mode: RetentionMode)?`,
  **with no default value**, like every other parameter on it. The detail gains
  "; the bucket already had a COMPLIANCE default retention of 30 days" (singular "day" at 1,
  like `recordCORSChanged`'s rule/rules). **Ten call sites** spell it, counted 2026-10-23 with
  `/usr/bin/grep -rn -o -e 'recordBucketCreated(' Sources Tests --include='*.swift'`, which
  prints **14** lines, one per OCCURRENCE (`grep -o`, not `grep -c`, which counts lines). The
  four that are not call sites, named one by one: the declaration, the copy of the pattern in
  that doc comment's own command, the copy inside its withdrawal paragraph, and a string literal
  in `createMakesOneRecordingCallPerArmItCanTake`. 14 - 4 = 10 — six in
  `CreateBucketSheet.swift`, one per arm, and four in `AuditRecorderBucketSettingsTests.swift`.

  **The corrected figure was itself wrong once, for the third failure mode in the same CLAUDE.md
  section.** The correction first said 13, counted before its own withdrawal paragraph was
  written; re-running the command after writing that paragraph returned 14, because the
  withdrawal quotes the pattern a second time. Two of the four non-call occurrences are the doc
  comment's own prose, so this figure moves whenever that prose does. Caught only by running the
  command again after writing the sentence, which is what that rule is for.

  **That figure was wrong twice over when first committed, and both failures are the ones
  CLAUDE.md names.** It read, verbatim: "Call sites counted 2026-10-23 with
  `/usr/bin/grep -rn -o -e 'recordBucketCreated(' Sources Tests --include=*.swift`, which prints
  **11 OCCURRENCES** (`grep -o`, one line of output per occurrence -- not `grep -c`, which would
  count lines): the declaration, five calls in `CreateBucketSheet.swift` (one per arm), four in
  `AuditRecorderBucketSettingsTests.swift`, and one string literal inside the source-scanning
  guard `createMakesOneRecordingCallPerArmItCanTake`." Extracted verbatim and run, that command
  printed `(eval):1: no matches found: --include=*.swift` and a count of **0**: zsh expands the
  bare glob before `grep` sees it. Quoted, it prints 13 and not 11 — and "five calls in the
  sheet" was stale by one, because this very round gave `create` a sixth arm. A figure nobody
  could check, and a command that had to be repaired before it ran, in one sentence. The same
  correction is in `AuditRecorder.recordBucketCreated`'s own doc comment, which is where the
  figure lives in the tree.
- A failed default read claims nothing either way: `.unconfirmed` where the protection matched
  (a success sentence would imply the absence the read did not establish), and the established
  mismatch where there was one (its sentence says the settings differ and claims nothing about a
  default).
- Six new tests: the fourth-notch case, its positive control (a locked bucket with no default is
  still reported as created -- which is the residual ambiguity, pinned so it cannot change
  silently), the plain-create-onto-a-default case, the no-lock-no-default-read guard, and the two
  failed-read cases.
- `createMakesOneRecordingCallPerArmItCanTake`, 5 → 6, corrected in place with its wording quoted.
- Catalogue counts, re-run after writing this: `grep -c '^"'` prints **1556** for each of `en`,
  `de`, `fr`, `pl`, from 1555. Key-set parity against `en` still empty for all three.

**The gated test, written and NEVER RUN.**
`S3CreateBucketGatedTests.recreatingABucketLeavesItsDefaultRetentionInPlace` asks the one thing
only the rig can answer: whether a re-create of a bucket that already carries a default retention
leaves that default in place. If a store cleared it, the evidence this round rests on would be
gone exactly when it is needed. I did not start the rig, did not run `MACSCP_ITEST=1`, and named
no rig bucket -- it makes its own throwaway, `macscp-create-default-<12 hex>`, and writes no
object into it, so the bucket stays deletable. It is a claim, it says so in its own doc comment,
and whoever runs the gated suite next is making its first measurement: if the rig disagrees, the
test is wrong and not the rig.

VERDICT: fixed, with the red measured through the harness rather than observed before the fix.

## The backlog row

One row, at the end of "Security and testability" in `docs/BACKLOG.md`, title "A created bucket
that already existed, with a lock and no default retention, cannot be told from a new one".
`git diff --stat docs/BACKLOG.md` printed `1 file changed, 1 insertion(+)`: one physical line
added, no other row touched, no row number swept. It records the residual ambiguity, why no read
closes it (the states differ only in what was true before the call, and establishing that is the
pre-flight existence check ruled out as a time-of-check race), that the maintainer chose this
narrowing on 2026-10-23 over the two stated alternatives, and that the gated test is unrun. Its
two figures travel with commands that have no pipe (several `-e` patterns, not one `-E`
alternation), each saying it counts LINES, and both were re-run from the committed text after the
row was written: **6** and **3**.

## An observation I cannot reproduce, recorded rather than dropped

One `swift test` run during this round printed
`✘ Test run with 5090 tests in 408 suites failed after 21.739 seconds with 1 issue` -- the CORE
target, which passes in every other run. No `✘ Test …` verdict line in that run named a test, so
I cannot attribute it. Three consecutive full runs afterwards printed
`✔ Test run with 5090 tests in 408 suites passed` every time, with the AppKit target's single
known issue and nothing else. One red run is evidence that something CAN happen, not that it
does, and a run whose summary says "1 issue" while no verdict line names a test is the shape
`docs/BACKLOG.md`'s "CI logs lose lines" row describes. I am not claiming it is that, and I am
not claiming it is nothing: I am reporting that I saw it once in roughly six runs of this round
and could not make it happen again.

## Round 4 state

Seven commits, over BASE `97dfc236`:

1. `0537fdc3` — `fix(app): read back what a create wrote before calling it done` (F1)
2. `a9a24a13` — `perf(core): ask a bucket's Object Lock state once per deleteTree, not per
   refused key` (F2)
3. `6d0c87c8` — `feat(app): draw the empty state an account with no buckets lands on` (F3)
4. `a89e7ed9` — `fix(app): read a created bucket's lock state even where no lock was asked for`
   (F1b)
5. `df948f90` — `perf(core): bound deleteTree's probing when a bucket's lock state cannot be
   read` (F2b)
6. `b6534374` — `fix(app): read back a plain create too, and say when a bucket carries
   protection nobody chose` (F1c)
7. `baf75c19` — `fix(app): read a created bucket's default retention, and say when it was not
   set here` (F1d; `b88b0302` was the tree the probe measured, amended to `4fadd23d` to carry
   that measurement and again to `baf75c19` to carry the corrected call-site derivation)

Tree clean at `baf75c19`, nothing pushed. Final suite, three runs in a row:
`✔ Test run with 5090 tests in 408 suites passed` (Core) and
`✘ Test run with 2877 tests in 241 suites failed … with 1 issue` (AppKit), the issue being
`ViewTestabilitySpike.swift:202` every time. `swift build` prints only SwiftPM's own
`missing creator for mutated node`.

Still not verified: the gated suites (the rig was NOT started here and I ran none of them),
anything on screen, and the `noix-docs` paragraph. The SDD ledger is untouched. The only
`docs/BACKLOG.md` change is the one row above.

---

# Round 5 — the Content-MD5 observation, made and written down

Not a fix: a measurement record. The maintainer started the rig and the coordinator ran the
observation that three comments and one backlog row had named as not-yet-made. It landed on the
accepted branch. BASE for this round was `d1e0efa0`, the coordinator's own row committed the
same day on top of `baf75c19`.

**I did not make this measurement and did not verify it.** It is the coordinator's observation,
reported to me, and what I wrote is the record of what they report. I did not start or stop the
rig, ran no gated suite, and named no rig bucket outside the record of what they did.

## What the record now says

Against `http://127.0.0.1:19000` (RustFS 1.0.0), curl's own SigV4, throwaway bucket named for
the purpose, GOVERNANCE and one day, no object written:

```
PUT /<bucket>  with x-amz-bucket-object-lock-enabled: true   200
PUT /<bucket>?object-lock  GOVERNANCE/1 day, NO Content-MD5  200, empty body
GET /<bucket>?object-lock  (the control)                     200, <Mode>GOVERNANCE</Mode><Days>1</Days>
DELETE /<bucket>                                             204
HEAD /<bucket>                                               404
```

The control is what makes it a measurement rather than a status: a 200 alone fits "accepted and
ignored" equally well. Without the read-back the observation would carry the same defect F1 was
about -- a write assumed from a 200 -- which is this branch's own anti-goal turned on its own
evidence.

**Two scopes, and the record keeps them apart.** MEASURED, of RustFS 1.0.0 and nothing else:
this store does not require the header on `PUT ?object-lock`. STILL A READING: that AWS answers
400 without it, from a search summary of AWS's published reference, with no measurement anywhere
in this project and no AWS endpoint ever reached from it.

**And one limit of the instrument, which the pre-decided method did not get.** The plan in
`S3ObjectLockGatedTests`'s header named `S3FileSystem.signedRequest`/`perform`; curl was used.
So what was exercised is the STORE's tolerance of a validly signed request lacking the header,
not macSCP's own code path without it -- which cannot be run without it, because
`setObjectLockDefault` takes no argument for that. For the purpose (does this store care?) the
substitution is sound, since tolerance is a property of the store and the 200 plus the read-back
show the signature was accepted. It is written at each of the four sites anyway, because the
difference between "the store accepts this" and "macSCP's request was accepted" is exactly the
kind of elision this branch keeps catching.

## What was edited

Four places, each quoting verbatim the wording it replaces:

1. `Tests/macSCPCoreTests/S3ObjectLockTests.swift`'s header -- "no run of the request without it
   is on record" and the 2026-10-22 correction that put it there, both withdrawn.
2. `Tests/macSCPCoreTests/S3ObjectLockGatedTests.swift`'s header -- the plan ("**The observation
   that would settle it, and has not been made.**" … "a test nobody has run is a claim")
   becomes the record. The refused branch is KEPT, as a statement about a store that is not this
   one or a later version of it: unmeasured, and still the informative case.
3. The doc comment of
   `S3ObjectLockTests.settingTheDefaultIsAPutWithASignedContentMD5OfItsBody`.
4. **`Sources/macSCPCore/S3/S3FileSystem.swift`, `setObjectLockDefault` -- NOT on the list this
   round was given.** Its passage read "this tree records no run of this request without the
   header against any store, the rig included", which the measurement falsifies. I found it by
   searching for what the observation made false rather than by working the list, and it would
   otherwise have been the only sentence left in the tree claiming the run did not exist.

Plus the `docs/BACKLOG.md` Content-MD5 row: `git diff --numstat` printed `1 1 docs/BACKLOG.md`,
one row, no others touched, no row-number sweep, and the cell holds no pipe (the row's own line
has exactly the two that delimit it).

**The row's sweep command, and a correction inside this round.** It is
`/usr/bin/grep -rn -o -F -e 'rig does not require' -e 'rig does not check' Tests Sources --include='*.swift'`,
which prints **4** lines, one per OCCURRENCE, re-run after the sentence was written. Classified
per MATCH and not per line: one is the live measured statement
(`S3ObjectLockTests.swift:17`), three sit inside quotations of withdrawn wording
(`S3ObjectLockTests.swift:417`, and `S3ObjectLockGatedTests.swift:70` and `:71`, two matches on
two consecutive lines of one quotation). The first draft of that sentence used `-c` with `-r`
and claimed it "prints one COUNT PER MATCHING FILE"; run, it printed a count for every file
scanned, almost all zeros. Replaced after running it, not before.

**A silent no-op, caught.** The first attempt at the row asserted its anchor and then replaced a
DIFFERENT string (`anchor + " |"`, where the row ends with no closing pipe), so the script
printed `ok` and changed nothing. `git diff --stat` showed `docs/BACKLOG.md` absent from the
diff, which is how it was noticed. That is the "A report says what the diff shows" failure mode
exactly, and the only reason it did not reach a report is that the diff was read.

## No test for it, deliberately

The coordinator ruled that no gated test should assert the store's tolerance, and I agree: it
would pin this rig's current behaviour as a requirement, and the next version changing it would
read as macSCP's regression rather than as the store's change. The tests keep pinning what
macSCP SENDS. Recorded in the gated header so the absence is a decision and not an oversight.

## Verification

Comment-only work, so a targeted run:
`swift test --filter 'S3ObjectLockTests|S3BucketSettingsTests|S3CORSTests|S3CreateBucketTests'`
printed `✔ Test run with 99 tests in 4 suites passed after 0.059 seconds`. `swift build` prints
only SwiftPM's own `missing creator for mutated node`. The gated suites were not run.

## State

Eight commits over BASE `97dfc236`, plus the coordinator's `d1e0efa0` in the middle:

1. `0537fdc3` — F1, read back after the create
2. `a9a24a13` — F2, the bucket lock state once per `deleteTree`
3. `6d0c87c8` — F3, the empty bucket list
4. `a89e7ed9` — F1b, the lock read where no lock was asked for
5. `df948f90` — F2b, the `.unknown` bound
6. `b6534374` — F1c, the plain create
7. `baf75c19` — F1d, the default retention
8. `d1e0efa0` — **the coordinator's**, the gated transport cases row
9. `fbc62ae8` — this round, the Content-MD5 measurement record

Tree clean at `fbc62ae8`, nothing pushed. My part is done; the scoped re-review of the fix wave
is not mine.

---

# Round 6 — the scoped re-review's four findings

BASE `fbc62ae8`. Four items, one commit each except M3 which carries the backlog row with it.
D1 is a regression THIS WAVE introduced; the other three are holes it left.

## D1 — a lock read that cannot find out must not fail a create that asked for no lock

**The regression.** `hasObjectLock` answers `false` for exactly one store answer, the code
`ObjectLockConfigurationNotFoundError`, which `S3SettingsXML.parseObjectLockState` maps to
`.notConfigured` while throwing on everything else. So a store that does not implement Object
Lock answers something that throws, and the read-back's single `catch` made that `.unconfirmed`:
a plain create that had fully succeeded showed a red sentence ending "do not create it again",
wrote an error-flagged audit row, and blocked the name. macSCP exists for non-AWS stores.

**It also put the branch in contradiction with itself**, which is how it was found without a
store: `BucketVersioningSheetTests.aLockThatCannotBeReadDoesNotCostABucketThatIsNotEnabled`
already held, in that sheet's own fix round, that a lock which cannot be read changes nothing
the sheet offers or says for a bucket that is not enabled.

**The red.** `swift test --filter 'CreateBucketSheetTests'`:

```
✘ Test aLockReadTheStoreCannotAnswerDoesNotFailAPlainCreate() recorded an issue at CreateBucketSheetTests.swift:668:9: Expectation failed: settings.reads == ["macscp-third"]
↳   settings.reads → []
✘ Test aLockReadTheStoreCannotAnswerDoesNotFailAPlainCreate() recorded an issue at CreateBucketSheetTests.swift:669:9: Expectation failed: model.isCreated
↳   isCreated → false
✘ Test aLockReadTheStoreCannotAnswerDoesNotFailAPlainCreate() recorded an issue at CreateBucketSheetTests.swift:670:9: Expectation failed: model.failureSentence == nil
↳   model.failureSentence → "A bucket named “macscp-third” exists now, but macSCP could not check whether it has the settings you chose. Open Versioning and Object Lock for it to see what it has, and do not create it again."
✘ Test aLockReadTheStoreCannotAnswerDoesNotFailAVersionedCreate() recorded an issue at CreateBucketSheetTests.swift:683:9: Expectation failed: model.isCreated
✘ Test run with 69 tests in 1 suite failed after 0.345 seconds with 6 issues.
```

The printed sentence IS the regression: a create that did exactly what was asked, told not to do
it again. `settings.reads → []` is why — the versioning read was never reached.

**What landed.** `hasLock` is a `Bool?`: `nil` is "not found out", which is not `false`. A
`nil` costs the create its success only when `choice == .lockedAndVersioned`. Otherwise the
outcome is decided on the versioning read, and `hasLock ?? false` enters only the comparison —
the protections name what is positively there, so an unknown lock is left out of the audit line
rather than reported absent, and `protection(hasObjectLock: false, …)` can never answer
`.lockedAndVersioned`, which keeps the default-retention read unreachable on an unknown lock. A
failure of the VERSIONING read is `.unconfirmed` whatever was asked: with neither property
established there is nothing left to report. The sibling's precedent is cited at the line.
Four tests, including the negative control (asked for a lock, cannot confirm → still
`.unconfirmed`, and the versioning read not spent).

**The price, written into `readBack`'s doc comment as ruled.** On a store with no Object Lock,
`protectionNotChosen`'s lock half and `defaultRetentionNotSetHere` cannot fire — acceptable,
since such a store has no lock to carry. The real loss is narrower: a store that DOES implement
Object Lock, on a bucket that has one, whose `GET ?object-lock` is REFUSED rather than answered.
That was `.unconfirmed` (which at least said the settings could not be checked) and is now a
clean success. The versioning half still fires, so a plain create onto a versioned bucket is
still reported.

VERDICT: fixed. Commit `4dc3aebc`.

## M1 — a plant on the `.unconfirmed` arm went unnoticed

Reproduced the re-review's own measurement first, through the harness against `4dc3aebc`:
changing that arm's `bucketDefault: nil` to `(days: 7, mode: .compliance)` gave
`RESULT: GREEN — 84 test(s) ran and NONE of them noticed the plant`, with
`control: 84 test(s) ran, 0 pre-existing failures` above it — so insensitivity, not a build
that never compiled. With the plant in, a create whose read-back was refused wrote a flat claim
that the bucket already had a COMPLIANCE default retention of 7 days, about a bucket where
nothing was established. `createMakesOneRecordingCallPerArmItCanTake` counts calls and reads no
arguments, and no behavioural case drove `create` to `.unconfirmed` with a recorder at all.

`anUnconfirmedCreateRecordsTheAttemptAndNoDefault` now asserts the detail is the ATTEMPT
("created bucket macscp-third with versioning and Object Lock"), carries no default clause, and
is error-flagged with the unconfirmed sentence. Same plant re-run against the commit:
`RESULT: RED — 85 test(s) ran, and the plant was caught by …
anUnconfirmedCreateRecordsTheAttemptAndNoDefault()`. GREEN at `4dc3aebc`, RED at `af0b03be`,
measured from both sides.

VERDICT: closed. Commit `001baac8` (amended from `af0b03be` to carry the after-measurement).

## M2 — F2's own harm survived on a bucket that really is locked

`.inForce` had no bound, so in F2's exact failure configuration on a locked bucket — list but
not delete, every key refused, no key under a hold — the ~2000 requests F2 measured were still
paid in full, on the one bucket state the hoist cannot settle. The comment cited that
measurement as what the hoist prevents without saying where it survives.

**The red.** `swift test --filter 'S3ObjectLockTests'`:

```
✘ Test aLockedBucketStopsProbingAfterEnoughUninformativeAnswers() recorded an issue at S3ObjectLockTests.swift:849:9: Expectation failed: outcome.probeRequests == 1 + 2 * bound
↳   outcome.probeRequests → 13
✘ Test run with 54 tests in 1 suite failed after 0.037 seconds with 1 issue.
```

13 = one bucket read plus two per refused key over a batch of six. The bound makes it 9.

**The bound is four, derived in `uninformativeProbeBound`'s own doc comment.** N uninformative
answers in a row against one bucket is evidence the refusals are permission-based rather than
lock-based: a locked bucket may hold unlocked objects, so ONE uninformative probe proves nothing
and a pair is a cheap coincidence; four is the smallest N past that which is still a sample, and
costs at most eight signed GETs, under half a percent of the 2000. What it trades away: the
finding is given up only when none of the first four refused keys is locked while a later one
is, and the order is the batch's, which is the listing's. The test READS the constant rather
than spelling it, and asserts `keys.count > bound` and `bound >= 1` as controls for its own
figure. The counter is renamed `uninformativeProbes` and counts probes made on every arm; its
old comment ("the bound is one") and the walk's comment are corrected with their wording quoted.

VERDICT: fixed. Commit `bb43ed49`.

## M3 — a comment this wave falsified without touching it

`BrowserScope.isContainerListRoot`'s doc said "FOUR readers, five reads" and carried
`git grep -no isContainerListRoot -- Sources ':!*BrowserScope.swift' | wc -l` claiming 4. My own
F3 (`6d0c87c8`) added a fifth reader, `EmptyContainerListView.isShown`, and never touched that
file. Run unrepaired on 2026-10-23 it prints **6**.

Recounted, classified per MATCH and not per line because two share a line and one is not a read:
`BrowserContextMenu.swift` twice, `ComparisonRequest.swift` twice on one line,
`EmptyContainerListView.swift` twice — once in prose, once in `isShown`. FIVE readers, SIX reads
(the sixth read is `acceptsIncomingFiles`, in the declaring file the command excludes). The old
paragraph's claim that the exclusion "leaves only reads" is also withdrawn: the exclusion keeps
this file's own spellings out, and nothing stops another file naming the symbol in a comment.
Re-run after writing, still 6 — unchanged by the sentence, which is what the exclusion buys.

VERDICT: corrected. Commit `a148e162`, with the backlog row below.

## The IPv6 row

`ConnectionDiagnosticsTests.resolveAcceptsABareIPv6LiteralAndRejectsABracketedOne`: the
coordinator saw it RED in one full unit run; alone it is green 3 of 3, reproduced here at
0.038 s, 0.010 s, 0.008 s. **I never saw it red**, and the row says so. It carries
`timeout: .seconds(2)` against a real `getaddrinfo`, in the file CLAUDE.md's wall-clock-ceiling
section cites twice for cases that came back at 20.68 s on a three-core runner. Ten such bounds
in the file, by
`/usr/bin/grep -c -F -e 'timeout: .seconds(2)' Tests/macSCPCoreTests/ConnectionDiagnosticsTests.swift`
— prints 10, counts LINES, and `grep -o` with `wc -l` also prints 10, so no line holds two. Not
fixed, by instruction. One row, no others touched, no row-number sweep, three pipes on the line.

**It retires a claim of this wave's own**, which the row states: round 4 reported "three
consecutive full runs" green apart from the known failure, and a suite with a resolver ceiling
in it has no reproducible verdict, so that was luck as much as measurement. It is also the
likely explanation of round 4's one unreproducible Core failure, recorded above — likely, not
established: that run named no test.

## Round 6 state

Thirteen commits over BASE `97dfc236`, of which `d1e0efa0` is the coordinator's:

`0537fdc3` (F1), `a9a24a13` (F2), `6d0c87c8` (F3), `a89e7ed9` (F1b), `df948f90` (F2b),
`b6534374` (F1c), `baf75c19` (F1d), `d1e0efa0` (coordinator's row), `fbc62ae8` (Content-MD5
record), `4dc3aebc` (D1), `001baac8` (M1), `bb43ed49` (M2), `a148e162` (M3 + the IPv6 row).

Tree clean at `a148e162`, nothing pushed. Final suite:
`✔ Test run with 5091 tests in 408 suites passed` (Core) and
`✘ Test run with 2882 tests in 241 suites failed … with 1 issue` (AppKit), the issue being
`ViewTestabilitySpike.swift:202`. `swift build` prints only SwiftPM's own
`missing creator for mutated node`. **Given the IPv6 row, "the suite is green apart from the
known failure" is a statement about these runs and not a reproducible property.**

Still not verified: the gated suites (the rig is up and the maintainer owns it — I did not start
it, stop it, or run any gated test, and named no rig bucket), anything on screen, the AWS half
of the Content-MD5 question, and `noix-docs`.

---

# Round 7 — the tension, rowed

One row, no code. The coordinator ruled on 2026-10-23 that D1's trade stands and the residue is
recorded rather than built out, with the weighing stated: D1's case is ONE condition (any store
without Object Lock, any plain create), the case the fix re-opens is a conjunction of THREE, and
a success-carrying-a-caveat would be new sheet semantics at the end of a branch where nothing
has been seen on screen.

## What the row says

Title: "A create cannot both forgive a lock read it did not need and warn about protections the
bucket already has". In `docs/BACKLOG.md`, "Security and testability", inserted directly after
the residual-ambiguity row so the family is adjacent. Six things, in the order the row has to be
judged in:

1. **The tension as a tension.** `readBack` forgives a lock read keyed on what the REQUEST
   promised; `protectionNotChosenTemplate` and `defaultRetentionNotSetHereTemplate` exist for
   what the BUCKET turns out to have. No arm serves both, and none of the six arms `create`
   records on is "succeeded, with something we could not check".
2. **The exact case given up, by symbol**: a store that implements Object Lock, a bucket that
   has one, `hasObjectLock(ofBucket:)` refused rather than answered. `ReadBack.unconfirmed`
   before `4dc3aebc`, a clean success after. The versioning half still fires.
3. **What closing it would take**: a fourth outcome, a success with a caveat, distinct from
   `.unconfirmed`, which is a failure — plus one sentence per catalogue. The sentence is the
   cheap half: `Outcome` has four cases and no success-with-caveat shape, so every reader of
   `isCreated`, `failureSentence` and `bucketMayExist` is a site to re-decide.
4. **The conjunction of three conditions** for data to actually be at risk: lock implemented,
   lock configuration unreadable by that key, and a default retention present — without which
   the lock locks nothing. Against D1's one.
5. **That D1 was this wave's own regression**, introduced by F1's read-back and fixed inside the
   wave, found because the sibling sheet had already decided the same question the other way. So
   the row is not a pre-existing hole nobody noticed; it is the residue of a fix.
6. **The family**: it and the residual-ambiguity row circle one question — whether `create` can
   report anything truthful about authorship without reading the bucket before it writes, which
   is the pre-flight existence check ruled out as a time-of-check race — and both take the
   disposition the maintainer chose on 2026-10-23.

## Figures, both re-run after the row was written

- `/usr/bin/grep -c -F -e 'recorder?.recordBucketCreated(' Sources/MacSCPAppKit/CreateBucketSheet.swift`
  prints **6**, counting LINES, each of those calls beginning its own line. The same command the
  residual-ambiguity row uses, deliberately, so the two rows share a derivation.
- `/usr/bin/grep -rl -F -e 's3.createBucket.error.protectionNotChosen' Sources/MacSCPAppKit/Resources`
  prints **4** paths, one per `.lproj`: what any new sentence costs.
- The two enum counts the row asserts were READ from the source rather than remembered:
  `ReadBack` has five cases (`asAsked`, `lessThanAsked`, `moreThanAsked`,
  `defaultRetentionNotSetHere`, `unconfirmed`) and `Outcome` four
  (`editing`, `creating`, `created`, `failed`).

`git diff --numstat` printed `1 0 docs/BACKLOG.md`: one line added, no other row touched, no
row-number sweep, three pipes on the line.

VERDICT: recorded. Commit `eac54709`. The suite is unaffected —
`✔ Test run with 5091 tests in 408 suites passed` (Core) and
`✘ Test run with 2882 tests in 241 suites failed … with 1 issue` (AppKit), the issue being
`ViewTestabilitySpike.swift:202`, with the IPv6 row's caveat on what "green" is worth here.

## Three things the coordinator accepted as they stand, recorded so they are not re-opened

- `uninformativeProbeBound = 4` is a judgement with a written derivation, not a measurement, and
  its doc comment says so. Measuring it would need a gated fixture with a known mix of locked
  and unlocked objects, which does not exist.
- Round 4's "three consecutive full runs" claim and round 6's IPv6 row both stand. The
  unreproducible Core failure from round 4 named no test and so cannot be attributed; "probably
  the same thing" is as strong as the evidence allows, and the two statements are NOT tidied
  into one.
- The IPv6 row says plainly that I never saw it red: the red is the coordinator's, mine are the
  three alone-runs and the code reading.

## Final state of my part

Fourteen commits over BASE `97dfc236`, of which `d1e0efa0` is the coordinator's:

`0537fdc3` (F1) · `a9a24a13` (F2) · `6d0c87c8` (F3) · `a89e7ed9` (F1b) · `df948f90` (F2b) ·
`b6534374` (F1c) · `baf75c19` (F1d) · `d1e0efa0` (coordinator's row) · `fbc62ae8` (Content-MD5
record) · `4dc3aebc` (D1) · `001baac8` (M1) · `bb43ed49` (M2) · `a148e162` (M3 + IPv6 row) ·
`eac54709` (this row).

Tree clean at `eac54709`, nothing pushed. Three `docs/BACKLOG.md` rows are mine: the
residual-ambiguity row, the IPv6 flake row, and this one. The SDD ledger, the user
documentation and the merge are the coordinator's.

Not verified: the gated suites (the rig is up and owned by the maintainer — I did not start it,
stop it, run any gated test, or name any rig bucket), anything on screen, the AWS half of the
Content-MD5 question, `noix-docs`.

Not verified.
