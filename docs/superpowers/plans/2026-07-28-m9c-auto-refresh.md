# M9c — Auto-Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The remote pane of the active tab refreshes itself silently every X seconds (no spinner, selection stays), default 5 s, adjustable (toggle + 2–300 s) in the General tab.

**Architecture:** `refreshQuietly()` in the Core VM (stays `.loaded`, shares filter/sort preparation with `load()`, prunes selection, swallows errors silently, double-guarded against races); two new SettingsStore properties; the timer is a `.task` in the detail tree of the active tab (dies/starts with the `.id(tab.id)` identity from M8a).

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, SwiftUI `.task` + `Task.sleep`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-28-m9c-auto-refresh-design.md` — binding. Branch: **develop**.
- Silent refresh: state stays UNCHANGED at `.loaded` (no flicker, no lock); errors swallowed silently (no state change, no message); guard against non-`.loaded` at the start AND before writing items; selection pruned to paths of the new FILTERED list; filter+sort identical to `load()` (ONE shared private function, no duplicate).
- Settings: `autoRefreshEnabled` default `true`; `autoRefreshIntervalSeconds` default `5`, clamped `2...300` on both set AND read; forward-compatible store pattern as before.
- Timer ONLY in the active tab detail (remote pane), never for background/form tabs or the local pane; reads toggle/interval fresh on every lap.
- All new UI text EN/DE; code + comments English ONLY; no new dependencies.
- Conventional Commits (English), footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + full `swift test` green after every task (starting point 445 tests / 36 suites); gated suites only in T3; tests run SYNCHRONOUSLY in the foreground.
- TDD for Core; App target untestable → T2 delivers a build + a behavior description.

## Schedule

T1 (Core: refreshQuietly + Settings) → T2 (App: Timer + Settings UI) → T3 wrap-up (coordinator).

---

### Task 1: refreshQuietly + Settings properties (Core)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` (refactor `load()` ~line 50–64 + new method), `Sources/macSCPCore/Settings/SettingsStore.swift` (two properties following the `showHiddenFiles` pattern ~line 177)
- Test: `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift`, `Tests/macSCPCoreTests/SettingsStoreTests.swift` (extend existing files; follow the pattern already there)

**Interfaces:**
- Produces (T2 relies on this exactly):
  - `RemoteBrowserViewModel.refreshQuietly() async` (public)
  - `SettingsStore.autoRefreshEnabled: Bool` (get/set, default `true`)
  - `SettingsStore.autoRefreshIntervalSeconds: Int` (get/set, default `5`, clamped `2...300` in both setter AND getter)

- [x] **Step 1: Failing VM tests** (follow the file's mock-FS pattern — helpers for tree mutation/throwing mocks already exist; leave assertions unchanged):

```swift
    // refreshQuietlyUpdatesItemsWithoutStateFlicker:
    //   load() auf Verzeichnis mit [a.txt]; Mock-Tree um b.txt ergänzen;
    //   refreshQuietly(); #expect(items enthalten a+b sortiert, state == .loaded).
    // refreshQuietlyPrunesVanishedAndHiddenFromSelection:
    //   Verzeichnis [a.txt, b.txt, .hidden]; showHiddenFiles = true; load();
    //   selectedItems = [a, b, .hidden]; Mock: b.txt entfernen; showHiddenFiles = false;
    //   refreshQuietly(); #expect(selectedItems.map(\.name) == ["a.txt"])
    //   (b verschwunden, .hidden nun gefiltert).
    // refreshQuietlySwallowsErrors:
    //   load() ok; Mock ab jetzt werfend (connectionFailed-Form des Mocks);
    //   refreshQuietly(); #expect(state == .loaded, items unverändert).
    // refreshQuietlyBailsWhenNotLoaded:
    //   state == .failed (load gegen werfenden Mock); Mock heilen;
    //   refreshQuietly(); #expect(state bleibt .failed, items leer)
    //   — der stille Refresh repariert NICHT (nur „Erneut versuchen" tut das).
```

- [x] **Step 2: Prove red.** `swift test --filter RemoteBrowserViewModelTests` → FAIL (method missing).

- [x] **Step 3: Implementation.** In `RemoteBrowserViewModel`:

```swift
    /// Shared display pipeline for `load()` and `refreshQuietly()` — the
    /// hidden-files filter and sort MUST stay identical between the two.
    private func displayItems(from listed: [RemoteFileItem]) -> [RemoteFileItem] {
        let visible = showHiddenFiles
            ? listed
            : listed.filter { !$0.name.hasPrefix(".") }
        return Self.sortedForDisplay(visible)
    }

    /// Silent background refresh (M9c): re-lists the current directory and
    /// swaps the rows WITHOUT touching `state` — no spinner, no hit-test
    /// block, selection preserved (pruned to paths still visible, which
    /// also closes the M7a backlog note about the hidden filter). Errors
    /// are swallowed silently: a dead server must not paint a failure
    /// screen every few seconds — any manual action still surfaces real
    /// problems. Both guards are needed: the state can change while the
    /// listing is in flight (e.g. a manual `load()` or `open()`), and the
    /// late writer must lose.
    public func refreshQuietly() async {
        guard state == .loaded else { return }
        let path = currentPath
        guard let listed = try? await fs.list(path: path) else { return }
        guard state == .loaded, currentPath == path else { return }
        items = displayItems(from: listed)
        let visiblePaths = Set(items.map(\.path))
        selectedItems = selectedItems.filter { visiblePaths.contains($0.path) }
    }
```

Switch `load()` over to `items = displayItems(from: listed)` (remove the filter/sort lines there). In `SettingsStore` (add key/default entries following the file's pattern; look up the file's `intValue`/`setInt` helpers — analogous helpers exist for the transfer settings):

```swift
    /// Auto-refresh of the active tab's remote pane (M9c). Default ON.
    public var autoRefreshEnabled: Bool {
        get { boolValue(for: Keys.autoRefreshEnabled, default: Defaults.autoRefreshEnabled) }
        set { setBool(newValue, for: Keys.autoRefreshEnabled) }
    }

    /// Interval in seconds, clamped to 2...300 on BOTH ends so a hand-edited
    /// settings.json cannot produce SFTP spam or a dead timer.
    public var autoRefreshIntervalSeconds: Int {
        get { min(300, max(2, intValue(for: Keys.autoRefreshIntervalSeconds, default: Defaults.autoRefreshIntervalSeconds))) }
        set { setInt(min(300, max(2, newValue)), for: Keys.autoRefreshIntervalSeconds) }
    }
```

- [x] **Step 4: Failing Settings tests** (file's pattern): defaults (true/5), setter clamping (1→2, 9999→300), getter clamping (write raw value 0 resp. 100000 directly into the JSON file the way the forward-compatibility tests do → reading yields 2 resp. 300), roundtrip, an old settings.json without the keys loads with defaults. Red → implement → green.

- [x] **Step 5: Full suite + commit.** `swift test` → 445 + ~8 (record the actual count).

```bash
git add -A
git commit -m "feat: add a silent remote refresh and its settings"
```

---

### Task 2: Timer in the active tab + Settings UI (App)

**Files:**
- Modify: `Sources/MacSCPApp/ContentView.swift` (timer `.task` in the detail tree), `Sources/MacSCPApp/SettingsView.swift` (General tab ~line 41), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: none (App target; smoke test in T3)

**Interfaces:**
- Consumes: `refreshQuietly()`, `autoRefreshEnabled`, `autoRefreshIntervalSeconds` (T1); the `.id(tab.id)` detail identity (M8a) in `ContentView.detail`.

**Behavior requirements:**
1. In the detail tree of the active tab, INSIDE the `.id(tab.id)` group and only on the connected branch (`if let session = tab.session`), attach:

```swift
        .task {
            // Auto-refresh loop (M9c): lives inside the tab's `.id` identity,
            // so switching tabs (or disconnecting) cancels it and the next
            // active tab starts its own. Reads the settings fresh every lap
            // so changes apply without restart; skipped laps just sleep on.
            while !Task.isCancelled {
                let seconds = settingsStore.autoRefreshIntervalSeconds
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, settingsStore.autoRefreshEnabled else { continue }
                await session.remote.refreshQuietly()
            }
        }
```

   (Placement: on the same view as the existing `.task { await viewModel.load() }` style — specifically on the browser layout container on the connected branch; NOT on the form branch. `refreshQuietly` guards itself against `.loaded` — no extra state needed.)
2. Settings UI in the General tab below the hidden-files toggle: a toggle (key `settings.general.autoRefresh` — EN "Auto-refresh remote view", DE „Remote-Ansicht automatisch aktualisieren") + a stepper/text-field row (key `settings.general.autoRefreshInterval %lld` — EN "Every %lld seconds", DE „Alle %lld Sekunden"; look up and follow the form style of the existing transfer-settings rows — the number-field-plus-clamping pattern exists there), field disabled when the toggle is off.
3. Keys in BOTH catalogs; grep cross-check.

- [x] **Step 1:** Timer. **Step 2:** Settings UI + keys. **Step 3:** `swift build` (0 errors, no new warnings) + full `swift test` (as of T1). **Step 4:** Commit `feat: auto-refresh the active remote pane on an interval`.

---

### Task 3: Final verification (coordinator)

- [ ] Gated suites (rig from the main checkout): `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` ⇒ fully green, zero skips.
- [ ] Visual smoke (dev wrapper; maintainer may test this themselves): connect → create a file on the server via `docker exec` → appears within ~5 s WITHOUT spinner/selection loss; hold selection during a refresh; delete the file server-side → disappears from the list AND from the selection; change the interval in Settings (takes effect without restart), toggle off → quiet; tab switch: only the active tab polls (docker logs, or the second tab stays stale until switched to); form tab/disconnected: no polling; sheets/menu open during a refresh → undisturbed; failure case: stop the rig → NO error-screen flicker, manual action shows the error.
- [ ] Plan checkboxes, ledger, Opus whole-branch final review (base = commit before T1), fixes, push develop, CI, rig `stop`, memory update, milestone summary (+ M9d terminal rendering next; release bundling still open).
