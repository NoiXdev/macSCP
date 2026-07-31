# M11n — Menüleisten-Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein app-weites Menüleisten-Symbol (`MenuBarExtra`, Panel-Stil), das aktive SSH-Verbindungen und pro Verbindung gruppierte Übertragungs-Aktivität zeigt; ein Klick holt das Hauptfenster nach vorn und aktiviert den Tab.

**Architecture:** Die getestete Aggregations-Logik (Items eines Tabs → kompakte Summe) liegt in Core (`TransferActivitySummary` + `TransferQueueViewModel.activitySummary`). Die App-Schicht rendert über eine app-weite `@Observable`-Brücke (`MenuBarStatusModel`) nach dem bestehenden `TabCommands`-Muster: `ContentView` spiegelt `tabsModel.tabs` hinein und setzt die Fenster-holen-Closures; Panel und Icon lesen die `@Observable`-Tab-Member direkt, sodass SwiftUI live aktualisiert.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftUI `MenuBarExtra` (`.window`-Stil), Swift Testing, macOS 15.

## Global Constraints

- Swift-tools 6.0, alle Targets `.swiftLanguageMode(.v5)`, min. macOS 15.
- Tests: Swift Testing (`@Test`/`#expect`), TDD red→green; neue Logik kommt mit Tests.
- Code/Kommentare/`reason:`-Strings **English only**.
- UI-Strings über die `.strings`-Kataloge `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`, EN-Default + DE, Lookup via `L10n.string(key, "English default")` / `L10n.text(...)`.
- **Typografische Anführungszeichen `„ "` und `…` in Strings; ein ASCII-`"` in einer deutschen Zeile macht den ganzen DE-Katalog ungültig** (`plutil -lint` + `LocalizableStringsTests` bewachen das).
- Keine app-weiten Singletons für Session-State: der Menüleisten-Eintrag hält **keinen** eigenen Verbindungszustand, nur die Brücke zu `tabsModel.tabs`.
- Kein Release/Tag ohne ausdrückliche Maintainer-Anordnung.
- Baseline vor M11n: **891 Tests / 61 Suiten** grün.

---

### Task 1: Core — TransferActivitySummary + activitySummary + Settings-Flag

**Files:**
- Create: `Sources/macSCPCore/Presentation/TransferActivitySummary.swift`
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (computed `activitySummary` + internes statisches Fold)
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift` (`menuBarEnabled`)
- Test: `Tests/macSCPCoreTests/TransferActivitySummaryTests.swift`
- Test: `Tests/macSCPCoreTests/SettingsStoreTests.swift` (zwei Fälle anhängen)

**Interfaces:**
- Consumes (bestehend, verifiziert): `TransferQueueViewModel.Item` mit `status: Item.Status` (`.queued`, `.running(TransferProgress)`, terminal) und `direction: TransferDirection`; `Item.Status.isRunning: Bool`; `TransferProgress { bytesTransferred: UInt64; totalBytes: UInt64?; bytesPerSecond: Double?; fraction: Double? }`; `TransferQueueViewModel.displayDirection: TransferDirection?`; `TransferDirection { .upload, .download }`; `Item`s interner memberwise-Init (via `@testable import`). `SettingsStore`-Bool-Muster: `boolValue(for:default:)` / `setBool(_:for:)`, `enum Keys`, `enum Defaults`.
- Produces (für Task 2):
  - `public struct TransferActivitySummary: Equatable, Sendable` mit `runningCount: Int`, `pendingCount: Int`, `fraction: Double?`, `bytesPerSecond: Double?`, `direction: TransferDirection?` und public memberwise-Init.
  - `TransferQueueViewModel.activitySummary: TransferActivitySummary?` (computed, public).
  - `SettingsStore.menuBarEnabled: Bool` (default `true`).

- [ ] **Step 1: Failing test für das Fold.** Neue Datei `Tests/macSCPCoreTests/TransferActivitySummaryTests.swift`. Das Fold ist eine interne statische Funktion `TransferQueueViewModel.activitySummary(for:direction:)`, die `[Item]` faltet — testbar ohne die Queue zu treiben. Ein lokaler `makeItem`-Helfer baut `Item`s über den (via `@testable`) sichtbaren memberwise-Init.

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

- [ ] **Step 2: Rot.** `swift test --filter TransferActivitySummary`
  Expected: FAIL — `TransferActivitySummary` und `activitySummary(for:direction:)` existieren nicht (Compile-Fehler).

- [ ] **Step 3: Struct anlegen.** Neue Datei `Sources/macSCPCore/Presentation/TransferActivitySummary.swift`:

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

- [ ] **Step 4: Fold + computed property.** In `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`, direkt nach der bestehenden `displayDirection`-computed-Property (um Zeile 177) einfügen:

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

- [ ] **Step 5: Grün.** `swift test --filter TransferActivitySummary`
  Expected: PASS (7/7).

- [ ] **Step 6: Failing test für `menuBarEnabled`.** In `Tests/macSCPCoreTests/SettingsStoreTests.swift` zwei `@Test`-Fälle anhängen (Muster wie `defaultsWithoutFile` / `persistenceRoundtrips`):

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

- [ ] **Step 7: Rot.** `swift test --filter SettingsStore`
  Expected: FAIL — `menuBarEnabled` existiert nicht (Compile-Fehler).

- [ ] **Step 8: `menuBarEnabled` implementieren.** In `Sources/macSCPCore/Settings/SettingsStore.swift`:
  - In `enum Keys` (nach `visibleColumns`): `static let menuBarEnabled = "menuBarEnabled"`.
  - In `enum Defaults` (nach `updateCheckEnabled`): `static let menuBarEnabled = true`.
  - Bei den anderen Bool-Vars (z.B. direkt nach `updateCheckEnabled` um Zeile 263):

```swift
    /// Whether the app shows its menu-bar status item (M11n). Default on.
    public var menuBarEnabled: Bool {
        get { boolValue(for: Keys.menuBarEnabled, default: Defaults.menuBarEnabled) }
        set { setBool(newValue, for: Keys.menuBarEnabled) }
    }
```

- [ ] **Step 9: Grün + volle Suite.** `swift test --filter SettingsStore` → PASS; dann `swift test`
  Expected: 891 bestehende + 9 neue = **900 Tests** grün, keine neuen Build-Warnungen.

- [ ] **Step 10: Commit.**

```bash
git add Sources/macSCPCore/Presentation/TransferActivitySummary.swift \
        Sources/macSCPCore/Presentation/TransferQueueViewModel.swift \
        Sources/macSCPCore/Settings/SettingsStore.swift \
        Tests/macSCPCoreTests/TransferActivitySummaryTests.swift \
        Tests/macSCPCoreTests/SettingsStoreTests.swift
git commit -m "feat: roll up transfer activity and add the menu-bar toggle"
```

---

### Task 2: App — MenuBarExtra-Panel, Brücke, Settings-Toggle, L10n

**Files:**
- Create: `Sources/MacSCPApp/MenuBarStatusModel.swift`
- Create: `Sources/MacSCPApp/MenuBarStatusPanel.swift` (Panel + Label + Zeilen-Views)
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (`@State menuBarModel` + `MenuBarExtra`-Szene)
- Modify: `Sources/MacSCPApp/ContentView.swift` (Brücke füttern in `.task` + `.onChange`)
- Modify: `Sources/MacSCPApp/SettingsView.swift` (Toggle in „Allgemein")
- Modify: `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/MacSCPApp/Resources/de.lproj/Localizable.strings`

**Interfaces:**
- Consumes (Task 1): `TransferActivitySummary`, `TransferQueueViewModel.activitySummary`, `SettingsStore.menuBarEnabled`.
- Consumes (bestehend, verifiziert): `SessionTab` (`@Observable`) mit `id: UUID`, `displayTitle: String`, `isConnected: Bool`, `connectionViewModel: ConnectionViewModel`, `transferQueue: TransferQueueViewModel`; `ConnectionViewModel.state: State` (`.idle`/`.connecting`/`.failed`); `TabsViewModel.tabs: [SessionTab]`, `.activeTabID`, `activate(_:)`; `TabCommands`-Muster in `MacSCPApp`/`ContentView`; `L10n.string`/`L10n.text`; `TransferRateFormatting.compactLabel(bytesPerSecond:etaSeconds:)`.

> **Hinweis App-Tests:** Es gibt (wie in allen bisherigen App-only-Tasks) **kein** App-Test-Target. „Verifikation" heißt hier `swift build` ohne neue Warnungen + Lesen/Trace der Verdrahtung. Die riskante Logik ist in Task 1 Core-getestet.

- [ ] **Step 1: `MenuBarStatusModel` anlegen.** Neue Datei `Sources/MacSCPApp/MenuBarStatusModel.swift`:

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

- [ ] **Step 2: Panel + Label + Zeile.** Neue Datei `Sources/MacSCPApp/MenuBarStatusPanel.swift`. Nutzt Design-Tokens/`L10n` wie der Rest der App. Status-Punkt-Farbe: grün (verbunden) / gelb (`.connecting`) / rot (`.failed`) / sekundär (bereit).

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

- [ ] **Step 3: Szene + Brücke in `MacSCPApp`.** In `Sources/MacSCPApp/MacSCPApp.swift`:
  - Neben den bestehenden `@State`-Objekten (`settingsStore`, `bandwidthLimiter`, …): `@State private var menuBarModel = MenuBarStatusModel()`.
  - `menuBarModel` an `ContentView` durchreichen (neuer Parameter, siehe Step 4).
  - Nach der `WindowGroup { … }`-Szene und der `Settings { … }`-Szene eine dritte Szene anfügen. `settingsStore` ist `@Observable`; für das Binding `@Bindable var settingsStore` lokal in einer computed `body`-Hilfsvariable oder via `@Bindable` an der Property. Muster:

```swift
        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarStatusPanel(model: menuBarModel)
        } label: {
            MenuBarStatusLabel(model: menuBarModel)
        }
        .menuBarExtraStyle(.window)   // scene modifier — NOT on the content view
```

  Für das `isInserted:`-Binding braucht es ein `Binding<Bool>`. Da `SettingsStore` `@Observable` ist: in `MacSCPApp` `@Bindable var settingsStore`-Zugriff über eine kleine computed Property herstellen, z.B.:

```swift
    private var menuBarInserted: Binding<Bool> {
        Binding(get: { settingsStore.menuBarEnabled },
                set: { settingsStore.menuBarEnabled = $0 })
    }
```

  und dann `MenuBarExtra(isInserted: menuBarInserted) { … }`. (Explizites `Binding` vermeidet `@Bindable`-Feinheiten auf `@State`-`@Observable` in der `App`-`body`.)

- [ ] **Step 4: Brücke in `ContentView` füttern.** In `Sources/MacSCPApp/ContentView.swift`:
  - Neuen Parameter `let menuBarModel: MenuBarStatusModel` aufnehmen (analog wie `tabCommands` hereinkommt) und im `MacSCPApp`-Aufrufort übergeben.
  - Im bestehenden `.task { … }` (wo `tabCommands`-Closures gesetzt werden) ergänzen:

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

  - Neben den bestehenden `.onChange`-Spiegelungen (wie `isActiveTabConnected`) eine für die Tab-Liste:

```swift
        .onChange(of: tabsModel.tabs) { _, newTabs in
            menuBarModel.tabs = newTabs
        }
```

  Falls `tabsModel.tabs` nicht direkt `Equatable`-`onChange`-fähig ist, stattdessen auf `tabsModel.tabs.map(\.id)` beobachten und im Handler `menuBarModel.tabs = tabsModel.tabs` setzen.

- [ ] **Step 5: Settings-Toggle.** In `Sources/MacSCPApp/SettingsView.swift`, im „Allgemein"-Tab bei den anderen Togglen (`updateCheckEnabled`/`showHiddenFiles`), mit `@Bindable`-Zugriff auf den `settingsStore`:

```swift
                Toggle(L10n.string("settings.general.menubar", "Show menu bar icon"),
                       isOn: $settings.menuBarEnabled)
```

  (`$settings` = der im View bereits vorhandene `@Bindable`-Store; denselben Namen wie die anderen Toggles im selben Block verwenden.)

- [ ] **Step 6: Strings EN.** In `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` anfügen:

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

- [ ] **Step 7: Strings DE.** In `Sources/MacSCPApp/Resources/de.lproj/Localizable.strings` anfügen (typografische `…`, nur ASCII-`"` als Delimiter, keine im Wert):

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

- [ ] **Step 8: Katalog-Lint + Parität.** 

```bash
plutil -lint Sources/MacSCPApp/Resources/en.lproj/Localizable.strings
plutil -lint Sources/MacSCPApp/Resources/de.lproj/Localizable.strings
```
  Expected: beide „OK". Dann `swift test --filter Localizable` (die `LocalizableStringsTests` prüfen EN/DE-Schlüssel-Parität) → PASS.

- [ ] **Step 9: Build + volle Suite.** `swift build` (Expected: `Build complete`, keine neuen Warnungen außer den vier vorbestehenden Citadel/`_`-Warnungen). Dann `swift test` → **900 Tests** grün.

- [ ] **Step 10: Trace-Verifikation (kein App-Test-Target).** Lesen und bestätigen:
  - `MacSCPApp` erzeugt genau eine `MenuBarStatusModel`-Instanz und reicht sie an `ContentView` **und** die `MenuBarExtra`-Szene.
  - `isInserted`-Binding liest/schreibt `settingsStore.menuBarEnabled`.
  - `ContentView.task` setzt `focusTab`/`showMainWindow` und Initial-`tabs`; `.onChange` hält `menuBarModel.tabs` synchron.
  - Panel/Row lesen nur `@Observable`-Member (`displayTitle`, `isConnected`, `connectionViewModel.state`, `transferQueue.activitySummary`) → Live-Update.

- [ ] **Step 11: Commit.**

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

### Task 3: Abschluss-Verifikation (Koordinator)

- [ ] Gated Suiten: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → grün, zero skips (Docker-Rig aus dem Haupt-Checkout, nicht aus einem Worktree).
- [ ] `swift build` sauber (keine neuen Warnungen).
- [ ] Whole-Milestone Opus-Review über `review-package <base> HEAD`: Fokus auf (a) `activitySummary`-Fold korrekt bei gemischten/unbekannten Totals und nur-wartenden Items; (b) Brücken-Synchronisation ohne app-weites Session-Singleton (spiegelt nur `tabsModel.tabs`); (c) `isInserted`-Binding blendet ohne Neustart; (d) Live-Update ohne Timer (nur `@Observable`-Reads); (e) `focusTab` holt Fenster + Tab robust auch bei minimiert/versteckt; (f) L10n-Parität + `plutil` + keine ASCII-`"` in DE. Fix-Runden bis „Ready to merge: Yes".
- [ ] Visueller Smoke — Maintainer (Checkliste: Icon in der Menüleiste sichtbar; Klick öffnet Panel; verbundene/verbindende/fehlgeschlagene Tabs mit richtigem Statuspunkt; laufende Übertragung zeigt gruppierte Zeile mit ↑/↓/%/Rate; Klick auf Zeile holt Fenster + Tab; „macSCP anzeigen" holt Fenster; Settings-Toggle blendet das Icon aus/ein ohne Neustart; hell/dunkel; DE ↔ EN).
- [ ] Plan-Checkboxen, Ledger, Push develop, `gh run watch`, Dev-Build (`MACSCP_VERSION=1.2.0-dev MACSCP_BUILD=<commit> scripts/package-app` → codesign → xattr → `~/Desktop/macSCP-dev.app`), Memory. **KEIN Release.**
