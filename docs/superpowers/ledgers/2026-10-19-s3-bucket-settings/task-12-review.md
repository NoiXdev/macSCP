# Task 12 review: the audit trail

Reviewer: task reviewer, 2026-10-22. Worktree
`/Users/noidee/macSCP/.claude/worktrees/diff-view`, head `ee0bbf0a`, tree clean
at the start and at the end of this review.

Inputs read: `task-12-brief.md`, `task-12-report.md`,
`review-341434f8..ee0bbf0a.diff`, and the tree at `ee0bbf0a`.

---

## Verdict 1 — spec compliance: **PASS**

Every requirement the brief names is in the tree, and the one the brief exists
for — a COMPLIANCE retention leaving a line that names its mode and its date —
is held and probed.

| Brief requirement | Where | Verified |
|---|---|---|
| `AuditEvent.Kind` gains `bucketCreated`, `versioningChanged`, `corsChanged`, `objectLockChanged` | `Sources/macSCPCore/Sessions/AuditEvent.swift` | present, four cases, doc'd |
| `AuditRecorder` gains a method per kind | `Sources/macSCPCore/Sessions/AuditRecorder.swift` | `recordBucketCreated`, `recordVersioningChanged`, `recordCORSChanged`, `recordObjectLockChanged` + `ObjectLockChange` |
| Catalogues ×4 | `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings` | four keys in each of the four; no hardcoded display string anywhere in the diff |
| **The App side — the five apply sites** (added to the brief 2026-10-21 because the task otherwise had no caller) | `CreateBucketSheet.swift`, `BucketVersioningSheet.swift`, `BucketCORSSheet.swift`, `ObjectLockSheet.swift`, `BucketObjectLockSheet.swift` | all five record, success and refusal |
| `everyKindHasACatalogLabel` covers the new kinds | `Tests/macSCPAppKitTests/SnippetAuditWiringGuardTests.swift` | widened to `allCases × {en,de,fr,pl}`, 19 cases; key derived as `"audit.kind.\(kind.rawValue)"`, not spelled — matches `AuditLogSorting.swift:24` |
| `theFourNewKindsAreDeclaredWithTheSpellingsTheCatalogueUses` | `Tests/macSCPCoreTests/AuditRecorderBucketSettingsTests.swift` | present |
| `eachOperationRecordsExactlyOneEventOfItsOwnKind`, parameterised over the five | `Tests/macSCPAppKitTests/BucketSettingsAuditTests.swift` | table of six rows for five methods (`ObjectLockModel.run` serves two), driven through each sheet's own apply path |
| `aRefusedOperationRecordsTheFailureAndNotASuccess` | both test targets | present |
| `anObjectLockLineNamesWhichOfTheThreeOperationsItWas` | both test targets | present; the App case asserts `COMPLIANCE`, `2027-01-15T08:00:00Z` and `b1/reports/q3.pdf` in the retention line and that the other two lines do not borrow the word `COMPLIANCE` |
| "prefer a recorder a new apply path cannot compile without, over a scan" | five apply methods, five sheet inits, five `ContentView.*SheetItem` memberwise inits | `recorder: AuditRecorder?`, required, no default, in all fifteen places |
| "No detail may be the store's words or carry a secret" | `aRefusalsOwnWordsNeverReachTheTrail` | held — see below |
| The `#expect`-prints-source-text rule | `BucketSettingsAuditTests.storeWords` | followed: named constant, `Bool` computed before the expectation (`#expect(leaked == false)`) |

**Brief Step 2's command, run as written:** `swift test --filter
"Audit|everyKindHasACatalogLabel"` → `50 tests in 10 suites passed` and
`43 tests in 5 suites passed`, no failures. (The report ran narrower filters;
the brief's own command passes too.)

**The secret-leak constraint, checked on both exits.** Every `failure:` value
that reaches an event is one of four App-layer mappers
(`CreateBucketModel.refusalSentence`, `BucketCORSModel.message(for:applying:)`,
`BucketVersioningModel.message(for:applying:)`,
`ObjectLockLines.message(for:during:)`). All four resolve to either a fixed
`CatalogueLine` or `RemoteFSFinding.message`, and `RemoteFSFinding` carries no
foreign text by construction — pinned by its own
`RemoteFSFindingTests.noFindingCarriesForeignText`. No `error`/`reason` text is
interpolated on any of the ten recording call sites. The `detail` strings carry
only bucket, key, versioning state, retention mode, day count, rule count and a
UTC date — all macSCP's own values. On the second exit (the test's own failure
message), `BucketSettingsAuditTests` keeps the canary in
`private static let storeWords` and computes `leaked` before the expectation;
the one place an `errorMessage` is compared directly
(`#expect(events.first?.errorMessage == nil)`) is in the **success** path, where
it is `nil` by construction.

**Figures in the committed text, extracted and re-run.** Every command the
commit messages and the report commit beside a figure reproduces its figure, in
the form it is committed, under both the session `grep` (ugrep) and
`/usr/bin/grep`:

```
git show c355dd63 -- Tests | grep '^+' | grep -o ', recorder: nil)' | wc -l   → 68
git show c355dd63 -- Tests | grep '^+' | grep -o 'recorder: nil,$' | wc -l    → 37
```

and the 37 split as claimed: `BoundedViewRegistry.swift` 35,
`CreateBucketSheetTests.swift` 1, `BucketCORSSheetTests.swift` 1. The report's
alternative spelling of the second command
(`grep -E -o 'Sheet\(recorder: nil|^\+ *recorder: nil,$'`) also prints 37.
`/usr/bin/grep -c '^ *echo "RESULT:' scripts/mutation-probe` prints 9, as that
script's header says. The Core test's own date derivation, run in the form it
is committed —
`python3 -c "import datetime; print(datetime.datetime.utcfromtimestamp(1_800_000_000).isoformat())"`
— prints `2027-01-15T08:00:00`, matching `someDateText`.

Claim 3 of the controller's list (the 69→68 / 40→37 correction) is therefore
**verified**: the figures are right, the commands run unedited, `c355dd63` is
not rewritten, and `ee0bbf0a` quotes the withdrawn wording verbatim
("69 test call sites and 40 sheet constructions gained `recorder: nil` for it.").

**Project constraints, checked:** no `syncShutdownGracefully()`,
`futureResult.wait()`, `DispatchSemaphore`, `.wait()` or `sleep(` on any added
test line; no `elapsed`/clock ceiling anywhere in the diff; every added Swift
line is English (the only non-ASCII characters added to source are two em
dashes in English prose); no hardcoded display string — the four labels go
through `L10n` via `AuditLogSorting`'s derived key.

---

## Verdict 2 — task quality: **PASS with findings** (two Important, three Minor)

The task does the hard part well. The recorder is required with no default in
all fifteen places a decision could be skipped, so the "rule with no caller"
shape this branch keeps producing cannot recur here without a compile error;
the one place the compiler cannot help (the *value* passed) is covered by two
source scans whose sensitivity I measured myself. The three greens the
implementer found in its own probes were real findings, correctly diagnosed,
and the fixes are fixes — not merely probe-reddening. Nothing leaks.

The findings are about what the tests do **not** read, and about an enumeration
in the report that is short by two.

### What I verified by running it

**The implementer's claim 2 — the three green probes and their fix —
reproduces.** I re-ran all three from the committed `--filter`/`--apply` text
in `ee0bbf0a`'s message, extracted rather than retyped, through
`scripts/mutation-probe` on the clean committed tree at `ee0bbf0a`:

| probe | outcome I observed |
|---|---|
| P4 CORS success records 0 rules | control 10 ran, 0 pre-existing failures → **RED**, caught by `eachOperationRecordsExactlyOneEventOfItsOwnKind(operation:)` |
| P6 legal hold recorded inverted | control 10 → **RED**, same test |
| P9 per-file sheet built with `recorder: nil` | control 10 → **RED**, caught by `everySheetIsBuiltWithItsItemsRecorder()` |

And the fixes are structural, not probe-shaped:

- The table test now compares `detail.hasPrefix(operation.detailPrefix)`
  against a per-row expected prefix carrying the bucket, the key, the
  state/mode, the count. That is a **positive** check on the value, so it
  cannot go stale in silence; `theTableCoversEveryNewKind` is its positive
  control and is a set **equality** (not a superset), so a row that quietly
  claimed an old kind fails it.
- `firstUse(of:in:)` is a genuine identifier-boundary match, not a second
  spelling: it searches for the name followed by `(` and rejects a hit whose
  preceding character is a letter, digit or underscore. `ObjectLockSheet(`
  inside `BucketObjectLockSheet(` is rejected on the `t`, and the trailing
  paren prevents the mirror error (`ObjectLockSheetItem(` matching for
  `ObjectLockSheet`). The collision is **gone, not moved**: confirmed
  empirically by the P9 re-run above, and the one theoretical hole left — a
  comment containing the constructor text above the real call — would move the
  120-character window off `recorder: item.recorder` and turn the guard
  **red**, not green, so the project's "scanners read comments too" failure
  mode cannot apply here in the silent direction.

**The implementer's claim 4 — the two wiring scans had no observed red, their
only evidence is the probes — I strengthened.** The report concedes "Not
probed: the dispatcher arms other than the per-file one and the sheet builders
individually". I planted two of the arms it did not:

| my probe | plant | outcome |
|---|---|---|
| N1 | CORS **dispatcher** arm in `ContentView+MenuActions.swift`: the tab's recorder replaced with `nil` | control 10 ran, 0 pre-existing → **RED**, `everySheetItemIsBuiltWithTheTabsRecorder()` |
| N2 | versioning **sheet builder** in `ContentView+Sheets.swift`: the item's recorder replaced with `nil` | control 10 → **RED**, `everySheetIsBuiltWithItsItemsRecorder()` |

Both scans loop over all five names with a `#require` anchor ("is built
nowhere") beside the positive `contains`, so the loop body is now measured in
both scans and the remaining arms differ only in which identifier is passed.
Claim 4 is adequately backed.

**Claim 1 — the ad-hoc premise.** Verified independently:
`ContentView.swift:2158` passes
`sessionID: AdHocAudit.logSessionID(storedID: storedSession?.id)` to
`attachAuditRecorder`, which unconditionally sets `tab.auditRecorder` and
writes `recordConnected` **and** the `plaintextConfirmed` row. So an ad-hoc
connect does get a recorder, and the brief's Ruling-15 premise was indeed
false. The one real `nil` is `ContentView+Detail.swift:71` (`onDelete`), which
is what `withNoRecorderTheWriteStillGoesThroughAndNothingIsRecorded` pins.
The only write routes to the five operations are the five apply methods — a
recursive search of `Sources/MacSCPAppKit/` and `Sources/macSCPCLI` for
`setCORS(`, `setVersioning(`, `setObjectLockDefault(`, `setRetention(`,
`setLegalHold(` and `createBucket(` returns nothing outside the five sheet
files. No seam without a contributor.

**Guard paths.** Every pre-request refusal (`CreateBucketModel.canCreate`,
`BucketVersioningModel.offeredStates`, `BucketCORSModel.canSave`,
`ObjectLockModel.canRun`, `BucketObjectLockModel.canSave`) returns above the
first recording call, so "a click the sheet refuses records nothing" is
structural, not a test's claim. `BucketCORSModel.save`'s read-back failure sets
no `saveFailure`, so the trail and the sheet cannot disagree there.

---

## Findings

### Important 1 — the refusal path's `detail` is asserted by nothing, and a refused COMPLIANCE retention can be recorded as GOVERNANCE

`aRefusedOperationRecordsTheFailureAndNotASuccess` asserts `events.count == 1`,
the kind, `isError == true` and a non-empty `errorMessage`. It does **not**
assert the `detail`. `eachOperationRecordsExactlyOneEventOfItsOwnKind` — the
one App test that reads `detail`, via `detailPrefix` — only ever drives the
**success** path, and so does
`anObjectLockLineNamesWhichOfTheThreeOperationsItWas`. On the refusal path all
six rows may therefore record any `detail` at all.

Measured, not argued. Two plants, both through `scripts/mutation-probe` on the
clean tree at `ee0bbf0a`, filter `ObjectLock|Audit` (control **245 tests ran,
0 pre-existing failures** both times). Each `--apply` is a `perl -0pi -e`
substitution in `Sources/MacSCPAppKit/ObjectLockSheet.swift`, on the
`failure: applyFailure` arm only:

- **N3** — the refused retention's mode forced to `.governance`
  (`.retention(written, …)` replaced by
  `.retention(ObjectRetention(mode: .governance, retainUntil: written.retainUntil), …)`):
  `RESULT: GREEN — 245 test(s) ran and NONE of them noticed the plant.`
- **N4** — the refused legal hold inverted (`.legalHold(wanted, …)` replaced by
  `.legalHold(!wanted, …)`):
  `RESULT: GREEN — 245 test(s) ran and NONE of them noticed the plant.`

N4 is the exact mirror of the implementer's own **P6**, which is RED on the
success path. The success half of each property is guarded; the failure half is
not, and nothing in the task says that was a decision.

The state that produces the wrong behaviour: the user opens the per-file Object
Lock sheet, selects **COMPLIANCE**, sets a retain-until date, ticks the
acknowledgement, clicks Apply, and the store refuses (missing
`s3:PutObjectRetention`, a bucket without Object Lock, a 403). Under N3's
defect the audit line reads `retention of b1/… set to GOVERNANCE until …` with
`isError: true`. The failed attempt at the one irreversible write in the
product is recorded as an attempt at the reversible one, and no test can tell.

Smallest fix: assert the detail in
`aRefusedOperationRecordsTheFailureAndNotASuccess` as well. The refused line
carries the same text as the success line — Core's
`AuditRecorderBucketSettingsTests.aRefusedOperationRecordsTheFailureAndNotASuccess`
already pins exactly that property with
`#expect(events.first?.detail == "created bucket b1")` — so
`operation.detailPrefix` can be reused unchanged.

### Important 2 — the report's enumeration of stale ad-hoc comments is short by two, and one of the misses now cites the comment this diff corrected

The report (Ruling 15) names exactly three stale claims —
`SessionTab.auditRecorder`, `ContentView.attachAuditRecorder`, and
`TeardownStage.swift` — corrects two and leaves the third on purpose. There are
**five**. Derivation: a recursive, case-insensitive search of `Sources/` and
`Tests/` for `ad-hoc`/`adhoc` restricted to `*.swift`, filtered to lines also
mentioning `recorder`, `audit trail`, `no audit` or `stored session`, returns 24
lines; two of them carry live false claims that the report does not mention:

1. **`Sources/MacSCPAppKit/SessionTab.swift:144`**, on
   `pendingPlaintextConfirmation`: "… even an ad-hoc one, **which has no audit
   trail to write it into** (see `attachAuditRecorder`'s own doc comment) …".
   False — `attachAuditRecorder` writes the `plaintextConfirmed` row
   unconditionally, for an ad-hoc connect too (`ContentView+Lifecycle.swift`,
   `if tab.pendingPlaintextConfirmation { recorder.recordAction(…) }`) — and it
   cites as its authority the very doc comment `c355dd63` rewrote to say the
   opposite. It sits in the **same file**, 104 lines above, as one of the two
   comments the task did correct.
2. **`Sources/MacSCPAppKit/TabTeardown.swift:194`**: "only present for a stored
   session (**`attachAuditRecorder` never runs for an ad-hoc connect**), so
   this is a no-op otherwise." Flatly false, and it names `attachAuditRecorder`
   by symbol. The code it sits on is correct — the `if let recorder` block now
   runs for ad-hoc connects too, which is what M31 wants; only the comment
   lies.

This is the project's "Comments that describe other code" rule twice over — a
semantic change means searching for comments that name those callers
*including in files the diff does not touch* — and a report's enumeration is a
claim about the rest of the project that has to be counted as it is written. It
also matters for the one decision the report escalates: it asks the maintainer
to re-read `TeardownStage.swift`'s decision because "one of its two reasons is
wrong". The same wrong reason sits in two more places, so that re-read is
bigger than the report says.

### Minor 1 — the four new kinds reach no filter facet, and nothing forced that decision

`AuditLogSheet.matchesFilter` (`Sources/MacSCPAppKit/AuditLogSheet.swift:250`)
switches per facet with `default: return false` in each arm, so
`bucketCreated` / `versioningChanged` / `corsChanged` / `objectLockChanged`
appear only under **All** and **Errors**. Input that shows it: set a COMPLIANCE
retention successfully, open the audit log, choose **File Ops** (or Transfers,
Terminal, Connection) — the line is absent from all four.

The report discloses this, which is why it is Minor rather than Important. What
makes it worth writing down is the asymmetry: the same commit extended
`ConnectionHistory.rows` with an **exhaustive** switch precisely so that "a
kind added later has to be classified here instead of being left to a
`default`", and then left the sheet's four facet `default:` arms to absorb the
four new kinds in silence. Whatever the maintainer decides about a "Bucket
settings" facet, those `default:` arms are where the next kind will go
unclassified too.

### Minor 2 — `CreateBucketModel.create`'s failure recording is conditional on a pattern that is currently total

```swift
outcome = await failure(for: error, bucket: bucket, protection: choice, via: settings)
if case .failed(let sentence, _) = outcome {
    recorder?.recordBucketCreated(bucket: bucket, protection: choice, failure: sentence)
}
```

`failure(for:bucket:protection:via:)` returns `.failed` on every one of its
five paths today, so the `if case` always fires. But it is the one recording
site in the task that can silently record **nothing** rather than fail to
compile: a later arm returning `.created` or a new `.exists` (the function
already calls `settings.versioning(ofBucket:)` and could reasonably decide the
bucket is there) drops the refusal line, and no test would notice — the refusal
tests all drive the `.failed` path. The other four apply methods record from a
`catch` with no such gate. An `else { assertionFailure(…) }`, or recording from
the `catch` with `Self.refusalSentence(for: error)` and letting `failure(for:)`
decide only the *outcome*, removes the gap.

### Minor 3 — `theTableCoversEveryNewKind` pins the kinds but not the row count

It asserts the set of kinds is exactly the four, and that three rows carry
`.objectLockChanged`. It does not assert `operations.count == 6`, so a
duplicated non-lock row — two "create a bucket" rows, one correct and one not —
would pass it while every parameterised test below ran the bogus case as if it
were a sixth operation. One more line (`#expect(Self.operations.count == 6)`)
closes it. Named because this table is the positive control for five other
tests.

---

## Could not check

- **Nothing was drawn.** No GUI run, no app binary, no Docker rig — same as the
  implementer. The four new rows have not been *seen* in the audit sheet; I
  verified only that the label key is derived the way the sheet resolves it
  (`AuditLogSorting.swift:24` builds `"audit.kind.\(kind.rawValue)"`, and the
  widened guard derives the identical key from `Kind.allCases`).
- **The de / fr / pl wording** is not reviewed by a native reader. I confirmed
  only that all four keys exist in all four catalogues, that the terms match
  the ones those catalogues already use for the same features, and that no
  second-person address appears, so the German `du` rule is not engaged here.
- **"Recorded before the read-back, so nothing after can lose it"** remains
  unfalsifiable with the current fakes, as the report says: `FakeBucketSettings`
  never throws or cancels on read-back. I did not build a fake that does.
- **The capture edge of Ruling 17** — a sheet holding a recorder for a stored
  session deleted from another window, recreating the log as an orphan — I read
  but did not exercise; it needs two windows and a live sidebar delete. The
  report's reading matches the code I read. It is written up, not fixed, and
  belongs in the closeout as a backlog row.
- **User documentation** (`noix-docs`) is untouched. Four new audit-log row
  labels are user-visible, so the project's docs rule makes this a closeout
  item. Outside this task's scope; flagged so it is not lost.
- `ViewTestabilitySpike` at `:202` is the known pre-existing failure and is
  counted nowhere above; every `mutation-probe` control run in this review
  reported **0 pre-existing failures** in its filtered scope.

Tree verified clean after the last probe.
