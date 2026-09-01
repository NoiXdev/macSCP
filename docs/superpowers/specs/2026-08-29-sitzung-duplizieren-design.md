# Duplicating a session — design

**Status:** 2026-08-29. Implementation of **item 1** from
`docs/superpowers/specs/2026-08-20-backlog-verwaltungs-sheets.md`.

---

## What the data model already answers

The entry raises three questions. The tree answers two of them, if you look.

**A session's secret lives in SecretStore under the session's `id`
itself** — the slot *is* the identifier. A copy with a fresh `id` therefore
has no secret; "point at the same entry" is not even expressible without
actively **copying** it.

**And the naming rule already exists:**
`SessionNameCollision.freeName(basedOn:avoiding:)`, built for the
pre-filled names and verified — it uses the same comparison as
`SessionListViewModel.save`, which was the pitfall here. A second naming
arithmetic beside it is therefore neither needed nor allowed.

## Maintainer decision (2026-08-29)

**Copy nothing, carry references along.**

The copy inherits everything that is a **reference** — group, tags,
login-set binding, jump spec — and nothing that is a **secret**.

That yields an asymmetry which is not a drawback but the rule at work:
**a session on a login set works immediately**, because its credential
hangs off the set anyway, not off it. A session with its own password asks
once on first connect.

The reason is the one promise this project keeps in one place: secret
material lives only where the user put it. Multiplying a password without
the user's involvement creates a second keychain entry the user would need
to know about when changing or revoking it — and that is exactly what one
never knows about the second one.

## The design

### Duplication is a pure value

What the copy carries and what it does not depends only on the template
and the existing names. That belongs in Core as a testable function —
following the model of `SessionNameCollision` and `SidebarOrdering` —, not
in a menu action.

The value decides; the sidebar calls it and saves the result.

### What is carried over and what is not

| | |
|---|---|
| **Carried over** | Protocol type and all connection fields, group, tags, login-set binding, jump spec |
| **Fresh** | `id`, and with it an empty secret slot |
| **Not carried over** | every secret, in every slot |
| **Name** | `freeName(basedOn:avoiding:)` over the template's name |

**The jump spec is the case that needs attention.** It carries its own
`secretID` — a *different* slot than the session's. A raw carried-over
`secretID` would leave the copy pointing at the template's secret, and
then the decision above would be circumvented at exactly the point where
nobody is looking. **The copy gets a fresh `secretID`.**

If the jump instead carries a `loginSetID` or a `sessionID`, those are
references and travel along.

### Where the entry sits

In the sidebar's context menu, next to Rename and Delete. The copy lands
in the same group as the template and is selected, so what was created is
visible.

**Only show what is possible** — the standing rule; nothing is greyed
out.

## What no test in this project can see

Everything decidable is testable: that references travel and secrets do
not, that the session slot **and** jump slot are fresh, that the name
follows the existing rule, and that a login-set session is complete after
duplication while one with its own password is not.

**Not testable** remains that the user sees the copy in the running
sidebar at the expected spot.

## What explicitly does not belong here

- **No copying of any secret**, not even on request.
- **No second naming rule.** `freeName(basedOn:avoiding:)` or none at all.
- **No change to `SessionListViewModel.save`** and its upsert over the
  name.
- **No multi-duplicating of a selection** — one entry, one session.
