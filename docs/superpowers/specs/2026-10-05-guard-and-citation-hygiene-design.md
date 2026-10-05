# Guard and citation hygiene — design

**Date:** 2026-10-05. **Base:** `develop` at `35664708`.
**Branch:** `guard-and-citation-hygiene`.

Three rows of `docs/BACKLOG.md` that the file's own "If you don't know where
to start" section names as its three candidates, plus the consequence of
closing them: that section then names three defects this same file records
as fixed.

All three are hygiene on the measurement record and on the guards that
protect it. None changes what the app does, so no user documentation is
owed (CLAUDE.md, "User documentation ships with the feature" — the rule
binds user-visible change, and there is none here).

## What was measured before designing

Every claim the three rows make was re-run at `35664708` on 2026-10-05
rather than read out of the row. Three results changed the design:

1. **Row 147's three findings all hold**, at the exact lines it cites:
   `PaneVisibilityOwnershipGuardTests.swift:86` reads `SourceCorpus.text(of:)`,
   `:81` filters `$0.lastPathComponent != "SessionTab.swift"`, and
   `CLITunnelStartTests.swift:642` — inside `CLISourceWalk.init(directory:)`
   — reads `SourceCorpus.children(of:)`.
2. **Row 147's one citation of a sibling is stale**: it names the
   `files(under:)` precedent at `CLISessionsCommandGuardTests.swift:408`; it
   is at `:414`, inside
   `everySessionTargetCommandCarriesTheCompletion`. The row is to be
   corrected with the rest.
3. **Row 285's own replacement line numbers have already gone stale.** It
   gives the nine S3 endpoint sites as `:1064`, `:1069`, `:1380`, `:1387`,
   `:1397`, `:1496`, `:1502`, `:1511`, `:1555`, measured at `2428a642`. At
   `35664708`:

   ```
   grep -n 'S3EndpointReason\.' Sources/macSCPCore/S3/S3FileSystem.swift
   ```

   prints `:1064`, `:1069`, `:1384`, `:1391`, `:1401`, `:1500`, `:1506`,
   `:1515`, `:1559` — **seven of the nine moved by four lines in a week**.
   A correction that writes nine fresh numbers would be stale again before
   anyone read it.

Finding 3 is the design's pivot: Part C replaces enumerated line numbers
with a **re-runnable command plus the symbol name**, not with fresh numbers.
That is CLAUDE.md's own corollary ("prefer the symbol to the line number")
applied to the rows that most need it, and the command above is itself the
evidence for why.

## Part A — three guard repairs (row 147)

One commit. Three changes, each a few words, each proven by a planted
violation measured red and green. The suite's own doc comment already
carries a measurement in this form from 2026-09-27 ("green 3 of 3 against
the flat listing and red 3 of 3 against this walk"); these join it.

### A1 — the guard reads raw text where every sibling reads code

`PaneVisibilityOwnershipGuardTests.onlySessionTabReadsShowsFilesOffTheSession`
reads `SourceCorpus.text(of: file)` and scans line by line. A doc comment or
a string literal spelling `session.showsFiles` is therefore reported as an
offender — CLAUDE.md, "Source-scanning guards read comments too". `a22658df`
widened the walk from 116 to 119 files without touching the read, so the
blast radius grew.

**Change:** `text(of:)` → `commentFree(of:)` (comments blanked, string
literals kept). `SourceCorpus` guarantees every view is exactly as long in
`Character`s as the text it came from — `lengthCheckedView` refuses
otherwise — so the line numbering the offender message reports is unchanged.

**Corrected 2026-10-05, fix round 1.** This section first read "`text(of:)` →
`code(of:)` (comments *and* string literals blanked)" and "`commentFree(of:)`
is the wrong choice here: a string literal spelling the property is a false
positive too, and only `code(of:)` blanks those." Both are withdrawn. This
guard is a negative check, and `SwiftSource.blankingCommentsAndStrings`
documents that "a negative one must be read as 'not present outside a
literal'", because an interpolated expression is blanked with the literal
carrying it. Measured: a planted `"\(session.showsFiles)"` was green 3 of 3
against `code(of:)` (the false negative) and red 3 of 3 against
`commentFree(of:)`. The price is the one the withdrawn sentence named: a
plain string literal spelling the property is still flagged (measured red
3 of 3).

**Probe:** plant a doc comment line reading `/// if session.showsFiles {`
in an App source file that is not `SessionTab.swift`. Red before the change
(the comment is named as an offender), green after. Measured both ways,
repeated to a count, and the count written into the suite.

### A2 — the exemption is a bare file name

**Struck 2026-10-05, after Task 1's first run.** The premise below, that "a
`SessionTab.swift` in any subdirectory would be silently exempted", describes
a tree that cannot be built: with `--build-system native` SwiftPM maps two
files of one name in one target to one object path and fails with `couldn't
build .../MacSCPAppKit.build/SessionTab.swift.o because of multiple
producers`. The only reachable case where the two spellings differ is the
owner moving into a subdirectory, where the bare name keeps exempting it
correctly and a relative path would go red for no violation. The maintainer
struck the change; the text below is kept as written and is not the plan.

`:81` exempts `$0.lastPathComponent != "SessionTab.swift"`. Since the walk
descends (`files(under:)`, widened 2026-09-27), a `SessionTab.swift` in any
subdirectory would be silently exempted from the only negative this suite
exists for. `TabRegistrationTests.relativePath(of:)` solved exactly this with a
relative path, and *this same suite* already carries the identical helper,
`PaneVisibilityOwnershipGuardTests.relativePath(of:)`.

**Change:** `.filter { Self.relativePath(of: $0) != "SessionTab.swift" }`.
`SessionTab.swift` sits directly in `Sources/MacSCPAppKit` today (verified
2026-10-05, `find Sources -name SessionTab.swift` returns exactly that one
path), so the exemption still exempts the file it names and nothing else.

**Probe:** plant `Sources/MacSCPAppKit/Presentation/SessionTab.swift`
containing a `session.showsFiles` read. Green before the change — the bare
name exempts it, which is the defect — and red after. This is the inverse
direction from A1: the probe proves the guard *starts* catching something.

### A3 — the last flat whole-directory reader

`CLISourceWalk.init(directory:)`, in `CLITunnelStartTests.swift`, reads
`SourceCorpus.children(of:)`, which by construction does not descend. The
walk feeds `derivedBuilder()`, whose `#expect(builders.count == 1)` would
stay green at 1 if a second function returning `HostKeyDecider` appeared
under a future `Sources/MacSCPCLI/<subdir>/`. The sibling
`CLISessionsCommandGuardTests.everySessionTargetCommandCarriesTheCompletion`
chose `files(under:)` for this reason and says so in a comment.

`Sources/MacSCPCLI` is flat today, so this is latent, and the change is
behaviour-preserving at HEAD.

**Change:** `children(of:)` → `files(under:)`.

**Probe:** plant `Sources/MacSCPCLI/<subdir>/` with a second
`-> HostKeyDecider` builder reachable from `LsCommand.swift`. Green before
(the count stays 1), red after.

### What the probes are for, and what they are not

CLAUDE.md: "Mutation testing verifies a guard's sensitivity, never its
scope", and "a probe that never ran proves nothing either way" —
`scripts/mutation-probe` reports `BUILD FAILED` as its own outcome for
exactly this reason. Each probe here answers one question: does this change
move the guard from not-catching to catching (A2, A3) or from
false-positive to clean (A1)? Nothing here claims the guards are now
complete.

Every probe is reverted by `git restore --staged`-free means: the planted
files are **untracked**, so they are removed with `rm`, and no tracked file
is restored from the index. CLAUDE.md records why that matters
(`git checkout -- <file>` takes uncommitted edits with it); `git status
--porcelain` is read back after each revert and must show only the intended
edits.

## Part B — a comment that counted three where four decide (row 148)

The doc comment on `ConnectionDiagnostics.outcome(forUnanswered:)`
(`Sources/macSCPCore/Diagnostics/ConnectionDiagnostics+Jump.swift`) says the
mapping is "Spelled ONCE, and read from three places … so the three cannot
come to disagree about what a probe that never began says to a reader".

The three calls are right. But `InternetSpeedProbe.swift` decides the same
question independently: it maps `.unanswered(.neverBegan)` to
`DiagnosticReason.probeNotStarted`, and maps that back to `.notStarted` by
comparing against the symbol. The sentence therefore claims a property
("the three cannot come to disagree") over a set it did not count.

**Decision taken by the maintainer, 2026-10-05:** name the fourth site
rather than drop the count or restructure the code. The count is
*countable* here — unlike the 412 sentence of 2026-10-02, which enumerated
causes nothing could enumerate — and CLAUDE.md's rule is that a number in a
comment is counted in the moment it is written, not that numbers are
forbidden. Making `InternetSpeedProbe` call `outcome(forUnanswered:)` was
considered and rejected for this pass: it is a code change on a path this
row never measured, and it would need its own test.

**Change:** the comment names four deciders — the three calls and
`InternetSpeedProbe` — and says what distinguishes the fourth: it compares
the symbol rather than carrying a second copy of the text, which is why the
disagreement the sentence worries about cannot happen through it either.
No code changes.

**Verification:** `grep -rn "outcome(forUnanswered" Sources/` is re-run
*after* the comment is written (CLAUDE.md: "run it again after writing the
sentence" — the sentence can change the answer, and this comment spells the
symbol). The new comment must not add a match that the count does not
expect; if it does, the comment is reworded, not the count.

## Part C — six rows re-derived (row 285)

Six rows of `docs/BACKLOG.md`, each re-derived at `35664708` rather than
adjusted. Row 285 names four and points at two more:

| Row | What it cites today | What it should cite |
|---|---|---|
| Diagnostics: error text as a leak route | nine `S3FileSystem.swift` line numbers measured at an older head, plus four English sentences quoted by hand | the `grep` above, and the four `S3EndpointReason` constants by name |
| S3 `delete(path:)` on a directory is a silent no-op | `delete(path:)` at `:387-395`, `RootMode.resolve(path:)` at `:76-92` | both by symbol |
| Raw error text can still reach the CLI and the browser banner | a ten-site census pinned to `2bc3fa90` | the census re-derived, or marked as the dated snapshot it is |
| S3: the tools of s3Manager | `createDirectory` at `:521`, `rename` at `:552` | both by symbol |
| the first delete-lookup row | `deleteLookup` at `:350-379`, `DeleteLookup` at `:320-324`, `listedEntry(at:)` at `:310` | all three by symbol |
| the second delete-lookup row | `deleteLookup` at `:360-402`, `DeleteLookup` at `:323-328` | both by symbol |

**Form of each correction, decided by the maintainer 2026-10-05:** one
group sentence per row, quoting the withdrawn citations verbatim and
carrying the date of the re-derivation. This is the pattern row 106 of this
same file already uses; its marker, read off `docs/BACKLOG.md` on
2026-10-05:

"**The three line citations above were replaced by symbols in the same pass, not retaken**, and all three had gone stale: this row cited `mapStatus` at `:643`, its 412 arm at `:662` and the guarded read at `:341`"

The `fullCRUDRoundTripOverBasic` row carries a second shape for the same
job, a bold lead with the withdrawn wording in curly quotes:

"**Fix round 1 withdraws a clause that stood here**, “on the same keep-alive connection (`ka=5` there, `ka=8` on the MOVE)”"

Seven such passages sit on that one row, and CLAUDE.md's "A correction quotes
what it withdraws" enumerates them. What the shapes share is the invariant a
correction here has to meet: a bold marker, the withdrawn wording or
citation named verbatim, and a date. Quoting each of the ~25 citations in
its own clause was considered and rejected: it would add more text than the
rows it protects.
Treating a line number as a typo owing no quote was also rejected — a
citation is a claim about the tree, and replacing it withdraws that claim.

Both quotations above are kept on single long lines deliberately. Wrapped,
each was verbatim only modulo this document's own line breaks: measured
2026-10-05, before the wrap was removed, a raw search for either returned
nothing while a whitespace-normalised one found it. A quotation a reader
cannot grep is a claim they have to take on trust, which is the failure this
document exists to remove.

**Corrected 2026-10-05** (Task 4, fix round 1). This paragraph first gave
row 106's marker as “Before this correction this row cited `mapStatus` at
`:643` …”, presented as a quotation. It is not one:
`grep -n 'Before this correction' docs/BACKLOG.md` prints 0 lines, paired
with the positive
`grep -n 'The three line citations above were replaced by symbols' docs/BACKLOG.md`,
which prints 1 and is row 106 — so the row and the citation it names are
real, and only the lead-in was invented, written as quoted while never
having been read. Task 4's brief carried the same invented phrase as the
instruction for finding the form, which sent its implementer to a `grep`
that matched nothing; the real wording above was read off the file instead.

**Where a symbol does not exist**, a line number stays, and it is marked
with the date it was derived so the next reader knows how old it is. The
ten-site census is the likely case: a census is a count, and a count is not
a symbol. Then CLAUDE.md's rule applies in full — the command that produced
it travels with it, in a form that runs from a `docs/BACKLOG.md` table cell
(no pipe; several `-e` patterns rather than one `-E` alternation).

## Part D — the index the three candidates leave behind

`docs/BACKLOG.md`'s closing section, "If you don't know where to start",
names exactly these three rows and carries a committed `awk` command
asserting that each opens `**Open` and ends `Not started.`. Closing them
makes that section point a reader at three defects the same file records as
fixed — which is the failure the section's own preamble documents having
made once already, on 2026-10-02.

So the closeout:

- closes rows 147, 148 and 285 in place, each quoting nothing (a closure
  adds, it withdraws no measurement),
- replaces the three candidates with three read out of the rows at that
  moment, not remembered, and
- re-runs the section's assertion command, rewritten for the new three, and
  records what it printed.

The three replacements are not chosen here: choosing them now, before the
rest of the branch runs, would be exactly the remembered-rather-than-read
failure the section exists to avoid.

## Testing

- Part A: the existing suites must stay green, and each of the three probes
  must produce the stated red and the stated green, repeated to a count.
  `swift test --build-system native` for the whole suite at the end.
- Part B: no test. The comment is prose about code; the verification is the
  re-run `grep`, and `swift test` proves the file still builds.
- Parts C and D: no test exists for a backlog row. Every command written
  into a row is extracted from the committed text and run, in that form,
  after the row is written.

## Out of scope

- Making `InternetSpeedProbe` call `outcome(forUnanswered:)` (Part B's
  rejected third option).
- The three stale `.claude/worktrees/` checkouts from earlier sessions.
- Cutting a release, though `v1.6.0..HEAD` is 41 commits and four passages
  in the published user docs are marked as coming in the next release. That
  is a maintainer's decision and belongs in no backlog row.
