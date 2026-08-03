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
    /// "Hidden Imports…" (M11f/T2) — same bridge shape/key-window guard as
    /// `showKnownHosts`/`showLogins` above, opens the hidden-imports
    /// management sheet.
    var showHiddenImports: (() -> Void)?
    /// "SSH Keys…" (M18/T5) — same bridge shape/key-window guard as
    /// `showKnownHosts`/`showLogins`/`showHiddenImports` above, opens the
    /// SSH-key management sheet (replaces the M17 Settings tab).
    var showSSHKeys: (() -> Void)?
    /// Mirrors `ContentView`'s `hiddenImportAliases.count` (M11f/T2, same
    /// rationale as `isActiveTabConnected` below): the "Hidden Imports…"
    /// menu title's count suffix needs this observed value since `MacSCPApp`
    /// builds a separate Scene that does not see `ContentView`'s `@State`.
    var hiddenImportsCount = 0
    var exportAllSessions: (() -> Void)?
    var importSessions: (() -> Void)?
    /// "Import Logins…" (M19/T8) — opens the login-sets sheet with its file
    /// picker armed. Exporting logins lives in that sheet only (it needs a
    /// selection to scope), so there is no menu counterpart for it.
    var importLogins: (() -> Void)?
    /// Terminal menu (M11d/T2): these two entries always offer BOTH ways to
    /// open a session's shell, regardless of `SettingsStore.terminalTarget`
    /// — the setting only picks what ⌘T/the toolbar button do, it never
    /// takes either capability away.
    var toggleTerminal: (() -> Void)?
    var openExternalTerminal: (() -> Void)?
    /// Transfer-bar toggle (M11o): the "Show/Hide Transfers" menu entry and
    /// ⌘⇧Y drive this; `ContentView.task` wires it against `window?.isKeyWindow`
    /// and toggles the active tab's `transfersPanelVisible`. Enabled state
    /// mirrors `isActiveTabConnected` (same as the Terminal entries).
    var toggleTransfers: (() -> Void)?
    /// Mirrors `ContentView`'s active tab connection state (M11d/T2): this
    /// `TabCommands` instance is the only thing `MacSCPApp`'s `.commands`
    /// closure observes, and that closure builds a separate Scene that does
    /// NOT see `ContentView`'s own `tabsModel` — so the enabled state of the
    /// two Terminal menu entries above has to be mirrored here explicitly
    /// (see `ContentView`'s `.onChange(of: isActiveTabConnected)`).
    var isActiveTabConnected = false
    /// Capability gate (M12/T7b): `false` while the active tab's backend
    /// has no shell (S3) — `ContentView` mirrors
    /// `BackendDescriptor.descriptor(for:).capabilities.supportsShell` here
    /// the same way it mirrors `isActiveTabConnected` above, for the same
    /// reason (this Scene doesn't see `tabsModel`). Defaults `true` so the
    /// menu behaves exactly as before this feature until the mirror runs.
    var activeTabSupportsShell = true
}

@main
struct MacSCPApp: App {
    /// Single instance for the whole app — passed to `ContentView` and the
    /// `Settings` scene below (M5c/T3: no singleton, per the v2 multi-window
    /// rule).
    @State private var settingsStore: SettingsStore
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
    /// App-global update-check state (M11b/T2) — see `UpdateCheckModel`'s
    /// doc comment for why this lives here rather than in `ContentView`'s
    /// per-tab machinery.
    @State private var updateModel = UpdateCheckModel()
    /// Menu-bar status bridge (M11n) — one instance for the whole app,
    /// passed to `ContentView` (which mirrors its tabs into it) and to the
    /// `MenuBarController` below, same no-singleton pattern as the other
    /// app-global stores above.
    @State private var menuBarModel: MenuBarStatusModel

    /// AppKit menu-bar status item (M11n, re-landed). Retained for the app's
    /// lifetime; reads `menuBarModel` and shows/hides itself from
    /// `settingsStore.menuBarEnabled`. Replaces the SwiftUI `MenuBarExtra`,
    /// which loops SwiftUI layout on macOS 26 — see `MenuBarController`.
    private let menuBarController: MenuBarController
    /// The language that was in effect when THIS process launched (M11p):
    /// captured once in `init`, alongside the `AppleLanguages` override
    /// applied below. `GeneralSettingsTab` compares this against the live
    /// `store.selectedLanguage` to decide whether to show the relaunch
    /// button — a change only takes effect on a fresh launch.
    let launchLanguage: AppLanguage

    init() {
        // Sweep any orphaned edit temp directories left behind by a
        // hard-killed previous run (M6a) — first, before anything else
        // touches the temp tree.
        EditSessionManager.sweepOrphanedTempDirectories()
        // Same sweep for orphaned external-terminal launch scripts (M11d/T2)
        // — see `ExternalTerminalLauncher.sweepOrphanedTempDirectories`.
        ExternalTerminalLauncher.sweepOrphanedTempDirectories()
        // Without an app bundle (started via `swift run`) the process runs
        // as an accessory — only the regular policy brings a window and a
        // Dock icon. A real `.app` bundle lands in M6.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Build the settings store and the menu-bar bridge here (not as
        // property initializers) so the AppKit `MenuBarController` can share
        // the very same instances the views observe.
        let store = SettingsStore(directory: SettingsStore.defaultDirectory)

        // Apply the chosen UI language before any localized lookup (M11p).
        // `L10n`/`CoreL10n` defer to Foundation's AppleLanguages resolution,
        // so setting this here (before `body` builds any menu/view) is early
        // enough for a fresh launch; a change made while running needs a
        // relaunch (the bundle tables cache). `.system` clears the override.
        let language = store.selectedLanguage
        if let code = language.localeCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        launchLanguage = language

        let model = MenuBarStatusModel()
        _settingsStore = State(initialValue: store)
        _menuBarModel = State(initialValue: model)
        menuBarController = MenuBarController(model: model, settingsStore: store)
    }

    var body: some Scene {
        // The minimum size depends on the connection state (compact form vs.
        // browser) — it lives conditionally in `ContentView` instead of here
        // globally (M5c/T0).
        WindowGroup("macSCP") {
            ContentView(
                settingsStore: settingsStore, bandwidthLimiter: bandwidthLimiter,
                auditStore: auditStore, tabCommands: tabCommands, updateModel: updateModel,
                menuBarModel: menuBarModel)
        }
        .commands {
            // "Check for Updates…" (M11b/T2), directly under "About macSCP"
            // (spec §4). App-global, not routed through the `tabCommands`
            // key-window bridge like the tab/session commands below — the
            // check itself doesn't depend on which window is focused, it
            // just compares the running bundle against the latest GitHub
            // release. Disabled while a check is already running (spec §4
            // multi-click guard); a manual click always presents a result,
            // shown via `updateModel.presentedResult` in `ContentView`'s
            // alert (the app's one window, where app-global result dialogs
            // already live — see the import/export alerts there).
            CommandGroup(after: .appInfo) {
                Button(L10n.string("menu.checkForUpdates", "Check for Updates…")) {
                    Task { await updateModel.check(manual: true, settingsStore: settingsStore) }
                }
                .disabled(updateModel.isChecking)
            }
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

                Button(L10n.string("menu.transfers.toggle", "Show/Hide Transfers")) {
                    tabCommands.toggleTransfers?()
                }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(!tabCommands.isActiveTabConnected)
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
                // "SSH Keys…" (M18/T5): opens the SSH-key management sheet —
                // same key-window guard as the other entries in this menu.
                Button(L10n.string("menu.sshKeys", "SSH Keys…")) {
                    tabCommands.showSSHKeys?()
                }
                // "Hidden Imports…" (M11f/T2): the count suffix is the ONLY
                // way back once every imported entry is hidden and the
                // IMPORTED sidebar section itself disappears — see
                // `hiddenImportsMenuTitle(count:)`.
                Button(hiddenImportsMenuTitle(count: tabCommands.hiddenImportsCount)) {
                    tabCommands.showHiddenImports?()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button(L10n.string("menu.exportAllSessions", "Export All Sessions…")) {
                    tabCommands.exportAllSessions?()
                }
                Button(L10n.string("menu.importSessions", "Import Sessions…")) {
                    tabCommands.importSessions?()
                }
                Button(L10n.string("menu.importLogins", "Import Logins…")) {
                    tabCommands.importLogins?()
                }
            }
            // "Terminal" menu (M11d/T2, spec §4): always offers BOTH ways to
            // open a session's shell — the toolbar button/⌘T follow
            // `SettingsStore.terminalTarget`, but these two entries never
            // change with that setting, so switching it never takes a
            // capability away. Both disabled while the active tab has no
            // connected session (`tabCommands.isActiveTabConnected`, kept in
            // sync by `ContentView`), OR the active backend has no shell
            // (`tabCommands.activeTabSupportsShell`, M12/T7b — e.g. an S3
            // session).
            CommandMenu(L10n.string("menu.terminal", "Terminal")) {
                Button(L10n.string("menu.terminal.toggle", "Show/Hide Terminal")) {
                    tabCommands.toggleTerminal?()
                }
                .disabled(!tabCommands.isActiveTabConnected || !tabCommands.activeTabSupportsShell)
                Button(L10n.string("menu.terminal.openExternal", "Open in External Terminal")) {
                    tabCommands.openExternalTerminal?()
                }
                .disabled(!tabCommands.isActiveTabConnected || !tabCommands.activeTabSupportsShell)
            }
        }

        // Opened via Cmd-, or the app menu's "Settings…" item (M5c/T3).
        // `updateModel` passed through (M11h/T2) so the General tab's "Check
        // Now" button can drive the SAME `UpdateCheckModel` instance as the
        // app-menu item above — one shared `isChecking`/`presentedResult`,
        // not a second check path.
        Settings {
            SettingsView(store: settingsStore, updateModel: updateModel,
                         launchLanguage: launchLanguage)
                .tint(DesignTokens.remoteBlue)
        }

        // The menu-bar status item is an AppKit `NSStatusItem` driven by
        // `menuBarController` (created in `init`), NOT a SwiftUI scene —
        // `MenuBarExtra` loops SwiftUI layout on macOS 26. See
        // `MenuBarController`.
    }
}
