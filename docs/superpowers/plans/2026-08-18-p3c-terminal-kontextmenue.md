# P3c: Terminal from the host context menu — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The context menu of a stored session gets "Open Terminal"
(in macSCP, without the file browser) and "Open in External Terminal" —
both only when the session has a shell.

**Architecture:** The configuration resolution that `connect()` today does
internally becomes its own function, which **both** paths use — connection
setup and the external launch. No second resolution path.

**Tech Stack:** Swift 6, `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+,
SwiftUI, Swift Testing, two test targets.

Spec: `docs/superpowers/specs/2026-08-18-p3-ordnung-design.md`, section P3c.

## Global Constraints

- **Code, comments, test names: English.** Internal docs (`docs/`) German.
- **Every new L10n key in all four catalogs** (en/de/fr/pl), identical
  key sets, `plutil -lint` clean.
- **Never a line number in a comment.**
- **No secret in a log, error, or test failure message.** This phase
  handles credentials — see the dedicated warning below.
- **Every factual claim in this plan must be checked against the code
  before it is used.** In the last milestone, **twelve** of my task
  descriptions contained a factual error about the code. The signatures
  quoted below were measured on 2026-08-18; if something differs, **the
  plan** is wrong — report it, don't adapt around it.
- **Two probes before every commit**, both:
  1. Would a test stay green if the function returned a constant?
  2. **Which claim in my doc comment does no test observe?**
     In the last milestone, **five** doc comments were simply wrong.
     Check every sentence against the code before writing it.
- **The GUI is not launched.** `scripts/package-app` is allowed,
  `scripts/release` is not.
- Conventional Commits, English, footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Full suite green before every commit. Starting point: **2060 tests in
  176 suites** — measure it yourself too.

## Measured current state (2026-08-18)

- `ConnectionViewModel.connect()` does four things in sequence: validate
  the form (schema + jump), `descriptor.makeConfig(values, resolvedSecret)`,
  `attachingJump(to:)`, then dial. On success it remembers
  `lastConnectedConfig` — **only** for the SSH case.
- `ContentView.requestExternalTerminal(for tab:)` today requires
  `tab.isConnected` **and** `tab.connectionViewModel.lastConnectedConfig`.
  An external terminal is thereby reachable only from a tab that is
  **already connected**.
- `ExternalTerminalLauncher.open(config:target:customPath:root:)` needs a
  finished `SSHConnectionConfig`.
- `disconnect` sets `lastConnectedConfig` to `nil` — deliberately, so no
  plaintext password persists past disconnection. **This phase must not
  weaken that property.**
- The sidebar's row context menu today contains "Connect" and "Edit…"
  (`sidebar.connect`, `sidebar.edit`) and calls `onSelect()` / `onEdit()`.
- `BackendDescriptor.descriptor(for:).capabilities.supportsShell` is
  `false` for S3 and WebDAV.
- `SessionTab.showsFiles` and `PaneVisibility` (from P2) determine which
  window halves a session shows; `StoredSession.paneVisibility` holds
  that persisted, default `.filesOnly`.

---

### Task 1: One resolution, two callers (Core)

**Why:** An external terminal needs exactly the first three steps of
`connect()` and must not do the fourth. Writing those three steps a
second time is the mistake this project has paid for repeatedly in
recent phases.

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift`
- Create/Modify: the associated tests

**Interfaces:**
- Produces (names are a suggestion — pick better ones if you see them,
  and write the ones you chose into the report):

```swift
/// The config `connect()` would dial, resolved without dialing anything.
/// Returns nil and sets `state` exactly as `connect()` would when the form
/// or the jump does not validate.
public func resolvedConfigWithoutDialing() -> ConnectionConfig?
```

- [ ] **Step 1: Read first, then cut**

Read `connect()` in full. Determine which part is **pure resolution**
and where connection setup begins. The cut sits before
`state = .connecting`.

While doing so, check whether `state` on failure should mean the same
thing on both paths. An external launch that puts the form into the
error state may be correct — or disruptive, because the form isn't even
visible. **Decide deliberately and justify it in the report.**

- [ ] **Step 2: The equivalence guard first**

A test that proves `connect()` and the new function produce the **same**
configuration — for a simple SSH case, one with a jump, and one where
resolution fails. It is the reason for this task; it must go red if
someone later changes one of the two paths.

- [ ] **Step 3: `connect()` calls it instead of repeating it**

`connect()` uses the new function and keeps its behavior exactly. The
full suite is the regression proof here: `connect()` is extensively
tested in this project.

- [ ] **Step 4: Full suite + commit**

```bash
swift test
git commit -m "refactor(core): resolve a connection config without dialing it"
```

---

### Task 2: The two entries (App)

**Files:**
- Modify: `Sources/MacSCPAppKit/SessionSidebar.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift` and/or the matching
  extension file
- Modify: the four `Localizable.strings`
- Create: `Tests/macSCPAppKitTests/…` (see Step 4)

**Interfaces:**
- Consumes: `resolvedConfigWithoutDialing()` from Task 1

- [ ] **Step 1: The visibility rule — as a testable type, not an `if`**

Whether the two entries appear depends on
`BackendDescriptor.descriptor(for: session.kind).capabilities.supportsShell`.
**Hidden, not greyed out** — a permanently dead entry on an S3 bucket
explains nothing.

This decision belongs as a small, testable function in Core or in a
testable App file, **not** as a condition in the view body. In P2 exactly
this shape produced an empty window, and in P3a it made groups vanish
empty.

New keys (all four catalogs):
- `sidebar.openTerminal` — "Open Terminal"
- `sidebar.openExternalTerminal` — "Open in External Terminal"

- [ ] **Step 2: "Open Terminal"**

Connects like "Connect", but the session comes up **without the file
browser**. The mechanism for that has existed since P2.

**Both questions the spec left open, you answer here — as follows:**
this entry behaves, in everything not concerning window layout, **exactly
like "Connect"**. New tab or active tab, already-connected session, error
case: whatever "Connect" does today, this entry does too. **Measure what
that is**, and write it into the report — not because I don't want to
decide it, but because two entries that behave differently confuse
people for no reason.

- [ ] **Step 3: "Open in External Terminal"**

Resolves the configuration via Task 1 and hands it to
`ExternalTerminalLauncher`. **macSCP itself does not connect.**

**Three things that are mandatory here:**

1. **The existing password notice applies here too.**
   `requestExternalTerminal` shows it once, when the auth is a password —
   because the password gets written into a script. This path must not
   bypass it. Check in the code how it is triggered, and hook into it
   instead of building a second one.
2. **No secret is left lying around.** `disconnect` deliberately sets
   `lastConnectedConfig` to `nil`, so no plaintext password exists past
   disconnection. Your path must create **no** new spot where a resolved
   configuration lives longer than the call. Keep it local.
3. **Errors are shown.** If resolution fails (missing secret, broken
   jump) or the launch fails, the user gets the same kind of message as
   on the existing path — no silent failure.

- [ ] **Step 4: Check what's checkable**

The visibility rule from Step 1 is a pure function and gets real tests.
The wiring of the menu entries is not observable without a rendering
tool — **say that plainly in the report**, instead of implying coverage.
The project has seven source-scanning guards, and a review has called
the pattern past its useful size: an eighth only with justification.

- [ ] **Step 5: Catalog proof + full suite + commit**

```bash
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
swift test
git commit -m "feat(app): open a terminal straight from a host's context menu"
```

---

### Task 3: Phase closeout

**Files:**
- Create: `docs/superpowers/specs/2026-08-18-p3c-abschluss.md`

- [ ] **Step 1: Measure**

```bash
swift test 2>&1 | tail -3
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
MACSCP_VERSION="1.2.0-dev" MACSCP_BUILD="$(git rev-list --count HEAD)" ./scripts/package-app
```

Start the build **in the background**; afterward check both binaries
(`lipo -archs`), both resource bundles, all four `.lproj`, `plutil -lint`
on the Info.plist. **The app is not launched.**

- [ ] **Step 2: Report**

It states the measured numbers; how the resolution was split and what
the equivalence guard holds; what "Connect" does and what "Open Terminal"
therefore matches; that no resolved configuration lives longer than the
call; and **explicitly**, that the GUI was not launched — with the list
for the maintainer: both entries on an SSH session, **neither** on an S3
or WebDAV session, the built-in terminal without the file browser, the
external launch including the password notice the first time.

- [ ] **Step 3: Commit**

```bash
git commit -m "docs(app): record the terminal context menu phase"
```

---

## Self-review of this plan

**Spec coverage:** Two separate entries → Task 2. Only when a shell is
present, hidden instead of greyed out → Task 2, Step 1. Built-in =
without the file browser → Task 2, Step 2. External = no connection of
its own → Task 2, Step 3. The spec's two open questions (new tab?
already connected?) → answered by the rule "behaves like Connect",
measured rather than guessed.

**Placeholders:** none. Task 1 deliberately names no finished body,
because the cut has to be determined from reading `connect()` — that is
a work instruction, not an open point.

**Type consistency:** `resolvedConfigWithoutDialing()` written the same
way in Tasks 1 and 2; the name may change, but then in both places.
