# Snippet Editor Part 2 — Multi-line Snippets: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A snippet may have several lines; when triggered, the remote's
bracketed-paste mode decides how it is sent.

**Architecture:** A pure planning function in Core decides, from
(command, execute?, bracketed?), the bytes to send — or a refusal.
The app layer reads the mode from SwiftTerm's `Terminal` and passes it in as
a `Bool`; Core never sees SwiftTerm. The model loses its line-break
rejection, and the editor becomes multi-line.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
Swift Testing (`@Test`/`#expect`), SwiftUI + AppKit, SwiftTerm.

**Spec:** `docs/superpowers/specs/2026-08-19-snippet-multiline-design.md`

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English**.
  Internal docs under `docs/` stay German.
- Conventional Commits. Footer on **every** commit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- TDD red→green. Every new piece of logic ships with tests; every
  regression is proved red first.
- Unit suite: `swift test`. Baseline before this plan: **2197 tests in 196
  suites, green.**
- User-visible strings go through `L10n.string` and exist in
  **all four** catalogs (`en`, `de`, `fr`, `pl`). A guard test keeps the
  key sets equal — a key present in only three catalogs turns the suite
  red.
- **Writing a number or an enumeration of call sites into a comment means
  counting them in that same moment** (`CLAUDE.md`). That also applies to
  numbers that come from this plan.
- Snippets **never** contain credentials — the store is plain JSON.
  No change in this plan may touch that.
- The app is **not** launched; visual checks are the maintainer's job.

---

## Files

**New:**

- `Sources/macSCPCore/Terminal/SnippetSendPlan.swift` — the result type and
  the planning function. Sole responsibility: derive the bytes, or the
  refusal, from a command plus two flags.
- `Tests/macSCPCoreTests/SnippetSendPlanTests.swift`

**Changed:**

- `Sources/macSCPCore/Terminal/SnippetKeystrokes.swift` — gains a
  per-line function that the planner builds on.
- `Sources/macSCPCore/Terminal/Snippet.swift` — the initializer loses the
  line-break rejection and, with it, its failability.
- `Sources/macSCPCore/Terminal/SnippetCommandInput.swift` — **deleted.**
- `Sources/MacSCPAppKit/SnippetCommandEditor.swift` — becomes multi-line.
- `Sources/MacSCPAppKit/SnippetsSheet.swift` — ⌘Return, list row.
- `Sources/MacSCPAppKit/ContentView.swift` — `triggerSnippet` routed through the planner.
- `Sources/MacSCPAppKit/SSHTerminalView.swift` — passes the mode through.
- `Sources/macSCPCore/Presentation/TerminalPanelViewModel.swift` — receives
  it.
- The four `Localizable.strings` files.

---

## Task 1: Core — the Send Plan

**Files:**
- Create: `Sources/macSCPCore/Terminal/SnippetSendPlan.swift`
- Create: `Tests/macSCPCoreTests/SnippetSendPlanTests.swift`
- Modify: `Sources/macSCPCore/Terminal/SnippetKeystrokes.swift`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces:
  - `public enum SnippetSendPlan: Equatable { case send([UInt8]); case refusedMultilineInsert }`
  - `public enum SnippetSendPlanner { public static func plan(command: String, execute: Bool, bracketedPaste: Bool) -> SnippetSendPlan }`
  - `public static func SnippetKeystrokes.bytes(forLine line: String, execute: Bool) -> [UInt8]`

**Context the implementer needs:** `SnippetKeystrokes` today sends
`Array(snippet.command.utf8)` plus, when `execute`, a CR (`0x0D`). The
doc comment on `terminator` carries the measured chain of evidence for
that — **do not touch it, do not rephrase it.** This task only shifts a
parameter from `Snippet` to `String`.

- [ ] **Step 1: Extract a per-line function from `bytes(for:execute:)`**

In `SnippetKeystrokes.swift`: `private static let terminator` becomes
`static let terminator` (module-internal, so the planner can append it; the
entire doc comment stays unchanged). Then:

```swift
    /// The keystrokes for a single command line: `line` as UTF-8, followed
    /// by `terminator` only when `execute` is `true`.
    ///
    /// `bytes(for:execute:)` below is this function applied to a snippet's
    /// whole command, which is the right thing only while that command is a
    /// single line. `SnippetSendPlanner` calls this one per line for the
    /// multi-line fallback.
    public static func bytes(forLine line: String, execute: Bool) -> [UInt8] {
        var bytes = Array(line.utf8)
        if execute {
            bytes.append(terminator)
        }
        return bytes
    }

    /// The keystrokes for `snippet`: its command as UTF-8, followed by
    /// `terminator` only when `execute` is `true`.
    ///
    /// Inserting (`execute: false`) never appends a terminator, whatever else
    /// changes here — the text lands in the input line exactly as if typed,
    /// and the user still presses Return. That guarantee is asserted once, at
    /// this seam, rather than at each surface that calls it.
    public static func bytes(for snippet: Snippet, execute: Bool) -> [UInt8] {
        bytes(forLine: snippet.command, execute: execute)
    }
```

- [ ] **Step 2: Build and run the existing suite**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: 2197 tests, green. This change alters no behavior; if it
turns red, something else is wrong.

- [ ] **Step 3: Write the failing tests**

`Tests/macSCPCoreTests/SnippetSendPlanTests.swift`:

```swift
import Testing
@testable import macSCPCore

/// `SnippetSendPlanner` turns a command plus two flags into the bytes that
/// go to the shell — or into a refusal.
///
/// The bracketed-paste rule is not this project's invention: SwiftTerm's own
/// ⌘V path on macOS wraps a paste in these two sequences exactly when the
/// remote has enabled mode 2004, and sends the pasted text's raw UTF-8
/// between them with no line-ending translation of any kind
/// (`MacTerminalView.paste(_:)` → `insertText(_:replacementRange:isPaste:)`
/// → `send(txt:)` → `[UInt8](txt.utf8)`). macSCP follows that rule so a
/// snippet behaves like a paste the user performed themselves.
@Suite("SnippetSendPlanner")
struct SnippetSendPlanTests {
    private static let start: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    private static let end: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
    private static let cr: UInt8 = 0x0D

    /// Compared against `SnippetKeystrokes` rather than against a byte
    /// literal written out here: the point is that the planner delegates
    /// for this case, not that someone transcribed the same bytes twice.
    /// Deliberately takes a plain `String` and never builds a `Snippet` —
    /// this suite must not care whether that initializer is failable, which
    /// is a thing Task 2 changes.
    @Test("a single line inserts exactly the bytes it always did")
    func singleLineInsertIsUnchanged() {
        let plan = SnippetSendPlanner.plan(
            command: "docker ps -a", execute: false, bracketedPaste: false)
        #expect(plan == .send(SnippetKeystrokes.bytes(forLine: "docker ps -a", execute: false)))
    }

    @Test("a single line executes exactly the bytes it always did")
    func singleLineExecuteIsUnchanged() {
        let plan = SnippetSendPlanner.plan(
            command: "docker ps -a", execute: true, bracketedPaste: true)
        #expect(plan == .send(SnippetKeystrokes.bytes(forLine: "docker ps -a", execute: true)))
    }

    @Test("a single line is never bracketed, even when the mode is on")
    func singleLineIsNeverBracketed() {
        let plan = SnippetSendPlanner.plan(
            command: "echo hi", execute: false, bracketedPaste: true)
        guard case .send(let bytes) = plan else {
            Issue.record("expected bytes, got \(plan)")
            return
        }
        #expect(!bytes.starts(with: Self.start))
    }

    @Test("multiple lines are bracketed verbatim when the mode is on")
    func multilineIsBracketed() {
        let plan = SnippetSendPlanner.plan(
            command: "cd /tmp\nls -la", execute: false, bracketedPaste: true)
        #expect(plan == .send(Self.start + Array("cd /tmp\nls -la".utf8) + Self.end))
    }

    @Test("a bracketed execute appends one carriage return after the closing sequence")
    func bracketedExecuteAppendsOneReturn() {
        let plan = SnippetSendPlanner.plan(
            command: "cd /tmp\nls -la", execute: true, bracketedPaste: true)
        #expect(plan == .send(Self.start + Array("cd /tmp\nls -la".utf8) + Self.end + [Self.cr]))
    }

    @Test("without bracketing, executing sends each line with its own return")
    func unbracketedExecuteIsLineByLine() {
        let plan = SnippetSendPlanner.plan(
            command: "cd /tmp\nls -la", execute: true, bracketedPaste: false)
        #expect(plan == .send(Array("cd /tmp".utf8) + [Self.cr] + Array("ls -la".utf8) + [Self.cr]))
    }

    @Test("without bracketing, inserting several lines is refused instead of executed")
    func unbracketedMultilineInsertIsRefused() {
        let plan = SnippetSendPlanner.plan(
            command: "cd /tmp\nls -la", execute: false, bracketedPaste: false)
        #expect(plan == .refusedMultilineInsert)
    }

    /// `"\r\n"` is ONE `Character` in Swift, so a rule written with
    /// `contains("\n")` does not see a CRLF command at all — the trap
    /// `Snippet.init?` was fixed for in P3e. A CRLF command must be treated
    /// as two lines here too, not as one line containing junk.
    func crlfCountsAsALineBreak() {
        let plan = SnippetSendPlanner.plan(
            command: "cd /tmp\r\nls -la", execute: false, bracketedPaste: false)
        #expect(plan == .refusedMultilineInsert)
    }

    /// The line-by-line fallback normalizes: whatever separator the command
    /// carries, each line is terminated with the same CR a keypress sends.
    @Test("the line-by-line fallback normalizes CRLF to the terminator")
    func lineByLineNormalizesCRLF() {
        let plan = SnippetSendPlanner.plan(
            command: "a\r\nb", execute: true, bracketedPaste: false)
        #expect(plan == .send(Array("a".utf8) + [Self.cr] + Array("b".utf8) + [Self.cr]))
    }

    /// A trailing newline makes a final empty line, and it is NOT dropped:
    /// at a prompt an empty line is a harmless no-op, and silently trimming
    /// input the user typed is the larger surprise.
    @Test("a trailing newline produces a trailing empty line")
    func trailingNewlineKeepsItsEmptyLine() {
        let plan = SnippetSendPlanner.plan(
            command: "echo hi\n", execute: true, bracketedPaste: false)
        #expect(plan == .send(Array("echo hi".utf8) + [Self.cr] + [Self.cr]))
    }
}
```

**Note:** `crlfCountsAsALineBreak` above **deliberately has no** `@Test` —
that is a mistake that Step 5 finds. See there.

- [ ] **Step 4: Run red**

Run: `swift test --filter SnippetSendPlan 2>&1 | tail -20`
Expected: compile error — `SnippetSendPlanner` and `SnippetSendPlan` do
not exist yet.

- [ ] **Step 5: Add the missing `@Test`**

`crlfCountsAsALineBreak` carries no `@Test` annotation and is therefore
never run — a test that proves nothing is worse than no test at all. Put
`@Test("a CRLF command counts as two lines")` in front of it.

Run afterwards: `swift test --filter SnippetSendPlan 2>&1 | grep -c 'Test .* passed\|Test .* failed'`
Expected: **10** test functions are counted (not 9).

- [ ] **Step 6: Write the minimal implementation**

`Sources/macSCPCore/Terminal/SnippetSendPlan.swift`:

```swift
import Foundation

/// What should go to the shell for one snippet trigger — or why nothing
/// should.
///
/// A plain `[UInt8]` cannot express the one case that matters: inserting a
/// multi-line command into a shell that has not enabled bracketed paste
/// would EXECUTE its leading lines, because the embedded line breaks are
/// what a Return keypress sends. The menu entry says "insert"; bytes that
/// run things are not an insert. So the refusal is part of the result type
/// and the caller has to look at it.
public enum SnippetSendPlan: Equatable {
    case send([UInt8])
    /// Inserting is impossible here without also executing — the caller
    /// explains and offers to execute instead.
    case refusedMultilineInsert
}

/// Decides what a snippet trigger sends.
///
/// Pure: the caller supplies whether the remote has bracketed paste on,
/// which the App layer reads from SwiftTerm's `Terminal`. Core neither
/// imports SwiftTerm nor needs a terminal to be tested.
public enum SnippetSendPlanner {
    /// `ESC [ 2 0 0 ~` — the sequence a terminal emits before pasted text
    /// while the remote has mode 2004 on. Byte-for-byte SwiftTerm's
    /// `EscapeSequences.bracketedPasteStart`; spelled out here because Core
    /// does not import SwiftTerm, and pinned by this file's tests.
    private static let bracketedPasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    /// `ESC [ 2 0 1 ~` — the matching closing sequence
    /// (`EscapeSequences.bracketedPasteEnd`).
    private static let bracketedPasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]

    /// The bytes for `command`, or a refusal.
    ///
    /// A single-line command takes the path it always took and is **never**
    /// bracketed: that keeps the overwhelmingly common case byte-identical
    /// to what shipped before multi-line snippets existed.
    ///
    /// Between the brackets goes the command's raw UTF-8, unchanged — that
    /// is what SwiftTerm's own ⌘V does with the clipboard's string, with no
    /// line-ending translation. The line-by-line fallback does normalize,
    /// because there each line ends with the byte a Return keypress sends.
    public static func plan(
        command: String, execute: Bool, bracketedPaste: Bool
    ) -> SnippetSendPlan {
        // `\r\n` is ONE `Character` in Swift, so `isNewline` per character is
        // the whole rule -- `contains("\n")` would miss a CRLF command.
        guard command.contains(where: \.isNewline) else {
            return .send(SnippetKeystrokes.bytes(forLine: command, execute: execute))
        }
        if bracketedPaste {
            var bytes = bracketedPasteStart
            bytes.append(contentsOf: Array(command.utf8))
            bytes.append(contentsOf: bracketedPasteEnd)
            if execute {
                bytes.append(SnippetKeystrokes.terminator)
            }
            return .send(bytes)
        }
        guard execute else { return .refusedMultilineInsert }
        let lines = command.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var bytes: [UInt8] = []
        for line in lines {
            bytes.append(contentsOf: SnippetKeystrokes.bytes(forLine: String(line), execute: true))
        }
        return .send(bytes)
    }
}
```

- [ ] **Step 7: Run green**

Run: `swift test --filter SnippetSendPlan 2>&1 | tail -5`
Expected: all 10 green.

- [ ] **Step 8: Manually run the constant-return probe**

Temporarily replace `plan`'s body with
`return .send(Array(command.utf8))` and run the suite.

Run: `swift test --filter SnippetSendPlan 2>&1 | grep -c 'failed'`
Expected: **at least 5** tests fail. If fewer fail, the tests aren't
checking enough — report that instead of moving on. Afterwards restore
the body and run the suite green again.

- [ ] **Step 9: Commit**

```bash
git add Sources/macSCPCore/Terminal/SnippetSendPlan.swift Sources/macSCPCore/Terminal/SnippetKeystrokes.swift Tests/macSCPCoreTests/SnippetSendPlanTests.swift
git commit -m "$(cat <<'EOF'
feat(core): plan snippet bytes from the bracketed paste mode

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Core — the Model Accepts Line Breaks

**Files:**
- Modify: `Sources/macSCPCore/Terminal/Snippet.swift`
- Delete: `Sources/macSCPCore/Terminal/SnippetCommandInput.swift`
- Modify: `Tests/macSCPCoreTests/SnippetHighlighterTests.swift` (three
  `SnippetCommandInput` tests are removed)
- Modify: all files with `Snippet(` call sites (see Step 4)
- Modify: `Sources/MacSCPAppKit/SnippetCommandEditor.swift` (only the
  sanitizer call, see Step 5)
- Modify: `Tests/macSCPCoreTests/SnippetTests.swift`,
  `Tests/macSCPCoreTests/SnippetAuditDetailTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `public init(id: UUID = UUID(), name: String, command: String, tags: [String] = [])`
  — **no longer failable.** Tasks 3 and 4 rely on a multi-line command
  being constructible.

**Context:** The line-break rejection was the **only** reason
`Snippet.init?` could fail. Once it goes, an `init?` that never returns
`nil` is a lie — every later reader would write a `guard let` for nothing.
So the initializer becomes non-failable, and the call sites follow suit.
This is mechanical and extensive; it is deliberately its own task.

- [ ] **Step 1: Write the failing test**

Append to `Tests/macSCPCoreTests/SnippetTests.swift`:

```swift
    /// Part 2: a snippet may span lines. `"\r\n"` is ONE `Character` in
    /// Swift, so it gets its own case — a rule written with
    /// `contains("\n")` would not see it.
    @Test("a multi-line command is accepted and kept verbatim")
    func multilineCommandIsKept() {
        let snippet = Snippet(name: "deploy", command: "cd /srv\r\nmake all\n")
        #expect(snippet.command == "cd /srv\r\nmake all\n")
    }

    @Test("a multi-line command survives a store round trip")
    func multilineCommandSurvivesEncoding() throws {
        let original = Snippet(name: "deploy", command: "cd /srv\r\nmake all")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Snippet.self, from: data)
        #expect(decoded.command == original.command)
    }
```

Append to `Tests/macSCPCoreTests/SnippetAuditDetailTests.swift`:

```swift
    /// The audit log is one line per event. `SnippetAuditDetail` already
    /// collapsed whitespace when a command could not contain a newline —
    /// this pins that the rule actually covers newlines, now that a command
    /// can carry them. In Swift every `isNewline` character is also
    /// `isWhitespace`, which is why the existing rule suffices.
    @Test("a multi-line command is logged on a single line")
    func multilineCommandLogsOnOneLine() {
        let snippet = Snippet(name: "deploy", command: "cd /srv\nmake all")
        let text = SnippetAuditDetail.text(for: snippet)
        #expect(!text.contains(where: \.isNewline))
        #expect(text.contains("cd /srv make all"))
    }
```

- [ ] **Step 2: Run red**

Run: `swift test --filter 'Snippet' 2>&1 | tail -20`
Expected: compile errors in the new tests — `Snippet(...)` returns a
`Snippet?`, which cannot be compared with a `String`.

- [ ] **Step 3: Convert the initializer**

In `Snippet.swift`, shorten the doc comment on `command` (the paragraph
about single-line-ness is no longer true; the paragraph about `let` and
normalization stays) and replace the initializer:

```swift
    /// Normalizes `tags` via `TagList.normalized` — see that type's doc
    /// comment for the exact rule.
    ///
    /// No longer failable (snippet editor, part 2): the single-line rule was
    /// the only thing this initializer ever rejected, and a command may now
    /// span lines. How a multi-line command reaches the shell is
    /// `SnippetSendPlanner`'s decision, not the model's.
    public init(id: UUID = UUID(), name: String, command: String, tags: [String] = []) {
        self.id = id
        self.name = name
        self.command = command
        self.tags = TagList.normalized(tags)
    }
```

And in the decoder, replace the `guard let` block with the direct call:

```swift
        let tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self = Self(id: id, name: name, command: command, tags: tags)
```

The comment above it ("Via the normalizing (and validating) init …") becomes
"Via the normalizing init — otherwise decode would be a second write path
that a hand-edited store file could use to smuggle an untrimmed or duplicate
tag past the normalization above."

- [ ] **Step 4: Update the call sites**

Run: `grep -rn 'Snippet(name:\|Snippet(id:' Sources/ Tests/ | wc -l`

Note the number **now**; it is the amount of work and belongs in the
report. At every one of these spots, remove the trailing `!` or unwrap
`try #require(...)`. Affected are files in `Sources/macSCPCore/`,
`Tests/macSCPCoreTests/`, and `Tests/macSCPAppKitTests/`.

Run afterwards: `swift build 2>&1 | grep -c error`
Expected: `0`.

- [ ] **Step 5: Delete the sanitizer**

```bash
git rm Sources/macSCPCore/Terminal/SnippetCommandInput.swift
```

Remove the three `SnippetCommandInput` lines from
`Tests/macSCPCoreTests/SnippetHighlighterTests.swift`, along with the test
functions that carry them and their doc comments.

In the same pass, remove the one remaining call in
`Sources/MacSCPAppKit/SnippetCommandEditor.swift`: the delegate method
`textView(_:shouldChangeTextIn:replacementString:)` did nothing but
sanitize and is removed entirely. **Only this method** — the rest of the
editor belongs to Task 3.

This belongs here and not in Task 3, so that every commit on this branch
compiles on its own; a commit that doesn't build the app layer is not an
acceptable intermediate state under this project's CI gates. From now on
the editor accepts pasted line breaks, while a typed Return is still
swallowed — a coherent intermediate state that Task 3 resolves.

Run: `grep -rn 'SnippetCommandInput' Sources/ Tests/`
Expected: **no matches.**

- [ ] **Step 6: Fix the two doc comments that are now wrong**

`Tests/macSCPCoreTests/SnippetExportCodecTests.swift` (the line range around
the comment "`Snippet.init(from:)` refuses a multi-line command") and
`Tests/macSCPCoreTests/SnippetImportPlannerTests.swift` ("`Snippet.init?` only
rejects a multi-line command, not a blank name") both claim a rule that no
longer exists. Find them with

```bash
grep -rn 'refuses a multi-line\|rejects a multi-line' Tests/
```

and rewrite them to say what the respective test actually checks. In the
same pass, check whether the associated test still proves anything — if it
no longer does, report that instead of silently leaving it in place.

- [ ] **Step 7: Build and run the full suite**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: green — **the whole suite, not just Core.** If the app layer
does not build, Step 5 is incomplete.

- [ ] **Step 8: Commit**

```bash
git add -A Sources/macSCPCore Tests/macSCPCoreTests Tests/macSCPAppKitTests
git commit -m "$(cat <<'EOF'
feat(core): let a snippet command span lines

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: App — the Editor Becomes Multi-line

**Files:**
- Modify: `Sources/MacSCPAppKit/SnippetCommandEditor.swift`
- Modify: `Sources/MacSCPAppKit/SnippetsSheet.swift`
- Modify: `Tests/macSCPAppKitTests/SnippetCommandEditorGuardTests.swift`

**Interfaces:**
- Consumes: from Task 2, that `Snippet(name:command:)` is no longer failable
  and accepts line breaks.
- Produces: nothing that Task 4 relies on.

**Context:** The editor is an `NSTextView` inside an
`NSViewRepresentable`, built in Part 1 and checked by the maintainer
against the running build. What's there was hard-won — in particular the
disabled automatic substitutions, the Tab handling, and the
no-line-break setting. **Don't touch any of it**, except what is
explicitly named here.

- [ ] **Step 1: Flip the guard tests (red)**

In `SnippetCommandEditorGuardTests.swift`: the suite's doc comment names
point 4 "Return swallowed at the command layer" with the justification
"This field is single-line". Neither is true any more. Replace the
paragraph with:

```swift
/// 4. **Return inserts a line break.** Part 2 made a snippet command
///    multi-line, so a typed Return has something to insert and must NOT be
///    claimed at the command layer. A reappearing `insertNewline(_:)` case
///    in `textView(_:doCommandBy:)` would silently make the field
///    single-line again, and the failure would look like "Return does
///    nothing" rather than like a bug.
```

And rename the test `insertNewlineIsClaimedInDoCommandBy` to
`insertNewlineIsNotClaimedInDoCommandBy`, with the reversed expectation:
the selector must **not** appear in `doCommandBy`. Adjust that test's two
self-tests accordingly.

Add a guard for the new Save shortcut, in the style of its neighbors in
this file (source-scanning, fail-closed, with a self-test):

```swift
    /// The snippet editor's Save button carries ⌘Return, not the plain
    /// default action: Return belongs to the command field now, which is
    /// multi-line. A Save button that reverted to `.defaultAction` would
    /// take Return back and make line breaks untypeable — and the failure
    /// would present as "the editor saves when I try to add a line".
    @Test("the snippet editor saves on command-Return")
    func snippetEditorSavesOnCommandReturn() throws {
        let source = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        let body = try Self.functionBody(containing: "SnippetCommandEditor(", in: source)
        #expect(body.contains("keyboardShortcut(.return, modifiers: .command)"))
        #expect(!body.contains("keyboardShortcut(.defaultAction)"))
    }

    @Test("the command-Return scan reacts to a reverted shortcut")
    func commandReturnScanReactsToRegression() throws {
        let reverted = """
            func editorSheet() -> some View {
                SnippetCommandEditor(text: $command)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
            """
        let body = try Self.functionBody(containing: "SnippetCommandEditor(", in: reverted)
        #expect(!body.contains("keyboardShortcut(.return, modifiers: .command)"))
    }
```

If `functionBody(containing:in:)` cannot find the editor call site inside a
function that also contains the Save button, then the two are not in the
same body — report that instead of loosening the scan.

Run: `swift test --filter SnippetCommandEditor 2>&1 | tail -10`
Expected: red — the selector is still there.

- [ ] **Step 2: Convert the editor**

In `SnippetCommandEditor.swift`:

1. Remove the `case #selector(NSResponder.insertNewline(_:))` branch from
   `textView(_:doCommandBy:)` (Tab and Shift-Tab stay).
2. Remove the sanitizer call in the `shouldChangeTextIn:` delegate; the
   method is thereby removed entirely, because it did nothing else.
3. Revise the type's doc comment: Hazard 4 was called "Newlines" and
   described the substitution. It becomes:

```swift
/// 4. **Line breaks are content.** Part 2 made a snippet command
///    multi-line: a typed Return inserts, a pasted multi-line string is
///    kept as it stands, and `Snippet` stores both verbatim. What reaches
///    the shell is `SnippetSendPlanner`'s decision, made at trigger time
///    from the remote's bracketed-paste mode — not this view's.
```

4. `textView.isVerticallyResizable` stays `false` and `autoresizingMask`
   stays `[.height]`: the height still comes from the form row. The
   comment there justifies that with "one-line field" — change the
   justification to "the row decides the height; the view reports how
   tall it would like to be through `intrinsicHeight` below", **not** the
   setting.
5. Add a measured desired height that the call site can read:

```swift
    /// How tall this field wants to be for `text`: one line's height per
    /// line, plus the container insets, clamped so a long script cannot push
    /// the sheet off screen. Beyond the clamp the view scrolls vertically.
    ///
    /// The bounds are estimates and belong in the maintainer's visual check
    /// — no test in this project draws an `NSViewRepresentable`.
    static func intrinsicHeight(for text: String) -> CGFloat {
        let lineHeight: CGFloat = 16
        let insets: CGFloat = 8
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        let clamped = min(max(lines, 1), 8)
        return CGFloat(clamped) * lineHeight + insets
    }
```

6. Set `scroll.hasVerticalScroller = true` (instead of `false`), so a
   body beyond the upper bound stays reachable.

- [ ] **Step 3: Update the call site in the sheet**

In `SnippetsSheet.swift`, replace the fixed `.frame(height: 24)` with the
measured height and set the Save shortcut. Find the spot with

```bash
grep -n 'SnippetCommandEditor(' Sources/MacSCPAppKit/SnippetsSheet.swift
```

and replace `.frame(height: 24)` with
`.frame(height: SnippetCommandEditor.intrinsicHeight(for: command))`.

**This** sheet's Save button loses `.keyboardShortcut(.defaultAction)`
and gets `.keyboardShortcut(.return, modifiers: .command)`. Count
beforehand how many `.defaultAction` spots the file has, and change
**only** the one in the snippet editor:

```bash
grep -n 'keyboardShortcut(.defaultAction)' Sources/MacSCPAppKit/SnippetsSheet.swift
```

Enter the number in the report and explain in the commit which one you
touched.

- [ ] **Step 4: Make the list row honest**

The command text is displayed on a single line in three places — in the
sheet (`SnippetsSheet.row`), in the preview line on the terminal panel
(`ContentView+Detail.commandPreviewLine`), and in the action sheet
(`SnippetActionSheet`). Check all three:

```bash
grep -rn 'Text(snippet.command)\|snippet.command$' Sources/MacSCPAppKit/
```

`.lineLimit(1)` shows only the first line of a multi-line command,
**with no indication** that more follow. For this, add a tested helper in
Core instead of writing the rule three times in views —
`Sources/macSCPCore/Terminal/SnippetCommandSummary.swift`:

```swift
import Foundation

/// One line standing in for a command that may have several.
///
/// Three surfaces show a command in a single line — the snippets sheet's
/// row, the terminal panel's hover preview, and the action sheet's header.
/// `.lineLimit(1)` alone would show the first line and silently drop the
/// rest, so "cd /srv" and "cd /srv" + "rm -rf build" would look identical
/// in the list. The count is the whole point.
public enum SnippetCommandSummary {
    /// `command`'s first line, plus how many lines follow when there are
    /// any. Returns the command unchanged when it is a single line, so the
    /// common case gains no decoration at all.
    public static func firstLine(of command: String) -> (text: String, moreLines: Int) {
        let lines = command.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let first = lines.first, lines.count > 1 else { return (command, 0) }
        return (String(first), lines.count - 1)
    }
}
```

The corresponding test, in `Tests/macSCPCoreTests/SnippetCommandSummaryTests.swift`:

```swift
import Testing
@testable import macSCPCore

@Suite("SnippetCommandSummary")
struct SnippetCommandSummaryTests {
    @Test("a single-line command is returned unchanged with no follow-up count")
    func singleLineIsUnchanged() {
        let summary = SnippetCommandSummary.firstLine(of: "docker ps -a")
        #expect(summary.text == "docker ps -a")
        #expect(summary.moreLines == 0)
    }

    @Test("a two-line command reports its first line and one follower")
    func twoLinesReportOneFollower() {
        let summary = SnippetCommandSummary.firstLine(of: "cd /srv\nmake all")
        #expect(summary.text == "cd /srv")
        #expect(summary.moreLines == 1)
    }

    /// `"\r\n"` is ONE `Character` in Swift — a split written against "\n"
    /// alone would see one line here, not two.
    @Test("CRLF separates lines like any other break")
    func crlfSeparatesLines() {
        let summary = SnippetCommandSummary.firstLine(of: "a\r\nb\r\nc")
        #expect(summary.text == "a")
        #expect(summary.moreLines == 2)
    }

    @Test("a trailing newline counts the empty line it creates")
    func trailingNewlineCounts() {
        let summary = SnippetCommandSummary.firstLine(of: "echo hi\n")
        #expect(summary.text == "echo hi")
        #expect(summary.moreLines == 1)
    }
}
```

Wire it up at the two single-line spots. In `SnippetsSheet.row`, replace

```swift
                Text(snippet.command)
```

this line with this block:

```swift
                let summary = SnippetCommandSummary.firstLine(of: snippet.command)
                HStack(spacing: 4) {
                    Text(summary.text)
                    if summary.moreLines > 0 {
                        Text(String(
                            format: L10n.string("snippets.command.moreLines %lld", "+%lld more"),
                            summary.moreLines))
                            .foregroundStyle(DesignTokens.inkTertiary)
                    }
                }
```

In `ContentView+Detail.commandPreviewLine`, apply the same derivation to
the command found there via `SnippetPreviewLine.row(hovered:pinned:)`; the
fallback text ("Point at a snippet…") stays unchanged.

The **action sheet** (`SnippetActionSheet.swift`) shows the command in
full and is the one place meant to show it completely: there, any
truncation is removed — the `Text(snippet.command)` gets no `lineLimit`.
When touching it, check whether one is already there.

The key `snippets.command.moreLines %lld` goes into all four catalogs; the
texts are in Task 4 Step 4. The form — format marker **in the key**, call
via `String(format:)` — is this project's own, see `AuditLogSheet.swift`
with `audit.count %lld`. Do not deviate from it.

- [ ] **Step 5: Build and run the suite**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: green, and more tests than before Task 2 (the new ones from
Task 1 and 2, minus the three deleted sanitizer tests).

- [ ] **Step 6: Commit**

```bash
git add -A Sources/MacSCPAppKit Tests/macSCPAppKitTests
git commit -m "$(cat <<'EOF'
feat(app): make the snippet command field multi-line

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: App — Wiring, Refusal, Translations

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TerminalPanelViewModel.swift`
- Modify: `Sources/MacSCPAppKit/SSHTerminalView.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift`
- Modify: `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `SnippetSendPlanner.plan(command:execute:bracketedPaste:)` and
  `SnippetSendPlan` from Task 1.
- Produces: nothing.

**Context:** `triggerSnippet` in `ContentView.swift` today calls
`SnippetKeystrokes.bytes(for:execute:)` and `terminal.send(bytes)`.
`terminal` is a `TerminalPanelViewModel` (Core) — it does not know
SwiftTerm. The SwiftTerm `TerminalView` is created in
`SSHTerminalView.makeNSView`. The established path between the two is a
closure that the view hands to the model: `viewModel.onOutput = { [weak
terminal] bytes in … }` sits right there. This task uses the same shape
for the reverse direction.

- [ ] **Step 1: Add the channel in the model**

In `TerminalPanelViewModel.swift`, next to `onOutput`:

```swift
    /// Whether the remote has bracketed paste (mode 2004) on, as the local
    /// emulator has observed it. Set by the terminal view, the same way
    /// `onOutput` is; `nil` while no view is attached, which reads as "off"
    /// — the conservative answer, since it only ever costs a refusal or a
    /// line-by-line send, never an unexpected execution.
    public var bracketedPasteQuery: (() -> Bool)?

    /// `bracketedPasteQuery`'s answer, defaulting to `false`.
    public var remoteWantsBracketedPaste: Bool { bracketedPasteQuery?() ?? false }
```

- [ ] **Step 2: The view fills it**

In `SSHTerminalView.makeNSView`, right next to `viewModel.onOutput = …`:

```swift
        viewModel.bracketedPasteQuery = { [weak terminal] in
            terminal?.getTerminal().bracketedPasteMode ?? false
        }
```

- [ ] **Step 3: Route `triggerSnippet` through the planner**

In `ContentView.swift`, replace the block starting at
`let bytes = SnippetKeystrokes.bytes(...)`:

```swift
        let plan = SnippetSendPlanner.plan(
            command: snippet.command, execute: execute,
            bracketedPaste: terminal.remoteWantsBracketedPaste)
        guard case .send(let bytes) = plan else {
            // The remote cannot take a multi-line paste without running it,
            // and this entry promised to insert. Explain instead of sending
            // bytes that would execute -- see `SnippetSendPlan`.
            pendingMultilineInsertRefusal = snippet
            return
        }
```

The rest (`guard execute else { terminal.send(bytes); return }` and the
audit branch) stays unchanged. Add `@State var pendingMultilineInsertRefusal: Snippet?` next to the
other `@State` fields in `ContentView.swift`, and the alert wherever the
file keeps its other alerts:

```swift
        .alert(
            L10n.string("snippets.insert.multilineRefused.title", "This snippet has several lines"),
            isPresented: Binding(
                get: { pendingMultilineInsertRefusal != nil },
                set: { if !$0 { pendingMultilineInsertRefusal = nil } }),
            presenting: pendingMultilineInsertRefusal
        ) { snippet in
            Button(L10n.string("snippets.insert.multilineRefused.execute", "Execute")) {
                pendingMultilineInsertRefusal = nil
                triggerSnippet(snippet, execute: true)
            }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {
                pendingMultilineInsertRefusal = nil
            }
        } message: { _ in
            Text(L10n.string(
                "snippets.insert.multilineRefused.body",
                "The remote shell cannot take a multi-line command without running it. Execute it instead?"))
        }
```

**Before writing it, check** whether `common.cancel` exists as a key.

```bash
grep -n '"common.cancel"' Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings
```

If that finds nothing, use whatever key this file's neighboring alerts use
for their Cancel button — and note in the report which one that was.

- [ ] **Step 4: The texts into all four catalogs**

Four keys, in `en`, `de`, `fr`, and `pl`. `snippets.command.moreLines %lld`
belongs to Task 3 Step 4 and is entered here too, so that the four
catalogs catch up in one pass. Put them in each catalog at the same spot
as the other `snippets.*` keys:

```
"snippets.insert.multilineRefused.title" = "This snippet has several lines";
"snippets.insert.multilineRefused.body" = "The remote shell cannot take a multi-line command without running it. Execute it instead?";
"snippets.insert.multilineRefused.execute" = "Execute";
"snippets.command.moreLines %lld" = "+%lld more";
```

German:

```
"snippets.insert.multilineRefused.title" = "Dieses Snippet hat mehrere Zeilen";
"snippets.insert.multilineRefused.body" = "Die Gegenstelle kann einen mehrzeiligen Befehl nicht übernehmen, ohne ihn auszuführen. Stattdessen ausführen?";
"snippets.insert.multilineRefused.execute" = "Ausführen";
"snippets.command.moreLines %lld" = "+%lld weitere";
```

French:

```
"snippets.insert.multilineRefused.title" = "Cet extrait comporte plusieurs lignes";
"snippets.insert.multilineRefused.body" = "L’interpréteur distant ne peut pas recevoir une commande multiligne sans l’exécuter. L’exécuter à la place ?";
"snippets.insert.multilineRefused.execute" = "Exécuter";
"snippets.command.moreLines %lld" = "+%lld de plus";
```

Polish:

```
"snippets.insert.multilineRefused.title" = "Ten fragment ma kilka wierszy";
"snippets.insert.multilineRefused.body" = "Zdalna powłoka nie może przyjąć polecenia wielowierszowego bez jego wykonania. Wykonać je zamiast tego?";
"snippets.insert.multilineRefused.execute" = "Wykonaj";
"snippets.command.moreLines %lld" = "+%lld więcej";
```

- [ ] **Step 5: Build and run the full suite**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: green. If a key is missing from a catalog, the L10n guard test
turns the suite red — that is the intended safety-net effect.

- [ ] **Step 6: Commit**

```bash
git add -A Sources
git commit -m "$(cat <<'EOF'
feat(app): send multi-line snippets by the remote's paste mode

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Wrap-up

After Task 4, a wrap-up report belongs at
`docs/superpowers/specs/2026-08-19-snippet-multiline-closeout.md`, in
German, with:

- the measured suite counts before and after,
- the call-site count counted in Task 2 Step 4,
- the `.defaultAction` count counted in Task 3 Step 3,
- **explicitly**, the pending visual check: the field growing along with
  its upper bound, ⌘Return, the three display spots with a multi-line
  command, and a bracketed paste against a real shell with the mode
  turned on.

Part 1 showed that for `NSViewRepresentable`, neither the green suite nor
the review is enough: looking at the running app found two bugs there,
both of which looked plausible. This section is not a footnote.
