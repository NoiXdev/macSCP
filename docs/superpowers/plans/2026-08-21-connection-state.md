# Connection Liveness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A session can say at any time whether it is alive — and offers a way back after a drop, without the app freezing on a dead host.

**Architecture:** One state value per session in Core, driven by a pure decision rule; a probe as `.task(id:)` following the pattern of the existing auto-refresh loop; display as a dot on the tab and as a pane in the tab that covers connecting, operating and loss with **one** mechanism.

**Tech Stack:** Swift 6 in `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+, Swift Testing, SwiftUI + AppKit, Citadel/NIOSSH.

**Spec:** `docs/superpowers/specs/2026-08-21-connection-state-design.md`

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English only.** Internal docs may stay German.
- Conventional Commits; footer on every commit: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- `macSCPCore` imports **no** SwiftTerm and **no** AppKit.
- New user-visible strings in **all four** catalogs (`en`, `de`, `fr`, `pl`); a guard test enforces matching key sets.
- **TOFU stays a hard stop.** Reconnecting uses the same connection path as a fresh connect; no second path is created.
- No secret and no user-typed value in a log, export, error message, or test failure text.
- Teardown only through the existing order `cancelAll` → terminal `shutdown` → `disconnect`; no `deinit` cleanup.
- Never a line number in a comment. A number or enumeration in a comment is **counted in the same pass** in which it is written.
- New logic comes with tests; prove regressions red first.
- The app is **not** launched. `scripts/release` is **not** run.

---

### Task 1: State and decision rule (Core, pure logic)

**Files:**
- Create: `Sources/macSCPCore/Sessions/ConnectionLiveness.swift`
- Test: `Tests/macSCPCoreTests/ConnectionLivenessTests.swift`

**Interfaces:**
- Produces: `ConnectionLiveness` (4 cases), `LivenessProbePolicy.decide(...) -> LivenessProbeAction`, `LivenessProbePolicy.probeTimeout(forInterval:)`, `ReconnectBackoff.delay(forAttempt:)`
- Consumes: nothing

- [ ] **Step 1: Test first — the state and the derivation of the probe deadline**

```swift
@Test func theProbeTimeoutIsHalfTheIntervalCappedAtTen() {
    #expect(LivenessProbePolicy.probeTimeout(forInterval: 60) == 10)
    #expect(LivenessProbePolicy.probeTimeout(forInterval: 20) == 10)
    #expect(LivenessProbePolicy.probeTimeout(forInterval: 12) == 6)
    // Never zero, never longer than the interval: a probe that outlives its
    // own tick would overlap the next one.
    #expect(LivenessProbePolicy.probeTimeout(forInterval: 1) == 1)
}

@Test func aBusyQueueProvesLivenessBetterThanAProbe() {
    #expect(LivenessProbePolicy.decide(queueIsBusy: true, consecutiveFailures: 0) == .skip)
}

@Test func theFirstFailureDegradesAndRetriesTheSecondGivesUp() {
    #expect(LivenessProbePolicy.decide(queueIsBusy: false, consecutiveFailures: 0) == .probe)
    #expect(LivenessProbePolicy.decide(queueIsBusy: false, consecutiveFailures: 1) == .probeAgainNow)
    #expect(LivenessProbePolicy.decide(queueIsBusy: false, consecutiveFailures: 2) == .giveUp)
}

@Test func theBackoffDoublesFromFiveAndStopsAtSixty() {
    #expect(ReconnectBackoff.delay(forAttempt: 1) == 5)
    #expect(ReconnectBackoff.delay(forAttempt: 2) == 10)
    #expect(ReconnectBackoff.delay(forAttempt: 3) == 20)
    #expect(ReconnectBackoff.delay(forAttempt: 4) == 40)
    #expect(ReconnectBackoff.delay(forAttempt: 5) == 60)
    #expect(ReconnectBackoff.delay(forAttempt: 99) == 60)
}
```

- [ ] **Step 2: Run red**

Run: `swift test --filter ConnectionLiveness`
Expected: FAIL, the types do not exist.

- [ ] **Step 3: Implement minimally**

```swift
/// What a session's connection is doing right now. Four states, three
/// colours: `connecting` and `degraded` share amber, because both mean
/// "macSCP does not know yet" and the user's next move is the same — wait
/// or cancel.
public enum ConnectionLiveness: Equatable, Sendable {
    case connecting
    case connected
    /// One probe failed and a second is on its way. Without this state a
    /// single lost packet would look exactly like a severed connection.
    case degraded
    case lost
}

public enum LivenessProbeAction: Equatable, Sendable {
    case skip
    case probe
    case probeAgainNow
    case giveUp
}

public enum LivenessProbePolicy {
    public static func decide(queueIsBusy: Bool, consecutiveFailures: Int) -> LivenessProbeAction {
        if queueIsBusy { return .skip }
        switch consecutiveFailures {
        case 0: return .probe
        case 1: return .probeAgainNow
        default: return .giveUp
        }
    }

    /// Deliberately not a setting: a probe timeout longer than the interval
    /// would let probes overlap, and a user-editable settings file could
    /// produce exactly that.
    public static func probeTimeout(forInterval interval: Int) -> Int {
        max(1, min(10, interval / 2))
    }
}

public enum ReconnectBackoff {
    public static func delay(forAttempt attempt: Int) -> Int {
        guard attempt > 1 else { return 5 }
        return min(60, 5 * (1 << min(attempt - 1, 10)))
    }
}
```

- [ ] **Step 4: Run green**

Run: `swift test --filter ConnectionLiveness`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/ConnectionLiveness.swift Tests/macSCPCoreTests/ConnectionLivenessTests.swift
git commit -m "feat(core): decide when to probe a connection and when to give up"
```

---

### Task 2: The three settings (Core)

**Files:**
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift`
- Test: `Tests/macSCPCoreTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: `ConnectionLiveness.swift` from Task 1 (only for `ReconnectBehaviour`'s neighbourhood, not a requirement)
- Produces: `SettingsStore.reconnectBehaviour`, `.keepAliveIntervalSeconds`, `.connectTimeoutSeconds`, and `ReconnectBehaviour`

**Pattern:** `autoRefreshIntervalSeconds` in the same file. The tests build
the store as `SettingsStore(directory: dir)` over a temporary
directory — that is how `SettingsStoreTests` does it throughout, there is no
factory helper there — getter clamps **and** setter clamps, so that a
hand-edited `settings.json` can produce neither spam nor a dead timer. The
same applies here.

- [ ] **Step 1: Test first**

```swift
@Test func theKeepAliveIntervalIsClampedOnBothEnds() {
    let store = SettingsStore(directory: dir)
    store.keepAliveIntervalSeconds = 5
    // 0 means off and is the ONLY value below the floor that survives.
    #expect(store.keepAliveIntervalSeconds == 15)
    store.keepAliveIntervalSeconds = 0
    #expect(store.keepAliveIntervalSeconds == 0)
    store.keepAliveIntervalSeconds = 9_999
    #expect(store.keepAliveIntervalSeconds == 600)
}

@Test func theConnectTimeoutIsClampedAndDefaultsBelowCitadelsThirty() {
    let store = SettingsStore(directory: dir)
    #expect(store.connectTimeoutSeconds == 10)
    store.connectTimeoutSeconds = 1
    #expect(store.connectTimeoutSeconds == 5)
    store.connectTimeoutSeconds = 10_000
    #expect(store.connectTimeoutSeconds == 120)
}

@Test func reconnectDefaultsToOfferingOnly() {
    #expect(SettingsStore(directory: dir).reconnectBehaviour == .offerOnly)
}
```

- [ ] **Step 2: Run red** — `swift test --filter SettingsStore`, FAIL.

- [ ] **Step 3: Implement**

```swift
/// What macSCP does when a session's connection is found gone.
public enum ReconnectBehaviour: String, CaseIterable, Sendable {
    /// Nothing happens without a click. The default, because reconnecting
    /// re-authenticates — a keychain read, possibly a passphrase — and a
    /// changed host key is a hard stop that needs a person.
    case offerOnly
    case onceThenAsk
    case automatic
}
```

Alongside it the three properties following the pattern of
`autoRefreshIntervalSeconds`. Clamp: interval `0` **or** `15...600`;
timeout `5...120`, default `10`. `ReconnectBehaviour` is stored as a
`String` like `TerminalCursorStyle` and falls back to `.offerOnly` on
unrecognised content.

- [ ] **Step 4: Run green.**

- [ ] **Step 5: Commit** — `feat(core): settle how long a connection may stay silent`

---

### Task 3: Actually passing on the connect timeout (Core)

**Files:**
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift`
- Test: `Tests/macSCPCoreTests/CitadelFileSystemTests.swift`

**Interfaces:**
- Consumes: `SettingsStore.connectTimeoutSeconds`
- Produces: a `connectTimeout` parameter on the connection entry point, passed through to **both** call sites

**The finding:** `SSHClient.connect(host:port:…)` carries
`connectTimeout: TimeAmount = .seconds(30)`. `CitadelFileSystem` calls this
overload **twice** — jump hop and destination — and passes the parameter at
neither. Both sites need to be supplied; one alone would leave a chain with
a jump host at the old wait time.

- [ ] **Step 1: Guard test first** — a source scan following the pattern of
  the existing wiring guards: `SSHClient.connect(` in this file never
  appears without `connectTimeout:`. Fail-closed, with a self-test against
  synthetic source text, and **verified by mutation**: disarm one of the
  two calls, see red, revert, see green. Both results go into the report.

- [ ] **Step 2: Run red.**

- [ ] **Step 3: Implement** — add the parameter at the entry point, pass it
  through to both calls, supply the caller in the app with
  `settingsStore.connectTimeoutSeconds`.

- [ ] **Step 4: Run green** (the full suite, not just the filter).

- [ ] **Step 5: Commit** — `fix(ssh): pass the connect timeout Citadel already offers`

---

### Task 4: State and probe on the session (App)

**Files:**
- Modify: `Sources/MacSCPAppKit/SessionTab.swift` (state on `BrowserSession`/`SessionTab`)
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift` (probe loop)
- Test: `Tests/macSCPAppKitTests/LivenessProbeWiringGuardTests.swift`

**Interfaces:**
- Consumes: Task 1 (`LivenessProbePolicy`), Task 2 (settings)
- Produces: a readable `ConnectionLiveness` per tab

**Pattern already in place:** the auto-refresh loop in
`ContentView+Detail.swift` — `.task(id: session.id)`, settings read
**freshly each round**, skipped rounds keep sleeping. The probe follows the
same shape, so that switching tabs or a teardown cleans it up along with
everything else.

The probe calls `stat` on the **home path determined at connect time**.
`homeDirectoryPath()` already runs at connect; the value is captured there
so the probe does not need a second round trip to find its target.

- [ ] **Step 1: Guard test first** — three assertions about the source
  text, each verified by mutation: the loop reads the interval inside the
  loop (not before it), it asks `LivenessProbePolicy` instead of deciding
  itself, and on `.giveUp` the teardown runs through `ContentView.teardown(_:)`
  instead of its own path.
- [ ] **Step 2: Red.**
- [ ] **Step 3: Implement.** Interval `0` means: no probe at all.
- [ ] **Step 4: Green.**
- [ ] **Step 5: Commit** — `feat(app): probe an idle session and notice when it dies`

---

### Task 5: The dot on the tab (App)

**Files:**
- Modify: `Sources/MacSCPAppKit/TabStripView.swift`
- Modify: all four `Localizable.strings`

**Interfaces:** Consumes: Task 4.

A small dot before `tab.displayTitle`: green for `connected`, yellow for
`connecting`/`degraded`, red for `lost`. **Colour is never the only signal**
— every state gets a `help` text and an `accessibilityLabel`, otherwise the
tab is mute for the colour-blind and for VoiceOver.

- [ ] Step 1: Catalog keys in all four languages, guard test green.
- [ ] Step 2: Draw the dot, colours from `DesignTokens`, no literals.
- [ ] Step 3: Full suite green.
- [ ] Step 4: Commit — `feat(app): show each tab whether its session is alive`

---

### Task 6: Connecting as a cancellable tab state (App)

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift`
- Modify: all four `Localizable.strings`

**Interfaces:** Consumes: Task 3 (timeout), Task 4 (state).

The tab shows "Connecting…" with **Cancel**, the rest of the app stays
usable. Cancel aborts the task and tears down through
`ContentView.teardown(_:)` — not through its own path.

**If, while implementing this, it turns out the main thread is actually
blocked** (rather than just showing a dead pane), that is a separate
finding: report it, do not fix it on the side. The spec explicitly states
that this is unmeasured.

- [ ] Step 1: Catalog keys. — [ ] Step 2: Pane and cancel.
- [ ] Step 3: Full suite. — [ ] Step 4: Commit — `fix(app): let a connection attempt be cancelled`

---

### Task 7: Error view and reconnecting (App)

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift`
- Create: `Tests/macSCPAppKitTests/ReconnectWiringGuardTests.swift`
- Modify: all four `Localizable.strings`

**Interfaces:** Consumes: Task 2 (`reconnectBehaviour`), Task 4, Task 6 (the same pane).

`lost` shows the reason and **"Reconnect"**. Reconnecting calls **the
same** connection path as a fresh connect.

- [ ] **Step 1: Guard test first**, verified by mutation: the reconnect
  calls the shared connection function and not Citadel directly. That is
  exactly the place where a second path would arise — and with it a second
  opportunity to forget TOFU.
- [ ] Step 2: Red. — [ ] Step 3: Implement, incl. `onceThenAsk` and
  `automatic` with `ReconnectBackoff`; an attempt that runs into TOFU or a
  passphrase ends in the error view and is **not** retried.
- [ ] Step 4: Full suite. — [ ] Step 5: Commit — `feat(app): offer the way back after a connection is lost`

---

### Task 8: Transfers during a drop (App/Core)

**Files:**
- Modify: the queue wiring in `Sources/MacSCPAppKit/ContentView+Transfers.swift`
- Modify: all four `Localizable.strings`
- Test: `Tests/macSCPCoreTests/` (reason and retention of the list)

A running transfer fails with the reason "Connection lost";
waiting ones stay in the list and are marked. **Nothing is discarded,
nothing is resumed.**

- [ ] Step 1: Test — after the drop, the number of listed entries is
  unchanged and the reason is set.
- [ ] Step 2: Red. — [ ] Step 3: Implement. — [ ] Step 4: Green.
- [ ] Step 5: Commit — `feat(transfers): keep the queue after a connection is lost`

---

### Task 9: Making settings visible (App)

**Files:**
- Modify: `Sources/MacSCPAppKit/SettingsView.swift`
- Modify: all four `Localizable.strings`

Three controls following the pattern of the auto-refresh section of the
same file; the interval field is disabled when the interval is `0`.

- [ ] Step 1: Catalog keys, guard test green.
- [ ] Step 2: Controls.
- [ ] Step 3: Full suite green.
- [ ] Step 4: Commit — `feat(settings): expose the connection's liveness options`

---

### Task 10: Proof against the Docker rig

**Files:**
- Test: `Tests/macSCPCoreTests/` (behind `MACSCP_ITEST=1`)

**Always start the rig from the main checkout, never from a worktree** —
the seed mount is relative to the compose file.

- [ ] Step 1: A probe against the live counterpart succeeds.
- [ ] Step 2: Stop the container → the probe fails and the state becomes
  `lost`. This is the only test in this branch that produces a real drop;
  without it, the whole detection is only claimed.
- [ ] Step 3: Commit — `test(itest): prove the probe notices a real drop`

---

## What is explicitly out of scope

- No `SO_KEEPALIVE`, no custom bootstrap (spec, section 9).
- No resuming of cancelled transfers.
- No change to TOFU, keychain, or the connection path itself.
- `AgentBackedPrivateKey`'s blocking `semaphore.wait(timeout:)` has been
  seen and is **not** part of this scope.
