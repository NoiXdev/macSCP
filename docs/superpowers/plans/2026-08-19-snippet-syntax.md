# Snippet syntax display: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task.

**Goal:** The command field in the snippet editor colours shell syntax —
while typing, not only when reading.

**Architecture:** A tested tokenizer in Core (text in, named ranges out, no
colours) and an `NSTextView` in an `NSViewRepresentable` that pulls its
colours from the existing design tokens. Alongside it, a tested function
that intercepts line breaks, because `Snippet.init?` rejects them.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
Swift Testing, AppKit.

**Spec:** `docs/superpowers/specs/2026-08-19-snippet-syntax-design.md`

## Global Constraints

- Code, comments, test names, commit messages **English**; docs German.
- Conventional Commits, footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Core knows **no colours and no AppKit**. The mapping of kind → colour
  happens exclusively in the App layer.
- **No stored `type` field on `Snippet`.** The language is a parameter
  that today has one case.
- TDD red→green. Suite: `swift test`.
- **This plan's prose is a claim to be checked.** If a signature or a
  field name does not match: report it, do not silently rebuild.

## Files

| File | Role |
|---|---|
| `Sources/macSCPCore/Terminal/SnippetHighlighter.swift` (new) | tokenizer + language enum + token type |
| `Sources/macSCPCore/Terminal/SnippetCommandInput.swift` (new) | intercept line breaks |
| `Tests/macSCPCoreTests/SnippetHighlighterTests.swift` (new) | both |
| `Sources/MacSCPAppKit/SnippetCommandEditor.swift` (new) | `NSViewRepresentable` over `NSTextView` |
| `Sources/MacSCPAppKit/SnippetsSheet.swift` | replace the `TextField` in the editor sheet |

---

### Task 1: Tokenizer and input filter (Core)

**Files:**
- Create: `Sources/macSCPCore/Terminal/SnippetHighlighter.swift`
- Create: `Sources/macSCPCore/Terminal/SnippetCommandInput.swift`
- Test: `Tests/macSCPCoreTests/SnippetHighlighterTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `SnippetHighlighter.tokens(in:language:) -> [SnippetToken]`,
  `SnippetToken` with `kind` and `range: Range<String.Index>`,
  `SnippetLanguage.shell`, `SnippetCommandInput.sanitized(_:) -> String`.
  Task 2 calls all three.

- [ ] **Step 1: Write the tests**

```swift
import Foundation
import Testing
@testable import macSCPCore

/// Covers what the snippet editor colours BEFORE any view is involved:
/// which ranges of a command are what. No colours here -- Core does not
/// know any; the App layer maps kinds to design tokens.
@Suite("Snippet highlighter")
struct SnippetHighlighterTests {
    /// Reads a token back as the substring it covers, so the expectations
    /// below stay readable and do not depend on index arithmetic.
    private func spans(_ text: String, _ kind: SnippetToken.Kind) -> [String] {
        SnippetHighlighter.tokens(in: text, language: .shell)
            .filter { $0.kind == kind }
            .map { String(text[$0.range]) }
    }

    @Test func theFirstWordIsTheCommand() {
        #expect(spans("docker ps -a", .command) == ["docker"])
    }

    @Test func dashedWordsAreOptions() {
        #expect(spans("tail -f --lines 20 x.log", .option) == ["-f", "--lines"])
    }

    @Test func quotedRunsAreStrings() {
        #expect(spans("echo 'a b' \"c d\"", .string) == ["'a b'", "\"c d\""])
    }

    @Test func dollarNamesAreVariables() {
        #expect(spans("echo $HOME ${TAG}", .variable) == ["$HOME", "${TAG}"])
    }

    @Test func hashStartsACommentToEndOfLine() {
        #expect(spans("ls # list them", .comment) == ["# list them"])
    }

    @Test func pipesAndSemicolonsAreOperators() {
        #expect(spans("a | b && c ; d > e", .operator) == ["|", "&&", ";", ">"])
    }

    // --- the traps -------------------------------------------------------

    /// An unterminated quote runs to the end rather than swallowing the
    /// tokenizer or producing nothing.
    @Test func anUnterminatedStringRunsToTheEnd() {
        #expect(spans("echo \"abc", .string) == ["\"abc"])
    }

    /// A `#` INSIDE a string is text, not a comment -- the single most
    /// common way a naive scanner breaks.
    @Test func aHashInsideAStringIsNotAComment() {
        #expect(spans("echo 'a # b'", .comment).isEmpty)
        #expect(spans("echo 'a # b'", .string) == ["'a # b'"])
    }

    /// A `$` with no name after it is not a variable.
    @Test func aDollarWithoutANameIsNotAVariable() {
        #expect(spans("echo $", .variable).isEmpty)
    }

    /// Constant-return probe, the other direction: a tokenizer that marks
    /// EVERYTHING as the command fails here, and one that marks everything
    /// plain fails every test above.
    @Test func onlyTheFirstWordIsTheCommand() {
        let text = "cp source target"
        #expect(spans(text, .command) == ["cp"])
        #expect(spans(text, .plain) == ["source", "target"])
    }

    // --- newline rejection ----------------------------------------------

    /// `Snippet.init?` refuses any newline, and an `NSTextView` accepts
    /// Return by default. Pasting a two-line command must therefore become
    /// one line rather than a value the model rejects on save.
    @Test func newlinesBecomeSpaces() {
        #expect(SnippetCommandInput.sanitized("a\nb") == "a b")
    }

    /// CRLF is ONE `Character` in Swift, so a naive `contains("\n")` misses
    /// it -- the same trap `Snippet.init?` was fixed for in P3e.
    @Test func aCarriageReturnLineFeedAlsoBecomesOneSpace() {
        #expect(SnippetCommandInput.sanitized("a\r\nb") == "a b")
    }

    @Test func textWithoutNewlinesIsUnchanged() {
        #expect(SnippetCommandInput.sanitized("docker ps -a") == "docker ps -a")
    }
}
```

- [ ] **Step 2: Run the tests, confirm red**

```bash
swift test --filter "SnippetHighlighterTests"
```

Expected: FAIL, `cannot find 'SnippetHighlighter' in scope`.

- [ ] **Step 3: Build the tokenizer**

`Sources/macSCPCore/Terminal/SnippetHighlighter.swift`:

```swift
import Foundation

/// Which syntax a snippet's command is written in (snippet editor, part 1).
///
/// A parameter rather than a stored field on `Snippet`: today there is one
/// case, and a stored column with a single possible value buys nothing but
/// a migration. When a second protocol arrives, the field gets added then
/// and legacy JSON decodes as `.shell` -- the same optional-defaulting
/// pattern `groupID` and `loginSetID` already use.
public enum SnippetLanguage: Sendable {
    case shell
}

/// One coloured run of a command. Carries WHAT a range is, never which
/// colour it gets -- Core knows no colours; the App layer maps kinds to
/// design tokens.
public struct SnippetToken: Equatable, Sendable {
    public enum Kind: Sendable, Equatable {
        case command, option, string, variable, comment, `operator`, plain
    }
    public let kind: Kind
    public let range: Range<String.Index>

    public init(kind: Kind, range: Range<String.Index>) {
        self.kind = kind
        self.range = range
    }
}

public enum SnippetHighlighter {
    /// Splits `text` into coloured runs. Single pass, left to right; every
    /// character lands in exactly one token, so the App layer can colour
    /// the whole string without gaps.
    public static func tokens(in text: String, language: SnippetLanguage) -> [SnippetToken] {
        switch language {
        case .shell: return shellTokens(in: text)
        }
    }

    private static let operatorStarts: Set<Character> = ["|", "&", ";", ">", "<"]

    private static func shellTokens(in text: String) -> [SnippetToken] {
        var tokens: [SnippetToken] = []
        var i = text.startIndex
        var sawCommand = false

        while i < text.endIndex {
            let c = text[i]

            if c.isWhitespace {
                i = text.index(after: i)
                continue
            }

            // A comment runs to the end of the line -- but only outside a
            // string, which is why quotes are consumed whole below.
            if c == "#" {
                tokens.append(SnippetToken(kind: .comment, range: i..<text.endIndex))
                break
            }

            if c == "'" || c == "\"" {
                var j = text.index(after: i)
                while j < text.endIndex, text[j] != c { j = text.index(after: j) }
                // An unterminated quote runs to the end rather than
                // dropping the rest of the line on the floor.
                let end = j < text.endIndex ? text.index(after: j) : text.endIndex
                tokens.append(SnippetToken(kind: .string, range: i..<end))
                i = end
                continue
            }

            if c == "$" {
                var j = text.index(after: i)
                if j < text.endIndex, text[j] == "{" {
                    while j < text.endIndex, text[j] != "}" { j = text.index(after: j) }
                    if j < text.endIndex { j = text.index(after: j) }
                    tokens.append(SnippetToken(kind: .variable, range: i..<j))
                    i = j
                    continue
                }
                while j < text.endIndex, text[j].isLetter || text[j].isNumber || text[j] == "_" {
                    j = text.index(after: j)
                }
                // A bare `$` names nothing, so it is not a variable.
                if j > text.index(after: i) {
                    tokens.append(SnippetToken(kind: .variable, range: i..<j))
                    i = j
                } else {
                    tokens.append(SnippetToken(kind: .plain, range: i..<j))
                    i = j
                }
                continue
            }

            if operatorStarts.contains(c) {
                var j = text.index(after: i)
                // `&&` and `||` are one operator, `&` and `|` on their own
                // are too.
                if j < text.endIndex, text[j] == c, c == "&" || c == "|" {
                    j = text.index(after: j)
                }
                tokens.append(SnippetToken(kind: .operator, range: i..<j))
                i = j
                continue
            }

            // A plain word: everything up to whitespace or a character that
            // starts something else.
            var j = i
            while j < text.endIndex,
                  !text[j].isWhitespace,
                  text[j] != "'", text[j] != "\"", text[j] != "$", text[j] != "#",
                  !operatorStarts.contains(text[j]) {
                j = text.index(after: j)
            }
            let word = text[i..<j]
            let kind: SnippetToken.Kind
            if !sawCommand {
                kind = .command
                sawCommand = true
            } else if word.hasPrefix("-") {
                kind = .option
            } else {
                kind = .plain
            }
            tokens.append(SnippetToken(kind: kind, range: i..<j))
            i = j
        }
        return tokens
    }
}
```

- [ ] **Step 4: Build the input filter**

`Sources/macSCPCore/Terminal/SnippetCommandInput.swift`:

```swift
import Foundation

/// What may enter a snippet's command field (snippet editor, part 1).
///
/// `Snippet.init?` refuses a command containing any newline, and an
/// `NSTextView` accepts Return by default. Without this, the editor would
/// happily build a value the model rejects on save, and the user would see
/// only that saving does nothing.
///
/// Newlines become a single space rather than being dropped: pasting a
/// two-line command should stay runnable, not silently glue two words
/// together.
public enum SnippetCommandInput {
    public static func sanitized(_ text: String) -> String {
        // `\r\n` is ONE `Character` in Swift, so a search for "\n" alone
        // misses it -- the same trap `Snippet.init?` was fixed for in P3e.
        String(text.map { $0.isNewline ? " " : $0 })
    }
}
```

- [ ] **Step 5: Run the tests, confirm green**

```bash
swift test --filter "SnippetHighlighterTests"
```

Expected: PASS (13 tests).

- [ ] **Step 6: Full suite**

```bash
swift test
```

- [ ] **Step 7: Commit**

```bash
git add Sources/macSCPCore/Terminal Tests/macSCPCoreTests/SnippetHighlighterTests.swift
git commit -m "feat(core): tokenize a snippet command for highlighting

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: The colouring input field (App)

**Files:**
- Create: `Sources/MacSCPAppKit/SnippetCommandEditor.swift`
- Modify: `Sources/MacSCPAppKit/SnippetsSheet.swift` (the `TextField` in the editor sheet)

**Interfaces:**
- Consumes: `SnippetHighlighter.tokens(in:language:)`, `SnippetToken.Kind`,
  `SnippetLanguage.shell`, `SnippetCommandInput.sanitized(_:)` from Task 1;
  `DesignTokens.inkNS`, `.inkSecondaryNS`, `.inkTertiaryNS`,
  `.remoteBlueNS` equivalents via `Color` tokens (see Step 2)
- Produces: nothing

- [ ] **Step 1: Build the representable**

`Sources/MacSCPAppKit/SnippetCommandEditor.swift`. The four known
pitfalls are each implemented here as a named safeguard — whoever
removes one should know what it was holding up:

```swift
import AppKit
import SwiftUI
import macSCPCore

/// The snippet editor's command field: an `NSTextView` so the text can be
/// coloured WHILE typing, which a SwiftUI `TextField` cannot do.
///
/// Four hazards this deliberately handles, because each of them is
/// invisible until someone hits it:
///
/// 1. **Caret.** Re-colouring sets attributes; without saving and restoring
///    the selected range, the insertion point jumps to the end on every
///    keystroke.
/// 2. **Undo.** Attribute changes must not enter the undo stack, or ⌘Z
///    undoes colours instead of text.
/// 3. **Binding loop.** text change → binding → `updateNSView` → text
///    change. The guard is comparing the string before assigning it.
/// 4. **Newlines.** `Snippet.init?` refuses them; `SnippetCommandInput`
///    turns them into spaces before the binding ever sees them.
struct SnippetCommandEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.drawsBackground = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .bezelBorder
        context.coordinator.apply(text, to: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Hazard 3: only touch the view when the value actually differs,
        // or every binding round trip re-enters this.
        guard textView.string != text else { return }
        context.coordinator.apply(text, to: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: SnippetCommandEditor

        init(_ parent: SnippetCommandEditor) { self.parent = parent }

        /// Hazard 4: Return, and a pasted multi-line command, become spaces
        /// before anything else sees them.
        func textView(
            _ textView: NSTextView, shouldChangeTextIn range: NSRange,
            replacementString: String?
        ) -> Bool {
            guard let replacement = replacementString else { return true }
            let cleaned = SnippetCommandInput.sanitized(replacement)
            guard cleaned != replacement else { return true }
            textView.insertText(cleaned, replacementRange: range)
            return false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            recolour(textView)
        }

        func apply(_ value: String, to textView: NSTextView) {
            textView.string = value
            recolour(textView)
        }

        /// Hazards 1 and 2: the caret is put back where it was, and the
        /// attribute run is kept out of the undo stack.
        private func recolour(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let selected = textView.selectedRange()
            let text = textView.string
            let full = NSRange(location: 0, length: (text as NSString).length)

            textView.undoManager?.disableUndoRegistration()
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: DesignTokens.inkNS, range: full)
            for token in SnippetHighlighter.tokens(in: text, language: .shell) {
                storage.addAttribute(
                    .foregroundColor, value: Self.colour(for: token.kind),
                    range: NSRange(token.range, in: text))
            }
            storage.endEditing()
            textView.undoManager?.enableUndoRegistration()

            textView.setSelectedRange(selected)
        }

        /// The one place kinds become colours. Core supplies neither.
        private static func colour(for kind: SnippetToken.Kind) -> NSColor {
            switch kind {
            case .command: return NSColor(DesignTokens.remoteBlue)
            case .option: return NSColor(DesignTokens.agentGreen)
            case .string: return NSColor(DesignTokens.localAmber)
            case .variable: return NSColor(DesignTokens.remoteBlue)
            case .comment: return DesignTokens.inkTertiaryNS
            case .operator: return DesignTokens.inkSecondaryNS
            case .plain: return DesignTokens.inkNS
            }
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build
```

Expected: no errors. `NSColor(_ color: Color)` exists from macOS 11
onward; if that fails, the `…NS` variants of the tokens are the
replacement — report which one is missing rather than hardcoding a colour.

- [ ] **Step 3: Swap the field into the sheet**

In `SnippetsSheet.swift`, in the editor sheet:

```swift
            let commandLabel = L10n.string("snippets.editor.command", "Command")
            FormRow(label: commandLabel) {
                // Snippet editor part 1: an NSTextView, because a SwiftUI
                // TextField cannot colour text while it is being typed.
                // Single-line stays the rule -- `SnippetCommandEditor`
                // turns Return into a space, since `Snippet.init?` refuses
                // newlines.
                SnippetCommandEditor(text: $command)
                    .frame(height: 24)
            }
```

- [ ] **Step 4: Build and full suite**

```bash
swift build && swift test
```

Expected: PASS. No test in this project renders the representable — the
suite only proves here that nothing else broke.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPAppKit
git commit -m "feat(app): colour shell syntax in the snippet command field

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Wrap-up

**Files:**
- Create: `docs/superpowers/specs/2026-08-19-snippet-syntax-closeout.md`

- [ ] **Step 1: Full suite, read the output BEFORE committing**

```bash
swift test
```

- [ ] **Step 2: Verify that Core knows no colours**

```bash
grep -c "NSColor\|Color\|import AppKit\|import SwiftUI" Sources/macSCPCore/Terminal/SnippetHighlighter.swift
```

Expected: `0`. A positive control, so that an empty hit does not pass as
success:

```bash
grep -c "SnippetToken" Sources/macSCPCore/Terminal/SnippetHighlighter.swift
```

Expected: at least 1 — otherwise the first command read the wrong file.

- [ ] **Step 3: Write the closing report**

German, with: what was implemented, suite numbers, the result of Step 2,
and **explicitly the outstanding visual check** — caret behavior when
typing in the middle, ⌘Z, pasting a multi-line command, focus ring, and
resemblance to the name field next to it. No test in this project
renders `NSViewRepresentable`.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-08-19-snippet-syntax-closeout.md
git commit -m "docs(snippets): record the syntax highlighting close

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
