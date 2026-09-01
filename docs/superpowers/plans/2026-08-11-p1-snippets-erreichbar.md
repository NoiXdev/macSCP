# P1: Making snippets reachable — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Snippets can be triggered wherever the work happens — menu bar,
context menu on the host, terminal header, right-click in the terminal —
and the decision "insert or execute" is made at trigger time rather than at
creation time.

**Architecture:** A Core type `SnippetMenuModel` computes the finished menu
structure from snippets, tag filter and connection state; the four trigger
surfaces do nothing but render from it. The `runsImmediately` flag
disappears from `Snippet`; `SnippetKeystrokes.bytes(for:execute:)` gets the
decision from the caller. Tags are a model rule, not a form detail.

**Tech Stack:** Swift 6, `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+,
SwiftUI, Swift Testing (`@Test`/`#expect`), two test targets
(`macSCPCoreTests`, `macSCPAppKitTests`).

## Global Constraints

- **Code, comments, test names: English.** Internal docs (`docs/`) may be
  German.
- **User-facing strings** through `L10n.string(_:_:)`; **every new key in
  all four catalogs** (en/de/fr/pl). Proof: the existing guard test plus
  `plutil -lint` across all eight catalogs.
- **Snippets never contain credentials.** The store is JSON; secrets live
  exclusively in the keychain. No snippet field accepts a secret, and no
  snippet text may end up in an error message.
- **No secret in a log, error, or test failure message.** `#expect`
  expands its expression.
- **Never write a line number into a comment.** Name the thing.
- **This plan's prose is a claim to be checked, not a fact.** In the
  pre-phase, five of eleven tasks had a real error in the brief. If
  something doesn't match the code: report it, don't silently rework it.
- **A test that stays green against a constant return value is not a
  test.** Run this probe on yourself before every commit.
- **Commit/push only on request** from the coordinator. No
  `scripts/release`.
- **The GUI is not launched.** `scripts/package-app` is allowed.
- Conventional Commits, English, footer on every commit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Full suite green before every commit. Starting point: **1786 tests in 150
  suites** — measure fresh, never copy the number.

## File structure

| File | Responsibility |
|---|---|
| `Sources/macSCPCore/Terminal/Snippet.swift` | Model: `runsImmediately` out, `tags` in, tag rule in the initializer |
| `Sources/macSCPCore/Terminal/SnippetKeystrokes.swift` | `bytes(for:execute:)` |
| `Sources/macSCPCore/Terminal/SnippetTagSuggestions.swift` | **new** — suggestion list while typing |
| `Sources/macSCPCore/Terminal/SnippetMenuModel.swift` | **new** — the structure all four surfaces render from |
| `Sources/MacSCPAppKit/SnippetTagField.swift` | **new** — token field with suggestions |
| `Sources/MacSCPAppKit/SnippetsSheet.swift` | Editor without a checkbox, filter row |
| `Sources/MacSCPAppKit/SnippetMenuItems.swift` | **new** — the shared SwiftUI rendering of a `SnippetMenuModel` |
| `Sources/MacSCPAppKit/MacSCPApp.swift` | Menu bar onto the model |
| `Sources/MacSCPAppKit/SessionSidebar.swift` | Context menu on the host |
| `Sources/MacSCPAppKit/ContentView+Detail.swift` | Terminal header + popover |
| `Sources/MacSCPAppKit/SSHTerminalView.swift` | Right-click |
| `Sources/MacSCPAppKit/KeyboardShortcutsCatalog.swift` | Shortcut entry |

---

## Part A: Core

### Task 1: The model — flag out, tags in

**Files:**
- Modify: `Sources/macSCPCore/Terminal/Snippet.swift`
- Modify: `Tests/macSCPCoreTests/SnippetTests.swift`

**Interfaces:**
- Produces: `Snippet(id:name:command:tags:)` (failable), `Snippet.tags: [String]`.
  `runsImmediately` no longer exists.

- [ ] **Step 1: Read the current state**

`Snippet.swift` including its `init(from:)`, and the existing tests. The
newline guard and the "decode goes through the validating initializer" path
stay **unchanged** — they are the reason a hand-edited file cannot get
around the rule. The tag rule is built the same way.

- [ ] **Step 2: Write the failing tests**

```swift
/// Whitespace around a tag is typing noise, not part of the tag.
@Test func aTagIsTrimmed() throws {
    let snippet = try #require(Snippet(name: "n", command: "c", tags: ["  docker  "]))
    #expect(snippet.tags == ["docker"])
}

/// A tag that is only whitespace carries no meaning and would render as an
/// empty chip nobody can aim at.
@Test func anEmptyTagIsDropped() throws {
    let snippet = try #require(Snippet(name: "n", command: "c", tags: ["docker", "   ", ""]))
    #expect(snippet.tags == ["docker"])
}

/// Case is preserved — the maintainer's decision. `Docker` and `docker` are
/// two tags, and the suggestion list (not the store) is what keeps users
/// from creating both by accident.
@Test func caseIsPreserved() throws {
    let snippet = try #require(Snippet(name: "n", command: "c", tags: ["Docker", "docker"]))
    #expect(snippet.tags == ["Docker", "docker"])
}

/// Exact duplicates collapse; order is the order they were entered in.
@Test func exactDuplicatesCollapseAndOrderSurvives() throws {
    let snippet = try #require(
        Snippet(name: "n", command: "c", tags: ["b", "a", "b"]))
    #expect(snippet.tags == ["b", "a"])
}

/// A store file written before tags existed still loads, and the flag it
/// carries is ignored rather than rejected — the user keeps their snippets.
@Test func aRoundOneStoreFileLoadsWithoutTags() throws {
    let json = Data("""
        {"id":"11111111-1111-1111-1111-111111111111","name":"Restart",
         "command":"systemctl restart nginx","runsImmediately":true}
        """.utf8)

    let snippet = try JSONDecoder().decode(Snippet.self, from: json)

    #expect(snippet.tags.isEmpty)
    #expect(snippet.command == "systemctl restart nginx")
}

/// The tag rule is a model rule, so a hand-edited file cannot smuggle an
/// untrimmed tag past it — the same reason the newline rule lives here.
@Test func aHandEditedTagIsNormalizedOnDecode() throws {
    let json = Data("""
        {"id":"22222222-2222-2222-2222-222222222222","name":"n",
         "command":"c","tags":["  docker  ","",  "docker  "]}
        """.utf8)

    let snippet = try JSONDecoder().decode(Snippet.self, from: json)

    #expect(snippet.tags == ["docker"])
}
```

- [ ] **Step 3: Run it red**

Run: `swift test --filter SnippetTests`
Expected: FAIL — `tags` doesn't exist.

- [ ] **Step 4: Change the model**

```swift
public struct Snippet: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let command: String
    /// Free-form labels that order snippets and group the trigger surfaces.
    /// Normalized at construction: trimmed, empties dropped, exact
    /// duplicates removed, order of first appearance kept, case left as
    /// typed. `let` for the same reason `command` is — an in-place mutation
    /// would be a second, unchecked write path around that normalization.
    public let tags: [String]

    public init?(id: UUID = UUID(), name: String, command: String, tags: [String] = []) {
        guard !command.contains("\n"), !command.contains("\r") else { return nil }
        self.id = id
        self.name = name
        self.command = command
        var seen = Set<String>()
        self.tags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    …
}
```

`init(from:)` decodes `tags` with `decodeIfPresent(… ) ?? []` and routes
onward through the initializer above. **`runsImmediately` is not decoded**
— an unknown key doesn't bother `JSONDecoder`, and the flag is meant to go
away anyway. The type's doc comment must stop mentioning
`runsImmediately`; the paragraph about the newline needs a new
justification, since it can no longer lean on the flag.

- [ ] **Step 5: Green, then callers**

Run: `swift test --filter SnippetTests` → PASS.
Then build the whole tree: every caller of `runsImmediately` now breaks.
**Don't fix it, report it** if a spot needs more than dropping the
argument — Task 2 and Task 5 pick those up. For this task it is enough to
satisfy the compiler with the minimal intervention (drop the argument, set
flag-reading spots to "insert" for now) and name that in the report.

- [ ] **Step 6: Full suite and commit**

```bash
swift test
git add Sources/macSCPCore/Terminal/Snippet.swift Tests/macSCPCoreTests/SnippetTests.swift
git commit -m "feat(core): give snippets tags and drop the runs-immediately flag"
```

---

### Task 2: The bytes — the decision moves to the call site

**Files:**
- Modify: `Sources/macSCPCore/Terminal/SnippetKeystrokes.swift`
- Modify: `Tests/macSCPCoreTests/SnippetKeystrokesTests.swift`

**Interfaces:**
- Consumes: `Snippet` without `runsImmediately` (Task 1).
- Produces: `SnippetKeystrokes.bytes(for snippet: Snippet, execute: Bool) -> [UInt8]`

- [ ] **Step 1: Read the existing code and its tests**

Especially the doc comment above `terminator`. The measured `0x0D` and the
chain of evidence around it **stay exactly as written** — they are the
result of a measurement that corrected a real bug in round 1.

- [ ] **Step 2: Write the failing tests**

```swift
/// Inserting never appends a terminator — that is the whole difference
/// between putting text in the input line and running it on the far host.
/// This holds for every caller, which is why it is asserted here and not
/// left to the four trigger surfaces.
@Test func insertingNeverAppendsATerminator() throws {
    let snippet = try #require(Snippet(name: "n", command: "uptime"))

    let bytes = SnippetKeystrokes.bytes(for: snippet, execute: false)

    #expect(bytes == Array("uptime".utf8))
}

/// Executing appends exactly one carriage return — not zero, not two.
@Test func executingAppendsExactlyOneCarriageReturn() throws {
    let snippet = try #require(Snippet(name: "n", command: "uptime"))

    let bytes = SnippetKeystrokes.bytes(for: snippet, execute: true)

    #expect(bytes == Array("uptime".utf8) + [0x0D])
}

/// The two differ in exactly one byte — a regression that made them equal
/// would otherwise pass whichever of the two tests above still matched.
@Test func theTwoCallsDifferByTheTerminatorAlone() throws {
    let snippet = try #require(Snippet(name: "n", command: "df -h"))

    let inserted = SnippetKeystrokes.bytes(for: snippet, execute: false)
    let executed = SnippetKeystrokes.bytes(for: snippet, execute: true)

    #expect(executed.count == inserted.count + 1)
    #expect(Array(executed.dropLast()) == inserted)
}
```

- [ ] **Step 3: Red, implement, green**

Run: `swift test --filter SnippetKeystrokes` → FAIL, then change the
signature (`if execute { bytes.append(terminator) }`), then PASS.

- [ ] **Step 4: Full suite and commit**

```bash
swift test
git add Sources/macSCPCore/Terminal/SnippetKeystrokes.swift Tests/macSCPCoreTests/SnippetKeystrokesTests.swift
git commit -m "feat(core): let the caller decide whether a snippet executes"
```

---

### Task 3: The suggestion list

The maintainer's decision is "only trim, case stays as typed". That makes
`Docker` and `docker` two tags. This is damped **at the input**: someone
typing `doc` gets the existing `Docker` offered.

**Files:**
- Create: `Sources/macSCPCore/Terminal/SnippetTagSuggestions.swift`
- Create: `Tests/macSCPCoreTests/SnippetTagSuggestionsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum SnippetTagSuggestions {
      public static func all(in snippets: [Snippet]) -> [(tag: String, count: Int)]
      public static func matching(_ prefix: String, in snippets: [Snippet], excluding taken: [String]) -> [(tag: String, count: Int)]
  }
  ```
  Both sorted: descending by `count`, alphabetically on a tie (compared
  case-insensitively).

- [ ] **Step 1: Write the failing tests**

```swift
/// The whole point of the suggestion list: typing lowercase must surface an
/// existing differently-cased tag, so the user picks it instead of creating
/// a second one. The store keeps the case; only the search ignores it.
@Test func aLowercasePrefixFindsADifferentlyCasedTag() throws {
    let snippets = [try #require(Snippet(name: "n", command: "c", tags: ["Docker"]))]

    let matches = SnippetTagSuggestions.matching("doc", in: snippets, excluding: [])

    #expect(matches.map(\.tag) == ["Docker"])
}

/// A tag already on the snippet being edited is not offered again.
@Test func aTagAlreadyTakenIsNotOffered() throws {
    let snippets = [try #require(Snippet(name: "n", command: "c", tags: ["docker"]))]

    let matches = SnippetTagSuggestions.matching("doc", in: snippets, excluding: ["docker"])

    #expect(matches.isEmpty)
}

/// Counts drive the order, so the tags in heaviest use come first.
@Test func theMostUsedTagComesFirst() throws {
    let snippets = [
        try #require(Snippet(name: "a", command: "c", tags: ["rare", "common"])),
        try #require(Snippet(name: "b", command: "c", tags: ["common"])),
    ]

    let all = SnippetTagSuggestions.all(in: snippets)

    #expect(all.map(\.tag) == ["common", "rare"])
    #expect(all.map(\.count) == [2, 1])
}

/// An empty prefix offers everything not already taken — that is what the
/// list shows when the field is focused but empty.
@Test func anEmptyPrefixOffersEverythingUntaken() throws {
    let snippets = [try #require(Snippet(name: "n", command: "c", tags: ["a", "b"]))]

    let matches = SnippetTagSuggestions.matching("", in: snippets, excluding: ["a"])

    #expect(matches.map(\.tag) == ["b"])
}
```

- [ ] **Step 2: Red, implement, green, full suite, commit**

Run: `swift test --filter SnippetTagSuggestions` → FAIL → PASS.

**Before the commit, the constant probe:** if `matching` always returned
`[]`, which test goes red? If it returned all tags unfiltered, which one?
Both answers in the report.

```bash
git commit -m "feat(core): suggest existing tags case-insensitively"
```

---

### Task 4: `SnippetMenuModel` — one type, four surfaces

**Files:**
- Create: `Sources/macSCPCore/Terminal/SnippetMenuModel.swift`
- Create: `Tests/macSCPCoreTests/SnippetMenuModelTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct SnippetMenuModel: Equatable, Sendable {
      public enum DisabledReason: Equatable, Sendable {
          case notConnected
          case backendHasNoShell
      }
      public struct Group: Identifiable, Equatable, Sendable {
          public var id: String { tag ?? "" }
          public let tag: String?          // nil = the untagged group
          public let snippets: [Snippet]
      }
      public let groups: [Group]
      public let disabledReason: DisabledReason?
      public var isEmpty: Bool { groups.isEmpty }

      public static func build(
          snippets: [Snippet], isConnected: Bool, supportsShell: Bool
      ) -> SnippetMenuModel
  }
  ```

**Two decisions fixed here so they don't come out differently across four
views:**

1. **A snippet with two tags appears under both.** That is what a tag
   means — you look for it wherever you filed it. Duplicate entries in the
   menu are the price, and are intended.
2. **Untagged comes last**, in a group with `tag == nil`. Otherwise exactly
   the snippets nobody has sorted yet would become unreachable.

- [ ] **Step 1: Write the failing tests**

```swift
/// A snippet carrying two tags is reachable under both — that is what a tag
/// is for. The duplicate entry is deliberate, not an oversight.
@Test func aSnippetWithTwoTagsAppearsUnderBoth() throws {
    let snippet = try #require(Snippet(name: "n", command: "c", tags: ["a", "b"]))

    let model = SnippetMenuModel.build(
        snippets: [snippet], isConnected: true, supportsShell: true)

    #expect(model.groups.map(\.tag) == ["a", "b"])
    #expect(model.groups.allSatisfy { $0.snippets == [snippet] })
}

/// Untagged snippets are last, never dropped — otherwise the ones nobody
/// has sorted yet become unreachable, which is the state every new snippet
/// starts in.
@Test func untaggedSnippetsComeLastAndAreNeverDropped() throws {
    let tagged = try #require(Snippet(name: "t", command: "c", tags: ["a"]))
    let untagged = try #require(Snippet(name: "u", command: "c"))

    let model = SnippetMenuModel.build(
        snippets: [untagged, tagged], isConnected: true, supportsShell: true)

    #expect(model.groups.map(\.tag) == ["a", nil])
    #expect(model.groups.last?.snippets == [untagged])
}

/// Order inside a group is store order, not alphabetical — the user's own
/// arrangement survives.
@Test func orderInsideAGroupIsStoreOrder() throws {
    let second = try #require(Snippet(name: "zeta", command: "c", tags: ["a"]))
    let first = try #require(Snippet(name: "alpha", command: "c", tags: ["a"]))

    let model = SnippetMenuModel.build(
        snippets: [second, first], isConnected: true, supportsShell: true)

    #expect(model.groups.first?.snippets.map(\.name) == ["zeta", "alpha"])
}

/// Without a connection there is no shell to send to. The entries stay
/// visible — a disabled entry teaches where the feature lives; a missing
/// one teaches nothing — but they carry the reason.
@Test func aDisconnectedTabDisablesTheEntriesWithoutHidingThem() throws {
    let snippet = try #require(Snippet(name: "n", command: "c"))

    let model = SnippetMenuModel.build(
        snippets: [snippet], isConnected: false, supportsShell: true)

    #expect(model.disabledReason == .notConnected)
    #expect(model.groups.isEmpty == false)
}

/// S3 and WebDAV have no shell at all. That is a different reason from "not
/// connected yet" and the two must not collapse — the first is permanent
/// for this backend, the second goes away when the user connects.
@Test func aBackendWithoutAShellIsADistinctReason() throws {
    let snippet = try #require(Snippet(name: "n", command: "c"))

    let model = SnippetMenuModel.build(
        snippets: [snippet], isConnected: true, supportsShell: false)

    #expect(model.disabledReason == .backendHasNoShell)
}

/// No snippets means no groups — the surfaces show their own empty hint
/// rather than an empty group box.
@Test func noSnippetsMeansNoGroups() {
    let model = SnippetMenuModel.build(
        snippets: [], isConnected: true, supportsShell: true)

    #expect(model.isEmpty)
    #expect(model.disabledReason == nil)
}
```

- [ ] **Step 2: Red, implement, green**

Group order: tags alphabetically (compared case-insensitively, stable on a
tie), `nil` last.

**If `isConnected == false` and `supportsShell == false` hold at the same
time:** pick a precedence, write it in the doc comment, and pin it with a
test. Otherwise a case with no fixed answer gets guessed four different
ways across four views.

- [ ] **Step 3: Constant probe, full suite, commit**

If `build` always returned a model with no groups — which test goes red?
Always `disabledReason == nil`? Into the report.

```bash
git commit -m "feat(core): derive the snippet menu structure in one tested place"
```

---

## Part B: App

### Task 5: The management sheet — checkbox out, tags in

**Files:**
- Create: `Sources/MacSCPAppKit/SnippetTagField.swift`
- Modify: `Sources/MacSCPAppKit/SnippetsSheet.swift`
- Modify: the four `Localizable.xcstrings` (en/de/fr/pl)
- Modify: `Tests/macSCPAppKitTests/SnippetsPresentationTests.swift` (if
  `SnippetMenuEntry.title(for:)` goes away — see below)

- [ ] **Step 1: Read what's there**

`SnippetsSheet.swift` in full, `SnippetsPresentation.swift` in full.
`SheetSearchField` from M18 exists and is reused.

**`SnippetMenuEntry.title(for:)` loses its purpose** — it marked executing
snippets in the title, and executing snippets no longer exist. Remove it
along with its tests. Verify with the compiler, not with `grep`, that no
caller remains.

- [ ] **Step 2: The token field**

`SnippetTagField` is a `View` with `@Binding var tags: [String]` and a
`suggestions: (String) -> [(tag: String, count: Int)]` closure (from
`SnippetTagSuggestions`, passed in rather than built internally — the same
seam that made `SessionSecretPolicy` testable).

Behavior: set tags as chips with a remove button; a suggestion list with
count while typing; **last entry always** "create *x* as a new tag".
Return picks up the highlighted suggestion, comma closes off the typed tag,
backspace in the empty field removes the last chip.

**New L10n keys** (wording is your call, but named identically in all four
catalogs):
`snippets.tags.label`, `snippets.tags.placeholder`,
`snippets.tags.createNew`, `snippets.tags.remove`,
`snippets.filter.all`, `snippets.filter.untagged`.

- [ ] **Step 3: Editor and filter row**

In the editor: **remove** the "run immediately" checkbox, put the tag field
below. Below the existing search field, a chip row: "All", one chip per tag
with count, plus "untagged". **Single-select** — one chip at a time, "All"
resets.

- [ ] **Step 4: Catalogs and suite**

```bash
swift test
for f in $(git ls-files '*.xcstrings'); do plutil -lint "$f"; done
```
Expected: suite green, all catalogs OK, the existing guard test keeps the
key sets aligned.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(app): tag snippets in the editor and filter the list by tag"
```

---

### Task 6: The menu bar onto the model

**Files:**
- Create: `Sources/MacSCPAppKit/SnippetMenuItems.swift`
- Modify: `Sources/MacSCPAppKit/MacSCPApp.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift` (`triggerSnippet`)
- Modify: `Sources/MacSCPAppKit/KeyboardShortcutsCatalog.swift`
- Modify: the four catalogs

- [ ] **Step 1: Read**

`snippetMenuItems` and `snippetButton` in `MacSCPApp.swift`,
`triggerSnippet` in `ContentView.swift`, `SnippetsLoad` in
`SnippetsPresentation.swift` (**stays** — a store that can't be read must
never look like an empty one).

- [ ] **Step 2: The shared rendering**

`SnippetMenuItems` is a `View` that renders the entries from a
`SnippetMenuModel`: a submenu per group, **two** actions per snippet
("Insert", "Execute"). It receives the action as a closure
`(Snippet, Bool) -> Void` — the same piece is reused in Task 7 and 8, so
that all four surfaces demonstrably read from one model.

- [ ] **Step 3: `triggerSnippet` onto two actions**

`triggerSnippet(_ snippet: Snippet, execute: Bool)`, passes `execute`
through to `SnippetKeystrokes.bytes(for:execute:)`. Otherwise unchanged.

- [ ] **Step 4: Shortcut**

⌃⌘1–3 **insert** the first three snippets in store order. **Execute gets no
shortcut** — a keystroke that immediately runs on a host has no good
failure case. Keep the shortcuts catalog from M11q updated; its doc comment
names that as a duty.

- [ ] **Step 5: Suite, catalogs, commit**

```bash
swift test && for f in $(git ls-files '*.xcstrings'); do plutil -lint "$f"; done
git commit -m "feat(app): offer insert and execute for every snippet in the Terminal menu"
```

---

### Task 7: Context menu on the host

**Files:**
- Modify: `Sources/MacSCPAppKit/SessionSidebar.swift`
- Modify: the four catalogs

- [ ] **Step 1: Read**

The existing `.contextMenu` blocks in `SessionSidebar.swift` — there are
several, for the session row, the group, and the imported host. **Only the
session row** gets the snippet entry.

- [ ] **Step 2: Wire it up**

A submenu "Snippet" that renders `SnippetMenuItems` with the same
`SnippetMenuModel`. Disabled via
`BackendDescriptor.descriptor(for:).capabilities.supportsShell` — S3 and
WebDAV sessions show the entry greyed out instead of leading nowhere.

**To clarify and answer in the report:** a session in the sidebar is not
necessarily the **active** one — which shell does the entry send to?
Decide, write it into the doc comment, and if the answer is "only for the
active session, disabled otherwise", say so to the user in the menu instead
of doing it silently.

- [ ] **Step 3: Suite, catalogs, commit**

```bash
git commit -m "feat(app): reach snippets from a session's context menu"
```

---

### Task 8: Terminal header with popover

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift` (`terminalPanel`)
- Modify: the four catalogs

- [ ] **Step 1: Measure before you build**

Note the **current** margin value and the height of the terminal strip from
`terminalPanel`. The number goes into the report. **Don't change it** —
the margin is P2, not this task. This header is being added because the
popover needs it.

- [ ] **Step 2: The header**

A slim row above the terminal area: the host on the left, a snippet button
on the right. The button opens a popover with `SheetSearchField` and
`SnippetMenuItems` on the same `SnippetMenuModel`.

- [ ] **Step 3: Suite, catalogs, commit**

```bash
git commit -m "feat(app): give the terminal panel a header with a snippet picker"
```

---

### Task 9: Right-click in the terminal

**Files:**
- Modify: `Sources/MacSCPAppKit/SSHTerminalView.swift`

- [ ] **Step 1: Measure, don't infer**

From SwiftTerm's `MacTerminalView` source it is known: **no override of
`rightMouseDown`, no `menu(for:)`**, but there is a `paste(_:)` action.
**It does not follow** from that that a set menu actually arrives.

Determine whether an `NSMenu` set on the hosted view appears on
right-click, and whether that loses anything the terminal area currently
does with the right mouse button. Record **how** you determined it. If it
can't be done without launching the GUI: say so, and carry the point into
the report as an open visual check — **do not launch the GUI**.

- [ ] **Step 2: Wire it up or report it**

If it works: the same entries as in Task 6, via `SnippetMenuItems`. If it
doesn't: **report it, don't improvise.** A half-working right-click is
worse than none.

- [ ] **Step 3: Suite and commit**

```bash
git commit -m "feat(app): reach snippets by right-clicking the terminal"
```

---

## Part C: Wrap-up

### Task 10: Phase close-out

**Files:**
- Create: `docs/superpowers/specs/2026-08-11-p1-snippets-abschluss.md`

- [ ] **Step 1: Measure**

```bash
swift test 2>&1 | tail -3
for f in $(git ls-files '*.xcstrings'); do plutil -lint "$f"; done
MACSCP_VERSION="1.2.0-dev" MACSCP_BUILD="$(git rev-list --count HEAD)" ./scripts/package-app
```
Measure all numbers fresh. **The app is not launched.**

- [ ] **Step 2: Report**

It states: the measured numbers; that all four surfaces read from **one**
model and that this is proof in the code, not a test; which criteria are
review points rather than tests; the result of the right-click
measurement; and **explicitly** that the GUI was not launched, and which
visual checks are left for the maintainer — header, popover, context menu,
filter row, token field.

- [ ] **Step 3: Commit**

```bash
git commit -m "docs(app): record the snippet trigger surfaces"
```

---

## Self-review of this plan

**Spec coverage** (section "P1" of the spec): model + migration → T1.
Tag rule → T1. Suggestion list → T3. Bytes → T2. `SnippetMenuModel` → T4.
Tag input field → T5. Filter row → T5. Four trigger surfaces → T6/T7/T8/T9.
Shortcut + catalog → T6. Both "to be measured" points: right-click → T9
step 1; terminal margin → T8 step 1 measures it, but deliberately changes
it only in P2.

**Three places where this plan deliberately does not guess**, and instead
leaves the implementer to decide and justify: the precedence between
`notConnected` and `backendHasNoShell` (T4), which shell the host context
menu sends to (T7), and whether the right-click even works (T9). All three
carry "decide, write into the doc comment, pin it" or "report, don't
improvise" — never a made-up answer.

**Not part of this:** the terminal margin and the plain terminal window
(P2), host tags and import/export (P3), the bulk runner, multi-line
commands, syntax highlighting, placeholders, agent forwarding.
