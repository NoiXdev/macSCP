# Backlog: keep-alive as two settings instead of one

**Created:** 2026-08-25, from a review finding on Task 9 of the
connection-state work. Small, clearly scoped — and the cause was a wrong
directive of mine, not an implementation error.

## What holds today

`SettingsStore.keepAliveIntervalSeconds` is **one** stored `Int`: `0`
means "off", any other value gets clamped to 15…600. The UI represents
this via a toggle plus interval field, with a **view-local, unsaved**
memory of the last-used interval.

## The cost, measured

Turn keep-alive off, quit the app, restart, turn it on again — the
self-chosen interval is gone and back at 60. The memory lives only in
the view, and the stored value got overwritten with `0` on turning it
off.

This is disclosed (the explanatory text in the settings section says
so), but it's not good behavior.

## Why it happened this way

**The directive "one stored value, no second setting" came from my own
brief and was wrong.** As a pattern I had explicitly named the
auto-refresh section of the same file — and that consists of **two**
settings:

```
autoRefreshEnabled          Bool
autoRefreshIntervalSeconds  Int, geklemmt 2…300
```

There the interval is always valid, there's no magic value, and a
restart loses nothing. I decided against the house convention that I had
myself cited.

## What would need doing

Introduce `keepAliveEnabled: Bool`, clamp `keepAliveIntervalSeconds` to
15…600 without the `0` special case, and drop the view-local memory
entirely.

**Not done in Task 9, with reason:** the `0` special case is already
shipped in Core and is read by the probe — both checked and closed.
Changing the Core API at the end of a long branch buys a small
improvement for a real regression risk, in code nobody's currently
looking at.

When touching it: a migration is needed, but trivial — a stored `0`
becomes `enabled: false` plus the default interval. And the clamping
belongs, like its neighbor, in **both getter and setter**, so a
hand-edited file produces neither spam nor a dead timer.
