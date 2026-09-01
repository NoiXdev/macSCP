# Snippet editor part 2 — multiline snippets (design)

**Status:** 2026-08-19, approved. Builds on part 1
(`2026-08-19-snippet-syntax-design.md`, completed and visually verified).

## Starting point

A snippet today is **one** command line. `Snippet.init?` fails as soon as
the command contains a character for which `Character.isNewline` holds —
that is the only reason this initializer can fail at all. Part 1 made this
constraint visible and deliberately left it standing: the input field turns
pasted line breaks into spaces, "until part 2 exists".

The need is small, recurring workflows: a database export, collecting a
log and filing it under a name. Three lines, no script.

## The decisive question was not the editor

It was **what happens on the other side**. The editor is the easy part.

Measured, not assumed: `Terminal.bracketedPasteMode` in SwiftTerm is
`public private(set) var`, and SwiftTerm's own ⌘V path on macOS reads it
(`MacTerminalView`: `if isPaste, terminal.bracketedPasteMode { … }`).
**Bracketed paste is a mode the remote shell switches on, and the local
emulator tracks it** — so the app can read it without asking the other
side. `getTerminal()` is public; the state is reachable from the app
layer, where `TerminalView` lives.

**Maintainer decision:** bracketed when the mode is on, otherwise
line-by-line. This makes macSCP follow the same rule SwiftTerm already
applies for ⌘V, instead of inventing its own.

Rejected were:

- **Always line-by-line.** Consistent everywhere, but a failing line does
  not stop the ones after it, and if a line starts a program that reads
  `stdin` (`python`, `mysql`, `ssh`), the rest ends up inside that program.
- **Always as a heredoc.** One logical command regardless of mode — but it
  runs in a subshell, so `cd`, `export`, `source` no longer affect the
  session, and what runs is no longer verbatim what is written.

## No mode on the snippet

A snippet either **contains** line breaks or it does not; the content
already carries the information. An extra `multiline` flag would be a
state that can contradict the content — flag off, content two lines, which
wins? It is dropped, and with it the store migration and the export/import
adjustment.

Price, deliberately paid: the Return key must write a line break inside
the command field. This means the Return question left open in part 1 is
not observed but **redefined** — it no longer arises.

## Model

`Snippet.init?` loses the line-break rejection. No new field. The store
format stays unchanged: a JSON string carries line breaks, old files read
without migration.

`SnippetCommandInput.sanitized` is dropped **with no replacement** — its
only job was replacing line breaks with spaces. The call in the editor's
`shouldChangeTextIn:` branch disappears with it; a pasted multiline command
is now valid input.

`Snippet.command` stays `let`. The reason for that was never only the
line-break rule, but also tag normalization — see the type's doc comment.

## Sending: a pure function with a result type

New in Core, next to `SnippetKeystrokes`. It returns **not just** bytes,
but a type that can also say "refused" — otherwise a menu item would have
to send bytes that do something other than what it promises:

```swift
public enum SnippetSendPlan: Equatable {
    case send([UInt8])
    /// Insert is not possible without execution when unbracketed.
    case refusedMultilineInsert
}
```

Inputs: the snippet command, `execute: Bool`, `bracketedPaste: Bool`.

| Command | Bracketing | Action | Result |
|---|---|---|---|
| single-line | either | insert | bytes of the command |
| single-line | either | execute | bytes + CR |
| multiline | on | insert | `ESC[200~` + body + `ESC[201~` |
| multiline | on | execute | same + CR |
| multiline | off | execute | line-by-line, CR after **every** line |
| multiline | off | insert | `refusedMultilineInsert` |

**A single-line command is never bracketed**, even when the mode is on.
This keeps today's behavior byte-identical and is worth its own test: the
most common case must not shift as a result of this change.

The app reads `bracketedPasteMode` and passes the `Bool` in. Core never
sees SwiftTerm and stays testable without a terminal.

**`SnippetKeystrokes` stays and keeps its job:** the bytes of a single line
plus its terminator, including the evidence chain written down there for
the CR. The new function **calls it** — unchanged for the single-line
case, per line for the line-by-line fallback. So equality in the most
common case is not a test's claim against a literal, but structural: it is
the same call. The test only records that.

### What has to be measured before it is written

**Which line endings sit between the brackets.** This is the same kind of
question as the CR in part 1, which was measured there instead of guessed.
The plan measures against SwiftTerm's paste path what bytes a multiline
clipboard content actually produces between `ESC[200~` and `ESC[201~`, and
records the evidence chain as a doc comment at the seam — the way
`SnippetKeystrokes.terminator` carries it today for the CR.

Until that measurement exists, this spec makes **no** byte claim about the
body.

## Rejection at the surface

`refusedMultilineInsert` is not swallowed. The triggering spot shows a
hint: that the other side does not offer multiline insert without
execution, with the offer to execute instead. Text localized in all four
catalogues (`en`, `de`, `fr`, `pl`) — the guard test keeps the key sets
equal.

## Editor

Everything part 1 built and the maintainer verified stays: no wrapping,
horizontal scrolling, highlighting, disabled automatic substitutions, Tab
moves on.

What changes:

- **Return writes a line break.** The `insertNewline(_:)` claim in
  `doCommandBy:` is dropped; the corresponding guard test is flipped
  rather than deleted — it now asserts that Return is **not** claimed.
- **Save becomes ⌘Return**, and only in the snippet editor. The file's
  other `.defaultAction` spots stay untouched; which ones those are, the
  plan counts at the same moment it touches them.
- **The field grows with it** — one line tall for a single-line command,
  then more per line up to a cap, after which a vertical scroller takes
  over. The cap is an estimate and belongs in the visual check.
- The accessibility label stays as it is (M6a invariant).

## List

The snippet list shows the command as text. For several lines it shows the
**first line**; that more follow must be recognizable. The exact form
(marker, line count) is a decision for the implementation against the
existing code — it should follow the list's rhythm, not break it.

## Log: nothing to do, but now under strain

`SnippetAuditDetail` already folds whitespace down to plain spaces today,
and in Swift **every** character with `isNewline` is also `isWhitespace` —
so a multiline command already goes into the log as a single line on its
own. This is not a change.

But it is from now on a **strained** rule: it was written when multiline
commands could not exist. It therefore gets its own test.

## Tests

**The send function, complete** — every row of the table above, plus the
rejection.

**Constant-return probe:** an implementation that always returns the same
bytes must fail at least two of these cases. One that always brackets
fails the single-line case.

**The single-line case is byte-identical** — checked against today's
`SnippetKeystrokes.bytes(for:execute:)`, not against a freshly written
literal.

**The model accepts line breaks:** `Snippet(name:command:)` with `"a\nb"`
is no longer `nil`, and a `"\r\n"` in the command survives the round trip
through the store. The CRLF case earns its own test for the same reason
part 1 had one: `"\r\n"` is **one** grapheme cluster.

**The log stays single-line** for a multiline command.

**Guards in the app layer**, following the pattern of
`SnippetCommandEditorGuardTests`: Return is no longer claimed, Tab still
is, and the save shortcut is ⌘Return.

## What stays unverified

The presentation: the field growing with content, ⌘Return, and how a
bracketed insert feels in the running terminal. No test in this project
draws `NSViewRepresentable`, and none talks to a real shell in
bracketed-paste mode. **Visual check by the maintainer**, and that belongs
in the closing report as such.

Part 1 already delivered the evidence for this class of issue: the closing
review correctly found the line-break bug, and the fix replaced it with
two new ones that also looked plausible and were found only by looking at
the running app.

## Not in this part

- **Heredoc.** Bracketing solves the case better — without rewriting the
  command and without a subshell.
- **Variables with a prompt** and a `shell`/`telnet` marker: part 3, see
  `2026-08-19-backlog-snippet-teil-3.md`.
