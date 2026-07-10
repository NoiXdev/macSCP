import AppKit
import SwiftUI
import macSCPCore

struct BrowserSession {
    let localFS: LocalFileSystem
    let remoteFS: any RemoteFileSystem
    let local: RemoteBrowserViewModel
    let remote: RemoteBrowserViewModel
    let terminal: TerminalPanelViewModel
}

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
/// outlives the `ContentView` struct.
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
            Toggle(L10n.string("conflict.applyToAll", "Apply to all further items"), isOn: $applyToAll)
            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel"), role: .cancel) { onCancel() }
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
    /// no singleton, per the v2 multi-window rule). Wired into
    /// `transferQueue` at session start and kept in sync via `.onChange`
    /// (M5c/T4 queue parallelism, M5c/T5 bandwidth limits).
    let settingsStore: SettingsStore
    @State private var connectionViewModel = ConnectionViewModel(connector: { config, onUnknownHostKey in
        try await CitadelFileSystem.connect(
            config: config,
            knownHosts: KnownHostsStore(directory: SessionStore.defaultDirectory),
            onUnknownHostKey: onUnknownHostKey
        )
    })
    @State private var sessionListViewModel = SessionListViewModel(
        store: SessionStore(directory: SessionStore.defaultDirectory),
        secrets: KeychainSecretStore()
    )
    @State private var session: BrowserSession?
    @State private var activeSessionID: UUID?
    @State private var transferQueue = TransferQueueViewModel()
    @State private var isReconnecting = false
    @State private var importedHosts: [SSHConfigHost] = []
    @State private var conflictBridge = ConflictPromptBridge()
    /// Handed over by `WindowAccessor` — basis for the active resize calls
    /// on state transitions (M5c/T0).
    @State private var window: NSWindow?
    /// Last browser window size, remembered on disconnect — the next
    /// connect grows to it instead of the minimum size, if it's larger.
    @State private var lastBrowserSize: CGSize?

    private var sidebarDisabled: Bool {
        isReconnecting
            || transferQueue.isActive
            || connectionViewModel.state == .connecting
    }

    var body: some View {
        HSplitView {
            SessionSidebar(
                viewModel: sessionListViewModel,
                importedHosts: importedHosts,
                activeSessionID: activeSessionID,
                interactionsDisabled: sidebarDisabled,
                onSelect: { stored in connectStored(stored) },
                onDelete: { stored in
                    sessionListViewModel.delete(stored)
                    if activeSessionID == stored.id {
                        activeSessionID = nil
                    }
                },
                onNew: { disconnectToForm() },
                onSelectImported: { fillFromImported($0) }
            )
            .frame(minWidth: 170, idealWidth: 190, maxWidth: 260)

            detail
                .frame(minWidth: 590, maxWidth: .infinity)
        }
        // Compact form vs. browser: the minimum size depends on the
        // connection state (M5c/T0) — replaces the global `.frame` from
        // `MacSCPApp.swift`.
        .frame(minWidth: session == nil ? 700 : 930, minHeight: 460)
        .background(WindowAccessor { window = $0 })
        .task { importedHosts = SSHConfigImporter.load(path: SSHConfigImporter.defaultPath) }
        // Settings live-wiring (M5c/T4+T5): each observer targets
        // `transferQueue` directly rather than a captured snapshot, so it
        // keeps applying to whichever session's queue is current. A change
        // affects FUTURE slot assignments/items only — see the properties'
        // doc comments in `TransferQueueViewModel`.
        .onChange(of: settingsStore.maxConcurrentTransfers) { _, newValue in
            transferQueue.maxConcurrent = newValue
        }
        .onChange(of: settingsStore.uploadLimitKBs) { _, newValue in
            transferQueue.uploadLimitBytesPerSec = newValue * 1024
        }
        .onChange(of: settingsStore.downloadLimitKBs) { _, newValue in
            transferQueue.downloadLimitBytesPerSec = newValue * 1024
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let session {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    uploadButton(session)
                    downloadButton(session)
                    Spacer()
                    Button {
                        session.terminal.toggle()
                    } label: {
                        Label(L10n.string("browser.terminalToggle", "Terminal"), systemImage: "terminal")
                    }
                    .keyboardShortcut("t", modifiers: .command)
                    .help(L10n.string("browser.terminalToggleHelp", "Show/hide terminal (⌘T)"))
                    Button(L10n.string("browser.disconnect", "Disconnect")) {
                        disconnectToForm()
                    }
                    .disabled(transferQueue.isActive)
                }
                .padding(8)

                Divider()

                VSplitView {
                    HSplitView {
                        BrowserPane(
                            title: L10n.string("browser.paneLocal", "Local"),
                            tint: DesignTokens.localAmber,
                            viewModel: session.local,
                            pasteboardWriter: { item in
                                item.kind == .file
                                    ? NSURL(fileURLWithPath: item.path)
                                    : nil
                            }
                        )
                        .frame(minWidth: 280)

                        BrowserPane(
                            title: L10n.string("browser.paneRemote", "Remote"),
                            tint: DesignTokens.remoteBlue,
                            viewModel: session.remote,
                            onDropURLs: { urls in
                                uploadDropped(urls, session: session)
                            },
                            pasteboardWriter: { item in
                                item.kind == .file
                                    ? remotePromiseProvider(for: item, session: session)
                                    : nil
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

                TransferQueueBar(viewModel: transferQueue)
            }
            .sheet(
                item: Binding(
                    get: { conflictBridge.currentPrompt },
                    set: { newValue in
                        if newValue == nil { conflictBridge.dismiss() }
                    }
                ),
                onDismiss: { conflictBridge.dismiss() }
            ) { item in
                ConflictSheetView(
                    conflict: item.conflict,
                    onResolve: { resolution, applyToAll in
                        conflictBridge.resolve((resolution: resolution, applyToAll: applyToAll))
                    },
                    onCancel: { conflictBridge.dismiss() }
                )
            }
        } else {
            // Align the form to the top instead of centering it vertically
            // (user feedback 2026-07-10, M5c/T0) — otherwise the compact
            // window has a lot of empty space below the content.
            ConnectionFormView(viewModel: connectionViewModel) { fs in
                startSession(with: fs)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

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
                        .foregroundStyle(Color(nsColor: DesignTokens.terminalText))
                    Button(L10n.string("terminal.reopen", "Reopen")) { session.terminal.openIfNeeded() }
                }
            case .closed:
                Color.clear
            }
        }
    }

    /// After a successful connect: build the panes and save the session if requested.
    private func startSession(with fs: any RemoteFileSystem) {
        let shellProvider = fs as? RemoteShellProvider
        session = BrowserSession(
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
            })
        )
        // The queue is created ONCE (the `@State` initializer) and OUTLIVES
        // each session (M5d/T3): interrupted transfers stay in the bar across a
        // disconnect/reconnect so `retryInterrupted` can resume them. Only the
        // decider and the settings-derived limits are (re-)wired per session.
        let bridge = conflictBridge
        transferQueue.conflictDecider = { conflict in await bridge.ask(conflict) }
        // Settings wiring (M5c/T4 concurrency, M5c/T5 bandwidth): applied once
        // here at session start, and kept in sync afterwards by the
        // `.onChange` observers below (they target `transferQueue` directly,
        // so they keep working across session restarts too). KBs → bytes/s.
        transferQueue.maxConcurrent = settingsStore.maxConcurrentTransfers
        transferQueue.uploadLimitBytesPerSec = settingsStore.uploadLimitKBs * 1024
        transferQueue.downloadLimitBytesPerSec = settingsStore.downloadLimitKBs * 1024

        // Actively grow the window to the browser size (user feedback
        // 2026-07-10, M5c/T0) — to the last remembered browser size, if any
        // and larger than the minimum size.
        let targetSize = CGSize(
            width: max(lastBrowserSize?.width ?? 0, 930),
            height: max(lastBrowserSize?.height ?? 0, 620))
        resizeWindow(toWidth: targetSize.width, height: targetSize.height)

        if connectionViewModel.shouldSaveSession {
            let stored = sessionListViewModel.save(
                name: connectionViewModel.saveName
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                host: connectionViewModel.host
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                port: Int(connectionViewModel.port
                    .trimmingCharacters(in: .whitespaces)) ?? 22,
                username: connectionViewModel.username
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                password: connectionViewModel.password,
                authKind: connectionViewModel.authChoice == .password ? .password : .privateKey,
                keyPath: connectionViewModel.authChoice == .privateKey
                    ? connectionViewModel.keyPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil
            )
            activeSessionID = stored?.id
            connectionViewModel.shouldSaveSession = false
        }
    }

    /// Sidebar click: disconnect the current connection, fill the form from
    /// the store + keychain, and connect right away.
    private func connectStored(_ stored: StoredSession) {
        guard !isReconnecting else { return }
        isReconnecting = true // synchronous — locks the sidebar immediately, before the first await
        Task {
            defer { isReconnecting = false }
            await teardownSession()
            connectionViewModel.host = stored.host
            connectionViewModel.port = String(stored.port)
            connectionViewModel.username = stored.username
            connectionViewModel.saveName = stored.name
            connectionViewModel.shouldSaveSession = false
            connectionViewModel.password = sessionListViewModel.password(for: stored) ?? ""
            connectionViewModel.authChoice =
                stored.authKind == .privateKey ? .privateKey : .password
            connectionViewModel.keyPath = stored.keyPath ?? ""

            if let fs = await connectionViewModel.connect() {
                startSession(with: fs)
                activeSessionID = stored.id
            }
        }
    }

    /// Import click: fill the form from the ssh-config entry — deliberately
    /// WITHOUT connecting (the import knows no secrets).
    private func fillFromImported(_ host: SSHConfigHost) {
        guard !isReconnecting else { return }
        isReconnecting = true // synchronous — prevents double teardown (would corrupt lastBrowserSize)
        Task {
            defer { isReconnecting = false }
            await teardownSession()
            connectionViewModel.host = host.hostName ?? host.alias
            connectionViewModel.port = String(host.port ?? 22)
            connectionViewModel.username = host.user ?? ""
            connectionViewModel.saveName = host.alias
            connectionViewModel.shouldSaveSession = false
            if let identityFile = host.identityFile {
                connectionViewModel.authChoice = .privateKey
                connectionViewModel.keyPath = identityFile
            } else {
                connectionViewModel.authChoice = .password
                connectionViewModel.keyPath = ""
            }
        }
    }

    private func disconnectToForm() {
        guard !isReconnecting else { return }
        isReconnecting = true // synchronous — prevents double teardown (would corrupt lastBrowserSize)
        Task {
            defer { isReconnecting = false }
            await teardownSession()
        }
    }

    private func teardownSession() async {
        let hadSession = session != nil
        if let session {
            // MUST run before `cancelAll()`: an open conflict sheet would
            // otherwise keep the decider prompt open, which `cancelAll`
            // (documented) hangs on until it's answered — deadlock on disconnect.
            conflictBridge.dismiss()
            await transferQueue.cancelAll()
            await session.terminal.shutdown()
            await session.remote.disconnect()
        }
        connectionViewModel.clearPassword()
        connectionViewModel.authChoice = .password
        connectionViewModel.keyPath = ""
        session = nil
        activeSessionID = nil
        if hadSession {
            // Remember the current browser size (for the next connect) and
            // actively shrink the window to the compact form size (user
            // feedback 2026-07-10, M5c/T0).
            if let window { lastBrowserSize = window.frame.size }
            resizeWindow(toWidth: 700, height: 460)
        }
    }

    /// Locally selected file OR folder → current remote directory.
    /// Symlink selection stays disabled (not a meaningful transfer target).
    @ViewBuilder
    private func uploadButton(_ session: BrowserSession) -> some View {
        let selected = session.local.selectedItem
        Button {
            guard let selected else { return }
            if selected.kind == .directory {
                transferQueue.enqueueTree(
                    directoryName: selected.name, direction: .upload,
                    source: session.localFS, sourceDirectory: selected.path,
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { [weak remote = session.remote] in await remote?.refresh() }
                )
            } else {
                transferQueue.enqueue(
                    fileName: selected.name, direction: .upload,
                    source: session.localFS, sourcePath: selected.path,
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { [weak remote = session.remote] in await remote?.refresh() }
                )
            }
        } label: {
            Label(L10n.string("browser.upload", "Upload"), systemImage: "arrow.up")
        }
        .tint(DesignTokens.localAmber)
        .disabled(selected == nil || selected?.kind == .symlink)
        .help(L10n.string(
            "browser.uploadHelp", "Upload the selected local file/folder to the remote directory"))
    }

    /// Remotely selected file OR folder → current local directory.
    /// Symlink selection stays disabled (not a meaningful transfer target).
    @ViewBuilder
    private func downloadButton(_ session: BrowserSession) -> some View {
        let selected = session.remote.selectedItem
        Button {
            guard let selected else { return }
            if selected.kind == .directory {
                transferQueue.enqueueTree(
                    directoryName: selected.name, direction: .download,
                    source: session.remoteFS, sourceDirectory: selected.path,
                    destination: session.localFS,
                    destinationDirectory: session.local.currentPath,
                    onCompleted: { [weak local = session.local] in await local?.refresh() }
                )
            } else {
                transferQueue.enqueue(
                    fileName: selected.name, direction: .download,
                    source: session.remoteFS, sourcePath: selected.path,
                    destination: session.localFS,
                    destinationDirectory: session.local.currentPath,
                    onCompleted: { [weak local = session.local] in await local?.refresh() }
                )
            }
        } label: {
            Label(L10n.string("browser.download", "Download"), systemImage: "arrow.down")
        }
        .tint(DesignTokens.remoteBlue)
        .disabled(selected == nil || selected?.kind == .symlink)
        .help(L10n.string(
            "browser.downloadHelp", "Download the selected remote file/folder to the local directory"))
    }

    /// Enqueues dropped file/folder URLs onto the queue. Files run through
    /// `enqueue`, folders recursively through `enqueueTree` (M5b/T3/T4) — no
    /// more directory filter, only URLs that no longer exist are discarded.
    private func uploadDropped(_ urls: [URL], session: BrowserSession) {
        for url in urls {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            guard exists else { continue }
            if isDirectory.boolValue {
                transferQueue.enqueueTree(
                    directoryName: url.lastPathComponent, direction: .upload,
                    source: session.localFS, sourceDirectory: url.path(percentEncoded: false),
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { [weak remote = session.remote] in await remote?.refresh() }
                )
            } else {
                transferQueue.enqueue(
                    fileName: url.lastPathComponent, direction: .upload,
                    source: session.localFS, sourcePath: url.path(percentEncoded: false),
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { [weak remote = session.remote] in await remote?.refresh() }
                )
            }
        }
    }

    /// Promise fulfillment: loads a remote file through the queue to the URL
    /// specified by the Finder — serializes with all other transfers.
    private func remotePromiseProvider(
        for item: RemoteFileItem, session: BrowserSession
    ) -> RemoteFilePromiseProvider {
        RemoteFilePromiseProvider(item: item) { item, url in
            try await transferQueue.enqueueAndWait(
                fileName: url.lastPathComponent, direction: .download,
                source: session.remoteFS, sourcePath: item.path,
                destination: session.localFS,
                destinationDirectory: url.deletingLastPathComponent()
                    .path(percentEncoded: false)
            )
        }
    }
}
