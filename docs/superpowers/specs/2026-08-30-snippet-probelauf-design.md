# Snippet dry run and the per-snippet opt-out — design

**As of:** 2026-08-30. Implementation of
`docs/superpowers/specs/2026-08-20-backlog-snippet-probelauf.md`.

---

## Maintainer decisions (2026-08-30)

1. **Both**: the dry run *and* the flag on the individual snippet.
2. **Two entry points**: the path when triggering a rejection, **and** a
   "Test" button in the editor.

The third answer follows from the purpose without needing to be asked:
**remembered values are displayed.** The dry run shows what would actually
be sent; if it showed something other than the substituted value, it would
be dishonest in exactly the role it is built for.

## The measured starting state

| | |
|---|---|
| `SnippetSendPlan` | `.send([UInt8])` / `.refusedMultilineInsert` |
| Placeholder rejection | a second, separate mechanism (`SnippetCommandSurvey`) |
| `SnippetHighlighter` | present, structurally cut off from the check |
| `SnippetVariable.remembersLastValue` | present, with `SnippetVariableMemoryStore` |
| **`SnippetExportPayload`** | carries **`[Snippet]`** — the same type as the store |

**The last row is the finding that determines this design.** For sessions,
`ExportedGroup` and `ExportedSession` are their own types; for snippets, the
executed type is the stored one. A new field on `Snippet` therefore
travels **on its own** through export and import.

## The boundary, without which B does the opposite

The entry phrases the requirement as a rule:

> **An imported snippet always arrives with checking switched on.**

As a cleanup rule in the import planner, that would be one line that
someone forgets on the next rework — and forgetting it would be invisible,
because a snippet with checking switched off looks exactly like one
without the field at all.

**That is why the export gets its own type**, modeled on sessions:
`ExportedSnippet` carries the fields that belong shared, and the flag is
**not one of them**. An import then cannot set it — not because a test
forbids it, but because the file cannot express it.

That is the same capability boundary that closed the dial process and the
unbounded SFTP close this week, and for the same reason: a rule the
compiler carries does not go stale in silence.

## The dry run

### What it shows

- The **resolved command**, as it goes onto the wire — not the template.
- The result of the **send plan**: single-line, inserted bracketed,
  executed line by line, or rejected. For a multiline snippet without a
  bracketing mode, this decides something different from the wording.
- **Syntax highlighting** via `SnippetHighlighter`. An injected `$(…)`
  stands out immediately, colored.
- On a rejection: **the reason**, and below it "send anyway".

### What it is

A **checkable value** in Core that describes the display from snippet,
values and send plan — not a view that assembles it itself. Both entry
points thereby show the same thing, instead of two similar ones.

### The requirement it must not violate

The substituted value appears on the screen of whoever typed it — that is
fine. **It must not travel from there into the audit log, into an export,
or into an error message.** The audit log carries the template, and that
stays so.

This is not a style question: it is the same commitment this project holds
for secrets, applied to a value that may be a secret.

### The case it is meant to make visible

From the entry, measured against `bash`: for a **single-line** prefix
assignment, the shell expands `$P` **before** the assignment takes effect.

```
P=neu echo "$P"     →  alt
```

Anyone who, as a workaround for a rejected `[ -f {{PATH}} ]`, writes
`P='…' [ -f "$P" ]` silently gets the old value or none at all. The dry
run shows the resolved text, and whoever reads it sees it — today you only
notice it from the wrong result on the other end.

## The flag on the snippet

A field on `Snippet` that turns off the placeholder position check for
**this** snippet. It only takes effect where someone deliberately set it.

- **It does not travel.** See above — `ExportedSnippet` does not know it.
- **It is visible** wherever the snippet is edited, and names what it
  turns off. "Checking off" with no object would be a switch whose effect
  you only learn from the damage.
- **It turns off only the placeholder position check, nothing else.** The
  send plan and its rejection of a multiline insert stay untouched — that
  is a different question, and not one anyone should answer per snippet.

## The "Test" button in the editor

Shows the same dry run, without sending.

**It needs values for the placeholders**, and thus a second place where
placeholder values arise. The design fixes it: it uses **the same prompt**
as triggering does, with the same remembered values. A second prompt form
would be a second truth about what a value is.

**Nothing is sent and nothing is remembered** that the dry run in the
editor asks for: a trial run must not preload the next real run.

## What no test in this project can see

Everything decidable is checkable: what the display describes, that both
entry points describe the same thing, that the flag turns off only the
position check, that an imported snippet never carries it, and that the
substituted value appears in no log and no error message.

**Not checkable** is whether the highlighting actually makes an injected
construction stand out to a human. That is the purpose of the display, and
the only part only a look can judge.

## What is expressly not included

- **No global switch** in settings.
- **No change to `SnippetCommandSurvey`** itself — the allowlist stays as
  eight review rounds left it.
- **No change to `SnippetSendPlan`'s** rejection of a multiline insert.
- **No remembering of values from the editor dry run.**
