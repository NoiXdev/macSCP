# P3h — Wrap-up

**Goal:** "Export" in the footer means the same thing in both sheets and
predicts up front how many entries will be written.
**Status:** done. Suite 2139 tests in 188 suites, green.

## What was built

`ListExportScope.resolve(selectedID:from:)` in Core: the selection, if it
belongs to the visible rows, otherwise all visible ones. Both footers call
it — until now the rule sat as a private method in only one of the two
sheets, the other had none at all. Snippet export additionally got a
confirmation with the count: without it, narrowing to a selection would
be invisible, which is exactly what the spec warns against.

The **row** context menu stayed untouched: it still exports exactly its
row, unconfirmed. The click is the statement about scope.

Re-verified in the full check: the login sets' behavior is unchanged
case by case, including for a selection the filter has taken off screen,
and for a stale identifier.

## What the full check found

**Two comments that the commit immediately before had just fixed were
wrong again** — same spot, same cause: the phase moved who calls
`performExport` without following up on the comment that describes the
callers.

**A doc comment claimed a history that never existed:** "a second copy is
how Export came to mean two different things". There never was a second
copy — the rule sat in only one sheet, the other had none. The true
version is at the same time the stronger argument for the extraction.

**A naming collision from my plan:** the new type was called
`ExportScope`, exactly like the existing
`SessionListViewModel.ExportScope` (`.single`/`.group`/`.all`). It
compiled, because the call sites qualify — it wasn't readable. Now
`ListExportScope`, and in `Presentation/` instead of `Sessions/`.

**The confirm button shared its key with the trigger.** That contradicts
the pattern of the same file (`snippets.delete` / `snippets.delete.confirm`),
puts an ellipsis on a confirm button, and was the sole reason an existing
count guard had to be loosened from 2 to 3. Now `snippets.export.confirm`,
and the guard is back at 2.

## Open

**A visual check that no test can replace.** The confirm button arms the
save dialog from the action of a closing alert — on macOS that's a sheet
on a window that's currently tearing another one down. The in-house
model (`LoginSetsSheet`) does the same thing, but from a `.sheet`, not
from an `.alert`, and it works. Probably unproblematic, but untested:
**open Snippets → "Export…" → confirm → does the save dialog appear?**
If not, the fix is a `DispatchQueue.main.async` around the call in the
alert action.

**Singular grammar**, inherited from `logins.export.summary`: "1 snippets
will be written…". For login sets, one was the exceptional case; for
snippets, after this phase it's the regular case (select a row →
Export). The honest fix is a `.stringsdict`, not a two-way string — the
Polish plural rules make a two-way branch wrong regardless. A separate,
small task for both keys together.
