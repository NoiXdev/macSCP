# Tags: togglable and as a filter — Design

**Status:** 2026-08-29. Implements **E1 + E2** from
`docs/superpowers/specs/2026-08-20-backlog-sessions-tabs-sidebar.md`,
explicitly listed there as to be designed together, because they touch the
same spot in the sidebar. These are the entry's last two open points.

---

## The measured starting state

`SessionSidebar` holds `activeTag: String?` — **exactly one** tag, as view
state — and passes it to `SidebarVisibility.compute(activeTag:)`, which the
source names as the *one* place that filters.

Both of these follow from that: the and/or question could not previously
arise, and there is no setting that hides the bar.

Since D3 the same function additionally filters on a search term, and both
criteria apply together.

## Maintainer decisions (2026-08-29)

### E1: togglable means — the bar disappears, tags remain

A setting hides the **filter bar**. Tags remain assignable and visible in
session editing.

Anyone who doesn't like it as a filter loses nothing by this, and existing
tags don't become unreachable — that would be the case where a later
re-enabling surprises someone.

**An active filter is cleared when the bar is turned off.** Otherwise
something would keep filtering whose control no longer exists, and the
sidebar would show less than it has, with nothing explaining why. This
isn't a nicety: a list that filters invisibly is indistinguishable from a
lost list.

### E2: threshold six, linking selectable

At **six** tags and above, the bar collapses into a filter dialog. The
number belongs in Core as a named constant, not in the view.

Multiple tags can be linked as **all** (intersection) or **any** (union);
the user chooses.

## The design

### One model, two representations

**The filter is always a set of tags plus a link mode.** The bar is a
compact representation of it, not a second model.

That is the core of this design. Without it there would be "one tag from
the bar" and "several from the dialog" as two states that would need
translating into each other when crossing the threshold — and every such
translation is a place where a selection can quietly get lost.

`SidebarVisibility.compute` will take the filter value going forward
instead of a single tag. It remains the one place that filters.

| State | Representation |
|---|---|
| fewer than six tags | the bar; tags individually selectable and deselectable |
| six or more | a button that opens the dialog, showing the count of selected tags |
| bar turned off (E1) | nothing, and the filter is empty |

### The link mode appears only once it means something

With **zero or one** tag selected, "all" and "any" are the same thing. The
choice is therefore shown only once at least two tags are selected — in
the bar as in the dialog.

That is this project's standing rule, show only what is possible, applied
to a case where a visible control with no effect is especially confusing:
it would sit there, be flippable, and change nothing.

**The chosen mode survives deselection** and is not reset to a default
value when the selection drops below two. Otherwise removing a tag would
lose a setting the user had made.

### What the filter does with search

Nothing new: both apply **together**, as since D3. Anyone filtering by
tags and then typing searches within what's filtered. The ancestor rule
from D1+D2 applies unchanged to both criteria.

### The empty state names both narrowings

Since D3 the empty state says "No connection matches the filter" and its
button clears search and tag selection together. That stays as is and
covers the new case too — a filter made of several tags is the same case,
only narrower.

## What no test in this project can see

Everything decidable is testable: that the threshold takes effect, that
"all" and "any" do the right thing, that the link mode appears only from
two tags on and doesn't forget the mode while doing so, that turning it
off clears the filter, and that search and tag filter apply together.

**Not testable** is whether the threshold sitting at six is right. That's
a number derived from the word "a handful" and will show itself in use —
which is why it sits as a named constant in one place.

## What is explicitly excluded

- **No hiding of tag assignment.** E1 hides the filter bar, not the tags.
- **No change to `StoredSession.tags`** and nothing about the storage
  format.
- **No tag management** (rename, merge, delete across all sessions) — that
  would be its own change.
- **No change to the search** from D3 and none to the ancestor rule from
  D1+D2.
