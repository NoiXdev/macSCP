# P3f — Export on the snippet row

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The snippet list gets "Export…" in its row context menu — with
the same meaning this entry already has everywhere else in the app:
exactly this one row.

**Architecture:** Measuring before planning shrank the phase's scope to
a fifth of its original size and answered the spec's open question by
showing that the shipped code had already answered it:

| List | "Export" on the row |
|---|---|
| Session (sidebar) | present (`export.menu.single`) |
| Group (sidebar) | present (`export.menu.group`) |
| Login sets | present (`logins.export.action`) |
| SSH keys | present (public and private) |
| **Snippets** | **missing** |

The spec asked whether "Export" on the row means the same thing as in
the sheet. `LoginSetsSheet` answers that in code, with a comment: *"the
footer button covers 'all' (or whatever is selected); this one always
means THIS row."* The row entry also sets the selection first, so the
visible selection and the effective scope never drift apart. This phase
carries over exactly that pattern — it invents no second rule.

**Deliberately NOT part of this phase:** the two sheets' footers mean
different things for selection vs. visible (login sets: the selection,
otherwise the visible ones; snippets: always the visible ones). That is
pre-existing, affects no context-menu entry, and is a behavior change to
shipped code — it belongs in its own decision, not in this one.

The confirmation level, by contrast, differs for BOTH triggers (footer
and row), not just the footer: login sets opens its export sheet
(options + count) in both cases, snippets goes straight to the save
dialog in both cases. That is justified and pre-existing —
`SnippetExportCodec` has neither options nor a password argument (see
`performExport`'s own comment on this), so an options sheet would have
nothing to show there.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, Swift Testing.

## Global Constraints

- Code, comments, identifiers, test names: **English only.**
- User-visible strings via `L10n.string`; the key sets of the four
  catalogs (en/de/fr/pl) stay identical — a guard test checks this.
- Never write a line number into a comment.
- No comment claims something the code does not do.
- Tests: TDD red→green. `swift test` green at the end.
- Conventional Commits, footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: "Export…" in the snippet row menu

**Files:**
- Modify: `Sources/MacSCPAppKit/SnippetsSheet.swift`
- Test: `Tests/macSCPAppKitTests/SnippetRowExportMenuGuardTests.swift` (new)

**Interfaces:** no new public APIs.

**Context you don't need to guess:**
- The row context menu already exists and currently holds exactly two
  entries: "Edit…" and "Delete…". Both set `selectedID = snippet.id`
  first. The new entry follows the same pattern — the comment above the
  menu already explains why.
- `performExport(_ snippets: [Snippet])` is an existing private method
  on the same type. It encodes, builds the document, and opens the
  `fileExporter`. The new entry calls it with **exactly one** snippet.
- The key `snippets.export` (English "Export…") already exists in all
  four catalogs — it is the footer button's label. Reuse it; **do not
  create a new key.** Login sets do exactly this at the same spot (one
  key, two triggers).
- The entry belongs **between** "Edit…" and "Delete…", so the
  destructive action stays last in the menu (as it is in every other row
  menu in the app).

- [ ] **Step 1: Write the failing test**

There is no SwiftUI renderer in this suite. What is testable and
valuable is that the entry exists in the menu body at all and reuses
the existing label. New file
`Tests/macSCPAppKitTests/SnippetRowExportMenuGuardTests.swift`:

```swift
import Foundation
import Testing
@testable import MacSCPAppKit

/// The snippet row was the last list in the app whose context menu had no
/// "Export…" entry. This reads the source of `SnippetsSheet` and pins that
/// the row menu offers it, exports exactly the right-clicked snippet, and
/// keeps the destructive entry last.
@Suite("Snippet row export menu")
struct SnippetRowExportMenuGuardTests {
    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // macSCPAppKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/MacSCPAppKit/SnippetsSheet.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func theRowMenuExportsExactlyTheRightClickedSnippet() throws {
        let text = try source()
        #expect(text.contains("performExport([snippet])"))
    }

    @Test func theRowMenuReusesTheExistingExportLabel() throws {
        let text = try source()
        // One key, two triggers -- a second key would let the footer and the
        // row drift apart in translation.
        #expect(text.contains("\"snippets.export\""))
    }

    @Test func theDestructiveEntryStaysLastInTheRowMenu() throws {
        let text = try source()
        let exportIndex = try #require(text.range(of: "performExport([snippet])")).lowerBound
        let deleteIndex = try #require(text.range(of: "isShowingDeleteConfirm = true")).lowerBound
        #expect(exportIndex < deleteIndex)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter "Snippet row export menu"`
Expected: FAIL — the first and third tests, because
`performExport([snippet])` does not occur in the source. (The second
test is already green, because the footer button uses the same key —
that is intentional: it pins the reuse, not the novelty. Say in the
report that you noticed this.)

If the path construction via `#filePath` doesn't hold up: check the
existing source-reading guard tests under `Tests/macSCPAppKitTests/`
(e.g. `PaneVisibilityWiringGuardTests.swift`) and adopt **exactly their**
way of locating the file.

- [ ] **Step 3: Implement**

In `Sources/MacSCPAppKit/SnippetsSheet.swift`, in the row context menu,
between "Edit…" and "Delete…":

```swift
            Button(L10n.string("snippets.export", "Export…")) {
                selectedID = snippet.id
                performExport([snippet])
            }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "Snippet row export menu"` → PASS (3 tests).
Then the full suite: `swift test` — must be green.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPAppKit/SnippetsSheet.swift Tests/macSCPAppKitTests/SnippetRowExportMenuGuardTests.swift
git commit -m "feat(app): offer Export in the snippet row context menu"
```
