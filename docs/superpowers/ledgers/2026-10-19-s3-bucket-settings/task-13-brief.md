### Task 13: Closeout — docs, backlog, and the rig's leftover

**Files:**
- Modify: `docs/BACKLOG.md` (the s3Manager wishlist row, and the row Task 6's
  fix round opened for the unreachable `bucketListEmpty`)
- Modify: `docs/superpowers/specs/2026-09-02-s3-bucket-browser-design.md` (§2
  table, row 2 — see Step 4)
- Create: a page under `/Users/noidee/_dev/noix-docs/src/content/docs/macscp/guide/`

- [ ] **Step 1: Write the user documentation**

One page covering what the new menu does, in plain language, **with no tech-stack terms**. Work in a git worktree on its own branch in `noix-docs`; never touch a branch someone else has open; push or merge only when the maintainer asks. `npm run build` and `npm run check` must both pass.

- [ ] **Step 2: Correct the backlog row in place**

Move create bucket, CORS, Object Lock and versioning from "Missing" to done, naming the commits. **Every withdrawal quotes the wording it replaces.** State what is still missing: metadata editor, ACLs, sync, the version history, and the connection-manager surface.

- [ ] **Step 3: Record the rig's leftover**

A row for `macscp-probe-lock` — the bucket left on the rig under a COMPLIANCE retention until 2026-12-31 — naming that a gated test asserting on the bucket **list** will see it until the volume is reset.

- [ ] **Step 4: Record what Task 6 made unreachable**

**Added 2026-10-19, from Task 6's review.** Task 6 removed the only thrower of
`RemoteFSError.bucketListEmpty`, so three kinds of artifact now describe an
outcome that cannot occur, and this task's file list did not cover any of them:

- `docs/superpowers/specs/2026-09-02-s3-bucket-browser-design.md:44` (§2 table,
  row 2) — a measurement record, so the correction quotes the wording it
  replaces rather than deleting it.
- The four `core.connect.s3BucketListEmpty` catalogue strings (`en`, `de`, `fr`,
  `pl`). **They are not deleted.** The enum case still has consumers — the CLI
  mapping, `DialProbes`, two view models, `TransferFailureKind`, two AppKit
  files — and the localization parity checks read every key a case declares.
  Deleting the strings while the case stands breaks the parity suite; deleting
  the case is a separate decision with its own review.
- The **six** comment sites that describe the case, which Task 6's fix round put
  in a `docs/BACKLOG.md` row rather than in a report only. This step checks that
  row still names them, and corrects it if the count has moved.

  **Corrected 2026-10-20, by Task 6's re-review and verified by the
  controller.** This bullet first read "The five comment sites naming `connect`
  as the case's single thrower". Both halves were wrong. The count was five when
  this bullet was written and became six in the same fix round, which found an
  older site the two reviews had missed (`RemoteFSError.swift` near line 16).
  And "naming `connect` as the case's single thrower" is literally true of only
  two of them — `ConnectionViewModel.swift` near 2310 ("`.bucketListEmpty` is
  connect-time only — `connect` is its single thrower") and
  `RemoteBrowserViewModel.swift` near 1278. The others make different claims:
  near 2307 it is reachability ("both reachable ONLY with `startsAtBucketList`
  on"), near 2319 it is a true description of an arm that is now dead, and
  `RemoteFSError.swift` near 24 describes what the case meant at the form. They
  are all stale, for different reasons, which is why the row names each by its
  opening words rather than under one heading.

The row records the decision, not a fix: keep the case or delete it with its
consumers in one pass. Either way the comments go with it.

- [ ] **Step 5: Pin the census section's live figure to a commit**

**Added 2026-10-19, measured by the controller while closing Task 6.** The
closing census section of `docs/BACKLOG.md` prints three comparable outputs. Two
name a commit and reproduce exactly — re-run on this date they still print
`opens-Open=90 shown=47 hidden=43` and `opens-Open=94 shown=51 hidden=43`, the
recorded figures. The third runs the same `awk` over the live `docs/BACKLOG.md`
and is recorded as `opens-Open=95 shown=52 hidden=43` with no date and no commit
beside it. Run as committed, that third command now prints
`docs/BACKLOG.md opens-Open=137 shown=92 hidden=45`.

So the one figure in that section a reader can check against the working tree is
the one that contradicts it, by 42. **39 of those 42 predate this branch**: the
same command over this branch's base prints `opens-Open=134 shown=89 hidden=45`.
Three are this branch's own rows, one of them Task 6's.

Pin it: give that third line a commit of its own, exactly as its two neighbours
have, and quote the withdrawn bare figure. Do **not** re-sweep the section's row
numbers — the section already names those as stale and says the fix "is a sweep
of its own", and that remains true.

- [ ] **Step 6: Open a row for the warning gate's macro-expansion blind spot**

**Added 2026-10-20, measured by the controller from Task 7's review (I4).** Seven
warnings exist in the Core test target at four sites —
`S3CreateBucketTests.swift:54:49`, `:65:56`, `:84:51` and
`ArchiveRunnerTests.swift:82:76`. They appear on the **default** build system,
measured cold into a fresh scratch path with no `--build-system` flag:

    swift build --target macSCPCoreTests --scratch-path <fresh dir>

`grep -c 'warning:'` over that log prints 14 (each diagnostic twice: once in the
caret diagram, once as its own header), and
`grep -o 'macro expansion #expect:1:[0-9]*' | sort -u | wc -l` prints 7.

CI's gate matches **none** of them. Its pattern is
`^[^[:space:]]+:[0-9]+:[0-9]+: warning:` (`.github/workflows/ci.yml`, the
"Unique warning locations" step), and neither route reaches it:

- The warning's own location is `macro expansion #expect:1:46:` — it contains a
  space, so `[^[:space:]]+` cannot match it.
- The real source location appears only on a `note: expanded code originates
  here` line, which says `note:` and not `warning:`, and begins with a backtick
  and a hyphen rather than a path.

**Corrected 2026-10-20 by Task 8's review, which found a second and more general
cause.** This step first read: "So `MAX_WARNINGS: 0` was never at risk from
these — but the reason is that the gate cannot see a diagnostic reported against
a macro-expansion buffer, and in this repository every test assertion is
`#expect`." That mechanism is real and still stands for this class of warning,
but it is not the only one, and the one it hid is worse.

**The compiler colours its diagnostics even when stdout is a file or a pipe**, so
an ordinary warning line reads `…:82:43: <ESC>[1;33mwarning: …` and the gate's
pattern, which expects `warning:` directly after the location, matches none of
them. Task 8's review measured four actor-isolation warnings in the AppKit test
target that way: **0 of 4** matched on the raw log and **4 of 4** only after
`perl -pe 's/\e\[[0-9;]*m//g'`. CI captures the same way
(`2>&1 | tee "$RUNNER_TEMP/test.log"`, `.github/workflows/ci.yml:123-124`).

The two causes are independent and hit different classes:

- An **ordinary** diagnostic is invisible because of the colour escape. Stripping
  ANSI makes it visible.
- A **macro-expansion** diagnostic is invisible for a second reason on top:
  its location is `macro expansion #expect:1:46:`, which contains a space, and
  the line carrying the real file says `note:` rather than `warning:`. Measured
  on the controller's Core-target log: the gate's pattern matches **0** raw and
  still **0** after stripping ANSI.

So, locally, the gate cannot see a compiler diagnostic at all. **Whether CI's
logs are coloured was not measured** — the reviewer says so explicitly — and
that is the first thing the row's investigation should settle, because it decides
whether `MAX_WARNINGS: 0` has ever held anything. What does not change either
way: the branch is pushable, since nothing it adds matches the gate however the
gate behaves.

Open the row with the commands above and both mechanisms; **do not fix the
warnings and do not edit `ci.yml` in this plan** — the gate's pattern is its own
change with its own review, and it is now a larger change than this step first
implied.

- [ ] **Step 7: Open the Core rows Task 9's review earned**

**Added 2026-10-20 from Task 9's review.** Three findings land in Core, which
Task 9's brief excluded, so each is a row rather than a late edit to a reviewed
task. All three are about `S3SettingsXML` / `CORSRule`:

1. **Move the lossy-parse check into Core.** Task 9 detects a lossy CORS parse in
   the App by re-serializing the parsed rules and comparing element-name and
   attribute-name counts (`ElementCensus`). The reviewer verified the mechanism
   against `CORSDelegate` and 28 constructed inputs — every element `corsBody`
   writes maps injectively back to a distinct consumed element, so equality holds
   **iff every element was consumed**, which is the property itself rather than a
   proxy for it. The problem is where it lives: its correctness depends on
   `CORSDelegate`'s depth bookkeeping one target away, so a change to `parseCORS`
   can falsify the App's check with nothing going red. That is this project's
   "comments that describe other code" failure with a scan standing in for the
   comment. Preferred shape, from the review: one Core function
   `S3SettingsXML.parseCORSReportingLoss(_:) -> (rules, isLossless)`, census
   private inside it, tested beside `S3CORSTests`.
2. **`corsBody` is documented as `parseCORS`'s inverse and is not, for a value
   holding a carriage return.** `<AllowedOrigin>a&#13;b</AllowedOrigin>` parses to
   `a\rb` and re-serializes as `a\nb`. Task 9 closes the user-visible half by
   asserting `parseCORS(canonical) == rules` beside the census; the doc comment's
   claim is still too strong and the asymmetry is Core's.
3. **`CORSRule.validate()` has no range check**, so a negative `MaxAgeSeconds`
   passes the pre-send gate and is refused by the store instead — the one place
   this sheet's validation is less strict than the thing it is protecting the
   user from.

- [ ] **Step 8: Run the full suite and both gated suites**

Run: `swift test`
Run: `MACSCP_ITEST=1 swift test`

- [ ] **Step 9: Commit**

```bash
git commit -m "docs: close the bucket-settings half of the s3Manager row"
```
