import AppKit
import SwiftUI
import macSCPCore

/// Beide Seiten einer aktiven Verbindung inklusive der Dateisysteme —
/// die TransferEngine braucht Quelle und Ziel direkt.
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
    @State private var session: BrowserSession?
    @State private var transferViewModel = TransferViewModel()

    var body: some View {
        if let session {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    uploadButton(session)
                    downloadButton(session)
                    Spacer()
                    Button("Trennen") {
                        Task {
                            await session.remote.disconnect()
                            connectionViewModel.clearPassword()
                            self.session = nil
                        }
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
                            guard item.kind == .file else { return nil }
                            return RemoteFilePromiseProvider(item: item) { item, url in
                                try await TransferEngine.copyFile(
                                    from: session.remoteFS, sourcePath: item.path,
                                    to: LocalFileSystem(),
                                    destinationDirectory: url.deletingLastPathComponent()
                                        .path(percentEncoded: false),
                                    fileName: url.lastPathComponent,
                                    onProgress: { _ in }
                                )
                            }
                        }
                    )
                    .frame(minWidth: 280)
                }

                TransferBar(viewModel: transferViewModel)
            }
        } else {
            ConnectionFormView(viewModel: connectionViewModel) { fs in
                session = BrowserSession(
                    localFS: LocalFileSystem(),
                    remoteFS: fs,
                    local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
                    remote: RemoteBrowserViewModel(fs: fs)
                )
                transferViewModel = TransferViewModel()
            }
        }
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
}
