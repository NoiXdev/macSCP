# Snippet editor part 2 — multi-line snippets: completion

**Status:** done, mergeable after one fix wave. Suite **2217 tests in 199
suites**, green. Starting value before the branch: 2197 in 196.

## What was implemented

A snippet may have several lines. What goes to the remote side when
triggered is decided by bracketed-paste mode, which the remote shell
switches on and the local emulator tracks.

| Command | Bracketing | Action | Result |
|---|---|---|---|
| single-line | either | either | unchanged, byte-for-byte as before |
| multi-line | on | insert | `ESC[200~` + body + `ESC[201~` |
| multi-line | on | execute | same + CR |
| multi-line | off | execute | line by line, CR after each line |
| multi-line | off | insert | **rejected**, with an offer to execute |

Between the brackets sit the raw UTF-8 bytes of the body. This is not
guessed but read off SwiftTerm's own ⌘V path: `paste(_:)` passes the
clipboard string unchanged to `send(txt:)`, which turns it into
`[UInt8](txt.utf8)` — no line-ending translation anywhere along the way.

No field on the model, no store migration: a snippet **contains** line
breaks or it does not, the content itself carries the information.
`Snippet.init` thereby lost its only failure reason and can no longer
fail; **95** call sites were updated accordingly, and the line-break
sanitizer was deleted.

In the editor, Return now writes a line break, Save is ⌘Return (one of
**three** `.defaultAction` sites in the file, the other two were left
alone), and the field grows along with the content up to an upper bound.

## Compatibility — in one direction

Old `snippets.json` files load unchanged; the format has not changed, the
decoder has only become more lenient.

**The reverse does not hold.** A multi-line file written by this build
makes the **entire** file unreadable for the shipped 1.2.0, whose decoder
throws on the line break. That belongs in the release notes; it is not a
fix, because downgrading is not a supported path.

## The closing review found a Critical that no task review could see

`isVerticallyResizable = false` nailed the text view's frame in place. An
`NSScrollView` scrolls only as far as its document's frame reaches —
`hasVerticalScroller = true` alone does nothing. Beyond the eight-line
boundary the text was laid out but unreachable, and the insertion point
left the visible area while typing.

The reviewer did not suspect this, but **measured it with an AppKit
probe**: at 5, 12, 30 and 60 lines the frame stayed at 150 pt, while the
text needed 88, 200, 488 and 968.

**The bug was in the plan as written.** It said "`isVerticallyResizable`
stays `false`" *and* "after that a vertical scroller" — a contradiction
that the implementer faithfully implemented both halves of. It is the
fourth plan defect on this branch and the most expensive.

Also fixed: `SnippetKeystrokes.bytes(for:execute:)` had become orphaned
public API that reopened exactly the danger this branch was built
against (it delivers the raw line breaks as keystrokes for a multi-line
command) — now `internal`. The entire App→Core wiring was untested; the
reviewer proved it by mutation, not by assertion: flipped `?? false` to
`?? true`, 318 tests stayed green. And the rejection alert could get
swallowed because the trigger fired before sheet and popover had closed —
the fix wave found **two** trigger forms with four closures for this, not
the one from the finding.

## What stays unverified — visual check by the maintainer

No test in this project draws an `NSViewRepresentable` or talks to a real
shell. Explicitly open:

- **The field growing along with content** including its upper bound, and
  that beyond it vertical scrolling works. The Critical above was exactly
  here.
- **⌘Return saves**, Return writes a line break.
- **The three display sites** for a multi-line command: the line in the
  sheet, the preview line on the terminal panel (both "+N more"), and the
  action sheet, which deliberately shows the command in full.
- **The rejection alert from all four triggers** — it is the only new
  modal on this branch, and the presentation order was a finding.
- **A bracketed paste against a real shell** with mode 2004 switched on.

## The lesson of this branch

Four of the five bugs the reviews found were **in the plan**, not in the
implementation: a number a grep miscounted; a guard test that could never
have passed; a comment that concealed an exception; and the contradiction
above. Every time, the implementers did exactly what was written.

This is the third repetition of the same finding in this project.
Plan prose sounds complete while being written and is believed while
being implemented. What helps is not more care while writing, but giving
implementers the mandate to **report contradictions instead of resolving
them** — both times that happened, a real finding came out of it.
