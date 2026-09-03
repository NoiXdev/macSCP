import AppKit
import SwiftUI
import macSCPCore

/// Queue bar below the panes: compact item list,
/// ↑ amber (upload), ↓ ocean blue (download), errors in system red.
struct TransferQueueBar: View {
    let viewModel: TransferQueueViewModel
    /// Display name of the session that owns this queue — the tab's
    /// `titleName`, which is `nil` until a tab connects. It is what turns a
    /// bare remote path in a row's hint into one the user can place, and it
    /// cannot be derived here: the queue holds file systems, not names.
    /// `nil` qualifies nothing rather than inventing a placeholder.
    let sessionName: String?

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
                    cancelAllButton
                    Button(L10n.string("transfers.clear", "Clean up")) { viewModel.clearCompleted() }
                        .controlSize(.small)
                        // Nothing to tidy away while every listed item is
                        // still open work — the same predicate the rows use
                        // to decide whether they offer a cancel, read the
                        // other way round.
                        .disabled(viewModel.items.allSatisfy(\.status.isCancellable))
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

    /// "Cancel all", beside "Clean up": stops every transfer that has not
    /// finished yet, and leaves the finished ones listed for "Clean up" to
    /// remove. Available exactly while the queue reports work in flight —
    /// the gate is the queue's own activity predicate rather than a second
    /// reading of the item list, so this button and the per-row cancels can
    /// never disagree about whether anything is still open.
    @ViewBuilder
    private var cancelAllButton: some View {
        Button(L10n.string("transfers.cancelAll", "Cancel all")) {
            // A deliberate stop by the person at the keyboard, so the swept
            // items must read "cancelled" rather than "connection lost".
            Task { await viewModel.cancelAll(reason: .userRequested) }
        }
        .controlSize(.small)
        .disabled(!viewModel.isActive)
    }

    /// The per-row cancel: stops exactly this one transfer and leaves the
    /// rest of the queue running, including the other files of the same
    /// folder transfer. Offered only while the row is still stoppable — the
    /// queue answers a cancel for exactly those rows, so the button's
    /// visibility and the call's answer come from one predicate.
    @ViewBuilder
    private func cancelButton(_ item: TransferQueueViewModel.Item) -> some View {
        if item.status.isCancellable {
            Button {
                viewModel.cancel(itemID: item.id)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(DesignTokens.inkSecondary)
            .help(L10n.string("transfers.cancel", "Cancel this transfer"))
        }
    }

    /// Both full paths of a row, as one hover hint. The row itself shows a
    /// file name and an arrow, which is enough to recognise a transfer and
    /// not enough to identify one — two tabs uploading `config.yml` draw
    /// the same row. The fold from an item to its two paths lives in Core
    /// (`TransferRowPaths`), because deciding which side of a transfer is
    /// on this machine is a question about the queue's model, not about
    /// layout; this only labels and stacks the answer.
    private func pathsHint(_ item: TransferQueueViewModel.Item) -> String {
        let paths = TransferRowPaths(item: item, sessionName: sessionName)
        return String(
            format: L10n.string("transfers.paths.hint %1$@ %2$@", "From: %1$@\nTo: %2$@"),
            paths.source, paths.destination)
    }

    /// The other half of "on demand": the same two paths, on the
    /// pasteboard, from the row's own context menu — for the times the
    /// answer has to go into a shell or a message rather than just be read.
    /// The one-path-per-line rendering is the fold's own
    /// (`clipboardText`), so what is copied cannot drift from what the hint
    /// above displayed.
    @ViewBuilder
    private func copyPathsButton(_ item: TransferQueueViewModel.Item) -> some View {
        Button(L10n.string("transfers.paths.copy", "Copy paths")) {
            let paths = TransferRowPaths(item: item, sessionName: sessionName)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paths.clipboardText, forType: .string)
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
            cancelButton(item)
        }
        .font(.system(size: 12))
        .help(pathsHint(item))
        .contextMenu {
            copyPathsButton(item)
        }
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
