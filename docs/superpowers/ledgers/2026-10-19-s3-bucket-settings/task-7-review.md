# Task 7 review: the connection-level action seam

Reviewed `f3ec6e07..46bfdebb` (one commit). Read-only on this checkout except
through `scripts/mutation-probe`, which reverts; `git status --porcelain`
printed nothing before the first probe and nothing after the last.

**Note on HEAD.** While this review ran, `abd2eff2` landed on the branch
("docs: the empty-seam anti-goal pointed at a withdrawal and counted one too
many"), docs-only — `git show --name-only abd2eff2` lists exactly
`docs/superpowers/specs/2026-10-19-s3-bucket-settings-design.md`. It is the
controller acting on the implementer's concern 2 and finding a second error in
the same bullet. Every probe below therefore ran on `abd2eff2`'s tree, whose
code is byte-identical to `46bfdebb`'s.

## Spec Compliance

- ✅ **Spec compliant** against the brief, with two disclosed deviations that
  are improvements, and one extra key.

Checked item by item:

| Brief | Verdict |
|---|---|
| `ConnectionActionContribution` with exactly `id`/`titleKey`/`titleDefault`/`systemImage`, `Sendable, Equatable, Identifiable`, public memberwise init | ✅ `BackendContributions.swift:14-34` |
| `public let connectionActions: [ConnectionActionContribution]` on the descriptor | ✅ `BackendDescriptor.swift:125` |
| S3's four ids `s3.createBucket`, `s3.versioning`, `s3.cors`, `s3.objectLock`, in that order | ✅ `BackendDescriptor.swift:511-523`; pinned by `BackendContributionTests.s3OffersTheFourBucketActionsInTheOrderTheMenuShowsThem` |
| SSH's and WebDAV's are `[]` | ✅ `BackendDescriptor.swift:489`, `:574` |
| No default; every construction site spells it | ✅ 11 sites + the declaration, measured below |
| `ConnectionActionsMenu` as a `Menu` over the list, titles via `L10n.string(titleKey, titleDefault)` | ✅ `ConnectionActionsMenu.swift:29-49` |
| `isPresented(for:)` is `!connectionActions.isEmpty` | ✅ `ConnectionActionsMenu.swift:27-29` |
| `BoundedView` only if it declares a width | ✅ declares none; not a `BoundedView` |
| First in `ToolbarItemGroup(placement: .primaryAction)`, rendered only when presented | ✅ `ContentView+Lifecycle.swift:63-67`, before `uploadButton` at `:68` |
| Four catalogue entries × 4 locales | ✅ (five keys — see below) |
| Brief's three tests | ✅ present, two adapted (deviation 1) |

Deviations, all disclosed in the report and all defensible:

1. The brief's `BackendDescriptor.sshDescriptor` / `.webDAVDescriptor` spelling
   became `descriptor(for: .ssh)` / `(for: .webdav)`. The brief's symbol
   `webDAVDescriptor` does not exist (the tree spells it `webdavDescriptor`,
   `BackendDescriptor.swift:544`). Deriving through `descriptor(for:)` is also
   what CLAUDE.md's "a guard that spells a symbol it could read instead" asks
   for. Better than the brief.
2. A fifth catalogue key, `connection.actions.menu`, for the menu's own label.
   The brief names no label; a `Menu` needs one. Justified extra.

Extra tests beyond the brief's three (7 in `ConnectionActionsMenuTests`, 5 in
`BackendContributionTests`) are not over-engineering: they are the positive
checks CLAUDE.md requires beside the negative ones, plus the catalogue
coverage Step 7 implies.

- ⚠️ **Cannot verify from this diff** — two cross-task gaps the controller must
  assign; both are raised as Important below rather than left here, because
  neither has an owner in any later brief: the replacement of `onSelect: nil`,
  and spec §6.1's bucket-list-mode-only gate on Create Bucket.

## Checks I ran

**The no-default ruling, executed exactly.**
`grep -rn 'BackendDescriptor(' Sources Tests --include='*.swift'` prints 12
lines: 3 in `BackendDescriptor.swift` (`:460`, `:495`, `:544`), 8 in
`Tests/macSCPCoreTests`, and one false positive that is a test function name
(`Tests/macSCPAppKitTests/ImportFromSourceViewModelTests.swift:601`). So 11
construction sites. `grep -ro 'connectionActions: ' Sources Tests
--include='*.swift' | wc -l` prints 12 = 1 declaration + 11 sites. The
report's figures reproduce. (The report used `grep -rn … | wc -l`, which
counts lines; here occurrences equal lines — I measured both.)

**The withdrawn header paragraph is quoted verbatim.** Extracted both sides to
files and diffed:
`git show f3ec6e07:Sources/macSCPCore/Capabilities/BackendDescriptor.swift |
sed -n '8,11p' | sed 's|^/// ||'` against the indented block at
`BackendDescriptor.swift:12-15` with `^///     ` stripped — `diff` is silent,
261 bytes on each side. Line breaks preserved.

**The replacement asserts nothing unmeasured, and nothing about what the four
actions do.** `BackendDescriptor.swift:17-32` makes three claims, all true:
`onlyS3ContributesConnectionActions` "pins how many" (it asserts `count == 4`);
`theSeamIsNotEmptyInEveryBackend` "fails if every backend's list ever empties"
(probe F below); and the no-default rationale, which matches the tree. It does
**not** claim the actions work, open anything, or are reachable. One soft spot
is noted as Minor m3.

**`theSeamIsNotEmptyInEveryBackend` is a real guard, not a comment that runs.**
It is a *positive* assertion (`#expect(total > 0)`), the kind CLAUDE.md says
cannot go stale in silence, and it derives its descriptors from
`ConnectionKind.allCases` + `descriptor(for:)` rather than naming any
descriptor. Probe F turned it red. Caveat worth stating: it is strictly weaker
than `onlyS3ContributesConnectionActions` (`count == 4`), so it will never be
the only red — it earns its place as the written form of the anti-goal, not as
extra detection.

**Negative checks are paired, and the scans cannot read comments.**
`theMenuNamesNoBackendKind` (`ConnectionActionsMenuTests.swift:104-111`) is the
only test with negative checks (`!contains("ConnectionKind")`, `.s3`, `.ssh`,
`.webdav`); the positive `#expect(menu.contains("connectionActions"))` sits
immediately above them. Both placement scans `#require` both anchors before
comparing positions, and `toolbarGroup()` returns `nil` (→ `#require` failure)
rather than an empty string when the group is gone. Every scan reads
`SourceCorpus.code(of:)`, which is
`SwiftSource.blankingCommentsAndStrings` (`Tests/MacSCPTestSupport/SourceCorpus.swift:130-132`)
with a length check — so the long explanatory comment at
`ContentView+Lifecycle.swift:56-62`, which describes the menu in prose, cannot
satisfy or trip them. This is exactly the collision CLAUDE.md's
"Source-scanning guards read comments too" is about, and it was avoided.

**Literals vs derived names in the tests.** Nothing in either test file spells
a catalogue key or an English title: titles come from the descriptors, locales
from one private list, and `theEnglishCatalogueSaysTheDefault` holds
`titleDefault` and the `en` catalogue to one string. The four ids are spelled
once, in the order test, which is that test's subject. The
`#filePath` + three `deletingLastPathComponent()` repo-root derivation matches
the established pattern in this target (`AuditLogSortWiringGuardTests.swift:50-55`,
`BucketListTransferGuardTests.swift:42-43`, and others), so it is house style,
not a second copy.

**Mutation probes: all six reproduce, with identical catcher sets.** The report
commits no `--apply` commands (Minor m1), so I reconstructed each plant from
its table row; each ran through `scripts/mutation-probe`, tree clean before and
after:

| Plant | Result | Caught by |
|---|---|---|
| A: `if ConnectionActionsMenu.isPresented(for: descriptor) {` → `if true {` | RED, 7 ran | `theMenuIsConstructedOnlyWhereItIsPresented` |
| B: `let _ = uploadButton(in: activeTab, session: session)` inserted before the menu | RED, 7 ran | `theMenuIsTheFirstThingInThePrimaryActionGroup` |
| C: `static let planted = ConnectionKind.s3` added to the view | RED, 7 ran | `theMenuNamesNoBackendKind` |
| D: `isPresented(for:)` body → `true` | RED, 7 ran | `aBackendWithNoActionsRendersNoCapsule`, `presentationIsExactlyANonEmptyList` |
| E: `connection.action.objectLock` deleted from `pl.lproj` | RED, 7 ran | `everyActionTitleResolvesInAllFourLocales` |
| F: S3's list → `[]` | RED, 5 ran | all five `BackendContributionTests` |

Control runs reported 7 (or 5) tests and 0 pre-existing failures each time, so
no verdict rode on the `ViewTestabilitySpike` red.

**A seventh probe, mine, came back GREEN** — see Important I1.

**Localization.** All five keys present exactly once in all four locales:

    for k in connection.actions.menu connection.action.createBucket \
             connection.action.versioning connection.action.cors \
             connection.action.objectLock; do
      for l in en de fr pl; do
        grep -c "^\"$k\" = " Sources/MacSCPAppKit/Resources/$l.lproj/Localizable.strings
      done
    done

prints `1` twenty times. No display string is hardcoded in the view: both the
row titles and the menu label go through `L10n.string`, and `systemImage`
values are SF Symbol names, not text. The German catalogue needs no address
form — all four German strings are noun phrases or an infinitive ("Bucket
erstellen…"), so there is no `du`/`Sie` choice to get wrong, and
`GermanAddressFormTests` has nothing to object to. The fifth key is covered for
catalogue parity by the pre-existing `LocalizationParityTests`, which derives
its catalog locations and locales rather than listing them, not by the new
tests. The French entry uses the curly apostrophe (`d’objet`), which is the
majority style in that file (409 curly vs 47 `d'`).

**The two reported compiler warnings — measured on the DEFAULT build system,
and the report undercounts them.** Cold build, fresh scratch path, no
`--build-system` flag, from the worktree root:

    swift build --target macSCPCoreTests \
      --scratch-path /private/tmp/.../scratchpad/cold-default

`Build complete!`, then with ANSI stripped, `grep -n 'warning:'` and
`grep -n 'originates here'` give **seven distinct warnings at four sites** (each
printed twice, once in the header line and once inside the expansion box):

- `Tests/macSCPCoreTests/ArchiveRunnerTests.swift:82:76` — "no calls to
  throwing functions occur within 'try' expression"
- `Tests/macSCPCoreTests/S3CreateBucketTests.swift:54:49` — "expression of type
  'Bool?' is unused" **and** "left side of nil coalescing operator '??' has
  non-optional type 'String?'"
- the same pair at `S3CreateBucketTests.swift:65:56`
- the same pair at `S3CreateBucketTests.swift:84:51`

So: they **do** appear on the default build system — I did not need a
`--build-system native` run to settle it — and the report's "`S3CreateBucketTests.swift:84`
emits two compiler warnings" names one of three sites. All three are the same
construct, `#expect((… .url?.query ?? "").isEmpty)`. Not fixed, per
instruction.

One further measurement, because the report attaches a CI risk to this: the
gate at `.github/workflows/ci.yml:179-189` counts lines matching
`^[^[:space:]]+:[0-9]+:[0-9]+: warning:`. These warnings are reported against
the macro expansion buffer — the header line reads
`macro expansion #expect:1:75: warning: …`, whose prefix contains spaces, and
the second copy is indented — so the gate's own grep run against my log returns
**0** locations:

    /usr/bin/grep -E '^[^[:space:]]+:[0-9]+:[0-9]+: warning:' bd-plain.log | sort -u | wc -l   # 0

That is consistent with the earlier withdrawal this branch already made, and it
means the warnings are real but invisible to `MAX_WARNINGS: 0` as written.

**The second false comment: correct find, correct fix.** At BASE the `apply`
doc said "the one synthetic descriptor, in `SchemaConformanceTests`".
`grep -rn 'apply:' Tests --include='*.swift'` returns exactly 8 lines — five
passing `apply: { _, _ in }` (`ConnectionDiagnosticsTests:1760`,
`ICMPEchoTests:538`, `NetworkTraceTests:939`, `ResolveNamesTests:535`,
`SchemaConformanceTests:25`) and three passing `ssh.apply`
(`ConnectionDiagnosticsJumpTests:1766`, `ThroughputProbeTests:603`,
`InternetSpeedProbeTests:639`). The withdrawn count was wrong, the replacement
at `BackendDescriptor.swift:59-63` quotes the wording verbatim ("the wording
'the one synthetic descriptor' is withdrawn: it was not the only one") and
writes no new number. The pre-existing "three real descriptors" in the same
sentence is still correct.

**The implementer's BASE sweep reproduces.**
`git grep -n -i -e 'ossify' -e 'connection-level' -e 'connection level' -e 'action list' -e 'unused seam' f3ec6e07 -- 'Sources/*.swift' 'Tests/*.swift' CLAUDE.md`
hits `Sources` in exactly one place, the header at `:8` and `:10` — as
reported. (It also hits one unrelated test comment,
`SheetOverflowMenuWiringGuardTests.swift:239`, "an empty action list", about a
different menu; the report's claim was scoped to `Sources` and is accurate.)

**Third site for the same claim: found one, in the plan.**
`docs/superpowers/plans/2026-10-19-s3-bucket-settings.md:631` still reads "A
synthetic descriptor exists in `SchemaConformanceTests` and needs it too."
Minor m4 — it is incomplete rather than false, which is why I grade it low.
Nothing in `docs/BACKLOG.md` records the M22 deletion
(`grep -n -o -i -e 'connection-level action' -e 'ossify' docs/BACKLOG.md`
returns nothing), so no backlog row is owed.

**The `ViewTestabilitySpike` red is not this diff's.** I did not re-run it.
Structurally: `ViewTestabilitySpike.swift:195-203` renders a local
`searchField(text:isRegex:errorText:)` and compares bitmaps; nothing in this
diff is in its reach, and the file is not in the diff. Set aside.

**`connectionViewModel.kind` is the right source.** Named risk: the menu's
presence derives from `activeTab.connectionViewModel.kind`
(`ContentView+Lifecycle.swift:63-64`) rather than from the live session, so a
form edit in a connected tab could in principle move it. Checked: that is the
house source for "which backend is this tab" everywhere else —
`TabStripView.swift:701` (the protocol badge), `ContentView.swift:1005`
(`activeTabSupportsShell`), `ContentView+Diagnostics.swift:55`. Precedent
followed; no finding.

## Strengths

- The controller's no-default ruling is executed without a shortcut: 11 sites
  spelled, `[]` at the eight synthetic ones, and the header explains *why* the
  cost is being paid rather than apologising for it
  (`BackendDescriptor.swift:27-32`, `:118-124`).
- The withdrawal is byte-exact. 261 bytes on each side of a `diff` is the
  strongest form of CLAUDE.md's "a correction quotes what it withdraws", and it
  is what let the controller find a *second* error in the spec bullet the next
  day.
- Every source scan reads the comment-and-string-blanked view, and the one test
  with negative checks has its positive check in the line above. Probes A–F
  reproduce with the exact catcher sets claimed — six for six, including the
  five-way catch on plant F.
- The second false comment was a real find, in a different file from the
  change, which is precisely where CLAUDE.md says the damage hides.
- The report is honest where it is weakest: it volunteers the disabled rows,
  the missing §6.1 gate, the stale spec pointer and the untested `.disabled`
  line. Three of those four turned out to be the findings below, which means
  the disclosure was accurate rather than decorative.

## Issues

### Critical (Must Fix)

None.

### Important (Should Fix)

**I1 — The one user-visible decision this commit makes is unguarded; probe
GREEN.** `Sources/MacSCPAppKit/ConnectionActionsMenu.swift:41`
(`.disabled(onSelect == nil)`). I planted its removal:

    scripts/mutation-probe --filter ConnectionActionsMenuTests \
      --label 'G (reviewer): .disabled(onSelect == nil) removed from the rows' \
      --apply 'perl -ni -e "print unless /^                \.disabled\(onSelect == nil\)\$/" Sources/MacSCPAppKit/ConnectionActionsMenu.swift'

    RESULT: GREEN — 7 test(s) ran and NONE of them noticed the plant.

Every other decision in this file is mutation-caught; this one is not. It also
is not an incidental detail: "disabled rather than enabled and inert" is a
named rule in this tree, spelled out at `Sources/MacSCPAppKit/MacSCPApp.swift:144-148`
("a menu entry that is enabled and does nothing is exactly what
`PaneToggleState`'s own doc comment rules out"), and the implementer cites that
rule as the reason for the line. A rule worth citing is worth pinning. The fix
is one line in a test that already scans this file with `SourceCorpus.code`:
`#expect(menu.contains(".disabled(onSelect == nil)"))`, which goes stale loudly
because the positive `connectionActions` check beside it fails if the file is
gutted. Severity: Important rather than Minor because the project's own
standard for this class of decision is a guard, and because the line is the
whole of what a user meets on this commit.

**I2 — `onSelect: nil` has no owner in any later brief.**
`Sources/MacSCPAppKit/ContentView+Lifecycle.swift:66`. The report says "Task 8
should replace the `nil`". Task 8's brief does not: its file list is *Create*
`BucketVersioningSheet.swift`, *Modify* `ContentView+MenuActions.swift`, *Test*
`BucketVersioningSheetTests.swift`
(`docs/superpowers/plans/2026-10-19-s3-bucket-settings.md`, Task 8), and its
Step 4 is "Wire the contribution id … in `ContentView+MenuActions.swift`,
beside the existing `s3.presignedURL` arm". Nothing in it touches
`ContentView+Lifecycle.swift`. An implementer following that brief literally
adds a dispatch arm that nothing calls, and all four rows stay disabled for the
rest of the plan. **Controller action, not a Task 7 code change**: add the
`onSelect:` replacement to Task 8's file list and steps, or state where it
lands. I am raising it as Important because this is the failure mode where a
deliberately inert seam ships inert — the exact history the rebuilt header is
about.

**I3 — Spec §6.1's gate has no consumer either, for the same reason.** Spec
§6.1: "**the action is therefore offered in bucket-list mode only**". Deferring
it out of Task 7 is **acceptable** — spec §5 fixes this seam as "one list on
the descriptor" read without switching on `ConnectionKind`, and says nothing
about per-action availability, so inventing an availability hook here would
have been the over-engineering the rubric warns about. But the gate Task 11
carries is a *model* predicate, `CreateBucketModel.isOffered(rootMode:)`
(Task 11, Step 1, `theActionIsOfferedOnlyInBucketListMode`), and Task 11's file
list is `CreateBucketSheet.swift` + its test — nothing renders or consumes it,
and the menu row has no route to a `RootMode`. It is **not** the same gate as
Task 11's other contract: `aNameAlreadyInTheListBlocksTheButton` is an in-sheet
check on a typed name against a list the sheet already holds, which is a
different question from whether the row is offered at all. So two distinct
gates are specified, one of them has nowhere to attach, and on today's tree
`s3.createBucket` is listed in single-bucket mode where a created bucket would
be invisible. **Controller action**: decide whether the seam grows an
availability predicate (a `isAvailable: @Sendable (…) -> Bool` on the
contribution, or a filter applied by the toolbar) or whether Task 11 also owns
the menu-side wiring, and write it into a brief.

**I4 — The report's warning figure is wrong, and it is the kind of figure this
project has a rule for.** Report concern 5(b) says
"`S3CreateBucketTests.swift:84` emits two compiler warnings … in the build log
of every run". Measured on the default build system, cold (command and output
above): the same two warnings appear at **three** sites in that file — `:54`,
`:65`, `:84` — six warnings, not two, plus one unrelated at
`ArchiveRunnerTests.swift:82`. The report's own stated method
(`grep -n 'warning:' <green log>` then look for `S3CreateBucketTests`) would
have shown all three; the figure was written from one site rather than from the
command's output, which is the shape CLAUDE.md's "A number travels with the
command that produced it" and "A report says what the diff shows" both
describe. The accompanying CI concern also overstates the risk: the gate's grep
cannot see any of them (0 locations, measured above). Fix the report's figure,
not the warnings.

### Minor (Nice to Have)

**m1 — The probe table commits no commands.** The six rows give results and
catchers but no `--apply`, so the figures cannot be re-run as committed; I
reconstructed all six by hand, which is exactly the retyping hazard CLAUDE.md's
"the command must run in the form it is committed" exists to prevent. All six
reproduced, so nothing was wrong — but that was luck I had to buy. Paste each
`--apply` into the report's table or a code block beneath it.

**m2 — A false comment two lines above the added type, in a file the diff
touches.** `Sources/macSCPCore/Capabilities/BackendContributions.swift:3-4`:
"empty for ssh/s3 now — S3 presigned URL lands in M14", while
`BackendDescriptor.swift:508-510` gives `s3Descriptor` a `fileActions` entry
`s3.presignedURL`. Disclosed in report concern 5(c) and left. If any file in the
tree is covered by "search in the same pass for comments that describe it", it
is the one being edited; correcting it costs one line and the commit already
carries a correction of the same kind.

**m3 — A present-tense claim about code that does not exist.**
`BackendContributions.swift:20`: "`id` is the dispatch key -- the window routes
by it and never by `ConnectionKind`". Nothing routes by it in this commit
(`onSelect: nil`). True of `FileActionContribution`, aspirational here. "will
route" or a pointer to the task that does it would be accurate.

**m4 — Third site for the synthetic-descriptor claim, uncorrected.**
`docs/superpowers/plans/2026-10-19-s3-bucket-settings.md:631` reads "A synthetic
descriptor exists in `SchemaConformanceTests` and needs it too". Unlike the
source comment, this is incomplete rather than false — one does exist there and
did need it — but it reads as exhaustive and it is what seeded the undercount.
The controller corrected the sibling error in the spec in `abd2eff2`; this line
was not in that commit.

**m5 — A named exclusion that excludes nothing.** The report derives the
synthetic-`apply` count as "`grep -n 'apply:' Tests/macSCPCoreTests/*.swift`
minus `BackendApply*`". `grep -rn 'apply:' Tests --include='*.swift'` returns
exactly the 8 synthetic lines and no `BackendApplyTests` match at all (that file
calls `.apply(values, &session)`, never `apply:`), so the subtraction removes
zero. Harmless here, but CLAUDE.md asks for exclusions "named one by one, so the
next reader lands on the same starting set" — an exclusion for a set that is
empty sends the reader looking for lines that are not there.

**m6 — One catalogue key spelled twice, for two purposes that want different
text.** `ConnectionActionsMenu.swift:45` and `:48` both call
`L10n.string("connection.actions.menu", "Connection Actions")`, once for the
`Label` and once for `.help`. Two copies of the key literal, and a tooltip that
repeats its own label verbatim tells the user nothing. Hoist to a `let`, and if
the tooltip is worth having, give it its own key.

**m7 — The no-kind scan's span is one file, where the rule is about the
window.** `ConnectionActionsMenuTests.theMenuNamesNoBackendKind` scans only
`Sources/MacSCPAppKit/ConnectionActionsMenu.swift`. Spec §5's rule is that
"the window reads it without switching on `ConnectionKind`", and the window half
lives in `ContentView+Lifecycle.swift`, where a `switch kind` added beside the
menu would satisfy both placement scans. **Unmeasured — I did not plant this**,
so treat it as a reading of the scan's span, not a demonstrated hole. Probe C
proves the view half is sensitive.

**m8 — "CORS Rules…" is the better title, and the brief's phrase was the
weaker one.** Copy judgment, asked for explicitly. "Cross-Origin Rules…" is not
a term any S3 console, SDK or document uses; it reads as a translation of an
acronym rather than a name, so a reader who does not know CORS learns nothing
from it and a reader who does has to work out that it is the same thing. AWS
labels this surface "Cross-origin resource sharing (CORS)" — acronym present,
expansion attached. For a toolbar row, "CORS Rules…" is right: short, the term
the person who came looking for it already types, and consistent with the
German and Polish entries, which also keep the acronym. The expansion belongs
in the sheet (Task 9), one line under its title, where there is room to say
what it does; the title is the wrong place to teach the term. No change asked
for here.

## The disabled-rows question

Asked for as a judgment call, so stated plainly: **committing the menu with
four permanently disabled rows is the right state for this commit, and the
obligation it creates is not written down anywhere.**

Why rendering it is right. The alternative — withhold the menu until one row
works — withholds the one thing this task exists to settle. Spec §5 records that
the maintainer "asked for it on 2026-10-12 and confirmed its placement on
2026-10-19: its own capsule in the toolbar's free area, left of the existing
icon group", from a screenshot. Placement is this task's deliverable; a seam
that renders nothing leaves it unverifiable by eye and needs a second wiring
change later. And of the two ways to render a row with no handler, the one
chosen is the one this tree has a written rule for
(`MacSCPApp.swift:144-148`): disabled, not enabled-and-inert.

Why it is not free. On this commit a user connecting to S3 meets a toolbar
capsule whose four entries are all grey, with no per-row explanation of why —
the `.help` text repeats the menu's own name (m6). "Disabled so you can see why
the click does not land" is only honest when something says why, and nothing
does. That is tolerable for an intermediate commit on an unreleased branch and
intolerable in a release, and nothing in the tree currently distinguishes those
two cases: there is no `docs/BACKLOG.md` row, and the plan's closeout does not
mention the `nil`. Combined with I2 — no later brief owns replacing it — the
realistic failure mode is not "someone argues about greyed rows" but "nobody
removes the `nil` and the branch closes with a dead control". The fix is I2, not
a change here.

## Assessment

**Spec compliance:** ✅ Spec compliant (two improving deviations, one justified
extra key, both disclosed).

**Task quality:** Approved with fixes — I1 and I4 are in this task's hands; I2
and I3 are controller assignments to later briefs and should not be rolled into
Task 7.

**Reasoning:** The ruling the controller made is executed literally and the
history it protects against is written into the header with a byte-exact
withdrawal; the guards are paired, derive their names from the types, read the
blanked source view, and all six of the implementer's probes reproduce with the
exact catcher sets claimed. What is missing is narrow and specific: the single
line that encodes this commit's user-visible behaviour is the one decision no
test notices (probe GREEN), the reported warning figure names one of three
sites on the default build system, and the two deferrals the report discloses
turn out to have no owner in any later brief.
