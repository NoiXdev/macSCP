# P3d: The Snippet Picker in the Terminal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The snippet popover in the terminal header becomes a flat list
instead of nested submenus — with a context menu per row, an action
sheet on double-click, and the command shown on hover.

**Architecture:** `SnippetMenuModel` (Core) stays the **one** source for
all four trigger surfaces. Only the **presentation** splits: three surfaces
are real `NSMenu`s and keep `SnippetMenuItems`; the popover gets
a second view over the same model.

**Tech Stack:** Swift 6, `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+,
SwiftUI, Swift Testing, two test targets.

Spec: `docs/superpowers/specs/2026-08-18-p3-order-design.md`, section P3d.

## Global Constraints

- **Code, comments, test names: English.** Internal docs (`docs/`) English.
- **Every new L10n key in all four catalogs** (en/de/fr/pl),
  identical key sets, `plutil -lint` clean.
- **Never a line number in a comment.**
- **No secret in a log, error, or test failure message.**
- **Every factual claim in this plan must be checked against the code.** In
  the current milestone, **fourteen** of my task descriptions
  contained a factual error. The passages quoted below are measured as of
  2026-08-18; if something deviates, **the plan** is wrong — report it,
  don't just adapt.
- **Two checks before every commit**, both:
  1. Would a test stay green if the function returned a constant?
  2. **Which claim of my doc comment does no test observe?**
     In the current milestone, **five** doc comments were simply wrong.
- **The GUI is not launched.** `scripts/package-app` is allowed,
  `scripts/release` is not.
- Conventional Commits, English, footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Full suite green before every commit. Starting point: **2076 tests in 178
  suites** — measure it yourself.

## Measured current state (2026-08-18)

**Four trigger surfaces today all render `SnippetMenuItems`:**

| Location | Kind |
|---|---|
| `MacSCPApp.swift` (menu bar) | real menu |
| `SSHTerminalView.swift` (`NSHostingMenu`, right-click in the terminal) | real menu |
| `SessionSidebar.swift` (`.contextMenu` on the host) | real menu |
| `ContentView+Detail.swift` (header popover) | **list in a panel** |

`SnippetMenuItems` renders one `Menu(entry.snippet.name)` per snippet with
two buttons; inserting carries ⌃⌘n on the first entries
(`SnippetMenuPlan.Entry.insertShortcutDigit`), executing **never** — a
guard (`SnippetMenuItemsKeyboardShortcutGuardTests`) pins that down.

**Only the fourth location can become a flat list.** The three menus
must stay menus. Verify this yourself before rebuilding anything.

---

### Task 1: The row decision as a testable type (Core or a testable app file)

**Why first:** What a row offers — run, insert, both disabled — hangs on
the same model as the menus. This decision does **not** belong in the
view body. In P2 this shape produced an empty window; in P3a it made
empty groups disappear.

**Files:**
- Create: a file for the projection (justify the location: Core if it
  can do without SwiftUI; otherwise a testable app file next to
  `SnippetMenuPlan`)
- Create: the associated tests

**Interfaces:**
- Consumes: `SnippetMenuModel` (Core), the way `SnippetMenuPlan` does
- Produces: a flat projection — sections with a tag heading (or
  without one for untagged) and rows, each with the snippet, a display
  name, and whether its actions are available.

**Take `SnippetMenuPlan` as the model** — it makes the same kind of projection
for the menus, including the rule that a snippet with two tags appears in
**two** groups. Decide deliberately whether the flat list holds to that
too, or shows each row only once, and **justify it in the report**: in a
menu, duplication is harmless; in a scrollable list, it is confusing.

- [ ] **Step 1: Tests first** — empty model, a snippet without tags,
      one with two tags, one that is disabled (no shell / not connected).
- [ ] **Step 2: Run red.**
- [ ] **Step 3: The projection.**
- [ ] **Step 4: Full suite + commit**

```bash
swift test
git commit -m "feat(app): project the snippet model into a flat list"
```

---

### Task 2: The action window

**Files:**
- Create: the window/sheet view
- Modify: the four `Localizable.strings`
- Create/Modify: tests for everything checkable without rendering

**What it shows:** the name, the **command in plain text**, and three actions.

**The shortcuts are decided and not up for negotiation:**
- **Esc** cancels.
- **Return** is bound to **"Insert"**.
- **⌘Return** runs it.

The reasoning is in the spec: Return triggers the default button, and if
"Run" were the default, double-click + Return would be two keystrokes for
a command on someone else's machine. **Pin this mapping**, the way
`SnippetMenuItemsKeyboardShortcutGuardTests` pins the shortcut on the
insert entry — otherwise the next refactor will shift it unnoticed.

New keys (all four catalogs):
- `snippets.action.title` — window title
- `snippets.action.command` — heading above the command
- `snippets.action.insert`, `snippets.action.execute`, `snippets.action.cancel`

- [ ] **Step 1: Shortcut mapping as a test.**
- [ ] **Step 2: The window.**
- [ ] **Step 3: Catalog proof + full suite + commit**

```bash
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
swift test
git commit -m "feat(app): offer insert, run and cancel in one window"
```

---

### Task 3: The popover on the flat list

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift`
- Modify: the four `Localizable.strings`
- Create/Modify: tests

**What changes — and what explicitly does not:**

- The popover renders the projection from Task 1 instead of `SnippetMenuItems`.
- **The three menu surfaces stay untouched.** They keep rendering
  `SnippetMenuItems`. Do not touch them.
- The search field and the regex checkbox stay where they are.

**The three interactions:**
- **Right-click on a row** → Run, Insert, Preview.
- **Double-click** → the window from Task 2.
- **Hover** → the command as a **fixed line at the bottom of the popover**, not a
  tooltip. Measure whether the popover needs to grow taller for that, and
  whether the line truncates or wraps for very long commands — both are a
  decision, not an afterthought.
- **A single click only selects** and triggers nothing.

**"Preview" is to be decided while building:** the same window without
actions, or just highlighting the command line. Look at what is cheaper
and more honest with the existing window, and justify the choice.

**⌃⌘n:** today, the shortcut is attached to the insert entries of the
**menus**. The popover is not a menu. Check whether it can apply there at
all, and if not, say so in the report instead of silently losing it.

- [ ] **Step 1: Rebuild the popover.**
- [ ] **Step 2: Check what is verifiable without rendering** — and state
      clearly in the report what is not. The project has seven source-scanning
      guards, and a review called that pattern past its useful size: an
      eighth only with justification.
- [ ] **Step 3: Catalog proof + full suite + commit**

```bash
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
swift test
git commit -m "feat(app): flatten the terminal snippet picker"
```

---

### Task 4: Phase wrap-up

**Files:**
- Create: `docs/superpowers/specs/2026-08-18-p3d-closeout.md`

- [ ] **Step 1: Measure**

```bash
swift test 2>&1 | tail -3
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
MACSCP_VERSION="1.2.0-dev" MACSCP_BUILD="$(git rev-list --count HEAD)" ./scripts/package-app
```

Start the build **in the background**; then check both binaries, both
resource bundles, all four `.lproj`, `plutil -lint` on the Info.plist,
all three `UTExportedTypeDeclarations`. **The app is not launched.**

- [ ] **Step 2: Report**

It states the measured numbers; **that this is a usability change and
not a security fix** — the picker never had a "one click runs it"
behavior; how the model and the presentation split, and why three
surfaces stay menus; what happened to ⌃⌘n; and **explicitly** that the GUI
was not launched — with the maintainer checklist: the popover without
submenus, the context menu per row, the double-click plus window,
Esc/Return/⌘Return, the command line on hover, and that the menu bar and
right-click in the terminal still work unchanged.

- [ ] **Step 3: Commit**

```bash
git commit -m "docs(app): record the snippet picker phase"
```

---

## Self-review of this plan

**Spec coverage:** flat list → Tasks 1 and 3. Context menu per row,
double-click, hover, single click only selects → Task 3. Action window
with Esc/Return/⌘Return → Task 2. The open items of the spec (preview,
splitting the four surfaces, ⌃⌘n) → named in the tasks as decisions with
a justification requirement, not left open.

**Placeholders:** none. Task 1 deliberately does not name a finished type
definition, because the shape is to be determined from reading
`SnippetMenuPlan`.

**Type consistency:** the projection from Task 1 is used in Task 3; its
name is free there, but must be the same in both places.
