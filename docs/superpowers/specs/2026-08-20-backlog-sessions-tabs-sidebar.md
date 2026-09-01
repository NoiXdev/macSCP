# Backlog: connection state, tabs, sidebar, tags

**Created:** 2026-08-20, from a maintainer call-out. Eleven points, backed
ideas, **no design**. The current state below is measured against the
code, not assumed.

---

## A. Connection state

### A1. Make the timeout visible — **done 2026-08-25**

> Implemented via `docs/superpowers/plans/2026-08-25-failed-structure.md`.


Instead of a dead view: an error display in the tab, phrased
understandably, with **"Reconnect"**. A warning symbol in the tab
strip, and a green symbol as long as everything stands.

What this requires: a **connection state on the tab**, which does not
exist today. `SessionTab` carries the session and the panes; "connected
/ disrupted / disconnected" is not a value anyone could read off. To
clarify before designing: how does macSCP even notice the drop — from
the next call failing, or actively (see A2)? Without A2 the app only
learns about the drop when the user does something, and the warning
symbol would always come too late.

### A2. Keep-alive — **done 2026-08-26**

> Implemented via `docs/superpowers/plans/2026-08-21-connection-state.md`.


**There is none today** — no hit for `keepalive` or
`ServerAliveInterval` anywhere in the source tree. Regular signs of
life, so the session and tunnel don't drop, as a setting with an
interval.

To check before designing: at which layer this works. SSH has a
transport-level keep-alive; whether Citadel/NIOSSH offers it or whether
it has to be harmless channel traffic is a **feasibility question and
needs to be measured**, before a setting is designed for it. For jump
hosts the question applies twice.

**A2 before A1.** A2 is what notices the drop in the first place; A1 is
what it looks like.

---

## B. Tabs

### B1. Context menu on the tab — **done 2026-08-27**

> Together with B2 via `docs/superpowers/plans/2026-08-27-tab-context-menu-and-reorder.md`.


Close, for ad-hoc connections **save as a session**, move left / move
right. `TabStripView.swift` today has **no** `contextMenu`.

### B2. Reorder by dragging — **done 2026-08-27**

> Together with B1, as the entry demanded. The drop feedback came later, see `2026-08-27-backlog-tab-polish.md` section A.


Also nothing present — no `onMove`, no `draggable` in the tab files.
B1's "move left / move right" and B2 are the same underlying capability
(reordering tabs), just two ways to operate it. **Build together**,
otherwise the reordering gets built twice.

### B3. Where the entries come from (maintainer, 2026-08-25)

**No `switch` over `ConnectionKind`.** A tab menu can look different per
protocol, and this project already has a pattern for that:
`BackendDescriptor.fileActions: [FileActionContribution]` — every
backend **contributes** its actions, instead of one spot branching on
the kind. At the connection entry point, the reason is stated in the
source: living there "dissolved the last `ConnectionKind` switch on the
connection path".

Cross-check when creating this entry: the remaining `switch …kind` in
the tree run over **event** and **element** kinds, not over
`ConnectionKind`. So the pattern holds; a new switch would be a
regression.

**The distinction that's easily lost when building this:** the menu
mixes two origins.

| Entry | Where from |
|---|---|
| protocol-dependent actions | the backend's contribution, like `fileActions` |
| Close, move left / move right | a property of the **tab**, the same for every protocol |
| Save as session | a property of the **tab state** — only for an ad-hoc connection, independent of the backend |

Forcing everything through the descriptor would be just as wrong as a
switch: three backends would then have to contribute the same close
action. The dividing line is not "which menu", but **what the entry
depends on**.

---

## C. Starting a session

### C1. A single click shouldn't connect — **done 2026-08-26**

> Implemented via `docs/superpowers/plans/2026-08-25-small-controls.md`. Tackling it revealed: the sidebar had no notion of selection at all, the gesture was the smaller part.


Measured: `SessionSidebar.swift` hangs `onSelect()` off a row tap, and
`ContentView+Detail.swift` passes it on to `connectFromSidebar(stored)`
— **a click builds a connection today.** Wanted: selection on a single
click, connection only on a double click.

Fortunately: the context menu of the same row already has an entry
**"Connect"**. So the path isn't lost when the tap becomes a selection.
This is the smallest point on the whole list.

### C2. Session is already open — **done 2026-08-29** (`71b86c0`)

Designed in `2026-08-29-session-already-open-design.md`. Identity is
`activeStoredSessionID`, an ad-hoc connection does not count, it asks
every time. With several holders the first one in tab order wins; the
active tab counts like any other. The panel wish from "Open Terminal"
travels along in the query, so that an answered query doesn't silently
turn into an ordinary connect.

*The original note, as evidence of the open questions:*

Ask when starting a session that is already open: **open new** or
**jump to the existing one**. To decide: does macSCP remember the
answer ("don't ask again"), and what counts as "the same" — the same
stored session, or also the same destination via an ad-hoc connection?

---

## D. Sidebar

### D1. Nested folders + D2. Free-form sorting — **done 2026-08-29**

Designed in `2026-08-29-folder-and-sorting-design.md`, implemented in
four steps (`6a7a1be`, `5afdfa5`, `8ade149`, `22da6a9`). Additive in
`sessions-v2.json`, integer position on the element, arbitrary depth via
`parentID` with cycle checking in Core. The view computes no position —
checked by a scanner, backed by four positive guards.

**Two findings while building, both recorded:** `SidebarVisibility`
discarded folders that carried no matching session of their own — flat,
correct; nested, it lost matches, until a session two levels deeper was
no longer reachable by any path. And **export** now carries along the
ancestors of an exported folder, otherwise nesting doesn't survive a
round trip.

**Open, and a maintainer matter:** a folder cannot be dragged directly
**in front of** another one — dropping onto a folder means "into it".
Every arrangement stays reachable, but the gesture is missing. The fix
is explicitly **not** an insertion marker: a second drop zone on the
folder row would again be a coordinate.

*The original note:*

`StoredGroup` today carries **only `id` and `name`**. No parent, no
order. Both — nesting *and* free-form sorting — need new fields in the
session store.

**That's why they belong together.** Built separately, the storage
format changes twice, and every change drags `SessionExportCodec` and
the import planner along with it. Project rule: migrations additive,
never destructive.

D2's second part belongs here too: a context menu **per folder** that
sorts its sub-items once (by name or similar) — for a quick tidy-up, not
as a standing state.

### D3. Search in the session tree — **done 2026-08-29** (`7052e1b`)

Designed in `2026-08-29-search-in-session-tree-design.md`. The open
question "filter or highlight" answered itself via D1+D2: the filter
rule for a tree was already there, highlighting would have been new
machinery. Nesting raised a new one in exchange: a match inside a
collapsed folder is filtered and still invisible. Decided: expand while
searching, **never write** the remembered state while doing so.

Search covers name, host, user and tags; folder names don't count.
Search and tag filter apply together. `SheetSearchField` including
regex was added unchanged; an invalid pattern shows its error and
filters nothing.

*The original note:*

The sidebar has **no search** (no `searchText`, no `SheetSearchField`).
The building block already exists from M18 though and is used in four
management sheets; it would be reused here rather than built again.
Open: does the search filter the tree, or highlight matches — with
nested folders (D1) that is a difference.

### D4. Resize and remember the width — **done 2026-08-26**

> Implemented via `docs/superpowers/plans/2026-08-25-small-controls.md`, bounds 170…340.


Measured: `ContentView+Detail.swift` clamps the sidebar to
`minWidth: 170, idealWidth: 190, maxWidth: 260`. The **upper bound of
260** is why it can't be dragged wider, and nothing is persisted. To do:
release the clamp and store the width in `SettingsStore`.

---

## E. Tags — **done 2026-08-29** (`4e6ee36`)

Designed in `2026-08-29-tags-filter-design.md`, together as required
here. E1 hides the **filter bar**, never the tags; an active filter is
cleared when it's turned off. E2: threshold **6** as a named constant in
Core, the connective selectable between "all" and "any".

The answer to both open questions came from a decision that neither of
them posed: **the filter is always a set plus a connective**, the bar
just a compact display of it. Otherwise "one tag from the bar" and
"several from the dialog" would be two states that would have to be
translated into each other when crossing the threshold — and every such
translation eventually loses a selection silently.

The connective appears only from two selected tags onward and survives
falling back below that.

*The original notes:*

### E1. Tag search can be switched off

Hideable via settings, because not everyone likes it. To decide: does
only the display disappear, or the assignment of tags too?

### E2. Filter pouch instead of a bar

From more than a handful of tags on, the selection should collapse into
a filter that's assembled in a dialog. To decide before designing: **at
how many** does the display flip over, and is the filter an and or an
or connective — today the bar sets a single selection (`selection =
tag`), which never raised the question so far.

E1 and E2 touch the same spot in the sidebar and should be designed
together.

---

## Order

1. **C1** — smallest intervention, biggest daily effect, the context-menu
   path already exists.
2. **D4** — one clamp and one store field.
3. **A2 → A1** — notice first, then display.
4. **B1 + B2** — together, one capability.
5. **C2** — independent, any time.
6. **D1 + D2** — together, the most expensive point: a format migration
   with export and import in tow.
7. **D3** — after D1, because nesting co-determines the search display.
8. **E1 + E2** — together.
