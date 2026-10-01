# Splitting the two diagnostics files Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `ConnectionDiagnostics.swift` (1538 lines) and
`JumpProbes.swift` (1034) along the responsibility boundaries their own
`MARK` comments already draw, as two **pure moves**, with the comments and
the one guard that name them corrected in the same commits.

**Architecture:** No behaviour changes, no access-level changes, no renames.
Every moved declaration keeps its text; only the file it lives in changes.
The actor is split through extensions in the same module, so nothing becomes
`internal` that was `private`.

**Backlog row:** "`ConnectionDiagnostics.swift` and `JumpProbes.swift` want a
split, and it is a task of its own" (recorded 2026-09-27).

## Global Constraints

- Build and test with `swift test --build-system native`. The default build
  system fails on SwiftTerm's `Shaders.metal`.
- Swift 6 language mode; zero new warnings (CI's budget is 0).
- **A pure move is reviewable only as a pure move.** No commit in this plan
  may change behaviour, an access level, a name, or a signature. If something
  must change to compile, it goes in its own commit with its own reason.
- A number or an enumeration written into a comment is counted in that same
  moment.
- Changing which file a declaration lives in means searching, in the same
  pass, for comments that name that file — including in files the diff does
  not touch.
- `docs/` plans and specs that cite these files are dated measurement
  records of a past tree and are **left alone**.
- English code, comments and commit messages. Conventional Commits. Footer
  exactly `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`;
  "Claude Fable 5" in no commit message.

## The measurement this rests on

Counted at `0bc201e1` on 2026-10-01, and matching the row's own figures:
`ConnectionDiagnostics.swift` **1538** lines, `JumpProbes.swift` **1034**.
The next largest file in `Sources/macSCPCore/Diagnostics/` is
`NetworkTrace.swift` at **728**, so these two are 2.1× and 1.4× it.

**Who names these files, measured rather than assumed.**
`ConnectionDiagnostics.swift`: 19 references outside itself, 8 of them with a
line number — **all 19 in `docs/`**, which are dated records and stay. No code
comment names it.
`JumpProbes.swift`: 8 references, of which **four are in code or tests** —
`Sources/macSCPCore/Diagnostics/DiagnosticJump.swift:325`,
`Sources/macSCPCore/Diagnostics/DiagnosticStep.swift:140`,
`Sources/macSCPCore/Diagnostics/ConnectionDiagnostics.swift:748`, and
`Tests/macSCPCoreTests/SnippetCommandSurveyTests.swift:920`.

**The one that would have broken quietly, and why this is a task of its
own.** `SnippetCommandSurveyTests` keeps two hard-coded file-name lists:
`shellLexingFileNames` (`:890`, files that lex and must not name
`Character`) and `shellCallerFileNames` (`:913`, files that only hand a value
to `PosixQuoting.singleQuoted`). `JumpProbes.swift` is on the second, and the
list's doc comment states the reason in terms of **both** halves this plan
moves out: that it hands a target host to `PosixQuoting.singleQuoted`, and
that its `Character` use is in reading the tools' output back.

Two consequences, and they differ in kind:
- The guard at `:968` builds `Set(shellLexingFileNames + shellCallerFileNames)`
  and checks that every file mentioning the shell-lexing code is classified.
  That is a POSITIVE check, so a new file goes **red loudly** — good.
- The surviving `"JumpProbes.swift"` entry and its stated reason would go
  **stale silently** if what justified it no longer lives there. That is the
  one this plan has to catch by hand.

## File Structure

### `JumpProbes.swift` (1034) → three files

The file's own `MARK` comments draw the boundaries:

| new file | what moves | lines |
|---|---|---|
| `JumpProbeCommand.swift` | `MARK: The host a command may be handed` + `MARK: The command lines` — `JumpProbeHost` (`:54`), `JumpProbeCommand` (`:125`) | 30–255, ~226 |
| `JumpProbeReading.swift` | `MARK: Reading what the tools printed` — `JumpResolvedAddress`, `JumpPingSummary`, `JumpProbeCompletion`, `JumpProbeTranscript`, `JumpProbeReading` | 256–721, ~466 |
| `JumpProbes.swift` (stays) | `MARK: The three steps` — `extension DiagnosticJumpStep` (`:724`), `JumpProbeRun` (`:908`) | 722–1034, ~313 |

### `ConnectionDiagnostics.swift` (1538) → four files

| new file | what moves | lines |
|---|---|---|
| `DiagnosticScope.swift` | `DiagnosticScope` (`:38`) | 38–173, ~136 |
| `ConnectionDiagnostics+Jump.swift` | `MARK: Through a jump host` (`:736`–`:1054`) as an `extension ConnectionDiagnostics`, plus the private helpers `Walk` (`:1433`), `HeldJumpConnection` (`:1498`), `JumpHandoff` (`:1515`) | ~425 |
| `ConnectionDiagnostics+UniversalSteps.swift` | `MARK: The universal steps` (`:1055`–`:1359`) as an `extension ConnectionDiagnostics`, plus `DiagnosticTraceColumn` (`:174`), which only the trace rendering reads | ~353 |
| `ConnectionDiagnostics.swift` (stays) | `DiagnosticRunObserver` (`:222`), the actor's stored properties and `init`, the three `run` entry points, `contributions`, the internet-speed and throughput sections, and `MARK: The seam` | ~624 |

**Why extensions and not new types:** `private` members of a type are visible
to extensions **in the same file only**. Several moved methods are `private`
and call other `private` members. Swift's rule is that `private` at type
scope is file-scoped, so a `private func` moved into another file can no
longer see the actor's `private` state. **This is the one thing that could
force a non-move change**, and Task 2 Step 2 measures it before anything is
written rather than discovering it halfway.

---

### Task 1: split `JumpProbes.swift`

**Files:**
- Create: `Sources/macSCPCore/Diagnostics/JumpProbeCommand.swift`
- Create: `Sources/macSCPCore/Diagnostics/JumpProbeReading.swift`
- Modify: `Sources/macSCPCore/Diagnostics/JumpProbes.swift`
- Modify: `Tests/macSCPCoreTests/SnippetCommandSurveyTests.swift`
- Modify: `Sources/macSCPCore/Diagnostics/DiagnosticJump.swift:325`,
  `Sources/macSCPCore/Diagnostics/DiagnosticStep.swift:140`,
  `Sources/macSCPCore/Diagnostics/ConnectionDiagnostics.swift:748`

- [ ] **Step 1: Record the baseline**

```bash
swift test --build-system native 2>&1 | tail -3
wc -l Sources/macSCPCore/Diagnostics/JumpProbes.swift
```
Write both numbers into the report. The suite is the invariant this task may
not move.

- [ ] **Step 2: Move the two sections, text unchanged**

Cut lines 30–255 into `JumpProbeCommand.swift` and 256–721 into
`JumpProbeReading.swift`, each with the file header comment style the
neighbours use, and each keeping the `MARK` that introduced it. Carry every
`import` the moved code needs — and only those.

Do not reformat, do not reorder declarations, do not change an access level.
The one thing you may add is a file-leading doc comment saying what the file
holds and that it came out of `JumpProbes.swift` on 2026-10-01.

- [ ] **Step 3: Build, and let the guard fail**

```bash
swift test --build-system native --filter SnippetCommandSurvey 2>&1 | tail -6
```
Expected: RED, because the two new files mention the shell-lexing code and
are on neither list. **Record the exact failure text** — it is the evidence
that the positive check at `:968` works, and this plan's claim about it.

- [ ] **Step 4: Classify the new files, and recount the reason**

Put each new file on the right list and **rewrite the doc comment above
`shellCallerFileNames`**: today it justifies `JumpProbes` with the quoting
AND the `Character` use, which after this task live in two different files.
Say which file does which. If `JumpProbes.swift` no longer belongs on either
list, take it off and say so — an entry whose reason has moved out is the
silent staleness this task exists to prevent.

Count the entries on both lists after your edit and make any number in that
comment match.

- [ ] **Step 5: Correct the three prose comments**

`DiagnosticJump.swift:325`, `DiagnosticStep.swift:140` and
`ConnectionDiagnostics.swift:748` each name `JumpProbes.swift` for something
specific. Read each in context and point it at the file that now holds what
it means. Then re-grep:

```bash
grep -rn "JumpProbes.swift" Sources/ Tests/ | grep -v "^Sources/macSCPCore/Diagnostics/JumpProbes.swift:"
```
Every remaining hit must be true of the tree.

- [ ] **Step 6: Prove it is a pure move**

```bash
swift test --build-system native 2>&1 | tail -3
git diff --stat
git diff -M --summary
```
The suite must match Step 1's count exactly. Then, for each moved section,
diff the moved text against the original to show nothing changed:

```bash
git show HEAD:Sources/macSCPCore/Diagnostics/JumpProbes.swift | sed -n '30,255p' > /tmp/before.txt
sed -n '<new range>' Sources/macSCPCore/Diagnostics/JumpProbeCommand.swift > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt
```
Report the diff output. If it is not empty, say exactly what differs and why.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -F - <<'MSG'
refactor(diagnostics): JumpProbes splits into the command lines, the reading, and the steps

<what the diff shows: the three line counts, the guard's red text from
Step 3 and how you classified the new files, the three prose comments you
corrected, and the empty diffs that prove the move was pure>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Correction, 2026-10-01, before Task 2 was dispatched

Measuring Task 2's premises — which Task 1's implementer and reviewer both
asked for independently — changed three of them. The task description below
is superseded where they conflict.

**1. `ConnectionDiagnostics.swift` cannot be split as a pure move at all.**
Swift's `private` is file-scoped at type scope, so a `private` member moved
into another file loses sight of the actor's other `private` members. Counted
at `5cf965de`: the actor has **16** private stored properties, **11** of them
used by the sections that would move (`descriptor`, `values`, `secrets`,
`sessionID`, `stepTimeout`, `traceTimeout`, `appVersion`, `jump`, `jumpDialer`,
`jumpDialLaunch`, `lookups`). Task 2 Step 2 was written to catch this during
the task; catching it before dispatch was cheaper.

**The maintainer's decision, 2026-10-01: widen, in a commit of its own.** The
widening and the move are two commits, the widening first and carrying nothing
else, so the move stays reviewable as a move. `internal` does not leave
`macSCPCore`, so nothing changes outside the module.

**2. The widening is 12 declarations, not 14.** `HeldJumpConnection` (4 hits)
and `JumpHandoff` (3) are used **only** inside the jump section, so they move
with it into the same file and stay `private` — measured, not assumed. `Walk`
is used at `:527`, `:599`, `:628` and `:630`, outside the jump section, so it
is the one helper type that must widen. 11 properties + `Walk` = 12.

**3. `DiagnosticTraceColumn` gets its own file.** The table below says it is
read only by the trace rendering. It is read by **13** files, including
`Sources/MacSCPAppKit/Presentation/DiagnosticsViewModel.swift`,
`Sources/macSCPCore/CLI/DiagnoseRendering.swift`,
`Diagnostics/AddressNames.swift`, `InternetSpeedProbe.swift` and
`ThroughputProbe.swift`. A public type with that many readers belongs in a
file of its own, not appended to an extension.

**Also for the record**, since Task 1's text is pushed: its Step 3 cites "the
positive check at `:968`" of `SnippetCommandSurveyTests.swift`. At that base
`:968` is `let classified = Set(…)`; the positive check is `:976`. The claim
about what the check does was right, the line was not.

### Task 2 (revised): widen, then split `ConnectionDiagnostics.swift`

**Commit 2a — the widening, and nothing else.** Change exactly these from
`private` to `internal`: the 11 stored properties named above, and
`private struct Walk` at `:1433`. Nothing else in the diff. No reordering, no
comment rewriting except where a comment states an access level that is no
longer true — and if one does, say which.

**Commit 2b — the pure move**, in the same shape Task 1 used:

| new file | what moves |
|---|---|
| `DiagnosticScope.swift` | `DiagnosticScope` |
| `DiagnosticTraceColumn.swift` | `DiagnosticTraceColumn` |
| `ConnectionDiagnostics+Jump.swift` | the `MARK: Through a jump host` section as an `extension ConnectionDiagnostics`, plus `HeldJumpConnection` and `JumpHandoff`, both still `private` |
| `ConnectionDiagnostics+UniversalSteps.swift` | the `MARK: The universal steps` section as an `extension ConnectionDiagnostics` |
| `ConnectionDiagnostics.swift` (stays) | `DiagnosticRunObserver`, the actor's properties and `init`, the three `run` entry points, `contributions`, the internet-speed and throughput sections, `Walk`, and `MARK: The seam` |

Everything else in the original Task 2 below still applies: the baseline, the
per-section empty diffs, the declaration inventory, the comment sweep, and the
rule that a report says what the diff shows.

**One thing to measure and report rather than assume**, because the ranges
below were taken before Task 1: re-derive the two `MARK` sections' line
numbers from the tree at the commit you start from, and say what they are.

---

### Task 2: split `ConnectionDiagnostics.swift`

**Files:**
- Create: `Sources/macSCPCore/Diagnostics/DiagnosticScope.swift`
- Create: `Sources/macSCPCore/Diagnostics/ConnectionDiagnostics+Jump.swift`
- Create: `Sources/macSCPCore/Diagnostics/ConnectionDiagnostics+UniversalSteps.swift`
- Modify: `Sources/macSCPCore/Diagnostics/ConnectionDiagnostics.swift`

- [ ] **Step 1: Record the baseline**

The suite's count and `wc -l` on the file, as in Task 1.

- [ ] **Step 2: Measure the `private` boundary BEFORE moving anything**

`private` at type scope is file-scoped in Swift, so a `private` member moved
into another file loses sight of the actor's other `private` members. List,
from the tree:

```bash
grep -nE "^    private " Sources/macSCPCore/Diagnostics/ConnectionDiagnostics.swift
```

For each declaration in the two sections being moved (`:736`–`:1054` and
`:1055`–`:1359`), say whether it is `private` and whether its body touches a
`private` member that is **staying**. Report the list with counts.

**If the two sections are self-contained, the move is pure and you proceed.**
If they are not, STOP and report: the minimum change would be widening some
`private` to `fileprivate` or `internal`, which is not a pure move and needs
the coordinator's decision, not yours. Do not widen anything on your own
initiative.

- [ ] **Step 3: Move**

`DiagnosticScope` into its own file. The two `MARK` sections into
`extension ConnectionDiagnostics { … }` in their two files, each keeping its
`MARK` as the file's subject. `Walk`, `HeldJumpConnection` and `JumpHandoff`
go with the jump extension; `DiagnosticTraceColumn` with the universal steps.
Text unchanged, no reordering, no access-level change.

- [ ] **Step 4: Build and test**

```bash
swift test --build-system native 2>&1 | tail -3
```
Must match Step 1's count exactly, with no new warnings.

- [ ] **Step 5: The comment sweep**

```bash
grep -rn "ConnectionDiagnostics.swift" Sources/ Tests/
```
Measured at `0bc201e1`: no code comment names this file, every reference is
in `docs/`. **Verify that is still true** and say so; if a hit appears,
correct it. The `docs/` records stay as they are.

Also check the three symbols the backlog row names — `Walk`,
`HeldJumpConnection`, `JumpHandoff` — for comments elsewhere that say where
they live:

```bash
grep -rn "HeldJumpConnection\|JumpHandoff" Sources/ Tests/ | grep -v "Diagnostics/ConnectionDiagnostics"
```

- [ ] **Step 6: Prove it is a pure move**

As Task 1 Step 6: `git diff -M --summary`, and an empty `diff` per moved
section against the text at `HEAD`. Report the output.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -F - <<'MSG'
refactor(diagnostics): ConnectionDiagnostics splits into the scope, the jump half, and the universal steps

<what the diff shows, including the private-boundary measurement from
Step 2 and the empty diffs>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

### Task 3: closeout

- [ ] **Step 1: Recount every file in the directory**

```bash
wc -l Sources/macSCPCore/Diagnostics/*.swift | sort -rn
```
Write the new figures into `docs/BACKLOG.md`'s row, dated, beside the 1538
and 1034 it was opened with. Say what each new file holds.

- [ ] **Step 2: Record what the split found**

The guard with the two hard-coded file-name lists is the finding worth
keeping: a file-name allowlist is a negative check wearing a positive
check's clothes, and only the completeness check at `:968` made it safe to
split these files at all. Say so in the row, with the file and line.

- [ ] **Step 3: Commit the backlog**

---

## Self-review

**Spec coverage.** Both files are split (Tasks 1 and 2); the one guard and
the three prose comments that name them are in Task 1; the `docs/` records
are explicitly left alone in both.

**Placeholders.** The `<what the diff shows>` markers are deliberate: this
project's rule is that a commit message is written from the diff after the
change, not predicted. Every file, line range, command and expected outcome
is spelled out.

**The one thing that could stop this being a pure move** is Swift's
file-scoped `private`, and Task 2 Step 2 measures it before any text moves,
with an explicit instruction to stop rather than widen.
