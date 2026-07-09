import SwiftUI
import macSCPCore

/// Ein Datei-Pane (lokal oder remote): Kopfzeile mit Seiten-Badge in der
/// Markenfarbe, Pfad, Hoch/Aktualisieren — darunter die AppKit-Tabelle.
struct BrowserPane: View {
    let title: String
    let tint: Color
    let viewModel: RemoteBrowserViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(tint)

                Text(viewModel.currentPath)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task { await viewModel.goUp() }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(!viewModel.canGoUp || viewModel.state == .loading)
                .help("Übergeordnetes Verzeichnis")

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.state == .loading)
                .help("Aktualisieren")
            }
            .padding(8)

            Divider()

            ZStack {
                RemoteFileTableView(
                    items: viewModel.items,
                    selectedPath: viewModel.selectedItem?.path,
                    onOpen: { item in Task { await viewModel.open(item) } },
                    onSelect: { item in viewModel.selectedItem = item }
                )
                // Während des Ladens keine Klicks in die (alte) Liste lassen
                .allowsHitTesting(viewModel.state == .loaded)

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
