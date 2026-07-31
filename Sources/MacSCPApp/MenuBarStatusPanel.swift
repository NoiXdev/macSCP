import SwiftUI
import macSCPCore

/// The menu-bar button glyph: a calm two-state icon (M11n). Reads
/// `anyTransferActive` (an `@Observable` fold over the tabs) so it flips as
/// soon as a transfer starts or stops.
struct MenuBarStatusLabel: View {
    let model: MenuBarStatusModel

    var body: some View {
        Image(systemName: model.anyTransferActive
            ? "arrow.up.arrow.down.circle.fill"
            : "arrow.up.arrow.down")
    }
}

/// The dropdown panel (`.window` style). One row per tab, grouped transfer
/// line per connection; click a row to raise the window and activate the tab.
struct MenuBarStatusPanel: View {
    let model: MenuBarStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("macSCP").font(.headline)
                Spacer()
                Text(L10n.string("menubar.connections.count", "%d connections")
                    .replacingOccurrences(of: "%d", with: "\(model.connectedCount)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.tabs.isEmpty {
                Text(L10n.string("menubar.empty", "No active connections"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(model.tabs) { tab in
                    MenuBarConnectionRow(tab: tab) { model.focusTab(tab.id) }
                }
            }

            Divider()
            Button(L10n.string("menubar.show.window", "Show macSCP")) {
                model.showMainWindow()
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 300)
    }
}

/// One connection row: title + status dot on line 1, optional grouped
/// transfer summary on line 2. The whole row is a button.
struct MenuBarConnectionRow: View {
    let tab: SessionTab
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(tab.displayTitle).lineLimit(1)
                    Spacer()
                    Text(statusLabel).font(.caption).foregroundStyle(.secondary)
                }
                if let line = transferLine {
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        if tab.isConnected { return .green }
        switch tab.connectionViewModel.state {
        case .connecting: return .yellow
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    private var statusLabel: String {
        if tab.isConnected { return L10n.string("menubar.status.connected", "Connected") }
        switch tab.connectionViewModel.state {
        case .connecting: return L10n.string("menubar.status.connecting", "Connecting…")
        case .failed: return L10n.string("menubar.status.failed", "Failed")
        case .idle: return L10n.string("menubar.status.ready", "Ready")
        }
    }

    /// The grouped transfer line, or nil when the queue is idle.
    private var transferLine: String? {
        guard let summary = tab.transferQueue.activitySummary else { return nil }
        let arrow = summary.direction == .upload ? "↑" : "↓"
        if summary.runningCount > 0 {
            var parts: [String] = []
            let count = L10n.string("menubar.transfer.running", "%d transferring")
                .replacingOccurrences(of: "%d", with: "\(summary.runningCount)")
            parts.append("\(arrow) \(count)")
            if let fraction = summary.fraction {
                parts.append("\(Int((fraction * 100).rounded()))%")
            }
            if let rate = TransferRateFormatting.compactLabel(
                bytesPerSecond: summary.bytesPerSecond, etaSeconds: nil
            ) {
                parts.append(rate)
            }
            return parts.joined(separator: " · ")
        } else {
            return L10n.string("menubar.transfer.queued", "%d queued")
                .replacingOccurrences(of: "%d", with: "\(summary.pendingCount)")
        }
    }
}
