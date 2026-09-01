# Snippet editor part 1 — syntax display (Design)

As of 2026-08-19. Part 1 of three; the breakdown is in the backlog
(maintainer's wish, 2026-08-19). Purely additive: no model change, no
security relevance.

## Starting point

The command field in the snippet editor is today a single-line `TextField`
over `@State private var command: String`. The list shows the command as
plain `Text`. None of it is colored.

**SwiftUI cannot color a `TextField` while typing.** Color per
region only exists via `AttributedString` in a `Text` — that is, where
you read rather than type — or via an `NSTextView` as an
`NSViewRepresentable`. Maintainer decision 2026-08-19: **in the
input field too**, i.e. `NSTextView`.

## The cut

**A tested tokenizer in Core, an untested presentation in the
App layer.** That is the only cut that yields any test coverage at all:
no test in this project renders an `NSViewRepresentable` (measured
in PV/P0 — controls are invisible in the bitmap).

## Core: the tokenizer

A pure function. Command text in, named regions out — **no
AppKit, no colors**. Which color a kind gets is decided by
the App layer via the existing design tokens.

What is recognized is what actually occurs in a snippet:

| Kind | Example |
|---|---|
| Command (first word) | `docker` |
| Option | `-h`, `--follow` |
| String | `'…'`, `"…"` |
| Variable | `$HOME`, `${TAG}` |
| Comment | `# …` to end of line |
| Operator | `\|`, `&&`, `\|\|`, `;`, `>`, `<` |

Everything else is plain text.

**Language as a parameter, not as a stored field.** The function takes
the language (`tokens(in:language:)`), today with the single case
`.shell`. A *stored* `type` field on `Snippet` is **not**
added: it would have exactly one possible value, and this construction
has already earned itself the accusation, in this project, of being
structurally untestable
(see `LoginMergeCandidate.kind`, whose doc comment admits this).
When a second protocol arrives (Telnet or similar), the field is added
then, and old JSON decodes as `.shell` — the same optional
pattern that `groupID` and `loginSetID` already use here. Waiting loses
nothing.

## App: `NSTextView` in an `NSViewRepresentable`

Four known traps, listed explicitly as tasks instead of being
discovered later:

1. **Cursor preservation.** Re-coloring sets attributes; without a
   safeguard, the insertion point jumps to the end. Save the position
   beforehand, restore it afterward.
2. **Undo.** Attribute changes must not go onto the undo stack, otherwise
   ⌘Z undoes colors instead of text.
3. **Binding loop.** Text change → binding → view update →
   text change. Needs a guard condition, otherwise it recurses.
4. **Appearance.** The field sits next to plain `TextField`s in a
   form that has had four rounds of fine-tuning applied to it (M5f/g/h/k).
   Border, inner spacing, focus ring and font must match its
   neighbors.

## The line-break clamp

`Snippet.init?` rejects **every** line break (deliberately, see P3e) —
and an `NSTextView` accepts Enter by default. The field must therefore
reject Enter until part 2 (multi-line) exists.

This rejection belongs in a small, **tested** function, not
in a delegate branch no test sees. Otherwise part 1 silently builds
input that the model then discards afterward — and the user only sees
that saving doesn't work.

## Tests

**Tokenizer, complete.** One case per recognized kind, plus the traps:

- a string that never closes (`echo "abc`)
- a `#` **inside** a string — not a comment
- a `$` at the end with no name
- a command with no special characters at all — everything text except the
  first word

**Constant-return probe:** a tokenizer that returns "text" across the
board must fail at least one of these tests. The last case is
also the reverse direction — it fails against a tokenizer that
marks everything as a command.

**The line-break rejection** gets its own test.

## What stays unchecked

The presentation itself: cursor behavior, undo, focus ring and the
resemblance to the neighboring fields is seen **only by a visual check with
the maintainer**. No test in this project renders an `NSViewRepresentable`.
That is the price of the decision for a coloring input field and
belongs in the wrap-up report as such.
