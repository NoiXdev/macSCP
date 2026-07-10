import SwiftUI
import macSCPCore

/// Warteschlangen-Leiste unter den Panes: kompakte Item-Liste,
/// ↑ Bernstein (Upload), ↓ Ozeanblau (Download), Fehler in System-Rot.
struct TransferQueueBar: View {
    let viewModel: TransferQueueViewModel

    private func tint(for direction: TransferDirection) -> Color {
        direction == .upload ? DesignTokens.localAmber : DesignTokens.remoteBlue
    }

    var body: some View {
        if viewModel.items.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Text(viewModel.isActive
                         ? "Übertragungen — \(viewModel.pendingCount) ausstehend"
                         : "Übertragungen")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Aufräumen") { viewModel.clearCompleted() }
                        .controlSize(.small)
                        .disabled(viewModel.items.allSatisfy {
                            $0.status == .queued || $0.status.isRunning
                        })
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(viewModel.items) { item in
                            row(item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 110)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: TransferQueueViewModel.Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.direction == .upload ? "arrow.up" : "arrow.down")
                .foregroundStyle(tint(for: item.direction))
                .fontWeight(.bold)
                .frame(width: 14)
            Text(item.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            switch item.status {
            case .queued:
                Text("wartet").font(.caption).foregroundStyle(.secondary)
            case .running(let progress):
                // Rate/ETA (M5c/T5): compact "1,2 MB/s · 0:42" label, hidden
                // until the queue's rate window (`TransferQueueViewModel`)
                // has enough samples to produce a rate.
                if let label = TransferRateFormatting.compactLabel(
                    bytesPerSecond: progress.bytesPerSecond, etaSeconds: progress.etaSeconds
                ) {
                    Text(label)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .tint(tint(for: item.direction))
                        .frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
            case .finished:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(tint(for: item.direction))
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(message)
            case .cancelled:
                Text("abgebrochen").font(.caption).foregroundStyle(.secondary)
            case .skipped:
                Text("übersprungen").font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}
