# Name conflict on save — design

**Status:** 2026-08-27. Implementation of **I5** from the closing review of
the tab context menu.

---

## The measured starting state

`SessionListViewModel.save(name:…)` looks up an existing session **by
name** and modifies it in place instead of creating a new one. That is
intentional and justified in the source — it carries the group and
login-set binding forward, and the comment even records that a name match
across protocol boundaries **converts** the existing session.

**This upsert is not the problem and is not touched.** Where the user
types the name, it is coherent: whoever enters an existing name means that
session.

The problem is that the name is not always typed. `saveName` is pre-filled
in three places:

| Site | Source | Danger |
|---|---|---|
| Edit session | `stored.name` | none — this **is** that session |
| "Save as session" | `tab.displayTitle` | **yes**, as of today |
| ssh-config import | `host.alias` | **yes, and for longer** |

And there is **nowhere** a name-conflict warning for sessions; the only
model in the project is the duplicate check for snippet variables.

Together this means: two paths insert a name the user never typed, and
nothing tells them this name is already taken. If it hits, the other
session — group, tags, login set, jump spec and keychain secret included
— gets replaced.

## Maintainer decision (2026-08-27)

**Warn, and defuse the automatic name.** Both, not either.

### 1. The form warns

If the entered name matches an existing session, the form says so —
visibly, before saving, naming the session that would be replaced.

**It does not block.** The upsert stays reachable; whoever wants to
update an existing session should still be able to. The warning
establishes visibility, not a hurdle.

**The session being edited is excluded.** `ConnectionViewModel.mode` is
`FormMode.edit(sessionID: UUID)` in the edit case — if the name matches
exactly that ID, that is not a conflict but the normal case. Without this
exception, every edit of a saved session would warn that it replaces
itself; a warning that always appears stops being read after two days.

### 2. A pre-filled name steps aside

If **macSCP itself** inserts a name and that name is taken, the name that
gets set is not that one but the next free one. This applies only to the
two paths that invent a name — "Save as session" and the ssh-config
import.

**What the user types is never changed.** A suggestion may step aside, an
input may not: an app that silently rewrites typed text is worse than one
that overwrites, because afterward you no longer want to watch it type.

The rule must be a testable value in Core, not a one-liner at two call
sites — otherwise the two paths will eventually step aside differently.
Open, to be decided during implementation, with a test per case:

- How the free name is formed (an appended counter is the obvious choice).
- What happens if that one is also taken — i.e. that the rule really
  searches instead of guessing once.
- How to handle a name that already ends in a counter.
- Whether case matters. **This is the question with the trap:** `save`
  compares with `==`, i.e. exactly. If the pre-fill steps aside by
  different rules than `save` compares by, exactly the case arises that
  this change is meant to remove — a name that looks "free" and still
  hits, or conversely, stepping aside without a conflict. **The
  step-aside rule must use the same comparison as `save`.**

## What this is not

- **No change to `save`.** The upsert over the name stays.
- **No blocking.** Saving over an existing name remains possible.
- **No renaming of what exists.** Only the suggestion steps aside.
- **No uniqueness rule in the store.** Two sessions may still carry the
  same name if they got there differently (import, editing) — this
  change only stops that from happening by accident.

## What no test in this project can see

Everything is testable: the step-aside rule is a value in Core, and so is
whether the warning should appear for a given state.

**Not testable** is that the warning actually appears in the running form
and stands there legibly. That remains a maintainer's look.
