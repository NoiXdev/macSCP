import SwiftUI
import macSCPCore

struct BrowserView: View {
    let viewModel: RemoteBrowserViewModel
    let onDisconnect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    Task { await viewModel.goUp() }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(!viewModel.canGoUp)
                .help("Übergeordnetes Verzeichnis")

                Text(viewModel.currentPath)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Aktualisieren")

                Button("Trennen") {
                    Task {
                        await viewModel.disconnect()
                        onDisconnect()
                    }
                }
            }
            .padding(10)

            Divider()

            ZStack {
                RemoteFileTableView(items: viewModel.items) { item in
                    Task { await viewModel.open(item) }
                }

                if viewModel.state == .loading {
                    ProgressView()
                }

                if case .failed(let message) = viewModel.state {
                    VStack(spacing: 8) {
                        Text(message)
                            .foregroundStyle(.red)
                        Button("Erneut versuchen") {
                            Task { await viewModel.refresh() }
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .task { await viewModel.load() }
    }
}
