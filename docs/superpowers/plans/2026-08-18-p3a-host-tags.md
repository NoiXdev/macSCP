# P3a: Host tags and sidebar filter — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Saved hosts get tags, and the sidebar gets its first filter
element — a chip row that restricts to one tag.

**Architecture:** Tag normalization lives as **one** function in Core and
is called by `Snippet` and `StoredSession`. Which groups and sessions are
visible while a tag is active, and which empty state applies, is a testable
Core type; the sidebar reads from it and decides nothing itself.

**Tech Stack:** Swift 6, `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+,
SwiftUI, Swift Testing, two test targets.

Spec: `docs/superpowers/specs/2026-08-18-p3-ordnung-design.md`, section P3a.

## Global Constraints

- **Code, comments, test names: English.** Internal docs (`docs/`) German.
- **Every new L10n key in all four catalogs** (en/de/fr/pl), identical key
  sets. Proof:
  `for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done`
- **Never a line number in a comment.**
- **No secret in a log, error, or test failure message.**
- **This plan's prose is a claim to be checked.** In the two pre-phases,
  several briefs had a real error in them. If the code diverges, **the
  plan** is wrong — report it, don't adapt it.
- **Two probes before every commit**, both:
  1. Would a test stay green if the function returned a constant?
  2. **Which claim in my doc comment is observed by no test?**
     This question found a real gap in every task in P2, including a
     Critical and one comment that was simply wrong.
- **The GUI is not launched.** `scripts/package-app` is allowed,
  `scripts/release` is not.
- Conventional Commits, English, footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Full suite green before every commit. Starting point: **1958 tests in 166
  suites** — measure it yourself, never copy the number.

## Files

| File | Responsible for |
|---|---|
| `Sources/macSCPCore/Tags/TagList.swift` (new) | the one normalization rule |
| `Sources/macSCPCore/Terminal/Snippet.swift` | calls it instead of repeating it |
| `Sources/macSCPCore/Sessions/StoredSession.swift` | `tags` field + decode default |
| `Sources/macSCPCore/Sessions/SessionExportCodec.swift` | `tags` in the exchange format |
| `Sources/macSCPCore/Presentation/SidebarVisibility.swift` (new) | what's visible while a tag is active |
| `Sources/macSCPCore/Presentation/SessionListViewModel.swift` | `save(… tags:)` |
| `Sources/MacSCPAppKit/ConnectionFormView.swift` | tag field in the form |
| `Sources/MacSCPAppKit/SessionSidebar.swift` | chip row, empty state, wiring |

---

### Task 1: One rule, two callers

**Measured current state:** `Snippet.init?` normalizes inline:

```swift
var seen = Set<String>()
self.tags = tags
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty && seen.insert($0).inserted }
```

Check this yourself against the code before you move it.

**Files:**
- Create: `Sources/macSCPCore/Tags/TagList.swift`
- Modify: `Sources/macSCPCore/Terminal/Snippet.swift`
- Create: `Tests/macSCPCoreTests/TagListTests.swift`

**Interfaces:**
- Produces: `public enum TagList { public static func normalized(_ tags: [String]) -> [String] }`

- [ ] **Step 1: Tests first**

```swift
@Test func normalizationTrimsDropsEmptiesAndDeduplicatesKeepingOrder() {
    #expect(TagList.normalized(["  docker ", "", "web", "docker", "   "])
            == ["docker", "web"])
}

@Test func normalizationKeepsCaseSoTwoSpellingsStayTwoTags() {
    #expect(TagList.normalized(["Docker", "docker"]) == ["Docker", "docker"])
}

@Test func normalizationIsIdempotent() {
    let once = TagList.normalized([" a ", "b", "a"])
    #expect(TagList.normalized(once) == once)
}
```

- [ ] **Step 2: Run it red**

Run: `swift test --filter TagListTests`
Expected: FAIL, `TagList` doesn't exist.

- [ ] **Step 3: The function**

```swift
/// The one normalization every tag vocabulary in this app goes through:
/// trimmed, empties dropped, exact duplicates dropped, order of first
/// appearance kept, case left as typed.
///
/// Case is deliberately preserved — `Docker` and `docker` stay two tags.
/// Damping that is the input control's job (a case-insensitive suggestion
/// list), not this function's: folding case here would silently rewrite
/// what the user typed.
///
/// Host tags and snippet tags remain INDEPENDENT vocabularies — a host tag
/// hides no snippet. Only the rule is shared, because two copies of one
/// rule drift apart without any test noticing.
public enum TagList {
    public static func normalized(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
```

- [ ] **Step 4: `Snippet` calls it instead of repeating it**

In `Snippet.init?` replace the four lines with:

```swift
self.tags = TagList.normalized(tags)
```

Adjust the doc comment on `Snippet.tags` so it points to `TagList` instead
of describing the rule a second time in prose.

- [ ] **Step 5: The equivalence guard**

A test comparing both paths against the same inputs — it's the reason this
task exists:

```swift
@Test func snippetTagsGoThroughTheSharedRule() {
    let inputs: [[String]] = [
        ["  docker ", "", "web", "docker"],
        ["Docker", "docker"],
        [],
        ["   "],
        ["a", "b", "a", "b"],
    ]
    for input in inputs {
        let snippet = Snippet(name: "n", command: "c", tags: input)
        #expect(snippet?.tags == TagList.normalized(input))
    }
}
```

- [ ] **Step 6: Green + full suite + commit**

```bash
swift test --filter TagListTests
swift test
git commit -m "refactor(core): give both tag vocabularies one normalization"
```

---

### Task 2: `tags` on `StoredSession`

**Measured current state:** `StoredSession` has an **explicit**
`init(from:)` with `private enum CodingKeys`. `paneVisibility` is read there
as `decodeIfPresent(…) ?? .filesOnly` — exactly the pattern this field
needs. `groupID` is the precedent for a field that belongs to the session
but is **not a connection property**. Tags belong in the same category,
**not** in `FieldValues`.

**Files:**
- Modify: `Sources/macSCPCore/Sessions/StoredSession.swift`
- Create: `Tests/macSCPCoreTests/StoredSessionTagsTests.swift`

**Interfaces:**
- Consumes: `TagList.normalized(_:)` from Task 1
- Produces: `StoredSession.tags: [String]`, parameter `tags: [String] = []` in `init`

- [ ] **Step 1: Test first — against a literal legacy file**

```swift
@Test func aStoredSessionWithoutTheTagsKeyDecodesAsUntagged() throws {
    let json = """
    {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"box","kind":"ssh"}
    """
    let session = try JSONDecoder().decode(StoredSession.self, from: Data(json.utf8))
    #expect(session.tags.isEmpty)
}

@Test func decodingNormalizesTagsSoAHandEditedFileCannotSmuggleDuplicates() throws {
    let json = """
    {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"box","kind":"ssh",
     "tags":["  docker ","docker",""]}
    """
    let session = try JSONDecoder().decode(StoredSession.self, from: Data(json.utf8))
    #expect(session.tags == ["docker"])
}

@Test func tagsSurviveAnEncodeDecodeRoundTrip() throws {
    let original = StoredSession(name: "box", tags: ["docker", "web"])
    let data = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode(StoredSession.self, from: data)
    #expect(restored.tags == ["docker", "web"])
}
```

- [ ] **Step 2: Run it red**

Run: `swift test --filter StoredSessionTagsTests`
Expected: FAIL — `tags` doesn't exist (compile error on the third test,
`session.tags` on the first).

- [ ] **Step 3: The field**

Property beside `paneVisibility`:

```swift
/// Free-form labels for the sidebar's tag filter. Normalized through
/// `TagList` on every write path — the initializer AND the decoder — so a
/// hand-edited store file cannot smuggle an untrimmed or duplicate tag
/// past the rule.
///
/// Beside `groupID` and `paneVisibility` rather than inside `FieldValues`:
/// a tag is a property of the saved session, not of the protocol it speaks.
public var tags: [String] = []
```

`init`: parameter `tags: [String] = []`, assigned as
`self.tags = TagList.normalized(tags)`.

`CodingKeys`: add `tags`.

`init(from:)`:

```swift
tags = TagList.normalized(try c.decodeIfPresent([String].self, forKey: .tags) ?? [])
```

- [ ] **Step 4: Green + full suite + commit**

```bash
swift test --filter StoredSessionTagsTests
swift test
git commit -m "feat(core): let a saved session carry tags"
```

---

### Task 3: Tags survive export and import

**Measured current state:** `ExportedSession` in
`Sources/macSCPCore/Sessions/SessionExportCodec.swift` carries
`public var paneVisibility: PaneVisibility?`, lists it in its
`CodingKeys` and writes it with `encodeIfPresent`. Look at what the export
does with `paneVisibility` **and** with `groupID`, and do the same. Write
into the report what you found.

**Files:**
- Modify: `Sources/macSCPCore/Sessions/SessionExportCodec.swift`
- Modify/Create: the associated tests

**Interfaces:**
- Consumes: `StoredSession.tags` from Task 2

- [ ] **Step 1: Test first**

```swift
@Test func exportRoundTripCarriesTags() throws {
    let session = StoredSession(name: "box", tags: ["docker", "web"])
    let exported = ExportedSession(from: session)   // use the actual
                                                    // construction site
    let data = try JSONEncoder().encode(exported)
    let restored = try JSONDecoder().decode(ExportedSession.self, from: data)
    #expect(restored.tags == ["docker", "web"])
}

@Test func anExportFileWithoutTheTagsKeyImportsAsUntagged() throws {
    // Literal legacy JSON of an ExportedSession, without "tags".
    // Read the exact required fields off the type, don't guess.
}
```

Write out the second test **in full** once you've read `ExportedSession`'s
required fields — it's the proof of migration and must not stay a sketch.

- [ ] **Step 2: Red, then add the field**

`tags` on `ExportedSession` following the `paneVisibility` pattern
(incl. `CodingKeys`, `decodeIfPresent`, `encodeIfPresent` or `encode` —
**as the existing precedent does it**, not as you'd rather have it). Wire
both directions: session → export and import → session.

- [ ] **Step 3: Green + full suite + commit**

```bash
swift test
git commit -m "feat(core): carry session tags through export and import"
```

---

### Task 4: What's visible while a tag is active (Core)

**Why Core:** In P2, a display decision lived in the view body and was in
the end only held down by a source guard, after it had produced an empty
window. This decision becomes a testable type from the start.

**Measured current state:** `SessionListViewModel.sessions(inGroup:)`
filters `sessions.filter { $0.groupID == groupID }`. `StoredGroup` has
`id` and `name`. The sidebar renders groups as a `Section` and, next to
it, its own section "IMPORTED". `SnippetTagFilter` lives in the **App**
layer (`SnippetsPresentation.swift`) and is **not** reusable here — it
answers a different question (does a snippet match?) than this one (what
does the list show?).

**Files:**
- Create: `Sources/macSCPCore/Presentation/SidebarVisibility.swift`
- Create: `Tests/macSCPCoreTests/SidebarVisibilityTests.swift`

**Interfaces:**
- Produces:

```swift
public struct SidebarVisibility: Equatable, Sendable {
    public enum Emptiness: Equatable, Sendable {
        case notEmpty
        case noSessionsAtAll
        case filterMatchesNothing
    }
    public let groups: [StoredGroup]
    public let ungrouped: [StoredSession]
    public let sessionsByGroup: [UUID: [StoredSession]]
    public let showsImportedSection: Bool
    public let emptiness: Emptiness

    public static func compute(
        sessions: [StoredSession],
        groups: [StoredGroup],
        activeTag: String?
    ) -> SidebarVisibility

    public static func availableTags(in sessions: [StoredSession]) -> [String]

    public static func resolvedTag(_ activeTag: String?, in sessions: [StoredSession]) -> String?
}
```

- [ ] **Step 1: Tests first**

```swift
private func session(_ name: String, group: UUID? = nil, tags: [String] = [])
    -> StoredSession {
    StoredSession(name: name, groupID: group, tags: tags)
}

@Test func withoutAFilterEverythingShows() {
    let g = StoredGroup(name: "prod")
    let v = SidebarVisibility.compute(
        sessions: [session("a", group: g.id), session("b")],
        groups: [g], activeTag: nil)
    #expect(v.groups == [g])
    #expect(v.ungrouped.map(\.name) == ["b"])
    #expect(v.showsImportedSection)
    #expect(v.emptiness == .notEmpty)
}

@Test func anActiveTagHidesGroupsWithoutAMatchAndTheImportedSection() {
    let hit = StoredGroup(name: "prod")
    let miss = StoredGroup(name: "lab")
    let v = SidebarVisibility.compute(
        sessions: [session("a", group: hit.id, tags: ["docker"]),
                   session("b", group: miss.id)],
        groups: [hit, miss], activeTag: "docker")
    #expect(v.groups == [hit])
    #expect(v.sessionsByGroup[hit.id]?.map(\.name) == ["a"])
    #expect(v.sessionsByGroup[miss.id] == nil)
    #expect(!v.showsImportedSection)
}

@Test func theTwoEmptyStatesAreDistinguishable() {
    let none = SidebarVisibility.compute(sessions: [], groups: [], activeTag: nil)
    #expect(none.emptiness == .noSessionsAtAll)

    let filtered = SidebarVisibility.compute(
        sessions: [session("a", tags: ["web"])], groups: [], activeTag: "docker")
    #expect(filtered.emptiness == .filterMatchesNothing)
}

@Test func tagComparisonIsExactSoTwoSpellingsStayTwoTags() {
    let v = SidebarVisibility.compute(
        sessions: [session("a", tags: ["Docker"])], groups: [], activeTag: "docker")
    #expect(v.emptiness == .filterMatchesNothing)
}

@Test func availableTagsAreSortedAndDeduplicatedAcrossSessions() {
    #expect(SidebarVisibility.availableTags(in: [
        session("a", tags: ["web", "docker"]),
        session("b", tags: ["docker"]),
    ]) == ["docker", "web"])
}

@Test func aTagNobodyCarriesAnymoreResolvesToNoFilter() {
    #expect(SidebarVisibility.resolvedTag("gone", in: [session("a", tags: ["web"])]) == nil)
    #expect(SidebarVisibility.resolvedTag("web", in: [session("a", tags: ["web"])]) == "web")
}
```

- [ ] **Step 2: Run it red**

Run: `swift test --filter SidebarVisibilityTests`
Expected: FAIL — `SidebarVisibility` doesn't exist.

- [ ] **Step 3: The type**

`compute` filters on `tags.contains(activeTag)` when `activeTag` is
non-nil (exact comparison, the way `SnippetTagFilter.matches` does it),
drops groups with no match, sets `showsImportedSection = (activeTag == nil)`
and determines `emptiness` from (are there any sessions at all?) and (is it
filtered and nothing is left?).

`availableTags` collects all tags across all sessions, deduplicates and
sorts them (`sorted()`, so the chip row stays stable).

`resolvedTag` returns `nil` if nobody carries the tag anymore.

**Explicitly apply the second probe here:** every claim you write into the
doc comment needs a test that observes it — or it must not be there.

- [ ] **Step 4: Green + full suite + commit**

```bash
swift test --filter SidebarVisibilityTests
swift test
git commit -m "feat(core): decide what the sidebar shows while a tag is active"
```

---

### Task 5: Tags in the connection form

**Measured current state:** `SessionListViewModel.save` today has the
signature

```swift
public func save(
    name: String, values: FieldValues, password: String,
    kind: ConnectionKind = .ssh,
    groupID: UUID? = nil, loginSetID: UUID? = nil,
    jump: StoredSession.JumpSpec? = nil, jumpSecret: String? = nil
) -> StoredSession?
```

It looks for an existing session **by name** and mutates it, otherwise it
builds a new one. `ConnectionFormView` (about 1000 lines) renders the name
field in a `TextField` near the start of the form; the backend fields come
from the generic `SchemaFormView`. A tag is **not** a schema field and
belongs beside the name, not in the renderer.

`SnippetTagField` (`Sources/MacSCPAppKit/SnippetTagField.swift`) is a
`View` with `@Binding var tags: [String]`. **Measure for yourself whether
it can be reused unchanged** — if it depends on snippet-specific
suggestions, either split off the suggestion part or build a
similarly-looking field that uses the same `TagList` rule. Whichever
applies belongs in the report.

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift`
- Modify: `Sources/MacSCPAppKit/ConnectionFormView.swift`
- Modify: all four `Localizable.strings`
- Modify/Create: tests

**Interfaces:**
- Consumes: `StoredSession.tags`, `TagList.normalized(_:)`
- Produces: `save(… tags: [String] = [])`

- [ ] **Step 1: VM test first**

```swift
@Test func savingCarriesTagsOntoTheStoredSession() throws {
    // Use this test target's existing VM setup.
    let saved = viewModel.save(name: "box", values: values, password: "",
                               tags: ["  docker ", "docker", "web"])
    #expect(saved?.tags == ["docker", "web"])
}

@Test func savingAgainUnderTheSameNameReplacesTheTags() throws {
    _ = viewModel.save(name: "box", values: values, password: "", tags: ["web"])
    let again = viewModel.save(name: "box", values: values, password: "", tags: ["docker"])
    #expect(again?.tags == ["docker"])
}
```

The second test is not extra: `save` mutates a same-named session, and
without it whether tags are replaced or merged would stay open. It pins
"replaced".

- [ ] **Step 2: Red, then extend `save`**

Parameter `tags: [String] = []` **at the end** of the signature, so no
existing caller breaks. In the body, `session.tags = TagList.normalized(tags)`
at the same spot `groupID` is set.

- [ ] **Step 3: The form field**

A tag field directly under the name field, with an `L10n.string` label.
New keys:

- `form.tags.label` — "Tags"
- `form.tags.help` — "Comma-separated. Used by the sidebar filter."

Both in **all four** catalogs of `MacSCPAppKit`. The form state holds
`[String]`; the text↔list conversion is done by the field, not the form
view model.

When editing an existing session, the field is pre-filled with its tags,
and on save they go to `save(… tags:)`. Verify both paths against the code
rather than assuming them.

- [ ] **Step 4: Catalog proof + full suite + commit**

```bash
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
swift test
git commit -m "feat(app): tag a saved connection from its form"
```

---

### Task 6: The sidebar — chips, hiding, empty state

**Measured current state:** `SessionSidebar` (about 680 lines) runs
unfiltered through `viewModel.sessions(inGroup:)`, renders groups as
`Section(isExpanded:)` with a `Set<UUID>` in the view state, has its own
`importedSection` section and **no empty state**. Check this for yourself;
if it diverges, the plan is wrong.

`SnippetTagFilterRow` and `SnippetTagFilterChip` in `SnippetsSheet.swift`
are `private` — they are the **visual** template but not directly usable.
Either lift them into a shared file, or build the sidebar's row alongside
them. Decide deliberately and justify it in the report; a literal copy is
the one option this project doesn't want.

**Files:**
- Modify: `Sources/MacSCPAppKit/SessionSidebar.swift`
- Modify: all four `Localizable.strings`
- Create: `Tests/macSCPAppKitTests/SidebarFilterWiringTests.swift`

**Interfaces:**
- Consumes: `SidebarVisibility.compute/availableTags/resolvedTag` from Task 4

- [ ] **Step 1: State + chip row**

`@State private var activeTag: String?` in `SessionSidebar` — **not**
persisted, not in `SettingsStore`. The filter is a view, not a setting.

The chip row sits above the list, is fed from
`SidebarVisibility.availableTags(in: viewModel.sessions)` and shows nothing
at all as long as no session carries a tag — an empty chip bar above a
tagless list would be nothing but a frame.

New keys (all four catalogs):

- `sidebar.filter.all` — "All"
- `sidebar.empty.noSessions` — "No saved connections yet."
- `sidebar.empty.noMatches` — "No connection has this tag."
- `sidebar.empty.clearFilter` — "Show all"

- [ ] **Step 2: List and sections read from `SidebarVisibility`**

One `let visibility = SidebarVisibility.compute(sessions: viewModel.sessions,
groups: viewModel.groups, activeTag: activeTag)` at **one** spot, and read
groups, sessions, `importedSection` and the empty state from it.

**Explicitly not:** a second `if` in the body that checks `session.tags`
directly. Exactly this shape — the decision rebuilt a second time in the
view — was the Critical in P2.

- [ ] **Step 3: The fallback**

If the active tag disappears (session deleted, tag removed), the filter
falls back:

```swift
.onChange(of: viewModel.sessions) { _, sessions in
    activeTag = SidebarVisibility.resolvedTag(activeTag, in: sessions)
}
```

- [ ] **Step 4: The guard**

`SessionSidebar` cannot be instantiated in this project — there is no view
test tool. So a source guard following the pattern of
`PaneRenderConditionGuardTests` and `PaneVisibilityWiringGuardTests` (both
in `Tests/macSCPAppKitTests/`): it checks that the sidebar reads its
visibility from `SidebarVisibility` and **doesn't** hold `.tags` against
`activeTag` directly anywhere.

Prove it: temporarily revert the condition to a direct `tags` comparison,
show the red run, restore it, show green. **Document its blind spots in
its own doc comment**, as honestly as the two existing ones do — a guard
sold as tighter than it is would be worse than none.

- [ ] **Step 5: Catalog proof + full suite + commit**

```bash
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
swift test
git commit -m "feat(app): filter the sidebar by host tag"
```

---

### Task 7: Phase close-out

**Files:**
- Create: `docs/superpowers/specs/2026-08-18-p3a-abschluss.md`

- [ ] **Step 1: Measure**

```bash
swift test 2>&1 | tail -3
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
MACSCP_VERSION="1.2.0-dev" MACSCP_BUILD="$(git rev-list --count HEAD)" ./scripts/package-app
```

Start the build **in the background** and keep working; then check:
`lipo -archs` on both binaries, both resource bundles, all four `.lproj`,
`plutil -lint` on the Info.plist. **The app is not launched.**

- [ ] **Step 2: The report**

It states the measured numbers; what is held by tests and what only by
review (the guard from Task 6 explicitly belongs in the second column,
with its blind spots); what the export does with the new field and why;
whether `SnippetTagField` was reused or not and why; and **explicitly**
that the GUI was not launched — with the list of what the maintainer must
look at: the chip row, the tag field in the form, the hiding of groups and
"IMPORTED" while a filter is active, and both empty states.

- [ ] **Step 3: Commit**

```bash
git commit -m "docs(app): record the host tags phase"
```

---

## Self-review of this plan

**Spec coverage:** One rule, two vocabularies → Task 1. Field beside
`groupID`, `decodeIfPresent`, default `[]` → Task 2. Export/import → Task 3.
Chip filter, hiding of groups and "IMPORTED", fallback, decision in Core →
Tasks 4 and 6. Both empty states → Tasks 4 and 6. Form field → Task 5.
Non-persisted filter state → Task 6, step 1.

**Placeholder:** One is deliberately left open — the second test in Task 3
can only be written once `ExportedSession`'s required fields have been
read, and the step says so explicitly instead of hiding it.

**Type consistency:** `TagList.normalized(_:)` is written the same way in
Tasks 1, 2 and 5. `SidebarVisibility.compute/availableTags/resolvedTag` the
same way in Tasks 4 and 6. `save(… tags:)` defined once in Task 5.
