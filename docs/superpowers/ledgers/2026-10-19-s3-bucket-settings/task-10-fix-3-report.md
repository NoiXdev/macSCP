# Task 10, fix round 3 (the last)

One commit on top of `a4cdf0ea`, not amended, not pushed. The commit message
holds the 8 probes with their exact `--filter` and `--apply`; they ran at
`737f4ff1`, my own pre-amend commit, same tree.

## NEW-6, the one that mattered

The per-file sheet had the silent click: `dateNotInFuture` reads the unobservable
clock and `run()` was a bare `guard canRun else { return }`. Fixed the way NEW-1
was: a refused run increments `refusedRuns`, and the date blocker reads it.
`dateHasPassed` puts `_ = refusedRuns` **above** the condition, never folded in.
The sentence now says the date has passed. Old en, verbatim: "Choose a date and
time that is still ahead." Now: "The date and time you chose have passed. Choose a
date and time that is still ahead." de, fr and pl moved with it (all four
catalogues; the test asserts each language says it has passed).

- `aDateThatPassesWhileTheSheetIsOpenIsSaidSoOnTheClick` holds the link with
  `withObservationTracking` on a body drawn while the date was ahead (`canRun`
  true), moves an injected clock past the date, clicks, and asserts nothing was
  written, the tracking fired, and the explanation is the date sentence; the
  positive beside it is a later date whose click writes.
- Probes: T1 counter not incremented: RED. T2 the read folded into a
  short-circuiting `&&` (`... && refusedRuns >= 0`), the plant most likely to
  pass: **RED**, caught by that test alone.

## The three thinner guards

- **NEW-5.** The refusal test now asserts, per language, the connective
  (either / entweder / soit / albo) present and that language's hedge words for
  the rule absent, with both tables counted against the locales. T6 (the German
  string put back to "Möglicherweise lässt sich ...") is RED.
- **Starting mode.** `aLoadOverAComplianceFileLeavesTheModeWhereItWas`: after a
  load over a COMPLIANCE file `mode == .governance` and the only blocker is
  `complianceInForce`. T5 (seeding added) is RED.
- **Per-file jargon scan** now reads every line, counted. **It found nothing**:
  every line was already clean; no sentence and no scan was adjusted. T8 plants
  "header" into a per-file line and shows it can find something.

## NEW-4

`refusedSaves`' comment now says "In production code only the stale blocker
reads it; see there. (A test reads it too.)". Old wording, verbatim: "How many
saves were refused. Only the stale blocker reads it; see there."

## S4 and S7, run

Both reproduce, as T3 and T4: T3 (the `oldValue` guard on `acknowledged`
removed) RED, caught by `tickingAnAlreadyTickedBoxDoesNotRefreshTheDay`; T4
(`_ = refusedSaves` removed) RED, caught by `aClickOnAStaleTickIsSomethingTheSheetCanSee`.

## Red and green

- Red: new tests, no production change: 2 compile errors in
  `ObjectLockSheetTests.swift` (no member `refusedRuns`, `:422:23`, `:425:23`).
  With the property alone added: `aDateThatPassesWhileTheSheetIsOpenIsSaidSoOnTheClick`,
  `theDateSentenceSaysTheDateHasPassed` (4x), `onlyARefusedRunIsCounted` failed.
  The mode, per-language register and jargon tests passed before any change, as
  they should: the code was right and unheld.
- Green: `swift test`, no flags: Core 5074 passed; App 2764 run (2759 + 5 new),
  exactly one failure, `ViewTestabilitySpike` (`:202:9`), as before.
- 8 probes, all RED (caught), control 101 tests / 0 pre-existing failures.

## Not done / not verified

Nothing drawn or launched; the rig not contacted. The expiry boundary of
`complianceInForce` still rests on one arm of one test (the re-review's P3
observation); not widened, as it declined to open a finding. Deferred and
untouched: `acknowledged`'s writers beyond the one-line guard, the
bucket-creation promise, the German date phrasing, the 36,500 figure.
