# Toggling panes from the tab menu — Design

**Status:** 2026-08-27. Implements section **B** from
`docs/superpowers/specs/2026-08-27-backlog-tab-polish.md`, and
thereby also answers **I4** from the tab menu's closing review.

---

## Two corrections to the backlog entry, both measured

The entry rested on two assumptions. Both are wrong, and both make this
change **smaller**, not bigger.

**1. The "two truths" were already merged.** The doc comment on
`PaneVisibility` defers the relationship to `TerminalPanelViewModel.isVisible`
to "a later task's decision". That task has since happened:
`SessionTab.effectivePaneVisibility(terminalIsVisible:hasShell:)` is the one
assembly point —

```swift
PaneVisibility(showsFiles: showsFiles, showsTerminal: terminalIsVisible && hasShell)
```

— and its own comment states that there must be **only one**. The comment
on `PaneVisibility` is therefore stale and is corrected in this change.

**2. `terminalTarget` explicitly does NOT belong here.** I4 read as an
inconsistency ("the toolbar and ⌘T follow the setting, the tab menu
doesn't"). Measured, only the toolbar button follows it. The "Terminal"
menu carries two entries that **deliberately never** change with the
setting, with the rationale in the source:

> …so that switching never takes a capability away.

Making the tab menu entry follow the setting would therefore have made it
**inconsistent**, not more consistent — and would have taken the built-in
pane out of this menu for a user who switches to an external terminal.
**I4 is thereby answered: the entry does not follow the setting, and that
is correct as is.**

---

## The rule that decides everything else

**Show only what is possible.** No grayed-out entry — an entry you can see
and cannot use confuses more than a missing one is missed (maintainer,
2026-08-27). That is the same rule the rest of this menu's entries have
followed since `519c2df`.

For the pane toggles that means two things:

- If an action isn't possible, **the entry is absent** — not `.disabled`.
- The label names the action that IS possible: **"Show Files"**
  or **"Hide Files"**, depending on state. One entry per pane, a changing
  label.

This deliberately differs from the menu bar's "Terminal" menu, which grays
its entries out. There it's correct because a menu bar has to keep its
structure; a context menu has no such obligation.

## What the menu will carry

| Entry | Meaning | Appears when |
|---|---|---|
| Show/Hide Files | pane toggle | `toggleState(for: .files, …).isEnabled` |
| Show/Hide Terminal | pane toggle, **always the built-in one** | `toggleState(for: .terminal, …).isEnabled` |
| Open External Terminal | its own path, **always external** | connected **and** `supportsShell` |

The former one-way entry **"Open Terminal" is removed** and replaced by the
toggle. It only showed the pane and returned silently if the terminal was
already visible — this menu had no way back to the files.

**Why the invariant makes the toggles correct on its own:**
`PaneVisibility` cannot represent "neither half visible"; its initializer
repairs that to "files win". `toggleState` therefore reports
`isEnabled == false` for the **only currently visible** half. Per the rule
above, that entry then simply doesn't appear — so there is no click that
could empty the window, without anyone having to write a second check for
it anywhere.

**Both halves visible** is a valid state, and the pair expresses it
correctly: then both entries appear, each hiding its own half. A single
"Terminal ↔ Files" toggle could not do that.

## Where the facts come from

None of this is recomputed. `TabContextMenu.entries(…)` receives the
finished answer as input, the same way it already receives `supportsShell`,
`isAdHoc` and `isConnected` today — the view decides nothing, and
`ConnectionKind` appears nowhere.

The value that goes in comes from `effectivePaneVisibility(…)` and
`toggleState(for:hasShell:)`, i.e. from exactly the functions the toolbar
also reads from. That means the toolbar, the menu bar, and the tab menu
cannot drift apart — they answer the same question in the same place.

What a click does is answered by `applyingClick(on:hasShell:)`; for the
terminal, `TerminalPanelViewModel.toggle()` remains the only write path,
because it owns the shell's lifecycle (it opens it when showing). A bare
Bool write would bypass that — the source already states this explicitly
at that spot, and this change does not alter it.

## What no test in this project can see

Testable is which entries appear for which state and what they're named —
that's a value in Core with tests, like the rest of this menu's entries.

**Not testable** is that clicking the entry actually shows or hides the
pane in the running app. That's decided by a maintainer's look, and it's
not counted as "green".

---

## What is explicitly excluded

- No change to `terminalTarget`, to the toolbar, or to the menu bar's
  "Terminal" menu.
- No graying out in the tab menu — the rule is omission.
- No change to how `TerminalPanelViewModel.isVisible` is written:
  `toggle()` remains the only path.
- No answer to I5 (saving overwrites a same-named entry) — a separate item.
