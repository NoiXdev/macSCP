# M19a — Tooltips on icon actions + guard implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every clickable area that shows only a symbol says, on hover, what it does — and a test enforces that this stays a deliberate decision for future symbols.

**Architecture:** Two missing `.help` modifiers in the app, plus a source-scanning guard in the only existing test target (`macSCPCoreTests`), which reads the app sources and requires, for every symbol, either a nearby `.help` or a justified entry on a list of decorative symbols.

**Tech Stack:** Swift (SwiftPM, `.swiftLanguageMode(.v5)`), Swift Testing, SwiftUI, macOS 15+.

## Global Constraints

- Swift `.swiftLanguageMode(.v5)`, minimum macOS 15; **no new external dependency**.
- Code, comments, test names: **English**. UI strings EN/DE/FR/PL, typographic characters in non-English values (no ASCII `"`).
- The guard checks **exclusively** whether a decision was made per symbol — it must not turn into a creeping style linter.
- Conventional Commits; footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

**Anchored facts (verified in the code):** The tab `×` sits in `Sources/MacSCPApp/TabStripView.swift:107-113` (`Button(action: onClose)` with `Image(systemName: "xmark")`, `.buttonStyle(.plain)`), visible only when `isHovering`; the `+` next to it has its `.help` at `:34` with the key `tabs.newTabHelp` ("New tab (⌘N)"). **⌘W is confirmed as "Close Tab"** (`MacSCPApp.swift:187-190`, and `KeyboardShortcutsCatalog.swift:36` lists it). The `−` button sits in `Sources/MacSCPApp/SettingsView.swift:506-514` and **already** carries `.accessibilityLabel(L10n.string("settings.openWith.rules.remove", "Remove"))` — so the key already exists (`en.lproj:58`). Deliberately decorative: `TransferQueueBar.swift:77` (direction arrow) and `:128` (checkmark); the ⚠ (`:97`) has its `.help` at `:100`, the error case at `:135`. Model for the guard: the `#filePath` lint in `Tests/macSCPCoreTests/EmbeddedKeyPorterTests.swift` (strip comments → strip whitespace → whitespace-free needles).

**No app test target:** `Package.swift` has only `macSCPCoreTests`. The app changes are build-verified; the guard reads source text.

---

## Task 1: The two missing hover texts

**Files:**
- Modify: `Sources/MacSCPApp/TabStripView.swift`
- Modify: `Sources/MacSCPApp/SettingsView.swift`
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Produces: a new key `tabs.closeTabHelp`. The settings button gets **no** new key.

- [ ] **Step 1: Tab `×`**

Append to the `Button(action: onClose)` block in `TabStripView.swift` (after `.foregroundStyle(...)`, in the same modifier chain as the `+`):

```swift
                .help(L10n.string("tabs.closeTabHelp", "Close tab (⌘W)"))
```

The shortcut belongs in the text because the `+` next to it does the same — it's not decoration: ⌘W is really bound (`MacSCPApp.swift:190`).

- [ ] **Step 2: Settings `−`**

In `SettingsView.swift`, on the same button, **in addition to** the existing `.accessibilityLabel`:

```swift
                        .help(L10n.string("settings.openWith.rules.remove", "Remove"))
```

Reuse the same key — it already exists in all four catalogs. `.accessibilityLabel` is **not** a substitute for `.help`: it labels for VoiceOver but does not produce a hover hint. Record exactly that in a short comment, so the duplication doesn't later get "cleaned up" as redundancy.

- [ ] **Step 3: L10n**

`tabs.closeTabHelp` in **all four** catalogs, sorted directly next to `tabs.newTabHelp`:

EN:
```
"tabs.closeTabHelp" = "Close tab (⌘W)";
```
DE:
```
"tabs.closeTabHelp" = "Tab schließen (⌘W)";
```
FR:
```
"tabs.closeTabHelp" = "Fermer l’onglet (⌘W)";
```
PL:
```
"tabs.closeTabHelp" = "Zamknij kartę (⌘W)";
```

The FR value uses the typographic apostrophe U+2019, not an ASCII `'`.

- [ ] **Step 4: Build + parity**

Run: `swift build && swift test --filter Localizable`
Expected: 0 new warnings, parity green. Additionally confirm via grep that `tabs.closeTabHelp` is present in all four files — the parity test only diffs against `en.lproj` and does not see a key missing everywhere.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPApp
git commit -m "feat: explain the tab close and rule remove icons on hover

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: The guard

**Files:**
- Create: `Tests/macSCPCoreTests/IconTooltipLintTests.swift`

**Interfaces:**
- Consumes: the app sources under `Sources/MacSCPApp/`, via a path derived from `#filePath` (like the M19 lint).

- [ ] **Step 1: Write the lint**

Structure, modeled on `EmbeddedKeyPorterTests`'s source lint (look it up there, in particular how it derives the path from `#filePath` and how it strips comments before searching):

1. Read all `*.swift` under `Sources/MacSCPApp/`.
2. Strip line comments **before** searching (otherwise a commented-out symbol would be counted).
3. Find every occurrence of `Image(systemName:` and `systemImage:`, with file and line number.
4. For each occurrence, it counts as decided if **one** of these holds:
   - within the next **12 lines** there is a `.help(` — the modifier chain of an icon button never runs longer than that in this code (longest actual case: `TabStripView` `+`, 8 lines); or
   - file **and** symbol name are on `decorativeIcons`.
5. Otherwise: `Issue.record` with file, line, symbol name, and a note on what to do (add `.help` **or** put it on the list with a justification).

The list as a constant with a justification per entry, roughly like this:

```swift
    /// Icons that are deliberately decorative — they are not a hit target, so
    /// a hover hint would have nothing to explain. One line of reasoning per
    /// entry: the point of this list is that somebody DECIDED, not that the
    /// list is short.
    private static let decorativeIcons: [DecorativeIcon] = [
        DecorativeIcon(file: "TransferQueueBar.swift", symbol: "arrow.up",
                       reason: "Direction glyph; the row text already says upload or download."),
        // …
    ]
```

Derive the real entries from the actual state, don't guess: everything that, after the additions from Task 1, is still without `.help` belongs on the list with an honest justification. Expected at minimum: the direction arrow and the checkmark from `TransferQueueBar`; check the remaining files yourself and write an individual justification for each finding.

- [ ] **Step 2: Document the limits**

Doc comment on the test that states plainly, without varnish, what it does:

```swift
/// Guards ONE property: that every icon in the app target has been DECIDED
/// about — it carries a hover hint, or it is on the decorative list with a
/// reason. It deliberately does not check that a hint is good, or even that
/// it sits on the right element: a `.help` on a neighbouring control within
/// the window below satisfies the scan. The proximity window is a heuristic
/// and unusual formatting can fool it, and the list needs maintenance by
/// hand. In M19 a lint of this shape caught two real gaps — but only after a
/// reviewer defeated an earlier version of it with a line break, so treat
/// its reach as narrow and its value as "nobody adds an icon without
/// thinking", nothing more.
```

Also record: `.accessibilityLabel` does **not** count as satisfying it. It labels for VoiceOver and does not produce a hover hint — the settings button from Task 1 had exactly that and still needed a `.help`.

- [ ] **Step 3: Green against the cleaned-up state**

Run: `swift test --filter IconTooltipLint`
Expected: PASS.

- [ ] **Step 4: Prove red by mutation**

Insert a symbol without `.help` and without a list entry into an app file (e.g. an `Image(systemName: "star")` in a button), run the test — **must turn red**, and the message must name file, line, and symbol name. Record the output in the report, then revert the mutation and confirm green again.

Second mutation: remove one of the two `.help` calls added in Task 1 — that must also turn red. Then revert.

- [ ] **Step 5: Full suite + commit**

Run: `swift build && swift test`
Expected: all green, 0 new warnings.

```bash
git add Tests/macSCPCoreTests/IconTooltipLintTests.swift
git commit -m "test: require a decision for every icon in the app target

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: Wrap-up

- [ ] **Step 1: Full suite + parity**

Run: `swift build && swift test && swift test --filter Localizable`

- [ ] **Step 2: Visual check in the dev build**

Build and launch the dev build, hover the pointer over a tab's `×` and over the `−` in "Open with": both show their text. Also measure idle CPU (~0%).

- [ ] **Step 3: Review**

Review over `git merge-base develop HEAD`..HEAD. Focus: the guard checks nothing other than the decision; its limits are stated in the doc comment rather than in a promise it doesn't keep; the decorative-symbol list has a real justification per entry; catalog parity via grep, not only via test.

- [ ] **Step 4: Push (on maintainer instruction)**

---

## Self-Review

**1. Spec coverage:** The two gaps → Task 1 ✅ · guard with list → Task 2 ✅ · limits stated → Task 2 Step 2 ✅ · mutation proof → Task 2 Step 4 ✅ · catalog parity via grep → Task 1 Step 4 and Task 3 ✅ · decorative symbols stay without tooltip → Task 2 list ✅

**2. Placeholder scan:** Deliberately open with a clear instruction: the real entries of the `decorativeIcons` list (derive from the actual state, don't guess) and the exact path/comment handling of the M19 lint (look it up there). No "TBD/TODO".

**3. Type consistency:** `tabs.closeTabHelp` (new, 4 catalogs), `settings.openWith.rules.remove` (existing, reused), `decorativeIcons` / `DecorativeIcon(file:symbol:reason:)` — written consistently across both tasks.
