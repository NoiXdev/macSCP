# Task 10, fix round 2

One commit on top of `75bd8c50`, not amended, not pushed (`a4cdf0ea`;
probes ran at `ceb9dafb`, my own pre-amend commit, same tree). The
commit message holds all 13 probes with their exact `--filter` and `--apply`.

## A correction to the round-1 report

Round 1's report said `ObjectLockModel.load` clears the tick "at its start, like
the bucket model". That was wrong: the per-file model cleared at the start, the
bucket model at the end of its success path. The code and the round-1 commit
message did not claim it; only the report did. Read, decided, tested: the
bucket model's failed read **did** leave a stale tick standing (nothing could be
written on it, the read's own blockers hold, but the models disagreed). Both now
clear at the start, so a failed read clears too, and
`aFailedReadTakesAnyAcknowledgementBack` says so for both. The sentence is true
now.

## NEW-2 (raised to Important)

`RunBlocker.complianceInForce`: GOVERNANCE chosen over a COMPLIANCE retention
that has not run out. It stops the attempt and says why (own sentence, four
catalogues) instead of sending it and explaining with a refusal that names two
other causes. Scope, each pinned: only while the held date is still ahead (an
expired COMPLIANCE retention is not in force); only for GOVERNANCE over COMPLIANCE
(COMPLIANCE over COMPLIANCE is the ordinary acknowledged write, GOVERNANCE over
GOVERNANCE is untouched); not for a legal hold. The starting mode is not seeded
from the file's, as ruled.

The 256-state sweep gained the held retention as a fourth input (`Held`: nothing
or COMPLIANCE in force), now 512 states, so the blocker is reachable alone for
`everyBlockerCanBeTheOnlyReasonRunIsOff` and the oracle states the rule from the
other end; a new assertion says a COMPLIANCE retention in force is never written
over with GOVERNANCE. The sweep's comment says what it varies and quotes the
round-1 wording it withdraws.

Sentence (en): "This file has a Compliance retention that is still in force. It
cannot be changed to Governance until it has run out." It rests on the
re-review's premise and S3's documented semantics, not on a measurement here.

## The refusal sentence's register

Rule flat, cause hedged, all four languages. en now: "The change was refused.
Either a retention that is already in force cannot be shortened from macSCP, or
your access key is not allowed to change it." Old en, verbatim: "The change was
refused. Perhaps a retention that is already in force cannot be shortened, or
your access key is not allowed to change it." (quoted beside `retentionRefused`
and in the commit). de, fr and pl hedged the rule too and moved with it, so I
touched them this time; the test asserts each language names the app in the rule
and the English is "either ... or" with no "perhaps". It matches the governance
note's "not from macSCP". Still no next step in the sentence.

## NEW-1

A stale tick has its own blocker (`acknowledgementStale`) and sentence ("The day
has changed since you ticked the box. Untick it and tick it again to confirm the
new day."), so the caption no longer says to tick a box that is ticked. The
round-1 `save()` cleared a stale tick on the click; that left the generic
sentence as the only explanation, so it no longer clears (old comment quoted in
the source). Two orderings, one state: redraw before the click, or none, the tick
stands and the sentence is the stale one. Because the clock is not observable, a
refused save increments `refusedSaves` and the stale blocker reads it, so the
click redraws; `aClickOnAStaleTickIsSomethingTheSheetCanSee` holds that with
`withObservationTracking` (S6 and S7 are both caught by it).

## NEW-3

`guard acknowledged != oldValue else { return }`, plus
`tickingAnAlreadyTickedBoxDoesNotRefreshTheDay` (a repeated `true` after midnight
stays stale; a real untick-and-retick is a new decision). S4.

## R3 and R4, run

Same commands as round 1, now S11 and S12 in this round's probe list, against the
bucket default: both `RED — 96 test(s) ran`, caught by
`choosingComplianceShowsTheWarningAndGovernanceDoesNot` (S11) and
`theFormDrawsTheLineUnderTheModeChoice` (S12). The bucket sheet's two guards
are measured.

## Red and green

- Red: new tests, no production change: 7 compile errors, all in
  `BucketObjectLockSheetTests.swift` (`staleLine`, `refusedSaves`,
  `acknowledgementStale` not found); `ObjectLockSheetTests.swift` reported none.
  No behavioural test ran red before the change and none is claimed to have;
  S1-S13 are the evidence that each new guard holds.
- Green: `swift test`, no flags: Core 5074 passed; App 2759 run (2754 + 5 new),
  exactly one failure, `ViewTestabilitySpike` (`:202:9`), as before.
- 13 probes, all RED (caught), control 96 tests / 0 pre-existing failures.

## Not done / not verified

Nothing drawn or launched; the rig not contacted. Deferred and untouched as
ruled: `acknowledged`'s writers (only the one-line guard is in), the
bucket-creation promise, the German date phrasing, the 36,500 figure.
