# Snippet editor: collapsing variables, suggesting placeholders — Design

**Status:** 2026-08-30. Implements
`docs/superpowers/specs/2026-08-21-backlog-snippet-editor-bedienung.md`.

---

## Maintainer decisions (2026-08-30)

1. **No remembered collapse state.** Every opening starts the same way.
2. **Full scope for placeholders:** inserting via the variable row, a
   notice for an undeclared `{{NAME}}`, **and** type-ahead completion on
   `{{`.

## The measured starting state

`SnippetCommandEditor` is already an `NSTextView` — a suggestion list on
it is a solved problem; on a SwiftUI `TextField` it would not be one.

`SnippetVariableSubstitution.Problem` lists **six** cases, counted in this
pass: `invalidName`, `unanalyzableContext`, `unusedPlaceholder`,
`placeholderInsideQuotes`, `placeholderNotInArgumentPosition`,
`placeholderIsReparsedByItsCommand`.

**None of them is "used but not declared".** A `{{NAME}}` with no
declaration goes to the shell verbatim. Harmless as text — but the command
does something other than what the user believes, and nothing tells them.
The backlog entry calls this the real win, and it's right: the other two
points are usability, this one fixes a silent bug.

## 1. Collapsing

### No remembered state

Existing variables are **collapsed** on open, a newly added one is **open**
— otherwise nobody types into it.

Nothing is stored. That removes the question of where the state lives,
whether it matches the snippet, what happens to it when a variable is
deleted, and whether it travels with an export. The entry demands anyway
that it never enter the model; not having it at all is the shorter answer.

### What the collapsed row shows

**Name, kind and placement.** Enough to find the right one again without
opening it — and placement belongs in that set, because it decides whether
the variable even belongs in the command as `{{NAME}}`.

### A variable with an error stays open

It cannot be collapsed while it has a problem.

The alternative — collapsible with an error marker — tells you *that*
something is wrong but not *what*, and you open it anyway. And it defeats
the purpose of collapsing at exactly the row that needs attention.

**A useful property follows from this on its own:** "collapse all" leaves
the faulty ones open, and thereby becomes "show me only the problems".

### Bulk actions

"Expand all" and "collapse all", next to "Add Variable". **Show only what
is possible**: if all are already open, "expand all" does not appear.

## 2. Placeholders

### The notice for undeclared placeholders

If the command contains a `{{NAME}}` with no declaration, the editor says
so. **This is not a new `Problem` case**, but a display in the editor:
`SnippetVariableSubstitution` decides whether sending is allowed, and
nothing about that changes — an undeclared placeholder was and remains
sendable, it is simply literal.

The distinction matters: a check that **forbids** sending would be a
behavior change past eight review rounds. A notice in the editor is a
display.

### Inserting via the variable row

A way to place a declared variable into the command without typing its
name. Covers the case where you no longer remember it.

### Completion on `{{`

As soon as `{{` is typed, the declared names are offered.

**Only what belongs in the command as `{{NAME}}` is offered.** A variable
with placement "environment variable" does not belong there — it is
prepended as an assignment instead. Offering it too would produce exactly
the opposite of what its placement says.

**And it is also not offered as `$NAME`.** That is the pitfall from the
backlog entry, measured: for a **single-line** assignment used as a prefix,
the shell expands `$NAME` *before* the assignment takes effect —
`P=new echo "$P"` prints the old value. A completion that inserts `$NAME`
would be silently wrong in a single-line command, and "offer it sometimes,
depending on the line count" would be a rule that changes while typing.

**Anyone who writes `$NAME` by hand sees the consequence in the dry run** —
which has shown the resolved text since yesterday, and this case is
exactly the one it has a fixture for. That is the honest answer: not
prevent, but make visible.

## What no test in this project can see

Everything decidable is testable: what the collapsed row carries, that a
faulty one stays open, which names completion offers and which it does
not, and when the notice for an undeclared `{{NAME}}` appears.

**Not testable** is whether the suggestion list on the `NSTextView` feels
right while typing, and whether the form really fits the sheet after
collapsing. Both are a maintainer's-eye call.

## What is explicitly excluded

- **No stored collapse state**, in any form.
- **No new `Problem` case** and no change to
  `SnippetVariableSubstitution` or `SnippetCommandSurvey`. The notice is a
  display, not a gate.
- **No `$NAME` in the completion.**
- **No change to the sheet width** (460 pt). Room comes from collapsing,
  not from a larger window.
