import SwiftUI
import UniformTypeIdentifiers
import macSCPCore

/// A file pane (local or remote): header with a side badge in the brand
/// color, path, up/refresh — the AppKit table underneath.
/// With `onDropURLs` set, the pane becomes a drop target for file URLs
/// (tint highlight).
struct BrowserPane: View {
    let title: String
    let tint: Color
    let softTint: Color
    let viewModel: RemoteBrowserViewModel
    var onDropURLs: (([URL]) -> Void)? = nil
    /// Double-click on a remote FILE row — wired only for the remote pane
    /// (M5e/T4); the local pane leaves this `nil` and keeps its existing
    /// no-op-on-file behavior.
    var onOpenFile: ((RemoteFileItem) -> Void)? = nil
    var pasteboardWriter: ((RemoteFileItem) -> NSPasteboardWriting?)? = nil

    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.9)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(softTint, in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(tint)

                Text(viewModel.currentPath)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(DesignTokens.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task { await viewModel.goUp() }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(!viewModel.canGoUp || viewModel.state == .loading)
                .help(L10n.string("browser.pane.goUpHelp", "Parent directory"))

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.state == .loading)
                .help(L10n.string("browser.pane.refreshHelp", "Refresh"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Rectangle()
                .fill(DesignTokens.hairline)
                .frame(height: 1)

            ZStack {
                RemoteFileTableView(
                    items: viewModel.items,
                    selectedPaths: Set(viewModel.selectedItems.map(\.path)),
                    onOpen: { item in Task { await viewModel.open(item) } },
                    onSelect: { viewModel.selectedItems = $0 },
                    onOpenFile: onOpenFile,
                    pasteboardWriter: pasteboardWriter
                )
                .allowsHitTesting(viewModel.state == .loaded)

                if viewModel.state == .loading {
                    ProgressView()
                }

                if case .failed(let message) = viewModel.state {
                    VStack(spacing: 8) {
                        Text(message)
                            .foregroundStyle(.red)
                        Button(L10n.string("browser.pane.retry", "Try again")) {
                            Task { await viewModel.refresh() }
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tint, lineWidth: isDropTargeted && onDropURLs != nil ? 2.5 : 0)
                    .padding(2)
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                guard let onDropURLs else { return false }
                Task {
                    var urls: [URL] = []
                    for provider in providers {
                        if let url = await provider.macscpFileURL() {
                            urls.append(url)
                        }
                    }
                    await MainActor.run { onDropURLs(urls) }
                }
                return true
            }
        }
        .task { await viewModel.load() }
    }
}

fileprivate extension NSItemProvider {
    /// Extracts a file URL from the provider (drop payload).
    func macscpFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
