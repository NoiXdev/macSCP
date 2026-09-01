# Backlog: snippet editor part 3 — declared variables

**Created:** 2026-08-19. **Not a design, a solid idea.**

This sharpening came out of the conversation while scoping part 1 and
afterward lived in no file — it existed only in the transcript. It
surfaced while cleaning up the throwaway artifacts. It's written down
here so it survives a brainstorming pass, not so it replaces one.

## The maintainer's idea

A snippet gets a marker — called "extended snippet" in the conversation
— and only with it does an area appear where **variables get declared**:
name, type (free text, choice from a list), presumably a default value.
When triggered, macSCP asks for the values and passes them to the
command.

The core of the argument, and it's a good one: **this way nobody has to
hunt for the variables in the text.** The alternative — scanning the
command text for `{{name}}` or `$1` and building a form from that —
makes the command the source of truth for something the user never sees
laid out anywhere. A declaration is visible, sortable, commentable.

Examples from the conversation: a database export, collecting a log and
filing it under a name — that is, recurring workflows where exactly one
or two values change between two invocations.

Also considered: a **type marker on the snippet** (`shell`, eventually
`telnet` or similar), in case macSCP ever gets other session kinds. The
tokenizer from part 1 already takes the language as a parameter and
explicitly does **not** store it — this marker would be where it comes
from.

## What needs clarifying before a design

- **How the values get into the command.** Text substitution in the
  command, or as `NAME=value` environment assignments prepended? The
  first is obvious and prone to quoting errors; the second is robust,
  but only works for values that actually work as environment.
- **Quoting.** A value with a space, quotation marks, or `$` must not be
  able to reshape the command. That's the security-adjacent core of the
  whole undertaking and belongs in a tested spot in Core, not in the
  view.
- **Does it even need the marker?** The same question as in part 2,
  where it cost the toggle: an empty declaration list is already the
  statement "no variables". A flag next to it can contradict it. The
  difference from part 2: here the flag would at the same time be the
  switch that shows the area in the UI at all — that might be worth its
  price. Open, not decided.
- **Store format.** Unlike part 2, this part can't avoid a migration.
  The snippet JSON gets a structure, and export/import (the `macscp`
  envelope) have to follow along.
- **Never credentials.** The snippet store is plain JSON. A "password"
  variable type that stores the value is out; a type that asks on every
  invocation and doesn't retain the value would be conceivable — and
  would then also have to be kept out of the log, which today records
  the executed command.

## Ordering

After part 2. Part 2 makes multi-line bodies possible, and only then do
variables really pay off — a one-line command with three prompts is
rare.
