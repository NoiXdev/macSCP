# Sheet Bounds and Control Rigidity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every view in `MacSCPAppKit` that bounds its own size declares that
bound through one marker, is measured against it in all four catalogues, and
contains no localized control that can be silently squeezed.

**Architecture:** A `BoundedView` protocol carries each view's declared bound
as a static value, so the bound is discoverable instead of being a number in
a modifier that three different `grep`s find three different subsets of. A
test-target registry pairs each conformer with a builder and the state to
measure it in; a set-equality guard holds the registry to the conformances in
`Sources/`. Rigidity is a `Layout` that takes the maximum of its subview's
ideal width and the proposal, so a control cannot be compressed below its
ideal but still stretches, and three components bake it in so the
compressible form is not writable at a call site.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v6)`), SwiftPM, SwiftUI,
AppKit (`NSHostingController`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-17-sheet-width-and-control-rigidity-design.md`

## Global Constraints

- Build the view **inside** `L10n.$localeOverride.withValue`, never outside:
  measured 2026-10-17, building outside reported 373 pt where the correct
  figure is 411, silently, and the guard passed.
- Rigid means **a floor at the ideal, not a shrink to it**.
- Height is measured **where a view fixes it**.
- Remedies for a red measurement, all three sanctioned: make the control
  rigid; widen the bound to the maximum measured **across all four
  catalogues**; replace the control with a different kind.
- Never hardcode a display string: `L10n.string` in the App,
  `CoreL10n.string` in Core. No catalogue text changes in this plan.
- A negative check needs a positive check beside it.
- No wall-clock ceiling in a test; a floor is fine; hang bounds are
  `.timeLimit`.
- Every wait in a test is an `await`.
- A figure travels with the command that produced it, and the command runs
  in the form it is committed.
- A tracked-file plant goes through `scripts/mutation-probe`.
- `swift test` with **no** `--build-system` flag.
- Commit footer: `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- **If a measured minimum no longer fits `MainWindowSizePlan.formSize`
  (700x460) or `browserFloor` (930x620), stop and ask the maintainer.**
  That question is unsettled; see spec Constraint 3.

## Review Focus

Five failure modes the spec implies that no task's happy path exercises.
Each has its test named in the task that owns it.

1. **A view whose content is wider than its bound in one catalogue only.**
   Expected: that catalogue's entry is red and names the locale and the two
   figures. Pinned in Task 6.
2. **A registry that silently stops covering a view** when a conformer is
   added or renamed. Expected: set equality fails and names the missing
   type, not a count that happens to match. Pinned in Task 7.
3. **A control made rigid inside a bound that cannot hold it**, turning a
   silent squeeze into a visible clip. Expected: Task 6's guard is green
   before any rigidity lands, so this arrives as a red in Task 9/10 and is
   answered by a Remedy. Pinned by task ordering and by Task 10's step 2.
4. **A measurement that stops moving with the language** — the harness
   built outside the override, or a locale list that goes empty. Expected:
   the harness's own positive checks fail. Pinned in Task 2.
5. **A capped view measured against its minimum instead of its maximum.**
   `.capped(minWidth:maxWidth:)` clips at the maximum; comparing against
   the minimum would pass everything. Pinned in Task 5.

---

### Task 1: Read the guard's figures off CI

**Files:**
- Modify: `docs/BACKLOG.md` (the row titled "The only layout guard in the
  tree asserts point figures measured on Darwin 27, and CI runs macos-15")

**Interfaces:**
- Consumes: nothing.
- Produces: a recorded verdict — whether `NSHostingController.sizeThatFits`
  measures at all on a macos-15 runner, and the four figures if it does.
  Every later task's bound comparison depends on this answer.

- [ ] **Step 1: Push the branch**

Pushing is authorized for this measurement (maintainer ruling 2026-10-17,
`push ist ok`). Push the branch this work is on to `origin`. Do not open a
pull request and do not merge. The guard itself is already on `develop`
(`5855b592`), so any branch that contains `develop` runs it.

- [ ] **Step 2: Watch the run and read the four figures**

Run: `gh run watch`, then read the job log for the
`File action editor layout guard` suite.

Expected: either four per-locale figures, or a failure. Record the run id.

- [ ] **Step 3: Classify the outcome**

Three outcomes, and the plan continues differently for each:

- **Figures match the local ones** (en 364, de 411, fr 370, pl 405): write
  them into the backlog row beside the local ones with the run id, and
  continue to Task 2.
- **Figures differ but the suite passes:** record both sets. Every bound
  this plan compares against is the maximum across catalogues **and**
  platforms, per spec Constraint 5.
- **The suite errors** (no window server, missing fonts, a crash): this is
  a finding, not a reason to drop the guard. Write what it printed into the
  backlog row, report it, and **stop**. The remaining tasks assume a
  working instrument.

- [ ] **Step 4: Commit**

```bash
git add docs/BACKLOG.md
git commit -m "docs: record what the layout guard measures on a macos-15 runner"
```

---

### Task 2: The measurement harness

**Files:**
- Create: `Tests/MacSCPTestSupport/LayoutMeasure.swift`
- Create: `Tests/macSCPAppKitTests/LayoutMeasureTests.swift`

**Interfaces:**
- Consumes: `L10n.localeOverride` (`@TaskLocal static var localeOverride: String?`,
  `Sources/MacSCPAppKit/L10n.swift:78`).
- Produces:

```swift
@MainActor
public enum LayoutMeasure {
    /// Every shipped catalogue, read from the `.lproj` directory listing
    /// under `Sources/MacSCPAppKit/Resources`, sorted.
    public static var shippedLocales: [String] { get }

    /// The smallest width the content can take without clipping.
    public static func minimumWidth<V: View>(
        locale: String, of build: @MainActor () -> V) -> CGFloat

    /// The smallest height the content can take at `width` without clipping.
    public static func minimumHeight<V: View>(
        locale: String, at width: CGFloat, of build: @MainActor () -> V) -> CGFloat

    /// The width the content would take if nothing pushed back.
    public static func idealWidth<V: View>(
        locale: String, of build: @MainActor () -> V) -> CGFloat
}
```

Each function invokes `build` **inside** `L10n.$localeOverride.withValue(locale)`.
That is the whole reason it takes a closure rather than a view: a caller who
passes an already-built view has to write the extra closure to do it, and
Task 2's own tests pin what that costs.

- [ ] **Step 1: Write the failing tests**

In `LayoutMeasureTests.swift`, four tests:

```swift
@Test func everyShippedCatalogueIsListed()
// #expect(Set(LayoutMeasure.shippedLocales).isSuperset(of: ["en", "de", "fr", "pl"]))

@Test func theMeasurementMovesWithTheLanguage()
// widths = shippedLocales.map { minimumWidth(locale: $0) { FileActionEditor(...).sheetContent } }
// #expect(widths.allSatisfy { $0 > 0 })
// #expect(Set(widths).count > 1)

@Test func theGermanFigureIsTheOneTheCommittedGuardReports()
// #expect(minimumWidth(locale: "de") { editor().sheetContent } == 411)

@Test func buildingOutsideTheOverrideUnderMeasures()
// Measured 2026-10-17: 373 vs 411, because top-level labels resolve at
// construction and nested ones at render. This test exists so that a
// SwiftUI change to that behaviour is discovered rather than assumed.
// let outside = editor().sheetContent
// let wrong = LayoutMeasure.minimumWidth(locale: "de") { outside }
// let right = LayoutMeasure.minimumWidth(locale: "de") { editor().sheetContent }
// #expect(wrong < right)
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter LayoutMeasureTests`
Expected: FAIL — `LayoutMeasure` does not exist.

- [ ] **Step 3: Implement `LayoutMeasure`**

`minimumWidth` proposes `CGSize(width: 0, height: 100_000)`; `minimumHeight`
proposes `CGSize(width: width, height: 0)`; `idealWidth` applies
`.fixedSize(horizontal: true, vertical: false)` before proposing zero width.
`shippedLocales` reads the directory listing, as
`FileActionEditorLayoutGuardTests` already does — no locale is spelled in
code.

- [ ] **Step 4: Run them and watch them pass**

Run: `swift test --filter LayoutMeasureTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Tests/MacSCPTestSupport/LayoutMeasure.swift Tests/macSCPAppKitTests/LayoutMeasureTests.swift
git commit -m "test: add the per-catalogue layout measurement harness"
```

---

### Task 3: Open up the fourteen private types

**Files:**
- Modify: `Sources/MacSCPAppKit/SSHKeysSheet.swift`,
  `LoginSetsSheet.swift`, `SnippetsSheet.swift`, `ContentView+Detail.swift`,
  `SidebarTagFilterBar.swift`, `SettingsView.swift`
- Create: `Tests/macSCPAppKitTests/BoundedViewVisibilityTests.swift`

**Interfaces:**
- Produces: the fourteen types are `internal`. Run
  `scripts/sheet-bound-inventory` for the current list and its visibility
  column; as of 2026-10-18 it is `ChangeKeyPassphraseSheet`,
  `ConnectFailureView`, `ConnectingAttemptView`, `CorrectKeyPassphraseSheet`,
  `GenerateKeySheet`, `LoginSetEditorView`, `LostConnectionView`,
  `RenameKeySheet`, `SnippetEditorView`, `TagFilterSheet`,
  `TerminalPanelHeader`, plus `TerminalSettingsTab`, `CLISettingsSection`,
  `TagFilterJoinPicker`.

- [ ] **Step 1: Write the failing test**

The positive check is a compile-time one: a test file that mentions each
type is only buildable when every one of them is internal.

```swift
@Test func everyBoundedViewIsReachableFromTests() {
    let types: [Any.Type] = [
        ChangeKeyPassphraseSheet.self, ConnectFailureView.self, /* …all fourteen… */
    ]
    #expect(types.count == 14)
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter BoundedViewVisibilityTests`
Expected: FAIL to BUILD — `cannot find 'ChangeKeyPassphraseSheet' in scope`.
A build failure is the red here; record the first such line verbatim.

- [ ] **Step 3: Drop `private` from the fourteen declarations**

Change `private struct X: View` to `struct X: View`. Nothing else. Do not
reorder, rename, or move a type.

- [ ] **Step 4: Run it and watch it pass**

Run: `swift test --filter BoundedViewVisibilityTests`
Expected: PASS, 1 test.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: no new failures. A name collision with another internal type is
the one thing this step can surface.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacSCPAppKit Tests/macSCPAppKitTests/BoundedViewVisibilityTests.swift
git commit -m "refactor(views): make the bounded views reachable from the test target"
```

---

### Task 4: `SheetBound` and the `BoundedView` protocol

**Files:**
- Create: `Sources/MacSCPAppKit/SheetBound.swift`
- Create: `Tests/macSCPAppKitTests/SheetBoundTests.swift`

**Interfaces:**
- Produces:

```swift
public enum SheetBound: Equatable, Sendable {
    case width(CGFloat)
    case size(width: CGFloat, height: CGFloat)
    case capped(minWidth: CGFloat, maxWidth: CGFloat)

    /// The width a measurement is compared against: the fixed width, or a
    /// cap's MAXIMUM — a cap clips at its maximum, and comparing against
    /// its minimum would pass everything.
    public var grantedWidth: CGFloat { get }

    /// The height a measurement is compared against, or nil where the view
    /// does not fix one.
    public var grantedHeight: CGFloat? { get }
}

protocol BoundedView: View {
    static var bound: SheetBound { get }
}

extension View {
    func sheetBound(_ bound: SheetBound) -> some View
}
```

`sheetBound` applies `.frame(width:)`, `.frame(width:height:)` or
`.frame(minWidth:maxWidth:)` to match the case, so no view's rendered size
changes in this task.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aCapIsMeasuredAgainstItsMaximum()
// #expect(SheetBound.capped(minWidth: 420, maxWidth: 460).grantedWidth == 460)

@Test func aFixedWidthIsItsOwnGrant()
// #expect(SheetBound.width(520).grantedWidth == 520)
// #expect(SheetBound.width(520).grantedHeight == nil)

@Test func aFixedSizeGrantsBothAxes()
// #expect(SheetBound.size(width: 720, height: 460).grantedHeight == 460)

@Test func theModifierDoesNotChangeTheRenderedWidth()
// for each case, host Color.clear.sheetBound(case) and
// #expect(hostedWidth == case.grantedWidth) for .width and .size
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter SheetBoundTests`
Expected: FAIL — `SheetBound` does not exist.

- [ ] **Step 3: Implement `SheetBound`, `BoundedView` and `sheetBound`**

- [ ] **Step 4: Run them and watch them pass**

Run: `swift test --filter SheetBoundTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPAppKit/SheetBound.swift Tests/macSCPAppKitTests/SheetBoundTests.swift
git commit -m "feat(views): declare a view's size bound as a value"
```

---

### Task 5: Migrate all thirty-three views to declare their bound

**Files:**
- Modify: every file `scripts/sheet-bound-inventory` lists (14 files as of
  2026-10-18)
- Modify: `Sources/MacSCPAppKit/FileActionEditor.swift` — `sheetWidth`
  becomes `static let bound: SheetBound = .width(520)`
- Modify: `Tests/macSCPAppKitTests/FileActionEditorLayoutGuardTests.swift` —
  its `FileActionEditor.sheetWidth` reference becomes
  `FileActionEditor.bound.grantedWidth` **in this same task**. The file is
  not deleted until Task 6; leaving the rename to then would break the
  build in between, which is the one ordering trap in this plan.
- Create: `Tests/macSCPAppKitTests/BoundDeclarationScanTests.swift`

**Interfaces:**
- Consumes: `SheetBound`, `BoundedView`, `sheetBound(_:)` from Task 4.
- Produces: 33 types conforming to `BoundedView`, each applying
  `.sheetBound(Self.bound)` in its `body` and spelling no size literal
  there.

- [ ] **Step 1: Write the failing scan, with its positive**

```swift
@Test func noViewSpellsASizeLiteralAtItsRoot() throws
// Negative half: over the app's own sources —
// SourceCorpus.files(under: SourceCorpus.url(of: .sources)
//     .appendingPathComponent("MacSCPAppKit"))
// — the blanked
// code view contains no root-level `.frame(width: <digits>` ,
// `.frame(width: <digits>, height:` or `.frame(minWidth: <digits>, maxWidth:`.

@Test func theScanSeesTheFileItClaimsToRead() throws
// Positive half, required beside the negative: the same corpus DOES
// contain `.sheetBound(Self.bound)` at least 33 times, and contains the
// string `FileActionEditor` — so a scan reading an empty corpus fails here
// rather than passing above.
```

- [ ] **Step 2: Run them and watch the first fail**

Run: `swift test --filter BoundDeclarationScanTests`
Expected: FAIL — the negative half lists the 31 literals still present.
Record the first three lines verbatim.

- [ ] **Step 3: Migrate, in one pass per file**

For each entry the inventory prints: add `: BoundedView` to the type, add
`static let bound: SheetBound = <the case matching its spelling>`, and
replace the literal frame with `.sheetBound(Self.bound)`. The numbers come
from the inventory's `bound` column; copy them, do not retype them from
memory. `ContentView+Detail.swift:724`'s nested cap belongs to the type the
inventory names for it — check, because it is the one entry the three
commands do not return.

- [ ] **Step 4: Run them and watch them pass**

Run: `swift test --filter BoundDeclarationScanTests`
Expected: PASS, 2 tests.

- [ ] **Step 5: Run the inventory and confirm it finds nothing**

Run: `python3 -I scripts/sheet-bound-inventory`
Expected: `0 returned by the three commands`. The script's own figure is now
zero, which is the point: one marker replaces three spellings.

- [ ] **Step 6: Run the whole suite**

Run: `swift test`
Expected: no new failures. No rendered size has changed.

- [ ] **Step 7: Commit**

```bash
git add Sources/MacSCPAppKit Tests/macSCPAppKitTests/BoundDeclarationScanTests.swift
git commit -m "refactor(views): declare every bounded view's bound through one marker"
```

---

### Task 6: The registry and the clipping guard

**Files:**
- Create: `Tests/macSCPAppKitTests/BoundedViewRegistry.swift`
- Create: `Tests/macSCPAppKitTests/BoundedViewLayoutGuardTests.swift`
- Delete: `Tests/macSCPAppKitTests/FileActionEditorLayoutGuardTests.swift`
  (its two drafts become the `FileActionEditor` entries; its three positive
  checks move to the new suite, unchanged in meaning)

**Interfaces:**
- Consumes: `LayoutMeasure` (Task 2), `SheetBound`/`BoundedView` (Task 4).
- Produces:

```swift
@MainActor
struct BoundedViewEntry {
    let typeName: String       // must equal the conforming type's name
    let stateName: String      // what this entry puts on screen
    let bound: SheetBound
    let content: @MainActor () -> AnyView   // the view's own body content
}

@MainActor
enum BoundedViewRegistry { static var all: [BoundedViewEntry] { get } }
```

- [ ] **Step 1: Write the failing guard**

```swift
@Test func noViewNeedsMoreThanItsBoundGrantsInAnyLanguage() {
    for entry in BoundedViewRegistry.all {
        for locale in LayoutMeasure.shippedLocales {
            let width = LayoutMeasure.minimumWidth(locale: locale, of: entry.content)
            #expect(width <= entry.bound.grantedWidth,
                "\(entry.typeName), \(entry.stateName), \(locale): needs \(width) pt, granted \(entry.bound.grantedWidth) pt")
            if let grantedHeight = entry.bound.grantedHeight {
                let height = LayoutMeasure.minimumHeight(
                    locale: locale, at: entry.bound.grantedWidth, of: entry.content)
                #expect(height <= grantedHeight,
                    "\(entry.typeName), \(entry.stateName), \(locale): needs \(height) pt tall, granted \(grantedHeight) pt")
            }
        }
    }
}

@Test func theRegistryMeasuresSomething()   // all > 0, and widths differ across locales for at least one entry
@Test func everyShippedLanguageIsMeasured() // superset of en, de, fr, pl
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter BoundedViewLayoutGuardTests`
Expected: FAIL — the registry does not exist.

- [ ] **Step 3: Build the registry in four passes, committing after each**

Each pass adds entries and leaves the suite green, answering any red with a
Remedy from the Global Constraints and saying in the commit message which
one. The four passes, by how a view is constructed:

1. **Value-in, closures-out sheets** — `SnippetActionSheet`,
   `SnippetDryRunSheet`, `SnippetVariablePromptSheet`,
   `ExtractDestinationSheet`, `FileActionConfirmSheet`, `PresignedURLSheet`,
   `FileActionEditor` (two states, as the deleted suite had).
2. **`SSHKeysSheet`'s five sub-sheets** plus `SSHKeysSheet` itself.
3. **The both-axes sheets** — `AuditLogSheet`, `FileActionsSheet`,
   `HiddenImportsSheet`, `ImportFromSourceSheet`, `KnownHostsSheet`,
   `LoginSetsSheet`, `ServerCertificatesSheet`, `SnippetsSheet`,
   `WhatsNewSheet`, `TagFilterSheet`, `SnippetEditorView`,
   `LoginSetEditorView`.
4. **The capped views** — `ConnectFailureDetailsSheet`, `ConnectionFormView`,
   `LostConnectionView`, `ConnectFailureView`, `ConnectingAttemptView`,
   `TunnelHostKeyPromptView`, `TerminalPanelHeader`.

Each entry's `stateName` names the state and each state is the one that puts
that view's widest and tallest content up — a listing with rows rather than
an empty one, an error sentence shown rather than absent. Where a view needs
a store or a provider, build it over `FileManager.default.temporaryDirectory`
or the existing test double, as the deleted suite did for `FileActionStore`.

- [ ] **Step 4: Run the guard and watch it pass**

Run: `swift test --filter BoundedViewLayoutGuardTests`
Expected: PASS, 3 tests, 33 types covered.

- [ ] **Step 5: Commit** (once per pass, four commits)

```bash
git add Tests/macSCPAppKitTests
git commit -m "test(views): measure <pass> against its declared bound in every language"
```

---

### Task 7: Hold the registry to the conformances

**Files:**
- Create: `Tests/macSCPAppKitTests/BoundedViewCoverageTests.swift`

**Interfaces:**
- Consumes: `BoundedViewRegistry` (Task 6), `SourceCorpus`.

- [ ] **Step 1: Write the failing test**

Set equality, not a count — a count that happens to match hides a swap.

```swift
@Test func everyConformerIsInTheRegistry() throws {
    let declared = try boundedViewTypeNamesInSources()   // from `: BoundedView` conformances
    let measured = Set(BoundedViewRegistry.all.map(\.typeName))
    #expect(declared == measured, "only in Sources: \(declared.subtracting(measured)); only in the registry: \(measured.subtracting(declared))")
}

@Test func theScanFindsTheConformancesAtAll() throws {
    // The positive beside it: the scan returns at least 33 names and
    // contains "FileActionEditor".
}
```

- [ ] **Step 2: Run it and watch it fail**

Temporarily remove one entry from the registry to see the message name that
type; put it back. This plant edits a tracked file, so it goes through
`scripts/mutation-probe --apply`, never a hand-rolled restore.

Expected: FAIL naming the removed type.

- [ ] **Step 3: Implement `boundedViewTypeNamesInSources()`**

Read `SourceCorpus.code(of:)` for each file under
`SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit")` —
`Root` has exactly two cases, `.sources` and `.tests`, so the app tree is
reached by that path and not by a case of its own. The blanked view, so a
comment quoting a conformance is not counted — and collect the type name
preceding each `: BoundedView` conformance.

- [ ] **Step 4: Run it and watch it pass**

Run: `swift test --filter BoundedViewCoverageTests`
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
git add Tests/macSCPAppKitTests/BoundedViewCoverageTests.swift
git commit -m "test(views): hold the layout registry to the conformances in Sources"
```

---

### Task 8: `AtLeastIdealWidth` and the three rigid components

**Files:**
- Create: `Sources/MacSCPAppKit/RigidControls.swift`
- Create: `Tests/macSCPAppKitTests/RigidControlTests.swift`

**Interfaces:**
- Produces:

```swift
/// Takes the larger of its subview's ideal width and what is proposed, so
/// the subview stretches but is never compressed below its ideal. This is
/// what "rigid" means here: a floor at the ideal, not a shrink to it.
struct AtLeastIdealWidth: Layout { … }

struct SegmentedChoice<Value: Hashable>: View {
    init(_ accessibilityLabel: String, selection: Binding<Value>, options: [(value: Value, label: String)])
}
struct RadioChoice<Value: Hashable & CaseIterable>: View {
    init(_ accessibilityLabel: String, selection: Binding<Value>, label: @escaping (Value) -> String)
}
struct CheckboxRow: View {
    init(_ label: String, isOn: Binding<Bool>)
}
```

The `Layout` body is the one algorithm the signature does not determine:

```swift
func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let ideal = subviews[0].sizeThatFits(.unspecified)
    let width = max(ideal.width, proposal.width ?? ideal.width)
    return CGSize(width: width, height: subviews[0].sizeThatFits(
        ProposedViewSize(width: width, height: proposal.height)).height)
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func eachComponentIsRigidInEveryLanguage() {
    // For each of the three components, hosting a sample:
    // #expect(LayoutMeasure.minimumWidth(locale:of:) == LayoutMeasure.idealWidth(locale:of:))
}

@Test func theRawControlsAreNotRigid() {
    // The positive beside it, and the measurement that justifies the work:
    // a bare segmented picker reports a minimum BELOW its ideal in at
    // least one catalogue. Measured 2026-10-17: pl 173.5 vs 219.0.
}

@Test func aRigidControlStillStretches() {
    // Hosted at a proposal far above its ideal, the component reports the
    // proposal, not the ideal — this is what separates a floor from a
    // shrink, and it is the property `.fixedSize()` would fail.
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter RigidControlTests`
Expected: FAIL — the components do not exist.

- [ ] **Step 3: Implement the layout and the three components**

Each component wraps its control in `AtLeastIdealWidth` and keeps the
styling the call sites use today (`.labelsHidden()`, `.pickerStyle(…)`,
`.toggleStyle(.checkbox)`). No component spells a display string: labels
arrive as parameters.

- [ ] **Step 4: Run them and watch them pass**

Run: `swift test --filter RigidControlTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPAppKit/RigidControls.swift Tests/macSCPAppKitTests/RigidControlTests.swift
git commit -m "feat(views): add controls that cannot be compressed below their ideal width"
```

---

### Task 9: Migrate the control sites inside bounded views

**Files:**
- Modify: the control sites `python3 -I scripts/sheet-bound-inventory` and
  the census command below identify as living in a `BoundedView`
- Test: `Tests/macSCPAppKitTests/BoundedViewLayoutGuardTests.swift` (Task 6,
  unchanged — it is the net this task falls into)

**Interfaces:**
- Consumes: the three components (Task 8); the clipping guard (Task 6).

- [ ] **Step 1: List the sites**

Run: `grep -rnF '.pickerStyle(.segmented)' Sources/MacSCPAppKit/` and the
same for `.toggleStyle(.checkbox)` and `.pickerStyle(.radioGroup)`.
Expected as of 2026-10-18: 21, 4 and 2 lines. Keep only those inside a
`BoundedView`.

- [ ] **Step 2: Replace each with its component, one file per commit**

After each file, run `swift test --filter BoundedViewLayoutGuardTests`. A
red here is the expected shape of this task: a squeeze has become an
overflow, which is the whole point. Answer it with a Remedy, and say in the
commit message which Remedy and what it measured.

- [ ] **Step 3: Run the whole suite**

Run: `swift test`
Expected: green, with every bounded view measured.

- [ ] **Step 4: Commit** (one per file, as Step 2 says)

---

### Task 10: Migrate the control sites in resizable containers

**Files:**
- Modify: `Sources/MacSCPAppKit/ConnectionFormView.swift` (5 sites),
  `SettingsView.swift` (2), `FileSearchBar.swift` (1),
  `SidebarTagFilterBar.swift` (1), `SheetSearchField.swift` (1)
- Create: `Tests/macSCPAppKitTests/ResizableContainerFloorTests.swift`

**Interfaces:**
- Consumes: the three components (Task 8), `LayoutMeasure` (Task 2).
- Produces: a standing check on the six containers' minimum widths.

- [ ] **Step 1: Record each container's minimum width BEFORE the change**

Run a one-off measurement through `LayoutMeasure.minimumWidth` for the six
containers of spec Constraint 3 and write the figures into the new test's
doc comment. These are the "before" numbers the next step is compared with.

- [ ] **Step 2: Write the failing test**

```swift
@Test func noResizableContainerOutgrowsTheWindowItLivesIn() {
    // For each of the six: its minimum width in every catalogue is at most
    // the content width its window offers — MainWindowSizePlan.formSize
    // (700x460) for ConnectionFormView, and the recorded floor for each
    // other container.
}
```

- [ ] **Step 3: Replace the nine sites with their components**

- [ ] **Step 4: Run the test**

Run: `swift test --filter ResizableContainerFloorTests`
Expected: PASS. **If a container now needs more than its window offers,
stop and ask the maintainer** — a window the user can no longer make as
narrow is user-visible behaviour, and whether that is acceptable, and
whether it owes a `noix-docs` page, is unsettled (spec Constraint 3).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPAppKit Tests/macSCPAppKitTests/ResizableContainerFloorTests.swift
git commit -m "fix(views): stop the resizable containers squeezing their localized controls"
```

---

### Task 11: Close the raw styles off

**Files:**
- Create: `Tests/macSCPAppKitTests/RigidControlScanTests.swift`

**Interfaces:**
- Consumes: `SourceCorpus`, the components (Task 8).

- [ ] **Step 1: Write the failing scan with its positive**

```swift
@Test func theRawStylesAppearOnlyInTheComponentFile() throws
// Negative: in the blanked code view of each file under
// SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit"),
// the three
// raw style spellings appear in no file but RigidControls.swift.

@Test func theComponentFileStillCarriesThem() throws
// Positive beside it: RigidControls.swift DOES contain all three, so a
// scan that has stopped matching anything fails here instead of passing
// above.
```

- [ ] **Step 2: Run it and watch it fail or pass**

Run: `swift test --filter RigidControlScanTests`
Expected: PASS if Tasks 9 and 10 left no site behind; a FAIL names the
file that still spells a raw style, which is the point.

- [ ] **Step 3: Commit**

```bash
git add Tests/macSCPAppKitTests/RigidControlScanTests.swift
git commit -m "test(views): keep the compressible control styles out of call sites"
```

---

### Task 12: Closeout

**Files:**
- Modify: `docs/BACKLOG.md` — the three rows added 2026-10-17
- Modify: `scripts/sheet-bound-inventory` — it now finds nothing by the
  three commands; make it list `BoundedView` conformers instead, so it
  stays the inventory rather than becoming a script that prints zero
- Modify: `/Users/noidee/_dev/noix-docs` only if Task 10 changed a window
  floor, on its own worktree and branch, never pushed without the
  maintainer asking

- [ ] **Step 1: Close the two rows this plan answers**

The "Thirteen sheets and a popover" row and the "only layout guard …
Darwin 27" row. Each closing line names the commit and the figure, and
quotes any wording it withdraws.

- [ ] **Step 2: Leave the third row open**

The unexplained German screenshot row stays open: this plan does not
explain it, and its next step is still a sight check.

- [ ] **Step 3: Re-point the inventory script**

- [ ] **Step 4: Run the whole suite and the inventory**

Run: `swift test` and `python3 -I scripts/sheet-bound-inventory`
Expected: green; the inventory lists 33 conformers.

- [ ] **Step 5: Commit**

```bash
git add docs/BACKLOG.md scripts/sheet-bound-inventory
git commit -m "docs: close the sheet-bound rows this plan answers"
```
