# Snippet editor part 3 — declared variables (design)

**Status:** 2026-08-19, approved. Builds on part 1 (highlighting) and part 2
(multiline), both completed and visually verified. Supersedes the backlog
entry `2026-08-19-backlog-snippet-part-3.md`, which was deliberately carried
as a secured idea and not as a design.

## Starting point

A snippet today is a fixed command text. Recurring workflows — a database
export, collecting a log — often differ between two runs in exactly one
value.

The core of the request, in the maintainer's words: **the user should not
have to hunt for the variables in the text.** The alternative — scanning the
command for placeholders and building a form from that — makes the command
text the source of truth for something the user never sees laid out
together. A declaration is visible, sortable, and can carry a comment.

## Decisions

Five, all from the maintainer:

1. **Both substitution paths, selectable per variable** — a placeholder in
   the text, or a prepended environment assignment.
2. **No "advanced" flag** — an empty declaration list already says "no
   variables".
3. **The log gets the template, not the values.**
4. **Two kinds:** free text and selection from a list, each with an
   optional default value.
5. **Remembering is a checkbox on the declaration, off by default.**

### On (1): a deliberate departure from the recommendation

I had advised **one** path, arguing that two mechanisms mean two failure
modes and two test matrices. The maintainer chose both; that is noted, not
argued away.

The countermeasure is in the design: there is **one** declaration with a
`placement` field and **one** substitution function that serves both cases.
The test matrix runs over placement instead of doubling. Where the behavior
actually differs — and it does — it lives in one place.

### On (5): why the checkbox became necessary

The original choice was a third variable **kind**, "last used value". That
collided with decision (3): the log gets no values, so that an accidentally
typed password does not end up in a file — and a remembered value would sit
in the same JSON store, just a different file.

After that was pointed out, the decision fell on an **opt-in on the
declaration**, off by default. That way the choice is made before a value
exists, and it has the same shape as (3): safe as the default, convenience
as a deliberate choice.

Along the way this collapsed the third kind into a property. What remains
is two kinds and two independent properties (default value, remembering) —
less machinery than the question suggested.

## Model

`Snippet` gets `variables: [SnippetVariable]` with a default of `[]`; old
stores read without migration, because a missing key decodes as an empty
list (the same pattern used to introduce `tags`).

A declaration carries:

| Field | Meaning |
|---|---|
| `name` | the identifier, e.g. `DBNAME` |
| `prompt` | label in the prompt sheet |
| `kind` | `.freeText` or `.selection([String])` |
| `placement` | `.placeholder` or `.environment` |
| `defaultValue` | preset, may be empty |
| `remembersLastValue` | checkbox, default `false` |

**Naming rule, the same for both placements:** `[A-Za-z_][A-Za-z0-9_]*`.
For the environment placement this is mandatory, because it becomes a shell
assignment; for the placeholder it is not strictly necessary, but two rules
for the same field would be a source of errors with no benefit. Names are
unique within a snippet.

### Remembered values do not live in the snippet

They go into a separate, small JSON store next to `snippets.json`,
addressed by snippet ID and variable name — **in plain text, not
encrypted**, like every other non-secret store in this project. Precisely
for that reason, remembering is a deliberate opt-in and not a default. Two
reasons for the separate store, both mandatory:

- A snippet that changes itself when run is no longer a template record —
  every run would be a store write on the snippet.
- **Export must not carry the values along.** If the last value lived in
  the snippet, it would travel into every exported file and every share.

Declarations travel with export, remembered values never do.

**Orphaned entries.** If a snippet is deleted, its remembered values would
otherwise be left behind. Deletion clears them too — the same coupling that
deleting a session has with its keychain entry. An entry for a snippet ID
that no longer exists is discarded on load.

## Substitution

A pure function in Core: template plus values in, resolved command out —
or a rejection.

### Placeholder

`{{DBNAME}}` in the command is replaced by the value, quoted via the
existing `SSHCommandBuilder.posixSingleQuote` primitive (single quotes,
embedded `'` as `'\''`). The primitive already exists, is already tested
with a value containing an embedded quote, and is exposed for this use
rather than rebuilt.

**Only declared names are replaced.** This is not merely an economy rule,
but the resolution of a real collision:

```
kubectl get pods -o go-template='{{range .items}}{{.metadata.name}}{{end}}'
```

Double curly braces occur in real commands. `range .items` is not a
declared variable and stays literal. It therefore needs neither its own
dialect nor an escaping rule.

### Environment

`$DBNAME` in the command, and macSCP prepends the assignment:

- **single-line:** `DBNAME='kunden db' mysqldump …` — the assignment applies
  only to this one command.
- **multiline:** `DBNAME='kunden db'` as its own first line, followed by the
  body.

The second form has a **real side effect**: the variable stays set in the
session after the run. That belongs visibly in the editor's hint text, not
in a footnote — anyone choosing `$PATH` as a variable name should know what
happens beforehand.

Multiple assignments appear in declaration order.

## Two rejections, at save time

Both are pure, testable checks, and both fire in the editor, not at
execution time — a surprise on a remote host is more expensive than one in
your own form.

1. **A placeholder declaration with no use.** A variable with
   `placement == .placeholder` whose `{{NAME}}` does not occur in the
   command would be prompted for and arrive nowhere.

   **Placeholder only.** This check must not exist for the environment
   placement: there, the most common and intended case is precisely that
   `$NAME` does **not** appear in the command — `DBNAME='x' ./backup.sh`
   sets the variable for a script that reads it itself. A check for `$NAME`
   would reject exactly the natural use. (In this spec's own self-review,
   the check initially covered both placements; that was wrong.)
2. **A placeholder inside quotes.** `echo "{{DBNAME}}"` would produce
   `echo "'wert'"` — the quotes would show. Detecting whether a position
   sits inside single or double quotes is the same state machine that
   `SnippetHighlighter` from part 1 already runs to color strings. Whether
   the code is shared or only the rule is shared is a decision for the
   implementation against the existing code.

## The log does not change

`SnippetAuditDetail.text(for:)` reads `snippet.command` — and that **is**
the template. Decision (3) therefore costs no line of code; it describes
the state that results when nobody does anything against it.

Precisely for that reason it gets a **test**: a rule that is free will be
broken for free on the next refactor. The test asserts that a variable's
value does not occur in the log text.

## Flow on firing

Firing → if the snippet has declarations, a prompt sheet appears with one
field per variable, preset from a remembered value, otherwise from the
default value → **cancel sends nothing** → confirm resolves it, remembers
the checked values, and from there the path from part 2 continues
unchanged: the resolved command goes into `SnippetSendPlanner`, which
decides on bracketed-paste mode.

A snippet without declarations takes today's path, with no sheet.

## Tests

**Substitution, complete:** both placements, each single-line and
multiline; values with a space, a single quote, `$`, a backslash, and a
string that itself looks like a placeholder.

**Non-substitution:** a `{{…}}` that matches no declaration stays
untouched — with the `go-template` command above as the test case,
verbatim.

**Both rejections**, each with one case that triggers it and one that does
not.

**The naming rule**, with a name that would be invalid as a shell
assignment.

**The log**, see above.

**Constant-return probe:** a substitution function that returns the command
unchanged must fail at least half of these cases; one that substitutes
every value unquoted must fail on the values with special characters.

## What stays unverified

The prompt sheet itself and the variables section in the editor: no test in
this project draws SwiftUI views. **Visual check by the maintainer**, and
that belongs in the closing report as such — parts 1 and 2 both showed that
at this layer neither the green suite nor the review is enough.

## Not in this part

- **A `type` marker on the snippet** (`shell`, prospectively `telnet`). The
  tokenizer from part 1 already takes the language as a parameter and
  deliberately does not store it; this marker would be where it would come
  from. But there is not yet a second session kind for it to decide
  anything about.
- **Variables in a snippet's name or tags.** Only the command.
- **Chained variables** (a variable whose default value substitutes
  another). Neither requested nor needed.
