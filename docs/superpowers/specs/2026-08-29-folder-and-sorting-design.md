# Nested folders and free-form sorting — design

**As of:** 2026-08-29. Implementation of **D1 + D2** from
`docs/superpowers/specs/2026-08-20-backlog-sessions-tabs-sidebar.md`,
which explicitly treats them there as **one** change.

---

## Why together

`StoredGroup` today carries **only `id` and `name`**. Neither nesting nor
ordering can be expressed without new fields. Built separately, the
storage format would change twice, and each change drags in
`SessionExportCodec` and the import planner.

## The measured starting state

| | today |
|---|---|
| `StoredGroup` | `id`, `name` — nothing else |
| Session-to-folder mapping | `StoredSession.groupID: UUID?` |
| Dissolving a folder | `SessionStore.dissolveGroup(id:)` — folder gone, its sessions set to `groupID = nil` |
| Order | none; the display sorts on its own |
| Format | `sessions-v2.json`; the pre-M23 file `sessions.json` stays behind as a rollback snapshot |
| Export | `SessionExportCodec` with its own `ExportedGroup` |

## Maintainer decisions (2026-08-29)

### 1. Additive in `sessions-v2.json`, no new filename

New **optional** fields in the existing file. An older build keeps reading
it, because `JSONDecoder` skips unknown keys — and **loses nesting and
ordering the moment it writes itself.**

That is the price, and it is named here rather than discovered: the loss
is **organization, never a session**. Names, hosts, folder membership, and
credentials stay untouched; only who was filed where goes flat afterward.

The difference from M23, which changed the filename for exactly this
reason: there, the shipped build **aborted** on the missing `host`. Data
loss versus a broken read — that is not the same case.

### 2. Order is an integer on the element

`StoredGroup` and `StoredSession` each carry a position, numbered
sequentially when written.

**Not the file's array order.** `SessionListViewModel.save` looks up an
existing session by **name** and changes it in place; import and
filtering rebuild the list from scratch anyway. An order embedded in
array position would hang on a code-path property nobody guaranteed and
no test would notice tipping over.

**And no separate order list.** A list of identifiers alongside the
elements would be a second truth that drifts apart — the same class of
bug this project has already paid for with duplicate names.

### 3. Arbitrarily deep, via `parentID`

`StoredGroup.parentID: UUID?`. No artificial limit.

The price is a **cycle check**: a folder must not become its own
ancestor. That belongs in Core as a pure value, checkable without a UI —
and it must also cover import, where a foreign file can bring in a cycle.

## The design

### Dissolving generalizes what it already does

`dissolveGroup` today lifts a folder's sessions to `groupID = nil` — for a
top-level folder, that is **one level up**.

Nested, the same rule holds literally: sessions *and* subfolders move to
the **parent** of the dissolved folder. No new semantics, just the same
one carried forward. Nothing gets deleted along with it.

### Dragging derives its target from identities, never from an index

This week's tab reordering already has the shape: `move(tabID:to:)` and
`move(tabID:onto:)`. The reason was not taste — the index in the view
**was** the bug class, and removing it closed it.

Here the same shape carries both:

| Gesture | Effect |
|---|---|
| drag between two siblings | reorder |
| drag onto a folder | move into it, at the end |

Both paths end in **one** core function that computes a new order from two
identities. The view computes nothing.

### One-off sorting per folder

A context-menu entry on the folder that sorts its immediate children by
name **once** and rewrites the positions.

Explicitly **not persistent state**: there is no stored sort setting per
folder, only an action that overwrites the free-form order. For tidying
up, not as a mode. Acts only one level deep — anything more would be a
mass change hidden behind one menu item.

### Export and import carry it along

`SessionExportCodec` and the import planner carry `parentID` and the
positions. Both must handle a file that does **not** carry them — an
older export — and one that brings in a **cycle** or a **missing
parent**.

The rule for both defects is the same and follows the house rule
"additive, never destructive": a folder whose parent is missing or would
close a cycle lands at the top level. **Nothing gets discarded**, and the
import reports what it straightened out.

## What no test in this project can see

Everything decidable is checkable: the cycle check, generalizing the
dissolve, computing order from two identities, one-off sorting, and that
export and import carry the new fields and survive damaged ones.

**Not checkable** is whether the tree drags pleasantly in the live
sidebar. That stays a matter of the maintainer's own look.

## What is expressly not included

- **No stored sort setting per folder.** Only the one-off action.
- **No new filename**, no second file, no version key.
- **No change to `SessionListViewModel.save`** and its upsert by name.
- **No deleting sessions when a folder is dissolved** — not today, and
  certainly not nested.
- No search in the tree (D3). That comes after this change, because
  nesting shapes how it would be displayed.
