# Backlog: management sheets — filter, sorting, space

**Created:** 2026-08-20, from a maintainer call-out. Secured ideas, **not a
design**. Five points, four of them small and one an open question of
principle.

## Starting point, measured

| Sheet | Lines | Presentation | Buttons |
|---|---|---|---|
| `KnownHostsSheet` | 238 | **`Table`**, 6 columns | 6 |
| `AuditLogSheet` | 287 | **`Table`**, 3 columns | — |
| `HiddenImportsSheet` | 191 | `List` | — |
| `LoginSetsSheet` | 1024 | `List` (+ 1 `Table`) | 23 |
| `SSHKeysSheet` | 878 | `List`, **no `Table`** | 25 |

Existing building blocks: `SheetSearchField` (M18, text + regex toggle,
predicate via `FileSearch.compile`) in four sheets; the parameterized
sorting from M11l/M11m sits in the file table, not in the sheets.

## 1. Duplicate a session via the context menu

In the sidebar, next to Rename/Delete. Open and to be clarified before
design: what happens to the **secret** — does the duplicated session point
to the same keychain entry, or to none at all? And what about a
**login-set binding** (M11a) and group membership? The copy name needs a
rule that matches `duplicateKey` from the import path, instead of a second
naming arithmetic beside it.

## 2. Quick filter under the search field

A type filter below `SheetSearchField` in known hosts, SSH keys, and
logins. The facets differ per sheet — key type for keys, backend kind for
logins, algorithm for known hosts. To be decided: a shared control with
handed-in facets, or three separate ones. If shared, it belongs next to
`SheetSearchField` and shares its predicate form, so search and filter
chain rather than compete.

### Built on 2026-08-29 — the last open point of this entry

Decided and implemented per
`docs/superpowers/specs/2026-08-29-sheet-facets-filter-design.md`: **one
shared control** (`SheetFacetPicker`), which is handed the facets, over a
shared value (`SheetFacetFilter` /
`SheetNarrowing` in Core). The chaining of search and facet is a function
written once and called from the three sheets; `SheetSearchField` itself
was left untouched.

The facet values come from the rows, not from an enumeration — if a sheet
has only one value, no picker appears at all. The empty state
(`SheetListEmptyState`) names **which** narrowing emptied the list, and
clears both together.

Also done along the way: `KnownHostsSheet.isUnfiltered` read
`searchText.isEmpty` and would have become wrong with a facet in play. The
same shape stood in `SSHKeysSheet` (in `emptyStateText`) and in
`LoginSetsSheet` (directly in `body`); all three now ask the chained
result. `ServerCertificatesSheet` still carries the old shape — correctly
so there, because that sheet has no facet.

## 3. Column sorting in the known-hosts table

**The cheapest point on the list.** The sheet is already a `Table` with six
columns; SwiftUI delivers sorting via a `sortOrder` binding and
`KeyPathComparator`. No Core involvement needed — unless one wants to
remember the sort order across sessions, in which case a field is added to
`SettingsStore`. `AuditLogSheet` is also already a `Table` and would
inherit the same handle.

## 4. Table conversion — dropped (maintainer, 2026-08-20)

Considered and **rejected**: converting logins and SSH keys from `List` to
`Table`. Known hosts and audit log stay `Table`, the other two stay
`List`. The question is closed with this, not deferred.

**What building it had shown**, before the decision was made: the
login-set row would have gone through cleanly — badge, name, subtitle,
warning, usage count, five fields in a fixed order, no actions in the row.
The SSH-key row would have needed two workarounds: a third text line that
is only sometimes present, and five permanently visible icon buttons that
already duplicate that same row's context menu.

**What the decision costs, and permanently:** the subtitle is a composed
string — for keys `SHA256:… · <n> bit`, for login sets user and path.
Fingerprint, key length, and path are baked into it and are not available
as fields. **Sorting and filtering by them is therefore impossible** as
long as the row is a `List` row. Whoever wants that later runs back into
this decision — but then as its own effort, not as a side effect of
point 2.

## 5. Import/export under a three-dot menu — decided

**Measured before deciding** (footer buttons per sheet):

| Sheet | Buttons | Content |
|---|---|---|
| Login Sets | **6** | New, Edit, Delete, Export, Import, Close |
| SSH Keys | 3 | Import, Generate, Close |
| Known Hosts | 2 | Remove, Close |
| Hidden Imports | 1 | Close |

The space problem is therefore **login sets**, not "the sheets." For keys,
the same treatment removes one button and adds one click.

### The rule that decides it for both anyway

In the login-sets bar, two kinds of actions sit side by side: New / Edit /
Delete act on the **selection in the list**, Export / Import act on a
**file on disk**.

> **Selection actions stay visible. File actions move under the three-dot
> menu.**

This also implies what does *not* belong there: "Delete…" would save
space, but it is destructive — hiding a destructive action is the wrong
kind of saving. And the rule answers the next case in advance, instead of
turning it into a one-off question again.

### Settled

- **Both sheets** get the menu — keys not because of space pressure, but
  so the rule applies in one place instead of one of two. If the private
  key export later moves from the row into the footer, the space is
  already there.
- **Position:** immediately to the left of "Close."
- **Label:** icon only, no word. This therefore strictly needs a `help`
  text and an `accessibilityLabel`.
- Initial content: Export…, Import…

It is to be built against `List`, not against `Table` — see point 4.

### Built on 2026-08-29 — with a correction to the table above

Recounted before building, footer by footer: login sets **6** and SSH keys
**3** check out. **Known hosts are 3, not 2** — "Copy fingerprint",
"Remove…", "Close"; the row above had missed the copy button. Hidden
imports **1** checks out (the "Unhide" button sits in the row, not in the
footer).

Afterward: login sets four buttons (New, Edit, Delete, Close) plus the
menu, SSH keys two (Generate, Close) plus the menu. "Delete…" stayed
visible, as settled. The rule itself now carries a type:
`SheetOverflowAction` knows only export and import, `SheetOverflowMenu`
renders nothing else — a destructive action has no representation there.
For keys, no export is offered at all (the key exports sit in the row),
and for logins the export entry disappears rather than graying out when
the search leaves nothing.

### Followed up on 2026-08-29 — the third sheet, and what the count found

`SnippetsSheet` had the same shape and kept drawing its own Export…/
Import… buttons. Recounted before the rework: **6** buttons (New, Edit,
Delete, Export, Import, Close) — the same number as login sets, for the
same reason. Afterward: **4** (New, Edit, Delete, Close) plus the menu.
"Delete…" stayed visible. The per-row single export stayed where it is: it
always means the right-clicked row and does not ask.

The guards had, until then, enumerated the sheets **by hand** — exactly
the hole that had kept this sheet open for three milestones. The list has
been replaced: `SheetOverflowMenuWiringGuardTests` now finds the sheets
itself, and a second scan runs over *every* footer in the app layer, not
only the ones with a menu — otherwise a fourth deviating sheet would once
again stay invisible, simply because it never appears in the checked set.

This scan immediately found a case: **`AuditLogSheet` renders "Export as
Text…" in its footer.** Not converted along with the rest, but recorded as
a codified exception — the action writes a log for reading along, not a
document that can be read back in, has no Import next to it, and does not
carry the menu's wording. Whether it falls under the rule is a decision
about *this* sheet, not a mechanical repetition. The entry is pinned down:
if the button disappears without the exception being deleted, the test
fails.

## Order

With point 4 declined, all remaining points are independent of each
other.

3 first — it's practically free, since the sheet is already a `Table`, and
it makes the known-hosts view better immediately. Then 5, because the
three-dot menu relieves the rows before 2 lays another row on top. 1 is
independent of all three and can go in between.

**2 is now built against `List`**, not against `Table` — the filter works
on the same derived strings as the search and needs no column model.
