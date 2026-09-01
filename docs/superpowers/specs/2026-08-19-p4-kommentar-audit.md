# P4 — Comment truth audit (pilot)

**Trigger:** Across five phases in a row (P2, P3a, P3c, P3e, P3f, P3h) the
full review found comments that assert something the code does not do.
Always the same kind: statements about **callers**, about **call sites**,
about **uniqueness**.

## Measurement

38% of the lines in `Sources/` are comments (16,183 of 42,880). 5,558
comment lines name another identifier in backticks; 331 assert something
about callers or uniqueness. The search pattern was too narrow — in two of
the three pilot files the reviewer found more than it had estimated (39
instead of 28, 42 instead of 17). The 331 is a lower bound.

## Pilot across three files

| File | Last restructured | Claims | wrong |
|---|---|---|---|
| `SessionListViewModel` | M24, quiet since | 34 | **0** |
| `ContentView` | several times this week | 42 | **8** |
| `ConnectionViewModel` | ongoing, M22 → P3g | 39 | **9** |
| **Total** | | **115** | **17 (15%)** |

**Comments do not rot with age, but with the movement of the code they
describe.** The file unchanged since a milestone was error-free, the two
under ongoing restructuring sat at around a fifth.

All 17 wrong spots follow the same mechanism: an extraction, a rename, or
a new caller changes the truth about a *different* file — and the comment
there appears in no diff. Two examples:

- `buildJumpConfig()` said "only caller is `connect()`". That became false
  when P3c pulled out `resolveConfigWithoutDialing()` and created a second
  caller — in the same week, by the same hand.
- The rename `connectStored` → `connect(in:stored:)` (`2153a47`) carried
  along the comments near it, not the two further away in the same file.

## The actual finding: the correction rounds

| Round | Changes | of which wrong |
|---|---|---|
| Correcting the 17 findings | 17 | 3 newly wrong + 3 adjacent ones missed |
| Fixing these 6 | 6 | 4 wrong |
| Third round over these 4 | 4 | 1 wrong |
| Fourth round over this 1 | 1 | 0 — confirmed |

A correction round produces the same error rate as the problem it fixes.
It makes the same mistake as the developer moving the code: **it checks
what it touches, not what depends on it.**

The counter-reader isolated the pattern across all rounds:

> **Every single follow-on error sat in a number or an enumeration. Prose
> without cardinality stayed error-free.**

Round 1: three count/list errors. Round 2: two count errors plus one
misdirected list (the paragraph *next to* the flagged one was changed, the
wrong caller list stayed as it was — with a completion report). Round 3:
another number. The last error is the textbook case: the grep that listed
the third caller was already on screen while "two paths" was being
written.

The reason is close at hand. "Three call sites" is a claim about the rest
of the project that sounds plausible while writing it and is only
refutable by recounting. A sentence about a spot's intent, by contrast,
can be judged from the spot itself.

## Outcome

17 wrong claims corrected, across four rounds with independent
counter-reading after each. Across the entire pass, **zero non-comment
lines** were changed (checked mechanically). Suite unchanged and green,
2139 tests in 188 suites.

## What is NOT done

**No sweep over the remaining ~216 claims** in the 94 smaller files. At
0% errors in the quiet file and this error rate per correction round, the
expected damage would exceed the benefit. They should be checked when the
respective file gets restructured anyway — that is when the context
exists in which truth can be judged.

**No CI guard against dead names**, at least not in the form first
considered. A measurement showed that the conspicuous candidates
(`SSHKeysSettingsTab`, `TransferViewModel`) are **deliberate historical
references** — "removed in M18/T6" is true, not stale. Mechanically that
cannot be told apart from a forgotten rename; such a guard would have a
high false-positive rate and would get switched off after the third
exception.
