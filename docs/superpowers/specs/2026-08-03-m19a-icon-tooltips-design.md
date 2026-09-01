# M19a — Tooltips on icon actions + a guard (Design/Spec)

**Date:** 2026-08-03
**Status:** approved (maintainer), ready for writing-plans
**Branch:** `develop`
**Trigger:** maintainer question: „Icons für Aktionen sollten beim Überfahren einen Titel bekommen, damit man erkennt, was sie tun — oder?" ("Icons for actions should get a title on hover so you can tell what they do — right?")

## Goal

Every clickable area that shows only a symbol says, on hover, what it
does — and a test makes sure this isn't again left to chance for future
symbols.

## Starting point (verified in the code)

The suspicion holds as a rule, but coverage is already good — the
maintainer's own example is even fully covered:

- **SSH key sheet: 6 of 6 symbols have `.help`** (`SSHKeysSheet.swift`
  :237/:243/:249/:255/:261 for copy, export public, export private,
  rename, delete; :202 for the lock).
- **Toolbar fully covered:** terminal (`ContentView.swift:940`), transfer
  bar (:951), upload (:2689), download (:2706).
- **Tab strip partially:** the `+` has a hint with a shortcut
  (`TabStripView.swift:34`, "New tab (⌘N)"), the `×` does not.

**The two real gaps**, both clickable:

1. `TabStripView.swift:107-108` — `xmark`, closes the tab, appears on
   hovering the row.
2. `SettingsView.swift:511` — `minus.circle`, removes a file association
   in the "Open With" section.

**Deliberately decorative** (symbols that are not a clickable area):
`TransferQueueBar.swift:77` (direction arrow) and :128 (checkmark for
"done"). The ⚠ there (:97) already has a hint text (:100), so does the
error case (:135).

## Scope

### 1. The two missing hint texts

`×` on the tab: "Close Tab (⌘W)" — with the shortcut, because the `+`
next to it does the same. `−` in "Open With": "Remove Association".

Two new keys in **all four** catalogs (`{en,de,fr,pl}.lproj`), typographic
characters in the non-English values.

### 2. The guard

There is **no UI test target** (`Package.swift` has only
`macSCPCoreTests`), so the test has to read the source — the same means as
the `#filePath` lint from M19 (`EmbeddedKeyPorterTests`), which there
prevents a read ahead of the ownership guard.

The test searches `Sources/MacSCPApp/*.swift` for every occurrence of
`Image(systemName:` and `systemImage:` and requires exactly **one** of two
answers for each occurrence:

- a `.help(` sits nearby — done; **or**
- the occurrence is on an explicit list of decorative symbols, each entry
  with file, symbol name and **one line of rationale**.

A new symbol that fits neither drawer turns the test red.

**What the guard achieves and what it doesn't** — this belongs in the doc
comment exactly as stated, not prettied up:

- It does **not** prove that a hint text is good, or even attached to the
  right element. A `.help` on the wrong button nearby passes through.
- The proximity heuristic is coarse; unusual formatting can fool it.
- The list wants maintaining; it is deliberately a brake, not a
  convenience.

It enforces exactly one thing: that **someone made a decision**. That is
the claim, and a source-scanning check with no UI test can deliver no
more. In M19, a lint like this caught real gaps twice — but only after a
reviewer had already defeated it once with a line break. The weakness is
documented, not theoretical; that is why it is named instead of written
away.

## Tests

- **Guard (Core test target, reads App sources):** green against the
  cleaned-up state; red as soon as a symbol appears with no `.help` and
  no list entry. Proof is by mutation — insert a symbol with neither,
  the test must turn red, then revert it.
- **Catalog parity:** both new keys in all four catalogs, checked by grep
  (the parity test only diffs against `en.lproj` and does not see a key
  missing everywhere — exactly this gap shipped a bug in M18).
- App changes are build-verified; there is no runtime test for tooltips.

## Invariants

- No new external dependency.
- Code, comments, test names in English; UI strings EN/DE/FR/PL,
  typographic, no ASCII `"` in non-English values.
- The guard must check nothing other than the per-symbol decision — no
  creeping style linter.

## Not in M19a

- Retrofitting hint texts onto decorative symbols (direction arrow,
  checkmark, type badges) — they stay on the list.
- Introducing a UI test target.
- Hint texts on areas that already carry visible text.

## Files affected

- `Sources/MacSCPApp/TabStripView.swift` — **modify** (tooltip on the `×`).
- `Sources/MacSCPApp/SettingsView.swift` — **modify** (tooltip on the `−`).
- `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings` —
  **modify** (two new keys).
- `Tests/macSCPCoreTests/IconTooltipLintTests.swift` — **create** (guard +
  list of decorative symbols).
