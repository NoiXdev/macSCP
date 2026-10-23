# Scoped re-review of the final fix wave — `97dfc236..fbc62ae8`

Reviewer: scoped re-reviewer (Opus 5). Date: 2026-10-23.
Worktree: `/Users/noidee/macSCP/.claude/worktrees/diff-view`, clean at `fbc62ae8`.
Scope: the nine commits `97dfc236..fbc62ae8` only. 22 files, 1858 insertions
(`git diff --stat 97dfc236..fbc62ae8`).

Verdicts were written as each section was started (`VERDICT PENDING`) and filled
in when the section's evidence was in hand.

| # | Check | Verdict |
| - | ----- | ------- |
| 1 | The three original findings are closed | PASS |
| 2 | Read-back totality and non-overlap | PASS |
| 3 | The audit trail claims no protection the bucket lacks | PASS with one unguarded arm (M1) |
| 4 | No must-not-leak value reaches a failure message | PASS |
| 5 | F2b's bound and its written-down cost | PASS for `.absent`/`.unknown`; the `.inForce` cost is unrecorded (M2) |
| 6 | F3's rule tests and the honesty of "unverified" | PASS |
| 7 | Catalogue parity | PASS (six keys, not five) |
| 8 | The two maintainer measurements | PASS — both reproduce |
| 9 | A plant the new guards do not catch | FOUND ONE (M1) |

Found outside the nine checks: **D1** — a plain create now reports a false alarm
on any store whose `GET ?object-lock` is not answered with
`ObjectLockConfigurationNotFoundError`; **M3** — a comment the wave did not
touch now miscounts its own callers; **O1** — an ungated Core case went red
under a full run here and is green alone. All three have sections of their own.

Every figure below carries the command that produced it, in the form it was run.
`grep` in this session is a shell function running `ugrep -G`; every command
below spells `/usr/bin/grep` where the result is a figure.

## 1. The three original findings are closed

VERDICT: **PASS.** Read from the diff, not from the report.

**F1.** `CreateBucketModel.create`'s accepted-create arm is no longer
`outcome = .created` straight off a non-throw. It is
`switch await Self.readBack(choice, ofBucket: bucket, via: settings)` over six
arms, and `readBack` calls `settings.hasObjectLock(ofBucket:)` then
`settings.versioning(ofBucket:)` through the same capability the write used, and
`settings.objectLockDefault(ofBucket:)` when the bucket turns out to carry a
lock. The spec's anti-goal is met: no arm asserts a setting from a 200.

**F2.** The per-refused-key probe is gated on a per-call
`var bucketLock = BucketLockState.notAsked`, filled at most once per
`deleteTree` call by `bucketLockState(ofBucket:)`. A bucket with no Object Lock
now spends ONE probe request for a whole batch. Pinned by
`S3ObjectLockTests.aBatchOfRefusedKeysAsksTheBucketsLockStateOnlyOnce`
(`probeRequests == 1` over four refused keys, with `#expect(keys.count == 4)`
beside it as the control for the count).

**F3.** `Sources/MacSCPAppKit/EmptyContainerListView.swift` is new, drawn from
`BrowserPane`'s ZStack as a third state beside `.loading` and `.failed`, and its
button routes through `ContentView.openCreateContainerSheet(in:session:)` →
`handleConnectionAction`, which re-asks `ConnectionActionRoute.isAvailable`
before building a sheet (read at `ContentView+MenuActions.swift:194`). The
claim "it goes THROUGH the route" is true of the code, not only of the comment.

## 2. Read-back totality and non-overlap

VERDICT: **PASS.** Total, single-valued, every arm reachable, no `default`.

`ReadBack` is a private enum of six cases and the `switch` over it in `create`
has no `default` (nor does `protectionRank`, nor the `mayProbe` switch in
`deleteTree`). `readBack`'s body is a chain of guards in which every path ends
in exactly one `return`:

| read of lock+versioning | `actual` | default read | arm |
| - | - | - | - |
| throws | — | not reached | `.unconfirmed` |
| ok | `.none`/`.versioned`, `== choice` | not reached | `.asAsked` |
| ok | `.none`/`.versioned`, rank > choice | not reached | `.moreThanAsked` |
| ok | `.none`/`.versioned`, rank < choice | not reached | `.lessThanAsked` |
| ok | `.lockedAndVersioned` | returns a default | `.defaultRetentionNotSetHere` |
| ok | `.lockedAndVersioned` | returns `nil` | `mismatch ?? .asAsked` |
| ok | `.lockedAndVersioned` | throws | `mismatch ?? .unconfirmed` |

Three things worth stating, all of which check out:

- `.lessThanAsked` can never be produced for `actual == .lockedAndVersioned`,
  because rank 2 is the chain's maximum. So the `guard actual ==
  .lockedAndVersioned` only ever discards `.moreThanAsked` or `nil`. The
  `defaultRetentionNotSetHere` arm's "it outranks the three cases above" is
  therefore a claim about two cases plus success, and it is sound.
- The one place two findings compete is a locked bucket with a default where
  the protection ALSO mismatched (plain create onto a locked bucket with a
  default): the default wins, so the sheet says the retention sentence and not
  `protectionNotChosen`. The audit line still carries `protection: actual`, so
  nothing about the lock is lost from the record, and the retention sentence is
  the strictly scarier of the two. Pinned by
  `aPlainCreateOntoABucketWithADefaultGetsTheRetentionSentence`.
- `mayProbe`'s `.notAsked` arm in `deleteTree` is unreachable: the `if
  bucketLock == .notAsked { bucketLock = await bucketLockState(...) }`
  immediately above it guarantees a different value, and `bucketLockState`
  never returns `.notAsked`. That is exhaustiveness, not a hole — its value is
  `false`, the safe answer — but it is never exercised.

`theDirectionOfAMismatchDecidesWhichSentenceIsShown` walks all six ordered pairs
of distinct protections and asserts 3 more / 3 less, so the chain's totality is
measured and not asserted.

## 3. The audit trail claims no protection the bucket lacks

VERDICT: **PASS on the four read-back arms; the two attempt arms are correct by
the maintainer's ruling but nothing holds them to it (M1).**

Four of the six arms pass `protection: actual` — what was read — and
`BucketSettingsAuditTests` pins each direction with a positive control:

- `aCreateWhoseObjectLockDidNotTakeIsNotRecordedAsHavingIt`:
  `detail == "created bucket macscp-third with versioning"` and
  `detail.contains("Object Lock") == false`, with the applying store beside it
  producing `"… with versioning and Object Lock"`.
- `aCreateOntoAnAlreadyLockedBucketRecordsTheLockItFound` and
  `aPlainCreateOntoAnAlreadyProtectedBucketRecordsWhatItFound`: the inverse —
  the line does not OMIT a protection the bucket has.
- `aBucketDefaultFoundOnACreateIsRecordedWithItsModeAndDays`: the full detail
  string with `"; the bucket already had a COMPLIANCE default retention of 30
  days"`, and the no-default control asserting the clause's absence.

Every failure arm reaches `AuditEvent(isError: failure != nil, errorMessage:
failure)` through `appendBucketSetting`, and both surfaces that render a row
append the sentence to the detail: `AuditEventText.detail(for:)` returns
`"\(event.detail) — \(errorMessage)"`, which the table cell, the search string
and the export line all read. So no arm's detail is shown on its own.

**What I checked that the brief asked about specifically.** The `.unconfirmed`
arm and the thrown-refusal arm record `protection: choice` — the ATTEMPT. On the
`.unconfirmed` arm nothing was read, so the detail string
`created bucket X with versioning and Object Lock` is a sentence about a
protection that was never established. The disclosure is in the fix report's own
concern 3, and the coordinator upheld it; the mitigation is the error suffix
above, which is present by construction. I accept the ruling. **What is missing
is a check** — see M1.

**Minor, not a finding:** the detail's verb is "created bucket X", which on
`moreThanAsked` and `defaultRetentionNotSetHere` sits beside a sentence saying
the bucket "already existed". The two halves of the rendered row disagree about
authorship. The wording predates the wave; the arms that make it read oddly do
not.

## 4. No must-not-leak value reaches a failure message

VERDICT: **PASS.**

Three new tests carry a planted store `reason`
(`https://AKIDEXAMPLE:SECRETEXAMPLE@store.invalid`) and all three follow
CLAUDE.md's rule: the value is a named constant `planted`, the predicate is
computed into a `let quoted` before the expectation, and the expectation is
`#expect(!quoted)`:
`aRefusedPlainCreateSaysItWasNotCreatedAndNamesNoCause`,
`aReadBackThatIsRefusedSaysTheSettingsCouldNotBeConfirmed`,
`aDefaultReadThatIsRefusedClaimsNeitherADefaultNorItsAbsence`.

New code that could have carried a store's words and does not:

- `readBack`'s two `catch` arms discard the error entirely; neither the
  `.unconfirmed` sentence nor the audit `failure:` is derived from it.
- `deleteTree`'s two `reason` constants are static literals, the second built
  from the first by concatenation. Neither interpolates anything. The fixtures
  put `<Message>text the store wrote</Message>` on the wire and the tests assert
  `reason == S3FileSystem.deleteTreeRefusedReason` by equality, which excludes it.
- `recordBucketCreated`'s new `bucketDefault` contributes `mode.rawValue` (an
  enum case, `GOVERNANCE`/`COMPLIANCE`) and `days` (an `Int`). No free text
  from the store reaches the trail.

One observation, not a finding: the equality expectations that sit beside the
computed `Bool` (`#expect(sentence == CreateBucketModel.notCreatedLine.text)`)
would print the sentence's value on a red, and on a red that is exactly the
leak. The value is a planted fake defined in the test, and on that red the
printed leak is the diagnosis, so this is the right trade — but it is worth
knowing that the canary's *first* exit is still open and only the explicit
`quoted` check is closed.

## 5. F2b's bound and its written-down cost

VERDICT: **PASS — the bound is real and measured sensitive. But the `.inForce`
arm still pays the full cost F2 measured, in F2's own failure configuration, and
that is written down nowhere (M2).**

**The bound is real, not intended.** `probesWhileUnknown` is a per-call counter,
incremented before the probe, and `mayProbe` reads `probesWhileUnknown == 0` for
`.unknown`. Measured by mutation probe (plant: `case .unknown: mayProbe = true`,
filter `S3ObjectLockTests`, through `scripts/mutation-probe`):

```
── control: 53 test(s) ran, 0 pre-existing failures
RESULT: RED — 53 test(s) ran, and the plant was caught by:
  macSCPCoreTests.S3ObjectLockTests/anUnreadableBucketLockStateProbesOnlyTheFirstRefusedKey()
```

**The two reason constants distinguish the cases**, and each has a positive
control: `anUnreadableBucketLockStateProbesOnlyTheFirstRefusedKey` asserts
`reason == deleteTreeRefusedWithUnreadableLockStateReason` *and*
`reason != deleteTreeRefusedReason`, and
`aBucketWhoseLockStateReadsGivesThePlainReason` asserts the inverse, so neither
spelling is the answer to every refusal.

**The trade is written down** at the line in `deleteTree`, in
`BucketLockState.unknown`'s own doc comment (corrected in place, quoting what it
replaced), and in the fix report's F2b section, in the plain words the brief
asked for: a key further down the batch can carry a legal hold the first one
does not, and in that configuration the user now gets the generic message. The
`reason` records which case it was. That obligation is met.

**M2 — the cost the record does not name.** `.inForce` has no bound at all: it
is `mayProbe = true` for every refused key. The probing stops early only when a
probe is INFORMATIVE, because `lockFinding` throws. Take the exact
configuration F2's failure scenario names — an access key with `s3:ListBucket`
and no `s3:DeleteObject` — on a bucket that HAS Object Lock. Every key comes
back `AccessDenied`; `lockFinding` issues `GET ?legal-hold` and `GET ?retention`
for each; both are refused for the same missing permission, so `try?` yields
`nil` and the walk continues. One bucket read plus 2 × 1000 signed GETs: the
~2000 requests F2 measured, paid in full, for a bucket that merely happens to
have Object Lock on.

The comment at the site presents the hoist against exactly that scenario ("an
access key with list but not delete permission … about 2000 requests on a full
batch, which is what F2 … measured") without saying that the hoist does not help
when the bucket is locked. The original review's "the lock case is cheap — it
throws on the first established hold" is the same elision one level up: it is
cheap only when a probe is informative. No test exercises an `.inForce` batch in
which every probe is uninformative
(`aBucketWithObjectLockStillNamesTheKeyUnderAHold` makes the first key the
answer), so the suite is silent on it too.

I am not calling this a regression — the cost pre-dates the wave and the wave
reduces it — and whether `.inForce` should be bounded is a design decision, not
a fix. But the asymmetry is not derived from the stated principle: "nothing
distinguishes the five-hundredth key from the first" is why `.unknown` buys one
probe, and after the first uninformative probe it is equally true of
`.inForce`. At minimum the comment and the row should say that the measured
2000-request case survives for locked buckets.

## 6. F3's rule tests and the honesty of its unverified status

VERDICT: **PASS.**

- **In the registry as its neighbours are.** `BoundedViewRegistry.cappedViews`
  gains `BoundedViewEntry("an account with no buckets yet, the create action
  offered") { EmptyContainerListView(onCreate: {}) }`, and the entry is not
  optional: `BoundedViewCoverageTests` holds the registry to set equality
  against the declared `BoundedView` conformers, so an unregistered conformer is
  red. The bound `.capped(minWidth: 220, maxWidth: 260)` sits 20 pt inside
  `BrowserPane.minimumWidth`, which is `280` (read at
  `BrowserPane.swift:19`) — the comment's arithmetic is correct.
- **No literal.** `/usr/bin/grep -n -E 'Text\(|Button\(|systemName'
  Sources/MacSCPAppKit/EmptyContainerListView.swift` prints four lines (4
  occurrences, one per line): the `tray` SF Symbol, `Self.titleLine.text`,
  `Self.bodyLine.text` and `CreateBucketModel.titleLine.text`. So the view's
  text is **three catalogue lookups, from two own keys plus the sheet's title**,
  each resolved in all four catalogues — not four entries, as the brief's
  wording suggested. `/usr/bin/grep -o 'CatalogueLine('
  Sources/MacSCPAppKit/EmptyContainerListView.swift | wc -l` prints 2
  (occurrences). The icon is declared in `IconTooltipLintTests.decorativeIcons`
  with a reason, as that lint requires.
- **The rule tests.** Ten cases: the positive, five negatives in one case
  (`nothingElseGetsIt` — items present, loading, failed, non-container root,
  inside a bucket), a case tying `isShown` to `CreateBucketModel.isOffered`
  over three paths, three catalogue cases, and three wiring scans over
  COMMENT-FREE source. Every negative scan has a positive control beside it
  (`pane.contains("struct BrowserPane")`,
  `actions.contains("func handleConnectionAction(")`,
  `remoteBlock.contains("onCreateContainer:")`), which is CLAUDE.md's rule for
  a negative check.
- **The honesty.** The fix report says it plainly and in the right places: a
  bold "**NOT VERIFIED VISUALLY.** Nothing on this branch ever has been: no GUI
  was run, no screenshot taken, the app and its binary were never launched", a
  verdict line reading "fixed in code, unverified on screen", and an explicit
  list of what is measured (rule, catalogues, wiring, layout figures) against
  what is not (spacing, icon weight, whether the button reads as the next
  step). Nothing in it implies a visual check. I launched nothing either.

## 7. Catalogue parity

VERDICT: **PASS.** Key sets are identical across all four locales in both
localized targets, no duplicates, German is du-form. One correction to the
brief: the wave added **six** keys, not five.

Command (key-set comparison; `grep -o` counts OCCURRENCES of a line-initial
quoted key, one per line here, then `sort -u` and `diff` compare the SETS):

```
for t in MacSCPAppKit macSCPCore; do for l in de fr pl; do
  a=$(/usr/bin/grep -o -E '^"[^"]+"' Sources/$t/Resources/en.lproj/Localizable.strings | sort -u)
  b=$(/usr/bin/grep -o -E '^"[^"]+"' Sources/$t/Resources/$l.lproj/Localizable.strings | sort -u)
  diff <(echo "$a") <(echo "$b"); done; done
```

Raw totals: `MacSCPAppKit` 1556 unique keys in each of `en`, `de`, `fr`, `pl`,
zero diff lines for each pair; `macSCPCore` 131 in each, zero diff lines.
Duplicates within a catalogue, with `sort | uniq -d | wc -l`: 0 in all eight
files.

Keys added by the wave, from
`/usr/bin/grep -o -E '^\+"[^"]+"'` over `git diff 97dfc236..fbc62ae8 --
Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings` — **six**
occurrences, one per line:
`browser.pane.noContainers.title`, `browser.pane.noContainers.body`,
`s3.createBucket.error.settingsDidNotTake %@`,
`s3.createBucket.error.settingsUnconfirmed %@`,
`s3.createBucket.error.protectionNotChosen %@`,
`s3.createBucket.error.defaultRetentionNotSetHere %@`.
`Sources/macSCPCore/Resources/` is untouched by the wave.

German du-form, read by eye on all six new strings: "Erstelle einen",
"die **du** nicht gewählt hast", "Jede Datei, die **du** hinzufügst", "Öffne für
ihn". No `Sie`/`Ihnen`/`Ihr…`. `GermanAddressFormTests` derives its catalogue
list rather than naming it, so the new strings are inside its scan by
construction; its regex is capital-initial (`\bIhr(?:e|em|en|er|es)?\b`), and
the only lowercase `ihres` in the new text ("bis zum Ablauf ihres Datums") is
correctly out of scope.

## 8. The two maintainer measurements

VERDICT: **PASS. Both reproduce, extracted from the committed text and run
unrepaired. Neither overstates what it measured.**

### The gated-suite row (`d1e0efa0`)

Extracted with
`/usr/bin/grep -o -e 'MACSCP_ITEST=1 swift test --filter [^`]*' docs/BACKLOG.md`
and run verbatim. The rig was already up (I started and stopped nothing;
`docker ps` shows `macscp-test-sshd`, `macscp-test-s3`, `macscp-test-webdav`,
`macscp-test-sftpgo` and the host-key/forward variants running):

```
MACSCP_ITEST=1 swift test --filter s3ToSSHCopyIsByteIdentical --filter aLocalForwardCarriesABulkTransferPastTheHighWaterMark --filter aFinishedRunLeavesNoFileAndSweepsOnlyAnEarlierRunsFile --filter windowChangeReachesTheRemotePTY
→ ✔ Test run with 4 tests in 4 suites passed after 3.078 seconds.
   s3ToSSHCopyIsByteIdentical 0.388 s, aLocalForwardCarriesABulkTransferPastTheHighWaterMark 0.420 s,
   aFinishedRunLeavesNoFileAndSweepsOnlyAnEarlierRunsFile 0.691 s, windowChangeReachesTheRemotePTY 3.078 s
```

The row claims it "prints `Test run with 4 tests in 4 suites passed`, the cases
taking 0.456 s, 0.448 s, 0.703 s and 3.195 s". The verdict reproduces exactly;
my four times are all a little lower, which is what a per-run wall clock does
and is not something the row asserts as a figure to match.

**Pipe-cleanliness holds.** The row's own line carries exactly 3 pipes
(`awk 'NR==175' docs/BACKLOG.md | /usr/bin/grep -o '|' | wc -l` → 3): the
leader, the separator, the trailer. Nothing inside the cell. The commit message
says the same and is right. The four repeated `--filter` flags ran as committed;
nothing needed repairing, which is the whole point of the form.

**The row's other committed figure reproduces too.** `git diff --name-only
eec041f5..HEAD -- Sources | wc -l` prints 40, at `fbc62ae8` and at `d1e0efa0`,
and none of the 40 is a tunnel, throughput-rig or shell source (the one hit for
`-e pty` is `EmptyContainerListView.swift`, on "Em**pty**").

**Does the row overstate "not attributable"?** No. It states the set moves
between runs, names the one case in touched territory and says it did not
reproduce, counts the untouched areas with a command that runs, and then
explicitly withdraws the stronger word: "'pre-existing' here is an inference
from the moving set and the untouched areas rather than a comparison", because
the same two runs at the base `eec041f5` were not made. It also says the
mechanism is not measured and names two untested candidates. I have no
correction to offer.

### The Content-MD5 record (`fbc62ae8`)

The committed sweep command, run verbatim:

```
/usr/bin/grep -rn -o -F -e 'rig does not require' -e 'rig does not check' Tests Sources --include='*.swift'
→ 4 lines (occurrences, one per line):
  Tests/macSCPCoreTests/S3ObjectLockGatedTests.swift:70, :71
  Tests/macSCPCoreTests/S3ObjectLockTests.swift:17
  Tests/macSCPCoreTests/S3ObjectLockTests.swift:417
```

Classified per MATCH, as the row says: `:17` is the live measured statement;
`:417` is inside `(Withdrawn, verbatim: "and the rig does not check it", …)`;
`:70`/`:71` are two matches inside one quotation of the withdrawn 2026-10-22
wording. The live claim at `S3ObjectLockTests.swift:406` reads "The rig does
**NOT** check the header", with a capital, which is why it is not among the four
— and that is the only live statement outside `:17`. The classification is
correct.

**All four sites record the instrument's limit**, and none overstates:

1. `S3ObjectLockTests.swift` header: "Sent with curl's own SigV4 … **not**
   through `S3FileSystem`, so what is measured is that this store accepts a
   validly signed request without the header, not that macSCP's own code path
   was exercised without it." AWS kept as a reading: "**The AWS half is still a
   reading, not a measurement.**"
2. `S3ObjectLockGatedTests.swift` header: "**The instrument was curl's own
   SigV4** … and NOT `S3FileSystem.signedRequest`/`perform` as the plan below
   had named", with the scope bullet "It measures RustFS 1.0.0 and nothing
   else" and the refused branch kept as the still-informative case.
3. `S3ObjectLockTests.settingTheDefaultIsAPutWithASignedContentMD5OfItsBody`:
   names the measurement, scopes it to "RustFS 1.0.0 only", and refers to the
   file header "for the method and the control" rather than restating the
   instrument caveat. This is the weakest of the four, and I accept it: the
   claim it makes ("the rig does not check the header") is a claim about the
   store, which is exactly what was measured; the instrument only bounds the
   claim about macSCP's path, which this doc does not make.
4. `S3FileSystem.setObjectLockDefault`: "the RIG half is measured … (the record,
   with its control and its instrument, is in the header of
   `S3ObjectLockGatedTests`)" and "the requirement this comment rests on is
   AWS's, and it is a reading". It also keeps the right conclusion — "a tolerant
   store is a reason to keep sending the header, not to stop."

The control (the read-back `GET ?object-lock` showing
`<Mode>GOVERNANCE</Mode><Days>1</Days>`) is named at every site that reports the
200, which is what makes it a measurement rather than a status. The backlog row
says so in the branch's own terms. Nothing here claims an AWS measurement, and
nothing claims macSCP's own path was run without the header.

Cosmetic only, in `S3FileSystem.setObjectLockDefault`: two withdrawal
parentheses run together mid-line ("… had become false.) (Withdrawn, verbatim:
…"), which makes the second hard to find. Not a claim, not a finding.

## 9. A plant the new guards do not catch

VERDICT: **FOUND ONE.** M1 below.

### M1 — the `.unconfirmed` arm can be made to fabricate a default retention, and nothing goes red

The arm where NOTHING was read back is the arm whose audit call has no check on
its arguments. Plant, through `scripts/mutation-probe` against the committed
tree (`--apply` running a `perl -0pi -e` that asserts its anchor with `die
"anchor missing" unless index($_, $old) >= 0` before writing, per CLAUDE.md):

```
case .unconfirmed:
-   bucket: bucket, protection: choice, bucketDefault: nil, failure: sentence)
+   bucket: bucket, protection: choice, bucketDefault: (days: 7, mode: .compliance), failure: sentence)
```

Result, twice, at two filter widths:

```
--filter 'BucketSettingsAuditTests|CreateBucketSheetTests'
── control: 80 test(s) ran, 0 pre-existing failures
RESULT: GREEN — 80 test(s) ran and NONE of them noticed the plant.

--filter 'Audit|CreateBucket|BucketSettings'
── control: 186 test(s) ran, 0 pre-existing failures
RESULT: GREEN — 186 test(s) ran and NONE of them noticed the plant.
```

With the plant in, a create whose read-back was REFUSED writes an audit line
reading `created bucket X with versioning and Object Lock; the bucket already
had a COMPLIANCE default retention of 7 days` — a flat assertion of an
irreversible retention on a bucket about which nothing at all was established.
That is the exact harm the wave's own doc comments say the trail is protected
from ("no line claims a protection that is not there, and no line omits one
that is"), on the one arm no behavioural test reaches:
`/usr/bin/grep -n 'nconfirm' Tests/macSCPAppKitTests/BucketSettingsAuditTests.swift`
prints only lines inside the doc comments of
`createMakesOneRecordingCallPerArmItCanTake` — no case drives `create` to
`.unconfirmed` with a recorder attached. `createMakesOneRecordingCallPerArmItCanTake`
counts the recording CALLS (6) and reads none of their arguments, so it cannot
see this.

This is CLAUDE.md's "Guards that name what they watch" §3 in the usual shape: the
author's enumeration covered the arms where a value is read back, and the plant
lands on the arm where one is not. The ruling that this arm records the attempt
is the maintainer's and I do not reopen it; what is missing is a test pinning
*which* attempt it records — `protection: choice`, `bucketDefault: nil`, and the
sentence beside them.

### What I also tried, and did not catch anything

- Removing F2b's bound (`case .unknown: mayProbe = true`): RED, caught by name.
  Section 5.
- `recordBucketCreated`'s own call-site figure: the committed command
  `/usr/bin/grep -rn -o -e 'recordBucketCreated(' Sources Tests
  --include='*.swift'` prints **14** occurrences, exactly as the doc comment
  says, and its four named exclusions are the three in `AuditRecorder.swift`
  (the declaration, the copy in the command, the copy in the withdrawal) plus
  the string literal at `BucketSettingsAuditTests.swift:610`. 14 − 4 = 10 = six
  in `CreateBucketSheet.swift` + four in
  `AuditRecorderBucketSettingsTests.swift`. Reproduced.

## D1 — a plain create now reports a false alarm on a store without Object Lock

**This is the one thing in the wave I think would hurt a user.** It is a
consequence of F1c (the plain create reads back too), and it is new in these
nine commits.

`readBack` reads the lock FIRST, unconditionally, on every create the store
accepts. `S3FileSystem.hasObjectLock` is `objectLockState(ofBucket:)`, and
`S3SettingsXML.parseObjectLockState` turns a non-2xx into `.notConfigured` only
when the body's error code is exactly `ObjectLockConfigurationNotFoundError`;
anything else `throw`s through `S3FileSystem.mapErrorStatus`. So on a store whose
`GET ?object-lock` answers `NotImplemented`, `MethodNotAllowed`,
`InvalidRequest` or any other code — i.e. a store that does not implement Object
Lock at all — `hasObjectLock` throws, `readBack` returns `.unconfirmed`, and a
create that fully succeeded ends as a reported failure. Both plausible
behaviours of a non-supporting store land there, not just one: an error status
goes through `mapErrorStatus` and throws, and a gateway that IGNORES the unknown
`?object-lock` query and answers 200 with the bucket listing reaches
`parseObjectLock`, whose `leaves(of:root:"ObjectLockConfiguration")` refuses a
foreign root as `.protocolError`. The outcome:

- the sheet showing, in red, "A bucket named “X” exists now, but macSCP could
  not check whether it has the settings you chose. Open Versioning and Object
  Lock for it to see what it has, and **do not create it again**";
- an audit row flagged `isError: true` with that sentence appended;
- the name added to `takenNames`, so the same sheet will not retry it.

It happens for a PLAIN create — nothing ticked, nothing claimed — every time, on
every bucket, on such a store. Before this wave that create said "The bucket “X”
was created."

The distinction is not mine: `ObjectLockStateCache`'s own doc comment draws it
in the same subsystem — "The store's `404`
(`ObjectLockConfigurationNotFoundError`) arrives from Core as `false` and is
kept as 'no lock' … **Anything else Core throws is a failure to find out, not an
answer**". `readBack` collapses the second case into a reported failure of the
create.

Three things make me confident this is a real class and not a hypothetical. First,
the project already models it: `FakeBucketSettings`'s Object Lock calls throw
`RemoteFSError.finding(.operationNotSupported)` when no fixture is given, and
`BucketVersioningSheetTests` and `ObjectLockSheetTests` each have deliberate
cases for a store that answers that way. Second, the sibling sheet already
decided this exact question the other way, in its own fix round:
`BucketVersioningSheetTests.aLockThatCannotBeReadDoesNotCostABucketThatIsNotEnabled`
— "A lock that cannot be read changes nothing the sheet offers or says for a
bucket that is not enabled, so it must not cost the sheet its reach there." The
create sheet now does the opposite: a lock that cannot be read costs a create
that asked for no lock its entire outcome. Third, the create path reads
`settings.hasObjectLock` directly rather than through the session's
`ObjectLockStateCache` — correct for a read-back, which must not read a cache —
so it also does not inherit that type's "a failure is not cached, an answer is"
handling.

What is NOT measured, and I say so rather than gloss it: I have not seen a real
store answer `GET ?object-lock` with anything other than
`ObjectLockConfigurationNotFoundError`. The rig is RustFS 1.0.0 and supports
Object Lock, so it cannot show this, and no other store is reachable from here.
The store-side premise has the same standing as the AWS half of the Content-MD5
question — a reading, not a measurement. macSCP's own half I did measure, in
this session, with a throwaway untracked test file
(`Tests/macSCPAppKitTests/ZZReviewProbeTests.swift`, since deleted; `rm`, no
`git checkout`), driving a plain create against
`FakeBucketSettings(lock: .init(hasLock: false, hasLockError:
RemoteFSError.finding(.operationNotSupported)))`:

```
OBSERVED plain create, hasObjectLock throws .operationNotSupported:
  creates=[macSCPCore.BucketProtection.none]
  hasLockReads=["macscp-third"]
  versioningReads=[]
  isCreated=false
  canCreate=false
  sentence=A bucket named “macscp-third” exists now, but macSCP could not check
           whether it has the settings you chose. Open Versioning and Object
           Lock for it to see what it has, and do not create it again.
```

Note `versioningReads=[]`: the lock read goes first, so the create is reported
unconfirmed without the versioning read being made at all. The file was deleted
with `rm` immediately afterwards and `git status --porcelain` prints nothing.

No test in the suite covers it: `/usr/bin/grep -n 'hasLockError'
Tests/macSCPAppKitTests/CreateBucketSheetTests.swift` prints one line (710),
inside `aReadBackThatIsRefusedSaysTheSettingsCouldNotBeConfirmed`, which ticks
Object Lock. The combination "plain create, lock read unavailable" is in no case.

If the maintainer wants a shape for it, the cheapest one consistent with the rest
of the wave is to treat a lock read that fails as uninformative *for a create
that claimed no lock* — the versioning sheet's own rule — and to keep
`.unconfirmed` where a protection was actually asked for. That is a design call,
not mine to make.

## New defects introduced by the nine commits

- **D1** (above) — a plain create reports `.unconfirmed` on any store whose
  `GET ?object-lock` is not `ObjectLockConfigurationNotFoundError`. User-facing.
- **M1** (above) — the `.unconfirmed` audit arm is unguarded; a plant that makes
  it fabricate a COMPLIANCE default retention is green over 186 tests.
- **M3 — a stale count and a stale enumeration in a comment the diff does not
  touch.** `BrowserScope.isContainerListRoot`'s doc comment enumerates its
  callers ("**FOUR readers, five reads**", naming the background context menu,
  `.compareWithOtherPane`, `acceptsIncomingFiles` and
  `ComparisonRequest.panesAreComparable`) and carries a committed command whose
  figure it states: "`git grep -no isContainerListRoot -- Sources
  ':!*BrowserScope.swift' | wc -l` prints 4". Commit `6d0c87c8` added a fifth
  reader, `EmptyContainerListView.isShown`, and did not update either. The
  comment's own command, extracted from the committed text and run unrepaired
  from the worktree root —
  `git grep -no isContainerListRoot -- Sources ':!*BrowserScope.swift'` —
  prints **6** lines today, where the comment says 4. The same figure from a
  second instrument, `/usr/bin/grep -rn -o 'isContainerListRoot' Sources
  --include='*.swift' | /usr/bin/grep -v 'BrowserScope.swift' | wc -l`, is 6
  occurrences (not lines): `ComparisonRequest.swift:159` twice,
  `BrowserContextMenu.swift:168` and `:283`, and
  `EmptyContainerListView.swift:42` (a comment mention) and `:56` (the read).
  So the enumeration is one reader short and the figure is 4 where it is 6.
  This is precisely CLAUDE.md's "Comments that describe other code" rule 1 — the
  comment became wrong without appearing in the diff — and rule 2, a number
  written into a comment that a later commit moved. It is cheap to fix and it is
  in the measurement-adjacent prose the project holds itself to.

Comments the wave DID keep right, checked because the same rule applies:
`lockFinding`'s new "Two callers" (`/usr/bin/grep -rn -o 'lockFinding('
Sources --include='*.swift'` prints 3 occurrences — the declaration at `:896`
and the two calls at `:811` and `:1144`), the `BrowserPane.minimumWidth`
arithmetic in `EmptyContainerListView`'s bound comment (280 − 20 = 260), and the
`recordBucketCreated` call-site derivation (section 9).

## O1 — an UNGATED Core case went red under a full run and is green alone

Not attributable to the nine commits, and new information all the same: the unit
suite is not deterministically green at `fbc62ae8` on this machine.

On my second `swift test` (no flag, no `MACSCP_ITEST`), Core printed:

```
✘ Test resolveAcceptsABareIPv6LiteralAndRejectsABracketedOne() recorded an issue at ConnectionDiagnosticsTests.swift:128:25: Issue recorded
✘ Test run with 5090 tests in 408 suites failed after 20.817 seconds with 1 issue
```

Line 128 is `Issue.record("a bracketed literal resolved after all: \(bracketed)")`
— so `HostResolver.resolve(host: "[::1]", port: 9000, timeout: .seconds(2))`
did NOT come back `.failed` that time. Alone, three times in a row:

```
swift test --filter resolveAcceptsABareIPv6LiteralAndRejectsABracketedOne
→ ✔ Test run with 1 test in 1 suite passed after 0.014 seconds.
→ ✔ … 0.008 seconds.
→ ✔ … 0.012 seconds.
```

3 of 3 green alone at ~10 ms, 1 red in 2 full runs. The case carries a 2-second
`timeout:` against a real `getaddrinfo`, which is a wall-clock bound of exactly
the kind CLAUDE.md's "A wall-clock ceiling in a test measures the runner"
section is about — and in the very file that section cites twice. I am NOT
claiming the mechanism; I did not instrument it, and the machine was loaded
(the Docker rig up, my own `swift test` runs back to back).

Not the wave's: `git diff --name-only 97dfc236..fbc62ae8 | /usr/bin/grep -i -e
diagnos -e resolve -e network` prints nothing. But it does mean the fix report's
"Final suite, three runs in a row: `✔ Test run with 5090 tests in 408 suites
passed` (Core)" is not reproducible here as stated, and the maintainer's new
gated-suite row describes the same SHAPE — red under a full run, green alone —
one gate lower than the row's scope. Worth a line in that row or one of its own.

## Concerns

1. **The user documentation is still owed, and the wave is user-visible.**
   CLAUDE.md's "User documentation ships with the feature" binds four new
   outcome sentences on the create sheet and an entirely new screen. The fix
   report names this as a known debt it was told not to discharge
   (`/Users/noidee/_dev/noix-docs` untouched). It is the coordinator's to close
   before the branch is finished, not a defect in the diff.
2. **The read-back makes a correct create reportable as a failure** wherever a
   subresource read lags a write. The spec's anti-goal demands the read-back and
   this is its inherent price; on a store with eventual consistency on
   `?versioning` or `?object-lock`, a genuinely new and correctly configured
   bucket can land on `settingsDidNotTake` with "do not create it again" beside
   it. Unmeasured, and I am not claiming any store behaves this way — only that
   the design now has that failure mode and nothing in the tree notes it. D1 is
   the sharp, always-on instance of the same shape.
3. **The singular of the audit line's day count is untested.**
   `recordBucketCreated` renders `\(days) \(days == 1 ? "day" : "days")`; the
   only test of the clause uses 30 days, and the one case in the suite with
   `days: 1` (`aPlainCreateOntoABucketWithADefaultGetsTheRetentionSentence`)
   passes `recorder: nil`. A one-day default retention is the mildest and
   therefore the likeliest to be met. Cosmetic.
4. **`.unconfirmed` is now reachable from four different read failures** (the
   lock read, the versioning read, and the default read where the protection
   matched) and says the same sentence for all of them. That is honest — none of
   them established anything — but a person on a store that cannot answer
   `?object-lock` at all gets it every time, which is D1.
5. The nine commits' own measurement record is in good shape. Every committed
   command I extracted and ran reproduced its stated figure: four of them
   (the gated isolation run, the 40-file diff count, the Content-MD5 sweep, the
   `recordBucketCreated` count). The one stale figure in the tree is M3, in a
   comment the wave did not write.

## What I ran

- `swift build --build-tests` (no `--build-system` flag): exit 0.
- `swift test` (no flag), whole unit suite at `fbc62ae8`, twice. AppKit both
  times: `✘ Test run with 2877 tests in 241 suites failed … with 1 issue`, the
  issue being the known pre-existing `ViewTestabilitySpike.swift:202`
  (`off == on`). 2877 and 241 match the fix report's figures exactly. Core on
  the second run: `✘ Test run with 5090 tests in 408 suites failed after
  20.817 seconds with 1 issue` — see O1 below. (My first run's filter ended in
  `tail -20` and dropped the Core summary line; that is my own instrument's
  fault, not the tree's, so I re-ran it.)
- `MACSCP_ITEST=1 swift test --filter …` — the gated-suite row's own four-flag
  isolation command, extracted from `docs/BACKLOG.md` and run unrepaired. The
  rig was already up; I started and stopped nothing and named no rig bucket.
- Three mutation probes, all through `scripts/mutation-probe` against the
  committed tree, each `--apply` asserting its anchor before writing: two
  spellings of the `.unconfirmed` fabricated-default plant (GREEN at 80 and 186
  tests) and the F2b bound removal (RED, caught by name). The tree was clean
  before each and `git status --porcelain` printed nothing after each.
- One throwaway untracked test file for D1's observation, removed with `rm`.
- Four committed commands extracted from the tree's own text and re-run: the
  gated isolation run, `git diff --name-only eec041f5..HEAD -- Sources | wc -l`
  (40), the Content-MD5 sweep (4 occurrences), the `recordBucketCreated`
  call-site sweep (14 occurrences). All four reproduced their stated figures.
  A fifth, `BrowserScope.isContainerListRoot`'s, did not — that is M3.

I did not commit, amend or push; I did not launch the app or its binary; I did
not start, stop or seed the Docker rig; I dispatched no subagents.

---

Not verified.
