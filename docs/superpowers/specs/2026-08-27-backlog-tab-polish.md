# Backlog: Fine-tuning on the tabs

**Status:** open
**Logged:** 2026-08-27, maintainer, after reviewing the tab context menu
and drag-reordering in the running app.

Two items. Both look small; one of them is, the other one lands on a
seam the source code explicitly left open.

---

## A. Visible insertion marker while dragging

**Wanted:** while dragging a tab, see **where** it will land.

The caveat was already in the implementation's report ("no drop feedback at
the target, deliberately left out, worth its own UX item") — now it's
confirmed: without feedback you're dragging blind.

**The measured starting state:** `TabStripView` uses
`.draggable(tab.id.uuidString)` and `.dropDestination(for: String.self)`
**without** the `isTargeted:` branch. SwiftUI delivers the feedback for
free, it's simply never queried.

**The decision that comes first — and it isn't cosmetic.** The drop today
targets **a tab**, not a point between two. That's not an accident: the
position calculation was **removed** from the view in the last round,
because across three rounds of guard hardening, every piece of arithmetic
on it found a new spelling that could falsify it. `TabsViewModel` has
derived the target position itself from the two identities since
`19a8420`.

Two paths follow from this, with very different costs:

| Path | Cost |
|---|---|
| **Highlight the target tab** (`isTargeted`) | Matches the semantics exactly: "this is where you drop it". No geometry, no position, no step back. Cheap. |
| **Insertion line between two tabs** | Promises an insertion point the model doesn't know about — and needs drop-point geometry in the view for it, i.e. exactly what was just structurally removed. |

**Recommendation:** the first path. Whoever wants the second is also
deciding to bring the position calculation back into the view — that
should be named explicitly, not done in passing.

---

## B. Toggling between terminal and files

**Wanted:** for a connection with a terminal, toggle from the tab menu —
show the terminal or show the file browser, **depending on
what's currently active**.

**The measured starting state:** the item is named „Terminal öffnen" and is
**one-directional**. `openTerminalPane` only shows it and returns
immediately if the terminal is already visible. There is no path back
to the file browser from this menu.

### The seam this lands on

`PaneVisibility` carries `showsFiles` and `showsTerminal` and holds as an
invariant that **both halves can never be invisible at the same time** — the
initializer repairs that to "files win". Its own doc comment says,
however:

> This type only decides WHICH halves are visible. It says nothing about
> `TerminalPanelViewModel.isVisible`, the existing terminal toggle —
> **bringing the two into alignment is a later task's decision.**

So there are **two truths** about "is the terminal visible", and this
request is the first requirement that has to read both at once: to
decide whether the item is named „Terminal einblenden" or „Dateien
einblenden", it has to be settled which of the two applies.

**That is the actual substance of this item.** A menu item that reads the
wrong one of the two sources will occasionally show the wrong label —
and that is worse than a missing item, because you stop trusting it
afterward.

### To clarify before starting

1. **Which source wins?** Merge first, then label. There is
   already `PaneVisibility.applyingClick(on:hasShell:)` — it already holds a
   model for what a click on one half means.
2. **One item or two?** „Terminal einblenden" / „Dateien einblenden" as
   one item with a changing label, or two items, one of which is
   missing? This tab's existing menu items follow the rule
   *"doesn't appear when it doesn't apply"* rather than greying out.
3. **Both at once?** `PaneVisibility` allows both halves to be
   visible. A plain toggle cannot express that state — it would have
   to either abandon it or offer it.
4. **What about `terminalTarget`?** The toolbar and ⌘T follow the
   "built-in or external terminal" setting; the menu item does not
   (open item I4 from the final review of the same change). Whoever picks
   this item up should decide I4 in the same pass — otherwise three paths
   to the terminal carry two different meanings.

---

## Split

**Don't build A and B together.** A is a view-only change with no model
part and is done in one pass. B is first a decision between two
competing state sources and only after that a menu item; it belongs
together with I4, not with A.
