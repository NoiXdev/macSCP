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

