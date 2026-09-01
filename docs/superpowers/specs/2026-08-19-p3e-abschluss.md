# P3e — Completion

**Goal:** Whoever runs a snippet in the terminal can find it later in the
session log.
**Status:** done. Suite 2118 tests in 185 suites, green.

## What the feasibility measurement decided

Logging free keyboard input is not being built. SSH does not negotiate
echo, SwiftTerm's SRM mode is a stub, and `sudo` turns off echo
server-side via `termios` — invisible on the wire. So there is no honest
way to log typed input without at some point recording a password.
Only what macSCP itself sends, and whose text it knows, is logged.

## What the measurement changed about the phase's size

Two findings made it small: the audit machinery from M9b already stands
complete, and all four snippet surfaces (menu bar, terminal right-click,
header popover including the double-click window, row context menu,
sidebar submenu) run through **one** funnel,
`ContentView.triggerSnippet(_:execute:)`. What remained: one event type,
one Core formatter, one recording line, one filter category "Terminal",
four catalogs.

**Executions only.** An inserted snippet sits in the prompt and can be
changed before being sent; logging it as "executed" would be a wrong
entry. The ⌃⌘ shortcuts are dedicated exclusively to inserting and
therefore write nothing.

## What the full review found

**A real, pre-existing bug in `Snippet` — not caused by this phase, but
uncovered by it.** The guard checked
`command.contains("\n")` and `contains("\r")`. Swift treats `"\r\n"` as
**one** grapheme cluster, and `String.contains(_:)` searches by grapheme:

    let cmd = "cd /srv\r\nls -la"
    cmd.contains("\n")              // false
    cmd.contains("\r")              // false
    Array(cmd.utf8)                 // contains 13 AND 10

A snippet with Windows line endings therefore got through — and went to
the shell with a raw `0x0D` in the middle. That **immediately executes**
the first line, even on *insert*, where the code explicitly promises
never to append a line terminator. Reachable via the snippet import (a
file generated on Windows, or handwritten), because `init(from:)` runs
through the same guard. U+000B, U+000C, U+0085, U+2028 and U+2029 got
through in the same way.

The guard is now called `!command.contains(where: \.isNewline)`, with
red tests up front for CRLF and the vertical tab.

Additionally: the review found three untrue or stale pieces of text (the
promise "the log says what actually went out", the stale guard
description in the snippet sheet, and its L10n fallback text) and a weak
test, which now runs over `AuditEvent.Kind.allCases` and thereby catches
every future case with no catalog entry.

## Known limits (deliberately so)

- **The entry is created after the `send` call, not after delivery.**
  `TerminalPanelViewModel.send` is fire-and-forget: bytes that accumulate
  before the shell opens are buffered, and if opening fails, the error
  branch discards them — the entry stands anyway. Realistic with an
  account that has `ForceCommand`. The comment at that spot now says so.
  A real delivery acknowledgment would be a separate change to `send`.
- **Ad-hoc connections log nothing.** The recorder is tied to a saved
  session; without one there is also no sheet to open. This applies to
  the whole audit feature, but is noticed here first, because terminal
  and snippets work normally on an ad-hoc connection.
- **The rule "snippets carry no credentials" is a promise, not
  enforced.** What is new is that an executed command now also appears
  in the session log — it outlives the snippet, ends up in the log's
  text export, and repeats per session. The hint text in the editor now
  says so in all four languages.

## Backlog (from the review, pre-existing)

`AuditLogStore.loadIfNeeded` swallows decode errors and rewrites on the
next `append`. An older app version reading a log with an event type it
does not know sees it as empty and **overwrites that session's
history**. This applies to every kind ever added. A lenient decoder
(mapping unknown values to `.unknown`) would be the fix — to be done
before the next new event kind.
