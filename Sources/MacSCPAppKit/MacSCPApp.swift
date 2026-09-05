import SwiftUI
import macSCPCore

/// One window's menu bridge (M8a/T4): `MacSCPCommands` holds no reference
/// to `ContentView` — the menu items call these closures, and `ContentView`
/// assigns them (in `wireTabCommands()`) to its own tab-lifecycle methods.
/// `@Observable` for consistency with the app's other cross-layer bridges
/// (`ConflictPromptBridge`); the closures themselves are read once per
/// invocation, not observed reactively.
///
/// **Per window, not per app** (Detachable Tabs plan, Task 2 fix round 1).
/// Each `ContentView` owns one and publishes it with
/// `.focusedSceneValue(\.tabCommands, …)`; the menus read the FOCUSED
/// window's instance back with `@FocusedValue`. Before that there was one
/// instance for the whole app, and every closure carried a
/// `window?.isKeyWindow` guard to decide after the fact whether it was the
/// right window — which a second window broke twice over: the closures
/// belonged to whichever window ran its setup last, and the mirrored
/// enabled-state values to whichever window changed last, background
/// windows included. None of those guards survives; being focused is now
/// the precondition for being read at all.
///
/// What could NOT become per window is on `SettingsWindowBridge` — see
/// that type for why.
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
    /// "Server Certificates…" — same bridge shape as
    /// `showKnownHosts` above, opens the server-certificate management sheet.
    /// Its own entry rather than a section inside the known-hosts sheet; see
    /// `ServerCertificatesSheet`'s doc comment.
    var showServerCertificates: (() -> Void)?
    /// "Logins…" (M10b/T3) — same bridge shape as
    /// `showKnownHosts` above, opens the login-sets management sheet.
    var showLogins: (() -> Void)?
    /// "Hidden Imports…" (M11f/T2) — same bridge shape as
    /// `showKnownHosts`/`showLogins` above, opens the hidden-imports
    /// management sheet.
    var showHiddenImports: (() -> Void)?
    /// "SSH Keys…" (M18/T5) — same bridge shape as
    /// `showKnownHosts`/`showLogins`/`showHiddenImports` above, opens the
    /// SSH-key management sheet (replaces the M17 Settings tab).
    var showSSHKeys: (() -> Void)?
    /// Opens the ad-hoc connection log (M31). Its own entry rather than a
    /// parameter on the existing audit hook, because there is no session to
    /// pass -- the ad-hoc log's session is a value the App layer builds.
    var showAdHocAuditLog: (() -> Void)?
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
    /// "From Cyberduck…" (2026-09-03) — reads Cyberduck's bookmark folder
    /// and opens the import preview. Its own entry rather than a mode of
    /// `importSessions` above: that one takes a `.macscpsessions` file the
    /// user picks, this one takes another program's data directory and shows
    /// a preview before anything is written.
    var importFromCyberduck: (() -> Void)?
    /// Terminal menu (M11d/T2): these two entries always offer BOTH ways to
    /// open a session's shell, regardless of `SettingsStore.terminalTarget`
    /// — the setting only picks what ⌘T/the toolbar button do, it never
    /// takes either capability away.
    var toggleTerminal: (() -> Void)?
    var openExternalTerminal: (() -> Void)?
    /// Transfer-bar toggle (M11o): the "Show/Hide Transfers" menu entry and
    /// ⌘⇧Y drive this. Each window fills in its own closure, which toggles
    /// that window's active tab's `transfersPanelVisible`, and the menu
    /// reaches only the focused window's — there is no key-window check
    /// anywhere on this bridge any more. Enabled state mirrors
    /// `isActiveTabConnected` (same as the Terminal entries).
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
    /// Pane lock (P2 terminal-chrome milestone; whole-phase review, Fix 2):
    /// `false` while the terminal is the last visible half, so turning it off
    /// would empty the window. `ContentView` mirrors
    /// `SessionTab.paneToggleState(for: .terminal, …).isEnabled` here the
    /// same way it mirrors `activeTabSupportsShell` above, and for the same
    /// reason (this Scene cannot see `tabsModel`).
    ///
    /// It exists because `toggleTerminal`'s closure checks the lock and
    /// returns — and a menu entry that is enabled and does nothing is exactly
    /// what `PaneToggleState`'s own doc comment rules out ("disabled rather
    /// than silently inert, so the user can see why a click does not land").
    /// The toolbar button got this right from the start via its own
    /// `.disabled`; the menu entry lives in another Scene and could only get
    /// it through a mirror.
    ///
    /// Defaults `true` for the same reason `activeTabSupportsShell` does: the
    /// menu must behave exactly as before until the mirror has run once. The
    /// disconnected case is not this flag's business — `isActiveTabConnected`
    /// already covers it.
    var activeTabTerminalToggleIsUnlocked = true
    /// Whether the "Show/Hide Terminal" entry can do anything at all: a
    /// connected tab, on a backend with a shell, whose terminal half is not
    /// the last visible one. The menu's `.disabled` reads THIS rather than
    /// re-spelling the three conditions, so the entry and
    /// `toggleTerminal`'s own guards cannot drift apart on what "would not
    /// land" means.
    ///
    /// "Open in External Terminal" deliberately does NOT read this: that
    /// route never touches `TerminalPanelViewModel.isVisible`, so the pane
    /// lock has nothing to say about it (documented deliberate asymmetry,
    /// Task 3).
    var canToggleTerminal: Bool {
        isActiveTabConnected && activeTabSupportsShell && activeTabTerminalToggleIsUnlocked
    }
    /// The saved snippets, mirrored for the Terminal menu's snippet entries
    /// (Terminal-Snippets milestone) — same rationale as `hiddenImportsCount`
    /// above: this Scene cannot see `ContentView`'s `@State`, and here the
    /// menu needs the whole list, not just a count, because there is one
    /// entry per snippet. `ContentView` fills it from `SnippetStore` during
    /// window setup and again whenever the management sheet closes, which is
    /// the only place a snippet can be created, edited or deleted.
    ///
    /// Carries the read OUTCOME, not just a list: a store that cannot be read
    /// must not look like an empty one in the menu (see `SnippetsLoad`).
    var snippetsLoad: SnippetsLoad = .loaded([])
    /// Triggers one snippet in the active tab's shell — `ContentView`
    /// describes the run (`SnippetDryRun.describing`, which is where the
    /// send plan is made) and sends the resulting bytes to that tab's
    /// `TerminalPanelViewModel`. Same
    /// bridge shape as `toggleTerminal` above.
    /// `execute` is the trigger's own choice (Terminal-Snippets, Task 6):
    /// every snippet offers both an Insert and an Execute action, so this
    /// bridge carries WHICH ONE fired rather than deciding for it.
    var runSnippet: ((Snippet, Bool) -> Void)?
    /// "Manage Snippets…" — same bridge shape as `showLogins` above, opens
    /// the snippet management sheet in the focused window.
    var showSnippets: (() -> Void)?
    /// "Move Tab to New Window" (Detachable Tabs plan, Task 2) — the Window
    /// menu's route to the action the tab strip's context menu also offers.
    /// Same bridge shape as the entries above; it moves the ACTIVE tab of
    /// the window this bridge belongs to, which — the bridge being read
    /// through `@FocusedValue` — is the window in front, and the only tab a
    /// menu with no click target can mean.
    var moveTabToNewWindow: (() -> Void)?
    /// Whether that entry can do anything: `false` while the front window
    /// holds a single tab, because moving the only tab of a window into a
    /// new window closes one window and opens another holding the same
    /// thing. Mirrored from `ContentView` for the same reason
    /// `isActiveTabConnected` is — this Scene cannot see `tabsModel`.
    ///
    /// Defaults `false`, unlike the mirrors above, and deliberately: a
    /// window comes up with exactly one tab, so `false` is the true value
    /// until the mirror has run, and the entry is greyed rather than
    /// enabled-and-inert in the moment before it does.
    var canMoveTabToNewWindow = false
}

/// The Settings window's route into a main window, and the one bridge in
/// this app that is deliberately NOT per window.
///
/// The "Manage Data" section presents login sets, server certificates and
/// hidden imports through a MAIN window's sheets rather than opening a
/// second copy of each in the Settings window. It cannot use the focused
/// value `TabCommands` travels on (`MacSCPCommands.swift`): when these
/// entries are clicked the Settings window IS the focused one, so the
/// focused bridge is `nil` by definition. So this stays an app-wide object
/// every window writes into, and "the main window" means the window that
/// wrote last — the same meaning it had when there was only ever one.
///
/// It was carved out of `TabCommands` in the Detachable Tabs plan, Task 2
/// fix round 1, when that type became per window: these five members are
/// the ones that could not travel with it.
@MainActor
@Observable
final class SettingsWindowBridge {
    /// Settings-window route to the login-sets sheet ("Manage Data"
    /// section).
    ///
    /// Deliberately a SEPARATE closure from `TabCommands.showLogins`: that
    /// one belongs to the focused window and would be `nil` here, because
    /// the Settings window is the focused one when this fires. It exists at
    /// all because Settings must not present its own copy of
    /// `LoginSetsSheet` — see the wiring comment in
    /// `ContentView.wireTabCommands()` for the exact hazard.
    var showLoginsFromSettings: (() -> Void)?
    /// Settings-window route to the server-certificate sheet — same shape as
    /// `showLoginsFromSettings` above; the reason is trust, not state (see
    /// `ContentView.presentServerCertificatesFromSettings()`).
    var showServerCertificatesFromSettings: (() -> Void)?
    /// Settings-window route to the hidden-imports sheet — same shape and
    /// same reason as `showLoginsFromSettings` above.
    var showHiddenImportsFromSettings: (() -> Void)?
    /// Whether a main window EXISTS: the three routed entries above have
    /// nowhere to go without one, so the "Manage Data" section disables them
    /// rather than letting the click vanish. `ContentView` keeps this in sync
    /// from `updateMainWindowPresence()`/`handleWindowWillClose(_:)`, and it
    /// starts `false` — no window has resolved yet at that point.
    ///
    /// Existence, not visibility: the routed handlers raise the window before
    /// presenting, and raising deminiaturizes and unhides it, so a minimized
    /// window or a hidden app is still a window those entries work on. Asking
    /// `isVisible` here would grey them out (or worse, leave them enabled on a
    /// stale `true`) for states in which the action would have succeeded.
    var hasMainWindow = false
    /// The hidden-import count the "Manage Data" entry's title shows.
    ///
    /// The SAME number also lives on `TabCommands`, and the duplication is
    /// deliberate rather than an oversight: the Sessions menu's own "Hidden
    /// Imports…" title shows the FOCUSED window's count, and this one shows
    /// the count of whichever window the "Manage Data" entries would route
    /// to. With one window open the two are the same number; with two open
    /// they are answers to different questions.
    var hiddenImportsCount = 0
}

/// Wired into `MacSCPApp` through `@NSApplicationDelegateAdaptor` below —
/// SwiftUI's own `App` protocol has no termination callback of its own, and
/// `NSApplication.willTerminateNotification` (a prior round's choice, now
/// replaced) cannot be waited on synchronously: the notification fires from
/// a plain `NotificationCenter` block, and a callback that starts a `Task`
/// and returns has no guarantee the process outlives that `Task` ever being
/// scheduled — on an ordinary Cmd+Q that race can lose both the "app quit"
/// line and whatever was still buffered. `applicationWillTerminate(_:)` is a
/// real `NSApplicationDelegate` callback: AppKit holds the process open
/// until it returns, so a synchronous call inside it is guaranteed to run
/// before the process can exit — which is exactly what `flushSynchronously()`
/// needs (Diagnostic Log plan, Task 2 round 1).
///
/// No other code under `Sources/MacSCPAppKit` reads `NSApp.delegate` or
/// relies on `applicationDidFinishLaunching` (checked with `grep -rn
/// "NSApp.delegate\|applicationDidFinishLaunching" Sources/MacSCPAppKit`
/// before adding this — no matches), so installing this adaptor changes
/// nothing this app already depended on `NSApp.delegate` being.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticLog.shared.log(.info, "app", "quit")
        DiagnosticLog.shared.flushSynchronously()
    }
}

struct MacSCPApp: App {
    /// Installs `AppDelegate` above as `NSApp.delegate` — this is the ONLY
    /// thing that makes `applicationWillTerminate(_:)` run. `@State`/
    /// `@NSApplicationDelegateAdaptor` are both property wrappers SwiftUI
    /// resolves before `body` is ever asked for, so declaration order here
    /// doesn't matter the way it would for a plain stored property, but it
    /// is listed first as the thing the whole app's lifecycle depends on.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
    @State private var settingsBridge = SettingsWindowBridge()
    /// App-global update-check state (M11b/T2) — see `UpdateCheckModel`'s
    /// doc comment for why this lives here rather than in `ContentView`'s
    /// per-tab machinery.
    @State private var updateModel = UpdateCheckModel()
    /// The releases `decideWhatsNew(store:)` decided to show this launch —
    /// see that function's doc comment. `showWhatsNew` drives the sheet's
    /// presentation; this carries what it should show once presented.
    @State private var whatsNewReleases: [ChangelogRelease] = []
    /// Whether the "What's New" sheet should be showing. Set once in
    /// `init` from `decideWhatsNew(store:)`'s result and flipped back to
    /// `false` by the sheet's own Close button (`WhatsNewSheet.onClose`).
    @State private var showWhatsNew = false
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
    /// The running bundle's `CFBundleShortVersionString`, captured once in
    /// `init` for `WhatsNewSheet`'s title — empty when it could not be
    /// read (`decideWhatsNew(store:)` already declined to show anything in
    /// that case, so an empty title is never actually presented).
    let whatsNewCurrentVersion: String

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

        // Diagnostic log (Diagnostic Log plan, Task 2): configure the sink
        // from the persisted setting BEFORE anything else in this process
        // could log, then write the first line so a log file always
        // identifies the build that wrote it. Placed right beside the
        // What's New decision below — both are "the first thing this launch
        // decides" — rather than inside `decideWhatsNew(store:)` itself,
        // which is unrelated to logging and already documents its own,
        // narrower contract.
        DiagnosticLog.shared.configure(level: store.diagnosticLogLevel)
        let launchVersion = Self.bundleVersion
        let launchBuild = Self.bundleBuild
        DiagnosticLog.shared.log(.info, "app", "launch version=\(launchVersion) build=\(launchBuild)")

        // "app quit" (Diagnostic Log plan, Task 2 round 1): logged from
        // `AppDelegate.applicationWillTerminate`, not from here — see that
        // type's own doc comment for why a `NotificationCenter` observer
        // (this file's prior approach) could not guarantee the line, or the
        // rest of the buffer, actually reached disk before the process
        // exited.

        // "What's New" decision (What's New plan, Task 2) — see
        // `decideWhatsNew(store:)`'s own doc comment for exactly when
        // `lastSeenVersion` gets written and why that happens inside it,
        // synchronously, rather than after the sheet is dismissed.
        let whatsNew = Self.decideWhatsNew(store: store)
        whatsNewCurrentVersion = whatsNew.current
        _whatsNewReleases = State(initialValue: whatsNew.releases)
        _showWhatsNew = State(initialValue: !whatsNew.releases.isEmpty)

        let model = MenuBarStatusModel()
        _settingsStore = State(initialValue: store)
        _menuBarModel = State(initialValue: model)
        menuBarController = MenuBarController(model: model, settingsStore: store)
    }

    /// `CFBundleShortVersionString`/`CFBundleVersion` off `Bundle.main`, read
    /// the same way `UpdateCheckModel.check(manual:settingsStore:)` reads
    /// the short version (`UpdateCheckModel.swift:136`) — `"unknown"` when
    /// unresolvable (`swift run` outside a `.app`, or a malformed bundle),
    /// same fallback text that call site uses for its own user agent.
    private static var bundleVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    private static var bundleBuild: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "unknown"
    }

    /// Decides which releases (if any) "What's New" should show this
    /// launch, and records the running version as `store.lastSeenVersion`
    /// IMMEDIATELY as part of making that decision — before `body` ever
    /// builds the sheet, let alone before the user sees or dismisses it.
    ///
    /// Recording at decision time rather than at dismissal is deliberate:
    /// `init` runs once per process launch, and a crash mid-sheet (or the
    /// app quitting before the user closes it) must not leave the same
    /// release list queued to reappear next launch as though nothing had
    /// been acknowledged — the decision itself, not the user's reaction to
    /// it, is what "seen" means here. It mirrors how
    /// `UpdateCheckModel.check(manual:settingsStore:)` already writes
    /// `settingsStore.lastUpdateCheck` right after the attempt rather than
    /// after any alert it raises is dismissed.
    ///
    /// Returns an empty `current` and `[]` releases when the running
    /// bundle carries no `CFBundleShortVersionString` at all (`swift run`
    /// outside a `.app`, or a malformed bundle) — there is no "current"
    /// version to decide against, so nothing is shown and nothing is
    /// recorded either; a `nil` read is left exactly as unresolved as it
    /// was, rather than guessed at. A resolvable `current` with no
    /// `CHANGELOG.md` bundled (`ChangelogResource.load()` returns `nil`
    /// under `swift test`/`swift run`, or a build assembled without
    /// `scripts/package-app`/the dev-build recipe) still records
    /// `current`, just against an empty release list, exactly as
    /// `WhatsNewModel.releasesToShow` would for a `lastSeen` already
    /// caught up.
    ///
    /// The same is true of a resolvable but NON-NUMERIC `current` — a dev
    /// build's `"dev-<hash>"` (Round 1 ruling, `WhatsNewModel
    /// .releasesToShow`'s doc comment): `store.lastSeenVersion = current`
    /// below runs unconditionally, after `WhatsNewModel` has already
    /// decided `toShow` — a dev build never shows the sheet, but it still
    /// records the exact string it ran under, so a LATER numeric release
    /// compares against that recorded dev string rather than against
    /// whatever real version predates it (which `releasesToShow` treats as
    /// a fresh install per that same ruling, showing nothing either way,
    /// but with the true `lastSeen` on record either way).
    private static func decideWhatsNew(
        store: SettingsStore
    ) -> (current: String, releases: [ChangelogRelease]) {
        guard let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        else { return ("", []) }

        let releases = ChangelogResource.load().map(ChangelogParser.parse) ?? []
        let toShow = WhatsNewModel.releasesToShow(
            current: current, lastSeen: store.lastSeenVersion, in: releases)
        store.lastSeenVersion = current
        return (current, toShow)
    }

    /// The PRIMARY window: the one SwiftUI opens for the value-keyed
    /// `WindowGroup` with no seed at launch.
    ///
    /// It is the only window that presents "What's New", and that is the
    /// whole difference between the two branches. The decision was taken
    /// ONCE PER PROCESS, in `init` (`decideWhatsNew(store:)`, which also
    /// records `lastSeenVersion` there and then), so `showWhatsNew` is
    /// app-scope `@State`: a second window attaching the same sheet would
    /// present the same release notes again, over a window the user opened
    /// to move a tab into.
    @ViewBuilder
    private func primaryWindow() -> some View {
        windowContent(seed: nil)
            // "What's New" (What's New plan, Task 2): `showWhatsNew` was
            // decided once, in `init`, by `decideWhatsNew(store:)` — this
            // only presents what that decision already made.
            .sheet(isPresented: $showWhatsNew) {
                WhatsNewSheet(
                    currentVersion: whatsNewCurrentVersion, releases: whatsNewReleases,
                    onClose: { showWhatsNew = false })
            }
    }

    /// A window opened by moving a tab out of another one — see
    /// `primaryWindow()` above for what it deliberately does NOT carry.
    @ViewBuilder
    private func detachedWindow(seed: WindowSeed) -> some View {
        windowContent(seed: seed)
    }

    /// Everything both windows are: the same `ContentView` over the same
    /// app-global stores, told which seed (if any) it opened with.
    ///
    /// The diagnostic-log observer lives here rather than in one branch
    /// because a level change has to take effect while ANY window is open —
    /// including after the primary one has been closed. `configure(level:)`
    /// is idempotent, so several windows reacting to one change reconfigure
    /// the same sink to the same level; what it costs is one `level=` line
    /// per open window.
    @ViewBuilder
    private func windowContent(seed: WindowSeed?) -> some View {
        ContentView(
            settingsStore: settingsStore, bandwidthLimiter: bandwidthLimiter,
            auditStore: auditStore, settingsBridge: settingsBridge, updateModel: updateModel,
            menuBarModel: menuBarModel, seed: seed)
            // Diagnostic log (Diagnostic Log plan, Task 2): the General
            // settings pane's picker writes `settingsStore
            // .diagnosticLogLevel` directly (`SettingsView.swift`), so
            // this is the one place a level change reconfigures the
            // sink — reusing `configure(level:)`'s own "takes effect at
            // once" contract rather than re-deriving it here.
            .onChange(of: settingsStore.diagnosticLogLevel) { _, newLevel in
                DiagnosticLog.shared.configure(level: newLevel)
                DiagnosticLog.shared.log(.info, "app", "level=\(newLevel.rawValue)")
            }
    }

    var body: some Scene {
        // The minimum size depends on the connection state (compact form vs.
        // browser) — it lives conditionally in `ContentView` instead of here
        // globally (M5c/T0).
        // Value-keyed (Detachable Tabs plan, Task 2): each window instance
        // is identified by the `WindowSeed` it was opened with, which is
        // what lets `openWindow(value:)` open a SECOND window for a tab that
        // moved out of this one. SwiftUI opens the group's own window with a
        // `nil` value at launch — that one is the PRIMARY window, and the
        // two branches below are what "primary" means in code.
        WindowGroup("macSCP", for: WindowSeed.self) { $seed in
            if let seed {
                detachedWindow(seed: seed)
            } else {
                primaryWindow()
            }
        }
        // Every menu this app adds lives in `MacSCPCommands`
        // (`MacSCPCommands.swift`): it reads the focused window's
        // `TabCommands` through `@FocusedValue`, which `App.body` — not a
        // dynamic-property type — cannot do.
        // Windows are NOT restored at the next launch (Detachable Tabs
        // plan, Task 2 fix round 1). A value-keyed group persists its
        // `WindowSeed`s, so without this macOS would reopen every detached
        // window on the next launch with a seed nobody parked anything
        // under: a window per moved tab, each holding one fresh, empty form
        // tab. Task 5 is what makes restoration mean something — from
        // `SettingsStore`, off by default, and reconstructing the tabs
        // rather than the window frames — and it turns this off on its own
        // terms.
        .restorationBehavior(.disabled)
        .commands { MacSCPCommands(settingsStore: settingsStore, updateModel: updateModel) }

        // Opened via Cmd-, or the app menu's "Settings…" item (M5c/T3).
        // `updateModel` passed through (M11h/T2) so the General tab's "Check
        // Now" button can drive the SAME `UpdateCheckModel` instance as the
        // app-menu item above — one shared `isChecking`/`presentedResult`,
        // not a second check path. `settingsBridge` passed through for the
        // "Manage Data" section's two window-scoped entries (logins, hidden
        // imports), which reach the main window's sheets instead of opening
        // a second copy of their own.
        Settings {
            SettingsView(store: settingsStore, updateModel: updateModel,
                         launchLanguage: launchLanguage, settingsBridge: settingsBridge)
                .tint(DesignTokens.remoteBlue)
        }

        // The menu-bar status item is an AppKit `NSStatusItem` driven by
        // `menuBarController` (created in `init`), NOT a SwiftUI scene —
        // `MenuBarExtra` loops SwiftUI layout on macOS 26. See
        // `MenuBarController`.
    }

}
