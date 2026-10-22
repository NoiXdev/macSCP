# Task 12, fix round 1b -- report

Base `e298c50f`. Written section by section as each finishes.

## Important 2 -- stale "an ad-hoc connect has no audit trail" comments

Status: done. Commits `4e57f9bb` (the two assigned sites) and `034ee122`
(three further sites the sweep below found; separate so it can be dropped).

Edited, each quoting the withdrawn wording verbatim (comment-only; there is no
behavioural red to observe and none is claimed):

- `SessionTab.pendingPlaintextConfirmation` doc: withdrew "an ad-hoc one, which has no audit trail to write it into (see `attachAuditRecorder`'s own doc comment)".
- `TabTeardown` audit-recorder stage: withdrew "only present for a stored session (`attachAuditRecorder` never runs for an ad-hoc connect), so this is a no-op otherwise". The recorder is absent only when the sidebar deleted the stored session under the open tab (`ContentView+Detail.swift` nils it).
- `034ee122`: `RemoteBrowserViewModel.auditSink` and `TransferQueueViewModel.auditSink` ("default nil (no logging — matches ad-hoc/unstored sessions)", "... for stored sessions") and `ContentView.auditStore` ("every stored-session tab's `AuditRecorder`").

Left alone as instructed: `TeardownStage.swift` (its "`tab.auditRecorder` is nil for an ad-hoc connect" is the same false claim; the log-line decision is the maintainer's). Borderline, not touched: `AuditLogStore.swift` header "One JSON file per stored session" (file layout; the ad-hoc log is one more file).

### Important 2 -- method (the part that is inherited)

**Why the first pass found three of five.** I cannot see what it searched. What
the tree shows is that the five claims are phrased five ways and none shares a
phrase with another: "Never called for an ad-hoc connect" (`attachAuditRecorder`
doc), "(never for an ad-hoc connect)" (`SessionTab.auditRecorder` doc), "has no
audit trail to write it into" (`SessionTab.pendingPlaintextConfirmation` doc),
"`attachAuditRecorder` never runs for an ad-hoc connect" (`TabTeardown`),
"`tab.auditRecorder` is nil for an ad-hoc connect" (`TeardownStage`). A search for
a CLAIM ("never", "no audit") finds the phrasings you thought of. A search for the
SUBJECT finds all of them.

**Pass A -- the subject: every line that names an ad-hoc / unsaved connection and
has "audit" or "recorder" within 5 lines either side.** It is a script because the
window is the point (a bare `grep` needs both words on one line, and wrapped
comments put them on different ones). Verbatim, as run:

```
#!/usr/bin/env bash
# usage: sweepA.sh <root>   (root holds Sources/ and Tests/)
cd "$1" || exit 2
find Sources Tests -name '*.swift' | sort | while read -r f; do
  awk -v F="$f" '
    { L[NR]=$0 }
    END { for (i=1;i<=NR;i++) if (tolower(L[i]) ~ /ad-hoc|ad hoc|adhoc|unsaved/) {
            h=0; for (j=i-5;j<=i+5;j++) if (j>=1 && j<=NR && tolower(L[j]) ~ /audit|recorder/) h=1
            if (h) print F ":" i ":" L[i] } }' "$f"
done
```

Run against an export of each tree (`git archive -o x.tar <rev> Sources Tests`,
untar into an empty directory, `bash sweepA.sh <dir> | wc -l`). The count is
**hit lines** (one per line; a line holding the term twice prints once), measured
with `wc -l` on the script's output, not `grep -c`:

| tree | pass A hit lines |
|---|---|
| `c355dd63^` (before the first correction round) | 51 |
| `e298c50f` (this round's base) | 64 |
| `HEAD` after this round (`31e24403`) | 74 |

The rise is not new claims: it is the withdrawn wording quoted in the corrections
(the project's own rule puts it there) and new tests that name `AdHocAudit`.

A hit line is a candidate, not a finding: each has to be READ. Read at
`c355dd63^`, the false claims in pass A are the five above plus
`RemoteBrowserViewModel.auditSink` and `TransferQueueViewModel.auditSink`
("default nil (no logging — matches ad-hoc/unstored sessions)"). That is
**seven**, not five.

**Pass B -- the claim from the other side.** A comment that says what a STORED
session has asserts the ad-hoc absence without naming it, so pass A cannot see
it. Pass B lists comment lines that name stored / saved / unstored sessions and
have a comment line mentioning "audit" or "recorder" within 3 lines
(`sweepB.sh`: the same shape, regex `stored|not saved|never saved|unstored|saved
session`, restricted to `//` lines). Hit lines: 49 at `e298c50f`, 52 at `HEAD`.
Read, it adds one false claim pass A does not contain: `ContentView.auditStore`
("every stored-session tab's `AuditRecorder`"); and one borderline that states a
file layout rather than who has a recorder: `AuditLogStore.swift` ("One JSON file
per stored session"), left untouched.

**Total:** 8 false-or-stale sites across the two passes (the five claimed, the two
Core `auditSink` docs, `ContentView.auditStore`). Fixed: 2 assigned (`4e57f9bb`) +
3 found by the sweep (`034ee122`) = 5 this round, on top of the 2 already
corrected by `c355dd63`. Left: `TeardownStage.swift`, as instructed.

**What a sweep owes the next person:**
1. Search the SUBJECT, with a window, and classify per hit, not per file.
2. Do it twice: once for the thing the claim is about (ad-hoc), once for the thing
   it is contrasted with (stored). A claim that only names the contrast is
   invisible to the first.
3. Count hit lines, say so, and expect the count to RISE after a correction round:
   every correction quotes the wording it withdraws, so the withdrawn sentence is
   in the tree on purpose. Tell those apart by "Corrected" / "used to read".
4. A sweep is evidence only if it finds what is already known: pass A at
   `c355dd63^` contains the five known sites (checked), which is its positive
   check.

**What this sweep does not cover.** `.strings` catalogues (UI text; keys like
`audit.adhoc.name` are correct), `docs/` and `.superpowers/` (dated measurement
records, not scanned), and any claim phrased with neither an ad-hoc word nor a
stored/saved word (for instance "only when a sessionID exists").

## Minor 1 -- Ruling 19: the segment filter is exhaustive; four kinds under File Ops

Status: done. Commits `faf5434a` (change) and `31e24403` (guard strengthened after
probe P3).

What changed (read back from the diff): the five-way `switch` in
`AuditLogSheet.matchesFilter` is now `AuditLogSheet.Filter.segment(of:)`, one
`switch` over every `AuditEvent.Kind` with no catch-all arm, returning the one
segment that lists the kind or `nil`; `Filter.includes(_:)` asks it
(`.all` -> true, `.errors` -> `event.isError`, the other four ->
`segment(of: kind) == self`). `Filter` went from `private` to internal so a test can
reach it. `matchesFilter` is a one-line forwarder, kept because the sort wiring guard
looks for the call. `bucketCreated`, `versioningChanged`, `corsChanged`,
`objectLockChanged` are under File Ops, with a comment at the arm saying it is
COORDINATOR RULING 19, not the brief's or the review's, reversible by moving four
names.

**What exhaustiveness reached beyond the four kinds (you asked to be told):**
exactly one thing, `plaintextConfirmed`. A switch with no catch-all has to name it.
It was in no segment before (visible under All and Errors only) and is in none now:
it is spelled `case .plaintextConfirmed: return nil` with a comment, so the gap is
visible rather than accidental. Behaviour of every other kind is unchanged
(a 14-case test pins it). It did not reach beyond the four facets: Transfers,
Terminal and Connection list what they listed. If you want `plaintextConfirmed`
placed (Connection is the obvious home), that is one more name in one arm and it
needs your ruling; I did not make it.

**Red observed** (`swift test --filter AuditLogFilterTests`, run on a first step that
moved the old logic unchanged into `Filter.includes(_:)`, so the red is behavioural):

```
✘ Test aBucketSettingsWriteIsListedUnderFileOps(kind:) recorded an issue with 1 argument kind → .bucketCreated at AuditLogFilterTests.swift:39:9: Expectation failed: listed
  (and the same for .objectLockChanged, .versioningChanged, .corsChanged)
✘ Test everyKindIsInAtMostOneKindSegmentAndTheUnplacedAreNamed() recorded an issue at AuditLogFilterTests.swift:103:9: Expectation failed: unplaced == [.plaintextConfirmed]
✘ Test theClassificationHasNoDefaultArm() recorded an issue at AuditLogFilterTests.swift:116:25: Expectation failed: lines.firstIndex { $0.contains("func segment(of") }
✘ Test aBucketSettingsWriteIsListedUnderFileOps(kind:) with 4 test cases failed after 0.001 seconds with 4 issues.
✘ Suite "Audit-log filter segments" failed after 0.018 seconds with 6 issues.
```

The third is red only because the function it scans did not exist yet; it is not
behavioural evidence. Its sensitivity is the probes below. Green after the change:
`Test run with 7 tests in 1 suite passed`.

**Probes** (`scripts/mutation-probe`, each against a committed tree; re-runnable
unedited from the repository root; every one printed its own control line first,
7 tests ran, 0 pre-existing failures):

| # | `--filter` | `--apply` | result |
|---|---|---|---|
| P1 | `AuditLogFilterTests` | `perl -0pi -e 's/case \.plaintextConfirmed:\n(\s*)return nil/default:\n$1return nil/' Sources/MacSCPAppKit/AuditLogSheet.swift` | RED, caught by `theClassificationHasNoDefaultArm()` |
| P2 | `AuditLogFilterTests` | `perl -0pi -e 's/\.newFile,\n\s*\.bucketCreated, \.versioningChanged, \.corsChanged, \.objectLockChanged:/.newFile:/; s/case \.plaintextConfirmed:/case .plaintextConfirmed, .bucketCreated, .versioningChanged, .corsChanged, .objectLockChanged:/' Sources/MacSCPAppKit/AuditLogSheet.swift` | RED, caught by `aBucketSettingsWriteIsListedUnderFileOps(kind:)` and `everyKindIsInAtMostOneKindSegmentAndTheUnplacedAreNamed()` |
| P3 (before) | `AuditLogFilterTests` | `perl -0pi -e 's/case \.plaintextConfirmed:\n(\s*)return nil/case _:\n$1return nil/' Sources/MacSCPAppKit/AuditLogSheet.swift`, against `74bb1b55` | **GREEN**: "7 test(s) ran and NONE of them noticed the plant." |
| P3 (after) | same | same, against `31e24403` | RED, caught by `theClassificationHasNoDefaultArm()` |

(In the shell the `$1` is written `\$1` inside the double-quoted `--apply`.) P3 is the
finding: the guard looked for the text `default:`, and a wildcard arm is a catch-all
that does not spell it. I planted P3 against the committed weaker guard on purpose
(I had the strengthened one in a scratch copy and restored the committed version
with `git show HEAD:<path> >` before probing, because the harness refuses a dirty
tree) and it was green. The fix: the guard now requires the body to NAME every kind,
read off `AuditEvent.Kind.allCases` (raw value = case name), so a wildcard that
replaces an arm leaves a kind unnamed. A wildcard added AFTER every kind is named
is a compiler warning, not a hole the guard owns.

## Minor 2 -- Ruling 20: `create`'s record is structural

Status: done, `74bb1b55`.

What changed (from the diff): `failure(for:bucket:protection:via:)` returns a new
private `Refusal` (`sentence`, `bucketMayExist`) instead of `Outcome`; all six
`return .failed(...)` became `return Refusal(...)`. `create` builds
`outcome = .failed(sentence:bucketMayExist:)` from it and calls
`recorder?.recordBucketCreated(...)` unconditionally in the `catch`, like the other
four sites. The `if case .failed` gate is gone; a comment at the call quotes it.

**No behavioural red exists and none is claimed.** Nothing observable moved: same
arms, same sentences, one line per refused create; `CreateBucket*` and
`BucketSettingsAuditTests` pass before and after. What can be red is the guard that
keeps the gate from coming back, new in `BucketSettingsAuditTests`:
`createRecordsItsRefusalWithoutAnOutcomeGate` (scans `create`'s body in the
comment-and-string-blanked view; negative "no `if case`" beside a positive "exactly
two `recordBucketCreated(` calls"). Observed red before the change:

```
✘ Test createRecordsItsRefusalWithoutAnOutcomeGate() recorded an issue at BucketSettingsAuditTests.swift:395:9: Expectation failed: !hasGate
✘ Test createRecordsItsRefusalWithoutAnOutcomeGate() failed after 0.020 seconds with 1 issue.
```

The positive half (`recordingCalls == 2`) passed in the same run, so the red is
the gate and not a body that was never found.

| # | `--filter` | `--apply` | result |
|---|---|---|---|
| P4 | `BucketSettingsAuditTests` | `perl -0pi -e 's/(            )(recorder\?\.recordBucketCreated\(bucket: bucket, protection: choice, failure: refusal\.sentence\))/$1if case .failed = outcome { $2 }/' Sources/MacSCPAppKit/CreateBucketSheet.swift` | RED, caught ONLY by `createRecordsItsRefusalWithoutAnOutcomeGate()` (the gate is behaviourally invisible, as designed) |
| P5 | `BucketSettingsAuditTests` | `perl -0pi -e 's/            recorder\?\.recordBucketCreated\(bucket: bucket, protection: choice, failure: refusal\.sentence\)\n//' Sources/MacSCPAppKit/CreateBucketSheet.swift` | RED, caught by `aRefusalsOwnWordsNeverReachTheTrail(operation:)`, `aRefusedOperationRecordsTheFailureAndNotASuccess(operation:)` and the guard |

(Again `$1`/`$2` are `\$1`/`\$2` inside the double-quoted `--apply`.) Not probed: a
structural plant that makes an arm of `failure(for:)` return something other than a
refusal. That is the point of the change: it no longer compiles.

## Verification and commits

Commits on top of `e298c50f`, oldest first:

- `4e57f9bb` docs(app): the two assigned stale comments (Important 2)
- `034ee122` docs: three further stale comments found by the sweep (separable; drop it and nothing else moves)
- `faf5434a` fix(app): exhaustive segment filter, four kinds under File Ops (Minor 1)
- `74bb1b55` refactor(app): create-bucket records from a bare catch (Minor 2)
- `31e24403` test(app): the segment guard also catches a wildcard arm (probe P3)

Full `swift test` at `31e24403`, no `--build-system` flag: Core run
`5085 tests in 408 suites passed`; AppKit run `2847 tests in 240 suites failed ...
with 1 issue`, the one issue being the known `ViewTestabilitySpike.swift:202:9`
(`off == on`), not mine. Targeted before that: `--filter 'Audit|CreateBucket|everyKindHasACatalogLabel'`
passed in both runs (Core 62, AppKit 101).

## Not done / not verified

- `TeardownStage.swift` still carries the false "`tab.auditRecorder` is nil for an ad-hoc
  connect" claim, as instructed. The maintainer's log-line-not-`AuditEvent` decision it
  records rests partly on that claim, so the decision's stated reason is stale; that is
  for the plan's closeout.
- `AuditLogStore.swift` "One JSON file per stored session": borderline, untouched.
- `plaintextConfirmed` is in no segment (visible under All and Errors only). It is now
  spelled out as `nil`, not placed. Needs a ruling if it should be under Connection.
- The `commentFree`/`code` blanking is what the new guards read; I did not measure
  whether it blanks a comment nested in a multi-line string (none is involved here).
- Probes P1-P5 each ran once. Sensitivity here is a count of one per plant, not a
  repetition rate.
- Pass A and pass B are regex windows, not a parse: a false claim phrased with neither
  an ad-hoc word nor a stored/saved word is outside both.
- No GUI, no app binary, no Docker rig. The File Ops segment's behaviour is tested at
  `Filter.includes`, not by driving the sheet.
- The "62 and 101" in the `74bb1b55` commit message are the Core run and the AppKit run
  of one `swift test --filter` invocation, not two lines of one run.
