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

    init(settingsStore: SettingsStore, bandwidthLimiter: BandwidthLimiter) {
        self.settingsStore = settingsStore
        self.bandwidthLimiter = bandwidthLimiter
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
                onEdit: { stored in editStored(stored) }
            )
            .frame(minWidth: 170, idealWidth: 190, maxWidth: 260)

            detail
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
                                    case .copyPath:
                                        copyPaths(of: selection)
                                    case .openInEditor:
                                        break   // never emitted for the local pane (menu model)
                                    case .rename, .infoAndPermissions, .newFolder, .delete:
                                        break   // handled inside BrowserPane, never forwarded
                                    }
                                }
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
                                    case .openInEditor:
                                        if let item = selection.first {
                                            openInEditor(item, in: tab, session: session)
                                        }
                                    case .copyPath:
                                        copyPaths(of: selection)
                                    case .rename, .infoAndPermissions, .newFolder, .delete:
                                        break   // handled inside BrowserPane, never forwarded
                                    }
                                }
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
                // The binding deliberately resolves `tabsModel.activeTab` on every
                // access instead of capturing `tab`: only the tab in front may
                // present its prompt, and a tab switch must re-resolve the sheet
                // rather than keep a background tab's bridge alive here.
                .sheet(
                    item: Binding(
                        get: { tabsModel.activeTab.conflictBridge.currentPrompt },
                        set: { newValue in
                            if newValue == nil { tabsModel.activeTab.conflictBridge.dismiss() }
                        }
                    ),
                    onDismiss: { tabsModel.activeTab.conflictBridge.dismiss() }
                ) { item in
                    ConflictSheetView(
                        conflict: item.conflict,
                        onResolve: { resolution, applyToAll in
                            tabsModel.activeTab.conflictBridge.resolve(
                                (resolution: resolution, applyToAll: applyToAll))
                        },
                        onCancel: { tabsModel.activeTab.conflictBridge.dismiss() }
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

    /// Closes a tab: tab-local teardown first, then removal from the model
    /// (the last tab is not removable — `TabsViewModel.closeTab` returns
    /// false and the tab simply stays as a torn-down form tab).
    private func closeTab(_ tab: SessionTab) async {
        await teardown(tab)
        tabsModel.closeTab(tab.id)
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
}
