# Task 13 — closeout debts the brief cannot know

Written by the controller, 2026-10-22, for the Task 13 implementer. The plan's
Task 13 lists Steps 1–9. These are the debts accumulated by Tasks 5–12 and by
coordinator rulings during execution, which the plan could not list because they
did not exist when it was written.

**How to use this file.** Each item gives a title and a pointer. The pointer is
where the measurement lives — the SDD ledger at
`.superpowers/sdd/2026-10-19-s3-bucket-settings/progress.md`, or a named task
report in the same directory. **Read the pointer and take the figures from there,
not from this file.** This file deliberately restates no figure: a measurement
copied from memory into a second place is how three of this branch's own false
claims were made. Where an item says "per the ledger entry for X", find that
entry by searching the ledger for its heading.

**Every row obeys the project's rules for a measurement record**: a figure
travels with the command that produced it, in the form it is committed — inside a
`docs/BACKLOG.md` table cell that means no pipe at all, so several `-e` patterns
rather than one `-E` alternation. `grep -c` counts lines; `grep -o | wc -l`
counts occurrences. A correction quotes verbatim the wording it replaces. Run
each command again after writing the sentence, because the sentence can change
the answer.

---

## A. Rows that record a coordinator ruling

1. **`plaintextConfirmed` is in no filter segment** (Ruling 21). The audit log's
   facet filter is now exhaustive and this one kind is deliberately placed
   nowhere: it shows under All only, since it is not an error. Connection is the
   obvious home and the move is one name in one arm. The row records the decision
   and its reversal cost. Pointer: ledger, "Ruling 21".

2. **The unconditional shape of `create`'s refusal record is not guarded**
   (Rulings 20, 23 and 26). Ruling 20 made the record structural; a guard that
   pinned the shape was deleted after two ways round it were measured, and the
   five concrete gate spellings it did catch are now unguarded too. Nothing
   behavioural depends on the shape. The row records why there is no guard, so a
   later reader does not rebuild one and believe it holds. Pointer: ledger,
   "Ruling 26" and the correction of its cost line; detail in
   `task-12-fix-3-report.md`.

3. **A dated plan still names a symbol that was deleted** (Ruling 24).
   `docs/superpowers/plans/2026-08-19-p3e-terminal-protocol.md` names
   `matchesFilter`, removed on this branch. Decided: leave it, a dated plan is a
   record of its date. **This item needs no row** — it is listed here so that a
   future sweep finding that mention knows it was seen and ruled on. If you
   disagree, say so rather than acting.

## B. Rows the reviews earned, in areas a task's brief excluded

4. **Ruling 17's capture edge.** A bucket sheet holds its recorder by value, so a
   stored session deleted in another window while the sheet is open could
   recreate that session's audit log file. Pointer: `task-12-report.md`,
   section 5b, which names the file and the symbols.

5. **`TeardownStage.swift` records a maintainer decision resting partly on a
   false reason.** Its claim that `tab.auditRecorder` is nil for an ad-hoc
   connect is false since M31; the decision it documents (a log line rather than
   an `AuditEvent`) was left untouched on purpose, because the decision is the
   maintainer's and only its stated reason is stale. The row asks for the
   decision to be re-read, not for the comment to be edited. Pointer: ledger,
   Task 12 Important 2 entries.

6. **`AuditLogStore.swift`'s "One JSON file per stored session".** Borderline: it
   states a file layout rather than who has a recorder, and the ad-hoc log is one
   more file. Left untouched twice, deliberately. Fold into item 5's row or give
   it its own line.

7. **Two sort-wiring guards still read raw source text**, so a comment quoting
   the code they look for satisfies them. One sibling was moved to the blanked
   view on this branch; these two read string literals and cannot be. Also record
   the semantic defeat that no text scan can catch, named in the ledger. Pointer:
   ledger, "the sort-wiring guard reads RAW text" and `task-12-fix-3-report.md`.

## C. Debts carried from earlier tasks

For each, find the ledger entry for that task and take the wording and figures
from there. Several already have rows; where one does, check the row still says
what the ledger says and correct it in place with a quote if not.

8. **Task 11, M7 — the branch is not bisectable across Task 11.** Two commits are
   red. This is the one debt in this list that affects anyone who later bisects
   this branch, so it is the one to make sure lands. Pointer: ledger, Task 11
   review entries.

9. **Task 11, M1, M3 and M4**, including a word-pin limit and a height comparison
   measured on one machine only.

10. **Task 10's open items**: `acknowledged`'s writers unscanned, German date
    phrasing, one figure whose derivation is recorded in the ledger,
    `complianceInForce`'s expiry boundary on one arm of one test, and that
    **nothing visual was ever verified on this branch**.

11. **Task 8's committed probes were never verified by a second party.** The count
    is in the ledger; do not restate it from memory.

12. **Task 5's stale `RemoteFSFindingTests` count.**

13. **Task 12's "C1–C5 are GREEN" rests on a single observer.** The re-review of
    fix round 3 re-ran nine of nineteen probes and not these, so the measured
    cost of Ruling 26 has one observer. Pointer: ledger, the closing section of
    the Task 12 fix-round-3 re-review entry.

14. **The sweep guard remains nominal.** Pointer: ledger, Task 10/11 entries.

## D. Things that are NOT yours to do

- **Do not start the Docker rig.** It may only be started from the main checkout,
  `/Users/noidee/macSCP`, and this session cannot reach it. The rig is **not
  running** as of 2026-10-22 (checked with `docker ps`: no SSH on 2222, no store
  on 19000). So `MACSCP_ITEST=1 swift test`, the second half of the plan's
  Step 8, **cannot run here**. Run the ungated `swift test` and record plainly,
  in your report and in the commit message, that the gated suite was not run and
  why. Do not report Step 8 as done.
- **Do not reset the rig's volume.** Whether to reset it to clear
  `macscp-probe-lock` is an outstanding maintainer decision. Step 3's row records
  the leftover; it does not resolve it.
- **Never touch the rig buckets `macscp-seed`, `macscp-second` or
  `macscp-probe-lock`**, and never put a COMPLIANCE retention on any bucket meant
  to be deleted.
- **Do not fix the warnings and do not edit `.github/workflows/ci.yml`** (the
  plan's Step 6 says this itself, and it is still true).
- **Do not push anything.** Not this repository, not the docs repository.
- **The user documentation is not yours.** A separate dispatch owns
  `/Users/noidee/_dev/noix-docs`. Do not write there.
- **Do not re-sweep `docs/BACKLOG.md`'s row numbers.** The census section already
  names them stale and says the fix is a sweep of its own. The plan's Step 5 says
  so too.
