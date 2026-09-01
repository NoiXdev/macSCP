# Backlog: snippet editor — collapse variables, suggest placeholders

**Filed:** 2026-08-21, from a maintainer visual check on the built bundle.
Secured ideas, **not a design**. Two layout bugs from the same review pass
are already fixed and stand here only as context.

## Already fixed (not backlog)

- The variables block wasn't a `FormRow` and so sat at the left edge, while
  name, command and tags start indented 120 pt. Now a row like the others.
- Both help texts lacked `fixedSize` and got clipped to one line at the
  460 pt sheet width.

## 1. Variables collapsible and expandable

Every variable should be individually collapsible, and next to
"Add Variable" there need to be **bulk actions**: expand all, collapse all.

Why this is pressing: a variable row today carries name, kind, prompt,
placement, default value and the remember flag — with three variables the
form is already longer than the sheet. The editor is fixed at 460 pt wide,
so room can only grow downward.

To decide before the design:

- **What does the collapsed row show?** A sensible candidate: name, kind
  and placement — enough to find the right one again without opening it.
- **What is the starting state?** A newly added variable must be open,
  otherwise nobody types into it. Existing ones presumably collapsed when
  the editor opens — that needs checking, not assuming.
- **Is the state remembered?** If so, it belongs in the view, not the
  model — a collapse state has no business in `snippets.json`, and it must
  especially not travel with an export.
- A variable with an **error** (invalid name, duplicate name) must either
  expand itself automatically or be recognizable as faulty while
  collapsed. Otherwise collapsing hides exactly the row that needs
  attention.

## 2. Suggest placeholders in the command field

Wanted: the editor recognizes the declared variables while typing and
suggests them — or offers a way to insert them.

**The building block already exists.** `SnippetCommandEditor` is already
an `NSTextView` (from part 1, because a SwiftUI `TextField` cannot color
while typing). A suggestion list on an `NSTextView` is a solved problem;
on a `TextField` it would not have been.

The natural trigger is the opening brace: as soon as `{{` is typed, offer
the declared names. That's cheap because the list sits directly above, in
the same form.

To clarify before the design:

- **Suggest, insert, or both?** A menu on the variable row's "+" button
  ("insert into command") is significantly less work than type-ahead
  completion and covers the case where you no longer remember the name.
  Both together is the convenience case.
- **What happens with a variable whose placement is "environment
  variable"?** That one specifically does **not** belong in the command as
  `{{NAME}}` — it's prepended as an assignment. A completion that offers
  it too produces exactly the opposite. Either don't offer it, or offer it
  as `$NAME` (see the pitfall below).
- **The reverse path would be more valuable than the convenience:** a
  `{{NAME}}` in the command that is *not* declared is silent today — it
  stays as a literal. A notice for that would be the real win.

### The pitfall this surfaces

For a single-line assignment used as a prefix, the shell expands `$NAME`
**before** the assignment takes effect — measured: `P=neu echo "$P"`
prints the old value. So anyone who inserts an environment variable as
`$NAME` into a single-line command via completion silently gets the wrong
thing. See `2026-08-20-backlog-snippet-dry-run.md`, section B2.

## Order

1 first — it's the reported space problem and depends on nothing. 2
afterward, and there **the insert path first**, via the variable menu: it
resolves most of the need without building completion and its edge cases.

---

## Done 2026-08-30 (`bbd25c8`, `60dcea9`)

Designed in `2026-08-30-snippet-editor-interaction-design.md`.

**Point 1:** collapsing variables, with no remembered state — existing
ones collapsed, a new one open. The collapsed row carries name, kind and
placement. A variable **with a problem cannot be collapsed**, which
turns "collapse all" into "show me only the problems" on its own.

**Point 2:** inserting via the variable row, completion on `{{`, and the
notice for an undeclared `{{NAME}}` — the point this entry named as the
real win. The notice is a **display**, not a `Problem` case: sending is
still allowed as before.

Environment variables are offered by **neither** access path, not even as
`$NAME`. Both ask the same function, so the exclusion is structural.

## What was left open here — a design question, not a bug

**`{{DB}}` for a variable with placement "environment variable" is still
silent.** `resolve` only substitutes `.placeholder`; the text stays
literal, **exactly as for an undeclared one**. The new notice deliberately
does not flag it, because "not declared as a variable" would be wrong for
a declared name.

It is **one click in the placement menu** away from the case the notice
fixes — and the effect is the same. What's missing is a second sentence
for this case ("declared, but as an environment variable — nothing gets
substituted here"). That needs designing, not renaming.

Two further named limits: the insert path on the row currently appends at
the end (SwiftUI doesn't hand a `View` a cursor position; completion is
the access path that inserts at the point), and a `{{foo}}` from a foreign
templating language gets flagged along with the rest — it blocks nothing,
and what it says is correct.
