# M11i — Cycling through completion candidates (Design)

Date: 2026-07-30 · Status: requested by the maintainer (emphasized repeatedly)

## Goal

In the path input (M11g), repeated **Tab** with multiple candidates should
**cycle** through the list instead of just showing it again; **Esc**
aborts the cycling without losing the input.

## Starting point (M11g, `PathBar.swift`)

Today's flow:

- **1st Tab**: `handleTab()` lists the parent directory, calls
  `PathCompletion.complete`, sets `draft = result.completedInput` (the
  common prefix, with `/` on exactly one match), remembers
  `lastCandidates`, `lastCandidatesDirectory`, `lastCandidatesDraft`.
- **2nd Tab** (`justCompletedWithTab == true`): shows `lastCandidates` as
  an overlay, provided `lastCandidatesDraft == draft`.
- **every further Tab**: shows the same list again — nothing new
  happens.
- Clicking a candidate (`selectCandidate`) sets
  `RemotePath.join(lastCandidatesDirectory, name) + "/"` into the field.
- **Esc** (`cancelOperation` → `cancel()`): closes the field entirely and
  discards.
- **Shift+Tab** (`insertBacktab`): deliberately falls through to AppKit
  focus traversal and discards in the process (M11g finding M7).

## New behavior

As soon as the candidate list is visible (i.e. from the 2nd Tab on), the
input enters a **cycle mode**:

- **Every further Tab** selects the **next** candidate, sets it into the
  field (`RemotePath.join(lastCandidatesDirectory, name) + "/"`, exactly like
  `selectCandidate`), and highlights it in the list. The first Tab in
  cycle mode selects the **first** candidate (index 0).
- **Shift+Tab** selects the **previous** one; wraps at the start/end
  (modulo count). This requires `insertBacktab` to be handled in the
  `PathTextField` **as long as the list is open** — only otherwise does it
  fall through further (the M7 rule stays untouched outside of cycling).
- **Enter** jumps to the currently selected candidate — that is the
  current `draft`, `navigate(to:)` needs no special case.
- **Any other keypress** (a character, delete) leaves
  cycle mode: the text stays as the field shows it after the keypress,
  the list closes, and the next Tab round starts fresh
  (`justCompletedWithTab` reset — this already happens today in
  `resetTabTracking`).

## Esc — "one step back"

Esc today discards the whole field. That must not cost the whole
input while cycling, so Esc gets two stages:

- **1st Esc, while cycling**: restores the text that was
  in the field **before** cycling started (the common-prefix state
  from the 1st Tab, i.e. `lastCandidatesDraft`), leaves cycle mode and
  closes the list. **The field stays open.**
- **2nd Esc** (or Esc when NOT cycling): closes the field and
  discards, exactly as today.

This way Esc always means "one step back", and nobody accidentally
loses the typed input.

## State (purely additive)

Two new `@State` fields in `PathBar`, no existing field changes its
meaning:

- `cycleIndex: Int?` — `nil` means "not in cycle mode"; otherwise the
  index of the highlighted candidate in `lastCandidates`.
- `cycleBaseDraft: String` — the field text before the first cycle step,
  which the 1st Esc resets to.

Cycle mode is bound to `lastCandidates`: a new Tab round
(new listing) resets `cycleIndex = nil`, so that a late listing does not
write into a stale selection (the same care as in
M11g findings I2/I6).

## Display

`CandidatesList` gets an optional `selectedIndex`. The highlighted
entry gets the app's subdued selection area (`remoteSoft`, like the
table selection in M5g) and is scrolled into the visible area
(`ScrollViewReader`), so that while cycling through a long, capped
list you always see the current candidate. Without `selectedIndex` (the
plain 2nd-Tab state before the first cycle step) the list looks like
today.

## Deliberately NOT

- No keyboard navigation of the list with arrow keys (that comes, if
  at all, with the general browser keyboard control — its own
  milestone).
- No change to `PathCompletion` (Core) — pure App layer.
- No cycling over file candidates: the list continues to contain only
  directories (M11g).

## Tests

- **No App test target** (known from M11g): the state logic lives as
  `@State` in the view and is not reachable by automation. The pure
  computational core statement — "next/previous index modulo count" — is
  factored out as a **free, testable function** (e.g.
  `CandidateCycle.next(from:count:)` / `.previous(...)`) and covered
  in `Tests/macSCPCoreTests` or an App-adjacent pure test:
  wrap forward/backward, start from `nil`, count 1, count 0.
- The rest (Tab/Shift+Tab/Esc wiring, highlighting, scrolling) goes into
  the smoke checklist for the maintainer, as already with M11g.

## Breakdown

A single task (App + small pure cycle function with test) → done.
NO release.
