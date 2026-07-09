import SwiftUI
import macSCPCore

/// Fortschrittsleiste unter den Panes: ↑ Bernstein (Upload), ↓ Ozeanblau (Download).
struct TransferBar: View {
    let viewModel: TransferViewModel

    private func tint(for direction: TransferDirection) -> Color {
        direction == .upload ? DesignTokens.localAmber : DesignTokens.remoteBlue
    }

    private func arrow(for direction: TransferDirection) -> String {
        direction == .upload ? "arrow.up" : "arrow.down"
    }

    var body: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()
        case .running(let fileName, let direction, let progress):
            HStack(spacing: 10) {
                Image(systemName: arrow(for: direction))
                    .foregroundStyle(tint(for: direction))
                    .fontWeight(.bold)
                Text(fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .tint(tint(for: direction))
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .font(.callout)
                .padding(6)
        case .finished(let fileName, let direction):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(tint(for: direction))
                Text("\(fileName) übertragen")
                    .font(.callout)
            }
            .padding(6)
        }
    }
}
