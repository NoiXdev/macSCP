# Keep-Alive as Two Settings — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turning keep-alive off and on again across a restart returns to
the interval the user chose — because the interval is its own setting
that never carries "off".

**Architecture:** The house convention of the auto-refresh pair
(`autoRefreshEnabled: Bool` + `autoRefreshIntervalSeconds: Int` clamped
on both ends) applied to keep-alive: `keepAliveEnabled: Bool` +
`keepAliveIntervalSeconds: Int` clamped to 15…600 with **no `0`
sentinel**. A settings file written by an earlier build that stored `0`
with no `keepAliveEnabled` key reads as "off" once; the interval falls
back to the default because the old file carried none. The probe loop
reads the Bool first. The view-local `lastKnownKeepAliveInterval` memory
and `KeepAliveControlPlan` — the machinery that existed only to hide the
sentinel — are deleted, together with the source-scanning guard whose
only reason was that sentinel.

**Tech Stack:** Swift 6, Swift Testing, `SettingsStore` (JSON-backed,
`intValue`/`boolValue`/`setInt`/`setBool`), SwiftUI settings view, four
`.lproj` catalogs via `L10n.string`.

**Source:** `docs/superpowers/specs/2026-08-25-backlog-keepalive-two-settings.md`
— the measured cost ("interval gone after restart") and the admitted cause
(the brief's "one stored value" directive) bind; the connection-state
ledger parked this as "not closable without a SwiftUI harness" — this plan
closes it by removing the thing that needed the harness.

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English only**.
  Conventional Commits; footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- User-visible text in **all four catalogs** (`Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings`)
  via `L10n.string(_:_:)`; German du. `LocalizationParityTests` guards.
- **Migration is read-side and one-way**: a stored `0` with the new key
  absent means "off"; nothing rewrites the file until the user changes a
  setting. A raw JSON fixture proves it — `Codable`/dictionary defaults
  do not.
- **No probe while off, ever.** The probe loop in
  `Sources/MacSCPAppKit/ContentView+Detail.swift` (~line 938) must read
  `keepAliveEnabled` — a loop that still keys on `interval == 0` would
  probe every 15 s for a user who turned it off. Red first.
- **Deleting a guard is a decision with a reason written down**:
  `KeepAliveStepperWiringGuardTests` scanned the stepper for writes that
  bypass `KeepAliveControlPlan`; with no sentinel there is nothing to
  bypass. The commit message says which property the guard protected and
  why it is now structural.
- `.swiftLanguageMode(.v6)`; warning budget 1 on a fresh scratch path.
- TDD, red first. Commit per task. Do not push.

---

### Task 1: The store has two settings, and an old file still reads right

**Files:**
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift` (`Keys`,
  `Defaults`, `keepAliveIntervalSeconds`, new `keepAliveEnabled`, remove
  `clampKeepAliveInterval`'s `0` special case; keep
  `defaultKeepAliveIntervalSeconds` only if a caller remains — count them)
- Test: `Tests/macSCPCoreTests/SettingsStoreTests.swift` (the keep-alive
  cases near line 831 change; new cases)

- [ ] **Step 1: Red.** (a) `keepAliveEnabled` defaults to `true`, round-trips,
  persists as `"keepAliveEnabled": true/false` in the raw file (use the
  file's existing `persistedRaw(dir)` helper). (b) `keepAliveIntervalSeconds
  = 0` now clamps to `15` — the sentinel is gone (the existing test that
  expects `0` flips). (c) **Migration**: write a raw settings JSON with
  `"keepAliveIntervalSeconds": 0` and NO `keepAliveEnabled` key (look at
  how the suite writes raw fixtures — there is a pattern for
  forward-compat tests), open a store on it: `keepAliveEnabled == false`,
  `keepAliveIntervalSeconds == 60`, and the file is byte-unchanged until a
  write. (d) A raw file with `"keepAliveIntervalSeconds": 0` AND
  `"keepAliveEnabled": true` reads enabled with interval `15` — the new key
  wins, `0` is just out of range.
- [ ] **Step 2: Implement.**

```swift
/// Whether the idle-connection probe runs at all. Its own Bool, like
/// `autoRefreshEnabled`: the interval below never carries "off".
///
/// Files written before 2026-09-02 stored "off" as `keepAliveIntervalSeconds
/// == 0` and had no key for this. Read-side migration, once: when this key
/// is ABSENT and the stored interval is `0`, the answer is `false`. Nothing
/// is rewritten until the user changes a setting.
public var keepAliveEnabled: Bool {
    get {
        if let stored = optionalBool(for: Keys.keepAliveEnabled) { return stored }
        return intValue(for: Keys.keepAliveIntervalSeconds, default: Defaults.keepAliveIntervalSeconds) != 0
    }
    set { setBool(newValue, for: Keys.keepAliveEnabled) }
}
```

  (`optionalBool` — use whatever the store offers to tell "absent" from
  "false"; if nothing does, add the smallest private accessor beside
  `boolValue`.) `keepAliveIntervalSeconds` becomes `clamp(value, 15, 600)`
  on both ends, exactly like `autoRefreshIntervalSeconds`; delete
  `clampKeepAliveInterval`. Rewrite the doc comment: the old one explains
  the sentinel.
- [ ] **Step 3: Run** `swift test --filter SettingsStoreTests` — green.
- [ ] **Step 4: Commit** — `feat(settings): keep-alive is an on/off switch and an interval, not one value`

---

### Task 2: The probe loop reads the switch

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift` (~line 938, the
  `guard interval > 0` beat) and any comment there that explains the
  sentinel; `Sources/macSCPCore/Sessions/ConnectionLiveness.swift` (the
  `idleRecheckSeconds` doc comment names "`keepAliveIntervalSeconds` reads
  `0`" — say `keepAliveEnabled` instead)
- Test: find the test that drives the probe loop's idle beat
  (`grep -rn "idleRecheckSeconds\|keepAliveIntervalSeconds = 0" Tests`);
  if the loop is only exercised end-to-end, add the smallest seam-free
  test that proves "off means no probe": a store with
  `keepAliveEnabled = false` and interval 15 must not schedule a probe.

- [ ] **Step 1: Red.** With `keepAliveEnabled = false` and
  `keepAliveIntervalSeconds = 15`, no probe fires (today the loop sees 15
  and probes).
- [ ] **Step 2: Implement.** `guard settingsStore.keepAliveEnabled else { sleep idle; continue }`
  then `let interval = settingsStore.keepAliveIntervalSeconds` (always
  ≥ 15). Comments updated; no number in them that is not counted.
- [ ] **Step 3: Run** the covering tests, then the full unit suite.
- [ ] **Step 4: Commit** — `fix(liveness): the probe loop keys on the switch, not on a zero interval`

---

### Task 3: The settings view binds to the two settings, and the sentinel machinery goes

**Files:**
- Modify: `Sources/MacSCPAppKit/SettingsView.swift` (`SSHSettingsSection`:
  delete `lastKnownKeepAliveInterval` and its `init`, bind the Toggle to
  `store.keepAliveEnabled`, the Stepper to `store.keepAliveIntervalSeconds`
  with `.disabled(!store.keepAliveEnabled)`; delete `enum KeepAliveControlPlan`
  and the doc comments that explain the sentinel; the section footer
  text — it discloses the "interval is lost" behaviour — is rewritten)
- Delete: `Tests/macSCPAppKitTests/KeepAliveControlPlanTests.swift`,
  `Tests/macSCPAppKitTests/KeepAliveStepperWiringGuardTests.swift`
- Modify: the four App catalogs for the footer key (find it: grep
  `keepAlive` in `en.lproj`); render de (du) / fr / pl from `en`
- Test: `LocalizationParityTests` + `GermanAddressFormTests`; any
  source-scanning guard that anchors on `KeepAliveControlPlan` or on the
  footer key (grep `Tests/` for both — a guard whose anchor disappears must
  be updated or deleted with a reason, never left matching nothing)

- [ ] **Step 1: Find every anchor.** `grep -rn "KeepAliveControlPlan\|lastKnownKeepAliveInterval\|keepAlive" Tests Sources` — list what names them; each becomes either a change in this task or a line in the report.
- [ ] **Step 2: Implement** the bindings; delete the plan, the memory, the two test files.
- [ ] **Step 3: Footer text**, `en`: "While on, macSCP checks an idle connection every N seconds. Off keeps the interval for when you turn it back on." (adapt the existing key's wording style; `%lld` if the key is formatted). Four catalogs.
- [ ] **Step 4: Run** `swift test --filter "LocalizationParityTests|GermanAddressFormTests"` and every suite found in Step 1; then the full unit suite; warnings on a fresh scratch path.
- [ ] **Step 5: Commit** — `refactor(settings): bind keep-alive to its two settings and retire the sentinel machinery` — the message names the property `KeepAliveStepperWiringGuardTests` protected (no stray interval written while disabled) and why it is structural now (there is no sentinel; a stepper write while disabled stores an interval and nothing else).

---

### Task 4: The entry closes

**Files:**
- Modify: `docs/superpowers/specs/2026-08-25-backlog-keepalive-two-settings.md`, `docs/BACKLOG.md` (row "Keep-alive as two settings")

- [ ] **Step 1:** Append "Done 2026-09-02": the two settings, the read-side
  migration and its fixture, the probe-loop change, what was deleted and
  why, and the one thing this does not do (no rewrite of an old file until
  the user touches a setting). Update the index row.
- [ ] **Step 2: Commit** — `docs(backlog): close the keep-alive two-settings entry`

## What is explicitly not in this plan

- No change to `LivenessProbePolicy`, probe timeout, or the reconnect behaviour.
- No settings-file version bump; the migration is a read rule for one key.
- No downgrade guarantee: an older build reading a file with
  `keepAliveEnabled: false` and interval 60 would probe — accepted, the
  same shape as the auto-refresh pair.
