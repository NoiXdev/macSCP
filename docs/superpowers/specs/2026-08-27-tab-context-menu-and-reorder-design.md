# Tab context menu and reordering — design

**As of:** 2026-08-27. Basis:
`docs/superpowers/specs/2026-08-20-backlog-sessions-tabs-sidebar.md`,
items B1 (context menu), B2 (reordering) and B3 (where the entries come
from).

The backlog requires building B1 and B2 **together**: "move left / move
right" and dragging are the same underlying capability, just two input
methods. Built separately, the reordering logic would exist twice.

---

## The measured starting state

| | |
|---|---|
| `TabStripView.swift` | no `contextMenu`, no `onMove`, no `draggable` — both are new |
| Tabs across a restart | **are not restored**; there is no such path today |
| `TabsViewModel` | holds `tabs`, `activate`, `closeTab`, `addTab` — generic over `Tab`, in Core |
| `TabCloseWarning` | checks each tab for running **and** incoming transfers, produces a text |
| `teardown(_ tab:reason:)` | the one teardown path: cancel the queue → shut down the terminal → disconnect |
| `ProtocolCapabilities` | carries `supportsShell`: `true` for SSH, `false` for S3 and WebDAV |
| `BrowserContextMenu.entries(…)` | precedent: the menu as a pure value in Core, with its own test file |
| "Save & connect" | exists only **in the form before connecting**; a running ad-hoc connection cannot be saved after the fact today |

---

## 1. Where the entries come from

B3 settles two things. The first stays: **no `switch` over
`ConnectionKind`.** On the second — "instead, contributions like
`fileActions`" — this design deviates, and does so on measured grounds.

| Origin | Entries | Mechanism |
|---|---|---|
| The tab itself | Close, Close others, Move left, Move right | position and count |
| The tab's **state** | Save as session… | ad hoc **and** connected |
| The **protocol** | Open terminal | `capabilities.supportsShell` |

**Why not contributions.** `FileActionContribution` today has exactly one
user — S3's "share link". Its behavior hangs off an
`if action.id == "s3.presignedURL"` at the call site; the comment there
says a second contribution would need "just one more `if`". For the tab
menu that would mean: a mechanism with zero users plus a string branch, to
show a single action whose condition already exists as a capability flag.

The dividing line from B3 itself — *"not which menu, but what the entry
depends on"* — leads here to the capability check. A contribution becomes
right the moment a backend has an action that **no other backend knows and
that no flag describes**. At that point the pattern is ready and gets
copied.

## 2. The menu as a testable value

Following the precedent of `BrowserContextMenu`: a function in Core that
turns facts into a list. The view only draws what comes out, and makes no
decision of its own.

Facts that go in: the tab's position, the number of tabs, `supportsShell`,
whether the connection is ad hoc, whether it is up.

Visibility rules, each individually testable:

- **Move left** is absent on the first tab, **Move right** on the last. No
  greyed-out entry, no error — the entry simply does not appear there.
- **Close others** is absent when there are no others.
- **Open terminal** appears for SSH, is absent for S3 and WebDAV.
- **Save as session…** only when ad hoc **and** connected. On a saved
  session the entry makes no sense, nor does it on a failed connection.

**Explicitly not included:** *Rename* (a separate tab title would be new
state that would have to live somewhere) and *Close to the right* (fewer
entries is better here). Both are maintainer decisions from 2026-08-27.

## 3. Reordering

**One function on `TabsViewModel`**, right where `addTab`, `activate` and
`closeTab` already live — in Core, testable without a view. Both input
methods call it: the menu with ±1, dragging with the target position.

Three invariants:

1. **The active tab stays active.** Its position changes, its identity
   does not — even when another tab is pushed past it. `activeTab` hangs
   off an ID, which carries this.
2. **No connection is touched.** Reordering is purely a display order;
   session, queue and terminal stay untouched.
3. **The edges do nothing.** A move past the edge is not an error and not
   an exception — it simply leaves the order as it was.

**Not included:** dragging a tab out of the strip into a new window.
Multi-window is v2 per the architecture invariants, and connection state
hangs off the window scope. A drag into empty space leaves the tab where
it was.

Because tabs do not survive a restart, the order is pure session state: no
storage, no migration, no `SettingsStore` question.

## 4. Closing

**One path, not two.** "Close others" calls `teardown(_ tab:reason:)` per
tab. Building a second teardown path would undercut the architecture's
ordering invariant (queue → terminal → connection).

**"Others" means: everyone except the clicked tab** — not everyone except
the active one. The menu hangs off a specific row, and the user means the
one they clicked. If the clicked tab is not the active one, closing makes
it the active one, because otherwise there would be no tab left that could
be.

**One combined warning, not N.** `TabCloseWarning` today checks one tab;
for the bulk close a version is added that summarizes across several tabs
and names how many of the affected ones are currently transferring. Ask
once, decide once.

**Declining cancels everything**, not just the transferring tabs. One
question, one answer: whoever picks "Cancel" does not want half of them
closing anyway. Partially closing the quiet tabs would be a third behavior
nobody asked for.

## 5. Save as session

The entry with the actual new value: today there is no way to save a
running ad-hoc connection after the fact.

**It opens the existing save path, pre-filled** with the running
connection's values, instead of building a second save path. The user sees
the name and fields before saving and can set the name; whether the secret
comes along is answered by the form as always.

The source of the values is `values` in `ConnectionViewModel` — the
generic map, explicitly documented in the source as the single source of
truth, which the connect and save paths also read from. **Not**
`lastConnectedConfig`: that is an `SSHConnectionConfig?` and does not carry
S3 and WebDAV.

## 6. What no test in this project can see

Everything decidable is testable: which entries appear, what reordering
does to the order and the active tab, what the combined warning says, and
that the view is wired to the right functions.

**Not testable** is that SwiftUI triggers the drag and inserts the tab at
the expected spot — there is no rendering environment here. That is
settled by a look at the running app, as was last done for the Return key
on the sidebar row. This belongs, at wrap-up, explicitly named as a
maintainer check, not silently booked as "green".

---

## What is explicitly not included

- No restoring tabs across a restart — its own task.
- No dragging a tab into a new window — multi-window is v2.
- No change to `fileActions` or the browser context menu.
- No answer to C2 ("session is already open") — its own backlog item.
