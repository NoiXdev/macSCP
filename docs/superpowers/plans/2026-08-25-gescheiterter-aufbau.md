# Failed connection setup — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A failed connection attempt stays in its tab and offers a way forward, instead of falling back to the form without comment.

**Architecture:** A dedicated surface next to the lost-connection surface, fed from a checkable value; four actions, plus a dialog with the full message.

**Spec:** `docs/superpowers/specs/2026-08-25-gescheiterter-aufbau-design.md`

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English only**; catalog values are translations. All four catalogs, German by hand.
- Conventional Commits; footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **"Retry" runs through the same connection path as a fresh setup.** TOFU stays a hard stop. The allowlist in `ReconnectWiringGuardTests` must cover the new call site.
- **No secret** in log, export, error message, test failure text — and from now on also not in the details dialog.
- No line numbers, no location references in comments; every number counted in the same pass.
- **No attempt may reach the real keychain, session store, or configuration.** `ContentView` takes injected stores — use them.
- Guard: **Mutation tests prove sensitivity, never scope.** Before choosing an anchor, ask *where* the property could be violated from. Scan source free of comments and string literals.
- The app doesn't get launched, nothing gets pushed.

---

### Task 1: Can the details text carry a secret?

**Files:** Test in `Tests/macSCPCoreTests/`; corrections wherever an error originates — **not** in the display.

**The finding that triggers this task:** `ConnectionViewModel` produces its `state = .failed(message:field:)` almost everywhere from processed, localized texts. **One** spot embeds a raw error: `String(format: CoreL10n.string("core.error.unexpected %@"), String(describing: error))`.

So far this had no consequence, because the text only appeared in the form. The details dialog makes it prominent.

- [ ] **Step 1: Count which errors can arrive there.** Enumerate every type that can run into this `catch` — macSCP's own errors, Citadel, NIOSSH, Foundation. The number goes in the report, not in a comment, unless it's counted in the same pass.
- [ ] **Step 2: For each, check whether its text representation can carry a secret** — password, passphrase, key material. macSCP's own errors don't, by project rule; **that needs proving, not assuming.** Look at third-party types individually.
- [ ] **Step 3: Write a test that pins this down.** Against real error values, not made-up ones. If a type is found that *can* carry a secret, **it** gets fixed — the value shouldn't end up in the error in the first place.
- [ ] **Step 4: Full suite green.** — [ ] **Step 5: Commit** — `test(core): pin that a connect failure carries no secret`

---

### Task 2: The checkable value

**Files:** Next to `LostConnectionPlan` in `Sources/MacSCPAppKit/ContentView+Detail.swift`; test in `Tests/macSCPAppKitTests/`.

**Interfaces produced:** `ConnectFailurePlan.content(hasStoredSession:)` → a generic message plus the visible actions.

- [ ] **Step 1: Test first.** Four actions; **"Edit session" appears only** for a stored session, the other three always. The message is generic and carries no details — the same structural safety as `LostConnectionContent`: only `(key, fallback text)` pairs, no field a hostname could fit into.
- [ ] **Step 2: Run it red.** — [ ] **Step 3: Implement.** — [ ] **Step 4: Green.**
- [ ] **Step 5: Commit** — `feat(app): decide what a failed connect offers`

---

### Task 3: The surface, the dialog, the wiring

**Files:** `ContentView+Detail.swift` (`ConnectionSurfacePlan` and the surface), all four catalogs, guard test.

**Interfaces consumed:** Task 1 (safety proved), Task 2 (`ConnectFailurePlan`).

- [ ] **Step 1: Catalog keys** in all four languages, German by hand. Guard test for matching key sets, green.
- [ ] **Step 2: Extend `ConnectionSurfacePlan` for the failed setup.** Today it maps `.connected`, `.degraded`, and `nil` all onto `.form`; the failed attempt needs its own response. An open host-key prompt still overrides everything.
- [ ] **Step 3: Draw the surface** and wire up the four actions. "Retry" calls the **same** connection function as a click in the sidebar. "Edit" leads to the pre-filled form, "Edit session" into the session editor, "Close" closes the tab.
- [ ] **Step 4: The details dialog** with the full message.
- [ ] **Step 5: Guard.** The allowlist over dial and hand-off sites must cover the new "Retry" site — **prove it by mutation**, that a direct dial there turns red.
- [ ] **Step 6: Full suite green, multiple times.** — [ ] **Step 7: Commit** — `feat(app): keep a failed connect in its tab`

---

## What is explicitly not part of this

- The lost-connection case (`.lost`) and its texts stay unchanged.
- A setup that fails on a question only a human can answer has its own path and is not touched.
- No rework of the form and no change to where its error text lives.
