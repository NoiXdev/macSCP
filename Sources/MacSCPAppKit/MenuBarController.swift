import AppKit
import SwiftUI
import macSCPCore

/// AppKit-driven menu-bar status item (M11n, re-landed as an `NSStatusItem`).
///
/// The original implementation used SwiftUI's `MenuBarExtra`, which on
/// macOS 26 drives SwiftUI into an infinite `_sizeThatFits` layout loop at
/// launch (100% CPU, unresponsive window) regardless of `.window`/`.menu`
/// style or content — an OS-level SwiftUI regression that cannot be worked
/// around from inside `MenuBarExtra`. This controller drives an
/// `NSStatusItem` with a plain `NSMenu` instead: no SwiftUI in the menu bar,
/// so that bug class can't recur.
///
/// It holds no connection state of its own — it reads everything from the
/// app-wide `MenuBarStatusModel` bridge (which `ContentView` keeps in sync),
/// exactly like the SwiftUI panel did. The menu is rebuilt on every open
/// (`menuNeedsUpdate`), so it always reflects the live tab state without
/// continuous observation; only the button icon and the item's presence are
/// kept in sync via `withObservationTracking`.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: MenuBarStatusModel
    private let settingsStore: SettingsStore
    private var statusItem: NSStatusItem?

    init(model: MenuBarStatusModel, settingsStore: SettingsStore) {
        self.model = model
        self.settingsStore = settingsStore
        super.init()
        // Defer the first status-item creation off `App.init` (the status bar
        // is not reliably ready that early) onto the next main-actor turn.
        Task { @MainActor in
            self.applyVisibility()
            self.observe()
        }
    }

    // MARK: - Observation

    /// Tracks the two things that change the item OUTSIDE of a menu open: the
    /// Settings toggle (presence) and any running transfer (icon). Re-armed
    /// after each fire, per the `withObservationTracking` contract.
    private func observe() {
        withObservationTracking {
            _ = settingsStore.menuBarEnabled
            _ = model.anyTransferActive
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyVisibility()
                self.updateIcon()
                self.observe()
            }
        }
    }

    private func applyVisibility() {
        if settingsStore.menuBarEnabled {
            if statusItem == nil { install() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let name = model.anyTransferActive
            ? "arrow.up.arrow.down.circle.fill"
            : "arrow.up.arrow.down"
        // The status item is a hit target (clicking it opens the menu below),
        // and the icon is its only label. `accessibilityDescription` is for
        // VoiceOver and produces no hover text, so the button carries its own
        // tooltip. Static on purpose: `updateIcon()` only runs on the
        // visibility flag and `anyTransferActive`, so anything counting
        // connections here would go stale between menu opens.
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "macSCP")
        image?.isTemplate = true
        button.image = image
        button.toolTip = L10n.string("menubar.tooltip", "macSCP — connections and transfers")
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = disabledItem(
            L10n.string("menubar.connections.count", "%d connections")
                .replacingOccurrences(of: "%d", with: "\(model.connectedCount)"))
        menu.addItem(header)
        menu.addItem(.separator())

        if model.tabs.isEmpty {
            menu.addItem(disabledItem(
                L10n.string("menubar.empty", "No active connections")))
        } else {
            for tab in model.tabs {
                menu.addItem(connectionItem(for: tab))
            }
        }

        menu.addItem(.separator())
        let show = NSMenuItem(
            title: L10n.string("menubar.show.window", "Show macSCP"),
            action: #selector(showMainWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func connectionItem(for tab: SessionTab) -> NSMenuItem {
        let item = NSMenuItem(
            title: tab.displayTitle, action: #selector(activateTab(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = tab.id
        item.attributedTitle = attributedTitle(for: tab)
        item.image = statusDot(for: tab)
        return item
    }

    private func attributedTitle(for tab: SessionTab) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: tab.displayTitle,
            attributes: [.font: NSFont.menuFont(ofSize: 0)])
        title.append(NSAttributedString(
            string: "   \(statusLabel(for: tab))",
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        if let line = transferLine(for: tab) {
            title.append(NSAttributedString(
                string: "\n\(line)",
                attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
        }
        return title
    }

    private func statusDot(for tab: SessionTab) -> NSImage? {
        let color: NSColor
        if tab.isConnected {
            color = .systemGreen
        } else {
            switch tab.connectionViewModel.state {
            case .connecting: color = .systemYellow
            case .failed: color = .systemRed
            case .idle: color = .tertiaryLabelColor
            }
        }
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private func statusLabel(for tab: SessionTab) -> String {
        if tab.isConnected {
            return L10n.string("menubar.status.connected", "Connected")
        }
        switch tab.connectionViewModel.state {
        case .connecting: return L10n.string("menubar.status.connecting", "Connecting…")
        case .failed: return L10n.string("menubar.status.failed", "Failed")
        case .idle: return L10n.string("menubar.status.ready", "Ready")
        }
    }

    /// The grouped transfer line, or `nil` when the queue is idle — mirrors
    /// the same rules the SwiftUI panel used, reading the Core roll-up.
    private func transferLine(for tab: SessionTab) -> String? {
        guard let summary = tab.transferQueue.activitySummary else { return nil }
        let arrow = summary.direction == .upload ? "↑" : "↓"
        if summary.runningCount > 0 {
            var parts: [String] = []
            parts.append("\(arrow) "
                + L10n.string("menubar.transfer.running", "%d transferring")
                    .replacingOccurrences(of: "%d", with: "\(summary.runningCount)"))
            if let fraction = summary.fraction {
                parts.append("\(Int((fraction * 100).rounded()))%")
            }
            if let rate = TransferRateFormatting.compactLabel(
                bytesPerSecond: summary.bytesPerSecond, etaSeconds: nil)
            {
                parts.append(rate)
            }
            return parts.joined(separator: " · ")
        }
        return L10n.string("menubar.transfer.queued", "%d queued")
            .replacingOccurrences(of: "%d", with: "\(summary.pendingCount)")
    }

    // MARK: - Actions

    @objc private func activateTab(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        model.focusTab(id)
    }

    @objc private func showMainWindow() {
        model.showMainWindow()
    }
}
