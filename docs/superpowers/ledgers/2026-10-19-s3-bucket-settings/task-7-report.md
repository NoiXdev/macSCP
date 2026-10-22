# Task 7 report: the connection-level action seam

Status: DONE_WITH_CONCERNS (concerns at the end).
BASE `f3ec6e07`. One commit: `46bfdebb feat(app): a connection's own actions, as one list per backend`. Not pushed.

## What changed

- `BackendContributions.swift`: `ConnectionActionContribution` (`id`, `titleKey`, `titleDefault`, `systemImage`, public memberwise `init`), beside `FileActionContribution`.
- `BackendDescriptor.swift`: `public let connectionActions: [ConnectionActionContribution]`, **no default**. SSH and WebDAV spell `[]`; S3 spells four entries: `s3.createBucket`, `s3.versioning`, `s3.cors`, `s3.objectLock`.
- Eight synthetic descriptors in tests spell `connectionActions: []`: `ConnectionDiagnosticsTests`, `ConnectionDiagnosticsJumpTests`, `ICMPEchoTests`, `ThroughputProbeTests`, `InternetSpeedProbeTests`, `ResolveNamesTests`, `NetworkTraceTests`, `SchemaConformanceTests`.
- `Sources/MacSCPAppKit/ConnectionActionsMenu.swift` (new): `Menu` over `descriptor.connectionActions`, titles via `L10n.string(titleKey, titleDefault)`, `static func isPresented(for:)`. It declares no width, so it is not a `BoundedView`. It takes `onSelect: ((ConnectionActionContribution) -> Void)?`; with `nil` every row is `.disabled`.
- `ContentView+Lifecycle.swift`: the menu is the first item in `ToolbarItemGroup(placement: .primaryAction)`, constructed only under `if ConnectionActionsMenu.isPresented(for: descriptor)`. `onSelect: nil` is passed (see concern 1).
- Catalogues, four locales (`en`, `de`, `fr`, `pl`) in `Sources/MacSCPAppKit/Resources/<locale>.lproj/Localizable.strings`, five keys each, after `browser.action.presignedURL`: `connection.actions.menu` (the menu's own label and help text) and `connection.action.createBucket|versioning|cors|objectLock`. Only the App catalogues: titles are looked up through `L10n` in the App, as `browser.action.presignedURL` is. English: "Create Bucket…", "Versioning…", "CORS Rules…", "Object Lock…". German does not address the user (no du/Sie form is needed).
- Tests (new): `Tests/macSCPCoreTests/BackendContributionTests.swift` (5), `Tests/macSCPAppKitTests/ConnectionActionsMenuTests.swift` (7).

## The count of construction sites (the ruling)

Re-ran as instructed, from the worktree root:

    grep -rn 'BackendDescriptor(' Sources Tests --include='*.swift'

At BASE it printed 12 lines: 3 in `BackendDescriptor.swift`, 8 in `Tests/macSCPCoreTests`, 1 test function name (`ImportFromSourceViewModelTests.swift:601`). Your figures reproduce. No reason found to depart from the no-default ruling; it compiled as ruled. After the change, `grep -rn 'connectionActions: ' Sources Tests --include='*.swift' | wc -l` prints 12 = the declaration + 3 production + 8 synthetic.

## The red, observed

Tests written first; no production change yet. Command (note: the plan's `"A|B"` filter form is refused by this session's command checker, so two `--filter` flags, which `swift test` ORs):

    swift test --filter BackendContributionTests --filter ConnectionActionsMenuTests

Exit code 1. ANSI stripped, the log is 73 lines. What it contains, as an **excerpt**: `sed -n 21,69p` of the stripped log, i.e. everything from the first `error:` line to the line before `Failed frontend command:` (line 70, a ~5000-character swift-frontend command line, not reproduced). Lines 1-20 are build progress (`Building for debugging...`, `[Planning ...]`, `[27 / 47] macSCPCoreTests-product`) plus one `warning: missing creator for mutated node` for SwiftTerm's bundle; lines 71-73 are `error: Build failed` / `error: fatalError`.

```
error: SwiftCompile normal arm64 /Users/noidee/macSCP/.claude/worktrees/diff-view/Tests/macSCPAppKitTests/ConnectionActionsMenuTests.swift failed with a nonzero exit code. Command line:     cd /Users/noidee/macSCP/.claude/worktrees
    builtin-SwiftPerFileCompile ConnectionActionsMenuTests.swift
/Users/noidee/macSCP/.claude/worktrees/diff-view/Tests/macSCPAppKitTests/ConnectionActionsMenuTests.swift:19:17: error: cannot find 'ConnectionActionsMenu' in scope
17 |         let ssh = BackendDescriptor.descriptor(for: .ssh)
18 |         let s3 = BackendDescriptor.descriptor(for: .s3)
19 |         #expect(ConnectionActionsMenu.isPresented(for: ssh) == false)
   |                 `- error: cannot find 'ConnectionActionsMenu' in scope
20 |         #expect(ConnectionActionsMenu.isPresented(for: s3) == true)
21 |     }

/Users/noidee/macSCP/.claude/worktrees/diff-view/Tests/macSCPAppKitTests/ConnectionActionsMenuTests.swift:20:17: error: cannot find 'ConnectionActionsMenu' in scope
18 |         let s3 = BackendDescriptor.descriptor(for: .s3)
19 |         #expect(ConnectionActionsMenu.isPresented(for: ssh) == false)
20 |         #expect(ConnectionActionsMenu.isPresented(for: s3) == true)
   |                 `- error: cannot find 'ConnectionActionsMenu' in scope
21 |     }
22 | 

/Users/noidee/macSCP/.claude/worktrees/diff-view/Tests/macSCPAppKitTests/ConnectionActionsMenuTests.swift:30:40: error: value of type 'BackendDescriptor' has no member 'connectionActions'
28 |         for kind in ConnectionKind.allCases {
29 |             let descriptor = BackendDescriptor.descriptor(for: kind)
30 |             let expected = !descriptor.connectionActions.isEmpty
   |                                        `- error: value of type 'BackendDescriptor' has no member 'connectionActions'
31 |             #expect(ConnectionActionsMenu.isPresented(for: descriptor) == expected)
32 |             if expected { presented += 1 }

/Users/noidee/macSCP/.claude/worktrees/diff-view/Tests/macSCPAppKitTests/ConnectionActionsMenuTests.swift:31:21: error: cannot find 'ConnectionActionsMenu' in scope
29 |             let descriptor = BackendDescriptor.descriptor(for: kind)
30 |             let expected = !descriptor.connectionActions.isEmpty
31 |             #expect(ConnectionActionsMenu.isPresented(for: descriptor) == expected)
   |                     `- error: cannot find 'ConnectionActionsMenu' in scope
32 |             if expected { presented += 1 }
33 |         }

/Users/noidee/macSCP/.claude/worktrees/diff-view/Tests/macSCPAppKitTests/ConnectionActionsMenuTests.swift:44:67: error: value of type 'BackendDescriptor' has no member 'connectionActions'
42 |         var checked = 0
43 |         for kind in ConnectionKind.allCases {
44 |             for action in BackendDescriptor.descriptor(for: kind).connectionActions {
   |                                                                   `- error: value of type 'BackendDescriptor' has no member 'connectionActions'
45 |                 for locale in Self.locales {
46 |                     let resolved = L10n.$localeOverride.withValue(locale) {

/Users/noidee/macSCP/.claude/worktrees/diff-view/Tests/macSCPAppKitTests/ConnectionActionsMenuTests.swift:64:67: error: value of type 'BackendDescriptor' has no member 'connectionActions'
62 |         var checked = 0
63 |         for kind in ConnectionKind.allCases {
64 |             for action in BackendDescriptor.descriptor(for: kind).connectionActions {
   |                                                                   `- error: value of type 'BackendDescriptor' has no member 'connectionActions'
65 |                 let english = L10n.$localeOverride.withValue("en") {
66 |                     L10n.string(action.titleKey, "ZZ-UNRESOLVED-ZZ")
```

Two things the brief's prediction got slightly wrong or did not say:
- The message for the member is `value of type 'BackendDescriptor' has no member 'connectionActions'`, as predicted, but it appeared at three sites in `ConnectionActionsMenuTests.swift` (lines 30, 44, 64) beside `cannot find 'ConnectionActionsMenu' in scope` (lines 19, 20, 31).
- Only the `macSCPAppKitTests` compile unit reported errors in this run. `BackendContributionTests.swift` (Core) certainly uses the same missing member, but the build stopped at the first failing compile unit, so **no Core-test error line was observed** and I do not claim one.

## Green

Targeted, same two filters after the change: `Test run with 5 tests in 1 suite passed` (Core) and, after adding the wiring scans, `swift test --filter ConnectionActionsMenuTests` prints `Test run with 7 tests in 1 suite passed`.

Full suite, `swift test` with no flags, on the tree that became the commit. Command for the figures:

    grep -n -e '✘' -e 'Test run with' <log with ANSI stripped>

    12172:✔ Test run with 5074 tests in 407 suites passed after 19.776 seconds.
    17988:✘ Test "Varying only isRegex leaves the pixels unchanged" recorded an issue at ViewTestabilitySpike.swift:202:9: Expectation failed: off == on
    18010:✘ Test "Varying only isRegex leaves the pixels unchanged" failed after 0.798 seconds with 1 issue.
    18082:✘ Suite "ViewTestabilitySpike" failed after 23.879 seconds with 1 issue.
    18207:✘ Test run with 2563 tests in 231 suites failed after 24.671 seconds with 1 issue.

So: Core 5074 passed; App 2563 with exactly one failure, `ViewTestabilitySpike` "Varying only isRegex leaves the pixels unchanged" (an AppKit Toggle pixel comparison). **It is not mine and I measured that:** it fails the same way alone on my tree (`swift test --filter ViewTestabilitySpike`: `Test run with 7 tests in 1 suite failed ... with 1 issue`) and alone on BASE (detached `f3ec6e07`, same command, same line `ViewTestabilitySpike.swift:202:9: Expectation failed: off == on`). I returned to `s3-bucket-settings` afterwards; `git status --porcelain` empty, `git branch --show-current` prints `s3-bucket-settings`.

## Mutation probes (all via `scripts/mutation-probe`, tree clean before and after each; `git status --porcelain` printed nothing after the last one)

Control run each time: 7 (or 5) tests, 0 pre-existing failures.

| Plant | Result | Caught by |
|---|---|---|
| A: `if ConnectionActionsMenu.isPresented(for: descriptor) {` -> `if true {` in `ContentView+Lifecycle.swift` | RED, 7 ran | `theMenuIsConstructedOnlyWhereItIsPresented` |
| B: `let _ = uploadButton(...)` inserted before the menu | RED, 7 ran | `theMenuIsTheFirstThingInThePrimaryActionGroup` |
| C: `static let planted = ConnectionKind.s3` in `ConnectionActionsMenu.swift` | RED, 7 ran | `theMenuNamesNoBackendKind` |
| D: `isPresented(for:)` returns `true` | RED, 7 ran | `aBackendWithNoActionsRendersNoCapsule`, `presentationIsExactlyANonEmptyList` |
| E: delete `connection.action.objectLock` from `pl.lproj` | RED, 7 ran | `everyActionTitleResolvesInAllFourLocales` |
| F: S3's list replaced by `[]` | RED, 5 ran | `onlyS3ContributesConnectionActions`, `theSeamIsNotEmptyInEveryBackend`, `s3OffersTheFourBucketActionsInTheOrderTheMenuShowsThem`, `everyActionCarriesAllFourFields`, `everyActionIdIsUniqueWithinItsBackend` |

Plant F also shows the pairing rule working: the two "for every backend" loops (`everyActionCarriesAllFourFields`, `everyActionIdIsUniqueWithinItsBackend`) each end in `#expect(inspected > 0)`, so an emptied seam cannot satisfy them silently.

## Guard design (CLAUDE.md, "Guards that name what they watch")

- `theSeamIsNotEmptyInEveryBackend` is the brief's, verbatim in logic, but derives descriptors from `ConnectionKind.allCases` and `BackendDescriptor.descriptor(for:)`. No descriptor name is spelled (the brief spelled `webDAVDescriptor`; the real symbol is `webdavDescriptor`, and it is internal anyway).
- Every negative scan has a positive beside it: `theMenuNamesNoBackendKind` requires `connectionActions` to be present before it asserts `ConnectionKind` / `.s3` / `.ssh` / `.webdav` are absent. The placement scans require both anchors to exist (`#require`) before comparing positions. All source scans read `SourceCorpus.code(of:)` (comments and strings blanked), so the explanatory comment in the toolbar cannot satisfy or trip them.
- Catalogue checks derive titles from the descriptors: nothing in the tests spells a key or an English title. `theEnglishCatalogueSaysTheDefault` holds `titleDefault` and the `en` file to one string.
- No wall-clock ceilings, no blocking waits.

## Comments that described the absent list

`grep -rn -i -e 'ossify' -e 'connection-level' -e 'connection level' -e 'action list' -e 'unused seam' Sources Tests CLAUDE.md --include='*.swift' --include='*.md'` at BASE hit `Sources` in exactly one place: the `BackendDescriptor` header, lines 8-10. (The same command over `docs/` finds the spec and the M12 plan/design, see concern 2.) Done:

1. **The header is rewritten, not deleted.** The withdrawn paragraph is quoted verbatim, line breaks kept, in an indented block; the new text says what changed (the condition it named, "a real caller", arrived: S3's bucket settings) and on what terms (no default; `theSeamIsNotEmptyInEveryBackend`). The opening summary line now lists the connection-level actions too.
2. **A second comment this change made worse was found by the search for "synthetic".** The `apply` doc said "the one synthetic descriptor, in `SchemaConformanceTests`, passes an empty `apply`". Measured: eight synthetic descriptors, five pass `apply: { _, _ in }` and three pass `ssh.apply` (`grep -n 'apply:' Tests/macSCPCoreTests/*.swift` minus `BackendApply*`). Corrected in place, quoting what it withdraws ("the wording 'the one synthetic descriptor' is withdrawn: it was not the only one"), with no new number written (a count in prose is a claim about the rest of the project, per CLAUDE.md).
3. Left unchanged and checked: the `defaultValues` and `loginSetValues` doc comments say a stored memberwise member "would force every synthetic descriptor a test builds to name it". That is still true, and `connectionActions` is now an instance of it, on purpose.

## Concerns

1. **The menu rows are disabled, not live.** There is no handler for the four ids yet (Tasks 8-11 add the sheets and, per the plan, touch `ContentView+MenuActions.swift`), and an enabled entry that does nothing is what `PaneToggleState`'s doc comment rules out. So `ContentView+Lifecycle.swift` passes `onSelect: nil` and every row renders `.disabled`. Task 8 should replace the `nil`; it will need to do so in the first task that has a sheet, and the other three rows should stay disabled until theirs lands. Nothing tests the disabled state (no view is drawn in a test); `onSelect == nil` is one line in the view.
2. **The design spec points at a paragraph that no longer begins as it says.** `docs/superpowers/specs/2026-10-19-s3-bucket-settings-design.md` (anti-goal "An empty seam", around lines 82-88) says "the note sits in the file this design adds to (`BackendDescriptor.swift`, the paragraph beginning "There is no connection-level action list")". The new header paragraph quotes that sentence but does not begin with it. I did not touch the spec (a measurement record owned by you). The sentence still finds the quoted text with `grep -n 'There is no connection-level action list' Sources/macSCPCore/Capabilities/BackendDescriptor.swift`, but the pointer's wording is now stale; you may want to add a quoted correction there.
3. **Create Bucket is offered unconditionally.** Spec §6.1 says "the action is therefore offered in bucket-list mode only" (no bucket-list surface in `RootMode.bucket`). The seam is one static list per descriptor and has no per-action availability, so `s3.createBucket` shows in the menu whatever the root mode. That gating belongs to Task 11 (or a later seam change); I did not invent one.
4. **Brief deviations:** Step 3's symbol `webDAVDescriptor` is `webdavDescriptor` in the tree (and internal); tests use `descriptor(for:)`. Step 5 names no menu label; I added `connection.actions.menu` ("Connection Actions"), which is why there are five catalogue keys rather than four. Titles: "CORS Rules…" rather than spelling out cross-origin, because that is the term an S3 user knows; flag it if you want it spelled out.
5. **Pre-existing, not touched:** (a) `ViewTestabilitySpike` red, above. (b) `S3CreateBucketTests.swift:84` emits two compiler warnings (`expression of type 'Bool?' is unused`, and `?? ""` on a non-optional) in the build log of every run; from an earlier task on this branch, and CLAUDE.md notes CI counts warnings. Command: `grep -n 'warning:' <green log>` then look for `S3CreateBucketTests.swift`. (c) The `FileActionContribution` doc comment ("empty for ssh/s3 now — S3 presigned URL lands in M14") is stale (S3 has had `s3.presignedURL` since M14); not about this seam, so left.
6. The documentation rule (user docs ship with the feature, `noix-docs`): nothing user-visible works yet (rows disabled), so I wrote no docs page; that belongs to the closeout task once a sheet is live.
