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
    /// Command bridge (M8a/T4): `MacSCPApp` holds no reference to
    /// `ContentView`, so the menu's Cmd-N/Cmd-W/Cmd-1…9 items call into the
    /// closures this view assigns in `.task` below.
    let tabCommands: TabCommands
    @State private var sessionListViewModel = SessionListViewModel(
        store: SessionStore(directory: SessionStore.defaultDirectory),
        secrets: KeychainSecretStore()
    )
    /// Window-scoped tab collection (M8a/T3). Everything that used to be
    /// window-wide session state (connection form, session, queue, conflict
    /// bridge, title, edit error, reconnect flag) now lives per tab in
    /// `SessionTab`; only `window`, `lastBrowserSize`, `importedHosts`,
    /// `sessionListViewModel` and the two injected stores stay window-wide.
    @State private var tabsModel: TabsViewModel<SessionTab>
    @State private var importedHosts: [SSHConfigHost] = []
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

    // MARK: - Session export/import (M9a/T3)

    /// Wraps `ExportScope` so it can drive `.sheet(item:)` — `ExportScope`
    /// itself has no stable identity of its own that covers all three cases
    /// (`.all` has none at all).
    private struct ExportSheetItem: Identifiable {
        let id = UUID()
        let scope: SessionListViewModel.ExportScope
    }

    @State private var exportSheetItem: ExportSheetItem?
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
    @State private var importResultMessage: String = ""
    @State private var showImportResultAlert = false
    @State private var importErrorMessage: String?

    init(settingsStore: SettingsStore, bandwidthLimiter: BandwidthLimiter, tabCommands: TabCommands) {
        self.settingsStore = settingsStore
        self.bandwidthLimiter = bandwidthLimiter
        self.tabCommands = tabCommands
        _tabsModel = State(initialValue: TabsViewModel(
            initial: Self.makeTab(settingsStore: settingsStore, limiter: bandwidthLimiter)))
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

    var body: some View {
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
                    sessionListViewModel.delete(stored)
                    for tab in tabsModel.tabs where tab.activeStoredSessionID == stored.id {
                        tab.activeStoredSessionID = nil
                    }
                },
                onNew: { newConnection() },
                onSelectImported: { fillFromImported($0) },
                onEdit: { stored in editStored(stored) },
                onExport: { scope in exportSheetItem = ExportSheetItem(scope: scope) },
                onImport: { showImportFileImporter = true }
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
            importedHosts = SSHConfigImporter.load(path: SSHConfigImporter.defaultPath)
            // Seed the shared limiter from the settings once per window; the
            // `.onChange` observers below keep it in sync afterwards. KBs → bytes/s.
            bandwidthLimiter.uploadLimitBytesPerSec = settingsStore.uploadLimitKBs * 1024
            bandwidthLimiter.downloadLimitBytesPerSec = settingsStore.downloadLimitKBs * 1024
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
            tabCommands.closeActiveTab = {
                guard window?.isKeyWindow == true else {
                    // Not our window: route Close to whichever window IS key
                    // (typically Settings) via the system path instead of
                    // silently doing nothing.
                    NSApp.keyWindow?.performClose(nil)
                    return
                }
                let tab = tabsModel.activeTab
                if tabsModel.isLastTab && !tab.isConnected {
                    // The only tab left, already a pristine form: Cmd-W
                    // closes the WINDOW via the system path instead of the
                    // tab-close flow (there is nothing left to revert to).
                    window?.performClose(nil)
                } else {
                    requestClose(tab)
                }
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
        .sheet(isPresented: $showImportPasswordSheet) {
            ImportPasswordSheet(
                onSubmit: { password in
                    guard let data = importFileData else { return nil }
                    return finishImport(data: data, password: password)
                },
                onCancel: { importFileData = nil }
            )
        }
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
                        session.terminal.toggle()
                    } label: {
                        Label(L10n.string("browser.terminalToggle", "Terminal"), systemImage: "terminal")
                    }
                    .keyboardShortcut("t", modifiers: .command)
                    .help(L10n.string("browser.terminalToggleHelp", "Show/hide terminal (⌘T)"))
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
                                    case .rename, .infoAndPermissions, .newFolder, .delete:
                                        break   // handled inside BrowserPane, never forwarded
                                    }
                                },
                                crossSessionTargets: { crossSessionTargets(for: tab) }
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
                                    case .rename, .infoAndPermissions, .newFolder, .delete:
                                        break   // handled inside BrowserPane, never forwarded
                                    }
                                },
                                crossSessionTargets: { crossSessionTargets(for: tab) }
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

                    TransferQueueBar(viewModel: tab.transferQueue)
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
                    onSaveEdited: { stored, secret in
                        sessionListViewModel.updateSession(stored, newSecret: secret)
                        tab.connectionViewModel.endEditing()
                    },
                    onCancelEdit: { tab.connectionViewModel.endEditing() },
                    onConnectEdited: { stored in connect(in: tab, stored: stored) }
                ) { fs in
                    startSession(in: tab, with: fs)
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
            connectionViewModel: ConnectionViewModel(connector: { config, onUnknownHostKey in
                try await CitadelFileSystem.connect(
                    config: config,
                    knownHosts: KnownHostsStore(directory: SessionStore.defaultDirectory),
                    onUnknownHostKey: onUnknownHostKey
                )
            }),
            limiter: limiter,
            maxConcurrent: settingsStore.maxConcurrentTransfers
        )
    }

    private func makeTab() -> SessionTab {
        Self.makeTab(settingsStore: settingsStore, limiter: bandwidthLimiter)
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
        }
        let form = tab.connectionViewModel
        form.clearPassword()
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
    /// bottom, so it's adjusted by the height difference.
    private func resizeWindow(toWidth width: CGFloat, height: CGFloat) {
        guard let window else { return }
        let current = window.frame
        let newOrigin = NSPoint(x: current.origin.x, y: current.origin.y + current.height - height)
        let newFrame = NSRect(origin: newOrigin, size: CGSize(width: width, height: height))
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
                SSHTerminalView(viewModel: session.terminal)
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

    /// After a successful connect: build the panes of THIS tab and save the
    /// session if requested. `storedName` is the display name for the tab/
    /// window title when connecting to an already-stored session
    /// (`connect(in:stored:)`). It exists because
    /// `connectionViewModel.saveName` cannot be trusted here: the field
    /// survives toggling "Save as session" off and earlier sessions, so an
    /// UNSAVED connection could inherit a stale, unrelated name (M5f/T5
    /// review).
    private func startSession(
        in tab: SessionTab, with fs: any RemoteFileSystem, storedName: String? = nil
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
        tab.session = BrowserSession(
            id: sessionID,
            localFS: LocalFileSystem(),
            remoteFS: fs,
            local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
            remote: RemoteBrowserViewModel(fs: fs),
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
            let stored = sessionListViewModel.save(
                name: form.saveName.trimmingCharacters(in: .whitespacesAndNewlines),
                host: form.host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: Int(form.port.trimmingCharacters(in: .whitespaces)) ?? 22,
                username: form.username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: form.password,
                authKind: form.authChoice == .password ? .password : .privateKey,
                keyPath: form.authChoice == .privateKey
                    ? form.keyPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil,
                groupID: form.selectedGroupID
            )
            tab.activeStoredSessionID = stored?.id
            form.shouldSaveSession = false
            titleName = stored?.name ?? titleName
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
            form.username = stored.username
            form.saveName = stored.name
            form.shouldSaveSession = false
            form.password = sessionListViewModel.password(for: stored) ?? ""
            form.authChoice = stored.authKind == .privateKey ? .privateKey : .password
            form.keyPath = stored.keyPath ?? ""

            if let fs = await form.connect() {
                startSession(in: tab, with: fs, storedName: stored.name)
                tab.activeStoredSessionID = stored.id
            }
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
                id: other.id, title: other.displayTitle, remotePath: session.remote.currentPath)
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
                    destinationTabID: target.id)
            case (.local, _):
                queue.enqueue(
                    fileName: item.name, direction: .upload,
                    source: session.localFS, sourcePath: item.path,
                    destination: targetSession.remoteFS,
                    destinationDirectory: target.remotePath,
                    onCompleted: { [weak remote = targetSession.remote] in await remote?.refresh() },
                    destinationTabID: target.id)
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
                    destinationTabID: target.id, crossRemote: true)
            case (.remote, _):
                queue.enqueue(
                    fileName: item.name, direction: .upload,
                    source: session.remoteFS, sourcePath: item.path,
                    destination: targetSession.remoteFS,
                    destinationDirectory: target.remotePath,
                    onCompleted: { [weak remote = targetSession.remote] in await remote?.refresh() },
                    destinationTabID: target.id, crossRemote: true)
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
    }

    /// `fileImporter` completion: reads the chosen file with security-scoped
    /// access (the URL comes from an NSOpenPanel outside this app's own
    /// sandbox container, the same access pattern the key importer in
    /// `ConnectionFormView` relies on) and probes whether it's encrypted
    /// before deciding whether the password sheet is needed.
    private func handleImportFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importErrorMessage = String(format: L10n.string(
                "import.error.readFailed %@", "Could not read the file: %@"),
                String(describing: error))
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
                    _ = finishImport(data: data, password: nil)
                }
            } catch let error as SessionExportError {
                importErrorMessage = importErrorText(for: error)
            } catch {
                importErrorMessage = String(format: L10n.string(
                    "import.error.readFailed %@", "Could not read the file: %@"),
                    String(describing: error))
            }
        }
    }

    /// Decode → plan → apply for a chosen import file (spec M9a §3.4). No
    /// auto-connect afterwards (spec M9a §3.5) — only the store/keychain are
    /// touched. Returns an inline message for the CALLER to show (only
    /// meaningful for the password sheet's "wrong password" case, so it can
    /// stay open for another attempt); every other error kind is pushed to
    /// the top-level `importErrorMessage` alert directly and `nil` is
    /// returned so a presenting sheet dismisses.
    @discardableResult
    private func finishImport(data: Data, password: String?) -> String? {
        do {
            let payload = try SessionExportCodec.decode(data, password: password)
            let plan = SessionImportPlanner.plan(
                existing: sessionListViewModel.sessions,
                existingGroups: sessionListViewModel.groups,
                incoming: payload)
            let result = sessionListViewModel.applyImport(plan)
            importResultMessage = importResultText(
                result, includesSecrets: payload.includesSecrets, encrypted: password != nil)
            showImportResultAlert = true
            importFileData = nil
            return nil
        } catch SessionExportError.wrongPasswordOrCorrupted {
            return L10n.string("import.password.wrong", "Wrong password, or the file is corrupted.")
        } catch let error as SessionExportError {
            importErrorMessage = importErrorText(for: error)
            return nil
        } catch {
            importErrorMessage = String(format: L10n.string(
                "import.error.readFailed %@", "Could not read the file: %@"),
                String(describing: error))
            return nil
        }
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
        }
    }

    /// Assembles the multi-line import result alert body (spec M9a §3.4):
    /// the base imported/skipped/passwords-imported line, plus optional
    /// lines for password-save failures, store-write failures, and an
    /// unencrypted-secrets notice when the file wasn't itself encrypted.
    private func importResultText(
        _ result: SessionListViewModel.SessionImportResult, includesSecrets: Bool, encrypted: Bool
    ) -> String {
        var lines = [String(format: L10n.string(
            "import.result.body %lld %lld %lld",
            "%lld imported, %lld skipped as duplicates, %lld passwords imported"),
            result.imported, result.skipped, result.passwordsImported)]
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
