# Search in the session tree — Design

**As of:** 2026-08-29. Implementation of **D3** from
`docs/superpowers/specs/2026-08-20-backlog-sitzungen-tabs-seitenleiste.md`.
D3 deliberately waited for D1, because the nesting co-determines the
presentation — and it does in fact pose the question differently than
the entry posed it.

---

## The measured starting state

**The sidebar has no search.** No `searchText`, no search field.

Two building blocks are already in place, though, and both are the reason
this change is small:

- **`SheetSearchField`** from M18, used in four management sheets. It
  brings a **regex toggle** and an error display for an invalid
  expression.
- **`SidebarVisibility`**, tree-wide since D1+D2: today it filters purely
  on `StoredSession.tags` and keeps a folder alive if **anything
  underneath it** matches — from every match upward via
  `GroupTree.selfAndAncestors`.

The second one is the real news: **the filter rule for a tree already
exists and is proven.** A text search is the same rule with a second
criterion, not a second filtering path.

## Why "filter or highlight" is no longer the question

The entry leaves both open. After D1+D2, filtering is nearly free, and
highlighting would be new machinery — a second concept next to
"visible", with its own states.

The nesting poses a new question for this, one the entry couldn't have
had: **a match inside a collapsed folder is filtered and still
invisible.**

## Maintainer decision (2026-08-29)

**While searching, the tree expands.** With something in the search field,
the sidebar shows the filtered tree open — otherwise you'd be filtering
onto something you can't see.

**The user's collapse state stays untouched** and returns as soon as the
field is empty. The search *overlays* it, it does not overwrite it. That
is the condition under which this decision is bearable: a search that
permanently expands the user's folders has changed their organization
without their wanting it.

## The design

### One more criterion in the same rule

`SidebarVisibility.compute` gets the search term in addition to the
tag filter. Both apply **together**: someone who filters by a tag and
then types is searching within the filtered set. Anything else would be
surprising, and two filters that cancel each other out are hard to
explain.

The ancestor rule stays unchanged and applies to the new case just the
same — it is the reason a match deep down keeps its path upward.

### What is searched

**Name, host, username and tags** of a session. That is what a user
types when looking for a connection.

**Folder names don't count as a match.** A folder is visible because
something inside it matches — not because it is itself named that. Otherwise
a match on the folder name would show all of its contents, and the search
would claim matches that aren't.

### The expansion is a second, short-lived state

"Expanded while searching" and "collapsed by the user" are two
different things, and the design keeps them separate: the remembered
state is read when the search field is empty, and **ignored** while it
is not. Nothing is written while searching.

### The building block is used as it is

`SheetSearchField`, complete with the regex toggle and error display, as in
the four sheets. A dedicated search field for the sidebar would be a second
construction of the same thing — and the regex capability is arguably more
useful in a session list than in a sheet.

An **invalid** expression shows its error and **filters nothing** — it
must not empty the list, since an empty sidebar because of a half-typed
expression looks like data loss.

## What no test in this project can see

Testable is everything decidable: what is searched, that search and
tag filter apply together, that ancestors are preserved, that an
invalid expression filters nothing, and that the remembered collapse
state is neither read nor written while searching.

**Not testable** remains whether the expanding and falling back while
typing feels calm. Maintainer's eye.

## What is explicitly not included

- **No highlighting** of matches in the text, no second presentation of
  the sidebar, no flat match list.
- **No writing** to the remembered collapse state while searching.
- **No search over folder names.**
- **No dedicated search field** for the sidebar.
- No change to the tag bar (E1/E2) — same sidebar, different
  change.
