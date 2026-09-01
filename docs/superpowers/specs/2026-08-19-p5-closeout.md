# P5 — Three stragglers from P3

**Status:** done. Suite 2150 tests in 191 suites, green.

## Task 1 — A broken entry no longer deletes a log

**The bug:** `AuditLogStore.loadIfNeeded` decoded the whole array at
once and swallowed every error with `?? []`. A single non-decodable
entry turned that into `[]`, and the next `append` rewrote the file with
**only the new entry**. The session's history was gone, without notice.
Reachable via any event kind an older App version doesn't know —
`AuditEvent.Kind` is a `String` enum, an unknown raw value throws.

**Two halves, both necessary:** decode element by element, so a broken
entry only costs itself; and don't overwrite an incompletely read log,
so the older version doesn't permanently write away the newer version's
entries. Without the second half, the loss would only have been
delayed.

**Deliberately not done:** an `unknown` event kind. A plain case
without a carried raw value would turn `snippetExecuted` into
`unknown` on write-back — that falsifies the history instead of merely
truncating it.

The implementer found a gap in the spec: "clear log" and
"delete session" would have been silently blocked by the write protection.
An explicit user action must go through; both reset the protection for
the session. Confirmed by the reviewer, including that the "is not
overwritten" test really re-reads the file from disk — a cache test
would have stayed green even if the file had been destroyed.

## Task 2 — Real plural forms for the two count messages

"%lld snippets will be written" read, for a single selection, as "1 snippets",
and since P3h a single item is the **normal case** for snippets
(select a row → export), no longer the special case.

Four `.stringsdict` catalogs instead of a branch in the code: Polish has
three categories (one/few/many, based on the genitive plural after 5),
French treats zero the same as one. A two-way branch would have been
wrong for half of the supported languages.

**Three measurements made up front, not assumed:**
- `NSLocalizedString` resolves a `.stringsdict` entry before a
  `.strings` entry of the same name — checked with deliberately
  contradictory values in a throwaway bundle.
- SwiftPM's `.process(...)` copies a `.stringsdict` from the `.lproj` into
  the built bundle.
- The existing catalog guard reads only `.strings`. The
  keys therefore stay there (the `.stringsdict` wins at runtime), the
  guard stays untouched, and the fallback text keeps existing.

A fourth finding came up during testing and is the most subtle:
**`String(format:)` without an explicit `Locale` picks the plural
category based on the process locale**, not the language of the
catalog the format string came from. A test that simply loads the
Polish bundle and formats would, on a German machine, have applied
the German rules and would still have gone green — proving nothing. The
tests therefore explicitly pair a loaded language bundle with an
explicit `Locale`.

**Open, not verified:** the call sites in the App don't pass a
`Locale`. Whether the process locale follows the `AppleLanguages`
override from M11p is plausible, but not proved end to end. Cheap to
check: set the App language to Polish, export a single snippet.

## Task 3 — No log entry without delivery

`TerminalPanelViewModel.send` is fire-and-forget: bytes that accumulate
before the shell opens are buffered, and if opening fails, the error
branch discards them. The "ran snippet …" entry was recorded anyway,
because logging happened right after the `send` call. Realistic with an
account that has a `ForceCommand` rejecting the shell channel.

`send(_:onDelivered:)` fires only when the bytes actually went out: on
the running shell after a successful `shell.send`, or when flushed after
a successful open. The previous `try?` became `do/catch`, so a
swallowed send error doesn't pass as a delivery. The default
value `nil` leaves every existing call site unchanged.

Bytes and callbacks sit in two fields — `pendingBytes` is a flat
byte array, multiple sends merge into it, and their callbacks aren't
reconstructable from it. All the discard paths therefore go through
**one** helper instead of two assignments per site: a forgotten callback
would report a delivery that never happened.

## What this phase showed about the way of working

**Two delegations got stuck**, both at the same spot: the implementer
started builds in the background and waited on them, the second time after
an `rm -rf .build` that recompiles every dependency. Their preparatory
work was valuable regardless — the three measurements and the test file
from Task 2 are theirs, the catalogs and the commit are mine. For small,
well-scoped tasks, the handoff is more expensive than the execution.

**A red test got committed**, because the suite run and the commit
were in the same command and the output wasn't read before it
landed. The fix is in the commit right after.

**The red test was time-dependent** — a fixed 250 ms wait, sufficient on
its own, not under the suite's full load. It now polls for the
condition; the "still buffered" check runs synchronously before any
interruption, where no load is sufficient to trip it.
