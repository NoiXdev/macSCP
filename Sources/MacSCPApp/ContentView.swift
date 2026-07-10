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

struct ContentView: View {
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
        .task { importedHosts = SSHConfigImporter.load(path: SSHConfigImporter.defaultPath) }
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
                        Label("Terminal", systemImage: "terminal")
                    }
                    .keyboardShortcut("t", modifiers: .command)
                    .help("Terminal ein-/ausblenden (⌘T)")
                    Button("Trennen") {
                        disconnectToForm()
                    }
                    .disabled(transferQueue.isActive)
                }
                .padding(8)

                Divider()

                VSplitView {
                    HSplitView {
                        BrowserPane(
                            title: "Lokal",
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
                            title: "Remote",
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
        } else {
            ConnectionFormView(viewModel: connectionViewModel) { fs in
                startSession(with: fs)
            }
        }
    }

    /// Panel-Inhalt: Terminal bei laufender Shell, sonst Ende-/Leerzustand.
    /// `SSHTerminalView` wird bewusst nur bei aktiver Shell eingehängt, damit
    /// `onOutput` bei jedem Neuöffnen frisch bindet.
    @ViewBuilder
    private func terminalPanel(_ session: BrowserSession) -> some View {
        ZStack {
            Color(nsColor: DesignTokens.terminalBackground)
            switch session.terminal.state {
            case .running, .opening:
                SSHTerminalView(viewModel: session.terminal)
            case .ended(let message):
                VStack(spacing: 8) {
                    Text(message ?? "Shell beendet.")
                        .foregroundStyle(Color(nsColor: DesignTokens.terminalText))
                    Button("Neu öffnen") { session.terminal.openIfNeeded() }
                }
            case .closed:
                Color.clear
            }
        }
    }

    /// Nach erfolgreichem Verbinden: Panes aufbauen und ggf. Session speichern.
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
                        reason: "Diese Verbindung unterstützt kein Terminal.")
                }
                return try await shellProvider.openShell(
                    terminal: term, cols: cols, rows: rows)
            })
        )
        transferQueue = TransferQueueViewModel()

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

    /// Sidebar-Klick: bestehende Verbindung trennen, Formular aus Store +
    /// Schlüsselbund füllen und direkt verbinden.
    private func connectStored(_ stored: StoredSession) {
        guard !isReconnecting else { return }
        isReconnecting = true // synchron — sperrt die Sidebar sofort, vor dem ersten await
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

    /// Import-Klick: Formular aus dem ssh-config-Eintrag füllen — bewusst
    /// OHNE Verbinden (der Import kennt keine Geheimnisse).
    private func fillFromImported(_ host: SSHConfigHost) {
        guard !isReconnecting else { return }
        Task {
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
        Task {
            await teardownSession()
        }
    }

    private func teardownSession() async {
        if let session {
            await transferQueue.cancelAll()
            await session.terminal.shutdown()
            await session.remote.disconnect()
        }
        connectionViewModel.clearPassword()
        connectionViewModel.authChoice = .password
        connectionViewModel.keyPath = ""
        session = nil
        activeSessionID = nil
    }

    /// Lokal ausgewählte DATEI → aktuelles Remote-Verzeichnis.
    @ViewBuilder
    private func uploadButton(_ session: BrowserSession) -> some View {
        let selected = session.local.selectedItem
        Button {
            guard let selected else { return }
            transferQueue.enqueue(
                fileName: selected.name, direction: .upload,
                source: session.localFS, sourcePath: selected.path,
                destination: session.remoteFS,
                destinationDirectory: session.remote.currentPath,
                onCompleted: { await session.remote.refresh() }
            )
        } label: {
            Label("Hochladen", systemImage: "arrow.up")
        }
        .tint(DesignTokens.localAmber)
        .disabled(selected == nil || selected?.kind != .file)
        .help("Ausgewählte lokale Datei ins Remote-Verzeichnis hochladen")
    }

    /// Remote ausgewählte DATEI → aktuelles lokales Verzeichnis.
    @ViewBuilder
    private func downloadButton(_ session: BrowserSession) -> some View {
        let selected = session.remote.selectedItem
        Button {
            guard let selected else { return }
            transferQueue.enqueue(
                fileName: selected.name, direction: .download,
                source: session.remoteFS, sourcePath: selected.path,
                destination: session.localFS,
                destinationDirectory: session.local.currentPath,
                onCompleted: { await session.local.refresh() }
            )
        } label: {
            Label("Herunterladen", systemImage: "arrow.down")
        }
        .tint(DesignTokens.remoteBlue)
        .disabled(selected == nil || selected?.kind != .file)
        .help("Ausgewählte Remote-Datei ins lokale Verzeichnis herunterladen")
    }

    /// Gedroppte Datei-URLs in die Queue einreihen (Ordner werden übersprungen).
    /// Kein Guard mehr nötig: die Queue nimmt jeden Drop an und reiht ihn ein.
    private func uploadDropped(_ urls: [URL], session: BrowserSession) {
        let files = urls.filter { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            return exists && !isDirectory.boolValue
        }
        for url in files {
            transferQueue.enqueue(
                fileName: url.lastPathComponent, direction: .upload,
                source: session.localFS, sourcePath: url.path(percentEncoded: false),
                destination: session.remoteFS,
                destinationDirectory: session.remote.currentPath,
                onCompleted: { await session.remote.refresh() }
            )
        }
    }

    /// Promise-Einlösung: Remote-Datei über die Queue an die vom Finder
    /// vorgegebene URL laden — serialisiert sich mit allen anderen Transfers.
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
