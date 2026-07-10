import SwiftUI
import macSCPCore

/// Queue bar below the panes: compact item list,
/// ↑ amber (upload), ↓ ocean blue (download), errors in system red.
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
                         ? String(format: L10n.string(
                             "transfers.pending", "Transfers — %lld pending"),
                             Int64(viewModel.pendingCount))
                         : L10n.string("transfers.title", "Transfers"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.string("transfers.clear", "Clean up")) { viewModel.clearCompleted() }
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
                Text(L10n.string("transfers.status.queued", "queued"))
                    .font(.caption).foregroundStyle(.secondary)
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
                Text(L10n.string("transfers.status.cancelled", "cancelled"))
                    .font(.caption).foregroundStyle(.secondary)
            case .skipped:
                Text(L10n.string("transfers.status.skipped", "skipped"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}
