# Snippet Syntax Highlighting — Completion

**Status:** done. Suite 2197 tests in 196 suites, green (`swift test`,
local runtime approx. 5 s for the fast majority, transfer/queue tests
pull as usual around ~4.8–5.2 s each).

## What was implemented

Four commits for the effort itself, all on `develop` (this completion
report is the fifth; the two correction waves from the final review are
below):

- `c63be88` — plan document for this effort.
- `0920bf5` — Core: `SnippetHighlighter.tokens(in:language:)`, a pure
  shell tokenizer that returns `.command/.option/.string/.variable/.comment/
  .operator/.plain` ranges, without colors — `SnippetLanguage` is a
  parameter, not a stored field. Along with it,
  `SnippetCommandInput.sanitized(_:)`: every line break becomes a
  space before it reaches the binding. 13 tests.
- `8d99797` — doc correction on `SnippetHighlighter.tokens(in:language:)`
  (see "Review findings" below).
- `b37d3cf` — App: `SnippetCommandEditor`, an `NSTextView` inside an
  `NSViewRepresentable` that colors while typing, plus the
  replacement of the previous plain `TextField` in the snippet editor sheet.

The color mapping (token kind → `NSColor`) sits exclusively in the
`Coordinator` of the App component (`SnippetCommandEditor.swift:100–111`);
Core knows only token kinds, no colors — see verification below.

## Suite numbers (self-measured)

```
swift test
```

**2183 tests in 195 suites, all green.** Among them the 13 new Core
tests for `SnippetHighlighter.tokens(in:language:)` and
`SnippetCommandInput.sanitized(_:)` (`Tests/macSCPCoreTests/SnippetHighlighterTests.swift`).

## Verification: Core knows no colors

```
grep -c "NSColor\|Color\|import AppKit\|import SwiftUI" Sources/macSCPCore/Terminal/SnippetHighlighter.swift
```

Result: **`0`** — as expected.

Positive control, so an empty match doesn't falsely pass as success:

```
grep -c "SnippetToken" Sources/macSCPCore/Terminal/SnippetHighlighter.swift
```

Result: **`12`** (≥ 1 as required) — so the first command did in fact
read the right file and didn't slip past an empty one.

## Review findings

**Task 1 (Core), one Important finding, fixed in the same task:** The
doc comment for `tokens(in:language:)` initially claimed "every character
lands in exactly one token" — that's wrong, whitespace is not tokenized
and is skipped. The sentence came from the implementation plan, not from
the implementer themselves. Commit `8d99797` corrects the wording to
"every non-whitespace character lands in exactly one token, whitespace
is not tokenized" (`SnippetHighlighter.swift:31–34`).

**Two deferred minor findings on the tokenizer:**
- Only `&&` and `||` merge into a single operator token; `>>`, `<<` and
  `;;` remain two separate tokens.
- A standalone `-` is classified as `.option`, not as `.plain`.

**Two deferred minor findings on the App layer:**
- `Coordinator.parent` is never refreshed in `updateNSView`, unlike
  the model in `PathBar.swift`. Harmless today because `text` is a
  `@Binding` over `@State`; would become latent as soon as `parent`
  ever got a field that isn't a binding.
- The implementer's completion report named the file as 117 lines;
  it's actually 113 (`wc -l Sources/MacSCPAppKit/SnippetCommandEditor.swift`
  recounted by hand).

**One point the reviewer couldn't assess from the diff alone:**
If the system theme changes while the editor sheet is open and untouched,
the token colors may not recolor — recoloring only runs on a keystroke
(`recolour` is only called from `textDidChange` and `apply`). The base
color, by contrast, does adapt. Classified as cosmetic and rolled into
the pending visual check below rather than tracked as its own finding.

## Pending visual check — explicit, not a footnote

**No test in this project records `NSViewRepresentable`.** The
13 Core tests cover the tokenizer and the sanitization, not the
`NSTextView` behavior itself. The following can only be verified by
eye in the running app, not proved by the suite:

- **Caret behavior when typing in the middle** of an already-colored
  command — does the insertion point really land where expected after
  recoloring, not at the end of the text.
- **⌘Z** — does undo really only undo text changes, not the
  color attributes (Hazard 2 in the component's doc comment).
- **Pasting a multi-line command** — do all line breaks become
  spaces, even for multi-line clipboard content, and does the caret
  end up in a sensible position afterwards.
- **The focus ring** — does the component in focused state look like
  a native form field, or does the `NSScrollView` frame look different
  than expected.
- **Similarity to the name field next to it** — does the new `NSTextView`-
  based field look like a visually equal sibling of the previous
  `TextField` for the snippet name (height, padding, border color), or
  does the break stand out.
- Also, carried over from the review: **theme change with the sheet
  open and untouched** — do tokens recolor, and if not, whether that's
  noticeable in daily use.

The `.frame(height: 24)` at the embedding point in `SnippetsSheet.swift`
is an initial estimate; the visual check decides whether it fits or
needs adjusting. (The earlier line reference at this spot was wrong
within two commits — evidence for the house rule against writing
line numbers in prose about code.)

## Correction waves from the final review

The final review across the whole branch came back "not mergeable":
five important findings, all in the seam between the tested Core part
and the untested view. `401cbc2` fixed them in one pass, `11fd0b0`
fixed two leftovers from the follow-up check.

- **Automatic substitutions.** `NSTextView` left all five on
  default: "smart" quotes would have turned `echo "hi"` into
  typographic characters, `--` into an en dash — the command would
  have landed silently corrupted in `snippets.json`. The replaced
  `NSTextField` never had the problem because its field editor turns
  substitutions off on its own. Now explicitly turned off.
- **Tab.** Tab inserted a `\t` instead of passing focus along. `\t`
  is not `Character.isNewline`, so it survived the sanitizer,
  `Snippet.init?` and the tokenizer — stored invisibly and later
  sent to the shell. Tab and shift-tab now move focus.
- **Wrapping.** The view wrapped inside the 24-pt box, without a
  scroller; long commands disappeared from view. Maintainer decision:
  force single-line and scroll horizontally, as the replaced
  `TextField` did.
- **Accessibility label.** Was lost in the swap. `FormRow` hides its
  visible label precisely because the embedded control carries its
  own (invariant from M6a). Restored from the same localized string.
- **Dead error path.** The sanitizer turns out to be right: the check
  for multi-line input on save had become unreachable. The path and
  key `snippets.editor.error.multiline` were removed from all four
  catalogs.

**The open question that stays open.** Which control gets the Return
key — the text field or the Save button with
`.keyboardShortcut(.defaultAction)` — could not be observed here,
because the app is not started in this environment. Instead of
closing the question with a plausible-sounding claim, the behavior
was made independent of it: the `Coordinator` claims
`insertNewline(_:)` and inserts nothing. If the text field gets the
key, nothing happens; if the button gets it, it saves. Either is
correct for a single-line field. The doc comment names both
possibilities and states explicitly that which one occurs is
unverified.

**New tests.** The reviewer's objection to the sentence "nothing here
is testable" was warranted: for this sheet family, source-scanning
guards already exist. `SnippetCommandEditorGuardTests` follows the
pattern and pins down the substitution lockout, the tab handling,
the accessibility label, and the `insertNewline` claim — each
fail-closed and mutation-tested red.

## Visual check performed (maintainer, 2026-08-19)

Checked and confirmed against the running build: coloring, rounded
border matching the neighboring fields, and horizontal scrolling for
a command wider than the field.

Getting there involved two more bugs, both from the hardening wave,
both found only by looking:

1. **The scroller ate the line.** `hasHorizontalScroller = true`
   without autohide keeps the bar permanently visible; in a 24-pt row
   it takes up roughly two thirds of the height and draws as a dark
   capsule across the empty field. The field looked like a broken
   control. Bar removed — the clip view follows the insertion point
   just fine without it, exactly as with the replaced `TextField`.
2. **The width was pinned.** `autoresizingMask` included `.width`,
   tying the text view's width to the clip view's. Its frame could
   never grow past the visible width, and where nothing is wider than
   the field, there is nothing to scroll: the command ended at the
   right edge, the rest unreachable. `maxSize` was also missing. Now
   only the height tracks the row.

**The lesson behind it.** Both bugs were in the same change that was
meant to turn off wrapping, and neither was visible in the diff — the
final review correctly flagged the wrapping as a finding, and the fix
replaced it with two new bugs that *also* looked plausible. For
`NSViewRepresentable`, this project's rule still holds: the proof is
looking at the running app, not the green suite and not the review.

**Still unverified:** which control gets the Return key (see above)
and the theme change with the sheet open and untouched.

## Lesson: a number in a review finding is also a task to verify

The wrong numbers in the color comment ("six kinds … four colors"; it's
actually seven and six) did not come from the implementer. They stood
in the final review's finding, moved unverified into the coordinator's
ledger, and from there verbatim into the fix instruction — until they
stood as a claim in the source.

The house rule in `CLAUDE.md` has so far said: whoever writes a number
into a comment counts it again in that same moment. This round extends
it to the reverse direction: **a number in a review finding is also a
task to verify.** Whoever passes it along without counting is the
vehicle of the error — the finding sounds just as plausible when passed
along as the comment did when written.

This is the fourth case of the same class in this session. All four sat
in a number or an enumeration; none in prose without cardinality.
