# Nested folders and free sorting — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Folders can be nested inside one another and everything can be
freely sorted — without a rollback to an older version losing more than the
ordering itself.

**Foundation:** `docs/superpowers/specs/2026-08-29-folder-and-sorting-design.md`

**Architecture:** The rules are pure values in `macSCPCore` — tree
construction, cycle checking, ordering computation, repair of a damaged
import. The store writes, the sidebar displays. **No view computes a
position.**

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English only**.
- Conventional Commits; footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Migrations additive, never destructive.** New fields are optional; a
  file without them stays readable and loses nothing.
- **No new filename**, no second file, no version key.
  `sessions-v2.json` stays.
- **No change to `SessionListViewModel.save`** and its upsert by name.
- **No deleting of sessions.** Dissolving lifts up, it never removes.
- **No test reaches the real keychain, session store, or configuration.**
  Every store points at a temporary directory — `SessionListViewModel
  .init` has had no default values since `ab97f2a`, and that is intentional.
- **User-visible text goes through all four catalogs** (`en`, `de`,
  `fr`, `pl` under `Sources/MacSCPAppKit/Resources/<locale>.lproj/
  Localizable.strings`), reached through `L10n.string(_:_:)` / `L10n.text(_:_:)`.
  **No String Catalog, no `String(localized:)`, no `Bundle.module`** —
  that is what `CLAUDE.md` says, but older context extracts claim the
  opposite. The German **uses du**; `GermanAddressFormTests` enforces it.
- **No line numbers, no location references in comments.** Every number and
  every enumeration is counted in the pass that writes it.
- All six targets are on `.swiftLanguageMode(.v6)`; **CI turns red as soon
  as the number of distinct warning sites exceeds 1.**
- One scratch path per agent, deleted after use.
- The app is not launched, nothing is pushed.

---

### Task 1: The fields and the tree

**Files:**
- Modify: `Sources/macSCPCore/Sessions/StoredGroup.swift`,
  `Sources/macSCPCore/Sessions/StoredSession.swift`
- Create: `Sources/macSCPCore/Sessions/GroupTree.swift`
- Test: `Tests/macSCPCoreTests/GroupTreeTests.swift`

**Interfaces:**
- Produces: `StoredGroup.parentID: UUID?`, `StoredGroup.position: Int`,
  `StoredSession.position: Int`, and the namespace `GroupTree` with
  `wouldCycle(moving:under:in:)`, `repaired(_:)` and `children(of:in:)`.
  Tasks 2, 3 and 4 call into it.

**The measured status quo:** `StoredGroup` carries `id` and `name`,
`StoredSession` among other things `groupID: UUID?`. Both are `Codable`,
`Equatable`, `Sendable`.

- [ ] **Step 1: Write the test first.**

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("Group tree")
struct GroupTreeTests {
    private func group(_ name: String, parent: UUID? = nil, at position: Int = 0)
        -> StoredGroup
    {
        StoredGroup(id: UUID(), name: name, parentID: parent, position: position)
    }

    @Test func aGroupCannotBecomeItsOwnParent() {
        let a = group("a")
        #expect(GroupTree.wouldCycle(moving: a.id, under: a.id, in: [a]))
    }

    @Test func aGroupCannotMoveUnderItsOwnDescendant() {
        let a = group("a")
        let b = group("b", parent: a.id)
        let c = group("c", parent: b.id)
        #expect(GroupTree.wouldCycle(moving: a.id, under: c.id, in: [a, b, c]))
    }

    @Test func anUnrelatedMoveIsFine() {
        let a = group("a")
        let b = group("b")
        #expect(!GroupTree.wouldCycle(moving: a.id, under: b.id, in: [a, b]))
    }

    @Test func movingToTheTopLevelIsAlwaysFine() {
        let a = group("a")
        let b = group("b", parent: a.id)
        #expect(!GroupTree.wouldCycle(moving: b.id, under: nil, in: [a, b]))
    }

    @Test func repairLiftsAGroupWhoseParentIsMissing() {
        // An older export carries no parent, and a foreign file can name one
        // that is not in it. Nothing is discarded: the group lands at the top.
        let orphan = group("orphan", parent: UUID())
        let repaired = GroupTree.repaired([orphan])
        #expect(repaired.count == 1)
        #expect(repaired[0].parentID == nil)
    }

    @Test func repairBreaksACycleByLiftingTheFirstMemberItReaches() {
        var a = group("a")
        var b = group("b")
        a.parentID = b.id
        b.parentID = a.id
        let repaired = GroupTree.repaired([a, b])
        #expect(repaired.count == 2)
        #expect(repaired.filter { $0.parentID == nil }.count >= 1)
        #expect(!GroupTree.hasCycle(repaired))
    }

    @Test func repairLeavesAHealthyTreeAlone() {
        let a = group("a")
        let b = group("b", parent: a.id)
        #expect(GroupTree.repaired([a, b]) == [a, b])
    }

    @Test func childrenComeBackInPositionOrder() {
        let parent = group("p")
        let second = group("second", parent: parent.id, at: 1)
        let first = group("first", parent: parent.id, at: 0)
        let names = GroupTree.children(of: parent.id, in: [parent, second, first])
            .map(\.name)
        #expect(names == ["first", "second"])
    }
}
```

- [ ] **Step 2: Run it red.**

Run: `swift test --filter GroupTree`
Expected: FAIL — `StoredGroup` has no such initializer, `GroupTree`
does not exist.

- [ ] **Step 3: Add the fields.** `parentID: UUID?` and `position: Int`
  on `StoredGroup`, `position: Int` on `StoredSession`. **Both with a
  default value in the initializer and on decode**, so a file without them
  stays readable unchanged — that is the additive migration, and it is why
  no new filename is needed. `position` defaults to `0`; `Codable`
  does not synthesize that on its own for a missing key, so it needs an
  explicit `decode` path or optional storage with non-optional access.
  **Whichever way you choose, justify it in the comment — and verify it
  with a test that decodes real JSON without the new keys.**
- [ ] **Step 4: Implement `GroupTree`.** `wouldCycle(moving:under:in:)`,
  `hasCycle(_:)`, `repaired(_:)`, `children(of:in:)`. All pure, no file
  access. `repaired` **never** discards a folder.
- [ ] **Step 5: Run it green**, plus a decode test for the old file form.
- [ ] **Step 6:** Full suite green, no new warning.
- [ ] **Step 7: Commit** — `feat(sessions): give groups a parent and a position`

---

### Task 2: Computing and writing the ordering

**Files:**
- Create: `Sources/macSCPCore/Sessions/SidebarOrdering.swift`
- Modify: `Sources/macSCPCore/Sessions/SessionStore.swift`,
  `Sources/macSCPCore/Presentation/SessionListViewModel.swift`
- Test: `Tests/macSCPCoreTests/SidebarOrderingTests.swift`, plus the
  existing store suites

**Interfaces:**
- Consumes: `GroupTree` from Task 1.
- Produces: a move function that computes a new ordering from **two
  identities**, and a one-shot sort. Task 4 calls both.

**The model, and it is binding:** `TabsViewModel.move(tabID:to:)` and
`move(tabID:onto:)` from this week. They derive the target from two
identities rather than an index — **because the index in the view was the
error class.** Read both before starting, and build the same shape.

- [ ] **Step 1: Red first.** Tests for: dragging between two siblings
  reorders them; dragging onto a folder appends to the end of its children;
  a move that would close a cycle **changes nothing** (and reports that,
  instead of failing silently); positions are gapless and unique per parent
  after every move.
- [ ] **Step 2: Implement.** On write, the siblings of the affected parent
  get **renumbered** — that is the guarantee every later reader depends on,
  so it belongs in a test and not in a comment.
- [ ] **Step 3: The one-shot sort.** Orders the **immediate** children of a
  folder by name and rewrites their positions. Acts exactly one level deep.
  No stored state, no setting. The name comparison follows whatever the
  sidebar uses for sorting today — **look it up instead of inventing a new
  one**, and name in the comment which one you found.
- [ ] **Step 4: Generalize `dissolveGroup`.** Sessions **and** subfolders
  of the dissolved folder move to its `parentID`. The existing test for the
  flat case must stay green unchanged — if it does not, that is a finding
  and belongs in the report, not in an adjusted expectation.
- [ ] **Step 5:** Full suite green, no new warning.
- [ ] **Step 6: Commit** — `feat(sessions): reorder and nest by identity, never by index`

---

### Task 3: Export and import carry it along

**Files:**
- Modify: `Sources/macSCPCore/Sessions/SessionExportCodec.swift` and the
  import planner
- Test: the existing export/import suites, plus new cases

**Interfaces:**
- Consumes: `GroupTree.repaired(_:)` from Task 1.

**The measured status quo:** `ExportedGroup` carries `id` and `name`; its
comment says the identifier is file-local only and the planner assigns
fresh ones on import. **That is this task's trap:** a `parentID` refers to
a file-local identifier that gets reassigned on import. The mapping must
therefore **travel along during the re-keying** — a `parentID` carried over
raw pointed at nothing after import.

- [ ] **Step 1: Red first.** Three cases, each its own test: an export
  **without** the new fields imports unchanged (the old form stays
  readable); a `parentID` survives the change of identifiers; a file with
  a **cycle** or a **missing parent** imports completely, with the
  affected folders at the top.
- [ ] **Step 2: Implement.** `repaired(_:)` runs on the file as read,
  **before** anything is adopted.
- [ ] **Step 3: The import reports what it straightened out.** The planner
  already has a surface for its report — **find it and use it**, instead
  of building a new one. Name in the report which one you found.
- [ ] **Step 4:** Full suite green, no new warning.
- [ ] **Step 5: Commit** — `feat(sessions): carry nesting through export and import`

---

### Task 4: The sidebar

**Files:**
- Modify: `Sources/MacSCPAppKit/SessionSidebar.swift`
- Modify: all four `Localizable.strings`
- Test: `Tests/macSCPAppKitTests/`

**Interfaces:**
- Consumes: everything from Tasks 1–3.

**Requirement:** the view computes **no** position. Every gesture ends in
a core function from Task 2, with two identities as arguments. If you need
an index in the view, the design has been violated — report that, instead
of building it in.

- [ ] **Step 1: Display nested.** Folders inside folders, in position
  order via `GroupTree.children(of:in:)`.
- [ ] **Step 2: Dragging.** Between siblings reorders, onto a folder moves
  inside. **Visible target while dragging**, following the model of
  `TabStripView`'s `dropTarget` — the shape already exists, it highlights
  the target instead of computing an insertion mark between items.
- [ ] **Step 3: The folder context menu.** An entry "sort by name" that
  triggers Task 2's one-shot sort. **Only show what is possible** —
  a standing rule of this project, nothing is greyed out.
- [ ] **Step 4: The text.** In all four catalogs, matching key sets, the
  German uses du.
- [ ] **Step 5:** Full suite green, no new warning.
- [ ] **Step 6: Commit** — `feat(sidebar): nest folders and drag them into order`

---

## What is explicitly out of scope

- **No search in the tree (D3).** It comes afterward, because the nesting
  determines how it is displayed.
- **No stored sort setting per folder.**
- **No new filename and no second file.**
- **No change to the tags** (E1/E2) — same sidebar, different task.
