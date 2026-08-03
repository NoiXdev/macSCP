import AppKit
import SwiftUI
import macSCPCore

/// Sheet item wrapper: gives `TransferConflict` `Identifiable` conformance
/// without extending the Core type via extension (binding requirement
/// M5b/T4). One fresh UUID per prompt suffices because at most one sheet is
/// ever open at a time.
struct ConflictPromptItem: Identifiable {
    let id = UUID()
    let conflict: TransferConflict
}

/// Holds the continuation for the transfer queue's `ConflictDecider` prompt.
/// Pattern: `ConnectionViewModel.presentHostKeyPrompt`, including the
/// cancellation handler and exactly-once resolution. A reference type
/// (instead of a `@State` field directly on the view) because
/// `TransferQueueViewModel.conflictDecider` is a `@Sendable` closure that
/// outlives the `ContentView` struct. Owned per tab by `SessionTab` (M8a/T3),
/// so a background tab's prompt never presents on the active tab.
@MainActor
@Observable
final class ConflictPromptBridge {
    /// Currently open prompt — drives `.sheet(item:)` in `ContentView`.
    private(set) var currentPrompt: ConflictPromptItem?
    private var continuation:
        CheckedContinuation<(resolution: ConflictResolution, applyToAll: Bool)?, Never>?

    /// Decider side: awaited by `TransferQueueViewModel.conflictDecider`.
    /// Cancellation-safe: if the calling task is cancelled while the prompt
    /// is open, it resolves with `nil` (cancel) instead of hanging.
    func ask(_ conflict: TransferConflict) async
        -> (resolution: ConflictResolution, applyToAll: Bool)?
    {
        currentPrompt = ConflictPromptItem(conflict: conflict)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                self.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(nil)
            }
        }
    }

    /// Called from the sheet buttons. Exactly-once: a second resolution
    /// (e.g. a double click, or dismissal right after a button tap) is
    /// ignored.
    func resolve(_ result: (resolution: ConflictResolution, applyToAll: Bool)?) {
        guard let continuation else { return }
        self.continuation = nil
        currentPrompt = nil
        continuation.resume(returning: result)
    }

    /// Callable from the outside (teardown): resolves a still-open prompt as
    /// "cancel". MUST run before `transferQueue.cancelAll()` — `cancelAll`
    /// blocks (documented) on an open decider prompt that would otherwise
    /// never be answered (deadlock on disconnect with an open sheet).
    func dismiss() {
        resolve(nil)
    }
}

/// Conflict sheet content. Its own view type because of the local toggle
/// state (`applyToAll`) — SwiftUI instantiates it fresh for every sheet
/// presentation.
private struct ConflictSheetView: View {
    let conflict: TransferConflict
    let onResolve: (ConflictResolution, Bool) -> Void
    let onCancel: () -> Void

    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("conflict.title", "File already exists"))
                .font(.headline)
            Text(String(format: L10n.string(
                "conflict.message", "“%@” already exists in “%@”."),
                conflict.fileName, conflict.destinationDirectory))
                .foregroundStyle(.secondary)
            if conflict.isPartOfFolderTransfer {
                Text(L10n.string(
                    "conflict.folderHint",
                    "Canceling stops the whole folder transfer; files already copied are kept."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(L10n.string("conflict.applyToAll", "Apply to all further items"), isOn: $applyToAll)
            HStack {
                Spacer()
                Button(conflict.isPartOfFolderTransfer
                    ? L10n.string("conflict.cancelFolder", "Cancel folder transfer")
                    : L10n.string("common.cancel", "Cancel"),
                    role: .cancel) { onCancel() }
                Button(L10n.string("conflict.rename", "Rename")) { onResolve(.rename, applyToAll) }
                Button(L10n.string("conflict.skip", "Skip")) { onResolve(.skip, applyToAll) }
                Button(L10n.string("conflict.overwrite", "Overwrite"), role: .destructive) {
                    onResolve(.overwrite, applyToAll)
                }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        // Escape/click-outside must NOT resolve the prompt without fulfilling
        // the continuation — that would leave `cancelAll`/the queue hanging.
        // Resolution happens exclusively through the buttons.
        .interactiveDismissDisabled(true)
    }
}

/// Mediates access to the enclosing `NSWindow` — SwiftUI offers no API of
/// its own for this. `view.window` is only set AFTER the `NSView` has been
/// hooked into the window hierarchy, hence the `DispatchQueue.main.async`
/// detour (M5c/T0).
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

struct ContentView: View {
    /// Passed in from `MacSCPApp` (same instance as the `Settings` scene —
    /// no singleton, per the v2 multi-window rule). Wired into every tab's
    /// queue at tab creation and kept in sync via `.onChange` (M5c/T4 queue
    /// parallelism, M5c/T5 bandwidth limits).
    let settingsStore: SettingsStore
    /// App-global bandwidth ceilings (M8a/T2), created once in `MacSCPApp`.
    /// Every tab's queue resolves its throttle from this one instance, so
    /// limits apply in aggregate across tabs (M8a/T3).
    let bandwidthLimiter: BandwidthLimiter
    /// App-wide per-session audit log store (M9b), created once in
    /// `MacSCPApp` (no singleton) — shared by `sessionListViewModel` (log
    /// cleanup on delete) and every stored-session tab's `AuditRecorder`
    /// (see `attachAuditRecorder`).
    let auditStore: AuditLogStore
    /// Command bridge (M8a/T4): `MacSCPApp` holds no reference to
    /// `ContentView`, so the menu's Cmd-N/Cmd-W/Cmd-1…9 items call into the
    /// closures this view assigns in `.task` below.
    let tabCommands: TabCommands
    /// App-global update-check state (M11b/T2), created once in
    /// `MacSCPApp` (no singleton, same pattern as the stores above). Its
    /// result alert lives here because this is the app's one window — the
    /// same place the app-global import/export result alerts already live,
    /// despite those also being triggered from the app-wide Sessions menu.
    let updateModel: UpdateCheckModel
    /// Menu-bar status bridge (M11n), created once in `MacSCPApp` (no
    /// singleton, same pattern as the stores above) and shared with the
    /// AppKit `MenuBarController` there. This view mirrors `tabsModel.tabs`
    /// into it and sets its window-raising closures in `.task`/`.onChange`
    /// below — see `MenuBarStatusModel`'s doc comment.
    let menuBarModel: MenuBarStatusModel
    /// Assigned in `init` (not a bare default value) so it can pass
    /// `auditStore` through — mirrors `_tabsModel` below.
    @State private var sessionListViewModel: SessionListViewModel
    /// Window-scoped tab collection (M8a/T3). Everything that used to be
    /// window-wide session state (connection form, session, queue, conflict
    /// bridge, title, edit error, reconnect flag) now lives per tab in
    /// `SessionTab`; only `window`, `lastBrowserSize`, `importedHosts`,
    /// `sessionListViewModel` and the two injected stores stay window-wide.
    @State private var tabsModel: TabsViewModel<SessionTab>
    @State private var importedHosts: [SSHConfigHost] = []
    /// The full, unfiltered `~/.ssh/config` parse (M11f/T2) — read from disk
    /// exactly once in `.task` below. `refreshImportedHosts()` re-derives
    /// `importedHosts`/`hiddenImportAliases` from THIS, never by re-reading
    /// the config file, so hiding/unhiding an entry can never race a
    /// concurrent edit of the file the user made in a text editor.
    @State private var fullImportedHosts: [SSHConfigHost] = []
    /// Aliases currently hidden from the IMPORTED sidebar section (M11f/T2),
    /// freshly read from `HiddenImportStore` by every `refreshImportedHosts()`
    /// call. Its count drives the Sessions-menu/background-menu "Hidden
    /// Imports…" title (see `tabCommands.hiddenImportsCount` below).
    @State private var hiddenImportAliases: [String] = []
    /// Red inline message after `HiddenImportStore.hide`/`allHidden` throws
    /// (M11f/T2 review, findings 1+2) — same pattern as
    /// `SessionSidebar.jumpRestoreErrorMessage`. Both `hideImported` and
    /// `refreshImportedHosts` write here so a store failure is reported
    /// instead of silently leaving the row in place (hide) or failing open
    /// (refresh); cleared on the next successful `refreshImportedHosts`.
    @State private var hiddenImportsErrorMessage: String?
    /// Handed over by `WindowAccessor` — basis for the active resize calls
    /// on state transitions (M5c/T0).
    @State private var window: NSWindow?
    /// Last browser window size, remembered on disconnect — the next
    /// connect grows to it instead of the minimum size, if it's larger.
    @State private var lastBrowserSize: CGSize?
    /// Tab pending a destructive close confirmation (active transfers) — nil
    /// when no confirmation is showing (M8a/T4).
    @State private var closeRequest: SessionTab?
    /// Warning text for `closeRequest`, frozen at the moment the dialog is
    /// requested (M8b review, finding 4). The dialog's `message:` builder
    /// re-evaluates on every render; recomputing `closeWarningMessage(for:)`
    /// there instead of reading this snapshot would let the text go blank
    /// mid-dialog if the underlying transfers finish while it's still open —
    /// blank text under a destructive "Close" button.
    @State private var closeWarningText: String = ""

    // MARK: - Audit log (M9b/T3)

    /// Session whose audit log sheet is open, or `nil` when none is —
    /// `StoredSession` drives `.sheet(item:)` directly (it's already
    /// `Identifiable`). Opened from the sidebar's "Audit Log…" entry, works
    /// whether or not that session is currently connected.
    @State private var auditLogSession: StoredSession?

    // MARK: - Known hosts (M10a/T2)

    /// Drives the known-hosts management sheet — opened from the Sessions
    /// menu (⌘⇧K) and the sidebar's background context menu. No item payload
    /// needed (unlike `auditLogSession`): the sheet always shows the same,
    /// window-wide store.
    @State private var showKnownHostsSheet = false

    // MARK: - Login sets (M10b/T3)

    /// Drives the login-sets management sheet — opened from the Sessions
    /// menu (⌘⇧L) and the sidebar's background context menu. Same
    /// no-item-payload shape as `showKnownHostsSheet` above (always the same
    /// window-wide `sessionListViewModel`).
    @State private var showLoginSetsSheet = false
    /// Arms the login-sets sheet to open its file picker straight away
    /// (M19/T8): the Sessions menu's "Import Logins…" opens the SAME sheet the
    /// import lives in, rather than growing a second import implementation
    /// here — and the sheet is where the result belongs anyway, since the
    /// imported sets appear in its list.
    @State private var loginSetsSheetStartsImport = false

    // MARK: - Hidden imports (M11f/T2)

    /// Drives the hidden-imports management sheet — opened from the
    /// Sessions menu (⌘⇧I) and the sidebar's background context menu. Same
    /// no-item-payload shape as `showKnownHostsSheet`/`showLoginSetsSheet`
    /// above: the sheet always reflects `fullImportedHosts` plus a fresh
    /// `HiddenImportStore` read of its own.
    @State private var showHiddenImportsSheet = false

    // MARK: - SSH keys (M18/T5)

    /// Drives the SSH-key management sheet — opened from the Sessions menu.
    /// Same no-item-payload shape as `showKnownHostsSheet`/
    /// `showLoginSetsSheet`/`showHiddenImportsSheet` above: `SSHKeysSheet`
    /// always reflects the same window-wide `ManagedKeyStore` directory.
    @State private var showSSHKeysSheet = false

    // MARK: - Session export/import (M9a/T3)

    /// Wraps `ExportScope` so it can drive `.sheet(item:)` — `ExportScope`
    /// itself has no stable identity of its own that covers all three cases
    /// (`.all` has none at all).
    private struct ExportSheetItem: Identifiable {
        let id = UUID()
        let scope: SessionListViewModel.ExportScope
    }

    @State private var exportSheetItem: ExportSheetItem?

    /// A decoded session-import payload plus whether the file it came from was
    /// itself encrypted (which the result alert's plaintext notice needs).
    private struct PendingSessionImport {
        let payload: SessionExportPayload
        let wasEncrypted: Bool
    }

    // MARK: - Share link (M14/T5)

    /// Wraps the single selected remote file's S3 key plus the presigned
    /// provider captured at presentation time — the same "capture now,
    /// not later" discipline `detail`'s `bridge`/`tab` locals already use for
    /// the conflict sheet, so the sheet keeps talking to the file system it
    /// was opened against even if the active tab changes underneath it.
    private struct PresignedSheetItem: Identifiable {
        let id = UUID()
        /// The object key (no leading slash) `PresignedURLSheet` pre-fills
        /// for both GET (read-only) and PUT (editable) — see
        /// `RemotePath.normalizedAbsolute` at the call site for how a
        /// `RemoteFileItem.path` becomes this.
        let itemKey: String
        let provider: any PresignedURLProvider
    }

    @State private var presignedSheetItem: PresignedSheetItem?
    /// Set by `performExport` right before `showExportFileExporter` — the
    /// `fileExporter` completion handler reads it to decide whether the
    /// "exported without password" alert is needed (spec M9a §3.3).
    @State private var exportDocument: SessionExportDocument?
    @State private var showExportFileExporter = false
    @State private var exportMissingPasswordCount = 0
    @State private var showExportMissingPasswordAlert = false
    @State private var exportErrorMessage: String?

    @State private var showImportFileImporter = false
    /// Bytes read from the chosen import file, held between the initial
    /// `probe` and the (optional) password prompt's `decode` attempt.
    @State private var importFileData: Data?
    @State private var showImportPasswordSheet = false
    /// A successfully decoded payload waiting to be planned and applied
    /// (M19/T8). Planning can open the conflict sheet, and SwiftUI presents
    /// only one sheet per view at a time — so an import that came through the
    /// password prompt decodes while that prompt is up and plans only once it
    /// has closed. Without the split, the conflict sheet would never appear
    /// and the password sheet would wait on it forever.
    @State private var pendingImport: PendingSessionImport?
    /// Bridges the shared `ImportConflictSheet`'s callbacks to the
    /// `ImportConflictArbiter`'s decider for SESSION imports (login-set
    /// imports own an instance of the same bridge inside `LoginSetsSheet`).
    @State private var importConflictBridge = ImportConflictBridge()
    @State private var importResultMessage: String = ""
    @State private var showImportResultAlert = false
    @State private var importErrorMessage: String?

    // MARK: - External terminal (M11d/T2)

    /// One requested external-terminal open, captured between the moment the
    /// toolbar button/menu entry fires and the moment the password hint (if
    /// shown) is answered — `performExternalOpen` needs all four values.
    private struct ExternalTerminalRequest {
        let config: SSHConnectionConfig
        let target: TerminalTarget
        let customPath: String?
    }

    /// Non-nil while the "external terminals can't receive a saved password"
    /// hint is showing (spec §4 item 6) — drives its alert below.
    @State private var pendingPasswordHintRequest: ExternalTerminalRequest?
    /// Set by `performExternalOpen` on `ExternalTerminalLauncher.LaunchError`
    /// — drives the error alert below (spec §4 item 7).
    @State private var externalTerminalErrorMessage: String?
    /// Set when a shell-only command (⌘T/toolbar Terminal button, or the
    /// "Terminal" menu's two entries) is invoked while the active tab's
    /// backend has no shell (M12/T7b, e.g. an S3 session) — drives the
    /// alert below. Both the toolbar button and the menu bridge closures are
    /// ALSO disabled for this condition (belt-and-suspenders): this message
    /// is the "no silent no-op" fallback for any path that reaches the
    /// action despite the disabled state.
    @State private var terminalUnavailableAlertMessage: String?

    init(
        settingsStore: SettingsStore, bandwidthLimiter: BandwidthLimiter, auditStore: AuditLogStore,
        tabCommands: TabCommands, updateModel: UpdateCheckModel, menuBarModel: MenuBarStatusModel
    ) {
        self.settingsStore = settingsStore
        self.bandwidthLimiter = bandwidthLimiter
        self.auditStore = auditStore
        self.tabCommands = tabCommands
        self.updateModel = updateModel
        self.menuBarModel = menuBarModel
        _tabsModel = State(initialValue: TabsViewModel(
            initial: Self.makeTab(settingsStore: settingsStore, limiter: bandwidthLimiter)))
        _sessionListViewModel = State(initialValue: SessionListViewModel(
            store: SessionStore(directory: SessionStore.defaultDirectory),
            secrets: KeychainSecretStore(),
            auditStore: auditStore
        ))
    }

    /// The mounted tab. Every view below renders THIS tab's state; switching
    /// tabs re-resolves all of it (sheet, banners, queue bar, toolbar).
    private var activeTab: SessionTab { tabsModel.activeTab }

    /// "Fresh window" state: a single, unconnected tab. Drives the compact
    /// form geometry — with a second tab around, the window keeps its
    /// browser size even while the active tab shows a form.
    private var isPristine: Bool {
        tabsModel.isLastTab && !tabsModel.activeTab.isConnected
    }

    /// Mirrored into `tabCommands.isActiveTabConnected` via `.onChange` below
    /// (M11d/T2) — `MacSCPApp`'s "Terminal" menu lives in a separate Scene
    /// that doesn't observe `tabsModel`, so this is the value it reads to
    /// enable/disable its two entries.
    private var isActiveTabConnected: Bool { activeTab.isConnected }

    /// Mirrored into `tabCommands.activeTabSupportsShell` via `.onChange`
    /// below (M12/T7b), same rationale/mechanism as `isActiveTabConnected`
    /// above — the active tab's backend has no shell for an S3 session, and
    /// `MacSCPApp`'s "Terminal" menu needs to know that too.
    private var activeTabSupportsShell: Bool {
        BackendDescriptor.descriptor(for: activeTab.connectionViewModel.kind).capabilities.supportsShell
    }

    var body: some View {
        // Split from `mainContent` (M11d/T2 build fix): the External
        // Terminal `.onChange`/two `.alert`s below, chained directly onto
        // the already-large modifier chain, made the type checker time out
        // ("unable to type-check this expression in reasonable time") —
        // splitting the chain into two smaller expressions fixes that
        // without changing behavior.
        mainContent
            // Keeps `tabCommands.isActiveTabConnected` in sync (M11d/T2) —
            // see that property's doc comment for why `MacSCPApp`'s
            // "Terminal" menu needs this mirrored instead of reading
            // `tabsModel` directly. `initial: true` seeds it once at first
            // render too, not just on later transitions.
            .onChange(of: isActiveTabConnected, initial: true) { _, newValue in
                tabCommands.isActiveTabConnected = newValue
            }
            // Keeps `tabCommands.activeTabSupportsShell` in sync (M12/T7b) —
            // see that property's doc comment; mirrors `isActiveTabConnected`
            // above for the identical reason.
            .onChange(of: activeTabSupportsShell, initial: true) { _, newValue in
                tabCommands.activeTabSupportsShell = newValue
            }
            // Mirrors `hiddenImportAliases.count` into the command bridge
            // (M11f/T2, same rationale as `isActiveTabConnected` above):
            // `MacSCPApp`'s "Sessions" menu lives in a separate Scene that
            // doesn't observe this view's `@State`, so the "Hidden
            // Imports…" title's count suffix has to be mirrored here too.
            .onChange(of: hiddenImportAliases.count, initial: true) { _, newValue in
                tabCommands.hiddenImportsCount = newValue
            }
            // Password-login hint (M11d/T2, spec §4 item 6): shown once
            // before the FIRST external-terminal open of a
            // password-authenticated session, since macSCP cannot hand a
            // saved password to an outside process — ssh prompts there
            // instead. "Don't show again" persists the flag before opening;
            // "Open" opens without persisting it, so the hint reappears
            // next time.
            .alert(
                L10n.string("externalTerminal.passwordHint.title", "Password Login"),
                isPresented: passwordHintPresented
            ) {
                Button(L10n.string("externalTerminal.passwordHint.dontShowAgain", "Don't show again")) {
                    if let request = pendingPasswordHintRequest {
                        settingsStore.externalTerminalPasswordHintShown = true
                        Task {
                            await performExternalOpen(
                                config: request.config, target: request.target, customPath: request.customPath)
                        }
                    }
                    pendingPasswordHintRequest = nil
                }
                Button(L10n.string("externalTerminal.passwordHint.open", "Open")) {
                    if let request = pendingPasswordHintRequest {
                        Task {
                            await performExternalOpen(
                                config: request.config, target: request.target, customPath: request.customPath)
                        }
                    }
                    pendingPasswordHintRequest = nil
                }
                .keyboardShortcut(.defaultAction)
            } message: {
                Text(L10n.string(
                    "externalTerminal.passwordHint.message",
                    "macSCP can't hand a saved password to an external terminal — ssh will ask you for it there."))
            }
            // External-terminal launch failures (M11d/T2, spec §4 item 7):
            // `ExternalTerminalLauncher.LaunchError` is mapped to a concrete
            // message (app name/path, or the write-failure reason) in
            // `performExternalOpen` below.
            .alert(
                L10n.string("externalTerminal.error.title", "Couldn't Open External Terminal"),
                isPresented: externalTerminalErrorPresented
            ) {
                Button(L10n.string("common.ok", "OK"), role: .cancel) {}
            } message: {
                Text(externalTerminalErrorMessage ?? "")
            }
            // Shell-only shortcut invoked on a non-shell backend (M12/T7b) —
            // see `terminalUnavailableAlertMessage`'s doc comment.
            .alert(
                L10n.string("shortcut.unavailableForProtocol.title", "Not Available"),
                isPresented: Binding(
                    get: { terminalUnavailableAlertMessage != nil },
                    set: { isPresented in if !isPresented { terminalUnavailableAlertMessage = nil } })
            ) {
                Button(L10n.string("common.ok", "OK"), role: .cancel) {}
            } message: {
                Text(terminalUnavailableAlertMessage ?? "")
            }
    }

    private var mainContent: some View {
        HSplitView {
            SessionSidebar(
                viewModel: sessionListViewModel,
                importedHosts: importedHosts,
                activeSessionID: activeTab.activeStoredSessionID,
                // A running transfer no longer locks the sidebar (M8a): a
                // sidebar click opens a NEW tab instead of tearing the
                // connected one down. Only the active tab's own in-flight
                // connect/reconnect blocks interaction.
                interactionsDisabled: activeTab.isReconnecting
                    || activeTab.connectionViewModel.state == .connecting,
                onSelect: { stored in connectFromSidebar(stored) },
                onDelete: { stored in
                    // Return value (M11a/T3): the sidebar surfaces
                    // `secretFailures` as its own red inline message, the
                    // same way `LoginSetsSheet.deleteSelected()` does for
                    // `deleteLoginSet`.
                    let result = sessionListViewModel.delete(stored)
                    for tab in tabsModel.tabs where tab.activeStoredSessionID == stored.id {
                        tab.activeStoredSessionID = nil
                        // Same release as `teardown`'s audit recorder block
                        // (M9b/T4 review, finding 1): leaving `auditRecorder`
                        // and its two sinks wired after the STORE's log file
                        // was just deleted means the next event (teardown's
                        // own `recordDisconnected()` is guaranteed to fire
                        // later) recreates `audit/<id>.json` from scratch —
                        // an unreachable, permanent orphan, since no session
                        // list entry (and no sidebar menu) points at that id
                        // anymore.
                        tab.auditRecorder = nil
                        tab.transferQueue.auditSink = nil
                        tab.session?.remote.auditSink = nil
                    }
                    return result
                },
                onNew: { newConnection() },
                onSelectImported: { fillFromImported($0) },
                onEdit: { stored in editStored(stored) },
                onExport: { scope in exportSheetItem = ExportSheetItem(scope: scope) },
                onImport: { showImportFileImporter = true },
                onShowAuditLog: { stored in auditLogSession = stored },
                onShowKnownHosts: { showKnownHostsSheet = true },
                onShowLogins: { showLoginSetsSheet = true },
                onHideImported: { host in hideImported(host) },
                onShowHiddenImports: { showHiddenImportsSheet = true },
                hiddenImportsCount: hiddenImportAliases.count,
                hiddenImportsErrorMessage: hiddenImportsErrorMessage
            )
            .frame(minWidth: 170, idealWidth: 190, maxWidth: 260)

            VStack(spacing: 0) {
                // Hidden in the pristine (single unconnected tab) state — a
                // strip with nothing to switch between would just be clutter
                // (M8a/T4 spec 2).
                if !isPristine {
                    TabStripView(
                        tabs: tabsModel.tabs,
                        activeTabID: tabsModel.activeTabID,
                        onActivate: { activate($0) },
                        onClose: { requestClose($0) },
                        onAdd: { tabsModel.addTab(makeTab()) }
                    )
                }
                detail
            }
            // The detail minimum must fit inside the window minimum
            // below together with the sidebar minimum (170), otherwise
            // the split view's content overflows the window and gets
            // clipped on both sides instead of shrinking.
            .frame(minWidth: isPristine ? 500 : 590, maxWidth: .infinity)
        }
        // Compact form vs. browser: the minimum size depends on the window's
        // pristine state (M5c/T0, M8a/T3) — replaces the global `.frame` from
        // `MacSCPApp.swift`.
        .frame(minWidth: isPristine ? 700 : 930, minHeight: 460)
        .tint(DesignTokens.remoteBlue)
        .navigationTitle(activeTab.titleName.map { "macSCP — \($0)" } ?? "macSCP")
        .background(WindowAccessor { window = $0 })
        .task {
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
            tabCommands.toggleTerminal = {
                guard window?.isKeyWindow == true else { return }
                guard activeTabSupportsShell else {
                    presentTerminalUnavailable()
                    return
                }
                activeTab.session?.terminal.toggle()
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
        }
        // Destructive confirmation for closing a tab with active transfers
        // (M8a/T4) — mirrors `SessionSidebar`'s delete-confirmation pattern.
        // An idle tab bypasses this and closes immediately (`requestClose`).
        .confirmationDialog(
            L10n.string("tabs.close.title", "Close tab?"),
            isPresented: Binding(
                get: { closeRequest != nil },
                set: { isPresented in if !isPresented { closeRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("tabs.close.confirm", "Close"), role: .destructive) {
                if let tab = closeRequest {
                    closeRequest = nil
                    Task { await performClose(tab) }
                }
            }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {
                closeRequest = nil
            }
        } message: {
            Text(closeWarningText)
        }
        // Export sheet (M9a/T3): one view for all three scopes, opened by
        // the sidebar's context menus via `exportSheetItem`.
        .sheet(item: $exportSheetItem) { item in
            SessionExportSheet(
                viewModel: sessionListViewModel,
                scope: item.scope,
                onExport: { options in performExport(scope: item.scope, options: options) }
            )
        }
        // Share-link sheet (M14/T5): opened from the remote pane's
        // "Share Link…" context-menu entry (an S3-only `backendFileAction`,
        // see `detail` below) — never offered for SSH, since its descriptor's
        // `fileActions` is empty.
        .sheet(item: $presignedSheetItem) { item in
            PresignedURLSheet(
                itemKey: item.itemKey, provider: item.provider, settingsStore: settingsStore)
        }
        // Audit log sheet (M9b/T3): opened from the sidebar context menu,
        // available whether or not the session is currently connected — it
        // reads straight from `auditStore`, independent of any tab.
        .sheet(item: $auditLogSession) { stored in
            AuditLogSheet(session: stored, store: auditStore)
        }
        // Known-hosts sheet (M10a/T2) — same directory the connector's
        // `KnownHostsStore` uses (`makeTab` below), so it reflects the same
        // TOFU state the connect flow reads from.
        .sheet(isPresented: $showKnownHostsSheet) {
            KnownHostsSheet(store: KnownHostsStore(directory: SessionStore.defaultDirectory))
        }
        // Login-sets sheet (M10b/T3) — shares `sessionListViewModel` (not a
        // fresh store) so the Sessions-menu/sidebar entry point and the
        // form's own local "Manage logins…" sheet (`ConnectionFormView`)
        // always show the exact same, up-to-date list.
        .sheet(isPresented: $showLoginSetsSheet, onDismiss: {
            loginSetsSheetStartsImport = false
        }) {
            LoginSetsSheet(
                sessionList: sessionListViewModel, startsImport: loginSetsSheetStartsImport)
        }
        // SSH-keys sheet (M18/T5) — standalone overlay replacement for the
        // M17 Settings tab; owns its own `ManagedKeyStore` instance the same
        // way `showKnownHostsSheet` above does for `KnownHostsStore` (there
        // is no shared observable object to pass in, unlike
        // `showLoginSetsSheet`'s `sessionListViewModel`).
        .sheet(isPresented: $showSSHKeysSheet) {
            SSHKeysSheet()
        }
        // Hidden-imports sheet (M11f/T2) — `fullImportedHosts` is the SAME
        // full inventory `refreshImportedHosts()` reads from, so the sheet's
        // "still in config"/"orphaned" split matches the sidebar exactly.
        // `onChange` re-derives `importedHosts`/`hiddenImportAliases` after
        // every unhide, so the sidebar's IMPORTED section and the menu
        // count stay live while the sheet is still open.
        .sheet(isPresented: $showHiddenImportsSheet) {
            HiddenImportsSheet(
                store: HiddenImportStore(directory: SessionStore.defaultDirectory),
                hosts: fullImportedHosts,
                onChange: { refreshImportedHosts() }
            )
        }
        .fileExporter(
            isPresented: $showExportFileExporter,
            document: exportDocument,
            contentType: .macscpSessions,
            defaultFilename: "macSCP Sessions.macscpsessions"
        ) { result in
            handleExportResult(result)
        }
        .alert(
            L10n.string("export.error.title", "Export Failed"),
            isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { isPresented in if !isPresented { exportErrorMessage = nil } })
        ) {
            Button(L10n.string("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "")
        }
        .alert(
            L10n.string("export.result.title", "Export Complete"),
            isPresented: $showExportMissingPasswordAlert
        ) {
            Button(L10n.string("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(String(
                format: L10n.string("export.missingPasswords %lld", "Exported without password: %lld"),
                exportMissingPasswordCount))
        }
        // Import flow (M9a/T3): file picker → probe → optional password
        // sheet → decode/plan/apply → result/error alert. No auto-connect
        // after import (spec M9a §3.5).
        .fileImporter(
            isPresented: $showImportFileImporter,
            allowedContentTypes: [.macscpSessions, .json],
            allowsMultipleSelection: false
        ) { result in
            handleImportFileSelection(result)
        }
        .sheet(isPresented: $showImportPasswordSheet, onDismiss: {
            // Covers every dismissal path, including ESC/click-outside,
            // which bypasses the sheet's own Cancel button and its
            // `onCancel` handler below (M9a final review, Finding 4) — the
            // pending ciphertext must not linger in view state either way.
            importFileData = nil
            // Planning happens HERE, not in the sheet: it may open the
            // conflict sheet, which cannot present while this one is up
            // (M19/T8). A cancelled prompt leaves `pendingImport` nil and
            // nothing runs.
            if let pending = pendingImport {
                pendingImport = nil
                Task { await applyImport(pending) }
            }
        }) {
            ImportPasswordSheet(
                onSubmit: { password in
                    guard let data = importFileData else { return nil }
                    switch decodeImport(data: data, password: password) {
                    case .ready(let pending):
                        // Parked for `onDismiss` above; dismissing is what
                        // clears the way for the conflict sheet.
                        pendingImport = pending
                        return nil
                    case .retry(let message):
                        return message
                    case .failed:
                        return nil
                    }
                },
                onCancel: {
                    importFileData = nil
                    pendingImport = nil
                }
            )
        }
        // Shared import conflict sheet (M19/T7) for SESSION imports — the
        // login-set import presents the same view through the same modifier
        // inside `LoginSetsSheet`, so the resumption contract documented on
        // `importConflictSheet(bridge:)` covers both flows.
        .importConflictSheet(bridge: importConflictBridge)
        .alert(
            L10n.string("import.error.title", "Import Failed"),
            isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { isPresented in if !isPresented { importErrorMessage = nil } })
        ) {
            Button(L10n.string("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "")
        }
        .alert(
            L10n.string("import.result.title", "Import Complete"),
            isPresented: $showImportResultAlert
        ) {
            Button(L10n.string("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(importResultMessage)
        }
        // Update-check result (M11b/T2, spec §4): a manual "Check for
        // Updates…" always shows one of these four outcomes; the startup
        // automatic only ever reaches this alert for `.updateAvailable`
        // (see `UpdateCheckModel.check`, which stays silent otherwise).
        .alert(
            updateAlertTitle,
            isPresented: Binding(
                get: { updateModel.presentedResult != nil },
                set: { isPresented in if !isPresented { updateModel.presentedResult = nil } })
        ) {
            if case .updateAvailable(_, _, let url) = updateModel.presentedResult {
                Button(L10n.string("update.openReleasePage", "Open Release Page")) {
                    NSWorkspace.shared.open(url)
                }
                Button(L10n.string("update.later", "Later"), role: .cancel) {}
            } else {
                Button(L10n.string("common.ok", "OK"), role: .cancel) {}
            }
        } message: {
            Text(updateAlertMessage)
        }
        // Marks this `ContentView` as the (only) presenter of
        // `updateModel.presentedResult` while it's actually in the view
        // hierarchy (M11b final review, Finding I2): a manual check that
        // finds nobody mounted falls back to a plain `NSAlert` instead (see
        // `UpdateCheckModel.check`/`presentFallbackAlert`). On disappear —
        // this window closing — any leftover `presentedResult` is cleared
        // too, so a check that completed just as the window went away can
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
                        // offers the other one too.
                        if settingsStore.terminalTarget == .builtIn {
                            session.terminal.toggle()
                        } else {
                            requestExternalTerminal(for: activeTab)
                        }
                    } label: {
                        Label(L10n.string("browser.terminalToggle", "Terminal"), systemImage: "terminal")
                    }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(!activeTabSupportsShell)
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
        // time" budget (same failure class as `passwordHintPresented` below).
        .onChange(of: tabIDs) { _, _ in
            menuBarModel.tabs = tabsModel.tabs
        }
    }

    /// See the `.onChange(of: tabIDs)` call above.
    private var tabIDs: [UUID] {
        tabsModel.tabs.map(\.id)
    }

    /// Extracted from the `.alert(isPresented:)` call above (M11d/T2 build
    /// fix): inlined there, the whole modifier chain's combined closures made
    /// the type checker time out ("unable to type-check this expression in
    /// reasonable time") — a named computed `Binding` sidesteps that without
    /// changing behavior.
    private var passwordHintPresented: Binding<Bool> {
        Binding(
            get: { pendingPasswordHintRequest != nil },
            set: { isPresented in if !isPresented { pendingPasswordHintRequest = nil } })
    }

    /// Same fix as `passwordHintPresented` above, for the error alert.
    private var externalTerminalErrorPresented: Binding<Bool> {
        Binding(
            get: { externalTerminalErrorMessage != nil },
            set: { isPresented in if !isPresented { externalTerminalErrorMessage = nil } })
    }

    @ViewBuilder
    private var detail: some View {
        let tab = activeTab
        // Captured once per `detail` evaluation (M8a T5 review, finding 3):
        // the sheet's four closures below all read THIS tab's bridge, not
        // `tabsModel.activeTab` at call time. Without this, ⌘1–9 switching
        // the active tab while the sheet is still up would make `onDismiss`/
        // `onCancel`/`onResolve` resolve the NEWLY active tab's prompt
        // instead of the one actually presenting the sheet. Invariant: the
        // sheet always talks to its presenting tab's bridge, for its whole
        // lifetime, regardless of what becomes active afterwards.
        let bridge = tab.conflictBridge
        Group {
            if let session = tab.session {
                VStack(spacing: 0) {
                    VSplitView {
                        HSplitView {
                            BrowserPane(
                                title: L10n.string("browser.paneLocal", "Local"),
                                tint: DesignTokens.localAmber,
                                softTint: DesignTokens.localSoft,
                                viewModel: session.local,
                                side: .local,
                                fileSystem: session.localFS,
                                pasteboardWriter: { item in
                                    item.kind == .file
                                        ? NSURL(fileURLWithPath: item.path)
                                        : nil
                                },
                                onMenuAction: { entry, selection in
                                    switch entry {
                                    case .transferToOtherPane:
                                        transferSelection(
                                            selection, from: .local, in: tab, session: session)
                                    case .transferToSession(let target):
                                        transferToSession(
                                            selection, from: .local, target: target,
                                            in: tab, session: session)
                                    case .copyPath:
                                        copyPaths(of: selection)
                                    case .openInEditor:
                                        break   // never emitted for the local pane (menu model)
                                    case .rename, .infoAndPermissions, .newFolder, .newFile, .delete:
                                        break   // handled inside BrowserPane, never forwarded
                                    case .backendFileAction:
                                        break   // never contributed on the LOCAL pane (fileActions is nil here)
                                    }
                                },
                                crossSessionTargets: { crossSessionTargets(for: tab) },
                                visibleColumns: settingsStore.visibleColumns
                            )
                            .frame(minWidth: 280)

                            BrowserPane(
                                title: L10n.string("browser.paneRemote", "Remote"),
                                tint: DesignTokens.remoteBlue,
                                softTint: DesignTokens.remoteSoft,
                                viewModel: session.remote,
                                side: .remote,
                                onDropURLs: { urls in
                                    uploadDropped(urls, in: tab, session: session)
                                },
                                onOpenFile: { item in
                                    openInEditor(item, in: tab, session: session)
                                },
                                fileSystem: session.remoteFS,
                                pasteboardWriter: { item in
                                    item.kind == .file
                                        ? remotePromiseProvider(for: item, in: tab, session: session)
                                        : nil
                                },
                                onMenuAction: { entry, selection in
                                    switch entry {
                                    case .transferToOtherPane:
                                        transferSelection(
                                            selection, from: .remote, in: tab, session: session)
                                    case .transferToSession(let target):
                                        transferToSession(
                                            selection, from: .remote, target: target,
                                            in: tab, session: session)
                                    case .openInEditor:
                                        if let item = selection.first {
                                            openInEditor(item, in: tab, session: session)
                                        }
                                    case .copyPath:
                                        copyPaths(of: selection)
                                    case .rename, .infoAndPermissions, .newFolder, .newFile, .delete:
                                        break   // handled inside BrowserPane, never forwarded
                                    case .backendFileAction(let action):
                                        // Currently the only backend-contributed action is
                                        // S3's presigned URL (M14/T5) — keyed off `action.id`
                                        // so a future second contribution doesn't need a new
                                        // `BrowserMenuEntry` case, just another `if` here.
                                        // `selection.count == 1` mirrors the menu-model gate
                                        // (`BrowserContextMenu.entries`) that only ever offers
                                        // `backendFileAction` for a single selected file.
                                        if action.id == "s3.presignedURL",
                                            selection.count == 1, let file = selection.first,
                                            let provider = session.remoteFS as? PresignedURLProvider
                                        {
                                            // Same "no leading slash" convention
                                            // `S3FileSystem.objectKey(forPath:)` uses
                                            // internally: normalize first (collapses any
                                            // repeated slashes), then drop the single
                                            // leading one.
                                            let normalizedPath = RemotePath.normalizedAbsolute(file.path)
                                            let key = normalizedPath == "/" ? "" : String(normalizedPath.dropFirst())
                                            presignedSheetItem = PresignedSheetItem(
                                                itemKey: key, provider: provider)
                                        }
                                    }
                                },
                                crossSessionTargets: { crossSessionTargets(for: tab) },
                                fileActions: {
                                    BackendDescriptor.descriptor(for: tab.connectionViewModel.kind)
                                        .fileActions
                                },
                                visibleColumns: settingsStore.visibleColumns
                            )
                            .frame(minWidth: 280)
                        }
                        .frame(minHeight: 200)
                        .layoutPriority(1)

                        if session.terminal.isVisible {
                            terminalPanel(session)
                                .frame(minHeight: 120, idealHeight: 220)
                        }
                    }

                    // Resume banner: displayed when the ACTIVE tab has interrupted
                    // transfers (M5d/T4). Clicking "Resume" re-enqueues them with
                    // that tab's file systems and resume semantics enabled.
                    //
                    // No capability gate needed here (M12/T7b): the banner is
                    // governed by `ProtocolCapabilities.resumeMode`, but an
                    // S3 session can never populate `hasInterrupted` in the
                    // first place today — `S3FileSystem`'s read/write both
                    // throw `.protocolError` immediately (deferred to M13),
                    // so no S3 transfer can ever reach "interrupted" (that
                    // requires a transfer to have started and been cut off
                    // mid-flight). Gating this now would be dead code; M13
                    // is where `resumeMode == .rangeGet`'s actual mechanics
                    // (distinct from SSH's `.append`) need to be wired here.
                    if tab.transferQueue.hasInterrupted {
                        HStack {
                            Text(L10n.string(
                                "transfers.interrupted.banner",
                                "Interrupted transfers can be resumed."))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(L10n.string("transfers.interrupted.resume", "Resume")) {
                                tab.transferQueue.retryInterrupted(
                                    source: session.localFS,
                                    destination: session.remoteFS)
                            }
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .controlBackgroundColor))
                    }

                    // Edit-open error (M5e/T4): subtle inline message, matching
                    // the resume banner's placement/styling above. Dismissible;
                    // cleared automatically on the next successful editor open.
                    if let editErrorMessage = tab.editErrorMessage {
                        HStack {
                            Text(editErrorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                            Spacer()
                            Button {
                                tab.editErrorMessage = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }

                    if tab.transfersPanelVisible {
                        TransferQueueBar(viewModel: tab.transferQueue)
                    }
                }
                .onChange(of: tab.transferQueue.items.count) { oldCount, newCount in
                    // A newly enqueued transfer reveals the bar (M11o) — the
                    // pre-M11o auto-appear behavior, now gated by the per-tab
                    // visibility flag. Only an INCREASE reveals; clearing or
                    // finishing items never force-hides.
                    if newCount > oldCount {
                        tab.transfersPanelVisible = true
                    }
                }
                .task(id: session.id) {
                    // Auto-refresh loop (M9c): lives inside the tab's `.id` identity,
                    // so switching tabs (or disconnecting) cancels it and the next
                    // active tab starts its own. Keyed on the SESSION id as a
                    // defensive guard (final review): even a hypothetical
                    // synchronous session swap without a branch flip would
                    // restart the loop against the new session.
                    // Reads the settings fresh every lap
                    // so changes apply without restart; skipped laps just sleep on.
                    while !Task.isCancelled {
                        let seconds = settingsStore.autoRefreshIntervalSeconds
                        try? await Task.sleep(for: .seconds(seconds))
                        guard !Task.isCancelled, settingsStore.autoRefreshEnabled else { continue }
                        await session.remote.refreshQuietly()
                    }
                }
                .sheet(
                    item: Binding(
                        get: { bridge.currentPrompt },
                        set: { newValue in
                            if newValue == nil { bridge.dismiss() }
                        }
                    ),
                    onDismiss: { bridge.dismiss() }
                ) { item in
                    ConflictSheetView(
                        conflict: item.conflict,
                        onResolve: { resolution, applyToAll in
                            bridge.resolve((resolution: resolution, applyToAll: applyToAll))
                        },
                        onCancel: { bridge.dismiss() }
                    )
                }
            } else {
                // Align the form to the top instead of centering it vertically
                // (user feedback 2026-07-10, M5c/T0) — otherwise the compact
                // window has a lot of empty space below the content.
                ConnectionFormView(
                    viewModel: tab.connectionViewModel,
                    groups: sessionListViewModel.groups,
                    sessionList: sessionListViewModel,
                    resolveLoginSetForSubmit: {
                        // All three resolutions always run (never
                        // short-circuited) so a dangling target set, a
                        // dangling jump set, AND an unresolvable jump-session
                        // reference each surface their own `showFailure` —
                        // only the combined AND decides whether the caller
                        // may proceed (M11a/T3 added the third).
                        let targetResolved = resolveSelectedLoginSet(in: tab)
                        let jumpResolved = resolveSelectedJumpLoginSet(in: tab)
                        let jumpSessionResolved = resolveSelectedJumpSession(in: tab)
                        return targetResolved && jumpResolved && jumpSessionResolved
                    },
                    onSaveEdited: { stored, secret in
                        var stored = stored
                        var effectiveSecret = secret
                        if let newSetID = maybeCreateNewLoginSet(
                            from: tab.connectionViewModel, editedSession: stored
                        ) {
                            // The secret now lives under the new set's id —
                            // don't also duplicate it into the session's own
                            // keychain slot.
                            stored.loginSetID = newSetID
                            effectiveSecret = nil
                        } else if stored.loginSetID != nil {
                            // Set mode: the set already owns the secret.
                            effectiveSecret = nil
                        }
                        // Jump secret (M10c/T3): `stored.jump` was already
                        // built by `validateForEditSave()` (Set mode carries
                        // only `loginSetID`, Manual carries the manual
                        // fields + the EXISTING `secretID` it remembered) --
                        // `updateSession` itself gates on `jump.loginSetID
                        // == nil` before writing this, so passing it
                        // unconditionally is safe in Set/Manual mode.
                        //
                        // Session mode (M11a/T3): `jumpPassword` was just
                        // filled with the REFERENCED session's own resolved
                        // secret (`resolveSelectedJumpSession`, spec §4a) --
                        // passing that through here would copy it into the
                        // jump's supposedly UNUSED `secretID` slot (spec §1:
                        // "ungenutzt") on every save, not just the
                        // manual→session switch `cleanOrphanedJumpSlot`
                        // guards against. `nil` keeps that slot untouched.
                        sessionListViewModel.updateSession(
                            stored, newSecret: effectiveSecret,
                            jumpSecret: tab.connectionViewModel.jumpSourceMode == .session
                                ? nil : tab.connectionViewModel.jumpPassword)
                        tab.connectionViewModel.endEditing()
                    },
                    onCancelEdit: { tab.connectionViewModel.endEditing() },
                    onConnectEdited: { stored in
                        // onSaveEdited may have rewired loginSetID (e.g. "save as new
                        // login set") on its own local copy of `stored`, which never
                        // reaches this closure's parameter. `updateSession` inside
                        // onSaveEdited already reloaded the list synchronously, so look
                        // up the just-persisted session by id and connect with that.
                        let current = sessionListViewModel.sessions.first(where: { $0.id == stored.id }) ?? stored
                        connect(in: tab, stored: current)
                    }
                ) { fs in
                    // Remote home start (M9d): resolved once per connect,
                    // right before the browser session is built, so the
                    // remote pane opens where the user actually lands after
                    // login instead of hardcoded "/". A lookup failure
                    // (older SFTP servers, permission quirks) falls back to
                    // "/" rather than failing the connect.
                    // Accept only usable absolute paths (M9d final review): an
                    // empty/relative realpath result would land the pane in
                    // .failed where "/" always worked.
                    let resolved = (try? await fs.homeDirectoryPath()) ?? "/"
                    let home = resolved.hasPrefix("/") ? resolved : "/"
                    startSession(in: tab, with: fs, startPath: home)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        // Load-bearing identity (M8a/T3 review): forces this whole per-tab
        // subtree — the connected browser layout AND the form branch — to
        // remount on every tab switch. Without it, two connected tabs would
        // share the same SwiftUI view identities: `SSHTerminalView` binds
        // `onOutput` and replays its buffer only in `makeNSView` (see
        // SSHTerminalView.swift:29-30, `updateNSView` is empty), so a tab
        // switch would keep rendering/typing into the OLD tab's shell
        // instead of rebinding to the new one. `BrowserPane`/
        // `ConnectionFormView` `@State` would leak across tabs the same way.
        .id(tab.id)
    }

    // MARK: - Tab lifecycle

    /// Builds a fresh form tab: own connection view model, own queue (wired
    /// once here to the shared limiter, the settings concurrency and the
    /// tab's OWN conflict bridge). Static so `init` can seed `tabsModel`
    /// with the window's first tab.
    private static func makeTab(
        settingsStore: SettingsStore, limiter: BandwidthLimiter
    ) -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { config, decider in
                try await BackendConnector.connect(config, decider: decider)
            }),
            limiter: limiter,
            maxConcurrent: settingsStore.maxConcurrentTransfers
        )
    }

    private func makeTab() -> SessionTab {
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
    private func attachAuditRecorder(
        to tab: SessionTab, sessionID: UUID, host: String, username: String,
        viaJumpHost: String? = nil
    ) {
        let recorder = AuditRecorder(sessionID: sessionID, store: auditStore)
        tab.auditRecorder = recorder
        recorder.recordConnected(host: host, username: username, viaJumpHost: viaJumpHost)
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
    private func teardown(_ tab: SessionTab) async {
        tab.editErrorMessage = nil
        if let session = tab.session {
            // MUST run before `cancelAll()`: an open conflict sheet would
            // otherwise keep the decider prompt open, which `cancelAll`
            // (documented) hangs on until it's answered — deadlock on disconnect.
            tab.conflictBridge.dismiss()
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
    private func activate(_ id: UUID) {
        tabsModel.activate(id)
        guard tabsModel.activeTabID == id else { return }
        tabsModel.activeTab.seenFailureCount = tabsModel.activeTab.transferQueue.totalFailureCount
    }

    /// ⌘1–⌘9 target: 1-indexed, no-op outside the current tab range.
    private func selectTab(atIndex index: Int) {
        guard tabsModel.tabs.indices.contains(index) else { return }
        activate(tabsModel.tabs[index].id)
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
    private func wireMenuBarBridge() {
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
    private func handleCloseActiveTabCommand() {
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

    /// Tab close entry point (strip ✕, ⌘W): a tab with active transfers OF
    /// ITS OWN, or that is currently the DESTINATION of another tab's
    /// cross-session transfer (M8b/T4), requires destructive confirmation
    /// (`closeRequest`, bound to the confirmation dialog above); an
    /// otherwise-idle tab closes immediately.
    private func requestClose(_ tab: SessionTab) {
        if tab.transferQueue.isActive || hasIncomingTransfers(for: tab) {
            // Freeze the warning text NOW (M8b review, finding 4) — the
            // dialog reads this snapshot for its whole lifetime instead of
            // recomputing per render, so it can't go blank if the transfers
            // it describes finish while the confirmation is still up.
            closeWarningText = closeWarningMessage(for: tab)
            closeRequest = tab
        } else {
            Task { await performClose(tab) }
        }
    }

    /// Combined close-warning text (M8b/T4): a tab can have its OWN active
    /// transfers, be the destination of ANOTHER tab's cross-session
    /// transfer, or both — both reasons are shown (one per line) when they
    /// co-occur, so the user isn't left guessing which one applies.
    private func closeWarningMessage(for tab: SessionTab) -> String {
        var lines: [String] = []
        if tab.transferQueue.isActive {
            lines.append(L10n.string(
                "tabs.close.activeTransfers", "Active transfers in this tab will be canceled."))
        }
        if hasIncomingTransfers(for: tab) {
            lines.append(L10n.string(
                "tabs.close.incomingTransfers",
                "Other tabs are streaming to this session; closing cancels those transfers."))
        }
        return lines.joined(separator: "\n")
    }

    /// Title for the update-check result alert (M11b/T2, spec §4) — one per
    /// `UpdateCheckResult` case, `""` while no dialog is showing (`nil`).
    /// `SwiftUI` evaluates this even during dismissal, so it must not force-
    /// unwrap `presentedResult`. Delegates to `UpdateAlertContent` (M11b
    /// final review, Finding I2) so this copy can never drift from
    /// `UpdateCheckModel`'s `NSAlert` fallback.
    private var updateAlertTitle: String {
        UpdateAlertContent.title(for: updateModel.presentedResult)
    }

    /// Message body matching `updateAlertTitle` above — see
    /// `UpdateAlertContent.message` for the wording of each case.
    private var updateAlertMessage: String {
        UpdateAlertContent.message(for: updateModel.presentedResult)
    }

    /// True while any OTHER tab's queue holds a non-terminal item that
    /// targets this tab (M8b/T4) — closing it would sever those incoming
    /// cross-session streams. Evaluated live against the tabs collection at
    /// both call sites (confirm gate and warning text).
    private func hasIncomingTransfers(for tab: SessionTab) -> Bool {
        tabsModel.tabs.contains {
            $0.id != tab.id && $0.transferQueue.hasActiveItems(destinationTabID: tab.id)
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
    private func performClose(_ tab: SessionTab) async {
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
    private func resizeWindow(toWidth width: CGFloat, height: CGFloat) {
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
    private func shrinkIfPristine() {
        guard isPristine, let window else { return }
        let size = window.frame.size
        guard size.width > 700 || size.height > 460 else { return }
        lastBrowserSize = size
        resizeWindow(toWidth: 700, height: 460)
    }

    /// Panel content: terminal while the shell is running, otherwise an
    /// ended/empty state. `SSHTerminalView` is deliberately mounted only
    /// while the shell is active, so `onOutput` binds fresh on every reopen.
    @ViewBuilder
    private func terminalPanel(_ session: BrowserSession) -> some View {
        ZStack {
            Color(nsColor: DesignTokens.terminalBackground)
            switch session.terminal.state {
            case .running, .opening:
                SSHTerminalView(viewModel: session.terminal, settingsStore: settingsStore)
            case .ended(let message):
                VStack(spacing: 8) {
                    Text(message ?? L10n.string("terminal.ended", "Shell ended."))
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: DesignTokens.terminalText))
                    Button(L10n.string("terminal.reopen", "Reopen")) { session.terminal.openIfNeeded() }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
            case .closed:
                Color.clear
            }
        }
        // Mockup: the terminal strip carries a hairline top border.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DesignTokens.hairline)
                .frame(height: 1)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Connecting

    // MARK: - Login sets (M10b/T3)

    /// Fills the form's manual-looking fields from a login set — called
    /// right before Connect/Save whenever the form is in Set mode, so the
    /// EXISTING connect/save validators (which only know about
    /// username/authChoice/keyPath/password) see the set's current values.
    /// The secret is read from the keychain under the SET's own id, exactly
    /// where `saveLoginSet`/`deleteLoginSet` keep it — a synthetic
    /// `StoredSession` carrying that id is enough for `password(for:)` to
    /// find it, no separate lookup API needed on `SessionListViewModel`.
    private func fillForm(_ form: ConnectionViewModel, from set: LoginSet) {
        if set.kind == .s3 {
            form.s3AccessKeyID = set.accessKeyID ?? ""
            let synthetic = StoredSession(
                id: set.id, name: set.name, host: "", username: "")
            form.s3SecretAccessKey = sessionListViewModel.password(for: synthetic) ?? ""
            return
        }
        form.username = set.username
        form.authChoice = ConnectionViewModel.authChoice(for: set.authKind)
        form.keyPath = set.keyPath ?? ""
        // Agent sets carry no secret (M10d/T4) — skip the keychain lookup
        // entirely rather than looking up a slot that was never written.
        guard set.authKind != .agent else {
            form.password = ""
            return
        }
        let synthetic = StoredSession(
            id: set.id, name: set.name, host: "", username: set.username,
            authKind: set.authKind, keyPath: set.keyPath)
        form.password = sessionListViewModel.password(for: synthetic) ?? ""
    }

    /// `ConnectionFormView.resolveLoginSetForSubmit` implementation:
    /// mirrors `resolveSelectedJumpLoginSet` for the target (M11e/T1 point
    /// 5 — the two used to be asymmetric, this one silently no-op'd on a
    /// dangling set). Returns `true` outside Set mode, while nothing is
    /// selected (the button is disabled in that case anyway — the
    /// defensive belt-and-suspenders half), or on a successful fill.
    /// Returns `false` when the selection is DANGLING — the set was
    /// removed, e.g. via "Manage logins…" while this form stayed open —
    /// after surfacing that through `showFailure` with the same M10b
    /// `loginSets.missingSet` key the jump half uses. `field: nil` here
    /// (unlike the jump half's `.jumpHost`): there is no matching
    /// target-side field to highlight.
    private func resolveSelectedLoginSet(in tab: SessionTab) -> Bool {
        let form = tab.connectionViewModel
        guard form.loginMode == .set, let id = form.selectedLoginSetID else { return true }
        guard let set = sessionListViewModel.loginSets.first(where: { $0.id == id }) else {
            form.showFailure(
                message: L10n.string(
                    "loginSets.missingSet",
                    "The stored login for this connection was not found. Choose a login or enter credentials."),
                field: nil)
            return false
        }
        fillForm(form, from: set)
        return true
    }

    /// Same as `fillForm(_:from:)` but for the jump block's own login
    /// (M10c/T3) — fills `jumpUsername`/`jumpAuthChoice`/`jumpKeyPath`/
    /// `jumpPassword` instead of the target's fields. Kept as a separate
    /// function rather than a generalized field-pair helper: the two call
    /// sites bind to different `ConnectionViewModel` properties, and a
    /// shared abstraction would only add indirection for two short bodies.
    private func fillJumpForm(_ form: ConnectionViewModel, from set: LoginSet) {
        form.jumpUsername = set.username
        form.jumpAuthChoice = ConnectionViewModel.authChoice(for: set.authKind)
        form.jumpKeyPath = set.keyPath ?? ""
        // Agent sets carry no secret (M10d/T4) — skip the keychain lookup
        // entirely rather than looking up a slot that was never written.
        guard set.authKind != .agent else {
            form.jumpPassword = ""
            return
        }
        let synthetic = StoredSession(
            id: set.id, name: set.name, host: "", username: set.username,
            authKind: set.authKind, keyPath: set.keyPath)
        form.jumpPassword = sessionListViewModel.password(for: synthetic) ?? ""
    }

    /// `ConnectionFormView.resolveLoginSetForSubmit`'s jump half (M10c/T3):
    /// fills the jump's manual fields from the currently selected login set,
    /// mirroring `resolveSelectedLoginSet` for the target. Returns `true`
    /// (no-op) when the jump is off, in Manual mode, or nothing is selected
    /// yet (Connect/Save are already disabled for that last case via
    /// `jumpLoginSetModeIncomplete`, the belt-and-suspenders half). Returns
    /// `false` when the selection is DANGLING — the set was removed, e.g.
    /// via "Manage logins…" while this form stayed open (spec §4a) — after
    /// surfacing that through `showFailure` with the M10b `loginSets.
    /// missingSet` key; the caller must not proceed to connect/validate in
    /// that case.
    ///
    /// `jumpSourceMode != .session` (F-1 fix, final review): a leftover
    /// dangling `jumpSelectedLoginSetID` from a Manual+Set pick made before
    /// switching Source to "Saved connection" must not block submit with an
    /// error on a field session mode doesn't even render -- session mode has
    /// its own resolution path (`resolveSelectedJumpSession` below).
    private func resolveSelectedJumpLoginSet(in tab: SessionTab) -> Bool {
        let form = tab.connectionViewModel
        guard form.jumpEnabled, form.jumpSourceMode != .session,
              form.jumpLoginMode == .set, let id = form.jumpSelectedLoginSetID
        else {
            return true
        }
        guard let set = sessionListViewModel.loginSets.first(where: { $0.id == id }) else {
            form.showFailure(
                message: L10n.string(
                    "loginSets.missingSet",
                    "The stored login for this connection was not found. Choose a login or enter credentials."),
                field: .jumpHost)
            return false
        }
        fillJumpForm(form, from: set)
        return true
    }

    /// `ConnectionFormView.resolveLoginSetForSubmit`'s jump-SESSION half
    /// (M11a/T3, spec §4a): when the jump is enabled and in session mode,
    /// resolves the referenced connection and fills the jump's
    /// manual-looking fields (host/port/login) from that resolution —
    /// mirrors `resolveSelectedJumpLoginSet`'s fill-before-submit pattern,
    /// just sourced from a saved session instead of a login set. Returns
    /// `true` (no-op) when the jump is off, in Manual mode, or nothing is
    /// selected yet (Connect/Save are already disabled for that last case
    /// via `ConnectionFormView.jumpSessionModeIncomplete`, the
    /// belt-and-suspenders half). Returns `false` on
    /// `.missingJumpSession`/`.jumpChainNotSupported`/a dangling login set
    /// on the referenced session — surfaced through `showFailure` with
    /// `field: .jumpSession` — after which the caller must NOT proceed to
    /// connect/validate.
    private func resolveSelectedJumpSession(in tab: SessionTab) -> Bool {
        let form = tab.connectionViewModel
        guard form.jumpEnabled, form.jumpSourceMode == .session, let sessionID = form.jumpSessionID else {
            return true
        }
        let referencingID: UUID
        if case .edit(let id) = form.mode { referencingID = id } else { referencingID = UUID() }
        let spec = StoredSession.JumpSpec(host: "", username: "", sessionID: sessionID)
        let synthetic = StoredSession(id: referencingID, name: "", host: "", username: "", jump: spec)
        do {
            guard let resolved = try sessionListViewModel.resolvedJump(for: synthetic) else { return true }
            form.jumpHost = resolved.host
            form.jumpPort = String(resolved.port)
            form.jumpUsername = resolved.login.username
            form.jumpAuthChoice = ConnectionViewModel.authChoice(for: resolved.login.authKind)
            form.jumpKeyPath = resolved.login.keyPath ?? ""
            form.jumpPassword = resolved.login.secret ?? ""
            return true
        } catch LoginResolveError.missingJumpSession {
            form.showFailure(
                message: L10n.string(
                    "form.jump.session.missing", "The connection used as jump host no longer exists."),
                field: .jumpSession)
            return false
        } catch LoginResolveError.jumpChainNotSupported {
            form.showFailure(
                message: L10n.string(
                    "form.jump.session.chainNotSupported",
                    "The selected jump host connects through another jump host; chains are not supported."),
                field: .jumpSession)
            return false
        } catch {
            // Dangling login set on the REFERENCED session (`.missingSet`),
            // or any other unclassified failure — same fallback wording the
            // form's own read-only summary uses for this condition.
            form.showFailure(
                message: L10n.string(
                    "loginSets.missingSet",
                    "The stored login for this connection was not found. Choose a login or enter credentials."),
                field: .jumpSession)
            return false
        }
    }

    /// Manual mode + "Save as new login set": creates the set from the
    /// form's current fields and returns its id, or `nil` when the toggle
    /// isn't active (or the form is in Set mode, where there's nothing new
    /// to create). The name is the field's trimmed value, or
    /// `suggestedSetName(forUsername:)` when left blank (spec §3).
    ///
    /// `editedSession` is the session being edited when this runs from the
    /// edit-save path (`nil` for a brand-new connection). In edit mode
    /// `form.password` is intentionally empty ("leave empty to keep the
    /// existing secret" — see `ConnectionViewModel.beginEditing`), so an
    /// empty field here does NOT mean "no secret": it means the session's
    /// existing keychain secret must MOVE onto the new set rather than be
    /// dropped, or the session becomes unreachable after the rewire (B1).
    /// M17 review fix: a managed key's passphrase lives in the Keychain
    /// under its own `key.id` slot (`ManagedKeyPassphrase.resolve`'s doc
    /// comment) -- a session's or login set's own secret slot must never
    /// duplicate it, or a later stored-session open could read the
    /// (stale-prone) session/set slot instead of the authoritative key.id
    /// one. True only when `form` is in the SSH private-key case AND its
    /// current `keyPath` resolves to a managed key whose slot actually
    /// EXISTS; password auth, S3, and unmanaged/external key paths are
    /// unaffected.
    ///
    /// The slot is probed, not inferred from `ManagedKey.hasPassphrase`.
    /// That flag says the key file is encrypted, which for a key materialized
    /// out of a login-set export WITHOUT secrets (the default, and the common
    /// case) is true while no slot exists. Trusting it there made
    /// `passwordToPersist` force `""` and threw away the passphrase the user
    /// typed -- with no other UI anywhere to store a managed key's passphrase,
    /// that meant retyping it on every connect, forever. With no `key.id` slot
    /// there is also nothing to duplicate, so the session/set slot is the right
    /// home for it, exactly as it is for an external key path.
    ///
    /// M19: a probe that cannot be ANSWERED (an unreadable key store, a
    /// Keychain that refuses the read) is treated as `true`, i.e. "assume the
    /// key has its own slot". The alternative — the `try?` this used to be —
    /// turns a transient failure into "no slot" and duplicates the typed
    /// passphrase into the session's/set's own slot, permanently, which is
    /// precisely what this function exists to prevent. Declining to persist is
    /// recoverable (the user retypes it); a silent duplicate is not.
    private func isManagedKeyWithStoredPassphrase(_ form: ConnectionViewModel) -> Bool {
        guard form.kind == .ssh, form.authChoice == .privateKey else { return false }
        do {
            return try ManagedKeyPassphrase.hasStoredPassphrase(
                keyPath: form.keyPath.trimmingCharacters(in: .whitespacesAndNewlines),
                store: ManagedKeyStore(directory: SessionStore.defaultDirectory),
                secrets: KeychainSecretStore())
        } catch {
            return true
        }
    }

    /// The value to persist under a session's OWN secret slot (`session.
    /// id`). Empty for a managed key with a stored passphrase (see
    /// `isManagedKeyWithStoredPassphrase` -- the transient connect-time fill
    /// in `ConnectionFormView`'s Connect button and `connect(in:stored:)`
    /// still resolves it from `key.id`, so nothing is lost); `form.password`
    /// unchanged otherwise.
    private func passwordToPersist(for form: ConnectionViewModel) -> String {
        isManagedKeyWithStoredPassphrase(form) ? "" : form.password
    }

    private func maybeCreateNewLoginSet(
        from form: ConnectionViewModel, editedSession: StoredSession? = nil
    ) -> UUID? {
        guard form.loginMode == .manual, form.saveAsNewLoginSet else { return nil }

        if form.kind == .s3 {
            let accessKeyID = form.s3AccessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedName = form.newLoginSetName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmedName.isEmpty
                ? sessionListViewModel.suggestedSetName(forUsername: accessKeyID)
                : trimmedName
            let newSet = LoginSet(name: name, username: "", authKind: .password,
                                  kind: .s3, accessKeyID: accessKeyID)
            let secret = form.s3SecretAccessKey.isEmpty ? nil : form.s3SecretAccessKey
            sessionListViewModel.saveLoginSet(newSet, secret: secret)
            return newSet.id
        }

        let username = form.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = form.newLoginSetName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty
            ? sessionListViewModel.suggestedSetName(forUsername: username)
            : trimmedName
        // Three-way mapping (M10d/T4): reuses the Core helper instead of a
        // two-way ternary, which would silently save an agent-mode form as
        // a `.password` set.
        let authKind = ConnectionViewModel.storedAuthKind(for: form.authChoice)
        let keyPath = authKind == .privateKey
            ? form.keyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let newSet = LoginSet(name: name, username: username, authKind: authKind, keyPath: keyPath)
        // Agent sets never carry a secret (M10d/T4) — `saveLoginSet` already
        // refuses to write one for `.agent`, but skip the (then-discarded)
        // keychain lookup for the edited session's OWN secret too, rather
        // than reading a value that will never be used.
        let carried: String? = authKind == .agent ? nil
            : isManagedKeyWithStoredPassphrase(form) ? ""
            : (form.password.isEmpty
                ? (editedSession.flatMap { sessionListViewModel.password(for: $0) })
                : form.password)
        sessionListViewModel.saveLoginSet(newSet, secret: carried)
        return newSet.id
    }

    /// After a successful connect: build the panes of THIS tab and save the
    /// session if requested. `storedName` is the display name for the tab/
    /// window title when connecting to an already-stored session
    /// (`connect(in:stored:)`). It exists because
    /// `connectionViewModel.saveName` cannot be trusted here: the field
    /// survives toggling "Save as session" off and earlier sessions, so an
    /// UNSAVED connection could inherit a stale, unrelated name (M5f/T5
    /// review).
    // NOTE (M9d): `startSession` stays SYNCHRONOUS deliberately. Its two call
    // sites are already inside `async` contexts (the connect button's `Task`
    // in `ConnectionFormView`, and `connect(in:stored:)`'s `Task` below), so
    // the remote home directory is resolved there — with `await` — and
    // handed in as `startPath`. Marking `startSession` itself `async` was
    // tried first and had to be reverted: it made the compiler apply
    // stricter concurrency checking to the WHOLE function body, which then
    // flagged the pre-existing (harmless, `RemoteShellProvider` isn't
    // `Sendable`) `shellProvider` capture in the `openShell` closure below as
    // a new warning. Keeping this function sync avoids that regression
    // entirely while still resolving the home directory exactly once per
    // connect.
    private func startSession(
        in tab: SessionTab, with fs: any RemoteFileSystem, storedName: String? = nil,
        startPath: String = "/"
    ) {
        // Clear any stale edit error from a previous session so a late
        // openInEditor task cannot misattribute its failure to this session.
        tab.editErrorMessage = nil
        let form = tab.connectionViewModel
        let shellProvider = fs as? RemoteShellProvider
        // One UUID, shared by the session and its edit manager (M5e/T4) — see
        // `BrowserSession.id`'s doc comment.
        let sessionID = UUID()
        let queue = tab.transferQueue
        // Only pay for the per-entry `FileManager.attributesOfItem` syscall
        // (and the macOS permission prompt it can trigger on Desktop/
        // Documents/Downloads) when the owner or group column is actually
        // visible (M18a). Read once at session start: the local file system
        // is built here and lives for the session's lifetime, so a
        // visibility change made in Settings while this session is already
        // open takes effect on the NEXT connect, not live — acceptable for
        // this fix, matching how `visibleColumns` is otherwise threaded
        // through as a snapshot at each call site.
        let wantsOwnerGroup = settingsStore.visibleColumns.contains(.owner)
            || settingsStore.visibleColumns.contains(.group)
        tab.session = BrowserSession(
            id: sessionID,
            localFS: LocalFileSystem(fetchesOwnerGroup: wantsOwnerGroup),
            remoteFS: fs,
            local: RemoteBrowserViewModel(
                fs: LocalFileSystem(fetchesOwnerGroup: wantsOwnerGroup), startPath: NSHomeDirectory()),
            remote: RemoteBrowserViewModel(fs: fs, startPath: startPath),
            terminal: TerminalPanelViewModel(openShell: { term, cols, rows in
                guard let shellProvider else {
                    throw RemoteFSError.protocolError(
                        reason: "This connection does not support a terminal.")
                }
                return try await shellProvider.openShell(
                    terminal: term, cols: cols, rows: rows)
            }),
            editManager: EditSessionManager(sessionID: sessionID, queue: queue)
        )
        // Hidden-files toggle (M7a/T4): applied once here at session start,
        // kept in sync afterwards by the `.onChange` observer above.
        tab.session?.local.showHiddenFiles = settingsStore.showHiddenFiles
        tab.session?.remote.showHiddenFiles = settingsStore.showHiddenFiles
        // The tab's queue is created ONCE (in `SessionTab.init`, together with
        // its limiter/concurrency/decider wiring) and OUTLIVES each session of
        // that tab (M5d/T3): interrupted transfers stay in the bar across a
        // disconnect/reconnect so `retryInterrupted` can resume them.

        // Grow the window to the browser size (user feedback 2026-07-10,
        // M5c/T0) — to the last remembered browser size, if any and larger
        // than the minimum size. Gated on actual window GEOMETRY, not tab
        // connectivity (M8a/T3 review): "no tab connected" is not the same
        // as "window is form-sized" — a second form tab plus a manually
        // resized window would otherwise let a later connect yank the
        // window back down. The target is clamped to at least the current
        // frame size and the resize only fires when the window is smaller
        // than that target in either dimension, so a connect can only grow
        // the window, never shrink it.
        if let window {
            let targetSize = CGSize(
                width: max(lastBrowserSize?.width ?? 0, 930),
                height: max(lastBrowserSize?.height ?? 0, 620))
            if window.frame.width < targetSize.width || window.frame.height < targetSize.height {
                resizeWindow(
                    toWidth: max(targetSize.width, window.frame.width),
                    height: max(targetSize.height, window.frame.height))
            }
        }

        var titleName = storedName
        if form.shouldSaveSession {
            // Set mode: reference the picked set directly. Manual mode +
            // "Save as new login set": create the set FIRST, then reference
            // it — either way `password:` below is safely ignored by `save`
            // once `loginSetID` is non-nil (see its doc comment).
            let newSetID = maybeCreateNewLoginSet(from: form)
            // S3 (M12/T7b): a much shorter save — no host/username/auth/jump
            // concepts apply, so `host`/`username` get the SAME "unused"
            // placeholder `ConnectionViewModel.validateForEditSaveS3` uses
            // for the edit path, and the secret access key rides the
            // existing `password:` slot (no separate S3 secret path).
            let stored: StoredSession?
            if form.kind == .s3 {
                stored = sessionListViewModel.save(
                    name: form.saveName.trimmingCharacters(in: .whitespacesAndNewlines),
                    host: "unused", port: 22, username: "unused",
                    password: form.s3SecretAccessKey,
                    groupID: form.selectedGroupID,
                    loginSetID: form.loginMode == .set ? form.selectedLoginSetID : newSetID,
                    kind: .s3,
                    s3: StoredS3Config(
                        accessKeyID: form.s3AccessKeyID.trimmingCharacters(in: .whitespacesAndNewlines),
                        region: form.s3Region.trimmingCharacters(in: .whitespacesAndNewlines),
                        endpoint: form.s3Endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                        bucket: form.s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines),
                        usePathStyle: form.s3UsePathStyle)
                )
            } else {
                stored = sessionListViewModel.save(
                    name: form.saveName.trimmingCharacters(in: .whitespacesAndNewlines),
                    host: form.host.trimmingCharacters(in: .whitespacesAndNewlines),
                    port: Int(form.port.trimmingCharacters(in: .whitespaces)) ?? 22,
                    username: form.username.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: passwordToPersist(for: form),
                    // Three-way mapping (M10d/T4, found alongside the hand-off
                    // list's sites): the old two-way `.password ? : .privateKey`
                    // ternary would silently save an agent-mode connection as a
                    // private-key session.
                    authKind: ConnectionViewModel.storedAuthKind(for: form.authChoice),
                    keyPath: form.authChoice == .privateKey
                        ? form.keyPath.trimmingCharacters(in: .whitespacesAndNewlines)
                        : nil,
                    groupID: form.selectedGroupID,
                    loginSetID: form.loginMode == .set ? form.selectedLoginSetID : newSetID,
                    // Jump (M10c/T3): `existingSecretID` is nil here -- this is
                    // a BRAND-NEW session, so there is no previous manual slot
                    // to preserve (unlike `validateForEditSave()`'s own
                    // internal `buildJumpSpec` call, which reuses
                    // `existingJumpSecretID`).
                    //
                    // Session mode (M11a/T3) passes `nil` instead of
                    // `form.jumpPassword`, same reasoning as the edit-save path
                    // above: that field holds the REFERENCED session's own
                    // resolved secret at this point, and the jump's `secretID`
                    // slot is supposed to stay unused/empty while `sessionID` is
                    // set (spec §1), not a copy of a secret it never reads.
                    jump: form.buildJumpSpec(),
                    jumpSecret: form.jumpSourceMode == .session ? nil : form.jumpPassword,
                    kind: .ssh, s3: nil
                )
            }
            tab.activeStoredSessionID = stored?.id
            form.shouldSaveSession = false
            titleName = stored?.name ?? titleName
            // Audit recorder (M9b/T3): this "Save & connect" path just
            // turned an ad-hoc connect into a stored session — attach the
            // recorder here, mirroring `connect(in:stored:)` below.
            //
            // `form.jumpHost` (M-1 fix, final review), not `stored.jump?.
            // host`: for a session-mode jump `form.jumpHost` already holds
            // the freshly resolved host (`resolveSelectedJumpSession` filled
            // it before `connect()` ran, a few lines above `buildJumpSpec()`
            // reads the very same field) -- using `stored.jump?.host`
            // instead happened to read the identical value here (it's the
            // trimmed copy of this same field), but only by accident, not by
            // construction; `form.jumpHost` is the one field guaranteed to
            // be current in both connect paths.
            if let stored {
                attachAuditRecorder(
                    to: tab, sessionID: stored.id, host: stored.host, username: stored.username,
                    viaJumpHost: form.jumpEnabled ? form.jumpHost : nil)
            }
        }

        // Tab/window title: a stored session's name when this connection is
        // actually backed by one (just saved above, or passed in by
        // `connect(in:stored:)`), otherwise "user@host". Window chrome (proper
        // name + user data), deliberately not localized (no catalog key).
        tab.titleName = titleName?.isEmpty == false
            ? titleName!
            : "\(form.username)@\(form.host)"
    }

    /// Sidebar click: pick the target tab per the tab rule — the active tab
    /// when it is unconnected, otherwise a FRESH tab. A running session is
    /// therefore never torn down by a sidebar click (M8a spec 1.2).
    private func connectFromSidebar(_ stored: StoredSession) {
        let target = tabsModel.sidebarConnectTarget(
            activeTabIsConnected: activeTab.isConnected, makeTab: makeTab)
        connect(in: target, stored: stored)
    }

    /// Fills the tab's form from the store + keychain and connects right
    /// away. No teardown of any other tab.
    private func connect(in tab: SessionTab, stored: StoredSession) {
        guard !tab.isReconnecting else { return }
        tab.isReconnecting = true // synchronous — locks this tab immediately, before the first await
        Task {
            defer { tab.isReconnecting = false }
            // Defensive only: the sidebar rule always hands over an
            // unconnected tab. Reconnecting in place still tears THIS tab's
            // session down first, never anyone else's.
            if tab.isConnected { await teardown(tab) }
            let form = tab.connectionViewModel
            form.host = stored.host
            form.port = String(stored.port)
            form.saveName = stored.name
            form.shouldSaveSession = false

            // S3 (M12/T7b): a much shorter fill — no login sets, no jump,
            // no host-key TOFU. `kind` is reset explicitly on BOTH branches
            // (sticky-toggle lesson, same as `clearJumpFields()`'s own doc
            // comment): the tab's `ConnectionViewModel` outlives any single
            // connect, so a PREVIOUS S3 fill in this same tab must not
            // survive into an SSH session's fill, or vice versa. The secret
            // access key is resolved from the Keychain the same way the SSH
            // password is (`password(for:)`) — same slot, addressed by
            // session id regardless of kind.
            if stored.kind == .s3 {
                form.kind = .s3
                form.s3Endpoint = stored.s3?.endpoint ?? ""
                form.s3Region = stored.s3?.region ?? ""
                form.s3Bucket = stored.s3?.bucket ?? ""
                form.s3UsePathStyle = stored.s3?.usePathStyle ?? false
                // Credentials: from the bound S3 set if any, else the
                // session's own (M15). A dangling/kind-mismatched set does
                // NOT connect — same loginSets.missingSet path as SSH.
                do {
                    if let resolved = try sessionListViewModel.resolvedS3Login(for: stored) {
                        form.s3AccessKeyID = resolved.accessKeyID
                        form.s3SecretAccessKey = resolved.secretAccessKey ?? ""
                    } else {
                        form.s3AccessKeyID = stored.s3?.accessKeyID ?? ""
                        form.s3SecretAccessKey = sessionListViewModel.password(for: stored) ?? ""
                    }
                    form.loginMode = stored.loginSetID != nil ? .set : .manual
                    form.selectedLoginSetID = stored.loginSetID
                } catch is LoginResolveError {
                    form.s3AccessKeyID = stored.s3?.accessKeyID ?? ""
                    form.s3SecretAccessKey = ""
                    form.loginMode = .manual
                    form.selectedLoginSetID = nil
                    form.showFailure(message: L10n.string(
                        "loginSets.missingSet",
                        "The stored login for this connection was not found. Choose a login or enter credentials."))
                    return
                }
                form.clearJumpFields()
            } else {
                form.kind = .ssh
                // Resolve what this session should actually connect with (M10b/T3):
                // its own data for a manual session, or its set's credentials —
                // a dangling `loginSetID` throws rather than silently falling
                // back (`LoginResolver`'s doc comment).
                do {
                    if let resolved = try sessionListViewModel.resolvedLogin(for: stored) {
                        form.username = resolved.username
                        form.authChoice = ConnectionViewModel.authChoice(for: resolved.authKind)
                        form.keyPath = resolved.keyPath ?? ""
                        form.password = resolved.secret ?? ""
                    } else {
                        form.username = stored.username
                        form.authChoice = ConnectionViewModel.authChoice(for: stored.authKind)
                        form.keyPath = stored.keyPath ?? ""
                        // M-6: an agent login reads no keychain at all -- avoid
                        // the residual lookup on this path too.
                        form.password = stored.authKind != .agent
                            ? (sessionListViewModel.password(for: stored) ?? "") : ""
                    }
                    // M17: if this key is a managed key with a stored
                    // passphrase and none was typed, resolve it from the
                    // Keychain so the user need not re-enter it.
                    if form.authChoice == .privateKey {
                        form.password = ManagedKeyPassphrase.resolve(
                            keyPath: form.keyPath.trimmingCharacters(in: .whitespacesAndNewlines),
                            typed: form.password,
                            store: ManagedKeyStore(directory: SessionStore.defaultDirectory),
                            secrets: KeychainSecretStore())
                    }
                    form.loginMode = stored.loginSetID != nil ? .set : .manual
                    form.selectedLoginSetID = stored.loginSetID
                } catch is LoginResolveError {
                    // Missing set (target, M10c/T3): do NOT connect — show the
                    // form instead, with the mismatch surfaced through its
                    // existing error field (spec §2/§6). The user picks a login
                    // or enters credentials. Falls back to the session's own raw
                    // values so the form isn't left half-filled.
                    //
                    // Kept in its OWN do/catch, independent of the jump's below
                    // (final review M-1): sharing one catch meant a JUMP-only
                    // `.missingSet` also reset this (valid) target resolution —
                    // a dangling jump set discarded a perfectly good target
                    // login pick.
                    form.username = stored.username
                    form.authChoice = ConnectionViewModel.authChoice(for: stored.authKind)
                    form.keyPath = stored.keyPath ?? ""
                    form.password = ""
                    form.loginMode = .manual
                    form.selectedLoginSetID = nil
                    // A stale jump block from a DIFFERENT session's form must not
                    // survive this early return (F-1 fix): the jump `do`/`catch`
                    // below is never reached on this path, so apply the same
                    // raw-jump fallback it would have applied.
                    applyRawJumpFallback(form, from: stored)
                    form.showFailure(message: L10n.string(
                        "loginSets.missingSet",
                        "The stored login for this connection was not found. Choose a login or enter credentials."))
                    return
                }

                // Jump (M10c/T3, extended M11a/T3): same resolution as above,
                // for the jump's OWN login — `resolvedJumpLogin` is `nil` only
                // when the session has no jump at all; a resolved jump fills
                // the manual-looking fields regardless of whether it came from
                // a set or the jump's own manual secret, exactly like the
                // target's resolution above. In its OWN do/catch (final review
                // M-1, see comment above): a jump-only failure must fall back on
                // the JUMP side only, leaving the target fields resolved above
                // untouched.
                //
                // Session mode (`jump.sessionID` non-nil, spec §4b) branches
                // FIRST: host/port and the login all come from the REFERENCED
                // session via `resolvedJump(for:)`, unlike the manual/set branch
                // below which only ever resolves the jump's OWN fields via
                // `resolvedJumpLogin`. Each branch keeps its OWN nested do/catch
                // (rather than one shared catch for both) so a session-mode
                // failure highlights `.jumpSession` — the only field the
                // session-mode UI actually renders — while a manual/set failure
                // keeps highlighting `.jumpHost` exactly as before this feature.
                if let jump = stored.jump {
                    form.jumpEnabled = true
                    if let sessionID = jump.sessionID {
                        // Set BEFORE the throwing call below: on a failure the
                        // form stays in session mode with this selection intact,
                        // so the picker and the `.jumpSession` highlight the
                        // failure attaches to are both visible — switching back
                        // to manual with raw fallback values would hide the very
                        // field the error is about.
                        form.jumpSourceMode = .session
                        form.jumpSessionID = sessionID
                        do {
                            if let resolved = try sessionListViewModel.resolvedJump(for: stored) {
                                form.jumpHost = resolved.host
                                form.jumpPort = String(resolved.port)
                                form.jumpUsername = resolved.login.username
                                form.jumpAuthChoice = ConnectionViewModel.authChoice(for: resolved.login.authKind)
                                form.jumpKeyPath = resolved.login.keyPath ?? ""
                                form.jumpPassword = resolved.login.secret ?? ""
                            }
                        } catch LoginResolveError.missingJumpSession {
                            form.showFailure(
                                message: L10n.string(
                                    "form.jump.session.missing",
                                    "The connection used as jump host no longer exists."),
                                field: .jumpSession)
                            return
                        } catch LoginResolveError.jumpChainNotSupported {
                            form.showFailure(
                                message: L10n.string(
                                    "form.jump.session.chainNotSupported",
                                    "The selected jump host connects through another jump host; "
                                        + "chains are not supported."),
                                field: .jumpSession)
                            return
                        } catch is LoginResolveError {
                            // The REFERENCED session's own login set is dangling
                            // (`.missingSet`) -- same wording the login-set
                            // dangling-reference paths already use elsewhere.
                            form.showFailure(
                                message: L10n.string(
                                    "loginSets.missingSet",
                                    "The stored login for this connection was not found. "
                                        + "Choose a login or enter credentials."),
                                field: .jumpSession)
                            return
                        }
                    } else {
                        form.jumpSourceMode = .manual
                        form.jumpSessionID = nil
                        form.jumpHost = jump.host
                        form.jumpPort = String(jump.port)
                        form.jumpLoginMode = jump.loginSetID != nil ? .set : .manual
                        form.jumpSelectedLoginSetID = jump.loginSetID
                        do {
                            if let resolvedJump = try sessionListViewModel.resolvedJumpLogin(for: stored) {
                                form.jumpUsername = resolvedJump.username
                                form.jumpAuthChoice = ConnectionViewModel.authChoice(for: resolvedJump.authKind)
                                form.jumpKeyPath = resolvedJump.keyPath ?? ""
                                form.jumpPassword = resolvedJump.secret ?? ""
                            }
                        } catch is LoginResolveError {
                            // Missing set (jump only): the target fields resolved
                            // above stay untouched — only the jump falls back to
                            // its raw manual-looking values, and `field:
                            // .jumpHost` (not the target's `.host`) highlights
                            // the right row. Shares the fallback with the target
                            // catch above (F-1 fix) so both early-return paths
                            // leave the jump block in the identical,
                            // fully-reset-or-fully-raw state.
                            applyRawJumpFallback(form, from: stored)
                            form.showFailure(
                                message: L10n.string(
                                    "loginSets.missingSet",
                                    "The stored login for this connection was not found. "
                                        + "Choose a login or enter credentials."),
                                field: .jumpHost)
                            return
                        }
                    }
                } else {
                    form.clearJumpFields()
                }
            }

            if let fs = await form.connect() {
                // Accept only usable absolute paths (M9d final review): an
                // empty/relative realpath result would land the pane in
                // .failed where "/" always worked.
                let resolved = (try? await fs.homeDirectoryPath()) ?? "/"
                let home = resolved.hasPrefix("/") ? resolved : "/"
                startSession(in: tab, with: fs, storedName: stored.name, startPath: home)
                tab.activeStoredSessionID = stored.id
                // Audit recorder (M9b/T3): this IS the stored-session connect
                // path — attach right after `activeStoredSessionID`, once
                // `tab.session` (set inside `startSession`) exists.
                //
                // `form.jumpHost` (M-1 fix, final review), not
                // `stored.jump?.host`: for a session-mode jump the latter is
                // the snapshot taken at SAVE time, not the host actually
                // dialed just now -- if the bastion session moved since, the
                // audit entry would record a stale carrier host, defeating
                // reference semantics. `form.jumpHost` was just resolved
                // fresh above (`resolvedJump(for:)`/the manual fallback) and
                // is correct by construction; `jumpEnabled` gates it to `nil`
                // when there is no jump at all.
                attachAuditRecorder(
                    to: tab, sessionID: stored.id, host: stored.host, username: stored.username,
                    viaJumpHost: form.jumpEnabled ? form.jumpHost : nil)
            }
        }
    }

    /// Fills the jump block from the session's own raw JumpSpec values (no set
    /// resolution), or clears it entirely when the session has no jump. Used by
    /// BOTH early-return failure paths so a stale jump block from a previous form
    /// state can never survive into a different session's connect.
    ///
    /// `jumpSourceMode`/`jumpSessionID` are also reset here (F-2 fix, final
    /// review): the `if let jump` branch below fills only the manual-looking
    /// fields, so without this a stale `jumpSourceMode == .session` +
    /// `jumpSessionID` from a DIFFERENT, still-open form (e.g. an unconnected
    /// tab left in session mode with bastion X preselected) would survive
    /// into THIS session's (B's) connect: the picker would show X preselected
    /// while the manual fields hold B's raw jump values, and a subsequent
    /// Connect would silently route through X instead of B's own jump host.
    /// The `else` branch already resets both via `clearJumpFields()`.
    private func applyRawJumpFallback(_ form: ConnectionViewModel, from stored: StoredSession) {
        if let jump = stored.jump {
            form.jumpEnabled = true
            form.jumpSourceMode = .manual
            form.jumpSessionID = nil
            form.jumpHost = jump.host
            form.jumpPort = String(jump.port)
            form.jumpUsername = jump.username
            form.jumpAuthChoice = ConnectionViewModel.authChoice(for: jump.authKind)
            form.jumpKeyPath = jump.keyPath ?? ""
            form.jumpPassword = ""
            form.jumpLoginMode = .manual
            form.jumpSelectedLoginSetID = nil
        } else {
            form.clearJumpFields()
        }
    }

    /// Sidebar "Edit…" click: prefill the form for in-place editing — in the
    /// active tab when it is unconnected, otherwise in a fresh tab (a running
    /// session is never displaced). Deliberately no auto-connect: the user
    /// reviews/changes fields, then picks Save or Save & connect.
    private func editStored(_ stored: StoredSession) {
        guard let tab = formTarget() else { return }
        tab.connectionViewModel.beginEditing(stored)
    }

    /// Import click: fill the form from the ssh-config entry — deliberately
    /// WITHOUT connecting (the import knows no secrets). Same target rule as
    /// "Edit…".
    private func fillFromImported(_ host: SSHConfigHost) {
        guard let tab = formTarget() else { return }
        let form = tab.connectionViewModel
        form.exitEditMode()
        form.clearPassword()
        form.host = host.hostName ?? host.alias
        form.port = String(host.port ?? 22)
        form.username = host.user ?? ""
        form.saveName = host.alias
        form.shouldSaveSession = false
        if let identityFile = host.identityFile {
            form.authChoice = .privateKey
            form.keyPath = identityFile
        } else {
            form.authChoice = .password
            form.keyPath = ""
        }
    }

    /// Recomputes `importedHosts` (the sidebar's VISIBLE list) and
    /// `hiddenImportAliases` from `fullImportedHosts` and a fresh
    /// `HiddenImportStore` read (M11f/T2). Called once at startup (right
    /// after `fullImportedHosts` is populated in `.task`) and again after
    /// every hide/unhide — deliberately WITHOUT re-parsing
    /// `~/.ssh/config`, since hiding/unhiding never changes what is
    /// actually in that file. A store read failure (rare: e.g. a corrupt
    /// `hidden-imports.json`) reports `hiddenImportsErrorMessage` rather than
    /// failing silently (M11f/T2 review, finding 2) — a corrupted store would
    /// otherwise resurface every hidden host AND drop the Sessions-menu count
    /// with no indication anything went wrong. Success clears the message,
    /// matching `SessionSidebar.jumpRestoreErrorMessage`'s established pattern.
    ///
    /// On a read failure the visible list falls back to the FULL set rather
    /// than to whatever it held before (M11f/T2 re-review): hiding is a
    /// cosmetic display filter, so it must never subtract from a host list
    /// that WAS read successfully on the strength of preference data that
    /// was not. Keeping the previous list would strand the user at startup,
    /// where `importedHosts` is still empty when this first runs — the whole
    /// IMPORTED section would vanish on every launch, and the sheet (which
    /// re-reads the same broken file) offers no way back. `hiddenImportAliases`
    /// is deliberately left alone: a stale count keeps the menu entry
    /// discoverable, which is where the user goes to investigate.
    private func refreshImportedHosts() {
        do {
            let aliases = try HiddenImportStore(directory: SessionStore.defaultDirectory).allHidden()
            hiddenImportAliases = aliases
            importedHosts = ImportedHostPartition.split(hosts: fullImportedHosts, hiddenAliases: aliases).visible
            hiddenImportsErrorMessage = nil
        } catch {
            importedHosts = fullImportedHosts
            hiddenImportsErrorMessage = String(
                format: L10n.string(
                    "sidebar.hiddenImports.error %1$@ %2$@",
                    "Could not update hidden imports: %1$@ — you can delete %2$@ to reset the list."),
                String(describing: error),
                HiddenImportStore(directory: SessionStore.defaultDirectory).fileURL.path(percentEncoded: false))
        }
    }

    /// Sidebar imported-row context menu "Hide" (M11f/T2, spec: no
    /// confirmation dialog — this reports FAILURE only, never a success
    /// confirmation). A rare disk-write failure previously just left the
    /// row visible for another try with zero feedback (M11f/T2 review,
    /// finding 1); now it is captured separately, `refreshImportedHosts()`
    /// still runs unconditionally (the read usually still works even when
    /// the write just failed), and the write error is re-applied AFTER —
    /// same "capture separately, reload, reapply after" pattern as
    /// `HiddenImportsSheet.unhide`, so a successful `refreshImportedHosts()`
    /// read can't silently swallow this call's own write failure.
    private func hideImported(_ host: SSHConfigHost) {
        var hideError: String?
        do {
            try HiddenImportStore(directory: SessionStore.defaultDirectory).hide(host.alias)
        } catch {
            hideError = String(
                format: L10n.string(
                    "sidebar.hiddenImports.error %1$@ %2$@",
                    "Could not update hidden imports: %1$@ — you can delete %2$@ to reset the list."),
                String(describing: error),
                HiddenImportStore(directory: SessionStore.defaultDirectory).fileURL.path(percentEncoded: false))
        }
        refreshImportedHosts()
        if let hideError {
            hiddenImportsErrorMessage = hideError
        }
    }

    /// Sidebar "New connection": blank the active tab's form when it is
    /// unconnected (M6a — without this, host/username/name from a previous
    /// edit stay prefilled), otherwise open a fresh empty tab. The toolbar
    /// "Disconnect" deliberately keeps the fields (reconnect convenience) —
    /// only this path blanks them.
    private func newConnection() {
        let tab = activeTab
        if tab.isConnected {
            tabsModel.addTab(makeTab())
            return
        }
        guard !tab.isReconnecting else { return }
        tab.connectionViewModel.endEditing()
    }

    /// Target tab for the form-filling sidebar actions ("Edit…", ssh-config
    /// import): the active tab if it is unconnected and idle, otherwise a new
    /// tab. `nil` while the active tab is mid-connect (the click is ignored,
    /// as it is today).
    private func formTarget() -> SessionTab? {
        let tab = activeTab
        if tab.isConnected {
            let fresh = makeTab()
            tabsModel.addTab(fresh)
            return fresh
        }
        guard !tab.isReconnecting else { return nil }
        return tab
    }

    /// Toolbar "Disconnect": tears this tab's session down and returns it to
    /// the form. The tab's queue survives — interrupted transfers stay
    /// resumable after a reconnect, exactly as before.
    private func disconnectToForm(_ tab: SessionTab) {
        guard !tab.isReconnecting else { return }
        tab.isReconnecting = true // synchronous — prevents double teardown (would corrupt lastBrowserSize)
        Task {
            defer { tab.isReconnecting = false }
            await teardown(tab)
            shrinkIfPristine()
        }
    }

    /// Sets the localized "not available for this connection type" message
    /// (M12/T7b) — the shared fallback for every shell-only command path
    /// (toolbar button, ⌘T, both "Terminal" menu entries) that reaches its
    /// action despite already being disabled for the active tab's backend.
    private func presentTerminalUnavailable() {
        terminalUnavailableAlertMessage = L10n.string(
            "shortcut.unavailableForProtocol",
            "This shortcut isn't available for this connection type.")
    }

    // MARK: - External terminal (M11d/T2)

    /// Entry point for both routes to an external terminal (the toolbar
    /// button when `terminalTarget != .builtIn`, and the "Terminal" menu's
    /// "Open in External Terminal" entry, which ignores the setting
    /// entirely). Shows the password hint first when it applies (spec §4
    /// item 6); otherwise opens immediately.
    private func requestExternalTerminal(for tab: SessionTab) {
        // No session, or somehow no resolved config for one (never happens
        // in practice — a connected tab always has one, set by
        // `ConnectionViewModel.connect()` on success): nothing to open.
        guard tab.isConnected, let config = tab.connectionViewModel.lastConnectedConfig else { return }
        // The menu route ignores `terminalTarget` (it always means
        // "external"); the toolbar route already checked it before calling
        // here, but `.builtIn` still needs a concrete target to launch.
        // Review finding (M11d fix round 1): honour a validly configured
        // custom app here instead of always substituting Terminal.app —
        // a user who set a custom app but left the main setting on
        // "Built-in" would otherwise silently get Apple Terminal. Only fall
        // back to Terminal.app when no usable custom app is configured.
        let customPath = settingsStore.customTerminalAppPath
        let target: TerminalTarget
        if settingsStore.terminalTarget == .builtIn {
            target = ExternalTerminalLauncher.isValidCustomApp(atPath: customPath) ? .custom : .terminalApp
        } else {
            target = settingsStore.terminalTarget
        }

        if case .password = config.auth, !settingsStore.externalTerminalPasswordHintShown {
            pendingPasswordHintRequest = ExternalTerminalRequest(
                config: config, target: target, customPath: customPath)
            return
        }
        Task {
            await performExternalOpen(config: config, target: target, customPath: customPath)
        }
    }

    /// Writes and launches the disposable script via `ExternalTerminalLauncher`;
    /// any `LaunchError` becomes a concrete alert message (spec §4 item 7) —
    /// never a silent failure or a fallback to a different app. `async`
    /// because `ExternalTerminalLauncher.open` now awaits `NSWorkspace`'s
    /// own launch completion (review finding I-2) instead of firing it with
    /// `completionHandler: nil`; callers wrap this in `Task { }`.
    private func performExternalOpen(config: SSHConnectionConfig, target: TerminalTarget, customPath: String?) async {
        do {
            try await ExternalTerminalLauncher.open(config: config, target: target, customPath: customPath)
        } catch ExternalTerminalLauncher.LaunchError.applicationNotFound(let name) {
            externalTerminalErrorMessage = String(
                format: L10n.string("externalTerminal.error.applicationNotFound %@", "Couldn't find \u{201C}%@\u{201D}."),
                name)
        } catch ExternalTerminalLauncher.LaunchError.noCustomAppChosen {
            externalTerminalErrorMessage = L10n.string(
                "externalTerminal.error.noCustomAppChosen", "No app has been chosen yet.")
        } catch ExternalTerminalLauncher.LaunchError.scriptWriteFailed(let reason) {
            externalTerminalErrorMessage = String(
                format: L10n.string(
                    "externalTerminal.error.scriptWriteFailed %@", "Couldn't write the launch script: %@"),
                reason)
        } catch ExternalTerminalLauncher.LaunchError.launchFailed(let reason) {
            externalTerminalErrorMessage = String(
                format: L10n.string("externalTerminal.error.launchFailed %@", "Couldn't launch the app: %@"),
                reason)
        } catch {
            externalTerminalErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Transfers

    /// Locally selected files/folders → current remote directory.
    /// Symlinks in the selection are skipped silently (not a meaningful
    /// transfer target); enabled when at least one non-symlink is selected.
    @ViewBuilder
    private func uploadButton(in tab: SessionTab, session: BrowserSession) -> some View {
        let selected = session.local.selectedItems
        Button {
            transferSelection(selected, from: .local, in: tab, session: session)
        } label: {
            Label(L10n.string("browser.upload", "Upload"), systemImage: "arrow.up")
        }
        .tint(DesignTokens.localAmber)
        .disabled(!selected.contains { $0.kind != .symlink })
        .help(L10n.string(
            "browser.uploadHelp", "Upload the selected local file/folder to the remote directory"))
    }

    /// Remotely selected files/folders → current local directory.
    /// Symlinks in the selection are skipped silently (not a meaningful
    /// transfer target); enabled when at least one non-symlink is selected.
    @ViewBuilder
    private func downloadButton(in tab: SessionTab, session: BrowserSession) -> some View {
        let selected = session.remote.selectedItems
        Button {
            transferSelection(selected, from: .remote, in: tab, session: session)
        } label: {
            Label(L10n.string("browser.download", "Download"), systemImage: "arrow.down")
        }
        .tint(DesignTokens.remoteBlue)
        .disabled(!selected.contains { $0.kind != .symlink })
        .help(L10n.string(
            "browser.downloadHelp", "Download the selected remote file/folder to the local directory"))
    }

    /// Context-menu transfer: same per-item enqueue the toolbar buttons use.
    private func transferSelection(
        _ selection: [RemoteFileItem], from side: BrowserPaneSide,
        in tab: SessionTab, session: BrowserSession
    ) {
        let queue = tab.transferQueue
        for item in selection where item.kind != .symlink {
            switch (side, item.kind) {
            case (.local, .directory):
                queue.enqueueTree(
                    directoryName: item.name, direction: .upload,
                    source: session.localFS, sourceDirectory: item.path,
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { [weak remote = session.remote] in await remote?.refresh() })
            case (.local, _):
                queue.enqueue(
                    fileName: item.name, direction: .upload,
                    source: session.localFS, sourcePath: item.path,
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { [weak remote = session.remote] in await remote?.refresh() })
            case (.remote, .directory):
                queue.enqueueTree(
                    directoryName: item.name, direction: .download,
                    source: session.remoteFS, sourceDirectory: item.path,
                    destination: session.localFS,
                    destinationDirectory: session.local.currentPath,
                    onCompleted: { [weak local = session.local] in await local?.refresh() })
            case (.remote, _):
                queue.enqueue(
                    fileName: item.name, direction: .download,
                    source: session.remoteFS, sourcePath: item.path,
                    destination: session.localFS,
                    destinationDirectory: session.local.currentPath,
                    onCompleted: { [weak local = session.local] in await local?.refresh() })
            }
        }
    }

    /// Cross-session transfer targets for `tab`'s context menu (M8b/T4):
    /// every OTHER tab that currently has a live session, in tab-strip
    /// order, mapped to its remote pane's CURRENT directory. Called fresh
    /// from inside `menuNeedsUpdate` on every menu open (never cached) —
    /// the menu itself freezes the resulting path into `CrossSessionTarget`
    /// at build time (Spec §5.3), so staleness is bounded to "between two
    /// menu opens", never longer.
    private func crossSessionTargets(for tab: SessionTab) -> [CrossSessionTarget] {
        tabsModel.tabs.compactMap { other in
            guard other.id != tab.id, let session = other.session else { return nil }
            return CrossSessionTarget(
                id: other.id, title: other.displayTitle,
                remotePath: session.remote.currentPath,
                kind: other.connectionViewModel.kind)
        }
    }

    /// Context-menu transfer to ANOTHER tab's remote (M8b/T4): same
    /// per-item enqueue as `transferSelection`, but the destination is
    /// `target`'s remote file system/directory (frozen at menu-build time)
    /// instead of this tab's own other pane. Always enqueued on the SOURCE
    /// tab's queue (`tab.transferQueue`), regardless of which tab owns the
    /// destination. If the target tab disconnected between menu build and
    /// click, `targetTab.session` is `nil` — enqueue is silently skipped, no
    /// crash (Spec §5.3; the queue only surfaces an error for already
    /// in-flight jobs, not for a destination that was never enqueued).
    private func transferToSession(
        _ selection: [RemoteFileItem], from side: BrowserPaneSide, target: CrossSessionTarget,
        in tab: SessionTab, session: BrowserSession
    ) {
        guard let targetTab = tabsModel.tabs.first(where: { $0.id == target.id }),
              let targetSession = targetTab.session
        else { return }
        let queue = tab.transferQueue
        for item in selection where item.kind != .symlink {
            switch (side, item.kind) {
            case (.local, .directory):
                queue.enqueueTree(
                    directoryName: item.name, direction: .upload,
                    source: session.localFS, sourceDirectory: item.path,
                    destination: targetSession.remoteFS,
                    destinationDirectory: target.remotePath,
                    onCompleted: { [weak remote = targetSession.remote] in await remote?.refresh() },
                    destinationTabID: target.id,
                    crossBackendTarget: CrossBackendTarget(name: target.title, kind: target.kind))
            case (.local, _):
                queue.enqueue(
                    fileName: item.name, direction: .upload,
                    source: session.localFS, sourcePath: item.path,
                    destination: targetSession.remoteFS,
                    destinationDirectory: target.remotePath,
                    onCompleted: { [weak remote = targetSession.remote] in await remote?.refresh() },
                    destinationTabID: target.id,
                    crossBackendTarget: CrossBackendTarget(name: target.title, kind: target.kind))
            case (.remote, .directory):
                // Remote→remote (crossRemote): direction stays `.upload` —
                // the destination is always a remote file system here, the
                // "download" branch only exists for remote→LOCAL transfers.
                queue.enqueueTree(
                    directoryName: item.name, direction: .upload,
                    source: session.remoteFS, sourceDirectory: item.path,
                    destination: targetSession.remoteFS,
                    destinationDirectory: target.remotePath,
                    onCompleted: { [weak remote = targetSession.remote] in await remote?.refresh() },
                    destinationTabID: target.id, crossRemote: true,
                    crossBackendTarget: CrossBackendTarget(name: target.title, kind: target.kind))
            case (.remote, _):
                queue.enqueue(
                    fileName: item.name, direction: .upload,
                    source: session.remoteFS, sourcePath: item.path,
                    destination: targetSession.remoteFS,
                    destinationDirectory: target.remotePath,
                    onCompleted: { [weak remote = targetSession.remote] in await remote?.refresh() },
                    destinationTabID: target.id, crossRemote: true,
                    crossBackendTarget: CrossBackendTarget(name: target.title, kind: target.kind))
            }
        }
    }

    /// "Copy Path": one absolute path per line.
    private func copyPaths(of selection: [RemoteFileItem]) {
        let text = selection.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Enqueues dropped file/folder URLs onto the tab's queue. Files run
    /// through `enqueue`, folders recursively through `enqueueTree`
    /// (M5b/T3/T4) — no directory filter, only URLs that no longer exist are
    /// discarded.
    private func uploadDropped(_ urls: [URL], in tab: SessionTab, session: BrowserSession) {
        let queue = tab.transferQueue
        for url in urls {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            guard exists else { continue }
            if isDirectory.boolValue {
                queue.enqueueTree(
                    directoryName: url.lastPathComponent, direction: .upload,
                    source: session.localFS, sourceDirectory: url.path(percentEncoded: false),
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { [weak remote = session.remote] in await remote?.refresh() }
                )
            } else {
                queue.enqueue(
                    fileName: url.lastPathComponent, direction: .upload,
                    source: session.localFS, sourcePath: url.path(percentEncoded: false),
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { [weak remote = session.remote] in await remote?.refresh() }
                )
            }
        }
    }

    /// Promise fulfillment: loads a remote file through the tab's queue to
    /// the URL specified by the Finder — serializes with all other transfers
    /// of that tab.
    private func remotePromiseProvider(
        for item: RemoteFileItem, in tab: SessionTab, session: BrowserSession
    ) -> RemoteFilePromiseProvider {
        let queue = tab.transferQueue
        return RemoteFilePromiseProvider(item: item) { item, url in
            try await queue.enqueueAndWait(
                fileName: url.lastPathComponent, direction: .download,
                source: session.remoteFS, sourcePath: item.path,
                destination: session.localFS,
                destinationDirectory: url.deletingLastPathComponent()
                    .path(percentEncoded: false)
            )
        }
    }

    /// Double-click on a remote FILE (kind == .file; directories `cd` via
    /// `RemoteBrowserViewModel.open`, symlinks/other stay no-ops — unchanged,
    /// M5e/T4): downloads it into the session's edit temp dir via
    /// `editManager.beginEditing` (shows up as a download in the tab's queue
    /// bar), then opens it in the resolved application.
    ///
    /// Resolution is two-stage per the M5e plan: the extension-rule/default-
    /// editor lookup (`EditorResolver.applicationURL`) only needs the file
    /// name, so it runs BEFORE the download; the system-association fallback
    /// (`EditorResolver.systemApplicationURL`) needs the actual local file,
    /// so it runs AFTER the download completes. If neither yields an app,
    /// `NSWorkspace.shared.open(_:)` is asked to open the local file with
    /// whatever it can find, as a last resort.
    private func openInEditor(
        _ item: RemoteFileItem, in tab: SessionTab, session: BrowserSession
    ) {
        let preResolvedAppURL = EditorResolver.applicationURL(
            forFileName: item.name, settings: settingsStore)
        Task {
            do {
                let localURL = try await session.editManager.beginEditing(
                    remotePath: item.path, fileName: item.name,
                    source: session.remoteFS, destinationForUploads: session.remoteFS)
                let appURL = preResolvedAppURL ?? EditorResolver.systemApplicationURL(for: localURL)
                if let appURL {
                    _ = try await NSWorkspace.shared.open(
                        [localURL], withApplicationAt: appURL,
                        configuration: NSWorkspace.OpenConfiguration())
                } else {
                    NSWorkspace.shared.open(localURL)
                }
                tab.editErrorMessage = nil
            } catch is CancellationError {
                // Teardown cancelled the download (disconnect while opening) —
                // the session is going away; a stale banner on the NEXT
                // session would be misattributed. Show nothing.
            } catch {
                tab.editErrorMessage = String(format: L10n.string(
                    "edit.openFailed", "Could not open file for editing: %@"),
                    TransferQueueViewModel.message(for: error))
            }
        }
    }

    // MARK: - Session export/import (M9a/T3)

    /// Builds the export payload, encodes it, and arms `fileExporter` — the
    /// sheet's Export button calls this and stays open (showing the
    /// returned message) on failure, or dismisses itself on `nil` (spec
    /// M9a §3.3). Encoding failure is rare (random salt generation, AES-GCM
    /// sealing) but not impossible, so it is reported inline rather than
    /// asserted away.
    private func performExport(
        scope: SessionListViewModel.ExportScope, options: SessionExportOptions
    ) -> String? {
        let (payload, missingPasswordCount) = sessionListViewModel.exportPayload(
            for: scope, includeGroups: options.includeGroups, includePasswords: options.includePasswords)
        do {
            let data = try SessionExportCodec.encode(payload, password: options.password)
            exportDocument = SessionExportDocument(data: data)
            // Only meaningful when passwords were actually requested —
            // `exportPayload` only counts missing entries in that case.
            exportMissingPasswordCount = options.includePasswords ? missingPasswordCount : 0
            showExportFileExporter = true
            return nil
        } catch {
            return String(format: L10n.string(
                "export.error.encodeFailed %@", "Could not prepare the export: %@"),
                String(describing: error))
        }
    }

    /// `fileExporter` completion: on success, surfaces the "exported without
    /// password" notice when applicable (spec M9a §3.3); on failure, a
    /// generic localized write-error alert.
    private func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            if exportMissingPasswordCount > 0 {
                showExportMissingPasswordAlert = true
            }
        case .failure(let error):
            exportErrorMessage = String(format: L10n.string(
                "export.error.writeFailed %@", "Could not write the export file: %@"),
                String(describing: error))
        }
        // Clear the encoded (possibly plaintext-password-bearing) export
        // bytes from view state once the panel has resolved, whether it
        // succeeded, failed, or the user cancelled the save (M9a final
        // review, Finding 3) — nothing should keep them around indefinitely.
        exportDocument = nil
    }

    /// Shared formatter for non-typed read/decode failures on the import
    /// path — single source for the message so the three call sites cannot
    /// drift apart (T3 review).
    private func readErrorMessage(_ error: Error) -> String {
        String(format: L10n.string(
            "import.error.readFailed %@", "Could not read the file: %@"),
            String(describing: error))
    }

    /// `fileImporter` completion: reads the chosen file with security-scoped
    /// access (the URL comes from an NSOpenPanel outside this app's own
    /// sandbox container) and probes whether it's encrypted before deciding
    /// whether the password sheet is needed.
    private func handleImportFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importErrorMessage = readErrorMessage(error)
        case .success(let urls):
            guard let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                if try SessionExportCodec.probe(data) {
                    importFileData = data
                    showImportPasswordSheet = true
                } else {
                    // Unencrypted: decode right here (no sheet is up), then
                    // plan/apply — the planner is async since M19, and the
                    // file bytes are already in memory, so the security-scoped
                    // access this method holds need not outlive the task.
                    if case .ready(let pending) = decodeImport(data: data, password: nil) {
                        Task { await applyImport(pending) }
                    }
                }
            } catch let error as SessionExportError {
                importErrorMessage = importErrorText(for: error)
            } catch {
                importErrorMessage = readErrorMessage(error)
            }
        }
    }

    /// What a decode attempt produced: something to plan, something the user
    /// can fix by retyping the password, or a failure already surfaced in the
    /// top-level alert.
    private enum ImportDecodeOutcome {
        case ready(PendingSessionImport)
        /// Keep the password sheet open and show this message.
        case retry(String)
        case failed
    }

    /// Decode step of an import (spec M9a §3.4). Planning deliberately does
    /// NOT happen here — see `pendingImport`'s doc comment.
    private func decodeImport(data: Data, password: String?) -> ImportDecodeOutcome {
        do {
            return .ready(PendingSessionImport(
                payload: try SessionExportCodec.decode(data, password: password),
                wasEncrypted: password != nil))
        } catch SessionExportError.wrongPasswordOrCorrupted {
            return .retry(
                L10n.string("import.password.wrong", "Wrong password, or the file is corrupted."))
        } catch let error as SessionExportError {
            importErrorMessage = importErrorText(for: error)
            return .failed
        } catch {
            importErrorMessage = readErrorMessage(error)
            return .failed
        }
    }

    /// Plan → apply for an already-decoded payload. No auto-connect afterwards
    /// (spec M9a §3.5) — only the store/keychain are touched.
    ///
    /// Duplicates are resolved through the SHARED arbiter (M19), whose decider
    /// is `importConflictBridge` and therefore the same `ImportConflictSheet`
    /// the login-set import shows. A cancelled run reports NOTHING: no alert
    /// at all, rather than an "import finished" full of zeros for an import
    /// the user explicitly called off.
    private func applyImport(_ pending: PendingSessionImport) async {
        let bridge = importConflictBridge
        let arbiter = ImportConflictArbiter { conflict in await bridge.ask(conflict) }
        let plan = await SessionImportPlanner.plan(
            existing: sessionListViewModel.sessions,
            existingGroups: sessionListViewModel.groups,
            incoming: pending.payload,
            arbiter: arbiter)
        importFileData = nil
        guard !plan.cancelled else { return }
        let result = sessionListViewModel.applyImport(plan)
        importResultMessage = importResultText(
            result, plan: plan, includesSecrets: pending.payload.includesSecrets,
            encrypted: pending.wasEncrypted)
        showImportResultAlert = true
    }

    /// Maps the two non-password `SessionExportError` cases the top-level
    /// alert can show (spec M9a §3.5). `.passwordRequired` and
    /// `.wrongPasswordOrCorrupted` are only ever thrown from a `decode` call
    /// that already supplied a password (handled inline by the password
    /// sheet instead), so they fall back to the same generic text here —
    /// defensive only, never actually reached.
    private func importErrorText(for error: SessionExportError) -> String {
        switch error {
        case .notAnExportFile:
            return L10n.string("import.error.notExport", "Not a macSCP sessions file.")
        case .unsupportedVersion:
            return L10n.string(
                "import.error.newerVersion",
                "This file was created by a newer version of macSCP.")
        case .passwordRequired, .wrongPasswordOrCorrupted:
            return L10n.string("import.password.wrong", "Wrong password, or the file is corrupted.")
        case .randomnessUnavailable:
            // Only ever thrown from `encode`, never from `decode` — this
            // import-path mapper never actually reaches it. Kept for
            // exhaustiveness now that the enum has a fourth case.
            return L10n.string("import.error.notExport", "Not a macSCP sessions file.")
        }
    }

    /// Assembles the multi-line import result alert body (spec M9a §3.4):
    /// the base imported/skipped/passwords-imported line, the M19 lines for
    /// what the user decided about duplicates (replaced/renamed) and for
    /// secrets a replace removed, plus optional lines for password-save
    /// failures, store-write failures, and an unencrypted-secrets notice when
    /// the file wasn't itself encrypted.
    private func importResultText(
        _ result: SessionListViewModel.SessionImportResult, plan: SessionImportPlan,
        includesSecrets: Bool, encrypted: Bool
    ) -> String {
        var lines = [String(format: L10n.string(
            "import.result.body %lld %lld %lld",
            "%lld imported, %lld skipped as duplicates, %lld passwords imported"),
            result.imported, result.skipped, result.passwordsImported)]
        if !plan.replaced.isEmpty || !plan.renamed.isEmpty {
            lines.append(String(format: L10n.string(
                "import.result.resolved %lld %lld", "%lld replaced, %lld renamed"),
                plan.replaced.count, plan.renamed.count))
        }
        // A replace from a secret-free file drops the stored password rather
        // than leaving the old one bound (see `applyImport`) — the user has to
        // be told, or the session silently stops connecting.
        if result.secretsRemoved > 0 {
            lines.append(String(format: L10n.string(
                "import.result.secretsRemoved %lld",
                "Stored passwords removed because the file had none: %lld"),
                result.secretsRemoved))
        }
        // The other half of that rule: a removal the Keychain refused leaves
        // the OLD credential live under the reused id. Silence there would be
        // the worst case of all — a session connecting with a password the
        // user believes they just replaced.
        if result.secretRemovalFailures > 0 {
            lines.append(String(format: L10n.string(
                "import.result.secretsRemoveFailed %lld",
                "Stored passwords that could not be removed: %lld"),
                result.secretRemovalFailures))
        }
        if result.passwordFailures > 0 {
            lines.append(String(format: L10n.string(
                "import.result.passwordFailures %lld", "Passwords that could not be saved: %lld"),
                result.passwordFailures))
        }
        if result.storeFailures > 0 {
            lines.append(String(format: L10n.string(
                "import.result.storeFailures %lld", "Not saved due to an error: %lld"),
                result.storeFailures))
        }
        if includesSecrets && !encrypted {
            lines.append(L10n.string(
                "import.result.plaintextNotice", "The file contained unencrypted passwords."))
        }
        return lines.joined(separator: "\n")
    }
}
