# P3b — Completion: exporting and importing snippets

Completed 2026-08-18. Five substantive commits in the range `296cf74..HEAD`:

```
438c93b feat(core): give snippets an exchange format without a crypto path
8ad8a08 feat(core): plan a snippet import on the shared conflict arbiter
7b4857f feat(app): export the visible snippets to a file
4b2ecab fix(app): register the snippets export type in the packaged Info.plist
25a2ae6 feat(app): import snippets through the shared conflict sheet
```

**One correction to the brief itself:** the brief spoke of "the phase in
six commits" for this same range. The range additionally contains
`e1b1451` (`docs(app): note the P3d action window's keyboard shortcuts`) —
a pure documentation commit for a different, later phase (P3d) that only
touches the spec file
(`docs/superpowers/specs/2026-08-18-p3-ordnung-design.md`, +14 lines) and
has nothing to do with P3b in substance. It landed chronologically between
Task 3 and Task 4 on the same branch. The `git diff --stat` over the whole
range (excluding this one spec file) shows exactly the 13 files the four
task reports describe — no unexplained changes.

The phase covers exactly what the spec (`docs/superpowers/specs/
2026-08-18-p3-ordnung-design.md`, section "P3b — exporting and importing
snippets") required: an exchange format `macscp-snippets` over the shared
`ExportEnvelopeCodec`, always with `password: nil`; a dedicated planner on
the shared `ImportConflictArbiter`, duplicates keyed on name as with login
sets; export and import surfaces following the pattern of the session
sheets, with selection at export time and the shared conflict sheet from
M19.

## Measured numbers

- **Suite:** `swift test` — **2055 tests in 176 suites** at the end of the
  five tasks, 0 failures. Self-measured (not carried over from a report),
  matches the end state reported in Task 4. Progression across the phase:
  2029 (after Task 1) → 2042 (Task 2) → 2045 (Task 3) → 2055
  (Task 4); baseline before the phase 2024/175. **The fix round after the
  whole-phase review** (see the last section) added five more tests: end
  state **2060 tests in 176 suites**, likewise self-measured.
- **`.strings`:** `plutil -lint` on all eight catalogs
  (`Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings`,
  `Sources/macSCPCore/Resources/{en,de,fr,pl}.lproj/Localizable.strings`) —
  all eight `OK`.
- **Build:** `scripts/package-app` started in the background
  (`MACSCP_VERSION=1.2.0-dev MACSCP_BUILD=978`, `978` = `git rev-list
  --count HEAD` at the time of the run), completed successfully
  (`Build complete!`, `wrote dist/macSCP.app`). Checked:
  - `lipo -archs` on `macSCP` and `macscp-cli`: both `x86_64 arm64`.
  - Both resource bundles present:
    `macSCP_MacSCPAppKit.bundle`, `macSCP_macSCPCore.bundle`.
  - All four `.lproj` in the bundle: `en`, `de`, `fr`, `pl`.
  - `plutil -lint` on `Contents/Info.plist`: `OK`.
  - **All three `UTExportedTypeDeclarations` entries present**
    (`dev.noix.macscp.sessions`, `dev.noix.macscp.logins`,
    `dev.noix.macscp.snippets`), read from the actually built
    `Info.plist`, not just from the script — the third entry is the
    actual checkpoint of this phase, see below.
  - The app was **not started** — requirement of the brief.

## 1. Why the codec accepts no password, and how that is pinned

The reasoning is substantive, not technical: a snippet by construction
contains no credentials (`Snippet`'s own doc comment rules this out;
secrets live exclusively in the keychain). Encryption would fake a
security guarantee that does not exist — the same reasoning as in the
first round of snippet work, unchanged.

`SnippetExportCodec`'s public interface (`encode(_:)`, `probe(_:)`,
`decode(_:)`) at no point accepts a `password` parameter — unlike its two
siblings `SessionExportCodec` and `LoginSetExportCodec`. That already
rules out a caller wanting to pass in a password at the type-system
level, at compile time, without a test's involvement.

The remaining edge case is internal: `encode`/`decode` could later be
changed to pass something other than the literal `nil` on to
`ExportEnvelopeCodec`. That is pinned against — with the field on the
actually produced envelope, not with a source-scanning guard:
`ExportEnvelopeCodec.encode` writes `encrypted: false` **exactly when**
it received `password: nil` (see `ExportEnvelopeCodec.swift`,
`encode<P>` — the `guard let password else { … encrypted: false … }`
branch). `SnippetExportCodecTests.theWrittenFileIsPlainTextAndSaysSoInsteadOf
ClaimingEncryption` reads this field directly off the produced bytes,
`.probeAcceptsOurFormatAndRejectsASessionExport` reads it a second time
via `probe`'s return value on the same output. Both tests go red the
moment the internal call stops passing `nil` — that is a direct
observation of the pinned fact, not a proxy for it.

Deliberately **no** eighth source-scanning guard: at the time of this
phase, the project already has seven such guards (from P3a and earlier
phases), and a reviewer had recently judged the idiom to have reached its
sensible size. A guard would also have solved a problem here that the
fixed, password-less signature already solves structurally — there is
nothing a *caller* would need protecting from, because no caller can pass
a password in the first place.

## 2. What `probe` actually returns — and a correction

`probe` reports the envelope's `encrypted` flag, read back verbatim.
**It is not a format predicate.** For any file *this codec wrote*, the
return value is `false` — `encode` always passes `password: nil`.
**Correction (whole-phase review):** this used to say "always `false`,
regardless of whether the file is actually a snippet export file". That
is wrong, and the same wrong sentence was in the code (see the last
section, point 1): a **foreign** file that claims our format name with
`"encrypted": true` makes `probe` report `true`, and `decode` then
throws `.passwordRequired`. What rejects a file with the wrong format is
not `probe`'s return value but `ExportEnvelopeCodec`'s own format check,
which **throws**: the private function
`envelope(from:as:format:currentVersion:)` first decodes only a slim
`EnvelopeHeader` (format + version) and checks `header.format == format`;
if the format does not match, it throws `SessionExportError.notAnExportFile`
before an `encrypted` value even exists. `probe` and `decode` both call
this same `envelope(from:)` first — so the format check is equally sharp
for both, but it runs **before** and **independently of** what `probe`
ultimately returns.

This distinction was written down incorrectly once during this phase:
Task 1's own test design (in the plan, not in this completion task's
brief) asserted `#expect(try SnippetExportCodec.probe(ours))` — that
`probe` returns `true` on a file freshly produced by this codec. That is
wrong in both directions: first, this codec never encrypts, so the
correct value is `false`, not `true`; second, even a `true` result would
have said nothing about format membership, because `probe` is not a
format predicate at all. The implementer noticed this while writing the
test, corrected it (`== false`, analogous to
`LoginSetExportCodecTests.roundTripsUnencrypted`) and documented it in
their own report (`task-1-report.md`, section 4). For a future reader: a
green `probe(_:) == false` on this codec's own output is the *expected*
result here, not the surprising one — rejection of a wrongly-formatted
file shows up as a **throw**, not as `false`.

## 3. What is held by tests, what only by review

This project has no SwiftUI rendering tool (a project-wide, documented
boundary, nothing specific to this phase). Concretely for P3b:

**Tested** — new tests from the five tasks, counted as `+@Test` lines in
the range `296cf74..b4b91d5` (Core: `SnippetExportCodecTests` — 5,
`SnippetImportPlannerTests` — 13; App: `SnippetsPresentationTests` — **13**
new over the phase, together with the ones already present in one suite;
the suite itself is older, created in `429fdaf`). **Correction
(whole-phase review):** this used to say "17 new" for
`SnippetsPresentationTests`; the diff adds 13. The number matches the
measured suite progression — Task 3 brought +3, Task 4 +10
(2042 → 2045 → 2055). The other two numbers (5 and 13) were rechecked
and are correct. The subsequent fix round adds five more tests: +1 in
`SnippetExportCodecTests` (file then has 6), +2 in
`SnippetImportPlannerTests` (then 15), +2 in `SnippetsPresentationTests`
(making 15 new over the phase plus the fix round, file then has 26). See
the last section:

- The export roundtrip (name/command/tags), that the file is plaintext
  and carries `encrypted: false`, that a corrupted snippet payload
  throws the whole decode instead of silently dropping one entry, the
  version check.
- The planner: all four properties carried over from the login-set
  precedent — trimmed/case-insensitive name key, growing `takenNames`
  set, replacement at most once per existing id
  (`replacedExistingIDs`), full abort on cancellation — are pinned
  individually by tests, not merely claimed in the report; the reviewer
  per the ledger independently retraced them rather than trusting the
  report.
- `snippetsCanExport`: enabled when the store is loaded and non-empty;
  disabled on an empty visible result; disabled on `.unreadable`, even
  when `visibleSnippets` (the argument) would not be empty — the test
  proving the function checks `isUnreadable` itself instead of merely
  inferring it from emptiness.
- `applySnippetImportPlan`: a fresh import, replace-instead-of-duplicate,
  a cancelled run writes nothing, a write failure is counted instead of
  crashing. **Correction (whole-phase review):** this section described
  `applySnippetImportPlanReplacesRatherThanDuplicating` as "end-to-end
  from planner output to store state". That is not correct — the test
  builds its `PlannedSnippet` by hand and never calls the planner; it
  pins the *glue* between the documented planner contract (replace keeps
  the existing id) and `SnippetStore.save`, not the chain. The actually
  end-to-end chain is now written as
  `aRealExportRoundTripsThroughThePlannerAndTheApplierIntoTheStore`:
  real `encode` → `decode` → `SnippetImportPlanner.plan` →
  `applySnippetImportPlan` → `store.all()`.
- `snippetImportResultText`/`snippetImportErrorText`: text variants
  depending on count/error kind.

**Not tested** (unobservable without a rendering harness, not forgotten):

- That the export/import button even appears, that `.disabled` actually
  takes effect, and that the `fileExporter`/`fileImporter` opens.
- The order `probe` **before** `decode` in
  `handleImportFileSelection` — the type correctness of both calls is
  covered by their respective codec tests, the wiring order itself is
  not.
- The new third `kindText` case (`.snippet`) in
  `ImportConflictSheet.swift` — exactly like its two predecessors
  (`.loginSet`, `.session`), which were **never** unit-tested. Not a new
  gap, the same gap as before, now one case larger.
- The suppressed result alert after a cancelled import — only the write
  path (`applySnippetImportPlan` writes nothing on `cancelled`) is
  pinned, not the UI reaction (`guard !plan.cancelled else { return }`
  in `SnippetsSheet.applyImport`), that no alert therefore appears.
- The password-less design itself has gained no new checkpoint outside
  Task 1 — Tasks 3/4 add no new caller of
  `SnippetExportCodec.encode`/`decode` that could regress it, beyond
  what Task 1 already checks.

## 4. The GUI was never started throughout this entire phase

Every statement about actual rendering, click behavior, or the real
appearance of the save/open panel is carried in the task reports as an
unobserved claim. The maintainer must look at the following by hand
before the next release:

1. **Export with an active filter** — set a search term and/or tag
   filter in the snippets sheet, click "Export…", and open the written
   file: it must contain only the currently visible snippets, not all
   of them in the store. Per the source, `performExport` receives
   exactly `visibleSnippets` — whether this connection actually holds
   up in the running UI is unverified.
2. **Import a file with a name conflict** — import a previously
   exported file containing a snippet name that already exists in the
   current store (same name, including differing case or padding
   whitespace) and check that the shared conflict sheet appears,
   labels the new third case correctly, and that replace/keep-both
   behave as expected.
3. **Rejection of a wrong file** — select a session or login-set export
   file (`.macscpsessions`/`.macscplogins`) via the snippet import and
   confirm it is rejected (by `ExportEnvelopeCodec`'s format check,
   which throws, not by `probe`'s return value — see section 2) with an
   understandable error message, no silent malfunction.
4. Additionally, from Task 3: "Export…" is actually disabled when the
   store is unreadable (e.g. a hand-corrupted `snippets.json`), or leads
   to no action, and the extension/filename suggested in the save panel
   are correct.

## The packaging lesson

The new file type was declared in Swift (`UTType.macscpSnippets` in
`SessionExportImportSheets.swift`, Task 3), but initially got **no**
entry in `scripts/package-app`'s `UTExportedTypeDeclarations` array —
unlike its two siblings `macscpSessions`/`macscpLogins`, which were
already there. macOS would therefore not have known the `.macscpsnippets`
extension at all outside the app's own panels (Finder association,
"Open With", Spotlight). The `UTType.macscpSnippets` doc comment already
claimed at this point that the entry existed — a false statement, not an
unobserved one.

The coordinator review of Task 3 found this, not a test: neither
`swift test` nor `swift build` touch `scripts/package-app`, and because
the GUI is fundamentally never started in this phase, no manual look
would have caught it by chance either. The fix (`4b2ecab`) adds the
third entry field-for-field identical to the two existing ones
(`UTTypeIdentifier dev.noix.macscp.snippets`, description "macSCP
Snippets", `UTTypeConformsTo [public.json]`, extension `macscpsnippets`)
and was verified via a rebuild plus reading the actually built
`Info.plist`, not merely by re-reading the script. This completion task
reproduced the finding independently (see "Measured numbers" above).

**For a future format:** a new exchange type needs both halves — the
Swift `UTType` declaration **and** the matching
`UTExportedTypeDeclarations` entry in the packaging script — and this
project currently has no automatic checkpoint that reports a missing
second half other than the review itself.

## Brief errors of this phase (from the ledger, `progress.md`)

Ten brief errors total in this milestone; five of them fell within P3b:

- Task 1 (sixth): the test design in the plan asserted
  `probe(ourFile)` was true — see section 2 above.
- Task 2 (seventh): the fourth test design did not say whether `existing`
  starts empty; with an empty store, of two identically-named imported
  entries only the second one collides. The implementer pre-populated
  `existing` with an identically-named entry and justified this in the
  report.
- Task 3 (eighth): the plan pointed to "the session sheet" as the model
  for the `fileExporter` call; no such sheet exists — session export
  runs through `ContentView`/`ContentView+Sheets.swift`. `LoginSetsSheet`
  was the actually matching model and was followed instead.
- Task 4 (ninth): the plan described `snippets.import.result %lld` with
  two placeholders (by analogy to login sets); the key takes only one.
  Implemented literally; for Replaced/Renamed, the already-existing
  generic key `import.result.resolved %lld %lld` is reused instead.
- Task 4 (tenth): a doc comment on `SnippetExportDocument` claimed there
  was not yet an import call site — after Task 4 that was no longer
  true and was corrected.

Additionally, outside the numbered count: the `UTType.macscpSnippets`
doc comment from Task 3, which claimed the (at that point missing)
packaging entry was present — see "The packaging lesson" above. This
completion task itself found no new error in the Task 5 brief; its
statements on format, planner, surface, and commit count were correct
apart from the six-versus-five correction named above.

## Known, deliberately deferred points

- The sequential-processing / "at most one `arbiter.resolve` at a time"
  claim in the `SnippetImportPlanner` doc comment is untested — taken
  verbatim from `LoginSetImportPlanner`'s identical, likewise untested
  claim. Not a new gap.
- The two already-existing `kindText` cases in
  `ImportConflictSheet.swift` (`.loginSet`, `.session`) were never
  unit-tested; the new third case (`.snippet`) shares this gap rather
  than closing it.

## What the whole-phase review found (fix round after completion)

The five task reviews each found one task clean; only looking at the
whole phase found the following. Five fixes, `5d46aab` and the three
before it (`6efd7fa`, `13066dc`, `ad04b48`) plus this documentation
commit. Suite afterward 2060/176, self-measured.

### 1. The fourth false doc claim of this milestone (IMPORTANT)

`SnippetExportCodec.probe`'s doc said the result was "always `false` for
this format"; `snippetImportErrorText`'s doc (and a test's doc) said
`.passwordRequired` could "never actually reach" this format. Both are
wrong for a **foreign** file: an envelope claiming `{"format":
"macscp-snippets", "version":1, "encrypted":true}` makes
`ExportEnvelopeCodec.probe` report **`true`**, and
`decode(…, password: nil)` runs into
`guard let password else { throw .passwordRequired }`.

The *behavior* was and is correct — a generic refusal, no crash, no half
import — and the production side is airtight because `encode` is the
only writer and unconditionally passes `nil`. Only the three comments
were wrong, and **nobody observed the actual behavior**. `6efd7fa`
corrects all three and pins the fact with
`SnippetExportCodecTests.aForeignFileClaimingEncryptionProbesTrueAndRefuses
ToDecode` (hand-written JSON, because this codec cannot produce such
bytes itself).

**The pattern, not the individual case:** this is the fourth doc claim
in this milestone that asserts something untrue or nonexistent
(previously: the `UTType.macscpSnippets` comment about the packaging
entry, the `SnippetExportDocument` comment about the missing import call
site, and the four comments falsified by the tags move in `c3296f8`).
The common cause is the same every time: the comment describes the
**intent** ("this format has no crypto path"), not the **code**
("`probe` reads a flag a foreign file can set"). For future rounds, the
useful question is not "does the comment match the design" but:
**which statement in this doc comment is observed by no test?**

### 2. The roundtrip was proved in two separate halves

No test chained `encode → decode → SnippetImportPlanner.plan →
applySnippetImportPlan → store.all()`. All Apply tests build their
`PlannedSnippet` by hand. `13066dc` writes the real chain
(`aRealExportRoundTripsThroughThePlannerAndTheApplierIntoTheStore`) and
corrects the sentence above that described a hand-built test as
end-to-end.

The test deliberately carries a snippet with only case-differing tags
(`["Docker", "docker"]`) and a name differing only in case ("prod"
against stored "Prod"): names collide case-insensitively, tags remain
two tags — the split this phase committed to, visible along the whole
path.

**Correction to the fix round's brief (eleventh brief error):** the
brief justified this test by saying a case-insensitive
`TagList.normalized` would "silently break the export roundtrip, with
every current test staying green." Cross-checked by mutation
(`seen.insert($0.lowercased())`): **four** tests go red, three of them
pre-existing — `TagListTests.normalizationKeepsCaseSoTwoSpellingsStayTwo
Tags`, `SnippetTests.caseIsPreserved`,
`SnippetMenuModelTests.differentlyCasedTagsSortAsNeighbours` — plus the
new chain test. The property was therefore not unprotected; only the
path *through export, import planner, and applier* was, and that is
exactly what the new test now covers. It remains justified, the
justification was overstated.

### 3. The localized default filename carried the extension (MINOR)

`snippets.export.filename` read identically in all four catalogs
"macSCP Snippets.macscpsnippets" and was the **only** localized
`defaultFilename` in the project; both siblings set theirs fixed. A
translation that keeps writing past the dot produces a file macOS does
not associate, and one the importer then hides via its own
`allowedContentTypes` filtering.

**Decision:** follow the siblings and drop the key outright (`ad04b48`),
rather than only removing the extension from the translation. All four
catalogs carried the same untranslated English string anyway — nothing
is lost, and the pattern is now uniform across the project instead of
split in two.

### 4. A nameless snippet on import (MINOR)

Import was the only path to a snippet without a name: `"name": "   "`
trims to `""` and landed unchanged in the store — a blank row in the
sheet, a blank entry in the terminal menu —, while the editor of that
same sheet does not let you save such a name. Two of these in one file
also both collided on `""`, so the conflict sheet asked about an entry
*without a name*.

**Decision: the planner** (`5d46aab`), not `Snippet.init?` and not the
applier. `Snippet.init?` only checks the command, and `init(from:)` runs
through the same initializer — tightening it there would make an
**existing** store file with an empty name no longer decodable, turning
a cosmetic problem into a store the sheet reports as unreadable. The
applier is too late: by then the planner has already put both entries on
the same empty key and asked about them. The drop therefore happens
**before** key formation; the count travels along as
`SnippetImportPlan.namelessDiscarded` and gets its own line in the
result alert (`snippets.import.nameless %lld`, four catalogs), so the
entries don't vanish between "the file contained N" and "N-1 arrived".

### Deliberately not fixed (findings judged "leave as is")

- `applySnippetImportPlan` is **not transactional**: a failure on
  element *k* leaves 1…k−1 written behind. Counted and displayed via
  `storeFailures` — none of it is silent.
- Unlimited numbers of, and very long, tags are imported verbatim. A
  pure layout issue, self-inflicted.
- The sequential-processing claim in the planner doc — already carried
  above under "Known, deliberately deferred points", confirmed by the
  review rather than reopened.
