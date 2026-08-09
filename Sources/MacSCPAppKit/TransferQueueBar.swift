import SwiftUI
import macSCPCore

/// Queue bar below the panes: compact item list,
/// ↑ amber (upload), ↓ ocean blue (download), errors in system red.
struct TransferQueueBar: View {
    let viewModel: TransferQueueViewModel

    private func tint(for direction: TransferDirection) -> Color {
        direction == .upload ? DesignTokens.localAmber : DesignTokens.remoteBlue
    }

    /// Backend badge label for a cross-backend destination (M16) — reads
    /// the canonical M12 `BackendDescriptor` source, same as
    /// `SessionSidebar.swift`/`TabStripView.swift`, so the label always
    /// tracks the shared badge L10n keys instead of hardcoding a switch.
    private func backendBadgeLabel(_ kind: ConnectionKind) -> String {
        let descriptor = BackendDescriptor.descriptor(for: kind)
        return L10n.string(descriptor.badgeLabelKey, descriptor.badgeLabelDefault)
    }

    var body: some View {
        if viewModel.items.isEmpty {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(DesignTokens.hairline)
                    .frame(height: 1)
                HStack {
                    Text(L10n.string("transfers.empty", "No transfers"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignTokens.inkSecondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        } else {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(DesignTokens.hairline)
                    .frame(height: 1)
                HStack {
                    Text(viewModel.isActive
                         ? String(format: L10n.string(
                             "transfers.pending", "Transfers — %lld pending"),
                             Int64(viewModel.pendingCount))
                         : L10n.string("transfers.title", "Transfers"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignTokens.inkSecondary)
                    Spacer()
                    Button(L10n.string("transfers.clear", "Clean up")) { viewModel.clearCompleted() }
                        .controlSize(.small)
                        .disabled(viewModel.items.allSatisfy {
                            $0.status == .queued || $0.status.isRunning
                        })
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(viewModel.items) { item in
                            row(item)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 110)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: TransferQueueViewModel.Item) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.direction == .upload ? "arrow.up" : "arrow.down")
                .foregroundStyle(tint(for: item.direction))
                .fontWeight(.bold)
                .frame(width: 14)
            Text(item.fileName)
                .foregroundStyle(DesignTokens.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            if let target = item.crossBackendTarget {
                Text(backendBadgeLabel(target.kind))
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(DesignTokens.remoteSoft, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(DesignTokens.inkSecondary)
                Text("→ \(target.name)")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.inkSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if !item.destinationSupportsResume, item.status == .queued || item.status.isRunning {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(L10n.string(
                        "transfers.noResume.hint",
                        "If interrupted, this upload restarts from the beginning."))
            }
            Spacer(minLength: 8)
            switch item.status {
            case .queued:
                Text(L10n.string("transfers.status.queued", "queued"))
                    .font(.caption).foregroundStyle(DesignTokens.inkSecondary)
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
                        .foregroundStyle(DesignTokens.inkSecondary)
                }
                if let fraction = progress.fraction {
                    PillProgress(fraction: fraction, fill: tint(for: item.direction))
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
                    .font(.caption).foregroundStyle(DesignTokens.inkSecondary)
            case .skipped:
                Text(L10n.string("transfers.status.skipped", "skipped"))
                    .font(.caption).foregroundStyle(DesignTokens.inkSecondary)
            case .interrupted:
                // Orange, not red (M5d/T3): interrupted is resumable, not a
                // hard failure — a reconnect can continue it.
                Text(L10n.string("transfers.status.interrupted", "interrupted"))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .font(.system(size: 12))
    }
}

/// Mockup-style progress pill: 5pt capsule track in the hairline color,
/// capsule fill in the transfer direction's brand color (CI rule: amber =
/// upload, blue = download — only the SHAPE comes from the mockup).
private struct PillProgress: View {
    let fraction: Double
    let fill: Color

    private var clampedFraction: Double { min(max(fraction, 0), 1) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DesignTokens.hairline)
                Capsule()
                    .fill(fill)
                    // Empty track at exactly 0; once bytes move, the fill
                    // stays at least capsule-round (5pt).
                    .frame(width: clampedFraction > 0
                           ? max(5, geometry.size.width * clampedFraction)
                           : 0)
            }
        }
        .frame(height: 5)
        .animation(.linear(duration: 0.2), value: fraction)
        // The custom shapes replaced ProgressView — keep the determinate
        // value readable for assistive tech.
        .accessibilityRepresentation { ProgressView(value: clampedFraction) }
    }
}
