# Option as Meta, as a setting — design

**Date:** 2026-10-09
**Status:** approved by the maintainer
**Backlog row:** `docs/BACKLOG.md`, the row opening "BUG: the terminal swallows
every character the Option key composes" (recorded 2026-10-09, `c21e9e77`)

## The defect, and whose it is

On a German keyboard the vertical bar, `@`, `~`, `\`, `{`, `}`, `[` and `]` are
all Option combinations, and none of them reaches the shell. The maintainer's
screenshot carries the proof: the prompt showed `(arg: 7)`, readline's
numeric-argument display for `Esc` followed by `7` — and `Esc 7` is what
`Option+7` became. `Option+7` is the vertical bar, which this document names
rather than prints wherever it would otherwise land inside a table cell.

The mechanism is SwiftTerm's own default, not a macSCP decision. At the pinned
revision `d5ee56e1c74777120f3af688600d336de4201bd2`
(`Package.swift`, the `migueldeicaza/SwiftTerm` entry),
`Sources/SwiftTerm/Mac/MacTerminalView.swift:1074` declares

```swift
public var optionAsMetaKey: Bool = true
```

and, while Option is held, sends the ESC prefix instead of the composed
character. SwiftTerm's own `Documentation.docc/Customization.md` states it, and the sentence is quoted here
whole because it does not stop where a shorter quote would want it to:
"Setting `optionAsMetaKey` to `true` makes it send an ESC prefix instead, which
is essential for terminal applications like Emacs that rely on the Meta key".

macSCP never sets the property, so it inherits that default. The checkable form,
scoped to `Sources/` so this document cannot match itself:

```
grep -rln optionAsMetaKey Sources/
```

Run from the repository root on 2026-10-09 it printed nothing, exit status 1.

A workaround exists today and nothing in the UI mentions it: **`Option+Command+O`
toggles the property inside the terminal.** Two sites in that same SwiftTerm file
handle the chord — `MacTerminalView.swift:1103` on the Kitty-protocol path and
`:1139` on the legacy path. That claim rests on the macOS source, not on
SwiftTerm's documentation, which names the chord for the OTHER platform only:
"The iOS view also supports toggling it at runtime with Option-Command-O" is all
`Customization.md` says about it, and a reader who checked the page alone would
conclude the macOS view has no such chord. The chord reaches SwiftTerm because
`MacSCPTerminalView` does not override `keyDown`: it carries six overrides —
`rightMouseDown(with:)`, `menu(for:)`, `mouseDown(with:)`,
`mouseDragged(with:)`, `selectionChanged(source:)` and `mouseUp(with:)` — and
this command, run from the repository root, prints those six lines and no
`keyDown` among them:

```
/usr/bin/grep -n 'override func' Sources/MacSCPAppKit/MacSCPTerminalView.swift
```

## Decisions

Three, taken by the maintainer on 2026-10-09. The backlog row named the first
two as the decision a taker owed.

1. **The default is off** — Option composes characters. The reported defect is
   then gone without the user finding anything, and Meta stays reachable by
   pressing `Esc` and then the key. Someone running Emacs over SSH turns it on.
2. **Global only**, one value in `SettingsStore`. No per-session override: the
   keyboard layout is a property of the person at the keyboard, not of the
   server — unlike the terminal type, which genuinely belongs per session.
3. **`⌥⌘O` stays effective.** The store's value is applied only when it
   changes, so a runtime toggle survives until the setting changes or the view
   is rebuilt.

**What this design does not do**, deliberately: it does not distinguish left
from right Option (SwiftTerm exposes one flag), and it carries no migration
notice for existing users who lose `M-x` on update. The release tooling writes
`CHANGELOG.md` from the commit subjects, and that is where the change is
announced. The maintainer was told this before approving.

## The value

`SettingsStore` gains exactly the shape `terminalCopyOnSelect` already has:

- `Keys.terminalOptionAsMetaKey = "terminalOptionAsMetaKey"`
- `Defaults.terminalOptionAsMetaKey = false`
- `public var terminalOptionAsMetaKey: Bool`, reading through
  `boolValue(for:default:)` and writing through `setBool(_:for:)`

The property is named after SwiftTerm's, the way `terminalCopyOnSelect` is named
after `copyOnSelect`. That is not a matter of style: the wiring guard reads the
assignment line out of the source, and a line whose two sides carry the same
name is one a reviewer can check at a glance.

## The wiring, and why it is not its neighbours' wiring

`SSHTerminalView.makeNSView` assigns `terminal.optionAsMetaKey` from the store
and records the assigned value on the coordinator as `appliedOptionAsMetaKey`.
`SSHTerminalView.updateNSView` assigns **only** when the store's value differs
from that record — the same gate `appliedCursorStyle` and `appliedTheme` already
have in that file.

The record holds **what the store last dictated, not what the view currently
carries**, and the behaviour the maintainer chose falls out of exactly that
asymmetry:

- Press `⌥⌘O`: the view's flag flips, the record stays. No later render writes
  back, so the toggle holds.
- Change the setting: the store's value now differs from the record, so the
  store wins and overrides the chord.
- Rebuild the view (a tab remount): `makeNSView` applies the store's value, and
  the chord is gone with the view that carried it.

The comment above the `copyOnSelect` and `pasteOnRightClick` assignments in
`updateNSView` — "Two plain flags read at the moment of a click, so assigning
them on every render costs nothing and restarts nothing" — stays true of those
two and is **not** extended over the new line. The new line does cost something:
the chord. Its own comment says so, and says which of the two records it is.

## The UI

A new `Section` in `TerminalSettingsTab`, placed after the mouse section, with
one `Toggle` and its own footer. Its own section because the existing one
carries a mouse footer and this is keyboard behaviour.

Strings in all four catalogues under both localized targets' conventions — `en`
as the source text, plus `de`, `fr`, `pl` — looked up through `L10n.string`,
never hardcoded. Two keys: the toggle label and the footer. The German catalogue
addresses the user as **du**.

The footer says three things, each of them measured above: that with the setting
off Option composes characters; that with it on an ESC prefix is sent first; and
that **`⌥⌘O` toggles it for the open terminal** until the setting changes or the
tab is rebuilt. The third is the part with immediate value — the chord exists
today and appears nowhere in the UI.

## Tests

**Core, red first.** Two cases beside the existing
`terminalCopyOnSelectAndPasteOnRightClickDefaultOff` and
`terminalCopyOnSelectAndPasteOnRightClickRoundtripIndependently` in
`SettingsStoreTests`: the new value defaults to
`false`, and it round-trips independently of its two neighbours.

**App, a wiring guard in the existing family.** The guard is **positive only** —
no `!contains` and no filter expected to come back empty, so there is nothing in
it that can go stale in silence. Three checks, each modelled on one that already
exists:

- the `makeNSView` assignment is present, as
  `TerminalMouseWiringGuardTests.theWrapperBuildsTheSubclassAndHandsItBothSettings`
  pins its two
- `appliedOptionAsMetaKey` is present in the source, as
  `TerminalThemeWiringGuardTests.theTerminalViewPaintsItselfFromTheResolvedTheme`
  pins `appliedTheme`
- the settings tab binds `$store.terminalOptionAsMetaKey`, and both new keys are
  in all four catalogues with the German footer in du-form, as
  `theSettingsTabBindsBothTogglesThroughTheCatalogueKeys`,
  `theKeysAreInAllFourCatalogues` and `theGermanFooterAddressesTheUserAsDu` do
  for the mouse pair

**What the tests do not establish.** A source scan proves the lines are there.
It does not prove the gate survives a real `⌥⌘O` press, because that needs a
running app, and this project does not launch the GUI binary from a session. The
plan carries that as a step assigned to the maintainer, named as unverified by
the suite — not as a quietly green checkbox.

## Documentation and the record

`src/content/docs/macscp/guide/terminal.md` in `/Users/noidee/_dev/noix-docs`
gains the setting, its default and the chord — in a worktree on its own branch,
pushed or merged only when the maintainer asks, because that repository is
shared with other products and other sessions.

Backlog row 117 is corrected **in place**, quoting what it withdraws. Its
"**Not a default to flip, a setting to add.**" stands; its closing sentence —
"the decision a taker owes is which way it defaults and whether it is
per-session or global" — is replaced by the decision, with its date and its
outcome. `CHANGELOG.md` is not touched by hand; the release tooling writes it
from the commit subjects.
