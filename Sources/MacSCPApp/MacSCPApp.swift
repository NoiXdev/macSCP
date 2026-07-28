import SwiftUI
import macSCPCore

/// Command bridge (M8a/T4): the WindowGroup's `.commands` closures are built
/// by `MacSCPApp`, which holds no reference to `ContentView` — the menu
/// items call these closures, and `ContentView` assigns them (in `.task`) to
/// its own tab-lifecycle methods. `@Observable` for consistency with the
/// app's other cross-layer bridges (`ConflictPromptBridge`); the closures
/// themselves are read once per invocation, not observed reactively.
@MainActor
@Observable
final class TabCommands {
    var newTab: (() -> Void)?
    var closeActiveTab: (() -> Void)?
    var selectTab: ((Int) -> Void)?
    /// Sessions menu bridge (M10a/T2): "Known Hosts…" opens the management
    /// sheet; the export/import closures bind to `ContentView`'s EXISTING
    /// M9a handlers (`exportSheetItem`/`showImportFileImporter`) — the
    /// sidebar's own "Export All…"/"Import…" entries are untouched.
    var showKnownHosts: (() -> Void)?
    /// "Logins…" (M10b/T3) — same bridge shape/key-window guard as
    /// `showKnownHosts` above, opens the login-sets management sheet.
    var showLogins: (() -> Void)?
    var exportAllSessions: (() -> Void)?
    var importSessions: (() -> Void)?
}

@main
struct MacSCPApp: App {
    /// Single instance for the whole app — passed to `ContentView` and the
    /// `Settings` scene below (M5c/T3: no singleton, per the v2 multi-window
    /// rule).
    @State private var settingsStore = SettingsStore(directory: SettingsStore.defaultDirectory)
    /// App-global bandwidth ceilings (M8a/T2): one shared instance for the
    /// whole app, passed to `ContentView` so every tab's queue (T3) resolves
    /// its throttle from the same buckets — limits apply in aggregate across
    /// tabs, not per tab.
    @State private var bandwidthLimiter = BandwidthLimiter()
    /// App-wide per-session audit log persistence (M9b) — one instance for
    /// the whole app, passed to `ContentView` (no singleton, same pattern as
    /// `settingsStore`/`bandwidthLimiter` above). A stateless struct over a
    /// fixed directory, so a plain default-initialized `@State` is enough.
    @State private var auditStore = AuditLogStore(directory: AuditLogStore.defaultDirectory)
    /// Tab menu command bridge (M8a/T4) — see `TabCommands`.
    @State private var tabCommands = TabCommands()

    init() {
        // Sweep any orphaned edit temp directories left behind by a
        // hard-killed previous run (M6a) — first, before anything else
        // touches the temp tree.
        EditSessionManager.sweepOrphanedTempDirectories()
        // Without an app bundle (started via `swift run`) the process runs
        // as an accessory — only the regular policy brings a window and a
        // Dock icon. A real `.app` bundle lands in M6.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        // The minimum size depends on the connection state (compact form vs.
        // browser) — it lives conditionally in `ContentView` instead of here
        // globally (M5c/T0).
        WindowGroup("macSCP") {
            ContentView(
                settingsStore: settingsStore, bandwidthLimiter: bandwidthLimiter,
                auditStore: auditStore, tabCommands: tabCommands)
        }
        .commands {
            // Replaces the default "New Window" (⌘N) — this is a single-window,
            // multi-tab app (M8a/T4): ⌘N opens a new TAB instead. "Close Tab"
            // (⌘W) lives in the same group; it shadows the system "Close"
            // command with the same shortcut (there is no dedicated
            // `CommandGroupPlacement` to replace it outright), routing through
            // `tabCommands.closeActiveTab` which falls back to closing the
            // window when the active tab is the last, unconnected one.
            CommandGroup(replacing: .newItem) {
                Button(L10n.string("menu.newTab", "New Tab")) {
                    tabCommands.newTab?()
                }
                .keyboardShortcut("n", modifiers: .command)
                Button(L10n.string("menu.closeTab", "Close Tab")) {
                    tabCommands.closeActiveTab?()
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            // ⌘1–⌘9: jump to tab n (1-indexed); no-op past the tab count
            // (`ContentView.selectTab(atIndex:)`). ⌃Tab cycling was left out
            // — it could not be verified in this headless environment (no
            // NSEvent monitor per the M8a/T4 brief); flagged for the T5 smoke.
            CommandGroup(after: .windowList) {
                ForEach(1...9, id: \.self) { n in
                    Button(String(format: L10n.string("menu.selectTab", "Tab %lld"), n)) {
                        tabCommands.selectTab?(n - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
            }
            CommandGroup(after: .sidebar) {
                Button(L10n.string("menu.toggleHidden", "Show/Hide Hidden Files")) {
                    settingsStore.showHiddenFiles.toggle()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            }
            // "Sessions" menu (M10a/T2, mockup section 4): bundles the
            // management sheets and the sidebar's existing export/import
            // actions in one menu-bar home. Same key-window guard as the
            // other `tabCommands` closures above — `ContentView.task` wires
            // these against `window?.isKeyWindow`.
            CommandMenu(L10n.string("menu.sessions", "Sessions")) {
                Button(L10n.string("menu.knownHosts", "Known Hosts…")) {
                    tabCommands.showKnownHosts?()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                Button(L10n.string("menu.logins", "Logins…")) {
                    tabCommands.showLogins?()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                Button(L10n.string("menu.exportAllSessions", "Export All Sessions…")) {
                    tabCommands.exportAllSessions?()
                }
                Button(L10n.string("menu.importSessions", "Import Sessions…")) {
                    tabCommands.importSessions?()
                }
            }
        }

        // Opened via Cmd-, or the app menu's "Settings…" item (M5c/T3).
        Settings {
            SettingsView(store: settingsStore)
                .tint(DesignTokens.remoteBlue)
        }
    }
}
