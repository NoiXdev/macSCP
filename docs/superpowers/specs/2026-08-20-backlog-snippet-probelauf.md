# Backlog: snippet dry run and the escape hatch from the check

**Filed:** 2026-08-20, from a maintainer note. Secured ideas, **not a
design**. Two wishes that belong together — and in my view should become
**one** thing.

## Starting point

After eight review rounds the gate is an allowlist: a `{{PLACEHOLDER}}` is
only resolved when `SnippetCommandSurvey` positively recognizes its spot as
the topmost, unquoted argument and the command name isn't among the ones
where a shell re-reads the value as code. The stance is the union across
bash 3.2/4.4/5.x and zsh — **if any plausible shell picks the value back
up, it's rejected.**

Price knowingly accepted (maintainer, 2026-08-20):

```
[ -f {{PATH}} ]          abgelehnt
printf '%s' {{X}}        abgelehnt
export FOO={{VALUE}}     abgelehnt
```

These are ordinary forms. It's foreseeable that someone will miss them —
hence the two wishes below.

## A. Dry run: show what would actually be sent

Show, before sending, what the finished command looks like. That is more
than convenience: it makes an injected construction **visible**, instead of
turning it into a matter of trust.

What the display must cover to tell the truth:

- The **resolved command** with the values substituted, exactly as it goes
  on the wire — not the template.
- The result of the **send plan** (`SnippetSendPlan`), not just the text:
  single-line, inserted bracketed, executed line-by-line, or rejected. For
  a multi-line snippet with no bracketing mode, that decides something
  entirely different from the wording.
- **Syntax highlighting.** `SnippetHighlighter` already exists and is
  structurally cut off from the check — display is exactly its job. An
  injected `$(…)` stands out immediately once colored.

**Requirement:** the substituted value appears on the screen of the person
who typed it — that's fine. From there it must **not** travel into the
audit log, into an export, or into an error message. The audit log carries
the template, and that stays the case.

## B. Per-snippet opt-out (maintainer clarification, 2026-08-20)

Not a toggle in settings, but a **flag on the individual snippet**. That is
the clearly better form: it takes effect only where someone has
deliberately set it, instead of applying to everything imported afterward
too.

**One requirement, without which it does the opposite:** the flag is data
and therefore travels through export and import. `SnippetImportPlanner` has
carried the declarations along since this round — if it also carried this
flag, a shared snippet could arrive **with the check already turned off**.
That is exactly the supply-chain shape this whole branch is built against.

> **An imported snippet always arrives with the check turned on.** The flag
> is discarded on import, not carried over; anyone who wants it sets it
> themselves — after reading the command.

## B2. The other path: pass values as environment

Instead of `{{PLACEHOLDER}}`, use the `.environment` placement. The value
then travels along as an assignment and is never substituted into the
command text — the position check doesn't even come into play.

**This carries, but not everywhere.** Measured against `bash`:

| Form | Result |
|---|---|
| `P=neu ./skript.sh` — program reads it itself | script sees `neu` |
| multi-line, assignment as its own line | `[neu]` |
| `P=neu echo "$P"` — command text names `$P` | **`alt`** resp. empty |

The third line is the trap: for a **single-line** assignment used as a
prefix, the shell expands `$P` **before** the assignment takes effect.
Anyone who writes `P='…' [ -f "$P" ]` as a workaround for a rejected
`[ -f {{PATH}} ]` silently gets the old value or none at all.

The code already makes the distinction correctly: for a multi-line body the
assignment becomes its **own line** (otherwise it would only apply to the
first one), and there it takes effect as expected. The prefix case remains.

**Consequence for the dry run:** that is exactly a case it should make
visible. The resolved text shows `P=neu echo "$P"`, and anyone reading it
sees the problem — today you only notice it from the wrong result on the
remote side.

## The proposal: A **is** the escape hatch, not B

A supplies the evidence B presupposes. Instead of a toggle that removes the
check permanently:

> If a snippet is rejected, the dry run shows the command **as it would be
> resolved**, colored, with the reason for the rejection — and below it,
> "send anyway".

That's the same freedom, but **per trigger instead of permanent**, and with
the actual text in front of you instead of on trust. Anyone who needs
`[ -f {{PATH}} ]` gets it; anyone triggering an imported snippet sees the
`$(…)` before it runs.

To decide once this moves to a design:

1. Is that enough, or should the permanent toggle exist **in addition**?
2. Is the dry run its own button in the snippet editor ("Test"), the path
   taken on trigger, or both?
3. What happens with multiple placeholders and `remembersLastValue` — does
   the dry run show remembered values, or does it demand fresh input?

## Order

A first and alone. Once A stands, B can be answered honestly — then it's
known whether the toggle is still missing or whether the rejection with no
way out was the whole problem.
