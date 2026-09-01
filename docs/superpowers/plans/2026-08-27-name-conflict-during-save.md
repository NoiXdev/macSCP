# Name conflict when saving — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A prefilled session name no longer overwrites a different session, and a typed one only does so visibly.

**Basis:** `docs/superpowers/specs/2026-08-27-name-conflict-during-save-design.md`

**Architecture:** Two pure values in `macSCPCore` — "does this name collide?" and "which name is free?" — plus their wiring. `SessionListViewModel.save` is **not** touched; its upsert by name stays.

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English
  only**; catalog values are translations, the German addresses the
  user as *du*.
- Conventional Commits; footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **All four catalogs** (`en`, `de`, `fr`, `pl` under
  `Sources/MacSCPAppKit/Resources/`), same key sets.
- **What the user types is never altered.** A suggestion may step aside,
  an input may not.
- **The step-aside rule must use the same comparison as `save`.** `save`
  looks up with `sessions.first(where: { $0.name == name })`, so exact
  and case sensitive. A different comparison in the rule produces
  exactly the bug this work is meant to remove.
- **No test reaches the real keychain, session store, or configuration.**
- All six targets are on `.swiftLanguageMode(.v6)`; **CI goes red as soon
  as the number of distinct warning sites is above 1.**
- **No line numbers, no location references in comments.** Every number
  and every enumeration is counted in the pass that writes it.
- The app is not launched, nothing is pushed.

---

### Task 1: The two rules in Core

**Files:**
- Create: `Sources/macSCPCore/Sessions/SessionNameCollision.swift`
- Test: `Tests/macSCPCoreTests/SessionNameCollisionTests.swift`

**Interfaces:**
- Produces:
  `SessionNameCollision.collides(_ name: String, with existing: [StoredSession], excluding: UUID?) -> StoredSession?`
  and
  `SessionNameCollision.freeName(basedOn desired: String, avoiding existing: [StoredSession]) -> String`.
  Task 2 calls both.

**Why its own type and not two lines at the call sites:** there are two
paths that invent a name. Two copies of the rule diverge sooner or
later, and the trap above (same comparison as `save`) must hold in
exactly one place, not two.

- [ ] **Step 1: Write the test first.**

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("Session name collision")
struct SessionNameCollisionTests {
    private func session(_ name: String) -> StoredSession {
        StoredSession(id: UUID(), name: name, kind: .ssh)
    }

    @Test func aFreeNameIsReturnedUnchanged() {
        #expect(SessionNameCollision.freeName(
            basedOn: "web", avoiding: [session("other")]) == "web")
    }

    @Test func aTakenNameStepsAsideToTheNextNumber() {
        #expect(SessionNameCollision.freeName(
            basedOn: "web", avoiding: [session("web")]) == "web 2")
    }

    @Test func itKeepsCountingWhileTheAlternativesAreAlsoTaken() {
        let taken = [session("web"), session("web 2"), session("web 3")]
        #expect(SessionNameCollision.freeName(basedOn: "web", avoiding: taken) == "web 4")
    }

    @Test func aNameThatAlreadyEndsInANumberIsNotReinterpreted() {
        // "web 2" is a name in its own right, not "web" at number two: the
        // rule appends, it does not parse what it was given.
        #expect(SessionNameCollision.freeName(
            basedOn: "web 2", avoiding: [session("web 2")]) == "web 2 2")
    }

    @Test func theComparisonIsExactBecauseSaveIsExact() {
        // `SessionListViewModel.save` matches with `==`. A rule that treated
        // "Web" as taken would step aside from a name that saving would have
        // left alone — and one that treated "web" as free when "Web" exists
        // would still overwrite. Both directions are wrong.
        #expect(SessionNameCollision.freeName(
            basedOn: "web", avoiding: [session("Web")]) == "web")
    }

    @Test func collisionReportsTheSessionThatWouldBeReplaced() {
        let target = session("web")
        let found = SessionNameCollision.collides(
            "web", with: [session("other"), target], excluding: nil)
        #expect(found?.id == target.id)
    }

    @Test func noCollisionIsReportedForAFreeName() {
        #expect(SessionNameCollision.collides(
            "web", with: [session("other")], excluding: nil) == nil)
    }

    @Test func theSessionBeingEditedIsNotACollisionWithItself() {
        let editing = session("web")
        #expect(SessionNameCollision.collides(
            "web", with: [editing], excluding: editing.id) == nil)
    }

    @Test func editingStillCollidesWithADifferentSessionOfThatName() {
        let editing = session("old")
        let other = session("web")
        let found = SessionNameCollision.collides(
            "web", with: [editing, other], excluding: editing.id)
        #expect(found?.id == other.id)
    }
}
```

- [ ] **Step 2: Run it red.**

Run: `swift test --filter SessionNameCollision`
Expected: FAIL, `cannot find 'SessionNameCollision' in scope`.

- [ ] **Step 3: Implement.**

```swift
import Foundation

/// Two questions about a session name, asked in one place because two call
/// sites need them and a second copy would drift.
///
/// Both use the SAME comparison `SessionListViewModel.save` uses to find the
/// session it overwrites — exact, case sensitive. That is the point rather
/// than an implementation detail: a rule that judged names differently than
/// saving does would either step aside from a name saving would have left
/// alone, or call a name free that saving then overwrites.
public enum SessionNameCollision {
    /// The session `name` would replace, or `nil` if none. `excluding` is the
    /// session currently being edited: a form editing a stored session shows
    /// that session's own name, and warning that it replaces itself would
    /// make the warning appear always — and an always-visible warning stops
    /// being read.
    public static func collides(
        _ name: String, with existing: [StoredSession], excluding: UUID?
    ) -> StoredSession? {
        existing.first { $0.name == name && $0.id != excluding }
    }

    /// `desired` if it is free, otherwise the first free `"<desired> N"`.
    ///
    /// Only for names macSCP invents. What the user typed is never rewritten:
    /// an app that silently edits typed text is worse than one that
    /// overwrites, because afterwards nobody trusts what they type.
    ///
    /// The suffix is appended, never parsed: `"web 2"` is a name in its own
    /// right, so the next free form of it is `"web 2 2"` rather than
    /// `"web 3"`. Parsing would guess at what a name means.
    public static func freeName(
        basedOn desired: String, avoiding existing: [StoredSession]
    ) -> String {
        let taken = Set(existing.map(\.name))
        guard taken.contains(desired) else { return desired }
        var counter = 2
        while taken.contains("\(desired) \(counter)") { counter += 1 }
        return "\(desired) \(counter)"
    }
}
```

- [ ] **Step 4: Run it green.** `swift test --filter SessionNameCollision`
- [ ] **Step 5:** Full suite green, no new warning.
- [ ] **Step 6: Commit** — `feat(sessions): decide when a session name collides`

---

### Task 2: Wiring

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView+Lifecycle.swift` (prefill for
  "Save as session"), `Sources/MacSCPAppKit/ContentView.swift` (prefill
  for ssh-config import), `Sources/MacSCPAppKit/ConnectionFormView.swift`
  (the warning)
- Modify: all four `Localizable.strings`

**Interfaces:**
- Consumes: both functions from Task 1.

**Measured current state:** `saveName` is set in three places — when
editing, from `stored.name` (**stays untouched**, that *is* this
session), for "Save as session" from `tab.displayTitle`, and for the
ssh-config import from `host.alias`. The last two invent a name.
`ConnectionViewModel.mode` is `FormMode.edit(sessionID: UUID)` in the
edit case and delivers the ID to exclude.

- [ ] **Step 1: Make the two invented names step aside.** Both spots will
  from now on set `SessionNameCollision.freeName(basedOn:avoiding:)`
  instead of the raw name. **Do not touch the third spot** — while
  editing, stepping aside would rename the session instead of updating it.
- [ ] **Step 2: The warning.** The form shows, when the entered name
  matches an existing session, which one that is — and that saving will
  replace it. The ID to exclude comes from `mode`; in the `.new` case it
  is `nil`. **The warning does not block** — no `.disabled` on the save
  button.
- [ ] **Step 3: The text.** One key into all four catalogs that names
  the affected session. The German addresses the user as *du*. If the
  text does not carry the session's name, one `.strings` line suffices;
  if it does carry a name, that is an argument and the key gets its
  placeholder in the name, the way this project's existing keys do.
- [ ] **Step 4:** Full suite green, no new warning.
- [ ] **Step 5: Commit** — `feat(sessions): say when saving would replace another session`

---

## What is explicitly out of scope

- **No change to `SessionListViewModel.save`.** The upsert by name
  stays, including the protocol conversion its comment describes.
- **No blocking** of saving on an existing name.
- **No renaming of existing sessions**, and no stepping aside for a
  name the user typed themselves.
- No uniqueness rule in the store: two sessions may still carry the same
  name if they got there by different paths.
