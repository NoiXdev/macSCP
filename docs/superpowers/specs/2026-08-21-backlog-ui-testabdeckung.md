# Backlog: How far can the interface be tested?

**Created:** 2026-08-21, from a maintainer question after the popover bug.
Was a weighing without a decision; **decided as of 2026-08-28** — see the
final section. The rest stands unchanged, so the weighing stays readable
instead of being re-argued.

## Starting point, measured

39 test files in `Tests/macSCPAppKitTests`. **Two** build a real `NSMenu`
(`SnippetMenuItemsTests`, `TerminalContextMenuTests`). **None** renders a
SwiftUI view — no ViewInspector, no `XCUIApplication`, no `NSHostingView`.

That is where today's boundary comes from, and it is not neglect but
construction: decisions move out of the views into plain types
(`SnippetSendPlan`, `SnippetListPlan`, `SnippetMenuModel`,
`SnippetCommandSurvey`), source-scanning guards secure the call sites, and
what remains goes on the visual-inspection list.

## The occasion

The bug from 2026-08-21: the value-prompt **sheet** was requested while the
snippet **popover** was still up, and vanished without a trace. As a
result, via the terminal icon, running and inserting did nothing at all as
soon as a snippet declared a variable.

Notable about it: the context-menu path **was** covered — an `NSMenu` can
be built in tests. The popover path was not. The boundary of coverage and
the location of the bug were the same line.

## The three options

### A. Extend guard tests to presentation order

The same source check that today secures three call sites could pin down:
*dismiss, then next runloop turn, then trigger.* The existing guard for
`triggerSnippet` already checks an **order** (check → alert → `return` →
prompt), so the pattern already exists.

**Would have prevented the bug. Costs no infrastructure.** Weakness: it
checks source text, not behavior — a new trigger site in an unscanned file
would stay invisible.

### B. ViewInspector

A library, runs under `swift test`, inspects the SwiftUI tree and can
trigger button actions. Catches "is the button there, does it call the
right thing".

**Would *not* have caught the bug** — it does not model presentation
timing. Costs a dependency that hangs on SwiftUI internals and breaks on
OS jumps.

### C. XCUITest

Drives the real app and clicks for real. **Would have caught the bug.**

Costs an Xcode project alongside the pure SwiftPM setup and a CI runner
with a GUI session. That is a project of its own, not an add-on — and it
touches `scripts/package-app` and the release chain.

## Second proven case (2026-08-21, connection-state task 4)

The same crack, in a different spot, and this time **proved threefold**.
The probe is supposed to check every connected tab, not just the visible
one. The decision about that was pulled into a checkable type
(`LivenessProbeCoverage.tabsToProbe(from:)`, with no `activeTabID`
parameter, so the restriction cannot even be phrased there). Even so, each
of these three changes brings the bug back, and **all three leave the full
suite green**:

- a `.filter { $0.id == activeTabID }` behind the call at the mount site,
- the restriction in the runner instead of at the mount,
- a runner body that returns `EmptyView()` for non-active tabs.

The reason is always the same: a source scan proves that a call **exists**,
not that it **works**. Three guards on this branch failed one after
another at exactly this boundary — first a label instead of a passed-
through value, then presence instead of location, then location instead of
coverage.

**Decision:** not pursued further. A fourth, cleverer scan would hit the
same boundary. What catches this class is option **C** — and that is a
project of its own, not an add-on. The gap stands as a comment on
`LivenessProbeMountGuardTests`, so it is visible at the site of the
problem rather than only here.

**That makes two proven cases instead of one** — the number the
recommendation below hangs on.

## Recommendation

**A now, consider C as its own project, not B.** B costs a dependency and,
of all things, does not see the bug class that hit us.

Before C, it would be honest to ask how many bugs of this kind there have
been so far. Counted on 2026-08-21: **four**. Two swallowed presentations
(the rejection alert from Snippets part 2, the value sheet from the
popover) and two cases where a guard witnessed a spelling instead of a
property (the build deadline, the probe coverage).

Four is no longer a number that argues for A alone. It argues for taking
C seriously — but as its own project with its own design, not as an
attachment to the next branch.

## Maintainer decision (2026-08-28): C struck for now

**XCUITest will not be pursued.** Not rejected — struck, until an occasion
brings it back. The recommendation above stands, so the weighing stays
readable; from here it is no longer an open task.

The reason is not that the bug class has disappeared. It has grown. C
costs an Xcode project alongside the pure SwiftPM setup, a CI runner with
a GUI session, and touches `scripts/package-app` along with the release
chain — and the release backlog is itself an open item. Pulling in a
second build system while the first has not yet shipped moves the problem
instead of solving it.

**The number above is stale, and in the direction that argues for C.**
"Four" is from 2026-08-21. Provably added since, without recounting here:

- the tab-menu guard that survived five correction rounds, and the
  prefill guard that went silent without anyone noticing — both measured
  on 2026-08-27 and recorded in `CLAUDE.md` under "Guards that name what
  they watch";
- the rename `replacedSession` → `nameConflict`, which left a filter
  naming a symbol that no longer existed (2026-08-28);
- six rounds, six spellings on the connection path, see
  `2026-08-22-backlog-verbindungs-fähigkeit.md`.

**That does not automatically commission A.** The guard A refers to now
exists as `SnippetVariablePromptWiringGuardTests` — what it pins down
about presentation order and what is still missing is to be measured when
taken up, not asserted from here. Whoever takes on A counts first.

**What brings C back:** a bug of this class that reaches a user — not one
a review round catches beforehand. Until then, the path this project has
actually walked since the entry, and which has carried in several recent
tasks, applies: **not a cleverer scan, but a capability boundary** — a
type that cannot let the violation compile. That is neither A nor C, and
it was not yet visible when this entry was filed.
