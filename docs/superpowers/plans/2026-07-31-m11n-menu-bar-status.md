# M11n — Menu Bar Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An app-wide menu bar icon (`MenuBarExtra`, panel style) that shows active SSH connections and per-connection grouped transfer activity; a click brings the main window forward and activates the tab.

**Architecture:** The tested aggregation logic (a tab's items → a compact summary) lives in Core (`TransferActivitySummary` + `TransferQueueViewModel.activitySummary`). The App layer renders via an app-wide `@Observable` bridge (`MenuBarStatusModel`) following the existing `TabCommands` pattern: `ContentView` mirrors `tabsModel.tabs` into it and sets the window-raising closures; the panel and icon read the `@Observable` tab members directly, so SwiftUI updates live.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftUI `MenuBarExtra` (`.window` style), Swift Testing, macOS 15.

## Global Constraints

- Swift tools 6.0, all targets `.swiftLanguageMode(.v5)`, min. macOS 15.
- Tests: Swift Testing (`@Test`/`#expect`), TDD red→green; new logic ships with tests.
- Code/comments/`reason:` strings **English only**.
- UI strings via the `.strings` catalogs `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`, EN default + DE, lookup via `L10n.string(key, "English default")` / `L10n.text(...)`.
- **Typographic quotes `„ "` and `…` in strings; an ASCII `"` in a German line invalidates the entire DE catalog** (`plutil -lint` + `LocalizableStringsTests` guard against this).
- No app-wide singletons for session state: the menu bar item holds **no** connection state of its own, only the bridge to `tabsModel.tabs`.
- No release/tag without the maintainer's explicit order.
- Baseline before M11n: **891 tests / 61 suites** green.

---

### Task 1: Core — TransferActivitySummary + activitySummary + Settings flag

**Files:**
- Create: `Sources/macSCPCore/Presentation/TransferActivitySummary.swift`
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (computed `activitySummary` + internal static fold)
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift` (`menuBarEnabled`)
- Test: `Tests/macSCPCoreTests/TransferActivitySummaryTests.swift`
- Test: `Tests/macSCPCoreTests/SettingsStoreTests.swift` (append two cases)

**Interfaces:**
- Consumes (existing, verified): `TransferQueueViewModel.Item` with `status: Item.Status` (`.queued`, `.running(TransferProgress)`, terminal) and `direction: TransferDirection`; `Item.Status.isRunning: Bool`; `TransferProgress { bytesTransferred: UInt64; totalBytes: UInt64?; bytesPerSecond: Double?; fraction: Double? }`; `TransferQueueViewModel.displayDirection: TransferDirection?`; `TransferDirection { .upload, .download }`; `Item`'s internal memberwise init (via `@testable import`). `SettingsStore` bool pattern: `boolValue(for:default:)` / `setBool(_:for:)`, `enum Keys`, `enum Defaults`.
- Produces (for Task 2):
  - `public struct TransferActivitySummary: Equatable, Sendable` with `runningCount: Int`, `pendingCount: Int`, `fraction: Double?`, `bytesPerSecond: Double?`, `direction: TransferDirection?` and a public memberwise init.
  - `TransferQueueViewModel.activitySummary: TransferActivitySummary?` (computed, public).
  - `SettingsStore.menuBarEnabled: Bool` (default `true`).

- [x] **Step 1: Failing test for the fold.** New file `Tests/macSCPCoreTests/TransferActivitySummaryTests.swift`. The fold is an internal static function `TransferQueueViewModel.activitySummary(for:direction:)` that folds `[Item]` — testable without driving the queue. A local `makeItem` helper builds `Item`s via the (via `@testable`) visible memberwise init.

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("TransferActivitySummary")
@MainActor
struct TransferActivitySummaryTests {
    private typealias VM = TransferQueueViewModel

    private func makeItem(
        status: VM.Item.Status,
        direction: TransferDirection = .download
    ) -> VM.Item {
        VM.Item(
            id: UUID(),
            fileName: "f",
            direction: direction,
            status: status,
            destinationTabID: nil,
            isEditUpload: false,
            destinationDirectory: "/"
        )
    }

    private func running(_ transferred: UInt64, _ total: UInt64?, rate: Double? = nil) -> VM.Item.Status {
        .running(TransferProgress(bytesTransferred: transferred, totalBytes: total, bytesPerSecond: rate))
    }

    @Test func nilWhenNoActiveItems() {
        let items = [makeItem(status: .finished), makeItem(status: .cancelled)]
        #expect(VM.activitySummary(for: items, direction: nil) == nil)
    }

    @Test func singleRunningWithKnownTotal() {
        let items = [makeItem(status: running(50, 100, rate: 1024))]
        let s = VM.activitySummary(for: items, direction: .download)
        #expect(s?.runningCount == 1)
        #expect(s?.pendingCount == 0)
        #expect(s?.fraction == 0.5)
        #expect(s?.bytesPerSecond == 1024)
        #expect(s?.direction == .download)
    }

    @Test func multipleRunningByteWeightedFraction() {
        // 10/100 and 40/100 → 50/200 = 0.25; rates 1000+3000 = 4000.
        let items = [
            makeItem(status: running(10, 100, rate: 1000)),
            makeItem(status: running(40, 100, rate: 3000)),
        ]
        let s = VM.activitySummary(for: items, direction: .upload)
        #expect(s?.runningCount == 2)
        #expect(s?.fraction == 0.25)
        #expect(s?.bytesPerSecond == 4000)
    }

    @Test func runningWithoutTotalGivesNilFractionButCounts() {
        let items = [makeItem(status: running(500, nil, rate: 2048))]
        let s = VM.activitySummary(for: items, direction: nil)
        #expect(s?.runningCount == 1)
        #expect(s?.fraction == nil)
        #expect(s?.bytesPerSecond == 2048)
    }

    @Test func rateNilWhenNoRunningItemReportsRate() {
        let items = [makeItem(status: running(10, 100, rate: nil))]
        let s = VM.activitySummary(for: items, direction: nil)
        #expect(s?.fraction == 0.1)
        #expect(s?.bytesPerSecond == nil)
    }

    @Test func onlyQueuedItems() {
        let items = [makeItem(status: .queued), makeItem(status: .queued)]
        let s = VM.activitySummary(for: items, direction: .download)
        #expect(s?.runningCount == 0)
        #expect(s?.pendingCount == 2)
        #expect(s?.fraction == nil)
        #expect(s?.bytesPerSecond == nil)
        #expect(s?.direction == .download)
    }

    @Test func mixedRunningAndQueued() {
        let items = [
            makeItem(status: running(25, 100, rate: 500)),
            makeItem(status: .queued),
            makeItem(status: .finished),
        ]
        let s = VM.activitySummary(for: items, direction: .download)
        #expect(s?.runningCount == 1)
        #expect(s?.pendingCount == 1)
        #expect(s?.fraction == 0.25)
    }
}
```

- [x] **Step 2: Red.** `swift test --filter TransferActivitySummary`
  Expected: FAIL — `TransferActivitySummary` and `activitySummary(for:direction:)` do not exist (compile error).

- [x] **Step 3: Create the struct.** New file `Sources/macSCPCore/Presentation/TransferActivitySummary.swift`:

```swift
import Foundation

/// A compact, app-glanceable roll-up of ONE transfer queue's current
/// activity (M11n). Derived purely from the queue's items so it can be unit
/// tested without driving the queue; the menu-bar panel renders one of these
/// per connected tab. `nil` (see `TransferQueueViewModel.activitySummary`)
/// means the queue is idle.
public struct TransferActivitySummary: Equatable, Sendable {
    /// Number of items currently transferring.
    public let runningCount: Int
    /// Number of items queued but not yet running.
    public let pendingCount: Int
    /// Byte-weighted overall progress across the RUNNING items whose total
    /// size is known (Σ transferred / Σ total). `nil` when no running item
    /// knows its total — the UI then omits the percentage rather than
    /// inventing one.
    public let fraction: Double?
    /// Sum of the per-item rates over running items that report one; `nil`
    /// when none reports a rate yet.
    public let bytesPerSecond: Double?
    /// Direction to show the up/down arrow for — the queue's `displayDirection`.
    public let direction: TransferDirection?

    public init(
        runningCount: Int,
        pendingCount: Int,
        fraction: Double?,
        bytesPerSecond: Double?,
        direction: TransferDirection?
    ) {
        self.runningCount = runningCount
        self.pendingCount = pendingCount
        self.fraction = fraction
        self.bytesPerSecond = bytesPerSecond
        self.direction = direction
    }
}
```

- [x] **Step 4: Fold + computed property.** In `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`, insert directly after the existing `displayDirection` computed property (around line 177):

```swift
    /// A compact roll-up of this queue's activity for the menu-bar panel
    /// (M11n). `nil` when the queue is idle. The fold lives in a pure static
    /// helper so it is unit-testable without driving the queue.
    public var activitySummary: TransferActivitySummary? {
        Self.activitySummary(for: items, direction: displayDirection)
    }

    /// Pure fold of a queue's items into a `TransferActivitySummary`. `nil`
    /// when nothing is queued or running. `fraction` is byte-weighted over
    /// running items with a known total; `bytesPerSecond` sums the running
    /// items that report a rate. Internal so tests (`@testable`) can call it
    /// with hand-built items.
    static func activitySummary(
        for items: [Item], direction: TransferDirection?
    ) -> TransferActivitySummary? {
        var runningCount = 0
        var pendingCount = 0
        var sumTransferred: UInt64 = 0
        var sumTotal: UInt64 = 0
        var anyKnownTotal = false
        var sumRate = 0.0
        var anyRate = false

        for item in items {
            switch item.status {
            case .queued:
                pendingCount += 1
            case let .running(progress):
                runningCount += 1
                if let total = progress.totalBytes, total > 0 {
                    sumTransferred += progress.bytesTransferred
                    sumTotal += total
                    anyKnownTotal = true
                }
                if let rate = progress.bytesPerSecond {
                    sumRate += rate
                    anyRate = true
                }
            case .finished, .failed, .cancelled, .skipped, .interrupted:
                continue
            }
        }

        guard runningCount > 0 || pendingCount > 0 else { return nil }

        let fraction = anyKnownTotal ? Double(sumTransferred) / Double(sumTotal) : nil
        let bytesPerSecond = anyRate ? sumRate : nil
        return TransferActivitySummary(
            runningCount: runningCount,
            pendingCount: pendingCount,
            fraction: fraction,
            bytesPerSecond: bytesPerSecond,
            direction: direction
        )
    }
```

- [x] **Step 5: Green.** `swift test --filter TransferActivitySummary`
  Expected: PASS (7/7).

- [x] **Step 6: Failing test for `menuBarEnabled`.** In `Tests/macSCPCoreTests/SettingsStoreTests.swift` append two `@Test` cases (pattern like `defaultsWithoutFile` / `persistenceRoundtrips`):

```swift
    @Test func menuBarEnabledDefaultsTrue() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.menuBarEnabled == true)
    }

    @Test func menuBarEnabledRoundtrips() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.menuBarEnabled = false
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.menuBarEnabled == false)
    }
```

- [x] **Step 7: Red.** `swift test --filter SettingsStore`
  Expected: FAIL — `menuBarEnabled` does not exist (compile error).

- [x] **Step 8: Implement `menuBarEnabled`.** In `Sources/macSCPCore/Settings/SettingsStore.swift`:
  - In `enum Keys` (after `visibleColumns`): `static let menuBarEnabled = "menuBarEnabled"`.
  - In `enum Defaults` (after `updateCheckEnabled`): `static let menuBarEnabled = true`.
  - Beside the other bool vars (e.g. directly after `updateCheckEnabled` around line 263):

```swift
    /// Whether the app shows its menu-bar status item (M11n). Default on.
    public var menuBarEnabled: Bool {
        get { boolValue(for: Keys.menuBarEnabled, default: Defaults.menuBarEnabled) }
        set { setBool(newValue, for: Keys.menuBarEnabled) }
    }
```

- [x] **Step 9: Green + full suite.** `swift test --filter SettingsStore` → PASS; then `swift test`
  Expected: 891 existing + 9 new = **900 tests** green, no new build warnings.

- [x] **Step 10: Commit.**

```bash
git add Sources/macSCPCore/Presentation/TransferActivitySummary.swift \
        Sources/macSCPCore/Presentation/TransferQueueViewModel.swift \
        Sources/macSCPCore/Settings/SettingsStore.swift \
        Tests/macSCPCoreTests/TransferActivitySummaryTests.swift \
        Tests/macSCPCoreTests/SettingsStoreTests.swift
git commit -m "feat: roll up transfer activity and add the menu-bar toggle"
```

---

### Task 2: App — MenuBarExtra panel, bridge, Settings toggle, L10n

**Files:**
- Create: `Sources/MacSCPApp/MenuBarStatusModel.swift`
- Create: `Sources/MacSCPApp/MenuBarStatusPanel.swift` (panel + label + row views)
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (`@State menuBarModel` + `MenuBarExtra` scene)
- Modify: `Sources/MacSCPApp/ContentView.swift` (feed the bridge in `.task` + `.onChange`)
- Modify: `Sources/MacSCPApp/SettingsView.swift` (toggle in "General")
- Modify: `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/MacSCPApp/Resources/de.lproj/Localizable.strings`

**Interfaces:**
- Consumes (Task 1): `TransferActivitySummary`, `TransferQueueViewModel.activitySummary`, `SettingsStore.menuBarEnabled`.
- Consumes (existing, verified): `SessionTab` (`@Observable`) with `id: UUID`, `displayTitle: String`, `isConnected: Bool`, `connectionViewModel: ConnectionViewModel`, `transferQueue: TransferQueueViewModel`; `ConnectionViewModel.state: State` (`.idle`/`.connecting`/`.failed`); `TabsViewModel.tabs: [SessionTab]`, `.activeTabID`, `activate(_:)`; the `TabCommands` pattern in `MacSCPApp`/`ContentView`; `L10n.string`/`L10n.text`; `TransferRateFormatting.compactLabel(bytesPerSecond:etaSeconds:)`.

> **App test note:** As with all prior App-only tasks, there is **no** App test target. "Verification" here means `swift build` without new warnings + reading/tracing the wiring. The risky logic is Core-tested in Task 1.

- [x] **Step 1: Create `MenuBarStatusModel`.** New file `Sources/MacSCPApp/MenuBarStatusModel.swift`:

```swift
import SwiftUI
import macSCPCore

/// App-wide bridge that feeds the menu-bar status item (M11n). It holds NO
/// connection state of its own — `ContentView` mirrors its `tabsModel.tabs`
/// into `tabs` and sets the window-raising closures, exactly like
/// `TabCommands`. The panel and label read the (`@Observable`) `SessionTab`
/// members directly, so SwiftUI updates them live during transfers without a
/// timer.
@MainActor
@Observable
final class MenuBarStatusModel {
    /// Snapshot of the window's tabs, kept in sync by `ContentView`.
    var tabs: [SessionTab] = []
    /// Raise the main window and activate the tab with this id.
    var focusTab: (UUID) -> Void = { _ in }
    /// Raise the main window without forcing a specific tab.
    var showMainWindow: () -> Void = {}

    /// True while any tab is actively transferring — drives the label's
    /// idle/active icon.
    var anyTransferActive: Bool {
        tabs.contains { ($0.transferQueue.activitySummary?.runningCount ?? 0) > 0 }
    }

    /// Number of currently connected tabs — the panel header counter.
    var connectedCount: Int {
        tabs.filter(\.isConnected).count
    }
}
```

- [x] **Step 2: Panel + label + row.** New file `Sources/MacSCPApp/MenuBarStatusPanel.swift`. Uses design tokens/`L10n` like the rest of the app. Status-dot color: green (connected) / yellow (`.connecting`) / red (`.failed`) / secondary (idle).

```swift
import SwiftUI
import macSCPCore

/// The menu-bar button glyph: a calm two-state icon (M11n). Reads
/// `anyTransferActive` (an `@Observable` fold over the tabs) so it flips as
/// soon as a transfer starts or stops.
struct MenuBarStatusLabel: View {
    let model: MenuBarStatusModel

    var body: some View {
        Image(systemName: model.anyTransferActive
            ? "arrow.up.arrow.down.circle.fill"
            : "arrow.up.arrow.down")
    }
}

/// The dropdown panel (`.window` style). One row per tab, grouped transfer
/// line per connection; click a row to raise the window and activate the tab.
struct MenuBarStatusPanel: View {
    let model: MenuBarStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("macSCP").font(.headline)
                Spacer()
                Text(L10n.string("menubar.connections.count", "%d connections")
                    .replacingOccurrences(of: "%d", with: "\(model.connectedCount)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.tabs.isEmpty {
                Text(L10n.string("menubar.empty", "No active connections"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(model.tabs) { tab in
                    MenuBarConnectionRow(tab: tab) { model.focusTab(tab.id) }
                }
            }

            Divider()
            Button(L10n.string("menubar.show.window", "Show macSCP")) {
                model.showMainWindow()
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 300)
    }
}

/// One connection row: title + status dot on line 1, optional grouped
/// transfer summary on line 2. The whole row is a button.
struct MenuBarConnectionRow: View {
    let tab: SessionTab
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(tab.displayTitle).lineLimit(1)
                    Spacer()
                    Text(statusLabel).font(.caption).foregroundStyle(.secondary)
                }
                if let line = transferLine {
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        if tab.isConnected { return .green }
        switch tab.connectionViewModel.state {
        case .connecting: return .yellow
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    private var statusLabel: String {
        if tab.isConnected { return L10n.string("menubar.status.connected", "Connected") }
        switch tab.connectionViewModel.state {
        case .connecting: return L10n.string("menubar.status.connecting", "Connecting…")
        case .failed: return L10n.string("menubar.status.failed", "Failed")
        case .idle: return L10n.string("menubar.status.ready", "Ready")
        }
    }

    /// The grouped transfer line, or nil when the queue is idle.
    private var transferLine: String? {
        guard let summary = tab.transferQueue.activitySummary else { return nil }
        let arrow = summary.direction == .upload ? "↑" : "↓"
        if summary.runningCount > 0 {
            var parts: [String] = []
            let count = L10n.string("menubar.transfer.running", "%d transferring")
                .replacingOccurrences(of: "%d", with: "\(summary.runningCount)")
            parts.append("\(arrow) \(count)")
            if let fraction = summary.fraction {
                parts.append("\(Int((fraction * 100).rounded()))%")
            }
            if let rate = TransferRateFormatting.compactLabel(
                bytesPerSecond: summary.bytesPerSecond, etaSeconds: nil
            ) {
                parts.append(rate)
            }
            return parts.joined(separator: " · ")
        } else {
            return L10n.string("menubar.transfer.queued", "%d queued")
                .replacingOccurrences(of: "%d", with: "\(summary.pendingCount)")
        }
    }
}
```

- [x] **Step 3: Scene + bridge in `MacSCPApp`.** In `Sources/MacSCPApp/MacSCPApp.swift`:
  - Beside the existing `@State` objects (`settingsStore`, `bandwidthLimiter`, …): `@State private var menuBarModel = MenuBarStatusModel()`.
  - Pass `menuBarModel` through to `ContentView` (new parameter, see Step 4).
  - After the `WindowGroup { … }` scene and the `Settings { … }` scene, append a third scene. `settingsStore` is `@Observable`; for the binding, use `@Bindable var settingsStore` locally in a computed `body` helper, or via `@Bindable` on the property. Pattern:

```swift
        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarStatusPanel(model: menuBarModel)
        } label: {
            MenuBarStatusLabel(model: menuBarModel)
        }
        .menuBarExtraStyle(.window)   // scene modifier — NOT on the content view
```

  For the `isInserted:` binding a `Binding<Bool>` is needed. Since `SettingsStore` is `@Observable`: in `MacSCPApp`, obtain `@Bindable var settingsStore` access via a small computed property, e.g.:

```swift
    private var menuBarInserted: Binding<Bool> {
        Binding(get: { settingsStore.menuBarEnabled },
                set: { settingsStore.menuBarEnabled = $0 })
    }
```

  and then `MenuBarExtra(isInserted: menuBarInserted) { … }`. (An explicit `Binding` avoids `@Bindable` subtleties on a `@State`-`@Observable` in the `App`'s `body`.)

- [x] **Step 4: Feed the bridge in `ContentView`.** In `Sources/MacSCPApp/ContentView.swift`:
  - Add a new parameter `let menuBarModel: MenuBarStatusModel` (analogous to how `tabCommands` comes in) and pass it in at the `MacSCPApp` call site.
  - In the existing `.task { … }` (where the `tabCommands` closures are set), add:

```swift
            menuBarModel.tabs = tabsModel.tabs
            menuBarModel.focusTab = { id in
                NSApplication.shared.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
                tabsModel.activate(id)
            }
            menuBarModel.showMainWindow = {
                NSApplication.shared.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            }
```

  - Beside the existing `.onChange` mirrors (like `isActiveTabConnected`), add one for the tab list:

```swift
        .onChange(of: tabsModel.tabs) { _, newTabs in
            menuBarModel.tabs = newTabs
        }
```

  If `tabsModel.tabs` is not directly `Equatable`-`onChange`-capable, observe `tabsModel.tabs.map(\.id)` instead and set `menuBarModel.tabs = tabsModel.tabs` in the handler.

- [x] **Step 5: Settings toggle.** In `Sources/MacSCPApp/SettingsView.swift`, in the "General" tab beside the other toggles (`updateCheckEnabled`/`showHiddenFiles`), with `@Bindable` access to `settingsStore`:

```swift
                Toggle(L10n.string("settings.general.menubar", "Show menu bar icon"),
                       isOn: $settings.menuBarEnabled)
```

  (`$settings` = the `@Bindable` store already present in the view; use the same name as the other toggles in the same block.)

- [x] **Step 6: EN strings.** Append to `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings`:

```
"menubar.connections.count" = "%d connections";
"menubar.empty" = "No active connections";
"menubar.show.window" = "Show macSCP";
"menubar.status.connected" = "Connected";
"menubar.status.connecting" = "Connecting…";
"menubar.status.failed" = "Failed";
"menubar.status.ready" = "Ready";
"menubar.transfer.running" = "%d transferring";
"menubar.transfer.queued" = "%d queued";
"settings.general.menubar" = "Show menu bar icon";
```

- [x] **Step 7: DE strings.** Append to `Sources/MacSCPApp/Resources/de.lproj/Localizable.strings` (typographic `…`, only ASCII `"` as delimiters, none inside the value):

```
"menubar.connections.count" = "%d Verbindungen";
"menubar.empty" = "Keine aktiven Verbindungen";
"menubar.show.window" = "macSCP anzeigen";
"menubar.status.connected" = "Verbunden";
"menubar.status.connecting" = "Verbindet…";
"menubar.status.failed" = "Fehlgeschlagen";
"menubar.status.ready" = "Bereit";
"menubar.transfer.running" = "%d überträgt";
"menubar.transfer.queued" = "%d in Warteschlange";
"settings.general.menubar" = "Menüleisten-Symbol anzeigen";
```

- [x] **Step 8: Catalog lint + parity.**

```bash
plutil -lint Sources/MacSCPApp/Resources/en.lproj/Localizable.strings
plutil -lint Sources/MacSCPApp/Resources/de.lproj/Localizable.strings
```
  Expected: both "OK". Then `swift test --filter Localizable` (the `LocalizableStringsTests` check EN/DE key parity) → PASS.

- [x] **Step 9: Build + full suite.** `swift build` (Expected: `Build complete`, no new warnings besides the four pre-existing Citadel/`_` warnings). Then `swift test` → **900 tests** green.

- [x] **Step 10: Trace verification (no App test target).** Read and confirm:
  - `MacSCPApp` creates exactly one `MenuBarStatusModel` instance and passes it to `ContentView` **and** the `MenuBarExtra` scene.
  - The `isInserted` binding reads/writes `settingsStore.menuBarEnabled`.
  - `ContentView.task` sets `focusTab`/`showMainWindow` and the initial `tabs`; `.onChange` keeps `menuBarModel.tabs` in sync.
  - The panel/row read only `@Observable` members (`displayTitle`, `isConnected`, `connectionViewModel.state`, `transferQueue.activitySummary`) → live update.

- [x] **Step 11: Commit.**

```bash
git add Sources/MacSCPApp/MenuBarStatusModel.swift \
        Sources/MacSCPApp/MenuBarStatusPanel.swift \
        Sources/MacSCPApp/MacSCPApp.swift \
        Sources/MacSCPApp/ContentView.swift \
        Sources/MacSCPApp/SettingsView.swift \
        Sources/MacSCPApp/Resources/en.lproj/Localizable.strings \
        Sources/MacSCPApp/Resources/de.lproj/Localizable.strings
git commit -m "feat: add a menu-bar status item for connections and transfers"
```

---

### Task 3: Close-out verification (coordinator)

- [x] Gated suites: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → green, zero skips (Docker rig from the main checkout, not from a worktree).
- [x] `swift build` clean (no new warnings).
- [x] Whole-milestone Opus review via `review-package <base> HEAD`: focus on (a) the `activitySummary` fold is correct for mixed/unknown totals and pending-only items; (b) bridge synchronization without an app-wide session singleton (mirrors only `tabsModel.tabs`); (c) the `isInserted` binding toggles without a restart; (d) live update without a timer (only `@Observable` reads); (e) `focusTab` reliably brings the window + tab forward even when minimized/hidden; (f) L10n parity + `plutil` + no ASCII `"` in DE. Fix rounds until "Ready to merge: Yes".
- [ ] Visual smoke — maintainer (checklist: icon visible in the menu bar; click opens the panel; connected/connecting/failed tabs show the correct status dot; a running transfer shows the grouped line with ↑/↓/%/rate; clicking a row brings the window + tab forward; "Show macSCP" brings the window forward; the Settings toggle shows/hides the icon without a restart; light/dark; DE ↔ EN).
- [x] Plan checkboxes, ledger, push develop, `gh run watch`, dev build (`MACSCP_VERSION=1.2.0-dev MACSCP_BUILD=<commit> scripts/package-app` → codesign → xattr → `~/Desktop/macSCP-dev.app`), memory. **NO release.**
