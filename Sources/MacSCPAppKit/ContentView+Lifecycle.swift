import AppKit
import SwiftUI
import macSCPCore

/// Tab lifecycle and window setup split out of `ContentView.swift`: appearance
/// lifecycle/toolbar wiring, tab construction/teardown, the window's one-time
/// setup pass, the menu-bar and window-presence bridges, and window geometry
/// (resize/shrink).
///
/// Extraction only (no behavior change) -- see `ContentView.swift` for the
/// surrounding state and the rest of the window's modifier groups.
extension ContentView {
    /// Appearance lifecycle, the toolbar, and the settings observers that keep
    /// live state in sync after `performWindowSetup()` seeded it.
    /// 
    /// See `windowChrome(_:)` for why these are grouped.
    func lifecycleAndToolbar<Content: View>(_ content: Content) -> some View {
        content
        // never resurface as a stale, unrequested dialog the next time a
        // fresh window opens.
        .onAppear { updateModel.hasPresentationTarget = true }
        .onDisappear {
            updateModel.hasPresentationTarget = false
            updateModel.presentedResult = nil
        }
        // Session actions live in the window's native toolbar (M5f/T5) —
        // attached at the outer container so it belongs to the window, not
        // the detail pane. Empty (no items) while the active tab is
        // disconnected.
        .toolbar {
            if let session = activeTab.session {
                ToolbarItemGroup(placement: .primaryAction) {
                    uploadButton(in: activeTab, session: session)
                    downloadButton(in: activeTab, session: session)
                    // Files toggle (P2 terminal-chrome milestone, Task 3):
                    // the pane pair's second half, next to Terminal below.
                    // No keyboard shortcut — ⌘T stays on Terminal, and
                    // nothing has asked for one here yet. Both toggles read
                    // their on/enabled state from `SessionTab.paneToggleState`,
                    // which asks `PaneVisibility` (Task 2) rather than
                    // re-deriving the "last visible half is locked" rule —
                    // see that method's doc comment.
                    Button {
                        activeTab.applyFilesToggleClick(
                            terminalIsVisible: session.terminal.isVisible,
                            hasShell: activeTabSupportsShell)
                        persistActivePaneVisibility()
                    } label: {
                        Label(L10n.string("browser.filesToggle", "Files"), systemImage: "folder")
                    }
                    .disabled(!activeTab.paneToggleState(
                        for: .files, terminalIsVisible: session.terminal.isVisible,
                        hasShell: activeTabSupportsShell
                    ).isEnabled)
                    .help(L10n.string("browser.filesToggleHelp", "Show/hide files"))
                    Button {
                        // Capability guard (M12/T7b): re-checked here too,
                        // same belt-and-suspenders rationale as the
                        // `tabCommands.toggleTerminal`/`openExternalTerminal`
                        // closures — the button/⌘T are already disabled
                        // below for a non-shell backend, but a silent no-op
                        // is never the fallback (spec).
                        guard activeTabSupportsShell else {
                            presentTerminalUnavailable()
                            return
                        }
                        // ⌘T/toolbar follow the setting (spec §4 item 5):
                        // `.builtIn` toggles the panel exactly like before
                        // this feature existed, anything else opens
                        // externally. Both routes stay reachable regardless
                        // — the "Terminal" menu (`tabCommands`) always
                        // offers the other one too. In `.builtIn` mode this
                        // ALSO re-checks the pane lock (Task 3): the
                        // `.disabled` below already blocks the click when
                        // Files is hidden and terminal is the only visible
                        // half, but external-terminal mode never touches
                        // `isVisible` at all, so the lock check only
                        // matters for this branch.
                        if settingsStore.terminalTarget == .builtIn {
                            guard activeTab.paneToggleState(
                                for: .terminal, terminalIsVisible: session.terminal.isVisible,
                                hasShell: activeTabSupportsShell
                            ).isEnabled else { return }
                            session.terminal.toggle()
                            persistActivePaneVisibility()
                        } else {
                            requestExternalTerminal(for: activeTab)
                        }
                    } label: {
                        Label(L10n.string("browser.terminalToggle", "Terminal"), systemImage: "terminal")
                    }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(settingsStore.terminalTarget == .builtIn
                        ? !activeTab.paneToggleState(
                            for: .terminal, terminalIsVisible: session.terminal.isVisible,
                            hasShell: activeTabSupportsShell
                        ).isEnabled
                        : !activeTabSupportsShell)
                    .help(settingsStore.terminalTarget == .builtIn
                        ? L10n.string("browser.terminalToggleHelp", "Show/hide terminal (⌘T)")
                        : L10n.string("browser.terminalOpenExternalHelp", "Open in external terminal (⌘T)"))
                    Button {
                        activeTab.transfersPanelVisible.toggle()
                    } label: {
                        Label(L10n.string("browser.transfersToggle", "Transfers"),
                              systemImage: "tray.full")
                    }
                    .help(L10n.string("browser.transfersToggleHelp",
                                      "Show/hide transfers (⌘⇧Y)"))
                    Button(L10n.string("browser.disconnect", "Disconnect")) {
                        disconnectToForm(activeTab)
                    }
                    .disabled(activeTab.transferQueue.isActive)
                }
            }
        }
        // Settings live-wiring (M5c/T4+T5): the concurrency observer targets
        // EVERY tab's queue (M8a/T3), the limit observers the shared limiter.
        // A change affects FUTURE slot assignments/items only — see the
        // properties' doc comments in `TransferQueueViewModel`.
        .onChange(of: settingsStore.maxConcurrentTransfers) { _, newValue in
            for tab in tabsModel.tabs {
                tab.transferQueue.maxConcurrent = newValue
            }
        }
        .onChange(of: settingsStore.uploadLimitKBs) { _, newValue in
            bandwidthLimiter.uploadLimitBytesPerSec = newValue * 1024
        }
        .onChange(of: settingsStore.downloadLimitKBs) { _, newValue in
            bandwidthLimiter.downloadLimitBytesPerSec = newValue * 1024
        }
        // Hidden-files toggle (M7a/T4): applies to the panes of EVERY
        // connected tab (M8a/T3), not just the active one — a background tab
        // would otherwise show a stale listing when it comes forward.
        .onChange(of: settingsStore.showHiddenFiles) { _, newValue in
            for tab in tabsModel.tabs {
                guard let session = tab.session else { continue }
                session.local.showHiddenFiles = newValue
                session.remote.showHiddenFiles = newValue
                Task {
                    await session.local.refresh()
                    await session.remote.refresh()
                }
            }
        }
        // Keeps `menuBarModel.tabs` synced with the window's tab list
        // (M11n/T2) — `SessionTab` is a class (`Identifiable`, not
        // `Equatable`), so `[SessionTab]` itself can't drive `.onChange`
        // directly; `tabIDs` (an `Equatable` proxy for "the tab set changed":
        // add/close/reorder) drives it instead, and the handler re-reads the
        // full array from `tabsModel.tabs`. Extracted as a typed computed
        // property (not an inline `.map(\.id)`) — inlined here it pushed the
        // surrounding modifier chain over the type checker's "reasonable
        // time" budget (same failure class as `passwordHintPresented` in
        // `ContentView+Sheets.swift`).
        .onChange(of: tabIDs) { _, _ in
            menuBarModel.tabs = tabsModel.tabs
        }
    }

    // MARK: - Tab lifecycle

    /// Mutable box carrying the `SessionTab` a connector closure belongs to —
    /// filled in immediately after that tab is constructed, in `makeTab`
    /// below. Needed because the closure is built and handed to
    /// `ConnectionViewModel.init` BEFORE the `SessionTab` that will own it
    /// exists, so it cannot simply capture the tab the way
    /// `ConnectionViewModel.connectSSH()` captures its OWN `self` to build
    /// the host-key decider (see `CertificatePromptBridge`'s own doc
    /// comment).
    ///
    /// `@unchecked Sendable`: `tab` is written exactly once, synchronously,
    /// right after `SessionTab.init` returns and before `makeTab` returns —
    /// by the time the connector closure can actually run (the earliest is a
    /// later, user-triggered `connect()`), the box is already stable. Every
    /// read of `tab` funnels straight into `SessionTab`'s own
    /// `@MainActor`-isolated interface (`await`ed methods), never touching
    /// its state directly from here.
    final class SessionTabBox: @unchecked Sendable {
        var tab: SessionTab!
    }

    /// Builds a fresh form tab: own connection view model, own queue (wired
    /// once here to the shared limiter, the settings concurrency and the
    /// tab's OWN conflict bridge). Static so `init` can seed `tabsModel`
    /// with the window's first tab.
    static func makeTab(
        settingsStore: SettingsStore, limiter: BandwidthLimiter
    ) -> SessionTab {
        let certificateBridge = CertificatePromptBridge()
        let box = SessionTabBox()
        let tab = SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { config, decider in
                // Plaintext confirmation (M21/T10): asked BEFORE dispatching
                // anything, so a refusal never opens a connection at all.
                // Reset first (see `pendingPlaintextConfirmation`'s own doc
                // comment on why), then set only on an actual confirm.
                await box.tab.resetPendingPlaintextConfirmation()
                if PlaintextTransportGate.requiresConfirmation(for: config) {
                    guard await box.tab.confirmPlaintext() else {
                        throw RemoteFSError.connectionFailed(
                            reason: "the user declined to send credentials over an unencrypted connection")
                    }
                    await box.tab.markPlaintextConfirmed()
                }
                // Certificate decider (M21/T10): unknown WebDAV/S3
                // certificates now reach `CertificatePromptView` instead of
                // being refused outright, which is what the command-line
                // driver still does for want of an interactive prompt (see
                // `MacSCPCLI/SessionConnecting.swift`). A MISMATCH
                // never reaches `certificateBridge.ask`
                // in the first place — `WebDAVSessionDelegate
                // .decideCertificate` refuses it before ever consulting the
                // decider — and surfaces instead as a thrown
                // `ServerCertificateError.mismatch`, which
                // `ConnectionViewModel.failedState(for:)` already maps to its
                // own honest, localized alert text (mirrors `HostKeyError`
                // case for case): nothing to intercept here.
                // Since M22/T10 each backend opens its own connection: the
                // descriptor's `connect` closure is what carries SSH's
                // known-hosts store and WebDAV's trust store, so there is no
                // central dispatcher left to route through.
                return try await BackendDescriptor.descriptor(for: config.kind).connect(
                    config, decider, { candidate in await certificateBridge.ask(candidate) })
            }),
            certificateBridge: certificateBridge,
            limiter: limiter,
            maxConcurrent: settingsStore.maxConcurrentTransfers
        )
        box.tab = tab
        return tab
    }

    func makeTab() -> SessionTab {
        Self.makeTab(settingsStore: settingsStore, limiter: bandwidthLimiter)
    }

    /// Attaches this tab's audit recorder once it connects to a STORED
    /// session (M9b/T3) — called from both places `activeStoredSessionID`
    /// gets assigned: `connect(in:stored:)` and `startSession`'s "Save &
    /// connect" path. Never called for an ad-hoc connect. Must run AFTER
    /// `tab.session` is populated (`startSession` always sets it first), so
    /// `tab.session?.remote.auditSink` below has something to wire.
    ///
    /// The recorder is captured by value in both closures (it's a plain
    /// `Sendable` struct over `sessionID` + `auditStore`); the queue sink
    /// additionally resolves a finished item's `destinationTabID` against
    /// `tabsModel` to the target tab's `displayTitle` for the
    /// cross-session-transfer detail — a target tab that's already gone
    /// resolves to `nil`, which `AuditRecorder.recordTransfer` renders as
    /// "unknown session".
    func attachAuditRecorder(
        to tab: SessionTab, sessionID: UUID, summary: String,
        viaJumpHost: String? = nil
    ) {
        let recorder = AuditRecorder(sessionID: sessionID, store: auditStore)
        tab.auditRecorder = recorder
        recorder.recordConnected(summary: summary, viaJumpHost: viaJumpHost)
        // Plaintext-transport audit trail (M21/T10): the connector closure
        // set this right after the user confirmed connecting over
        // `http://`; this is the first point afterward where a `sessionID`
        // (and with it, a recorder) exists to log it against. See
        // `SessionTab.pendingPlaintextConfirmation`'s own doc comment for
        // why it is safe to consume unconditionally here.
        if tab.pendingPlaintextConfirmation {
            recorder.recordAction(AuditEvent(
                kind: .plaintextConfirmed,
                detail: "connected without TLS after an explicit confirmation"))
            tab.pendingPlaintextConfirmation = false
        }
        // `[weak tabsModel]` (M9b/T4 review, finding 5): `TabsViewModel` is a
        // class, and this sink is retained by `tab.transferQueue` for the
        // tab's whole lifetime — a plain (implicit `self`) capture would
        // deviate from this file's weak-capture convention and pin every
        // `@State` box on `ContentView` (a full struct copy, including
        // `tabsModel`'s own storage) alive if the window ever dies without
        // running `teardown` (which nils this sink out).
        tab.transferQueue.auditSink = { [weak tabsModel] item in
            let targetTitle = item.destinationTabID.flatMap { id in
                tabsModel?.tabs.first(where: { $0.id == id })?.displayTitle
            }
            recorder.recordTransfer(item, targetTitle: targetTitle)
        }
        tab.session?.remote.auditSink = { event in recorder.recordAction(event) }
    }

    /// Tab-local teardown, in the invariant order: bridge dismiss →
    /// `cancelAll` → `editManager.stopAll` → `terminal.shutdown` →
    /// `remote.disconnect`. Touches ONLY this tab; other tabs' sessions,
    /// queues and forms are untouched.
    func teardown(_ tab: SessionTab) async {
        tab.editErrorMessage = nil
        if let session = tab.session {
            // MUST run before `cancelAll()`: an open conflict sheet would
            // otherwise keep the decider prompt open, which `cancelAll`
            // (documented) hangs on until it's answered — deadlock on disconnect.
            tab.conflictBridge.cancelOpenPrompt()
            await tab.transferQueue.cancelAll()
            // Binding order (M5e/T4 plan): AFTER `cancelAll` (any in-flight
            // edit download/upload has already been cancelled/settled by the
            // queue, so `stopAll` isn't racing a still-running transfer) and
            // BEFORE `terminal.shutdown`/`disconnect` (teardown proceeds
            // outward from the queue to the connection).
            await session.editManager.stopAll()
            await session.terminal.shutdown()
            await session.remote.disconnect()
            // Audit recorder teardown (M9b/T3): only present for a stored
            // session (`attachAuditRecorder` never runs for an ad-hoc
            // connect), so this is a no-op otherwise. `recordDisconnected()`
            // FIRST, then release the recorder and BOTH sinks it wired.
            if let recorder = tab.auditRecorder {
                recorder.recordDisconnected()
                tab.auditRecorder = nil
                tab.transferQueue.auditSink = nil
                session.remote.auditSink = nil
            }
        }
        let form = tab.connectionViewModel
        // `clearRetainedSecrets()` (not the narrower `clearPassword()`):
        // this tab's `connectionViewModel` survives past this teardown, so
        // its `lastConnectedConfig` (the external-terminal launcher's own
        // copy of the same secret) must be forgotten here too, or it would
        // keep the first connect's plaintext password in memory across
        // every later disconnect/reconnect in this tab (review finding,
        // M11d fix round 1).
        form.clearRetainedSecrets()
        form.authChoice = .password
        form.keyPath = ""
        // Reset any pending edit context: a stale `.edit(sessionID:)`
        // surviving into the next Save would overwrite the wrong stored
        // session (M5f/T4 review).
        form.exitEditMode()
        tab.session = nil
        tab.activeStoredSessionID = nil
        tab.titleName = nil
    }

    /// Activates a tab (strip click) and resets its attention indicator —
    /// visiting a tab acknowledges whatever failures it accumulated while in
    /// the background (M8a/T4 spec: reset on every activation call site).
    /// Guarded on the activation actually happening: `TabsViewModel.activate`
    /// no-ops for a stale/unknown id, and the reset must never fire for a
    /// tab the user did not actually visit.
    func activate(_ id: UUID) {
        tabsModel.activate(id)
        guard tabsModel.activeTabID == id else { return }
        tabsModel.activeTab.seenFailureCount = tabsModel.activeTab.transferQueue.totalFailureCount
    }

    /// ⌘1–⌘9 target: 1-indexed, no-op outside the current tab range.
    func selectTab(atIndex index: Int) {
        guard tabsModel.tabs.indices.contains(index) else { return }
        activate(tabsModel.tabs[index].id)
    }

    /// Everything this window does once, when it first appears: reading the
    /// SSH config inventory, seeding the bandwidth limiter, the due-check for
    /// updates, and wiring the menu-bar and menu-command bridges.
    ///
    /// A method rather than an inline `.task` closure, and deliberately so:
    /// see the comment at the call site. Nothing here is async -- the work is
    /// synchronous setup, and `.task` is only the hook that runs it once per
    /// window appearance.
    func performWindowSetup() {
        // Full inventory, read once (M11f/T2) — `refreshImportedHosts()`
        // below (and every later hide/unhide) re-splits THIS instead of
        // re-parsing the config file.
        fullImportedHosts = SSHConfigImporter.load(path: SSHConfigImporter.defaultPath)
        refreshImportedHosts()
        // Seed the shared limiter from the settings once per window; the
        // `.onChange` observers below keep it in sync afterwards. KBs → bytes/s.
        bandwidthLimiter.uploadLimitBytesPerSec = settingsStore.uploadLimitKBs * 1024
        bandwidthLimiter.downloadLimitBytesPerSec = settingsStore.downloadLimitKBs * 1024
        // Startup automatic update check (M11b/T2, spec §3): fires at
        // most once a day and only if due — `checkAutomaticallyIfDue`
        // no-ops instantly when disabled or not yet due, and otherwise
        // starts its own detached `Task`, so this never blocks the
        // window from appearing. `isChecking`'s synchronous guard (see
        // `UpdateCheckModel`) keeps this safe even if a second window
        // somehow ran this same `.task` concurrently.
        updateModel.checkAutomaticallyIfDue(settingsStore: settingsStore)
        // Menu-bar status bridge wiring (M11n/T2) — extracted into its
        // own method (like `refreshImportedHosts()` above) rather than
        // inlined here: this `.task` closure is already large enough
        // that the type checker times out on it (M11d/M11f review
        // precedent for this exact failure mode).
        wireMenuBarBridge()
        // Command bridge wiring (M8a/T4): `MacSCPApp` has no reference to
        // this view, so the menu items call back through these closures.
        //
        // Key-window guard (M8a T5 review, finding 1): the `Settings`
        // scene shares this exact ⌘N/⌘W/⌘1–9 command set (SwiftUI attaches
        // one `.commands` menu app-wide, not per window/scene), so with
        // Settings focused these closures would otherwise still fire
        // against THIS window's tabs instead of Settings — e.g. ⌘W would
        // tear down a tab instead of closing the Settings window. Each
        // closure checks that this window is actually key before acting.
        tabCommands.newTab = {
            guard window?.isKeyWindow == true else { return }
            tabsModel.addTab(makeTab())
        }
        tabCommands.selectTab = { index in
            guard window?.isKeyWindow == true else { return }
            selectTab(atIndex: index)
        }
        // Extracted into its own method (M14/T5 build fix — see
        // `wireMenuBarBridge()`'s doc comment above for the exact same
        // failure mode): inlined here, this closure's `if`/`else` body
        // was the straw that finally tipped the surrounding `.task`
        // closure over the type checker's "unable to type-check this
        // expression in reasonable time" limit. A plain function
        // reference assignment is far cheaper for the checker than a
        // multi-statement closure literal in the same inference scope.
        tabCommands.closeActiveTab = handleCloseActiveTabCommand
        // Sessions menu bridge (M10a/T2) — same key-window guard as the
        // tab commands above. Export/import route through the EXISTING
        // M9a state (`exportSheetItem`/`showImportFileImporter`), not a
        // duplicate handler.
        tabCommands.showKnownHosts = {
            guard window?.isKeyWindow == true else { return }
            showKnownHostsSheet = true
        }
        // "Server Certificates…" — same key-window guard, opens the
        // server-certificate management sheet.
        tabCommands.showServerCertificates = {
            guard window?.isKeyWindow == true else { return }
            showServerCertificatesSheet = true
        }
        // "Logins…" (M10b/T3) — same key-window guard, opens the
        // login-sets management sheet.
        tabCommands.showLogins = {
            guard window?.isKeyWindow == true else { return }
            loginSetsSheetStartsImport = false
            showLoginSetsSheet = true
        }
        // "Import Logins…" (M19/T8) — opens the same sheet, with its file
        // picker already armed.
        tabCommands.importLogins = {
            guard window?.isKeyWindow == true else { return }
            loginSetsSheetStartsImport = true
            showLoginSetsSheet = true
        }
        // "Hidden Imports…" (M11f/T2) — same key-window guard, opens the
        // hidden-imports management sheet.
        tabCommands.showHiddenImports = {
            guard window?.isKeyWindow == true else { return }
            showHiddenImportsSheet = true
        }
        // "SSH Keys…" (M18/T5) — same key-window guard, opens the
        // SSH-key management sheet.
        tabCommands.showSSHKeys = {
            guard window?.isKeyWindow == true else { return }
            showSSHKeysSheet = true
        }
        // Settings "Manage Data" bridge — the two entries that must NOT get
        // their own copy of the sheet in the Settings window. Extracted into
        // methods rather than inlined closures for the same type-checker
        // reason as `handleCloseActiveTabCommand` above.
        tabCommands.showLoginsFromSettings = presentLoginSetsFromSettings
        tabCommands.showServerCertificatesFromSettings = presentServerCertificatesFromSettings
        tabCommands.showHiddenImportsFromSettings = presentHiddenImportsFromSettings
        tabCommands.exportAllSessions = {
            guard window?.isKeyWindow == true else { return }
            exportSheetItem = ExportSheetItem(scope: .all)
        }
        tabCommands.importSessions = {
            guard window?.isKeyWindow == true else { return }
            showImportFileImporter = true
        }
        // "Terminal" menu bridge (M11d/T2) — same key-window guard as
        // the tab commands above. Unlike the toolbar button, these two
        // ALWAYS route to their own specific action regardless of
        // `settingsStore.terminalTarget` (spec §4 item 5).
        //
        // Capability guard (M12/T7b): the menu entry is already
        // disabled for a non-shell backend (`MacSCPApp`'s
        // `tabCommands.activeTabSupportsShell`), but this closure
        // re-checks anyway — belt-and-suspenders against any path that
        // reaches it regardless (spec: "no silent no-op").
        //
        // Pane-lock guard (P2 terminal-chrome milestone, Task 3): this menu
        // entry has no `.disabled` binding tied to the pane lock the way
        // the toolbar button does (it lives in a different Scene, wired
        // from `MacSCPApp.swift`), so it is the one caller that MUST check
        // `paneToggleState` itself rather than relying on a `.disabled` a
        // caller elsewhere already applied — otherwise this is the one
        // remaining path that could turn Terminal off while Files is
        // hidden and empty the window. A locked click is a no-op here,
        // same as `PaneVisibility.applyingClick` itself defines for the
        // Files toggle: not a capability problem needing
        // `presentTerminalUnavailable()`, just a click that doesn't land.
        tabCommands.toggleTerminal = {
            guard window?.isKeyWindow == true else { return }
            guard activeTabSupportsShell else {
                presentTerminalUnavailable()
                return
            }
            guard let terminal = activeTab.session?.terminal else { return }
            guard activeTab.paneToggleState(
                for: .terminal, terminalIsVisible: terminal.isVisible,
                hasShell: activeTabSupportsShell
            ).isEnabled else { return }
            terminal.toggle()
            persistActivePaneVisibility()
        }
        // Transfer-bar menu bridge (M11o) — same key-window guard as
        // the other tab commands; toggles the active tab's per-tab flag.
        tabCommands.toggleTransfers = {
            guard window?.isKeyWindow == true else { return }
            activeTab.transfersPanelVisible.toggle()
        }
        tabCommands.openExternalTerminal = {
            guard window?.isKeyWindow == true else { return }
            guard activeTabSupportsShell else {
                presentTerminalUnavailable()
                return
            }
            requestExternalTerminal(for: activeTab)
        }
        // Snippets in the Terminal menu (Terminal-Snippets milestone) —
        // seeds the mirrored list once, then wires the two entry points.
        // Both handlers are method references rather than inline closures,
        // for the same type-checker reason as `handleCloseActiveTabCommand`
        // above; each carries the key-window guard itself.
        reloadSnippets()
        tabCommands.runSnippet = triggerSnippet
        tabCommands.showSnippets = presentSnippets
    }

    /// Menu-bar status bridge wiring (M11n), called once from `.task`:
    /// seeds `menuBarModel.tabs` and sets its window-raising closures.
    /// `MacSCPApp` owns a separate AppKit `MenuBarController` with no
    /// reference to this view, so the menu's row taps and "Show macSCP" item
    /// call back through these closures — same shape as the `tabCommands` bridge
    /// below, minus the key-window guard (there is nothing to guard against:
    /// raising/activating this one window is always the right action,
    /// whichever window happened to be key when the menu-bar item was
    /// clicked).
    func wireMenuBarBridge() {
        menuBarModel.tabs = tabsModel.tabs
        menuBarModel.focusTab = { id in
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            // Route through the `activate(_:)` wrapper, not `tabsModel.activate`
            // directly (M11n final review): a menu-bar row tap is an activation
            // call site and must clear the tab's attention indicator (reset
            // `seenFailureCount`) just like a tab-strip click or ⌘1–9.
            activate(id)
        }
        menuBarModel.showMainWindow = {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        }
    }

    /// `tabCommands.closeActiveTab` handler (⌘W) — extracted out of the
    /// `.task` closure above (M14/T5 build fix) purely to keep that closure
    /// small enough for the type checker; behavior is unchanged from the
    /// inline version.
    func handleCloseActiveTabCommand() {
        guard window?.isKeyWindow == true else {
            // Not our window: route Close to whichever window IS key
            // (typically Settings) via the system path instead of silently
            // doing nothing.
            NSApp.keyWindow?.performClose(nil)
            return
        }
        let tab = tabsModel.activeTab
        if tabsModel.isLastTab && !tab.isConnected {
            // The only tab left, already a pristine form: Cmd-W closes the
            // WINDOW via the system path instead of the tab-close flow
            // (there is nothing left to revert to).
            window?.performClose(nil)
        } else {
            requestClose(tab)
        }
    }

    /// Mirrors "this window EXISTS" onto `TabCommands`, for the same reason
    /// `isActiveTabConnected`/`hiddenImportsCount` are mirrored there: the
    /// Settings scene cannot see this view's `@State`.
    ///
    /// The three "Manage Data" entries that route here are `.disabled` when
    /// this is `false`. Without it they would still be clickable with no main
    /// window (⌘W on the last, unconnected tab closes the window while the app
    /// keeps running) and would silently do nothing — and in that list, unlike
    /// in the Sessions menu, the user has no window context to explain it: two
    /// rows would open a sheet and three would not react at all.
    ///
    /// Existence, NOT visibility, and the reason is in the handlers rather
    /// than here: they raise the window with `makeKeyAndOrderFront`, which
    /// deminiaturizes and unhides it, so a window that exists is a window the
    /// action works on. That is what keeps this mirror and those guards in
    /// agreement — not that the two spell the same expression, but that
    /// "exists" is a property no state transition can change without also
    /// changing `window` here or closing the window outright. An earlier
    /// version of this pair asked `isVisible` on both sides: same text, but
    /// the guard read it live at click time while this snapshot was only
    /// rewritten from `WindowAccessor` and `willClose` — and neither
    /// miniaturization (⌘M) nor hiding the app goes through either of them.
    /// An enabled row whose click did nothing was the result, which is the
    /// exact defect this mirror was added to remove.
    ///
    /// Writes only on a real change: `@Observable` notifies on every set, this
    /// runs from `WindowAccessor.updateNSView` (i.e. on ordinary body
    /// updates), and `MacSCPApp`'s Scene body reads `tabCommands` — an
    /// unconditional assignment would invalidate the commands/Settings graph
    /// on every repaint of this window. The three mirrors next to it are all
    /// written from `.onChange` for the same reason; M11n was a render storm
    /// over a bridge in this repo already.
    func updateMainWindowPresence() {
        let present = window != nil
        if tabCommands.hasMainWindow != present {
            tabCommands.hasMainWindow = present
        }
    }

    /// `NSWindow.willCloseNotification` for THIS window — the one moment
    /// `updateMainWindowPresence()` cannot catch, since SwiftUI does not re-run
    /// `WindowAccessor` on the way out and `window` is therefore still
    /// non-nil. Hence the explicit `false` rather than a recompute. Every
    /// other window's close (sheets, the Settings window itself, the menu-bar
    /// panel) is filtered out by the identity check.
    ///
    /// Same write-on-change rule as `updateMainWindowPresence()` above: this
    /// notification fires for every window in the app, and the guard already
    /// drops the ones that are not ours, but the assignment stays conditional
    /// so a repeated close of an already-absent window cannot re-notify.
    func handleWindowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        if tabCommands.hasMainWindow {
            tabCommands.hasMainWindow = false
        }
    }

    /// Tab close entry point (strip ✕, ⌘W): a tab with active transfers OF
    /// ITS OWN, or that is currently the DESTINATION of another tab's
    /// cross-session transfer (M8b/T4), requires destructive confirmation
    /// (`closeRequest`, bound to the confirmation dialog above); an
    /// otherwise-idle tab closes immediately.
    func requestClose(_ tab: SessionTab) {
        let incoming = TabCloseWarning.hasIncomingTransfers(for: tab.id, in: tabsModel.tabs)
        if tab.transferQueue.isActive || incoming {
            // Freeze the warning text NOW (M8b review, finding 4) — the
            // dialog reads this snapshot for its whole lifetime instead of
            // recomputing per render, so it can't go blank if the transfers
            // it describes finish while the confirmation is still up.
            closeWarningText = TabCloseWarning.message(
                activeTransfers: tab.transferQueue.isActive, incomingTransfers: incoming)
            closeRequest = tab
        } else {
            Task { await performClose(tab) }
        }
    }

    /// Closes a tab: tab-local teardown first, then either removal from the
    /// model (the last tab is not removable — `TabsViewModel.closeTab`
    /// returns false and it simply stays as a torn-down form tab, reverting
    /// the window to the compact size via `shrinkIfPristine`) or, with
    /// another tab around, removal from the model. Only when the CLOSED tab
    /// was the active one does the auto-activated neighbor get its attention
    /// indicator reset (same rule as `activate(_:)`) — closing a background
    /// tab must not acknowledge failures on the untouched active tab.
    func performClose(_ tab: SessionTab) async {
        await teardown(tab)
        if !tabsModel.isLastTab {
            let wasActive = tab.id == tabsModel.activeTabID
            tabsModel.closeTab(tab.id)
            if wasActive {
                tabsModel.activeTab.seenFailureCount =
                    tabsModel.activeTab.transferQueue.totalFailureCount
            }
        }
        shrinkIfPristine()
    }

    // MARK: - Window geometry

    /// Actively grows/shrinks the window (animated) to the target size while
    /// keeping the top-left corner fixed — AppKit counts `origin.y` from the
    /// bottom, so it's adjusted by the height difference. Growing downward
    /// while the window sits low on its screen can push the computed bottom
    /// edge below the visible area (AppKit's `constrainFrameRect` only
    /// guards the top edge), so the target frame is clamped to the window's
    /// own screen's `visibleFrame` via `clampedToVisibleArea` (M18a/T5b,
    /// `macSCPCore`) before `setFrame` — a frame that's already fully
    /// inside comes back unchanged. If the window can't resolve a screen
    /// (`window.screen` and `NSScreen.main` both `nil`), the frame is set
    /// unclamped rather than dropping the resize.
    ///
    /// This is NOT where a *launch-time* off-screen window comes from
    /// (M18a/T5). That launch position is restored by AppKit's own frame
    /// autosave, which SwiftUI's `WindowGroup` installs for us: the key
    /// `"NSWindow Frame MacSCPApp.ContentView-1-AppWindow-1"` in the app's
    /// user defaults holds `x y w h` plus the SCREEN frame that was current
    /// when it was saved. When the display arrangement changes between runs
    /// (external display detached, or re-arranged above/below the built-in),
    /// AppKit can restore the window onto coordinates no attached screen
    /// covers any more. The app sets no `frameAutosaveName` and persists no
    /// geometry of its own — `lastBrowserSize` below is in-memory `@State`
    /// and is a SIZE only, never an origin. The clamp added here only
    /// bounds frames *this function itself* computes; it does not touch,
    /// and cannot fix, that launch-time restore — do not fold the two
    /// concerns together.
    func resizeWindow(toWidth width: CGFloat, height: CGFloat) {
        guard let window else { return }
        let current = window.frame
        let newOrigin = NSPoint(x: current.origin.x, y: current.origin.y + current.height - height)
        var newFrame = NSRect(origin: newOrigin, size: CGSize(width: width, height: height))
        if let screen = window.screen ?? NSScreen.main {
            newFrame = clampedToVisibleArea(newFrame, visible: screen.visibleFrame)
        }
        window.setFrame(newFrame, display: true, animate: true)
    }

    /// Remembers the browser size and shrinks back to the compact form size
    /// — but ONLY when the action left the window with a single unconnected
    /// tab (M8a/T3). With another tab still around, the window keeps its size.
    func shrinkIfPristine() {
        guard isPristine, let window else { return }
        let size = window.frame.size
        guard size.width > 700 || size.height > 460 else { return }
        lastBrowserSize = size
        resizeWindow(toWidth: 700, height: 460)
    }
}
