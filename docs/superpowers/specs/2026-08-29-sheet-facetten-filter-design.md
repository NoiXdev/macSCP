# Facet quick filter in the management sheets — Design

**As of:** 2026-08-29. Implementation of **item 2** from
`docs/superpowers/specs/2026-08-20-backlog-verwaltungs-sheets.md` — the
last open item of that entry.

---

## The measured starting state

`SheetSearchField` (M18) sits in several sheets and returns, via
`sheetSearchPredicate(text:isRegex:)`, a `FileSearch.FileSearchPredicate`
plus an error text for an invalid expression. Each sheet filters
its rows with it itself (`filteredRows`).

**A facet filter exists only in `AuditLogSheet`** — and that is not one
of the three sheets at issue here. Known Hosts, SSH keys and
Login Sets have the search, but no facets.

## Maintainer decision (2026-08-29)

**One shared control that the facets are passed into** — not
three separate ones.

The reason is stated in the entry itself: it shares the predicate shape of the
search, so search and filter **chain instead of competing**. Three copies
of this chaining would be three places where it has to be correct — and this
project has paid for the same rule sitting in multiple places
more than once this week.

## The design

### The facets are data, not construction

The control gets a list of facets and the function that maps a
row to its facet value. What a facet *is* is known only to the
respective sheet:

| Sheet | Facet |
|---|---|
| SSH Keys | Key type |
| Login Sets | Backend kind |
| Known Hosts | Algorithm |

### One selection, not several

One value or "All" — no set model with a combinator.

This is deliberately **different from the sidebar's tag filter**, and the
difference is not inconsistency: tags are open-ended and there can be any
number of them, which is why a set plus "all/any" was needed there. A facet
is a closed, small enumeration, and in practice the values are mutually
exclusive — a key has *one* type. A set model on top of that would be
machinery without a case for it.

**"All" is the absence of a selection**, not a facet value of its own.
Otherwise every mapping function would have to know a value that means
nothing.

### Chaining means: both must match

A row survives if the **search** matches it **and** the facet fits.
Someone who filters by a type and then types is searching within the
filtered set — the same rule the sidebar has followed since D3.

The chaining is a **testable value**, not a line in three separate
`filteredRows` piles. It is written once and called three times.

### The facets come from the data, not from a list

Which values a sheet offers is derived from its **rows**, not
fixed and enumerated. A key type nobody has does not belong in the
selection — and a new one someone creates appears without anyone updating
a list.

That is this project's standing rule ("only show what's possible")
and at the same time the one it has learned twice this week: a fixed
enumeration goes stale silently.

**It follows that:** if a sheet has only a single facet value, the
selection is meaningless and does **not** appear. A control that can be
operated and changes nothing is worse than none.

### The empty state names both narrowings

A sheet whose list is empty must say **why** — no match, or
no entry of that kind. And the possibility of both together clearing the
list belongs to that as well.

`KnownHostsSheet` currently derives `isUnfiltered` as `searchText.isEmpty`.
That becomes wrong with the facet and must be fixed in the same
pass — otherwise a sheet claims to be unfiltered while a facet hides
rows.

## What no test in this project can see

Testable is everything decidable: the chaining, that the facet values come
from the rows, that a selection with only one value does not appear, that
an invalid expression still filters nothing, and what the empty state
says.

**Not testable** remains whether the control sits well below the search.
Maintainer's eye.

## What is explicitly not included

- **No multi-select** and no and/or combinator.
- **No facet over a composite subtitle** — fingerprint,
  key length and path sit in one string and are not available as
  separate fields. That is the deliberately paid price of item 4 and
  remains so.
- **No facet filter in `AuditLogSheet`**, which has its own and
  keeps it.
- **No change to `SheetSearchField`** itself.
