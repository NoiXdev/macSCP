# Task 10, fix round 1

Commit `75bd8c50` on top of `9bc01f3a` (round BASE `7afd772f`; not amended, not
pushed). The commit message holds all 13 probes with their exact `--filter` and
`--apply`. Probes ran at `19c976e3`, the same tree before I amended my own
message.

## Important

**I-1, the warning was held by nothing.** Per sheet: (a) an identity assertion
on `modeDetailLine` by `key`, in both modes (GOVERNANCE is the positive beside
the negative; the legal-hold sheet has no line, the retention sheet does);
(b) a scan that the form region reads `model.modeDetailLine` and renders
`.text`, and that the sheet shows the form (`present` names `retentionForm` and
`legalHoldForm`; the bucket one names `form`). I ran the reviewer's two probes
verbatim, as R1 and R2, and the two on the bucket default as R3 and R4:

- R1 (COMPLIANCE's line becomes the governance note): was GREEN over 79 tests,
  now `RED — 91 test(s) ran`, caught by `choosingComplianceShowsTheWarningAndGovernanceDoesNot`.
- R2 (the warning's `Text` deleted): was GREEN, now RED, caught by
  `theRetentionFormDrawsTheLineUnderTheModeChoice`.
- R3 / R4, the same two on `BucketObjectLockSheet`: RED, caught by the bucket
  twins. R5 (GOVERNANCE's line becomes the warning) is RED too.

The reviewer expected the bucket default to have the same hole; the code there
was right and equally unheld, and is held now.

**I-2, the governance note promised an undo.** Kept the fact, removed the
promise, per your ruling, in all four catalogues. en: "Someone with the right
permission can shorten or remove a governance retention, but not from macSCP."
Old en, verbatim: "Someone with the right permission can still shorten or
remove a governance retention." (quoted in the doc comment on
`ObjectLockLines.governanceDetail` and in the commit message; de, fr, pl made the
same claim and moved with it).

**The refusal sentence: I moved the English to the three, not the three to the
English.** de ("möglicherweise"), fr ("peut-être"), pl ("być może") hedged; en
read as a flat rule. A refused `setRetention` has not been measured on the rig
and the answer does not say whether the retention or the key was the cause, so
a hedge is the honest register. en is now "The change was refused. Perhaps a
retention that is already in force cannot be shortened, or your access key is
not allowed to change it." Old en, verbatim: "The change was refused. A
retention that is already in force may not be shortened, and your access key may
not be allowed to change it." Quoted beside `retentionRefused`. A test pins
"perhaps" and the absence of the old phrase; I left de, fr, pl untouched. It
still stops short of naming a next step, which the review mentioned; I did not
add one.

## The seven Minor

1. `ObjectLockModel.load` now clears `acknowledged` (at its start, like the
   bucket model), with `aLoadTakesAnyAcknowledgementBack` saying which. Caught
   by R7.
2. The bucket default's acknowledgement names a **day**, not an instant
   (`ObjectLockDates.dayText`, same four catalogue strings), remembers the day it
   named (`acknowledgedDay`, captured when the tick is given), and
   `complianceNotAcknowledged` is active when the remembered day is not today's.
   A stale tick is taken back in `save()` where the person sees the box clear,
   and nothing is sent; a second later on the same day stands. Test
   `aTickGivenForOneDayDoesNotStandForAnother` moves an injected clock. R10-R12.
   Two consequences to know: the sentence is now less precise (a day, because a
   file added in a minute is locked until a minute later than that), and the
   per-file sheet is unchanged (its date is the instant written).
3. After the read lands, `retainUntil` starts at the later of the usual week and
   the retention already in force, **rounded up** to the minute, never down. Two
   tests (later, and earlier-so-unchanged); R8, R9. I did not also start the
   *mode* on the current retention's mode (a COMPLIANCE file offered GOVERNANCE
   is the same kind of refused default); it would start the sheet on the
   irreversible mode and I did not want to decide that unasked.
4. `FakeBucketSettings.defaultWrites` doc rewritten; old wording quoted.
5. The sweep comment corrected, old wording quoted, **sweep not widened** (the
   oracle's legal-hold arm would need a fourth input, and three loading tests
   hold the non-empty cases; the comment now names them).
6. `noOtherBackendContributesThem` asserts S3 contributes both ids and that it
   checked `(kinds - 1) * actions` pairs, and `checked > 0`.
7. `dayRange` comment separates "some ceiling is needed so the arithmetic cannot
   fail" from "36,500 is the figure macSCP chose"; old wording quoted.

Deferred as ruled, untouched: `acknowledged` as an unguarded `var`, the
bucket-creation promise in `notEnabledOnThisBucket`, the German date phrasing,
the 36,500 figure.

## Red and green

- Red: with the new tests and no production change, `swift test --filter
  ObjectLockSheetTests` stopped at two compile errors, both in
  `BucketObjectLockSheetTests.swift` (`type 'ObjectLockDates' has no member
  'dayText'`, `:93:66` and `:100:40`). With `dayText` alone added it ran and the
  behavioural reds were the six named in the commit message. The I-1 tests passed
  before any change, as they should; R1-R5 are what show they now hold it.
- Green: `swift test`, no flags: Core 5074 passed; App 2754 run, exactly one
  failure, `ViewTestabilitySpike` (`:202:9`), as before.
- 13 probes, all RED (caught), control 91 tests / 0 pre-existing failures.

## Could not do / not verified

Nothing was drawn or launched, and the rig was not contacted.
