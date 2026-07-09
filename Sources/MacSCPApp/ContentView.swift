import SwiftUI
import macSCPCore

struct ContentView: View {
    @State private var connectionViewModel = ConnectionViewModel(connector: { config in
        try await CitadelFileSystem.connect(config: config)
    })
    @State private var browserViewModel: RemoteBrowserViewModel?

    var body: some View {
        if let browserViewModel {
            BrowserView(viewModel: browserViewModel) {
                self.browserViewModel = nil
            }
        } else {
            ConnectionFormView(viewModel: connectionViewModel) { fs in
                browserViewModel = RemoteBrowserViewModel(fs: fs)
            }
        }
    }
}
