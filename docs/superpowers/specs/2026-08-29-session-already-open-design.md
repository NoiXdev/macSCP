# "Session is already open" — Design

**As of:** 2026-08-29. Implementation of **C2** from
`docs/superpowers/specs/2026-08-20-backlog-sessions-tabs-sidebar.md`.

---

## The measured starting state

**Today there is no detection of any kind.** Starting a stored session a
second time silently opens a second tab onto the same session.

Two things are already in the tree for this, and both are the reason
this change is small:

- **`SessionTab.activeStoredSessionID`** — the identifier of the stored
  session a tab is attached to. Set exclusively for a *stored*
  connection, never ad hoc, and cleared again in `teardown`. That is
  exactly the identity C2 needs, and it already exists.
- **`TabsViewModel.sidebarConnectTarget(activeTabIsConnected:makeTab:)`** —
  a pure decision function in Core that already determines today which
  tab a start lands in. It only knows a `Bool` and is therefore
  blind to the question; the seam is there, it just sees too little.

`TabsViewModel.activate(_:)` also exists — jumping is already
expressible.

## Maintainer decisions (2026-08-29)

### 1. "The same" means: the same stored session

A tab with the same `activeStoredSessionID` counts as open.

**An ad-hoc connection to the same target triggers nothing.** That is not
a convenience shortcut, it is correct: a typed connection can carry
different credentials, a different key, or a different jump host.
It looks the same and isn't. Comparing host and port would mean
guessing at an equality the program doesn't know.

### 2. It asks every time

**No "don't ask again", no stored value, no setting.**

A remembered choice can be retrofitted cheaply later, if asking turns
out to be annoying. The reverse isn't true: a stored answer with no
visible way back is a trap, and this project has already paid for that
once (keep-alive: a value that carried "off" and "interval" at the same
time).

## The design

### The decision is a value in Core

Following the model of `SessionNameCollision`: a pure function that says
**which tab** already holds the session — not what to do about it.

`TabsViewModel` is generic over its `Tab`, so it cannot read
`activeStoredSessionID` itself. The App passes the projection
in; the rule stays in Core and thus testable.

The function answers with the **first** tab, in tab order, that
holds the session. Several are possible once someone has chosen "open
anyway" once — at that point tab order is the only rule that doesn't
invent a preference.

### What the surface offers

Two paths, and **only the ones that do something**:

| | Effect |
|---|---|
| **Jump to the existing one** | `activate(_:)` on the tab found |
| **Open a new one anyway** | exactly today's behavior, unchanged |

Cancel is the third outcome and is simply closing the prompt.

**If the active tab itself holds the session**, it still asks.
Jumping is then a no-op — and that is the correct effect of this choice,
not a reason to suppress the question. The alternative ("open one
more") is just as sensible in this case as in any other.

### Where it does not ask

- **When reconnecting in place.** `isReconnecting` concerns the same
  tab; nothing is duplicated there.
- **With an ad-hoc connection**, per decision 1.
- **When no tab holds the session** — then today's behavior stays,
  including the rule that an unconnected active tab is
  reused.

## What no test in this project can see

Testable is everything decidable: which tab counts as holding it, that an
ad-hoc connection does not count, that with several the first wins, and
that both paths trigger the right thing.

**Not testable** remains that the prompt appears in the running window and
sits legibly — as with every surface in this project.

## What is explicitly not included

- **No remembering the answer**, no new setting, no new
  stored value.
- **No change to `sidebarConnectTarget`'s current rule** for the case
  where nothing is duplicated.
- **No ad-hoc equality** over host/port/user.
- No merging of two tabs, no closing one when jumping
  to the other.
