# P3h — One export scope for both sheets

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** "Export" in the footer means the same thing in both sheets —
the selection, if it is on screen, otherwise everything on screen — and
predicts how many entries will be written.

**Architecture:** From the P3f overall review, maintainer decision. Today
the two footers branch differently: `LoginSetsSheet` respects the
selection and names the count in its export sheet, `SnippetsSheet`
always exports the visible set and opens the save dialog immediately.

The rule therefore moves into Core, as **one** implementation that both
sheets call — so far it sits as a private method in only one of the two.
And the snippet export gets the step that makes the narrowing visible:
without it, "only the selection" would be exactly the invisible change
in meaning the spec warns against.

**No options sheet for snippets.** `SnippetExportCodec` knows neither
options nor a password; a sheet like the login sets' would have nothing
to show. It gets a confirmation with the count, nothing more.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, Swift Testing.

## Global Constraints

- Code, comments, identifiers, test names: **English only.**
- User-facing strings via `L10n.string`; the four catalogs
  (en/de/fr/pl) keep identical key sets — guards check that.
- Never write a line number into a comment.
- No comment claims something the code does not do.
- Tests: TDD red→green. `swift test` green at the end of every task.
- Conventional Commits, footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: The scope rule in Core

**Files:**
- Create: `Sources/macSCPCore/Sessions/ExportScope.swift`
- Test: `Tests/macSCPCoreTests/ExportScopeTests.swift` (new)

**Interfaces:**
- Produces: `ExportScope.resolve(selectedID:from:)`. Task 2 calls it twice.

- [ ] **Step 1: Write the failing tests**

New file `Tests/macSCPCoreTests/ExportScopeTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("ExportScope")
struct ExportScopeTests {
    private struct Row: Identifiable, Equatable {
        let id: Int
    }

    @Test func aSelectionThatIsOnScreenNarrowsTheScopeToIt() {
        let rows = [Row(id: 1), Row(id: 2), Row(id: 3)]
        #expect(ExportScope.resolve(selectedID: 2, from: rows) == [Row(id: 2)])
    }

    @Test func noSelectionMeansEverythingOnScreen() {
        let rows = [Row(id: 1), Row(id: 2)]
        #expect(ExportScope.resolve(selectedID: nil, from: rows) == rows)
    }

    /// The membership check is the whole point: a row the search has
    /// filtered away is still `selectedID`, and letting it through would
    /// export something the user cannot see.
    @Test func aSelectionFilteredOffScreenDoesNotNarrowTheScope() {
        let rows = [Row(id: 1), Row(id: 2)]
        #expect(ExportScope.resolve(selectedID: 99, from: rows) == rows)
    }

    @Test func anEmptyListStaysEmpty() {
        #expect(ExportScope.resolve(selectedID: 1, from: [Row]()) == [])
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "ExportScope"`
Expected: FAIL — `cannot find 'ExportScope' in scope`.

- [ ] **Step 3: Implement**

New file `Sources/macSCPCore/Sessions/ExportScope.swift`:

```swift
import Foundation

/// What an "Export…" button in a list's footer covers.
///
/// One rule for every such footer: the selection when it is one of the rows
/// currently on screen, otherwise every row on screen. The membership check
/// is what keeps a selection the search has filtered away from silently
/// widening — or narrowing — the scope, since a list's selection outlives
/// its filter.
///
/// Lives here rather than in a sheet so the two sheets that offer this
/// button cannot drift apart: a second copy is how "Export" came to mean
/// two different things in the first place.
public enum ExportScope {
    public static func resolve<Item: Identifiable>(
        selectedID: Item.ID?, from visible: [Item]
    ) -> [Item] {
        guard let selectedID, let selected = visible.first(where: { $0.id == selectedID })
        else { return visible }
        return [selected]
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "ExportScope"` → PASS (4 tests).
Then `swift test` — green.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/ExportScope.swift Tests/macSCPCoreTests/ExportScopeTests.swift
git commit -m "feat(core): define one export scope rule for list footers"
```

---

### Task 2: Both footers on the rule, snippets with a count

**Files:**
- Modify: `Sources/MacSCPAppKit/LoginSetsSheet.swift`
- Modify: `Sources/MacSCPAppKit/SnippetsSheet.swift`
- Modify: `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Test: `Tests/macSCPAppKitTests/SnippetExportConfirmGuardTests.swift` (new)

**Interfaces:**
- Consumes: `ExportScope.resolve(selectedID:from:)` from Task 1.

**Context you don't have to guess:**
- `LoginSetsSheet` today has a private method `exportScope(within:)` with
  exactly this rule, called at its footer button. Replace the call
  with `ExportScope.resolve(selectedID: selectedID, from: visibleSets)`
  and **delete the private method**. Its doc comment explains the rule —
  the core of it now lives on the Core type; leave at the call site only
  what still explains something there, and don't repeat anything twice.
  The behavior stays unchanged; that is the point.
- `SnippetsSheet`'s footer today calls `performExport(visibleSnippets)`.
  It should instead **have the resolved scope confirmed** and only
  export after confirmation.
- `snippetsCanExport` disables the button as long as `visibleSnippets` is
  empty — so the resolved scope can never be empty. Note that in a
  short comment instead of building an unreachable branch.
- The **row** context menu stays unchanged: it continues to export
  exactly its row, without confirmation. There is nothing to narrow and
  nothing to count there — the row that was clicked is the statement.

- [ ] **Step 1: Write the failing test**

New file `Tests/macSCPAppKitTests/SnippetExportConfirmGuardTests.swift`.
Build it in the idiom of its neighbor — look at
`Tests/macSCPAppKitTests/SnippetRowExportMenuGuardTests.swift` and
adopt its block isolation and fail-closed behavior. It pins:

1. the footer button **no longer** calls `performExport(` directly with
   `visibleSnippets`, but sets the confirmation state;
2. the confirming button calls `performExport(` with the resolved scope;
3. `ExportScope.resolve(` appears in the file;
4. the row menu continues to call `performExport([snippet])` without confirmation.

Phrase the assertions against the anchors you actually have in the code
after Step 3 — write the test first against your planned code, run it
red, and adjust only the anchors, never the property under test.

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter "SnippetExportConfirm"` → FAIL.

- [ ] **Step 3: Implement**

In `SnippetsSheet`:

```swift
    /// Non-nil while the export confirmation is up: the snippets the user
    /// is about to write, held rather than recomputed so what was confirmed
    /// is exactly what gets written even if the filter changes underneath.
    @State private var pendingExport: [Snippet]?
```

Footer button:

```swift
                Button(L10n.string("snippets.export", "Export…")) {
                    // `snippetsCanExport` already rules out an empty visible
                    // list, so the resolved scope always has at least one
                    // snippet in it.
                    pendingExport = ExportScope.resolve(
                        selectedID: selectedID, from: visibleSnippets)
                }
```

And an alert on the sheet body, in the style of this file's existing alerts:

```swift
        .alert(
            L10n.string("snippets.export.confirm.title", "Export snippets?"),
            isPresented: Binding(
                get: { pendingExport != nil },
                set: { if !$0 { pendingExport = nil } })
        ) {
            Button(L10n.string("snippets.export", "Export…")) {
                if let pendingExport { performExport(pendingExport) }
                pendingExport = nil
            }
            .keyboardShortcut(.defaultAction)
            Button(L10n.string("cancel", "Cancel"), role: .cancel) {
                pendingExport = nil
            }
        } message: {
            Text(String(
                format: L10n.string(
                    "snippets.export.confirm.message %lld",
                    "%lld snippets will be written to the file."),
                pendingExport?.count ?? 0))
        }
```

**Check the cancel key:** `"cancel"` is a guess. Search the catalogs
for the key the other alerts in this app use for "Cancel", and use
**exactly that one**. Do not create a new one. Name in the report which
one you found.

- [ ] **Step 4: Catalogs**

Two new keys in all four catalogs, next to the existing
`snippets.*` blocks. Phrase the count message in parallel to
`"logins.export.summary %lld"`, so both sheets sound alike:

```
en: "snippets.export.confirm.title" = "Export snippets?";
    "snippets.export.confirm.message %lld" = "%lld snippets will be written to the file.";
de: "snippets.export.confirm.title" = "Snippets exportieren?";
    "snippets.export.confirm.message %lld" = "%lld Snippets werden in die Datei geschrieben.";
```

For **fr** and **pl**, phrase them yourself, in parallel to the respective
version of `logins.export.summary %lld` in the same file — adopt their
sentence structure and word choice instead of reinventing it.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "SnippetExportConfirm"` → PASS.
Then `swift test` — green, including the catalog guards.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacSCPAppKit Tests/macSCPAppKitTests/SnippetExportConfirmGuardTests.swift
git commit -m "feat(app): give both export footers one scope and a count"
```
