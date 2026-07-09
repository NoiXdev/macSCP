import AppKit
import SwiftUI
import macSCPCore

struct BrowserSession {
    let localFS: LocalFileSystem
    let remoteFS: any RemoteFileSystem
    let local: RemoteBrowserViewModel
    let remote: RemoteBrowserViewModel
}

struct ContentView: View {
    @State private var connectionViewModel = ConnectionViewModel(connector: { config in
        try await CitadelFileSystem.connect(config: config)
    })
    @State private var sessionListViewModel = SessionListViewModel(
        store: SessionStore(directory: SessionStore.defaultDirectory),
        secrets: KeychainSecretStore()
    )
    @State private var session: BrowserSession?
    @State private var activeSessionID: UUID?
    @State private var transferViewModel = TransferViewModel()
    @State private var isReconnecting = false

    private var sidebarDisabled: Bool {
        isReconnecting
            || transferViewModel.isRunning
            || connectionViewModel.state == .connecting
    }

    var body: some View {
        HSplitView {
            SessionSidebar(
                viewModel: sessionListViewModel,
                activeSessionID: activeSessionID,
                interactionsDisabled: sidebarDisabled,
                onSelect: { stored in connectStored(stored) },
                onDelete: { stored in
                    sessionListViewModel.delete(stored)
                    if activeSessionID == stored.id {
                        activeSessionID = nil
                    }
                },
                onNew: { disconnectToForm() }
            )
            .frame(minWidth: 170, idealWidth: 190, maxWidth: 260)

            detail
                .frame(minWidth: 590, maxWidth: .infinity)
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
                    Button("Trennen") {
                        disconnectToForm()
                    }
                    .disabled(transferViewModel.isRunning)
                }
                .padding(8)

                Divider()

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

                TransferBar(viewModel: transferViewModel)
            }
        } else {
            ConnectionFormView(viewModel: connectionViewModel) { fs in
                startSession(with: fs)
            }
        }
    }

    /// Nach erfolgreichem Verbinden: Panes aufbauen und ggf. Session speichern.
    private func startSession(with fs: any RemoteFileSystem) {
        session = BrowserSession(
            localFS: LocalFileSystem(),
            remoteFS: fs,
            local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
            remote: RemoteBrowserViewModel(fs: fs)
        )
        transferViewModel = TransferViewModel()

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

    private func disconnectToForm() {
        guard !isReconnecting else { return }
        Task {
            await teardownSession()
        }
    }

    private func teardownSession() async {
        if let session {
            await session.remote.disconnect()
        }
        connectionViewModel.clearPassword()
        session = nil
        activeSessionID = nil
    }

    /// Lokal ausgewählte DATEI → aktuelles Remote-Verzeichnis.
    @ViewBuilder
    private func uploadButton(_ session: BrowserSession) -> some View {
        let selected = session.local.selectedItem
        Button {
            guard let selected else { return }
            Task {
                await transferViewModel.run(
                    fileName: selected.name, direction: .upload,
                    source: session.localFS, sourcePath: selected.path,
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { await session.remote.refresh() }
                )
            }
        } label: {
            Label("Hochladen", systemImage: "arrow.up")
        }
        .tint(DesignTokens.localAmber)
        .disabled(selected == nil || selected?.kind != .file || transferViewModel.isRunning)
        .help("Ausgewählte lokale Datei ins Remote-Verzeichnis hochladen")
    }

    /// Remote ausgewählte DATEI → aktuelles lokales Verzeichnis.
    @ViewBuilder
    private func downloadButton(_ session: BrowserSession) -> some View {
        let selected = session.remote.selectedItem
        Button {
            guard let selected else { return }
            Task {
                await transferViewModel.run(
                    fileName: selected.name, direction: .download,
                    source: session.remoteFS, sourcePath: selected.path,
                    destination: session.localFS,
                    destinationDirectory: session.local.currentPath,
                    onCompleted: { await session.local.refresh() }
                )
            }
        } label: {
            Label("Herunterladen", systemImage: "arrow.down")
        }
        .tint(DesignTokens.remoteBlue)
        .disabled(selected == nil || selected?.kind != .file || transferViewModel.isRunning)
        .help("Ausgewählte Remote-Datei ins lokale Verzeichnis herunterladen")
    }

    /// Gedroppte Datei-URLs sequenziell hochladen (Ordner werden übersprungen).
    /// WICHTIG: awaited-Schleife — TransferViewModel.run verwirft parallele
    /// Aufrufe (isRunning-Guard); erst M5 bringt eine echte Queue.
    private func uploadDropped(_ urls: [URL], session: BrowserSession) {
        // Wie die Buttons: während eines laufenden Transfers keine neuen Drops
        // annehmen — sonst verschluckt der isRunning-Guard Dateien still (Queue → M5).
        guard !transferViewModel.isRunning else { return }
        let files = urls.filter { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            return exists && !isDirectory.boolValue
        }
        guard !files.isEmpty else { return }
        Task {
            for url in files {
                await transferViewModel.run(
                    fileName: url.lastPathComponent, direction: .upload,
                    source: session.localFS, sourcePath: url.path(percentEncoded: false),
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { await session.remote.refresh() }
                )
            }
        }
    }

    /// Promise-Einlösung: Remote-Datei direkt über die Engine an die
    /// vom Finder vorgegebene URL laden (bewusst ohne TransferBar → M5).
    private func remotePromiseProvider(
        for item: RemoteFileItem, session: BrowserSession
    ) -> RemoteFilePromiseProvider {
        RemoteFilePromiseProvider(item: item) { item, url in
            try await TransferEngine.copyFile(
                from: session.remoteFS, sourcePath: item.path,
                to: session.localFS,
                destinationDirectory: url.deletingLastPathComponent()
                    .path(percentEncoded: false),
                fileName: url.lastPathComponent,
                onProgress: { _ in }
            )
        }
    }
}
