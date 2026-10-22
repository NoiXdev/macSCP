# Task 13 report — closeout, in-repository half

Implementer: Task 13 dispatch, BASE `b1537a05`. Sections are written at the point
each starts; a verdict is `VERDICT PENDING` until the step's check has run.

Not mine (per the brief and the debts file, section D): Step 1 (user docs, other
dispatch), Step 8's gated half (rig not running), the rig volume, `ci.yml`, any push.

## Orientation (before any edit)

- Tree at start: `git log -1` prints `b1537a05`; `git status --porcelain` printed nothing.
- `docs/superpowers/ledgers/` already exists with one precedent, commit `3934e2b3`
  ("docs: commit this branch's SDD ledger out of the gitignored workspace"): ledger
  copied verbatim to `docs/superpowers/ledgers/<date>-<slug>.md`, plus one report as a
  sibling `<date>-<slug>-final-fix-report.md`, plus an appended closing section; briefs,
  per-task reports and review diffs were NOT committed there.

## Extra: commit the SDD ledger (done first, so rows can cite it)

Method: `python3` copy with `filecmp.cmp(..., shallow=False)` asserted for each file.
Ledger -> `docs/superpowers/ledgers/2026-10-19-s3-bucket-settings.md`; records -> the
directory of the same name. Convention check: `docs/superpowers/ledgers/` held one
ledger (`3934e2b3`) as `<date>-<slug>.md` plus one sibling report; it does not cover
66 task records, so the directory layout is my choice and the commit message says so.
Counts, by `ls ... | /usr/bin/grep -c`: 14 briefs, 29 reports, 22 review/re-review
files, plus `task-13-closeout-debts.md`; 32 `review-*.diff` files NOT copied
(`ls .superpowers/sdd/2026-10-19-s3-bucket-settings/review-*.diff | wc -l`).
`task-13-report.md` is copied at the very end (final form).
Commit `49a93ec7`. Secret scan of the copied set: no rig credential strings found;
the ledger's header line names the loopback rig port once, as `CLAUDE.md` already does.
VERDICT: DONE (closing section for the phase after Task 12 still to append).

## Step 2 — the s3Manager wishlist row, corrected in place

Method: a python script (scratchpad `step2.py`) locating the row by its opening words
(asserted to match exactly one line), asserting every quoted passage occurs verbatim
in the row (and the design and ledger quotes in their files), asserting each named
hash resolves with `git cat-file -e <h>^{commit}`, asserting no pipe character in the
appended text, and `assert r.count(old) == 1` before each in-place insertion.
What changed: two "Superseded 2026-10-22" markers inserted after the "Missing (...)"
sentence and after "Not started."; one "Corrected 2026-10-22" appendix quoting all
three withdrawals whole; the built / not-built / still-missing lists with commits.
Finding for the maintainer: the old "Missing" sentence listed eight tools, of which
three are now built (CORS editor, Object Lock, create bucket); `versioning` was in its
search list but never in its list of missing tools, so the brief's "move ... versioning
from Missing to done" is stated as "never named missing, built as well".
The unconfirmed-placement sentence was ALSO withdrawn: the 2026-10-19 design records the
confirmation; both wordings quoted.
Commands (extracted from the committed row text and run unedited by `extract_run.py`
via `zsh -c`): `git rev-list --count eec041f5..b1537a05` -> 88 (exit 0); the
fixed-string search over `Sources` -> nothing, exit 1; the `crossBucketRenameRefused`
search -> one line, exit 0. Primitives: `rev-list --count` counts commits; the greps are
existence checks and no occurrence count is claimed.
Commit `0bdfbcee` (first made as `dba875f5`, amended once after `git log -1` before anything was built on it:
its message said "four commands" where the row holds three).
VERDICT: DONE.

## Coordinator addition — the stale "not in this tree" comment in `S3FileSystem.connect`

Method: located the comment by `/usr/bin/grep -n -F -e 'What would resolve an empty browser' Sources/macSCPCore/S3/S3FileSystem.swift`
(one hit, in the `.bucketList` arm of `connect`). Verified the tree before writing: the sheet
and the menu row landed together in `75fe0553` (`git show --stat` of it lists
`ConnectionActionRoute.swift`, `ContentView+MenuActions.swift`, `ContentView+Sheets.swift`);
`CreateBucketSheet.swift` was added by it (`git log --diff-filter=A`). History of the
paragraph by `git log -G'resolves the empty state'`: `612f1ece` wrote the first wording,
`09080f6e` (Task 6's fix round) replaced it with the "NO browser surface calls it yet"
wording. The edit (scratchpad `comment_fix.py`) asserts the old block occurs exactly once and
asserts both quoted wordings verbatim in the old block (whitespace joined across the `//`
line wraps) and in the new one. Both are quoted, both are stated withdrawn, and the new
text says the first version had the destination right and the date wrong. `swift build`: clean.
Commit `c6dda748` (first made as `61e30f7c`, amended once after `git log -1`, to correct which commit made the
earlier correction: the first message said `612f1ece`'s follow-up; it was `09080f6e`).
Not touched, as instructed: `bucketListEmpty`, its case, catalogue strings and six comment
sites; `Sources/macSCPCore/Compare/DiffEligibility.swift` near its "calls it yet" quotation.
Other comments naming the plan as future work, searched with
`/usr/bin/grep -rn -F -e 'calls it yet' -e 'not in this tree' -e 'until it lands' -e 'is planned' Sources --include='*.swift'`
(hits: `BrowserPane.swift` "anything is planned", unrelated; `DiffEligibility.swift`, the quotation
you named; the comment I edited) and by a comment-line search for `createBucket` near
"yet / no caller / nothing calls / no surface / not yet / planned" over Sources and Tests
(no hits). `S3SettingsXML.swift` names the s3-bucket-settings design in a doc comment, a
reference and not a claim of futurity; not touched. VERDICT: DONE (full `swift test` still to
run at Step 8, since a guard that reads raw source could in principle read this file).

## Step 3 — the `macscp-probe-lock` row

Method: `step3.py` asserts each quoted passage verbatim in its source (design section 4,
ledger, Task 4 report, rig README) before `insert_rows` appends one row at the end of the
"Tooling and maintenance" table (asserts exactly three pipe characters in the row).
Claims read from source, not run: the bucket-list-mode gated tests tolerate it. Commands in
the row extracted from the committed text and run unedited via `zsh -c`:
`/usr/bin/grep -n -F -e 'names.contains("macscp-second")' -e 'items.count == 1' Tests/macSCPCoreTests/S3FileSystemIntegrationTests.swift`
prints 2 lines (878, 949); `/usr/bin/grep -rl -F -e 'macscp-probe-lock' Tests` lists 5 files.
The rig was not looked at (not running); the row says so. The maintainer's decision is not
resolved. Commit `f3277b1c`.
VERDICT: DONE.

## Step 4 — what Task 6 made unreachable

Three artifacts, three results.
1. The `docs/BACKLOG.md` row: its four commands re-run on 2026-10-22 at `f3277b1c`, with
   `/usr/bin/grep` and with the session `grep` (ugrep -G; no `$` in any): nothing / exit 1, 19, 20, 4 lines.
   All reproduce the row. Primitive: the 19 is `grep -rn ... | wc -l` (lines), the 20 is
   `grep -rno ... | wc -l` (occurrences). The six comment sites: all present once, found by
   `sites.py` (flattened comment text) and by one fixed-string command (six lines). Count did
   NOT move (row says five plus a sixth; that is six). Two "near line" numbers drifted
   (1278 -> 1293, 24 -> 25); the row said approximate. A seventh occurrence of the word in a
   comment (`RemoteBrowserViewModel.swift` near 1330, "used to print as a bare case name")
   was looked at and judged not stale: MY judgement, flagged in the row; the maintainer may rule otherwise.
   Appended a "Re-checked 2026-10-22" paragraph; commit `35df439e`.
2. The spec row: **DISAGREEMENT WITH THE BRIEF, reported not corrected.** The brief cites the
   row as `...s3-bucket-browser-design.md:44`. It is line 45, and was at `612f1ece` and `b1537a05`
   (`git grep -n -F -e '200 with zero buckets' <commit> -- <file>`); the file's last commit is
   2026-09-02. The correction cites the row by its text. Corrected in place: row cells kept, a
   "superseded 2026-10-22" pointer appended to the meaning cell, a correction paragraph below
   the table quoting the meaning and message cells. Commit `280eff4b`.
   Also noticed, NOT touched: the same section's sentence "Three outcomes, each its own error case
   with its own catalog string" sits above a four-row table; it was already inexact on 2026-09-02.
3. The four catalogue strings: untouched, as the brief says. Case, consumers: untouched.
VERDICT: DONE.

## Step 5 — pin the census section's third output

Method: `census.py` feeds `git show <commit>:docs/BACKLOG.md` through the section's own awk.
The brief's figures REPRODUCE: `b1537a05` -> `opens-Open=137 shown=92 hidden=45`; base
`eec041f5` -> `134 / 89 / 45` (39 predate the branch, 3 are its rows). The recorded 95/52/43
reproduces at `493bc256` (the commit that carried the paragraph; its parent prints 94/51/43,
the `bd53975d` figure) and at its fix round `7b9c1e47`. Pinned to `493bc256`: the fence's third
line is now the same command over `git show 493bc256`; the paragraph's sentence carries a
pointer; a new correction paragraph after it quotes verbatim the withdrawn bare figure sentence and
the withdrawn third fence line, and a small fence carries the two revisions of the 42.
All five fence commands, extracted from the committed text and run unedited via `zsh -c`
(`run_fences.py`; the /tmp files they write were removed afterwards), print 90/47/43,
94/51/43, 95/52/43, 137/92/45, 134/89/45. Commit `6118e6ed`.
Found, NOT fixed (scope: "that third line"): (a) two clauses in the same paragraph make live-file
claims ("The section's own census command above prints those same three numbers..." and the
labelled listing's `candidates=52 removed=43 ...`); I ran each over `493bc256`'s own file
(`census2.py`): both reproduce there, and at `b1537a05` they print 137/92/45 and
`candidates=92 removed=45 opens-Open=137`. The correction paragraph says so. (b) The closing
paragraph of the section (2026-10-15/16) records live-file figures too (`docs/BACKLOG.md
opens-Open=117 ...`, then 119/76/43, dated 2026-10-16 but with no commit): same defect, not touched.
Row-number citations: not swept, per the brief.
VERDICT: DONE.

## Step 6 — the warning gate's blind spots

Method and figures (every command is in the committed row and was extracted from it and run unedited):
- Brief's local figures REPRODUCE, taken twice (first with a scratch path in the session scratchpad,
  then in the committed form with `/tmp` paths): `swift build --target macSCPCoreTests --scratch-path <fresh> > log 2>&1`
  (Swift 6.4, default build system, ~2 min) -> 14 `warning:` lines (`grep -c`, lines), 7 distinct
  `macro expansion #expect:1:N` headers, 7 `note: expanded code originates here` lines at 4 locations
  (`ArchiveRunnerTests.swift:82:76` once; `S3CreateBucketTests.swift` `:54:49`, `:65:56`, `:84:51` twice each);
  gate pattern: 0 raw, 0 after ANSI strip. Both runs agree.
- NEW, beyond the brief: the open question "are CI's logs coloured" is answered for two runs with `gh run view --log`.
  Run 33946526921 (2026-09-05): the gate counted a real, uncoloured warning (`Unique warning locations: 1 (budget: 1)`).
  Run 38225383495 (develop `c0762fac`, Xcode 16.4, success): its log contains the `ArchiveRunnerTests.swift:82:76`
  macro-expansion warning 24 times, uncoloured, and the gate printed `Unique warning locations: 0 (budget: 0)`.
  So the macro-expansion blind spot is real IN CI today; the colour blind spot is local (Swift 6.4 / default build
  system; reproduced with a one-file package: 0 raw, 1 stripped) and unmeasured for CI's future toolchain.
- Reproduction trap found by running the row's commands twice: a second build of an already-built package prints
  no warning and silently turns the figure into 0. The row says so.
- Consequence for the brief's claim "the branch is pushable": holds for every format measured, but CI has not run
  this branch and whether Xcode 16.4 emits the three `S3CreateBucketTests.swift` warnings is unmeasured. Flagged in the row.
- Not re-measured: Task 8's AppKit-target figure (0 of 4 raw, 4 of 4 stripped); cited from its review.
- Not done by instruction: no warning fixed, `ci.yml` untouched. /tmp scratch removed afterwards.
Commit `1714ac39`. VERDICT: DONE (with the CI findings above as additions).

## Step 7 — the three Core rows from Task 9's review

Three rows appended (`step7.py`; quotes asserted verbatim against `task-9-review.md` and the ledger).
Re-checked against the tree rather than the ledger: `ElementCensus` is in one file only and
`parseCORSReportingLoss` does not exist (exit 1); the `corsBody` doc comment still says "stays the inverse of
`parseCORS` for any rule"; `validate()` still has no range check. Two throwaway-test measurements (a Core test file,
run once, then deleted with `rm`; `git status --porcelain` empty afterwards): CR value scalars 97,13,98 -> 97,10,98,
round trip unequal; `MaxAgeSeconds` -5 parses to -5, `validate()` is `ok`. NOT reproducible from a committed command
(the rows say so); the CR half has a committed pin whose run (1 test, passed) is in the row.
Two findings beyond the brief, both in the rows: (a) the App test that pins the CR defect will fail when Core is
fixed (it asserts the defect); (b) the review's "the sheet inheriting it for free" is not quite right: the sheet's
`blockerLine` has an exhaustive `switch problem`. Also: whether a store refuses a negative `MaxAgeSeconds` is
unmeasured (rig not running); the brief's "is refused by the store instead" is an inference, and the row says so.
Commit `9305b4d8`. VERDICT: DONE.

## The debts file (items 1-14) — rows

Commit `c9542893` (amended once, after `git log -1`, to fix a "twelve/thirteenth" miscount in its message). Twelve rows, appended to the
tooling table by `step8.py`, which asserts every quote verbatim against its source (ledger, reports, source comments) before writing and
asserts three pipe characters per row. Every command in the rows was extracted from the committed text and run by
`run_all8.py` (output matched each stated figure). Item to row:
- A1 -> "`AuditEvent.Kind.plaintextConfirmed` is in no audit-log filter segment ...". A2 and 13 -> one row ("`CreateBucketModel.create` records its refusal
  unconditionally ..."). A3 -> no row, as instructed (seen and ruled; I do not disagree).
- B4 -> "A bucket-settings sheet holds its audit recorder by value ...". B5 and B6 -> one row ("`TeardownStage.swift` records a maintainer decision ...").
  B7 -> "The audit sheet's sort-wiring guards still read raw source text in eight places ...".
- C8 -> "The branch is not bisectable across Task 11 ..." (**re-measured by running it**, see below). C9 -> Task 11's recorded-not-fixed Minors. C10 -> Task 10's open items.
  C11 -> Task 8's unverified probes. C12 -> the stale `RemoteFSFindingTests` count (26 today). C14 -> the nominal sweep guard (its own row, not folded into C9).
- Item 12's "stale count": the doc comment says "five of twenty-three"; the awk form without a pipe prints 26; the ledger's original pipe form also prints 26.
Re-measured (not copied): **C8**: `git worktree add --detach <scratch> 75fe0553`, `swift test --filter RigidControlScanTests --filter entriesOfOneTypeMeasureDifferentStates`
-> "17 tests in 2 suites failed ... with 3 issues" (1 in `noRigidComponentIsHeldToAWidthFrame(component:)` for `CheckboxRow`, 2 in `entriesOfOneTypeMeasureDifferentStates()`);
checkout `b7371a8f` in the same worktree -> same 3 issues; `d7c6631c` -> 17 tests passed; branch head -> 17 passed. Only those two suites ran at each commit.
Worktree removed afterwards (`git worktree list` shows only the two real ones plus `file-actions-builder`, which is not mine).
Discrepancies and judgement calls (NOT quietly resolved): (1) hand-off item 10's "one figure whose derivation is recorded in the ledger" is ambiguous; I took it to be
the 36,500-day ceiling and said so in the row. (2) C10's grep for `acknowledged = ` prints 11 lines today; the ledger said "all 10 ... are resets"; the row gives both and notes that
two of today's 11 are declarations (so nine resets). (3) The hand-off lists B7 as "two guards ... cannot be" moved; the file has eight raw call sites and only two are known not to be
movable; the other six were not examined (said in the row). (4) The ledger's own wording "re-review ... re-ran nine of nineteen" and the two ledger lines are consistent with the row.
Twelfth row (not in the hand-off, owed by the ledger's Task 3 re-review: "worth a backlog line at closeout"): CORS leaf whitespace, measured with a throwaway test (deleted).
Source/test comments I found that disagree with Ruling 21 (`AuditLogSheet.swift` "shows under All and Errors only"; `AuditLogFilterTests` "not a decision anyone made for it") are
recorded in the A1 row and NOT edited (a row is not a source change; the coordinator may rule).
VERDICT: DONE.

## Rows the ledger owed that the hand-off did not list

1. **Content-MD5 row** (ledger, Task 3: "The row is corrected at closeout to say what was established and how"; Task 3 report concern 2 and Task 4 report item 8 both ask for it).
   Corrected in place (commit `bf5cb4d5`): the clause "neither AWS reference page was read when this row was written, so each task confirms the requirement against its own page"
   is quoted and withdrawn as a description of what happened (Task 3: "I did not fetch that page and relied on ruling A"); what the coordinator established (search summaries only,
   two differing results) is recorded; the closing condition ("a request-level test like the one named above") is found MET by `/usr/bin/grep -rn -F -e 'Content-MD5' Tests` (14 lines; tests named in the row);
   the row is left open. **Disagreement, not edited:** `S3FileSystem.setObjectLockDefault`'s comment says "(maintainer ruling A, measured)"; the ledger says search summary. The row had no closing
   pipe before and keeps that form (2 pipes, not 3).
2. **Sight checks** (the project's convention for "nothing visual was verified": eight existing "Sight checks for the ... build" rows). New row "Sight checks for the S3 bucket settings (2026-10-22 build)", SC-1..SC-8;
   every Look-for quotes the design or an English catalogue string, asserted verbatim; the row says they are derived and not observed. Commit `b0d9153e`. This is the vehicle for hand-off item 10's last clause, and it goes beyond what the hand-off asked.
3. **Pretty-printed CORS leaf** (in the debts commit above).
Considered and NOT done: ledger "Deferred minor: one gated assertion that `setCORS([])` on a fresh bucket does not throw" (Task 3 re-review) is a gated test, flagged there "for the final whole-branch review", not for the closeout; several
"carried to the final review" Minors are the final review's. A `Status: awaiting maintainer approval. Not planned, not started.` header in `docs/superpowers/specs/2026-10-19-s3-bucket-settings-design.md` is now false;
that file is not in Task 13's list, so it is reported here and not edited.

## Step 8 — the suite (ungated half only)

`swift test`, no `--build-system` flag, at `b0d9153e` (HEAD then; later commits are documentation only), output in the scratchpad:
Core `✔ Test run with 5085 tests in 408 suites passed`; AppKit `✘ Test run with 2848 tests in 240 suites failed ... with 1 issue`, the one issue being
`ViewTestabilitySpike.swift:202:9` ("Varying only isRegex leaves the pixels unchanged"), the known pre-existing local failure, not a finding. Same two figures as
the ledger records at `83ffa661`; the only Sources change in this closeout is the comment in `c6dda748`.
**`MACSCP_ITEST=1 swift test` was NOT run, and Step 8 is NOT reported as done.** Reason: the Docker rig is not running (hand-off: no SSH on 2222, no store on 19000, checked 2026-10-22) and may only be
started from the main checkout, which this session cannot reach. I did not try to start it. `MACSCP_KEYCHAIN`, `MACSCP_PIPE_TIMING`, `MACSCP_SATURATION`, `MACSCP_DIFF_COST` suites were not run either (not asked).
VERDICT: ungated half DONE; gated half NOT DONE.

## A defect of mine, caught late

Two commits were amended after they were made (their messages needed correcting), which changes their hashes. A BACKLOG row written between the commit and the amend named the old hash (`61e30f7c`), a hash no longer in history.
Found by extracting every 7-12-hex token this closeout added to `docs/BACKLOG.md`, the 2026-09-02 spec and `S3FileSystem.swift` and checking each is a commit reachable from HEAD (`hashcheck.py`): 48 tokens, one bad. Fixed in
`de54058f` (first made as `3f45c250`, amended once after `git log -1`); re-run: 48 tokens, none bad. The report text above was corrected the same way.
The same check over the two ledger files as committed in `ec369781` (114 tokens) reports eight that are not ancestors of HEAD, none of them an error: this report names three superseded hashes on purpose, each
labelled "first made as" (`3f45c250`, `61e30f7c`, `dba875f5`); the copied ledger, whose text is not mine, names three pre-squash hashes with its own words "squashed from" (`51ac79b9`, `ffa4fe9a`, `f83e0db8`)
and two hashes from the user-docs repository (`4a10178`, `d7c87bb`).

## Commits (BASE `b1537a05`; `git log --reverse --format='%h %s' b1537a05..HEAD` lists them)

`49a93ec7` ledger and task records; `0bdfbcee` s3Manager row; `c6dda748` `S3FileSystem` comment; `f3277b1c` probe-lock row; `280eff4b` spec row; `35df439e` dead-case row re-check;
`6118e6ed` census pin; `1714ac39` warning gate; `9305b4d8` three Core rows; `c9542893` eleven debt rows + one; `bf5cb4d5` Content-MD5 row; `b0d9153e` sight checks; `de54058f` hash fix;
and the final commit that appends the ledger's closing section and copies this report into `docs/superpowers/ledgers/2026-10-19-s3-bucket-settings/`. The plan's Step 9 names one commit,
`docs: close the bucket-settings half of the s3Manager row`; the work was done as one commit per coherent step instead, and the final commit's subject says "ledger", not that sentence.
Nothing pushed. No `git checkout -- <file>`, no bare stash. Two `git commit --amend` calls, each after `git log -1`; one temporary `git worktree add --detach` (removed).

## Concerns the coordinator should rule on (none acted on)

1. **CI's warning gate misses a macro-expansion warning that CI itself prints** (run 38225383495, 24 lines, gate says 0). The hand-off's "the branch is pushable ... however the gate behaves" is an inference that
   holds for every format measured here; CI has not run this branch, and whether Xcode 16.4 prints this branch's three new warnings at all is unmeasured.
2. **Comments that disagree with a ruling or a ledger, not edited**: `AuditLogSheet.swift` ("All and Errors only") and `AuditLogFilterTests.swift` ("not a decision anyone made for it") vs Ruling 21; `S3FileSystem.swift`
   `setObjectLockDefault` "(maintainer ruling A, measured)" vs the ledger's "search summaries".
3. **The design's `Status: awaiting maintainer approval. Not planned, not started.`** is false; the file is not in my list.
4. **The census section's later paragraph (2026-10-15/16)** records live-file figures with no commit, the same defect as the third output; and two clauses next to it. Row numbers still not swept (as instructed).
5. **The brief's `:44`** for the spec row is `:45` (always was). Reported in the commit message and the row, not corrected into agreement.
6. The ledger copy and my rows mention the loopback rig port (`19000`, `2222`) as `CLAUDE.md` and the design already do; I judged a loopback test-rig port is not the "endpoint" the hand-off forbids. Say if you read it otherwise.
7. **The `bisect` finding (C8)** means a squash/reorder of `75fe0553`/`b7371a8f` is available if you want a bisectable branch; I did not touch history.
8. `/tmp` was used for the committed forms of the warning-gate commands (they are written with `/tmp/macscp-*` paths); I removed those files afterwards, and the one with `swift build` output.

## Not done / not verified

- **Step 1 (user documentation):** not mine; another dispatch in `/Users/noidee/_dev/noix-docs`. Nothing written or read there.
- **Step 8's gated half:** not run (rig down; main-checkout-only). Nothing about the gated suites is claimed anywhere, except that the probe-lock row and the sight-check row say so.
- **The rig and `macscp-probe-lock`:** not looked at (not running). The row records the leftover from the design and Task 4's report; "still there" rests on those, not on a check. The reset decision is not taken.
- **Nothing on screen:** no GUI was launched; the sight-check row is derived from the design, not from observation.
- **What a store answers to a negative `MaxAgeSeconds`:** unmeasured; the row says so.
- **Whether Xcode 16.4 (CI) emits the three `S3CreateBucketTests.swift` warnings:** unmeasured.
- **Task 8's AppKit warning figures (0 of 4 raw / 4 of 4 stripped):** cited from its review, not re-measured. The mechanism was reproduced independently with a one-file package.
- **The other ten of the 19 Task 12 fix-round-3 probes (C1-C5 etc.):** not re-run (the row says one observer).
- **Task 8's sixteen probes:** not run.
- **Hand-off item 10's "one figure whose derivation is recorded in the ledger":** ambiguous; I took it to be 36,500 and said so in the row.
- **B7's other six raw-text guards:** not examined for movability.
- **The throwaway-test measurements** (CR scalars, negative `MaxAgeSeconds`, whitespace leaf) are not reproducible from a committed command; each row says so. The CR half has a committed pin whose run is in the row.
- **No fix was made to any of the defects the rows describe**, by instruction.
- **Two comment-line-level sweeps** (for other comments naming the plan as future work) were by `grep` on a few phrases and may have missed a differently-worded one.
- **Mutation-probe harness:** not used; no tracked file was planted. The throwaway test files were untracked and removed with `rm`; `git status --porcelain` was empty after each.


## Coordinator rulings, round 2 (a section is appended as each item starts)

Order ruled: (1) the Content-MD5 comment in `S3FileSystem.swift` and a sweep for other unsupported "(maintainer ruling ...)" or "measured" attributions;
(2) the design document's status line; (3) the two comments that disagree with Ruling 21; (4) the census paragraph of 2026-10-15/16, pinned; (5) the trap in the Step 7 rows.
My concerns 1 and 6: no work, ruled. Unchanged constraints: no push, `git log -1` before any amend, targeted test filters for comment-only work.

### Item 1 — the Content-MD5 comment, and a sweep for the same attribution elsewhere. VERDICT PENDING
Method: replace the parenthesis "(maintainer ruling A, measured)" above the signed request in `setObjectLockDefault` with what is known and where it comes from, quoting the withdrawn text verbatim;
assert the anchor is unique before writing; then sweep Sources and Tests for `maintainer ruling`, `(measured`, `measured 20` attributions and judge each against the ledger.
Result: comment corrected in `63e6233f` (anchor asserted unique; withdrawn wording quoted verbatim; says: sent and signed; a READING of AWS's reference from a search summary, not a measurement;
no run of the request without the header on record; rig measured to accept `PUT ?versioning` without it, nothing about this call; the test pins the request's shape). `swift test --filter S3ObjectLockTests`: 49 tests, 1 suite, passed.
The Content-MD5 row's search `'maintainer ruling A, measured'` printed one line and now prints nothing, so the row got a "Resolved 2026-10-22" paragraph quoting that sentence (`d7526a60`), with a replacement command (2 lines).
**Sweep for other attributions** (what I did and found; nothing edited beyond the one comment):
 - Method: `git diff eec041f5..HEAD -- Sources Tests`, added lines only, awk-labelled by file, filtered for `maintainer` and for `measured` and `Ruling [A-Z]`. (The whole-tree `maintainer decision/ruling` grep is ~80 lines of pre-branch comments; not this branch's.)
 - `maintainer`: 5 added lines. 4 are supported by the design: "the maintainer asked for the lock to [be at creation]" (`S3BucketSettings.swift`, and `S3ObjectLockTests.swift`: design 2.2/6.1), "The maintainer asked for COMPLIANCE" (`ObjectLockSheetTests.swift`: design 6.5), "maintainer's visual check" (`BucketCORSSheet.swift`, a pointer to a check, not a claim). The fifth was the one fixed.
 - `measured`: about 60 added lines. Those dated "measured 2026-10-19 (the rig)" match the design's section 4 table, as far as I compared (versioning, CORS order, `FETCH` accepted, object-lock 404, delete refusals, default applies to later writes). `CreateBucketSheetTests.aNameAlreadyInTheListBlocksTheButton` says "MEASURED on the rig (Task 5's review)": the measurement is in `task-5-report.md` ("On the rig, a second `createBucket` of a bucket the key already owns ...") and the ledger's Finding 11, so the claim holds and the attribution to "review" is loose (report/ledger). Not edited.
 - **NOT supported, found, NOT edited (for you to rule on):** three test comments say of `PUT ?object-lock` that "the rig does not require it" (`S3ObjectLockTests.swift` header; `S3ObjectLockGatedTests.swift` header) and "the rig does not check it" (doc comment of `settingTheDefaultIsAPutWithASignedContentMD5OfItsBody`). I find no run that sent that request without the header to the rig; the Content-MD5 row says only `PUT ?versioning` was measured. Same claim as the comment I fixed, in a test comment, without the borrowed authority.
 - Also looked at: `S3FileSystem.swift` doc on `deleteTree` ("which S3 requires for this call", DeleteObjects): older than this branch and not an attribution; untouched. `Ruling A/B/C` in `S3ObjectLockTests.swift` are Task 4's dispatch labels, not claimed as the maintainer's; their content for B and C is measured/ledgered.
VERDICT: DONE (sweep is by grep over added lines; a differently worded attribution could be missed).

### Item 2 — the design document's status line. VERDICT PENDING
Result: status line corrected in place (anchor asserted unique), withdrawn wording quoted verbatim; now: approved 2026-10-19, planned, implemented as the first half on `s3-bucket-settings`, second half out of scope (section 10).
No commit count restated. **The approval is recorded on the coordinator's word**: neither the design nor the ledger holds it (I grepped the ledger for "approv": only review verdicts); the correction says so.
`1dac7bd3` resolves. Commit: see item list at the end. VERDICT: DONE.

### Item 3 — the two comments and Ruling 21. VERDICT PENDING
Result: `AuditLogFilterTests.everyKindIsInAtMostOneKindSegmentAndTheUnplacedAreNamed`'s doc comment corrected (withdrawn sentence quoted verbatim; names Ruling 21, the ledger, the backlog row, and that the last
expectation changes on a reversal) and the Ruling 19 arm in `AuditLogSheet.swift` gained the docs-page cost, marked as the coordinator's statement and unread by me (`9483bc0b`; anchors asserted unique; comments only;
`swift test --filter AuditLogFilterTests --filter AuditLogSortWiringGuardTests --filter BucketSettingsAuditTests`: 28 tests in 3 suites passed). The "All and Errors only" comment is left, as ruled; the A1 row got an "Updated"
paragraph, with the withdrawn clause's status stated, and the recorder observation labelled as an observation. VERDICT: DONE.

### Item 4 — the census paragraph, pinned. VERDICT PENDING
Result (`census` commit below): found by `git log -S` and `census.py`: the live-file command of the 2026-10-15 paragraph read 117/74/43 at `693db7c0` and (2026-10-16) 119/76/43 at `ea330ada`; the 111/68/43 it withdrew was `177c9ef3`.
Edits: (a) the fence's second line is now `git show 693db7c0 | awk ... -v LABEL=693db7c0`; (b) the sentence after it names that label (first occurrence only; the 2026-10-16 paragraph's verbatim quotation of the old sentence is left, being history);
(c) a correction paragraph and a fence at the end of the file: quotes the withdrawn fence line and sentence verbatim, pins 119 to `ea330ada`, and pins the two clauses I had previously left unpinned (the longer-labelled census command and the labelled listing: both assert figures)
to `493bc256`, where each reproduces; at `b1537a05` they print 137/92/45 and `candidates=92 removed=45 opens-Open=137`. Row-number sentences left alone (assert positions, forbidden sweep). All five pinned lines run from the committed text print the stated figures
(`run_pinned.py`; /tmp copies removed). Hex-token check clean. VERDICT: DONE.

### Item 5 — the trap in Step 7's rows. VERDICT PENDING
Result (`70a2921d`): two Step 7 rows got an "Updated 2026-10-22" paragraph each. (corsBody) names `aValueThatChangesOnTheWayBackIsNotLossless` in `BucketCORSSheetTests.swift` as the test a Core fix turns red by design, says the fixer must rewrite it
to the new truth and not weaken it, lists the other users of the same value (`aMethodAndACarriageReturnAreBothSaid`, sweep cause `carriageReturnOrigin`, the lines helper, the registry entry "CORS text with a carriage return in a value"; `grep -rn -F -e '&#13;' Tests Sources`
prints 8 lines) and says what to do if no other value changes on the round trip (the state becomes unreachable: reserve or retire, as the `bucketListEmpty` row says). Which tests go red is READ, not measured (Core not changed).
(validate) the review's "with the sheet inheriting it for free" is quoted and withdrawn: `blockerLine`'s exhaustive switch over `problem` is a compile error for a new case; plus a four-language sentence, the model's line list, a sweep cause. `grep -rn -F -e 'CORSValidation'` prints
4 lines and does NOT find the switch (it never names the type); the row says so. (My first version of that sentence said six lines and test files; the count was wrong and was corrected before the commit.) Both rows' searches run from the committed text. VERDICT: DONE.

## Round 2 — summary

Commits (hashes final unless a later amend is stated): `63e6233f` Content-MD5 comment; `d7526a60` Content-MD5 row resolved; `2c69f1e1` design status line; `9483bc0b` Ruling 21 comments; `9ea5ca9f` plaintextConfirmed row updated;
`ac0ee57e` census pin; `70a2921d` Step 7 trap. Tests: filters per item (49 tests / S3ObjectLockTests; 28 tests in 3 suites / audit filters, sort wiring, audit recorder), then the full `swift test` below.
Found while sweeping for the second "(maintainer ruling ...)" attribution: none with that authority borrowed; but three test comments (`S3ObjectLockTests.swift` header, `S3ObjectLockGatedTests.swift` header, and the doc comment on
`settingTheDefaultIsAPutWithASignedContentMD5OfItsBody`) say "the rig does not require/check it" of `PUT ?object-lock` without Content-MD5, which I can find no run to support (only `PUT ?versioning` was measured). Not edited; recorded in the Content-MD5 row.
Full `swift test` (no build-system flag) at `70a2921d`: Core `✔ Test run with 5085 tests in 408 suites passed`; AppKit `✘ Test run with 2848 tests in 240 suites failed ... with 1 issue`, the known `ViewTestabilitySpike.swift:202`. Same figures as before round 2.
Gated suites still not run (rig down). Sources touched in round 2: three comment-only edits (`S3FileSystem.swift` in `63e6233f`, `AuditLogSheet.swift` in `9483bc0b`; tests comment in `9483bc0b`). The ledger's closing section said "Only `c6dda748` touches `Sources/`"; that sentence is now corrected in the ledger.
Not done in round 2 / not verified: the user-docs audit log page (the coordinator's statement that it names File Ops is repeated in a comment and a row, marked as unread by me); the design's approval (recorded on the coordinator's word); whether any test goes red after a Core fix for the carriage-return value (read, not run);
the sweep for unsupported attributions was by grep over added lines. Nothing pushed; no amend in round 2.

## Round 3 — coordinator's rulings on the three test comments (a section is appended as each item starts)

Order: (A) correct the three "the rig does not require/check it" test comments, quoting each; (B) write into `S3ObjectLockGatedTests.swift`'s header and into the Content-MD5 row the observation a gated run would settle and what each outcome means
(the gated test itself only if the file's pattern makes it a one-liner); (C) drop the "coordinator's statement" hedge on the audit-log docs page (verified by the coordinator, 2026-10-22), citing the page by its sentence;
(D) the ledger's closing section records the approval: chat words `plan passt, umsetzen`, the ledger as sole record, no date finer than the plan file's. The design document must not claim an artifact for it.

### A and B — the three comments and the observation. VERDICT PENDING
Result (A, B): `e6b94cc6` corrects the three comments (`S3ObjectLockTests.swift` header, `S3ObjectLockGatedTests.swift` header, doc comment of `settingTheDefaultIsAPutWithASignedContentMD5OfItsBody`), each quoting its withdrawn wording verbatim
(anchors asserted unique), and writes into the gated header the observation that would settle it: one signed `PUT ?object-lock`, GOVERNANCE default of one day, NO `Content-MD5`, on a throwaway lock-enabled bucket, status recorded; both outcomes decided in advance.
`4aedf6ae` carries the same into the Content-MD5 row (its "prints three lines" sentence and "were not edited" are withdrawn, quoted; the same search now prints 5 lines, each inside a quotation of the withdrawn wording or the decided outcome).
The test itself was NOT added: the file's pattern is a raw signed request through `S3FileSystem.signedRequest` and `perform`, plus bucket create and delete helpers, about two dozen lines, not a one-liner, and nobody can run it; an unrun test is a claim.
Tests: `swift test --filter S3ObjectLockTests --filter S3ObjectLockGatedTests`: 52 tests in 2 suites passed (the gated suite is disabled without `MACSCP_ITEST`).
**UNEXPECTED, from writing the outcomes down:** the favourable outcome does not do what the ruling hoped. If the rig ACCEPTS the request without the header, "the rig does not require it" becomes measured, for RustFS 1.0.0 only, but the ORIGINAL comment's claim was about AWS ("a `PutObjectLockConfiguration`
without it fails 400"), which the rig cannot measure either way. So even the best result leaves the AWS half a reading; the header and the row say so. The refused outcome is the more informative one: it would show the reason both test headers give for a shape-only test is wrong.
Second unexpected thing: the existing gated tests send the header on every request, so a green gated run was never silent-proof of anything about it, as the versioning row already said for its call; this is why the observation has to be a new, header-less request.
VERDICT: DONE.

### C — the docs-page hedge. VERDICT: DONE
`2a1f571a`: the Ruling 19 arm's comment in `AuditLogSheet.swift` now says the page was read by the coordinator on 2026-10-22 and cites its sentence ("under **File Ops** and under **All**", and File Ops in the filter menu's list), with the hedge dropped and its withdrawal stated; the `plaintextConfirmed` row got a "Verified" paragraph quoting the withdrawn hedge sentence.
I did not read the page myself (noix-docs untouched), so the provenance is stated as the coordinator's reading. `swift test --filter AuditLogFilterTests --filter AuditLogSortWiringGuardTests`: 17 tests in 2 suites passed.

### D — the approval. VERDICT: DONE
`7eb24262`: the ledger's closing section has an "Approval" paragraph: the chat words `plan passt, umsetzen`, received from the coordinator (I did not see the chat), the ledger as sole record because chat is not an artifact, no date finer than the plan file's own, 2026-10-19 (also the ledger's header and first entry);
the design's status correction was edited so it claims no artifact (its sentence "neither this file nor the ledger holds the approval itself" is quoted as withdrawn, since the ledger now holds it) and its status line no longer asserts "on 2026-10-19" as the approval's date but "no earlier than the plan, which is dated 2026-10-19".
Also a ledger "Round 3" paragraph; it quotes verbatim the round-2 sentence "Found and not edited: three test comments ..." as untrue since `e6b94cc6` (the quotation was asserted to occur twice in the file: original and quotation).
A third unexpected thing: the words approve "plan", not "design"; the coordinator told me they approved the design too, and the ledger paragraph says "this plan and the design under it" on his word, not on the words' own scope.

### Round 3 — summary
Commits: `e6b94cc6` three test comments and the gated header's observation; `4aedf6ae` Content-MD5 row; `2a1f571a` docs-page hedge dropped; `7eb24262` approval, design status line and round-3 ledger paragraph; plus the commit that copies this report.
Full `swift test` (no build-system flag) after `7eb24262`: Core `✔ Test run with 5085 tests in 408 suites passed`; AppKit `✘ Test run with 2848 tests in 240 suites failed ... with 1 issue` (the known `ViewTestabilitySpike.swift:202`). Gated suites still not run; nothing pushed; no amend this round.
Not verified: the gated observation (rig down); the docs page (read by the coordinator, not me); the chat words (received from the coordinator).
