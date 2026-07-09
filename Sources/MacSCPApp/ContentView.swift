import SwiftUI
import macSCPCore

/// Beide Seiten einer aktiven Verbindung: lokales Pane (Home-Verzeichnis)
/// und Remote-Pane (SFTP). Lebt genau so lange wie die Verbindung.
struct BrowserSession {
    let local: RemoteBrowserViewModel
    let remote: RemoteBrowserViewModel
}

struct ContentView: View {
    @State private var connectionViewModel = ConnectionViewModel(connector: { config in
        try await CitadelFileSystem.connect(config: config)
    })
    @State private var session: BrowserSession?

    var body: some View {
        if let session {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Trennen") {
                        Task {
                            await session.remote.disconnect()
                            connectionViewModel.clearPassword()
                            self.session = nil
                        }
                    }
                }
                .padding(8)

                Divider()

                HSplitView {
                    BrowserPane(
                        title: "Lokal",
                        tint: DesignTokens.localAmber,
                        viewModel: session.local
                    )
                    .frame(minWidth: 280)

                    BrowserPane(
                        title: "Remote",
                        tint: DesignTokens.remoteBlue,
                        viewModel: session.remote
                    )
                    .frame(minWidth: 280)
                }
            }
        } else {
            ConnectionFormView(viewModel: connectionViewModel) { fs in
                session = BrowserSession(
                    local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
                    remote: RemoteBrowserViewModel(fs: fs)
                )
            }
        }
    }
}
